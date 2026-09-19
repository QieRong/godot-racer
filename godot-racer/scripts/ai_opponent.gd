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

## 由外部注入：赛道数据源
var track: Node3D = null
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


## 由 main.gd 在赛道生成好之后调用：绑定赛道、摆上发车格、注入速度/圈数/抓地力。
func setup(p_track: Node3D, p_grid_index: int, p_speed_kmh: float, p_laps: int, p_friction_mult: float) -> void:
	track = p_track
	grid_index = maxi(0, p_grid_index)
	speed_cap_kmh = maxf(20.0, p_speed_kmh)
	laps_target = maxi(1, p_laps)
	apply_friction(p_friction_mult)
	_place_on_grid()


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
	_update_steering(delta)
	_update_drive()


## 追踪中心线：前视点 + 弯道预判限速
func _update_steering(delta: float) -> void:
	var planar_speed := Vector2(linear_velocity.x, linear_velocity.z).length()
	var lookahead := clampf((lookahead_base + planar_speed * lookahead_speed_gain) \
		* lerpf(0.65, 1.0, clampf(skill, 0.0, 1.0)), lookahead_min, lookahead_max)
	var target: Vector3 = track.call("centerline_point", _arc + lookahead)
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


## 弯道限速：沿前方多个距离采样**每一个弯的曲率**，取最严格的那个限速。
##
## 为什么不能只看一个点：第一版只比较"10m 处"和"45m 处"的方位差，
## 结果四台车全部在同一个发夹弯推头蹭墙停住（实测自救点集中在 Checkpoint3 前）。
## 45m 的采样可能已经跨过弯心，等于"弯都过了一半才想起来要减速"。
## 现在改成 12/28/48/72m 四点逐个算曲率、取最小限速，弯还没到就开始收油。
func _target_speed() -> float:
	var limit := speed_cap_kmh
	var prev: Vector3 = track.call("centerline_point", _arc)
	for d in [12.0, 28.0, 48.0, 72.0]:
		var p: Vector3 = track.call("centerline_point", _arc + d)
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
	return limit


func _update_drive() -> void:
	var planar_speed := Vector2(linear_velocity.x, linear_velocity.z).length()
	var want_mps := _target_speed() / 3.6
	# 转向越大越发收油，避免"全油门 + 打死方向"推头撞墙
	want_mps *= lerpf(1.0, 0.72, clampf(absf(_steer), 0.0, 1.0))
	# 贴边降速：已经跑到路面外侧就收油，让纯追踪把它拉回中心。
	# 这是针对"推头出去蹭墙停住"的直接对策 —— 车越靠边越不能给油。
	var center: Vector3 = track.call("centerline_point", _arc)
	var off := Vector2(global_position.x - center.x, global_position.z - center.z).length()
	var road_half := float(track.call("road_half_width"))
	if off > road_half * 0.6:
		var t := clampf((off - road_half * 0.6) / maxf(road_half * 0.4, 0.5), 0.0, 1.0)
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
