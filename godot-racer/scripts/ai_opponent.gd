extends VehicleBody3D
## AI 对手车辆：**纯追踪（pure pursuit）沿中心线行驶**，不做逐帧联网推理。
##
## 设计要点（以及为什么这么做）：
##  ① **复用 race_car.tscn 的车体，只换控制器脚本**。
##     车轮硬点/悬挂/摩擦那些数值是实测调出来的（race_car.tscn 里有长注释记录），
##     抄一份到新场景迟早会两边漂移。所以 AI 车 = 实例化 race_car.tscn + set_script(本脚本)。
##     注意：必须在 add_child **之前** set_script，否则 vehicle.gd 的 _ready 会先跑。
##  ② AI 车辆**不复制关卡参数**：极速由外部注入（关卡建议极速 × ai_speed_scale），
##     抓地力倍率也由外部注入（和玩家车走同一套 apply_friction 逻辑）。
##  ③ 名次用**沿中心线的累积弧长**，不用 Area3D 检查点信号
##     —— 后者在本项目已被证明不可靠（见 vehicle.gd 顶部计圈说明）。
##  ④ 方向盘/油门的符号约定直接沿用 vehicle.gd 实测结论：
##     - 车头在本地 -Z；
##     - 施加**正** engine_force 会让车朝车尾方向走，所以前进要用**负**力矩；
##     - steering 正值 = 左转（与 Input "steer_left" 同向）。

## 跑完一圈时发出（用于名次与 UI）
signal lap_completed(laps_done: int)
## 本关跑完目标圈数时发出
signal race_finished(total_laps: int)

@export var max_engine_force := 4000.0
## 全轮制动强度
@export var brake_force := 55.0
## 松油门时的发动机制动
@export var engine_brake := 6.0
## 最大前轮转角（**弧度**，与 vehicle.gd 的 max_steer 对齐）
@export var max_steer := 0.5
## 转向响应速度（弧度/秒，与 vehicle.gd 的 steer_speed 对齐）。
## ⚠ 这里踩过一个坑：我最初写成 90°/s（=1.57 rad/s），只有玩家车 4.0 rad/s 的 40%，
## 结果 AI 打方向太慢、追不上滑动，一路推头撞墙然后翻车。
@export var steer_speed := 4.0
## 车速越高允许转角越小（与玩家车同参数）
@export var steer_speed_falloff := 0.55
## 侧倾保护：超过这个角度开始收方向
@export var roll_guard_angle := 14.0
## 侧倾保护：到这个角度完全不给方向
@export var roll_guard_limit := 34.0
## 横向加速度上限（m/s²）
@export var max_lateral_accel := 16.0
## 质心高度。**必须显式设成 CUSTOM**：
## VehicleBody3D 默认 center_of_mass_mode = AUTO，会按碰撞盒算出约 0.55m，
## 那个高度实测会侧翻（vehicle.gd 的注释里写得很清楚）。
## AI 车是"换脚本"而不是跑 vehicle.gd 的 _ready，所以那份设置不会自动生效 ——
## 这是 AI 车成片翻车的**主因**，实测 up.y = -1.00 全底朝天。
@export var center_of_mass_height := 0.2
## 前视距离基数（米）。9m 而不是 12m：8m 宽的路面上，22m 的前视点会直接
## 切到发夹弯内侧去（瞄准点落在墙上），车就被带出去了。
@export var lookahead_base := 9.0
## 前视距离随速度增长的系数（秒）
@export var lookahead_speed_gain := 0.5
## 前视距离上下限（米）
@export var lookahead_min := 8.0
@export var lookahead_max := 28.0
## 弯道减速强度（0 = 不减速，1 = 标准）
@export var corner_slowdown := 1.0
## 弯道目标速度的下限比例（相对极速），防止慢到停住。
## 0.30 而不是 0.42：极地关卡的发夹弯上 0.42×216 ≈ 91 km/h 仍然太快，
## 实测四台车都在同一个弯推头出去蹭墙。
@export var min_speed_frac := 0.30
## "技术"系数（0.5~1.0）：越低前视越短、走线越晃，用来做难度层次。
## 不直接改极速 —— 极速由关卡的 ai_speed_scale 决定，两个旋钮别互相打架。
@export var skill := 0.92

## 巡航车道偏移（米，正数 = 赛道前进方向的右侧）。
##
## 为什么要偏移：玩家基本沿中心线跑，如果 AI 也咬中心线，两台车就是**抢同一条线**，
## 一路互相顶。给 AI 一条自己的车道，才是真正的"并排跑"。
## 具体取多少、以及为什么是这个值，见 docs/ai-opponent-design.md 的距离计算。
## setup() 里会按路宽夹紧，保证不会把 AI 挤到路肩外。
@export var lane_offset := 2.4
## 车道偏移的留白：AI 车半宽 + 这么多余量之外就贴边了，不能再往外偏
const LANE_EDGE_MARGIN := 0.7
## 车体半宽（米）。用**车体包围盒**（1.73m）而不是碰撞盒（1.60m）——
## 视觉上不能压线，碰撞盒窄一点是另一回事。所有间距计算都基于这个值，
## 推导见 docs/ai-opponent-design.md。
const BODY_HALF_WIDTH := 0.875

## 由外部注入：赛道数据源
var track: Node3D = null
## 由外部注入：障碍物场（可为 null）。AI 只做"这条车道被挡了就换边"，
## 不做逐帧规划 —— 够用，而且不会因为规划失败而卡死。
var obstacle_field: Node = null
## 由外部注入：玩家车。用于**主动避让**（见 _avoid_player_lane / _player_ahead_speed）
var player: Node3D = null
## 避让时离对方至少留出的横向净距（米）。车宽 1.75 之外再留这么多，
## 既不擦碰、也不至于绕得像躲瘟神。
const AVOID_MARGIN := 0.35
## 纵向"我跟前有车"的判定距离（米）
const FOLLOW_GAP := 9.0
## 我方车宽（米）
const CAR_WIDTH := 1.75
## 每帧算好的"玩家避让后的车道"，供 _effective_lane 复用
var _avoid_lane := 0.0
## 玩家是否就在我正前方（决定要不要跟车减速）
var _follow_speed_kmh := -1.0
## 本帧实际使用的车道偏移（会被障碍物临时改掉），避免一帧内重复查询
var _lane_now := 0.0
## 目标极速（km/h）= 关卡建议极速 × ai_speed_scale
var speed_cap_kmh := 150.0
## 目标圈数
var laps_target := 2
## 发车格位次（0 起）
var grid_index := 0
## 是否已发车
var armed := false

var _steer := 0.0
## 当前所在弧长（米）
var _arc := 0.0
var _prev_arc := 0.0
var _laps := 0
## 是否已经压过起终点线。
## **出生在门后方（弧长接近周长），出发后几米就会自然压线一次**，
## 那次是"发车"，不是"跑完一圈"。不抑制的话计时会立刻虚报 1 圈
## （实测：861m 的赛道 2.4 秒就报 1 圈）。玩家车在 P1 踩过同一个坑，
## 那边用的是 _lap_suppressed，这里用同样的思路。
var _crossed_start := false
## 压线次数（含发车那次），用于算单调递增的进度
var _crossings := 0
## 累积进度 = 圈数 × 周长 + 弧长，用于名次排序
var _progress := 0.0
var _total_len := 1.0
var _start_arc := 0.0
var _steer_wheels: Array[VehicleWheel3D] = []
var _drive_wheels: Array[VehicleWheel3D] = []
var _wheel_friction_base := {}
var _all_wheels: Array[VehicleWheel3D] = []
## 轴距（_ready 里从车轮硬点实测）
var _wheel_base := 2.1
## 卡住计数（贴墙/被撞停）
var _still_frames := 0
var _rescue_count := 0
var _last_pos := Vector3.ZERO


func _ready() -> void:
	for child in get_children():
		if child is VehicleWheel3D:
			var w: VehicleWheel3D = child
			_all_wheels.append(w)
			if w.use_as_steering:
				_steer_wheels.append(w)
			if w.use_as_traction:
				_drive_wheels.append(w)
	# 质心必须自己设：换脚本后 vehicle.gd 的 _apply_center_of_mass() 不会跑，
	# 留着 AUTO（≈0.55m）会成片翻车。
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, center_of_mass_height, 0.0)
	_measure_wheel_base()
	_last_pos = global_position
	_prev_arc = _arc
	# 保证 _lane_point 在任何时刻都有有效车道（_physics_process 会逐帧刷新）
	_lane_now = lane_offset


## 从车轮硬点实测轴距（和 vehicle.gd 同一套算法，避免两边写死不同值）。
func _measure_wheel_base() -> void:
	var front_z := 0.0
	var rear_z := 0.0
	var fn := 0
	var rn := 0
	for w in _all_wheels:
		if w.use_as_steering:
			front_z += w.position.z
			fn += 1
		elif w.use_as_traction:
			rear_z += w.position.z
			rn += 1
	if fn > 0 and rn > 0:
		_wheel_base = absf(front_z / float(fn) - rear_z / float(rn))
	if _wheel_base < 0.5:
		_wheel_base = 2.1


## 由 main.gd 在赛道生成好之后调用：绑定赛道、摆到玩家旁边、注入速度/圈数/抓地力。
## p_player 用于"与玩家并排发车"——位置直接由玩家的实际出生位姿推出，
## 这样不用在这里重算车头白线偏移（那份计算在 vehicle.gd，重复一份迟早漂移）。
func setup(p_track: Node3D, p_grid_index: int, p_speed_kmh: float, p_laps: int,
		p_friction_mult: float, p_player: Node3D = null) -> void:
	track = p_track
	grid_index = maxi(0, p_grid_index)
	speed_cap_kmh = maxf(20.0, p_speed_kmh)
	laps_target = maxi(1, p_laps)
	apply_friction(p_friction_mult)
	_clamp_lane()
	_lane_now = lane_offset
	if p_player != null:
		_place_beside(p_player)
	else:
		_place_on_grid()


## 按路宽夹紧车道偏移：AI 的外侧车轮不能压到路肩外。
## 上限 = 半路宽 − (AI 车半宽 + 余量)。8m 宽的极地关卡上限约 2.4m，
## 正好等于默认值；更宽的关卡不夹。
func _clamp_lane() -> void:
	if track == null or not track.has_method("road_half_width"):
		return
	var road_half := float(track.call("road_half_width"))
	var max_lane := road_half - (BODY_HALF_WIDTH + LANE_EDGE_MARGIN)
	lane_offset = clampf(lane_offset, 0.0, maxf(0.5, max_lane))


## 摆到玩家**旁边**（同一纵向位置，横向错开 lane_offset）。
##
## 为什么并排而不是排在后面：玩家只有一台对手，排在后面就只是"跟车"，
## 并排才是"对手"。位置直接用玩家的位置 + 右向偏移，两台车一定齐头。
func _place_beside(player: Node3D) -> void:
	var fwd := -player.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x)     # 赛道前进方向的右侧
	global_position = player.global_position + side * lane_offset
	_face_along(fwd)
	if track != null and track.has_method("nearest_on_centerline"):
		_arc = float(track.call("nearest_on_centerline", global_position, -1.0).get("arc", 0.0))
		_prev_arc = _arc
		_progress = _arc
	_total_len = maxf(1.0, float(track.call("road_length"))) if track != null else 1.0
	_last_pos = global_position
	print("[AI对手#%d] 已与玩家并排：横向偏移 %.2fm（本方右侧），纵向与玩家齐头"
		% [grid_index, lane_offset])


## 抓地力倍率：和玩家车同一套做法（记录基准值，避免换关卡越乘越小）
func apply_friction(mult: float) -> void:
	for w in _all_wheels:
		if not _wheel_friction_base.has(w):
			_wheel_friction_base[w] = w.wheel_friction_slip
		w.wheel_friction_slip = float(_wheel_friction_base[w]) * clampf(mult, 0.2, 2.0)


## 摆到发车格：起终点门**后方**按位次排开，避免和玩家车/彼此重叠出生。
## 两列一排：位次 0/1 在第一排，2/3 在第二排，依此类推。
func _place_on_grid() -> void:
	if track == null or not track.has_method("centerline_point"):
		return
	_total_len = maxf(1.0, float(track.call("road_length")))
	var sf = track.get("start_finish_t")
	_start_arc = _total_len * float(sf) if sf != null else 0.0
	var row := grid_index / 2
	var side := 1.0 if grid_index % 2 == 0 else -1.0
	var back := 6.0 + float(row) * 6.0
	# 横向间距必须随路宽收缩：固定 1.7m 在 8m 宽的极地关卡上会把车摆到路肩
	# （实测 AiCar3 离中心线 4.36m > 半路宽 4.0m，等于出生就在路外）。
	var road_half := float(track.call("road_half_width"))
	var lat_max := maxf(0.8, minf(1.7, road_half * 0.42))
	var lateral := side * lat_max
	var d := fposmod(_start_arc - back, _total_len)
	var fwd: Vector3 = track.call("centerline_forward", d)
	var side_dir := Vector3(fwd.z, 0.0, -fwd.x)
	if side_dir.length() < 0.001:
		side_dir = Vector3.RIGHT
	side_dir = side_dir.normalized()
	# 出生高度贴着行驶高度（玩家车出生是 y≈0.53）。
	# 之前写 +1.2 会让车从空中掉下来弹一下 —— 既是多余的视觉抖动，
	# 也污染物理耗时测量（实测"怠速 9.73ms"比"行驶中 5.53ms"还贵，就是落地抖动造成的）。
	global_position = track.call("centerline_point", d) + side_dir * lateral + Vector3(0, 0.6, 0)
	_face_along(fwd)
	_arc = d
	_prev_arc = d
	_progress = d
	_last_pos = global_position


## 让车头（本地 -Z）对准给定水平方向。
## 注意：不能写 `global_transform.basis = ...` —— Transform3D 是值类型，
## 那样只会改到一个临时副本。必须先取出、改、再整体赋回。
func _face_along(dir: Vector3) -> void:
	var f := Vector3(dir.x, 0.0, dir.z)
	if f.length() < 0.001:
		f = Vector3.FORWARD
	f = f.normalized()
	var z_axis := -f
	var x_axis := Vector3.UP.cross(z_axis)
	if x_axis.length() < 0.001:
		x_axis = Vector3.RIGHT
	x_axis = x_axis.normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	var t := global_transform
	t.basis = Basis(x_axis, y_axis, z_axis)
	global_transform = t


func _physics_process(delta: float) -> void:
	if track == null or not armed:
		# 未发车：不给油、不给方向，但给一点刹车防止在坡上溜车
		for w in _all_wheels:
			w.engine_force = 0.0
			w.brake = 10.0
		return
	_update_progress()
	_update_stuck_rescue()
	_lane_now = _effective_lane()
	_update_steering(delta)
	_update_drive()


## 本帧应该跑哪条车道：先按障碍换边，再按**玩家**换边。
##
## AI 原来只守自己车道、遇到障碍才换边，对玩家是"撞上就撞上"。
## 现在把玩家当成一个会动的障碍来处理：如果玩家占住了我这条线，
## 就绕到空的那一侧 —— 这才是"会开车的对手"。
func _effective_lane() -> float:
	var lane := lane_offset
	if obstacle_field != null and obstacle_field.has_method("clear_lane_for"):
		lane = float(obstacle_field.call("clear_lane_for", _arc, 45.0, lane, BODY_HALF_WIDTH))
	lane = _avoid_player_lane(lane)
	return lane


## 避让玩家：算出玩家相对我的（纵向距离, 横向偏移），占了我的线就换边。
##
## 几个刻意的取舍：
##  ① 只在**玩家在我前方一段距离内**才让 —— 玩家在我后面时我领先，不该乱让；
##  ② 玩家和我并排（纵向距离很小）时**保持车道**，绝不横打方向去挤：
##     并排时突然变线会把两台车都送出去；
##  ③ 换边方向优先选"路更宽的那一侧"，并且夹在路面内。
func _avoid_player_lane(lane: float) -> float:
	_avoid_lane = lane
	_follow_speed_kmh = -1.0
	if player == null or track == null:
		return lane
	var ppos: Vector3 = player.global_position
	# 玩家的弧长与横向偏移（用同一套中心线口径，避免两套坐标打架）
	var near: Dictionary = track.call("nearest_on_centerline", ppos, -1.0)
	var p_arc := float(near.get("arc", _arc))
	var pc: Vector3 = near.get("pos", ppos)
	var pfwd: Vector3 = near.get("forward", Vector3.FORWARD)
	var pside := Vector3(pfwd.z, 0.0, -pfwd.x)
	var p_lat := (ppos - pc).dot(pside)
	# 纵向距离：正数 = 玩家在我前方
	var ahead := fposmod(p_arc - _arc, _total_len)
	if ahead > _total_len * 0.5:
		ahead -= _total_len          # 换算成 [-total/2, total/2]
	var need := CAR_WIDTH + AVOID_MARGIN
	var lateral_gap := absf(p_lat - lane)
	if absf(ahead) <= FOLLOW_GAP:
		# 并排或很近：保持车道，不做横打方向。
		#
		# ⚠ 跟车限速这里修过一个会"把 AI 钉住"的 bug：
		#   原来条件是 `ahead > 0.0`（只要玩家比我靠前哪怕 1 厘米就算），
		#   且下限只有 20 km/h。于是**玩家把车停在 AI 旁边/前面**时，
		#   AI 的目标速度被压到 20 km/h —— 看起来就是"AI 不动"。
		#   现在：① 要求玩家**确实在前方**（>2m，排除浮点噪声）；
		#         ② 只有玩家确实比我慢才跟车；
		#         ③ 下限抬到极速的 60%，保证它仍然是一台在比赛的对手。
		if ahead > 2.0 and lateral_gap < need:
			var p_kmh := Vector2(player.linear_velocity.x, player.linear_velocity.z).length() * 3.6
			if p_kmh < speed_cap_kmh * 0.95:
				_follow_speed_kmh = clampf(p_kmh + 5.0,
					speed_cap_kmh * 0.60, speed_cap_kmh)
		return lane
	if ahead <= 0.0 or ahead > 60.0:
		return lane                  # 在我后面 / 太远：不让
	if lateral_gap >= need:
		return lane                  # 没占我的线：不让
	# 占了我的线：绕到空的那一侧
	var road_half := float(track.call("road_half_width"))
	var left_room := (p_lat - CAR_WIDTH * 0.5) + road_half
	var right_room := road_half - (p_lat + CAR_WIDTH * 0.5)
	var limit := road_half - BODY_HALF_WIDTH - 0.25
	var want: float
	if left_room >= right_room:
		want = p_lat - CAR_WIDTH * 0.5 - BODY_HALF_WIDTH - AVOID_MARGIN
	else:
		want = p_lat + CAR_WIDTH * 0.5 + BODY_HALF_WIDTH + AVOID_MARGIN
	want = clampf(want, -limit, limit)
	_avoid_lane = want
	# 避让时适当松油（不要全速冲过去），但**下限同样抬到极速的 55%**：
	# 原来写 maxf(30.0, speed*0.85)，AI 慢下来之后就只剩 30 km/h，
	# 一路被压着走不出避让状态。
	_follow_speed_kmh = clampf(speed_kmh() * 0.85, speed_cap_kmh * 0.55, speed_cap_kmh)
	return want


## 追踪中心线：前视点 + 弯道预判限速
func _update_steering(delta: float) -> void:
	var planar_speed := Vector2(linear_velocity.x, linear_velocity.z).length()
	var lookahead := clampf((lookahead_base + planar_speed * lookahead_speed_gain) \
		* lerpf(0.65, 1.0, clampf(skill, 0.0, 1.0)), lookahead_min, lookahead_max)
	var target: Vector3 = _lane_point(_arc + lookahead)
	# 车头方向（本地 -Z 即车头）
	var nose := -global_transform.basis.z
	nose.y = 0.0
	if nose.length() < 0.001:
		return
	nose = nose.normalized()
	var to_target := target - global_position
	to_target.y = 0.0
	if to_target.length() < 0.5:
		return
	to_target = to_target.normalized()
	# 带符号夹角：绕 +Y，正值 = 目标在左 = 需要正转向（左转），
	# 与 vehicle.gd 的 "steer_left = +1" 约定一致（推导见文件头注释）。
	var cross_y := nose.cross(to_target).y
	var err := atan2(cross_y, nose.dot(to_target))
	# 车速越高允许的转角越小（与玩家车同一套：高速猛打方向必翻）
	var limit := max_steer * (1.0 - clampf(planar_speed / 40.0, 0.0, 1.0) * steer_speed_falloff)
	limit *= _roll_guard_factor(planar_speed)
	var want := clampf(err / maxf(limit, 0.01), -1.0, 1.0)
	_steer = move_toward(_steer, want * limit, steer_speed * delta)
	steering = _steer


## 侧倾保护系数（0~1），逻辑与 vehicle.gd._roll_guard_factor 一致。
##
## 为什么必须移植：AI 车实测成片翻车（up.y = -1.00 底朝天、接地 2/4、速度 0），
## 因为"打太猛 → 侧倾力矩超过轮距 → 翻车"这条规律和谁在开无关。
## 两个限制取较小值：侧倾角接近上限就收方向；横向加速度超限按比例削。
func _roll_guard_factor(speed: float) -> float:
	if speed < 0.5:
		return 1.0
	var up := global_transform.basis.y.normalized()
	var lean_deg := rad_to_deg(acos(clampf(up.dot(Vector3.UP), -1.0, 1.0)))
	var lean_factor := 1.0
	if lean_deg > roll_guard_angle:
		lean_factor = clampf(1.0 - (lean_deg - roll_guard_angle)
			/ maxf(roll_guard_limit - roll_guard_angle, 1.0), 0.0, 1.0)
	var lateral := speed * speed * tan(absf(_steer)) / maxf(_wheel_base, 0.5)
	var accel_factor := 1.0
	if lateral > max_lateral_accel:
		accel_factor = clampf(max_lateral_accel / lateral, 0.0, 1.0)
	return minf(lean_factor, accel_factor)


## 中心线在弧长 d 处、再往本车道偏移 lane_offset 之后的目标点。
## 纯追踪瞄准的是**这条偏移线**而不是中心线本身 —— 否则 AI 会和玩家抢同一条线。
func _lane_point(d: float) -> Vector3:
	var c: Vector3 = track.call("centerline_point", d)
	# _lane_now 在 _ready 里就已初始化为 lane_offset，_physics_process 每帧刷新，
	# 所以这里一定拿到有效值。**不能**用 `_lane_now if _lane_now != 0.0 else lane_offset`
	# 这种写法：0.0 是合法的车道（绕到路中间），会被误判成"没算过"。
	var lane := _lane_now
	if absf(lane) <= 0.01:
		return c
	var fwd: Vector3 = track.call("centerline_forward", d)
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	return c + side * lane


## 弯道限速：沿前方多个距离采样**每一个弯的曲率**，取最严格的那个限速。
##
## 为什么不能只看一个点：第一版只比较"10m 处"和"45m 处"的方位差，
## 结果四台车全部在同一个发夹弯推头蹭墙停住（实测自救点集中在 Checkpoint3 前）。
## 45m 的采样可能已经跨过弯心，等于"弯都过了一半才想起来要减速"。
## 现在改成 12/28/48/72m 四点逐个算曲率、取最小限速，弯还没到就开始收油。
func _target_speed() -> float:
	var limit := speed_cap_kmh
	var prev: Vector3 = _lane_point(_arc)
	for d in [12.0, 28.0, 48.0, 72.0]:
		var p: Vector3 = _lane_point(_arc + d)
		var a := prev - global_position
		var b := p - prev
		a.y = 0.0
		b.y = 0.0
		if a.length() > 0.5 and b.length() > 0.5:
			var bend := absf(a.normalized().angle_to(b.normalized()))
			# 0° 弯 = 全速；bend 到 25° 就压到下限（比原来的 35° 更早介入）
			var frac := clampf(1.0 - corner_slowdown * (bend / deg_to_rad(25.0)), min_speed_frac, 1.0)
			limit = minf(limit, speed_cap_kmh * frac)
		prev = p
	# 跟车限速：正前方有车（并排或紧跟）时不超过它的速度，避免直接顶上去。
	# 这是"避让"的纵向那一半 —— 只靠横打方向躲不开已经贴上的车。
	if _follow_speed_kmh > 0.0:
		limit = minf(limit, _follow_speed_kmh)
	return limit


func _update_drive() -> void:
	var planar_speed := Vector2(linear_velocity.x, linear_velocity.z).length()
	var want_mps := _target_speed() / 3.6
	# 转向越大越发收油，避免"全油门 + 打死方向"推头撞墙
	want_mps *= lerpf(1.0, 0.72, clampf(absf(_steer), 0.0, 1.0))
	# 贴边降速：外沿逼近路面边缘就收油，让纯追踪把它拉回来。
	# 这是针对"推头出去蹭墙停住"的直接对策 —— 越靠边越不能给油。
	#
	# ⚠ 判据必须用**绝对边缘位置**，不能用"离中心线的比例"：
	# AI 现在本来就跑在 lane_offset（默认 2.4m）的车道上，如果用
	# "off > 半路宽 × 0.6"（8m 关卡上正好 2.4m）当条件，AI 会从第一帧起
	# 就认为自己贴边、一路收油跑不动。改成"外沿超过路面宽度的 92% 才介入"。
	var center: Vector3 = track.call("centerline_point", _arc)
	var off := Vector2(global_position.x - center.x, global_position.z - center.z).length()
	var road_half := float(track.call("road_half_width"))
	var edge_limit := road_half * 0.92 - BODY_HALF_WIDTH
	if off > edge_limit:
		var t := clampf((off - edge_limit) / maxf(BODY_HALF_WIDTH, 0.5), 0.0, 1.0)
		want_mps *= lerpf(1.0, 0.5, t)
	var force := 0.0
	var brake := 0.0
	if planar_speed < want_mps:
		# 前进用**负**力矩（vehicle.gd 实测结论，正力矩会倒着走）
		force = -max_engine_force * clampf((want_mps - planar_speed) / maxf(want_mps, 1.0) * 2.0, 0.25, 1.0)
	else:
		# 超速了：先松油，超出较多才刹车（避免速度在阈值附近抖动）
		var over := planar_speed - want_mps
		brake = 0.0 if over < 3.0 else clampf(over * 2.0, 0.0, brake_force)
	for w in _drive_wheels:
		w.engine_force = force
	var base_brake := brake if brake > 0.0 else engine_brake * 0.2
	for w in _all_wheels:
		w.brake = base_brake


## 弧长/圈数推进 + 圈数信号
func _update_progress() -> void:
	var near: Dictionary = track.call("nearest_on_centerline", global_position, _arc)
	_prev_arc = _arc
	_arc = float(near.get("arc", _arc))
	# 弧长回绕 = 冲过起终点线（从靠近周长处跳到接近 0）。
	# 出生点在门**后方**（弧长接近周长），所以首帧不能误判成"压线"：
	# 这里要求"上一帧在 75% 之后 且 这一帧到 25% 之前"，出生时两帧都在尾部，不会触发。
	if _prev_arc > _total_len * 0.75 and _arc < _total_len * 0.25:
		_crossings += 1
		if not _crossed_start:
			# 第一次压线 = 发车，不计圈
			_crossed_start = true
		else:
			_laps += 1
			lap_completed.emit(_laps)
			if _laps >= laps_target:
				race_finished.emit(_laps)
	# 进度用**压线次数**（含发车那次）算，不用圈数 ——
	# 否则发车压线后 _arc 从周长附近回绕到 0，进度会倒退一整圈，名次会瞬间反转。
	_progress = float(_crossings) * _total_len + _arc


## 名次用：累积进度（米）
func progress() -> float:
	return _progress


func laps_done() -> int:
	return _laps


## 速度（km/h），报告用
func speed_kmh() -> float:
	return Vector2(linear_velocity.x, linear_velocity.z).length() * 3.6


## 卡住自救：连续 3 秒几乎没动就回到中心线。
## 为什么不用"速度小"单独判定：贴墙慢速过弯时速度也小，但那不是卡住
## （这条教训在玩家车的自动脱困里已经踩过一次）。
func _update_stuck_rescue() -> void:
	var moved := _last_pos.distance_to(global_position)
	_last_pos = global_position
	if speed_kmh() < 3.0 and moved < 0.02:
		_still_frames += 1
	else:
		_still_frames = 0
	var hz := float(Engine.physics_ticks_per_second)
	if _still_frames >= int(hz * 3.0):
		_still_frames = 0
		_rescue_count += 1
		# 诊断数据（先查根因再改代码）：翻车和"被墙咬住"的兜底动作完全不同，
		# 只看"卡住了"没法判断，所以这里把姿态和接地情况一起打出来。
		var up_y := global_transform.basis.y.y
		var grounded := 0
		for w in _all_wheels:
			if w.is_in_contact():
				grounded += 1
		var near: Dictionary = track.call("nearest_on_centerline", global_position, _arc)
		var c: Vector3 = near.get("pos", global_position)
		var fwd: Vector3 = near.get("forward", Vector3.FORWARD)
		print("[AI对手#%d] 卡住自救（第 %d 次）：pos=%s 离中心线 %.2fm 姿态up.y=%.2f（%s）接地 %d/4 速度 %.1f km/h"
			% [grid_index, _rescue_count, global_position, float(near.get("dist", 0.0)),
			   up_y, "翻车" if up_y < 0.5 else "没翻", grounded, speed_kmh()])
		var t := global_transform
		t.origin = c + Vector3(0, 1.0, 0)
		global_transform = t
		_face_along(fwd)
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO


func rescue_count() -> int:
	return _rescue_count
