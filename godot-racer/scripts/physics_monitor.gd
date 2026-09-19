extends Node
## 运行时物理监控：定期把车辆状态打进日志
##
## 用途：无头模式下验证"车到底能不能开"，以及让你在编辑器里调参时能看到真实数值。
## 想看更详细的数据，把 verbose 勾上。

@export var verbose := true
## 多少帧报告一次（60 帧 ≈ 1 秒）
@export var report_interval := 60
## 前 N 帧自动全油门，用于自动化验证；设 0 表示不自动给油
@export var autothrottle_frames := 0
## 自动给油时施加的力矩（每轮）
@export var autothrottle_force := 600.0
## 自动给油时不踩刹车（否则 engine_brake 会抵消掉驱动力）
@export var no_brake := false

## 由命令行强制设置的车身旋转（度），仅诊断用
var _forced_body_rot := 0.0
## 由命令行强制施加的转向角（弧度），仅诊断用
var _forced_steer := 0.0
## 循迹模式：前视距离与赛道曲线
var _follow_lookahead := 0.0
var _follow_curve: Curve3D = null
var _follow_dist := 0.0
## 是否用 Input 动作模拟按键（走 vehicle.gd 的完整输入链路，含限速）
var _use_input_sim := false
## 右键环视复现模式
var _orbit_repro := false
var _orbit_cam: Camera3D = null
var _last_cam_pos := Vector3.ZERO
var _last_car_pos := Vector3.ZERO
## 持续转向（撞护栏测试）
var _persist_steer := false
var _max_off_track := 0.0
## 护栏碰撞探针
var _rail_probe := false
var _rail_probe_speed := 0.0
var _rail_probe_height := 0.6
var _rail_probe_start_dist := 0.0


## 车到赛道中心线的最短距离（横向偏离）
func _nearest_curve_dist() -> float:
	if _follow_curve == null:
		return 0.0
	var length := _follow_curve.get_baked_length()
	var pos := _car.global_position
	var best := INF
	# 粗采样整条曲线：够准且不依赖 Path3D 节点
	var steps := 400
	for i in range(steps):
		var d := float(i) / float(steps) * length
		best = minf(best, pos.distance_to(_follow_curve.sample_baked(d)))
	return best


## 从场景里找到赛道生成器建出的 Curve3D
func _find_track_curve() -> Curve3D:
	var track := _car.get_parent().get_node_or_null("Track")
	if track == null:
		return null
	var c = track.get("_curve")
	if c is Curve3D:
		return c
	return null


## 纯追踪循迹：朝曲线上"前方 lookahead 米"的点打方向
func _follow_track(delta: float) -> void:
	if _follow_curve == null:
		return
	var length := _follow_curve.get_baked_length()
	var pos := _car.global_position

	# 用当前进度附近取样找最近的曲线点（采样法，够用且不依赖 Path3D 节点）
	var best_d := _follow_dist
	var best_dist := INF
	var step := 4.0
	for k in range(-24, 73):
		var d := fposmod(_follow_dist + float(k) * step, length)
		var dist := pos.distance_to(_follow_curve.sample_baked(d))
		if dist < best_dist:
			best_dist = dist
			best_d = d
	_follow_dist = best_d

	# 目标点在前视距离处
	var target := _follow_curve.sample_baked(fposmod(_follow_dist + _follow_lookahead, length))
	var to_target := target - pos
	to_target.y = 0.0
	if to_target.length() < 0.01:
		return

	# 车身横向轴：用 basis.z 表示"侧向"
	var side := _car.global_transform.basis.z
	side.y = 0.0
	side = side.normalized()
	# 目标在左侧还是右侧，决定转向符号（符号由实测标定：正=左转）
	var cross := side.x * to_target.z - side.z * to_target.x
	var steer_cmd := clampf(cross * 0.4, -0.45, 0.45)
	_car.steering = steer_cmd


## 解析命令行覆盖参数，方便做受控的单变量实验：
##   -- --autothrottle=180 --force=3600 --stiff=200 --nobrake
func _parse_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--autothrottle":
			autothrottle_frames = 300
			print("[车辆] 已启用自动油门（5 秒）")
		elif arg.begins_with("--autothrottle="):
			autothrottle_frames = int(arg.split("=")[1])
			print("[车辆] 自动油门 %d 帧" % autothrottle_frames)
		elif arg.begins_with("--force="):
			autothrottle_force = float(arg.split("=")[1])
			print("[车辆] 力矩覆盖 = %.0f N/轮" % autothrottle_force)
		elif arg.begins_with("--stiff="):
			var v := float(arg.split("=")[1])
			for child in _car.get_children():
				if child is VehicleWheel3D:
					child.suspension_stiffness = v
			print("[车辆] 悬挂刚度覆盖 = %.0f" % v)
		elif arg == "--nobrake":
			no_brake = true
			print("[车辆] 本次不踩刹车（排除 engine_brake 干扰）")
		elif arg.begins_with("--bodyrot="):
			# 车身模型绕 Y 的旋转，用于确定哪个角度能让"车头朝前"
			var deg := float(arg.split("=")[1])
			var model := _car.get_node_or_null("CarModel")
			if model is Node3D:
				(model as Node3D).rotation = Vector3(0.0, deg_to_rad(deg), 0.0)
			_forced_body_rot = deg
			print("[车辆] 车身旋转 = %.0f°" % deg)
		elif arg.begins_with("--bodyyaw="):
			# 直接设定整车朝向（度），用于让车在起跑线上对准赛道方向
			var yaw := float(arg.split("=")[1])
			_car.rotation = Vector3(0.0, deg_to_rad(yaw), 0.0)
			print("[车辆] 整车朝向 = %.0f°" % yaw)
		elif arg.begins_with("--steer-const="):
			# 持续打死一个方向，用来测试"能不能冲穿护栏"。
			_forced_steer = float(arg.split("=")[1])
			_persist_steer = true
			print("[复现] 持续转向 = %.2f rad，用于撞护栏测试" % _forced_steer)
		elif arg.begins_with("--rail-probe="):
			# 护栏碰撞探针：把车放到护栏外侧，给它一个朝护栏的初速度，
			# 看它会不会穿过去。参数 = 朝护栏方向的速度 (m/s)
			_rail_probe_speed = float(arg.split("=")[1])
			_rail_probe = true
			print("[复现] 护栏探针：初速度 %.1f m/s 朝护栏" % _rail_probe_speed)
		elif arg.begins_with("--rail-height="):
			# 探针起始高度（米），用于测试"空中飞过去"会不会被空气墙拦住
			_rail_probe_height = float(arg.split("=")[1])
			print("[复现] 探针起始高度 = %.1f m" % _rail_probe_height)
		elif arg.begins_with("--follow="):
			# 沿赛道曲线自动循迹（纯追踪算法）。这是确定性测试：
			# 能跟住曲线 -> 物理与地形没问题，飞出去是"没转向"造成的；
			# 跟不住/被弹飞 -> 地形或悬挂参数有问题。
			_follow_lookahead = float(arg.split("=")[1])
			_follow_curve = _find_track_curve()
			print("[车辆] 循迹模式：前视距离 %.1f m，曲线=%s"
				% [_follow_lookahead, "已找到" if _follow_curve != null else "未找到"])
		elif arg == "--press":
			# 用 Input 动作模拟真实按键（走 vehicle.gd 的完整输入链路，
			# 包括限速逻辑），而不是直接写 engine_force
			_use_input_sim = true
			print("[车辆] 使用 Input 模拟按键（真实输入链路，含限速）")
		elif arg == "--orbit-repro":
			# 复现用户报告的场景：按住右键环视，同时不踩油门，
			# 观察 (a) 相机会不会跳 (b) 车会不会被自动脱困重置
			_orbit_repro = true
			_orbit_cam = get_parent().get_parent().get_node_or_null("ChaseCamera") as Camera3D
			print("[复现] 右键环视复现模式：相机=%s" % str(_orbit_cam))

var _car: VehicleBody3D
var _frames := 0
var _start := Vector3.ZERO


func _ready() -> void:
	_car = get_parent() as VehicleBody3D
	if _car == null:
		push_warning("physics_monitor 的父节点不是 VehicleBody3D，已禁用")
		set_physics_process(false)
		return
	_start = _car.global_position
	_parse_cmdline()


func _physics_process(_delta: float) -> void:
	_frames += 1

	# 自动给油（仅用于自动化验证）
	if autothrottle_frames > 0 and _frames <= autothrottle_frames:
		if _use_input_sim:
			# 走真实输入链路：模拟按住 W，由 vehicle.gd 处理（含限速）
			Input.action_press("accelerate")
		else:
			# 直接写轮子力矩（会绕过 vehicle.gd 的限速，仅供底层调试）
			for child in _car.get_children():
				if child is VehicleWheel3D and child.use_as_traction:
					child.engine_force = autothrottle_force
			if no_brake:
				for child in _car.get_children():
					if child is VehicleWheel3D:
						child.brake = 0.0
	elif _use_input_sim and _frames == autothrottle_frames + 1:
		Input.action_release("accelerate")

	# 强制转向（诊断用；在 vehicle.gd 之后覆盖）
	if _forced_steer != 0.0:
		_car.steering = _forced_steer

	# 撞护栏测试：持续转向，并测量车到赛道中心线的横向偏离
	if _persist_steer and _follow_curve != null:
		var d := _nearest_curve_dist()
		if _frames % 20 == 0:
			print("[复现] 帧%4d 离中心线=%6.1f m  (路面半宽 7.0，护栏在 8.2)  y=%.2f  速度=%.0f km/h"
				% [_frames, d, _car.global_position.y, _car.linear_velocity.length() * 3.6])
		if d > _max_off_track:
			_max_off_track = d

	# 循迹模式（诊断用）
	if _follow_lookahead > 0.0:
		_follow_track(_delta)

	# 护栏碰撞探针：把车放到赛道外侧，给一个朝赛道方向的初速度
	if _rail_probe:
		_rail_probe_step()

	# 右键环视复现：模拟按住右键 + 拖动鼠标，逐帧记录相机与车的位移
	if _orbit_repro:
		_orbit_repro_step()

	# 周期性状态报告
	_report()


## 护栏探针：验证护栏碰撞体到底拦不拦得住车。
## 做法：取赛道中心线上一点，沿横向把车放到护栏**外面**，然后给它一个
## 指向赛道方向的初速度，看它能否穿回赛道内 —— 能穿过去说明碰撞失效。
func _rail_probe_step() -> void:
	if _follow_curve == null:
		return
	var length := _follow_curve.get_baked_length()
	# 用第 0 号检查点附近作为测试点
	var pos := _follow_curve.sample_baked(0.0)
	var ahead := _follow_curve.sample_baked(5.0)
	var fwd := (ahead - pos)
	fwd.y = 0.0
	fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()

	if _frames == 1:
		# 放到护栏外侧 11m（护栏在 8.2m），朝赛道方向推。
		# 高度可调：用来测"从空中飞过去"会不会被空气墙拦住。
		_car.global_position = pos + side * 11.0 + Vector3.UP * _rail_probe_height
		_car.linear_velocity = -side * _rail_probe_speed
		# 关掉重力影响不好做，改为直接测试碰撞：给一个朝护栏的速度
		_rail_probe_start_dist = 11.0
		print("[探针] 车已放到外侧 11.0m、高度 %.1fm 处，朝赛道方向推 %.1f m/s"
			% [_rail_probe_height, _rail_probe_speed])
		return

	var d := _nearest_curve_dist()
	if _frames % 10 == 0:
		print("[探针] 帧%4d 离中心线=%6.2f m  横向速度=%6.2f  y=%.2f"
			% [_frames, d, _car.linear_velocity.dot(side), _car.global_position.y])
	# 判定：如果车穿过了护栏（距离 < 8.2）说明碰撞没拦住
	if d < 8.2 and _frames > 5:
		print("[探针] 结果：车穿过了护栏！当前离中心线 %.2f m（护栏在 8.2）-> 碰撞失效" % d)
		_rail_probe = false
	elif _frames > 120:
		print("[探针] 结果：车被拦在 %.2f m 处（护栏在 8.2）-> 碰撞有效 OK" % d)
		_rail_probe = false


## 复现"右键环视时车跳/重置"：每帧喂一个鼠标移动事件，并检查
## 相机是否出现位置突变、车是否被瞬间挪动（自动脱困的特征）
func _orbit_repro_step() -> void:
	if _orbit_cam == null:
		return
	# 模拟按住右键
	Input.action_press("camera_orbit")
	# 造一个鼠标移动事件喂进去
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(12.0, 0.0)
	_orbit_cam._unhandled_input(ev)

	var cam_pos := _orbit_cam.global_position
	var car_pos := _car.global_position

	if _frames > 2:
		var cam_jump := cam_pos.distance_to(_last_cam_pos)
		var car_jump := car_pos.distance_to(_last_car_pos)
		# 正常情况下相机每帧移动应该很小；车更不该瞬移
		if cam_jump > 2.0 or car_jump > 2.0:
			print("[复现] 帧%4d 相机跳变=%.2fm 车跳变=%.2fm  车pos=%s  相机pos=%s"
				% [_frames, cam_jump, car_jump, car_pos, cam_pos])
		if _frames % 30 == 0:
			print("[复现] 帧%4d 车=(%.1f,%.1f,%.1f) 速度=%.1f 相机=(%.1f,%.1f,%.1f) 相机-车距离=%.1f"
				% [_frames, car_pos.x, car_pos.y, car_pos.z,
				   _car.linear_velocity.length() * 3.6,
				   cam_pos.x, cam_pos.y, cam_pos.z,
				   cam_pos.distance_to(car_pos)])
	_last_cam_pos = cam_pos
	_last_car_pos = car_pos


## 周期性把车辆状态打进日志（诊断与调参用）
func _report() -> void:
	if _frames % report_interval != 0:
		return

	var v := _car.linear_velocity
	var moved := _car.global_position - _start
	var grounded := 0
	var rpm_sum := 0.0
	var rpm_n := 0
	for child in _car.get_children():
		if child is VehicleWheel3D:
			var w: VehicleWheel3D = child
			if w.is_in_contact():
				grounded += 1
			rpm_sum += absf(w.get_rpm())
			rpm_n += 1
	var rpm_avg := rpm_sum / maxf(float(rpm_n), 1.0)

	print("[车辆] t=%4.1fs  pos=(%6.2f,%5.2f,%6.2f)  位移=(%6.2f,%5.2f,%6.2f)  速度=%6.2f m/s (%5.1f km/h)  接地=%d/4  轮均rpm=%6.1f  Y转角=%6.1f°"
		% [_frames / 60.0,
		   _car.global_position.x, _car.global_position.y, _car.global_position.z,
		   moved.x, moved.y, moved.z,
		   v.length(), v.length() * 3.6,
		   grounded, rpm_avg, rad_to_deg(_car.global_rotation.y)])
	print("          实际旋转: rot.y=%.1f°  basis.x=(%.2f,%.2f,%.2f)  basis.z=(%.2f,%.2f,%.2f)"
		% [rad_to_deg(_car.global_rotation.y),
		   _car.global_transform.basis.x.x, _car.global_transform.basis.x.y, _car.global_transform.basis.x.z,
		   _car.global_transform.basis.z.x, _car.global_transform.basis.z.y, _car.global_transform.basis.z.z])

	# 车头判定（不依赖速度，避免下落/侧滑污染结果）：
	# 用"尾翼必然在车后方"这个几何事实。取四个轮心的平均作为车体中心，
	# 从车体中心指向尾翼的向量就是"车尾方向"，它的反方向即车头方向。
	var model := _car.get_node_or_null("CarModel")
	if model is Node3D:
		var wheel_center := Vector3.ZERO
		var wn := 0
		for child in _car.get_children():
			if child is VehicleWheel3D:
				wheel_center += (child as VehicleWheel3D).global_position
				wn += 1
		if wn > 0:
			wheel_center /= float(wn)
		var wing := (model as Node3D).find_child("Wing_Main", true, false)
		var nose_part := (model as Node3D).find_child("Nose_Wing", true, false)
		if wing is Node3D:
			var tail_dir := ((wing as Node3D).global_position - wheel_center)
			tail_dir.y = 0.0
			var nose_dir := -tail_dir.normalized()
			var planar := Vector3(v.x, 0.0, v.z)
			print("          轮心=%s" % wheel_center)
			print("          尾翼=%s  前翼=%s"
				% [(wing as Node3D).global_position,
				   (nose_part as Node3D).global_position if nose_part is Node3D else "?"])
			print("          水平速度=%s  车头方向(几何)=%s" % [planar, nose_dir])
			if planar.length() > 1.0:
				var dot := nose_dir.dot(planar.normalized())
				print("          点积=%+.2f  %s"
					% [dot,
					   "✔ 车头朝前" if dot > 0.5 else ("✘ 车头朝后" if dot < -0.5 else "? 侧向")])

	if verbose:
		# 地面接触信息：判断轮子到底踩在什么上面
		var w0: VehicleWheel3D = null
		for child in _car.get_children():
			if child is VehicleWheel3D and child.use_as_traction:
				w0 = child
				break
		if w0 != null and w0.is_in_contact():
			print("          接触体=%s  接触点=%s  接触法线=%s"
				% [w0.get_contact_body(), w0.get_contact_point(), w0.get_contact_normal()])
		for child in _car.get_children():
			if child is VehicleWheel3D:
				var w: VehicleWheel3D = child
				print("          %-16s 接地=%-5s rpm=%7.1f skid=%.2f force=%6.1f brake=%5.1f"
					% [w.name, w.is_in_contact(), w.get_rpm(), w.get_skidinfo(),
					   w.engine_force, w.brake])
		# 地面碰撞层：如果地面 mask=0，VehicleWheel3D 的射线可能查不到它
		var track := _car.get_parent().get_node_or_null("Track")
		if track != null:
			var ground := track.get_node_or_null("Ground")
			if ground is StaticBody3D:
				print("          地面 layer=%d mask=%d"
					% [ground.collision_layer, ground.collision_mask])
