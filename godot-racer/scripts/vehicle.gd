extends VehicleBody3D
## 赛车控制器：W/S 油门倒车，A/D 转向，空格刹车，R 复位
##
## 使用前提：
##   1. 本脚本挂在 VehicleBody3D 节点上（extends 已声明 VehicleBody3D）
##   2. VehicleBody3D 下必须有 4 个 VehicleWheel3D 子节点
##   3. 轮子的 use_as_traction / use_as_steering 建议在编辑器里勾好；
##      本脚本在 _ready() 里会按节点名兜底再设一遍，避免漏勾

# ---------------------------------------------------------------- 可调参数
@export_group("动力")
## 驱动轮最大力矩（整车质量 1200kg）。实测：Jolt+120Hz 下 4000 时
## 3 秒约 13 km/h、7 秒约 45 km/h，手感属"敏捷但不失控"。
@export var max_engine_force := 4000.0
## 倒车力矩（一般取前进的 40%~60%）
@export var reverse_force := 1800.0
## 松油门时的自然减速。
## 注意：这个值会直接抵消驱动力，实测 8.0 时把 W 的加速拖掉一大半，
## 所以给得很小；想更"溜车"就调到 0。
@export var engine_brake := 2.5
## 限速（km/h）。
## 这个值不是随手定的，而是按赛道几何反推：
##   本赛道两端弯道半径约 150 m，轮胎摩擦系数约 1.0，
##   可通过速度上限 v = sqrt(μ·g·r) = sqrt(1.0×9.8×150) ≈ 38 m/s ≈ 138 km/h。
##   实测车在 127 km/h 冲进弯道仍会转不过来（悬架/侧倾会吃掉一部分抓地），
##   所以保守取 100 km/h，让"不刹车也能过弯"。
## 想要更高极速，就相应放大 _build_curve() 里的弯道半径。
@export var max_speed_kmh := 100.0

@export_group("转向")
## 最大转向角（弧度）。0.5 rad ≈ 28.6°
@export var max_steer := 0.5
## 转向平滑速度，越大越灵敏
@export var steer_speed := 4.0
## 高速削弱转向的比例，避免高速一打方向就翻车
@export var steer_speed_falloff := 0.55

@export_group("制动")
## 刹车力矩（1000kg 建议 25~35）
@export var brake_force := 30.0

@export_group("音效")
@export var idle_pitch := 0.75
@export var max_pitch := 2.4
## 每挡覆盖的轮速区间，按手感调
@export var gear_span := 1400.0

@export_group("脱困")
## 是否开启自动脱困（翻车/卡住几秒后自动复位到最近的检查点）
@export var auto_recover := true
## 判定"卡住"的条件：水平速度低于此值（m/s）且持续时间超过 recover_delay
@export var stuck_speed := 1.0
## 连续卡住多少秒后自动复位
@export var recover_delay := 4.0
## 车身偏离"上方向"超过此角度（度）视为翻车
@export var flip_angle := 70.0

@export_group("稳定性")
## 质心高度（车体本地 y）。**必须手动压低**：
## Godot 的 VehicleBody3D 默认按碰撞盒自动算质心，本车得到约 0.55 m，
## 而轮距只有 ±0.68 m —— 侧倾力矩一超过轮距就翻车（实测：按住 A/D 几秒必翻）。
## 0.2 大致在轮轴线略上方，既压住侧倾，又不至于像"贴地"那样失真。
@export var center_of_mass_height := 0.2

# ---------------------------------------------------------------- 内部状态
var _steer := 0.0                 # 平滑后的转向角
var _wheel_base := 2.1            # 轴距，_ready 里实测
var _driving := false
var _braking := false
var _gear := 1
var _gear_count := 5
var _rpm01 := 0.0                 # 0~1 的挡内转速比例
var _stuck_time := 0.0
var _prev_planar_speed := 0.0      # 上一帧水平速度，用于识别"撞上东西"的速度骤降

## 单位立方体的 8 个角点比例，用于手动变换包围盒
## （AABB.get_endpoint 的参数是 int 索引，不是向量，所以自己算角点）
const CORNER_SCALES := [
	Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
	Vector3(1, 1, 0), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1),
]

var _steer_wheels: Array[VehicleWheel3D] = []
var _drive_wheels: Array[VehicleWheel3D] = []

@onready var _engine_sound: AudioStreamPlayer3D = $EngineSound


func _ready() -> void:
	_apply_center_of_mass()
	classify_wheels()
	_measure_wheel_base()
	_place_on_start_line()
	if _engine_sound and _engine_sound.stream:
		_engine_sound.play()


## 手动压低质心。
## Godot 的 VehicleBody3D 默认 center_of_mass_mode = AUTO，会按碰撞盒算出
## 约 y=0.55 的质心；而本车轮距只有 ±0.68，侧倾力矩一超过轮距就侧翻
## （实测：按住 A/D 几秒必翻）。这是三个手感问题里最根本的一个。
func _apply_center_of_mass() -> void:
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, center_of_mass_height, 0.0)
	print("[车辆] 质心已设为 y=%.2f（AUTO 默认约 0.55，会侧翻）" % center_of_mass_height)


## 把车停在起终点线**后面**。
##
## 为什么需要这个：起终点线不是一个"面"，而是一块横跨路面的长方形贴片
## （宽 = 路面宽，长 = start_line_depth）。如果只把车放在线的中心，
## 车就会骑在线上、一半在线前 —— 这不是合法的起跑位置。
##
## 正确做法：沿赛道方向**后退**，退到"车头刚好压在线后边缘"的位置。
## 后退距离 = 线厚/2 + 车头到车体中心的距离 + 一点余量。
## 这样换赛道形状或换车模型都会自动适配，不必手调坐标。
func _place_on_start_line() -> void:
	var track := get_parent().get_node_or_null("Track")
	if track == null:
		return
	var line_center = track.get("start_line_center")
	var line_fwd = track.get("start_line_forward")
	var line_depth: float = track.get("start_line_depth")
	if not (line_center is Vector3) or not (line_fwd is Vector3):
		return

	var fwd: Vector3 = line_fwd
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return
	fwd = fwd.normalized()

	# 车头到车体中心的距离：用**车头/车尾零件**的实测距离更准，
	# 包围盒会把尾翼和前翼算进去、比轴距大，用它会让车停得过远。
	var half_length := _measure_nose_to_center()
	var clearance := 0.08       # 只留一点点余量，让车头紧贴线后沿（标准起跑位）
	var back := line_depth * 0.5 + half_length + clearance

	var target: Vector3 = (line_center as Vector3) - fwd * back
	global_position = Vector3(target.x, global_position.y, target.z)

	# 车头朝向必须与赛道前进方向一致
	rotation.y = atan2(fwd.x, fwd.z) + PI

	print("[车辆] 出生点已按白线计算：线中心 z=%.2f，线厚 %.2f，车长 %.2f"
		% [(line_center as Vector3).z, line_depth, half_length * 2.0])
	print("[车辆] 沿赛道后退 %.2f m  →  出生位置 %s  （车头朝向赛道方向）"
		% [back, global_position])


## 量"车头到车体中心"的距离。
## 用前翼(Nose_Wing)与尾翼(Wing_Main)的世界位置：车体中心取两者中点，
## 车头到中心的距离 = 前翼到中点距离。这比包围盒准，因为包围盒受翼板影响。
func _measure_nose_to_center() -> float:
	var model := get_node_or_null("CarModel")
	if model == null:
		return 1.85
	var nose := model.find_child("Nose_Wing", true, false)
	var wing := model.find_child("Wing_Main", true, false)
	if nose is Node3D and wing is Node3D:
		var d := (nose as Node3D).global_position - (wing as Node3D).global_position
		d.y = 0.0
		return d.length() * 0.5
	# 退路：用包围盒的一半
	return _measure_body_length() * 0.5


## 量车体包围盒的车长（取 X/Z 中较大的那个水平尺寸）
func _measure_body_length() -> float:
	var model := get_node_or_null("CarModel")
	if model == null:
		return 3.7
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	var found := false
	for mi in _all_meshes(model):
		found = true
		var local: AABB = mi.mesh.get_aabb()
		for s in CORNER_SCALES:
			var p: Vector3 = mi.global_transform * (local.position + local.size * s)
			mn = mn.min(p)
			mx = mx.max(p)
	if not found:
		return 3.7
	var size := mx - mn
	return maxf(size.x, size.z)


func _all_meshes(node: Node) -> Array:
	var out := []
	for c in node.get_children():
		if c is MeshInstance3D and c.mesh != null:
			out.append(c)
		out.append_array(_all_meshes(c))
	return out


## 按节点名把车轮分成转向轮 / 驱动轮，并顺手写好开关
func classify_wheels() -> void:
	for child in get_children():
		if child is not VehicleWheel3D:
			continue
		var wheel: VehicleWheel3D = child
		var n := wheel.name.to_lower()
		if n.contains("front"):
			wheel.use_as_steering = true
			_steer_wheels.append(wheel)
		if n.contains("rear"):
			wheel.use_as_traction = true
			_drive_wheels.append(wheel)

	# 名字里既没有 front 也没有 rear 时，退化为「前两个转向、后两个驱动」
	if _steer_wheels.is_empty() or _drive_wheels.is_empty():
		push_warning("车轮命名未包含 Front/Rear，按子节点顺序退化分配")
		var all: Array[VehicleWheel3D] = []
		for child in get_children():
			if child is VehicleWheel3D:
				all.append(child)
		if all.size() >= 4:
			_steer_wheels = [all[0], all[1]]
			_drive_wheels = [all[2], all[3]]
			all[0].use_as_steering = true
			all[1].use_as_steering = true
			all[2].use_as_traction = true
			all[3].use_as_traction = true


## 轴距 = 前轮平均 Z 与后轮平均 Z 之差
## 注意：Godot 里车长沿 Z 轴（车头朝 -Z），横向才是 X 轴。
## 一开始这里误读了 position.x，而前轮与后轮的 X 都是 ±0.68，
## 平均值相同、相减恒为 0，导致轴距恒被判定为异常。
func _measure_wheel_base() -> void:
	var front_z := 0.0
	var rear_z := 0.0
	var fn := 0
	var rn := 0
	for w in _steer_wheels:
		front_z += w.position.z
		fn += 1
	for w in _drive_wheels:
		rear_z += w.position.z
		rn += 1
	if fn > 0 and rn > 0:
		_wheel_base = absf(front_z / float(fn) - rear_z / float(rn))
	if _wheel_base < 0.5:
		push_warning("轴距测量异常（%.2f m），回退默认值 2.1" % _wheel_base)
		_wheel_base = 2.1


func _physics_process(delta: float) -> void:
	_update_drive()
	_update_steering(delta)
	_update_engine_sound(delta)
	_check_recovery(delta)


## 自动脱困：撞护栏卡住、翻车后自动复位。
##
## 重要教训：最初我把"水平速度长期接近 0"当成卡住的唯一判据，
## 结果玩家停车不动、只想环视看看车时也会被判定为卡住并瞬移到检查点 ——
## 实测复现：静止 4 秒后车被挪动 2.36m，表现为"车一直跳、像被重置"。
## 现在要求同时满足：确实在给油（说明玩家想动却动不了），或者速度刚发生骤降（说明撞上了东西）。
func _check_recovery(delta: float) -> void:
	if not auto_recover:
		return

	# 翻车判定：车身"上方向"与世界上方夹角过大
	var up := global_transform.basis.y.normalized()
	var flipped := up.dot(Vector3.UP) < cos(deg_to_rad(flip_angle))

	var planar := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
	var was_fast := _prev_planar_speed > 5.0
	var now_stalled := planar < stuck_speed
	_prev_planar_speed = planar

	# 只有"想动却动不了"才算卡住：
	#   - 玩家正在踩油门/刹车，速度却上不去；或
	#   - 上一帧还挺快，这一帧突然瘫了（撞击特征）
	var wants_to_move := _driving or _braking
	var just_crashed := was_fast and now_stalled

	if now_stalled and (wants_to_move or just_crashed):
		_stuck_time += delta
	else:
		_stuck_time = 0.0

	if global_position.y >= 3.0:
		return
	# 翻车 -> 原地扶正（保留位置和朝向），不瞬移；
	# 卡住 -> 才退回最近的检查点（这是"想动却动不了"，需要换位置）
	if flipped:
		print("[车辆] 翻车，原地扶正（保留位置与朝向）")
		recover_upright()
		_stuck_time = 0.0
	elif _stuck_time >= recover_delay:
		print("[车辆] 想动却停住 %.1fs，退回最近检查点" % _stuck_time)
		reset_to_checkpoint()
		_stuck_time = 0.0


func _update_drive() -> void:
	# W = accelerate = +1；S = brake_reverse = -1
	var throttle := Input.get_axis("brake_reverse", "accelerate")
	_braking = Input.is_action_pressed("handbrake")
	_driving = absf(throttle) > 0.05 and not _braking

	# 方向说明（实测得出，与直觉相反但很重要）：
	# 本车几何上车头在 X 负侧（前翼 x=-1.66 < 尾翼 x=+1.68）。
	# 实测：施加**正** engine_force 会让车朝"车尾所指方向"移动，等于倒着开。
	# 因此把车头对准行驶方向后，前进要用**负**力矩，倒车用正力矩。
	# （这也是为什么 W 键会给负值 —— 看起来别扭，但是实测结果。）
	var force := 0.0
	if _driving:
		if throttle > 0.0:
			force = -max_engine_force * throttle
		elif linear_velocity.length() < 6.0:
			# 倒车：力矩更小，且要基本停稳才允许挂倒挡
			force = reverse_force * absf(throttle)

	# 限速：超过上限就断开动力。
	# 这里刻意用"速度矢量的水平模长"而不是"沿车头方向的投影" ——
	# 后者一旦车头方向判定错误就会得到负值，导致限速永远不触发
	# （我踩过这个坑：车以 198 km/h 越过 100 的限速而毫无反应）。
	if force != 0.0:
		var planar_speed := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
		if planar_speed * 3.6 > max_speed_kmh:
			force = 0.0

	for w in _drive_wheels:
		w.engine_force = force

	# 刹车：空格全轮制动；松油门时给一点发动机制动
	var b := 0.0
	if _braking:
		b = brake_force
	elif not _driving:
		b = engine_brake
	for child in get_children():
		if child is VehicleWheel3D:
			child.brake = b


func _update_steering(delta: float) -> void:
	var input := Input.get_axis("steer_right", "steer_left")   # D = -1，A = +1
	var speed := linear_velocity.length()
	# 车速越高，允许的转向角越小
	var limit := max_steer * (1.0 - clampf(speed / 40.0, 0.0, 1.0) * steer_speed_falloff)
	_steer = move_toward(_steer, input * limit, steer_speed * delta)
	steering = _steer                                          # VehicleBody3D 总转向


func _update_engine_sound(delta: float) -> void:
	if _engine_sound == null or _engine_sound.stream == null:
		return

	# 用驱动轮实际转速估算引擎转速
	var rpm := 0.0
	for w in _drive_wheels:
		rpm = maxf(rpm, absf(w.get_rpm()))

	# 轮速 -> 挡内比例，到 1 就升挡让音调回落，制造换挡顿挫感
	var raw := rpm / gear_span + 0.12                          # +0.12 保证怠速有底噪
	_gear = clampi(int(raw) + 1, 1, _gear_count)
	_rpm01 = clampf(raw - float(_gear - 1), 0.0, 1.0)

	# 给油时音调更高，松油门时沉闷
	var load_boost := 0.18 if _driving else 0.0
	var pitch := clampf(lerpf(idle_pitch, max_pitch, _rpm01) + load_boost, 0.5, 3.0)
	_engine_sound.pitch_scale = lerpf(_engine_sound.pitch_scale, pitch, 6.0 * delta)
	_engine_sound.volume_db = lerpf(_engine_sound.volume_db, -6.0 + 6.0 * _rpm01, 4.0 * delta)


## 翻车或冲出赛道时按 R 复位到最近的检查点
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		reset_to_checkpoint()


func reset_to_checkpoint() -> void:
	var best: Node3D = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group("checkpoints"):
		var cp := node as Node3D
		if cp == null:
			continue
		var d := global_position.distance_to(cp.global_position)
		if d < best_d:
			best_d = d
			best = cp
	if best == null:
		return
	# 复位到检查点上方一点，姿态对齐检查点朝向。
	# 注意要 +PI：赛道的检查点门是让**本地 +Z** 朝赛道前进方向（见 track_generator
	# 的 Basis(Vector3.UP, atan2(fwd.x, fwd.z))），而本车车头在**本地 -Z** ——
	# 直接照抄门的朝向，车会倒着落在赛道上。
	global_position = best.global_position + Vector3.UP * 0.8
	global_transform.basis = Basis(Vector3.UP, best.global_rotation.y + PI)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


## 原地扶正：把车身摆回水平、**保留当前位置**，清零速度。
##
## 为什么不瞬移到检查点：玩家在起跑区翻车时，"最近的检查点"就是起终点线，
## 表现成"翻个车就被扔回起点"，非常打断手感。扶正只付出一点时间代价。
func recover_upright() -> void:
	# 车头在车体本地 -Z，把它投影到水平面，作为扶正后的朝向
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	# Basis.looking_at 生成的基：-Z 指向目标方向、+Y 朝上，正合本车约定
	global_transform.basis = Basis.looking_at(fwd.normalized(), Vector3.UP)
	global_position += Vector3.UP * 0.3    # 抬离地面一点，免得扶正瞬间卡进路面
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
