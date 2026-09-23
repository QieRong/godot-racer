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
## **发车格**上两台车车身之间要留的净距（米）。
##
## 为什么和巡航车道分开：lane_offset(2.4) 只保证"不抢同一条线"，
## 它减去车宽 1.75 后车身缝只有 **0.65m** —— 玩家反馈"起点两辆车贴太近"（有截图为证）。
## 发车格用 车宽 + 1.25 = 3.0m 的横向偏移，车身缝 1.25m，看起来才像两台车在并排。
## 窄路关卡会被 road_half 夹住（极地 8m 宽只能给到 2.43m），所以这里是"能拉多开拉多开"。
@export var grid_clearance := 1.25
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
## 本关最紧弯半径（米），由 `setup()` 从 `LevelConfig.min_corner_radius` 注入。
## 用途：`ai_target_speed_kmh()` 的 `min_radius` 兜底（见 `setup` 的注释）。
var _min_corner_radius := 0.0
## `max_lateral_accel` 的**基准值**（未按抓地力缩放），-1 = 还没记录过。
## 与 `_wheel_friction_base` 同一个用途：让 `apply_friction()` 可以反复调用而不连乘。
var _max_lateral_accel_base := -1.0
## 弯度/限速的**唯一定义**所在的共享模块（AI 与验收、打印都用这一份）。
##
## ⚠ 用 `preload` 常量而不是每次 `load()`：`load()` 会返回 Variant，
##   GDScript 没法从它推断静态方法的返回类型（报 "Cannot infer the type"），
##   而本项目已经因为"两套限速公式漂移"吃过一次大亏 —— 这里必须走同一份。
const RacingLine := preload("res://scripts/racing_line.gd")
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
	# （几何取证探针不需要 contact_monitor：改用形状投射，见 _probe_collision_geometry）
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
##
## `p_min_corner_radius` 是任务 15 的 ②（物理上限）要用的"本关最紧弯"：
## 它决定 `speed_limit_kmh()` 的兜底值（`corner_radius_at()` 失效时会返回 0，
## 0 会让上限算成 0 km/h → **AI 直接停住**，是最难查的一类症状）。
## 默认 0.0 表示"调用方没提供" —— 那时 `ai_target_speed_kmh` 会退化成"只用策略限速"，
## 不会把 AI 钉住（宁可少一层保护，也不要制造"AI 不动"）。
func setup(p_track: Node3D, p_grid_index: int, p_speed_kmh: float, p_laps: int,
		p_friction_mult: float, p_player: Node3D = null, p_min_corner_radius := 0.0) -> void:
	track = p_track
	grid_index = maxi(0, p_grid_index)
	speed_cap_kmh = maxf(20.0, p_speed_kmh)
	laps_target = maxi(1, p_laps)
	_min_corner_radius = maxf(0.0, p_min_corner_radius)
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
	# 发车格横向偏移：比巡航车道更开（见 grid_clearance 的说明），但必须夹在路面内。
	# 上限与 _clamp_lane 同一口径：半路宽 −（车半宽 + 贴边余量）。
	var off := CAR_WIDTH + grid_clearance
	if track != null and track.has_method("road_half_width"):
		var max_lane := float(track.call("road_half_width")) - (BODY_HALF_WIDTH + LANE_EDGE_MARGIN)
		off = clampf(off, lane_offset, maxf(0.5, max_lane))
	global_position = player.global_position + side * off
	_face_along(fwd)
	if track != null and track.has_method("nearest_on_centerline"):
		_arc = float(track.call("nearest_on_centerline", global_position, -1.0).get("arc", 0.0))
		_prev_arc = _arc
		_progress = _arc
	_total_len = maxf(1.0, float(track.call("road_length"))) if track != null else 1.0
	_last_pos = global_position
	print("[AI对手#%d] 已与玩家并排：横向偏移 %.2fm（本方右侧，车身净距 %.2fm），纵向与玩家齐头"
		% [grid_index, off, off - CAR_WIDTH])


## 抓地力倍率：和玩家车同一套做法（记录基准值，避免换关卡越乘越小）
##
## ⚠ 任务 15 的 ③：这里**还**要按倍率缩放 `max_lateral_accel`。
## 为什么（不修这条，② 在低抓地力关卡上等于没做）：
##   ② 的物理上限 `sqrt(a_lat · R)` 里的 `a_lat` 用的是 `max_lateral_accel`。
##   若它固定 16.0（干燥路的值），L5 冰面会把上限算成 **96 km/h 而不是 51** ——
##   现象是"AI 在冰面依然推头"，极易被误判成"物理极限这条路走不通"。
##   这也是为什么 `--check=aidiag` 的 a_lat 是从 **AI 自己的字段**读的
##   （自己乘一遍 μ 会算出正确值 → 验收绿、游戏错，正是最忌讳的两套逻辑漂移）。
##
## ⚠ 必须**每次从基准值重算**，不能 `max_lateral_accel *= mult` 连乘：
##   换关卡/重开后越乘越小（与上面 `_wheel_friction_base` 同一个坑）。
func apply_friction(mult: float) -> void:
	var m := clampf(mult, 0.2, 2.0)
	for w in _all_wheels:
		if not _wheel_friction_base.has(w):
			_wheel_friction_base[w] = w.wheel_friction_slip
		w.wheel_friction_slip = float(_wheel_friction_base[w]) * m
	if _max_lateral_accel_base < 0.0:
		_max_lateral_accel_base = max_lateral_accel
	max_lateral_accel = _max_lateral_accel_base * m


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


## 避障时向前看多远（米）。45m 是"看得见的下一段路"：再远的话，
## 绕过第一个障碍的车道很可能被更后面的障碍否定掉，反复横跳。
const OBSTACLE_HORIZON := 45.0
## 找不到任何安全车道时，减速等待的下限速度（km/h）与"离障碍多远开始刹车"（米）。
##
## 为什么必须有"等待"而不是"硬塞一条车道"：L4 的静态石头全部落在中心线 ±0.125m
## 的带子里，动态路障又扫过 +2.0~+3.6 —— 当路障正好扫到 AI 的巡航道（+2.4）时，
## **每条现状车道都不安全**。旧实现只挪一次车道就交差，于是 AI 直接瞄准中心线上的
## 石头开过去（自救 55 次、卡死 180 秒）。正确行为是：不强行换道，减速跟在
## 障碍后面等它扫开（见 docs/plans/task15 §三 与 docs/testing.md 的已知缺陷）。
const QUEUE_MIN_KMH := 6.0
const QUEUE_RELEASE_M := 8.0
## 前方路面探测（形状射线）的探测距离（米）。
##
## 为什么还需要它：车道规划管的是"**准备**走哪条线"，管不住"车**现在**在哪"。
## 实测 L4 的失败链是：
##   ① 动态路障扫过 AI 的巡航道（+2.0~+3.6 与 +2.4 重叠）→ AI 换道；
##   ② 车被路障/追线误差推到中心线附近，而**静态石头全摆在中心线 ±0.125m**；
##   ③ 高速下转向权被 `steer_speed_falloff` 与 `_roll_guard_factor` 双重压制，
##      AI 需要 30m+ 才能纠回 2.4m 的横向误差 —— 于是直直撞上石头被楔住；
##   ④ 卡住 3 秒 → 自救把它传送回**中心线**（正好是石头所在位置）→ 无限循环。
## 这个探测 + 卡死时"挑一条通的车道再传送"是 ③④ 的直接对策：
## 它不改变 AI 想去哪，只保证"眼前有东西时不要高速撞上去"。
const PROBE_REACH := 18.0
## 探测到前方障碍时的限速公式：(距离 − 2m)² × 1.8 km/h。
## 形状：12m 外约 100 km/h、5m 外约 16 km/h、2m 内几乎为 0 —— 即"越近越慢"，
## 且**不会**在没障碍时生效（距离足够大时这个上限高于其它限速）。
const PROBE_CLEAR_M := 2.0
const PROBE_CLEAR_GAIN := 1.8
## 横向跟踪误差（实际横向位置 − 目标车道）的判定阈值与限速（米 / km/h）。
##
## 为什么横向误差要限速：本项目车辆的转向权限是**速度相关**的
##（`steer_speed_falloff` + `_roll_guard_factor`），高速时最多只能给到约 0.15 rad，
## 收不住 2m 级别的横向误差。速度降下来，转向权限恢复，才可能回到自己的车道。
const LATERAL_ERR_M := 1.2
const LATERAL_ERR_SPEED_KMH := 45.0
## "等待"状态的解除点：被挡住的障碍的弧长。<= 0（或它的弧长已经过去）表示没在等待。
var _queue_until_arc := -1.0
## 等待期间的目标速度上限（km/h）。-1 = 没在等待。供 aidiag/诊断读取。
var _queue_speed_kmh := -1.0


## 本帧应该跑哪条车道。
##
## 旧实现（已废）：`clear_lane_for()` 只看**第一个**挡路的障碍、把车道挪一次就返回，
## 再用 `_avoid_player_lane()` 覆盖一次 —— 结果既没有验证"最终车道是不是真的通"，
## 也把静态障碍与玩家割裂成了两套逻辑。L4 卡死就是这条链的直接后果。
##
## 新链路（与 AGENTS.md §8.2 一致：候选车道必须同时考虑玩家/AI/静态/动态/边界）：
##   ① 先算"想让玩家之后要跑的车道"（纵向跟车限速也在这里产生）；
##   ② 把障碍物场当成**唯一的占用真相来源**，让它给出一条
##      "在 [arc, arc+45m] 上对**全部**障碍都通"的车道（含赛道边界夹紧）；
##   ③ 找不到安全车道 → 不换道，进入减速等待。
func _effective_lane() -> float:
	var lane := _avoid_player_lane(lane_offset)     # ① 玩家（会动）+ 跟车限速
	if obstacle_field == null or not obstacle_field.has_method("pick_clear_lane"):
		_queue_until_arc = -1.0
		return lane
	var road_half := float(track.call("road_half_width")) if track != null else 4.0
	var lane_limit := maxf(0.0, road_half - BODY_HALF_WIDTH - 0.2)
	var res: Dictionary = obstacle_field.call("pick_clear_lane",
		lane, _arc, OBSTACLE_HORIZON, BODY_HALF_WIDTH, lane_limit)
	# ---- ③ 没有任何候选车道能撑过整段 horizon 时：不硬塞 ----
	if not bool(res.get("found", true)):
		var near: float = obstacle_field.call("nearest_blocker_dist",
			lane, _arc, OBSTACLE_HORIZON, BODY_HALF_WIDTH)
		if near < 0.0:
			_queue_until_arc = -1.0      # 兜底：其实没有障碍（不该发生），放行
			return lane
		_queue_until_arc = _arc + near
		# 车道**保持不变**（不横打方向去挤），只减速 —— 见 _target_speed() 的队列限速。
		return lane
	_queue_until_arc = -1.0
	return float(res.get("lane", lane))


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


## 测出"未经 clamp 的裸弯度"（度），供 `--check=aidiag` 打印。
##
## ⚠ 为什么必须能测裸值：`_target_speed()` 里 `frac` 被 `clampf(..., min_speed_frac, 1.0)`
##   截断过，所以从"最终目标速度"**反推**出的 `bend` 只是个**下界**（饱和时更是假的）。
##   排查"AI 为什么慢"必须看到真实的 `bend`，否则会把"公式把弯读大了"
##   误判成"下限把它钳住了"—— 我第一版就是这么把因果搞反的。
##
## 判定口径与 `_target_speed()` 完全一致（同一个纯函数、同一组采样距离），
## 只是**不**做 clamp、也**不**取 min —— 保证两处不会各说各话。
func debug_bend_at(arc: float) -> float:
	return bend_deg(arc)


## 前方采样距离（米）。`_target_speed()` 与诊断共用一个来源，
## 免得"诊断说 12m 处最弯、生产却在看别的距离"这种无声漂移。
const BEND_PROBES := [12.0, 28.0, 48.0, 72.0]


## 弧长 arc 处，用**同一个纯函数**算出的裸弯度（度）。
## 这个纯函数住在 `racing_line.gd`，因为 `--check=layout` 要用**构造的点列**
## 直接钉住它的守卫（退化向量那条：0.5m 的线段对 12m 求夹角能得出 101°）。
func bend_deg(arc: float) -> float:
	return float(_debug_bend_detail(arc).get("worst_deg", 0.0))


## 裸弯度的**明细**：除了最大夹角，还把每一档采样点的"两点距离 / 线段长度 / 夹角"
## 一起给出来。为什么需要明细 —— 实测 L1 上读到 101°、R=499m 的直线上读到 129°，
## 这个数**在几何上不可能**（R=499m、12m 弦的真实折角是 1.4°）。
## 只看一个汇总量没法定位是"朝向错了"还是"采样点算错了"，所以把中间量全摊开。
##
## ⚠ 明细里的 |a| 是**旧口径**（`prev − global_position` 的模），刻意保留：
##   它是"退化向量"这个 bug 的直接证据 —— 改前第一档 |a| 只有 0.5~0.6m 却报出 101°~121°。
##   改后第一档直接**不参与**（|a| ≤ MIN_BEND_SEG 被守卫挡掉），明细里能看到它变成"—"。
func _debug_bend_detail(arc: float) -> Dictionary:
	var pts: Array = [_lane_point(arc)]
	var dists: Array = [0.0]
	for d in BEND_PROBES:
		pts.append(_lane_point(arc + d))
		dists.append(d)
	var worst := 0.0
	var worst_d := 0.0
	var detail := []
	for i in range(1, pts.size() - 1):
		var a: Vector3 = pts[i] - pts[i - 1]
		var b: Vector3 = pts[i + 1] - pts[i]
		a.y = 0.0
		b.y = 0.0
		var ang := -1.0
		if a.length() > RacingLine.MIN_BEND_SEG and b.length() > RacingLine.MIN_BEND_SEG:
			ang = rad_to_deg(absf(a.normalized().angle_to(b.normalized())))
			if ang > worst:
				worst = ang
				worst_d = float(dists[i + 1])
		# 旧口径参考向量：车位置 → 第 i 个采样点（**退化向量的来源**，只用于打印对照）
		var legacy: Vector3 = pts[i] - global_position
		legacy.y = 0.0
		detail.append("d=%.0f 段长=(%.1f→%.1f) |a|(旧口径)=%.1f 夹角=%s"
			% [float(dists[i + 1]), a.length(), b.length(), legacy.length(),
			   "—（守卫挡掉：线段 ≤%.1fm）" % RacingLine.MIN_BEND_SEG if ang < 0.0 else "%.1f°" % ang])
	# AI 车头与赛道切线的夹角：用来区分"采样点算错"与"AI 真的横着/朝后"
	var tf: Vector3 = track.call("centerline_forward", arc)
	tf.y = 0.0
	var nose: Vector3 = -global_transform.basis.z
	nose.y = 0.0
	var nose_deg := -1.0
	if tf.length() > 0.001 and nose.length() > 0.001:
		nose_deg = rad_to_deg(acos(clampf(nose.normalized().dot(tf.normalized()), -1.0, 1.0)))
	return {"worst_deg": worst, "worst_d": worst_d, "nose_deg": nose_deg,
		"lane0_dist": pts[0].distance_to(global_position), "detail": detail}


## 弯道限速：沿前方多个距离采样**每一个弯的曲率**，取最严格的那个限速。
##
## 为什么不能只看一个点：第一版只比较"10m 处"和"45m 处"的方位差，
## 结果四台车全部在同一个发夹弯推头蹭墙停住（实测自救点集中在 Checkpoint3 前）。
## 45m 的采样可能已经跨过弯心，等于"弯都过了一半才想起来要减速"。
## 现在改成 12/28/48/72m 四点逐个算曲率、取最小限速，弯还没到就开始收油。
##
## ⚠ 弯度的算法在 `RacingLine.bend_angle_deg()`（纯函数、可单测）。**不要**在这里
##   再写一遍"车位置 → 前方点"的夹角 —— 那正是 2026-09 那个把 AI 钉在 43.2 km/h 的
##   退化向量 bug（第一档参考向量只有 0.5m 却报 101°）。
func _target_speed() -> float:
	var limit := speed_cap_kmh
	var pts: Array = [_lane_point(_arc)]
	for d in BEND_PROBES:
		pts.append(_lane_point(_arc + d))
	var bend_deg_v := RacingLine.bend_angle_deg(pts)
	# 0° 弯 = 全速；bend 到 25° 就压到下限（比原来的 35° 更早介入）
	var frac := clampf(1.0 - corner_slowdown * (bend_deg_v / 25.0), min_speed_frac, 1.0)
	limit = minf(limit, speed_cap_kmh * frac)
	# ---- 物理上限（任务 15 的 ②）：**地面的天花板，不受上面那道百分比下限约束** ----
	#
	# 语义（项目所有者拍板）：「物理极限是地面的天花板，策略下限是 AI 愿意降到多慢的地板。
	# 地板不允许高于天花板。」所以 `min_speed_frac` **保留**，但它只约束策略限速那一项；
	# 物理上限永远优先 —— 这也是 `min()` 而不是 `max()` 的原因。
	#
	# 不接这一条的实测后果（旧公式两头都错，与路面无关）：
	#   · L5 近似直道 R=6499m：物理上限 698，策略却只肯给 64.8 → **慢到 9%**
	#   · L5 冰面 R=34m：物理上限 51，策略给 64.8 → **超速 27%，必然推头**
	#
	# ⚠ `min_radius` 必须取本关的 `min_corner_radius`，不能用 0：
	#   `corner_radius_at()` 在赛道未生成/参数非法时**故意**返回 0（让失败可见化），
	#   0 传进去会得到 0 km/h → AI 直接停住（现象是"AI 不动"，本项目最难查的症状）。
	var min_r := _track_min_corner_radius()
	limit = RacingLine.ai_target_speed_kmh(limit, r_corner_now(), max_lateral_accel, min_r)
	# ---- 减速等待（避障的纵向那一半）：所有横向车道都不安全时，跟在障碍后面等 ----
	#
	# 为什么不能"停死"：卡住判定是"3 秒几乎没动"，停死会被自救拖回中心线 →
	# 又正对着石头 → 无限循环（L4 实测自救 55 次就是这么来的）。
	# 所以下限留 6 km/h，并且限速随"离被挡障碍还有多远"线性抬升：
	# 路障扫开的瞬间 AI 已经在动，能立刻补油通过，不需要从 0 起步。
	if _queue_until_arc > 0.0:
		var d_block := fposmod(_queue_until_arc - _arc, _total_len)
		_queue_speed_kmh = maxf(QUEUE_MIN_KMH, (d_block - QUEUE_RELEASE_M) * 3.0)
		limit = minf(limit, _queue_speed_kmh)
	else:
		_queue_speed_kmh = -1.0
	# ---- 横向跟踪误差限速：已经偏出自己车道就先慢下来，别高速硬掰 ----
	#
	# 目标点虽然有 2.4m 的横向偏移，但纯追踪在**高速**下纠不回来（转向权限被
	# 速度相关的两道保护压到只剩约 0.15 rad）。L4 实测就是：车偏到中心线附近后
	# 一路高速直冲，等纠回来已经撞上石头了。先减速，转向权限恢复，才谈得上回线。
	if track != null:
		var here: Dictionary = track.call('nearest_on_centerline', global_position, _arc)
		var hc: Vector3 = here.get('pos', global_position)
		var hf: Vector3 = here.get('forward', Vector3.FORWARD)
		var hside := Vector3(hf.z, 0.0, -hf.x)
		var lat_now := (global_position - hc).dot(hside)
		if absf(lat_now - _lane_now) > LATERAL_ERR_M:
			limit = minf(limit, LATERAL_ERR_SPEED_KMH)
	# ---- 前方路面探测：眼前真有东西就按距离限速（防高速直接撞上去被楔住）----
	var ahead_m := probe_ahead_m()
	if is_finite(ahead_m):
		limit = minf(limit, maxf(0.0, pow(maxf(ahead_m - PROBE_CLEAR_M, 0.0), 2.0) * PROBE_CLEAR_GAIN))
	# 跟车限速：正前方有车（并排或紧跟）时不超过它的速度，避免直接顶上去。
	# 这是"避让"的纵向那一半 —— 只靠横打方向躲不开已经贴上的车。
	if _follow_speed_kmh > 0.0:
		limit = minf(limit, _follow_speed_kmh)
	return limit


## 本关 `min_corner_radius`（赛道节点的字段），取不到就退回 `racing_line` 的默认下限口径。
## 单独一个函数是为了**只在一处**处理"字段可能不存在/为 0"这件事（见 `_target_speed` 的注释）。
func _track_min_corner_radius() -> float:
	# 由 `setup()` 显式注入：`LevelConfig.min_corner_radius` 是**关卡设计参数**，
	# `apply_to_track()` 并没有把它抄到赛道节点上（那边只抄几何/贴图）。
	# 所以不能去 `track.get("min_corner_radius")` —— 那永远拿到 null，会退回 0。
	return maxf(0.0, _min_corner_radius)


## 车当前位置前方的弯道半径（米）—— 物理上限的采样点。
## 与 `--check=aidiag` 的打印**故意取同一个口径**（`arc + 12m`、`ds = 12m`），
## 否则会出现"日志说上限 146、AI 却按别的半径限速"这种两边各说各话。
const PHYS_PROBE_AHEAD := 12.0
const PHYS_PROBE_DS := 12.0
func r_corner_now() -> float:
	if track == null:
		return 0.0
	return RacingLine.corner_radius_at(track, _arc + PHYS_PROBE_AHEAD, PHYS_PROBE_DS)



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
		# 诊断（卡死定位用）：把"想跑哪条车道、前方最近的障碍在哪"打出来。
		#   只看卡死坐标区分不了"车道被算错"与"车道对但车已经被推离车道"——
		#   2026-09 就是靠这两行才发现：自救把车传送回中心线，而石头正在中心线上。
		#   只打最近两条：真正的因果就在最近那个障碍上，全量摊开会让日志没法看。
		print("[AI对手#%d]   [诊断] arc=%.1f 期望车道=%.2f 上一帧实际车道=%.2f 玩家避让车道=%.2f" % [
			grid_index, _arc, _effective_lane(), _lane_now, _avoid_lane])
		if obstacle_field != null and obstacle_field.has_method("debug_ahead"):
			var rows: Array = obstacle_field.call("debug_ahead", _arc, OBSTACLE_HORIZON, _effective_lane(), BODY_HALF_WIDTH)
			if rows.is_empty():
				print("[AI对手#%d]   [诊断] 前方 %.0fm 内没有障碍" % [grid_index, OBSTACLE_HORIZON])
			else:
				for i in range(mini(2, rows.size())):
					print("[AI对手#%d]   [诊断] %s" % [grid_index, String(rows[i])])
		# 真实碰撞几何取证（只打印，不改任何状态）：回答"车到底以什么三维关系撞上石头"。
		# 必须在传送之前调用 —— 传送之后位置就变了，量不到卡死那一刻的几何。
		# 只在调试构建（编辑器 / 本项目验收跑的都是调试构建）里跑：它是纯诊断，
		# 发布构建不该为它付开销，也不需要它刷日志。
		if OS.is_debug_build():
			_probe_collision_geometry()
		# 落点不能无脑用中心线：L4 的静态石头就摆在中心线 ±0.125m 的带子里
		#（见 obstacle_field._pick_lateral 的 safe_max 推导），传送回中心线等于
		# 把车重新摆回石头上 —— 实测 55 次自救全部卡在同一个坐标，就是这个循环。
		# 所以落点优先选当前车道上一条能通的车道，中心线只作兜底。
		var safe_lane := _rescue_lane()
		var t := global_transform
		t.origin = _lane_point_at(c, fwd, safe_lane) + Vector3(0, 1.0, 0)
		global_transform = t
		_face_along(fwd)
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		_lane_now = safe_lane


## 自救落点用：当前车道上通的那条车道偏移；都不通就回 0（中心线）。
##
## 这里的 0 只是最后兜底，不是推荐值：L4 的石头就在中心线带里。
## 之所以还留它，是因为所有车道都被占时总得把车放回路面，
## 而放在中心线至少是一个确定、可复现、且不会掉出赛道的位置。
func _rescue_lane() -> float:
	if obstacle_field == null or not obstacle_field.has_method('pick_clear_lane'):
		return 0.0
	var road_half := float(track.call('road_half_width')) if track != null else 4.0
	var lane_limit := maxf(0.0, road_half - BODY_HALF_WIDTH - 0.2)
	var res: Dictionary = obstacle_field.call('pick_clear_lane',
		0.0, _arc, OBSTACLE_HORIZON, BODY_HALF_WIDTH, lane_limit)
	if bool(res.get('found', false)):
		return float(res.get('lane', 0.0))
	return 0.0


## 把中心线上的点 + 切线 + 车道偏移换算成世界坐标。
## 单独抽出来是因为自救落点与追线目标点要做同一件事，
## 两处各写一遍迟早会漂移（本项目在限速公式上已经吃过一次这种亏）。
func _lane_point_at(c: Vector3, fwd: Vector3, lane: float) -> Vector3:
	var f := Vector3(fwd.x, 0.0, fwd.z)
	if f.length() < 0.001:
		return c
	f = f.normalized()
	var side := Vector3(f.z, 0.0, -f.x)
	return c + side * lane


## 前方路面上离车最近的实体还有多远（米）；够远或没东西则返回 INF。
##
## 用车体大小的形状做投射，而不是一条细射线：细射线会从障碍旁边擦过去，
## 给出前方畅通的假结论 —— 而车是有宽度的（1.73m），擦边就是撞。
## mask=1 与车辆自身的碰撞 mask 一致（地面/护栏/障碍都在层 1），
## 车辆在层 2，所以不会打到玩家或别的 AI（那是 _avoid_player_lane 的职责）。
func probe_ahead_m() -> float:
	if track == null:
		return INF
	var space := get_world_3d().direct_space_state
	if space == null:
		return INF
	var shape := BoxShape3D.new()
	shape.size = Vector3(BODY_HALF_WIDTH * 2.0, 0.5, 0.8)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.collision_mask = 1
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.exclude = [get_rid()]
	var nose := -global_transform.basis.z
	nose.y = 0.0
	if nose.length() < 0.001:
		return INF
	nose = nose.normalized()
	params.transform = Transform3D(Basis(), global_position + Vector3(0, 0.7, 0) + nose * 0.5)
	params.motion = nose * PROBE_REACH
	# cast_motion 返回的是 PackedFloat32Array：[0] = 还能自由移动的比例，
	# [1] = 完全被挡住的比例（两者相等即第一次接触点）。
	# 取较小者 = 最早的接触点，用它换算成「离障碍还有多少米」。
	# 这里踩过一次类型坑：返回值是 PackedFloat32Array 而不是 Dictionary，
	# 写成 Dictionary 会在解析期报 Cannot assign a value of type PackedFloat32Array。
	var fracs: PackedFloat32Array = space.cast_motion(params)
	if fracs.size() < 2:
		return INF
	var frac := minf(fracs[0], fracs[1])
	if frac >= 1.0:
		return INF
	return PROBE_REACH * frac


## ==================== 开发期几何取证探针（不是验收判据）====================
##
## 为什么需要它：2026-09 定位 L4 卡死时，先用 2D 的 lateral 标量算了「石头横向 0.0 + 半宽 0.95
## vs 车半宽 0.875 → 间隙不足」，但那是**估算**：它把视觉 Mesh 的随机 Y 旋转（0.95×√2≈1.34）
## 当成了碰撞尺寸，而 `_place_static()` 里的旋转只加在 MeshInstance3D 上，
## CollisionShape3D **没有**旋转。标量 lateral 也表达不了「3.4m 长的车体斜着停在 1.9m 石头旁」
## 这种真实三维关系。所以这里直接用**物理世界里的真实碰撞形状**算最小间距。
##
## 输出口径：
##   · 车体：BodyCollision（BoxShape3D 1.6×0.7×3.4，父节点内偏移 y=+0.55）的 OBB 八个角点
##     （用的是 global_transform，所以姿态/倾斜都算进去）；
##   · 石头：每个 CollisionShape3D 的世界 AABB（它本来就是轴对齐盒，未旋转）；
##   · 分离量 = max_i(d_i − (half_body_i + half_rock_i))：逐轴分离量，
##     >0 表示分离（值即间隙），<0 表示在该轴上重叠（值即重叠深度）；
##   · 再用引擎自己的 intersect_shape 做一次相交判定，两边互相印证。
##
## 只在卡住自救时调用一次，不参与通过/失败判定，也不改任何物理状态。
func _probe_collision_geometry() -> void:
	var body := get_node_or_null('BodyCollision') as CollisionShape3D
	if body == null or obstacle_field == null:
		return
	var bshape := body.shape as BoxShape3D
	if bshape == null:
		return
	var half := bshape.size * 0.5
	var bt := body.global_transform
	print('[AI对手#%d]   [几何取证] 车体碰撞盒 size=%s 世界中心=%s 车头=%s' % [grid_index, str(bshape.size), str(bt.origin), str(-bt.basis.z)])
	var fwd_t: Vector3 = track.call('centerline_forward', _arc)
	var fwd_h := Vector3(fwd_t.x, 0.0, fwd_t.z)
	if fwd_h.length() < 0.001:
		fwd_h = Vector3.FORWARD
	fwd_h = fwd_h.normalized()
	var lateral_axis := Vector3(fwd_h.z, 0.0, -fwd_h.x)
	var body_center := bt.origin
	var idx := 0
	for it in _static_shapes():
		idx += 1
		var cs: CollisionShape3D = it['cs']
		var sz: Vector3 = it['size']
		var rpos := cs.global_transform.origin
		var rel := rpos - body_center
		var lat_r := rel.dot(lateral_axis)
		var long_r := rel.dot(fwd_h)
		var lo := Vector3(INF, INF, INF)
		var hi := Vector3(-INF, -INF, -INF)
		for corner in _box_corners(rpos, sz):
			var local: Vector3 = bt.affine_inverse() * corner
			lo = Vector3(minf(lo.x, local.x), minf(lo.y, local.y), minf(lo.z, local.z))
			hi = Vector3(maxf(hi.x, local.x), maxf(hi.y, local.y), maxf(hi.z, local.z))
		# ⚠ AABB 的有效分离量（2026-09-23 修过一次）：
		#   车体盒以局部原点为中心、半长 half；石头在车局部的 AABB 是 [lo, hi]。
		#   逐轴分离距离 = max(lo_i − half_i, −half_i − hi_i)，
		#   即「石头整体在车体正侧多远」与「石头整体在车体负侧多远」取较大者。
		#   第一版写成 max(lo_i, −hi_i) − half_i，它在石头偏在一侧时会算出**负值**（假重叠），
		#   而引擎的 intersect_shape 同时报不相交 —— 两边打架就说明公式错了。
		var gap_x := maxf(lo.x - half.x, -half.x - hi.x)
		var gap_y := maxf(lo.y - half.y, -half.y - hi.y)
		var gap_z := maxf(lo.z - half.z, -half.z - hi.z)
		var sep := maxf(gap_x, maxf(gap_y, gap_z))
		var hits := _shape_hits_static(bshape, bt)
		print('[AI对手#%d]   [几何取证] 石头#%d 碰撞盒 size=%s 世界中心=%s' % [grid_index, idx, str(sz), str(rpos)])
		print('[AI对手#%d]     相对车体：横向=%+.2fm 纵向=%+.2fm 高差=%+.2fm' % [grid_index, lat_r, long_r, rel.y])
		print('[AI对手#%d]     分离量（车局部分轴；>0 分离=间隙 / <0 重叠）：x=%+.2f y=%+.2f z=%+.2f → 最小=%+.2f m' % [grid_index, gap_x, gap_y, gap_z, sep])
		print('[AI对手#%d]     引擎 intersect_shape：%s' % [grid_index, '相交' if hits else '不相交'])
	# ---- 被什么挡住：把**车体自己的碰撞盒**沿六个方向各扫一次，看最先撞到谁 ----
	# ⚠ 只在卡住自救时跑一次（每次救援最多一次），所以这里不做缓存优化。
	# 为什么不用 contact_monitor：`get_contact_local_position()` / `get_contact_collider_object()`
	# 这些在 Godot 4.4 的 VehicleBody3D 上并不存在（实测解析期就报 not found）。
	# 形状投射是同一套物理世界的权威回答，而且用的就是车体真实的碰撞盒。
	var space2 := get_world_3d().direct_space_state
	if space2 != null:
		var dirs := {"车体右(+X)": bt.basis.x.normalized(), "车体左(-X)": -bt.basis.x.normalized(),
			"车体前(-Z)": -bt.basis.z.normalized(), "车体后(+Z)": bt.basis.z.normalized(),
			"上(+Y)": Vector3.UP, "下(-Y)": Vector3.DOWN}
		for k in dirs.keys():
			var d: Vector3 = dirs[k]
			var pq := PhysicsShapeQueryParameters3D.new()
			pq.shape = bshape
			pq.transform = bt
			pq.collision_mask = 1
			pq.collide_with_bodies = true
			pq.collide_with_areas = false
			pq.exclude = [get_rid()]
			pq.motion = d * 8.0
			var fr: PackedFloat32Array = space2.cast_motion(pq)
			var frac := 1.0 if fr.size() < 2 else minf(fr[0], fr[1])
			var dist := 8.0 * frac
			# 命中物是谁：用**射线**从盒心往该方向打一条细线，取命中的碰撞体名字。
			# 形状投射本身只给比例，不给对象；射线便宜且足够回答「被谁挡住」。
			var who := '—'
			# 射线要打**穿过**那个面：从盒心出发、终点取在接触点之外一点。
			# 第一次写成 dist + 0.05 时全部命中为空 —— 终点正好落在面上，射线打不到。
			var ray_end := bt.origin + d * (dist + 2.0)
			var ray := PhysicsRayQueryParameters3D.create(bt.origin, ray_end)
			ray.collision_mask = 1
			ray.collide_with_bodies = true
			ray.exclude = [get_rid()]
			var hitr: Dictionary = space2.intersect_ray(ray)
			if not hitr.is_empty():
				var col: Object = hitr.get('collider')
				who = str(col.name) if col != null else '?'
			print('[AI对手#%d]     %s 方向 8m 内最近实体：%s（%.2f m）命中=%s' % [grid_index, k, '无' if frac >= 1.0 else '有', dist, who])
	print('[AI对手#%d]     控制侧读数：前方探测 probe_ahead_m()=%s 队列限速=%.1f 目标车道路径=%.2f 实际横向=%.2f' % [grid_index, (str(probe_ahead_m()) if is_finite(probe_ahead_m()) else 'INF'), _queue_speed_kmh, _lane_now, _cur_lateral()])
	# ---- 动态路障相对车体的实时位置（L4 车道的最大威胁就是它）----
	var dyn_list: Array = obstacle_field.get('_dynamic')
	var di2 := 0
	for dd in dyn_list:
		di2 += 1
		var dnode: Node3D = (dd as Dictionary)['node']
		var drel: Vector3 = dnode.global_position - bt.origin
		print('[AI对手#%d]     动态路障#%d 世界中心=%s 相对车体：横向=%+.2fm 纵向=%+.2fm 高差=%+.2fm' % [grid_index, di2, str(dnode.global_position), drel.dot(lateral_axis), drel.dot(fwd_h), drel.y])
	for w in _all_wheels:
		print('[AI对手#%d]     轮 %s 世界轮心=%s 半径=%.2f 接地=%s' % [grid_index, w.name, str(w.global_position), w.wheel_radius, str(w.is_in_contact())])


## 收集静态障碍的 CollisionShape3D（它们合并在一个 StaticBody3D 里）。
func _static_shapes() -> Array:
	var out: Array = []
	if obstacle_field == null:
		return out
	var body := obstacle_field.get_node_or_null('ObstacleBody')
	if body == null:
		return out
	for c in body.get_children():
		var cs := c as CollisionShape3D
		if cs == null:
			continue
		var bs := cs.shape as BoxShape3D
		if bs == null:
			continue
		out.append({'cs': cs, 'size': bs.size})
	return out


## 轴对齐盒（世界中心 + 尺寸）的 8 个角点。
func _box_corners(center: Vector3, size: Vector3) -> Array:
	var h := size * 0.5
	var out: Array = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				out.append(center + Vector3(h.x * sx, h.y * sy, h.z * sz))
	return out


## 引擎视角的相交判定：该形状放在该 transform 时是否与层 1 的静态体相交。
## 用来跟上面的手工距离计算互相印证 —— 两边不一致就说明算错了。
func _shape_hits_static(shape: Shape3D, xf: Transform3D) -> bool:
	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = xf
	params.collision_mask = 1
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.exclude = [get_rid()]
	return space.intersect_shape(params, 1).size() > 0


## 当前实际横向位置（相对中心线，正数 = 赛道前进方向右侧）。
## 与 `_target_speed()` 里算横向跟踪误差用的是同一套口径 —— 抽出来只为两处一致。
func _cur_lateral() -> float:
	if track == null:
		return 0.0
	var near: Dictionary = track.call('nearest_on_centerline', global_position, _arc)
	var c: Vector3 = near.get('pos', global_position)
	var f: Vector3 = near.get('forward', Vector3.FORWARD)
	var side := Vector3(f.z, 0.0, -f.x)
	return (global_position - c).dot(side)


func rescue_count() -> int:
	return _rescue_count
