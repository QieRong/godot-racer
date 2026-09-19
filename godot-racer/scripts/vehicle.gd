extends VehicleBody3D
## 赛车控制器：W/S 油门倒车，A/D 转向，空格刹车，R 复位，V 切换视角
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
## 是否开启自动脱困（翻车原地扶正 / 卡住后回到最近的检查点）
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

@export_group("出界兜底")
## 是否开启出界自动回赛道
@export var auto_reset_out_of_bounds := true
## 低速时允许偏离中心线的上限 = 护栏中心线 + 这个余量（米）。
## 留一点余量是为了不误伤"贴着墙蹭过去"的正常驾驶。
@export var out_of_bounds_margin := 1.5
## 低速时允许在界外停留多久（秒）
@export var out_of_bounds_delay := 1.0
## 车速超过这个值（m/s）时视为"高速飞出"，界外判定余量收紧到下面这个值
@export var fast_escape_speed := 8.0
## 高速时允许偏离中心线的上限 = 护栏中心线 + 这个余量（米）。
## 高速下界外停留哪怕 0.2s 也会飞很远，所以余量给得很小、且立即复位。
@export var fast_escape_margin := 0.3
## 复位后的无敌时间（秒）。这段时间内不与其它车辆碰撞、也不触发检查点，
## 免得刚回到赛道上就被后车顶飞或被判定成压线。
@export var reset_immunity_time := 2.0

@export_group("车轮动画")
## 让模型里的车轮网格跟着物理轮转。
##
## VehicleWheel3D 只有物理、没有视觉 —— race_car.glb 里的
## Tire_*/Rim_*/Hub_* 是独立节点，**必须手动驱动**，否则车在跑、轮子一动不动。
@export var spin_wheel_meshes := true

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

# ---- 出界兜底 / 复位 用的状态 ----
## 赛道节点（提供中心线查询）。_ready 里找一次，之后不再 get_node。
var _track: Node3D = null
## 最近一次算出的"我在中心线上的弧长"，作为下次局部搜索的起点
var _arc_hint := -1.0
## 连续处于界外的时间
var _out_time := 0.0
## 复位后的剩余无敌时间
var _immunity := 0.0
## 最近通过的检查点顺序（当前保留作诊断用；复位落点由中心线查询决定）
var _last_checkpoint_order := -1
## 复位冷却，避免同一帧/连续帧反复瞬移
var _reset_cooldown := 0.0

## 单位立方体的 8 个角点比例，用于手动变换包围盒
## （AABB.get_endpoint 的参数是 int 索引，不是向量，所以自己算角点）
const CORNER_SCALES := [
	Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
	Vector3(1, 1, 0), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1),
]

## 车辆所在的物理层号（project.godot: 3d_physics/layer_2 = "vehicle"）
const VEHICLE_LAYER := 2
## 离中心线多近时，按 R 只扶正不传送（米）
const NEAR_TRACK_RESET_DIST := 3.0

var _steer_wheels: Array[VehicleWheel3D] = []
var _drive_wheels: Array[VehicleWheel3D] = []
## 每个车轮角一份：物理轮 + 它的视觉网格 + 静止姿态 + 自转/转向轴
var _wheel_visuals: Array = []

@onready var _engine_sound: AudioStreamPlayer3D = $EngineSound


func _ready() -> void:
	_apply_center_of_mass()
	classify_wheels()
	_measure_wheel_base()
	_find_track()
	_place_on_start_line()
	# 车轮视觉要在 _place_on_start_line 之后绑定：那里会改车的朝向，
	# 而自转轴是按"模型 Z 轴在世界里的方向"换算到车轮本地的。
	_bind_wheel_visuals()
	if _engine_sound and _engine_sound.stream:
		_engine_sound.play()
	# 记下起跑弧长，作为之后中心线局部搜索的起点
	if _track != null:
		var near := _nearest_track_point()
		if not near.is_empty():
			_arc_hint = float(near["arc"])


## 找到赛道节点（提供中心线查询）。找不到就退化为"没有出界兜底"，
## 老行为（纯检查点复位）仍然可用。
func _find_track() -> void:
	var p := get_parent()
	if p != null:
		_track = p.get_node_or_null("Track") as Node3D
	if _track != null:
		print("[车辆] 已接上赛道数据源，出界兜底/中心线复位可用")


## 查询"我离中心线最近的点"（含该点切线方向与弧长）
func _nearest_track_point() -> Dictionary:
	if _track == null or not _track.has_method("nearest_on_centerline"):
		return {}
	return _track.call("nearest_on_centerline", global_position, _arc_hint)


## 护栏中心线半宽（米）
func _rail_half_width() -> float:
	if _track != null and _track.has_method("rail_half_width"):
		return float(_track.call("rail_half_width"))
	return 8.2


## 路面半宽（米）
func _road_half_width() -> float:
	if _track != null and _track.has_method("road_half_width"):
		return float(_track.call("road_half_width"))
	return 7.0


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

	# 车头朝向必须与赛道前进方向一致（车头在本地 -Z，所以要 +PI）
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
		if child is VehicleWheel3D:
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


## 按角名找对应的 VehicleWheel3D（WheelFrontLeft -> front_left）
func _find_wheel(key: String) -> VehicleWheel3D:
	var want := key.replace("_", "")
	for child in get_children():
		if child is VehicleWheel3D:
			var n: String = child.name.to_lower().replace("wheel", "").replace("_", "")
			if n == want:
				return child
	return null


## 车轮视觉绑定：把四个角上的 Tire_/Rim_/Hub_ 网格和对应的物理轮关联起来。
##
## 关键点：模型是 90° 旋转过的 —— 车体横向对应**模型 Z 轴**、车体上方向对应模型 Y 轴。
## 所以自转轴必须取"模型 Z 轴在世界里的方向，换算到该网格的本地坐标系"，
## 直接按网格本地的 X 轴转会变成车轮左右摇摆（这是最容易写错的一步）。
func _bind_wheel_visuals() -> void:
	if not spin_wheel_meshes:
		return
	var model_node := get_node_or_null("CarModel")
	if not (model_node is Node3D):
		push_warning("没有 CarModel 节点，车轮动画跳过")
		return
	var model: Node3D = model_node

	var corners := {
		"front_left": ["Tire_Front_L", "Rim_Front_L", "Hub_Front_L"],
		"front_right": ["Tire_Front_R", "Rim_Front_R", "Hub_Front_R"],
		"rear_left": ["Tire_Rear_L", "Rim_Rear_L", "Hub_Rear_L"],
		"rear_right": ["Tire_Rear_R", "Rim_Rear_R", "Hub_Rear_R"],
	}
	for key in corners.keys():
		var wheel := _find_wheel(key)
		if wheel == null:
			continue
		var meshes: Array[Node3D] = []
		var rests: Array[Basis] = []
		var spins: Array[Vector3] = []
		var ups: Array[Vector3] = []
		for nm in corners[key]:
			var n := model.find_child(nm, true, false)
			if not (n is Node3D):
				continue
			var node: Node3D = n
			meshes.append(node)
			rests.append(node.basis)
			spins.append((node.global_transform.basis.inverse() * model.global_transform.basis.z).normalized())
			ups.append((node.global_transform.basis.inverse() * model.global_transform.basis.y).normalized())
		if meshes.is_empty():
			continue
		_wheel_visuals.append({
			"wheel": wheel,
			"meshes": meshes,
			"rests": rests,
			"spins": spins,
			"ups": ups,
			"angle": 0.0,
		})
	print("[车辆] 车轮视觉已绑定 %d 个角（自转轴 = 模型 Z 轴）" % _wheel_visuals.size())


## 车轮视觉：自转 + 前轮转向。
## 自转角速度直接取"前进速度 / 轮半径"，比用 get_rpm() 少一层符号不确定性。
func _update_wheel_visuals(delta: float) -> void:
	if _wheel_visuals.is_empty():
		return
	# 前进速度 = 速度在车头方向上的投影（车头在本地 -Z）
	var forward_speed := linear_velocity.dot(-global_transform.basis.z)
	for entry in _wheel_visuals:
		var wheel: VehicleWheel3D = entry["wheel"]
		if wheel == null or not is_instance_valid(wheel):
			continue
		var radius: float = maxf(wheel.wheel_radius, 0.05)
		var angle: float = float(entry["angle"]) + forward_speed / radius * delta
		entry["angle"] = angle
		var steer: float = steering if wheel.use_as_steering else 0.0
		var meshes: Array = entry["meshes"]
		var rests: Array = entry["rests"]
		var spins: Array = entry["spins"]
		var ups: Array = entry["ups"]
		for i in meshes.size():
			var node: Node3D = meshes[i]
			var rest: Basis = rests[i]
			var up: Vector3 = ups[i]
			var spin_axis: Vector3 = spins[i]
			# 先绕本地"上"转转向角，再绕（转完之后的）本地自转轴转滚动角
			node.basis = rest * Basis(up, steer) * Basis(spin_axis, angle)


func _physics_process(delta: float) -> void:
	_update_drive()
	_update_steering(delta)
	_update_wheel_visuals(delta)
	_update_engine_sound(delta)
	_check_recovery(delta)
	_check_out_of_bounds(delta)
	if _immunity > 0.0:
		_immunity = maxf(_immunity - delta, 0.0)
		if _immunity == 0.0:
			_set_ghost(false)
	if _reset_cooldown > 0.0:
		_reset_cooldown = maxf(_reset_cooldown - delta, 0.0)


## 自动脱困：撞护栏卡住、翻车后自动扶正。
##
## 重要教训：最初我把"水平速度长期接近 0"当成卡住的唯一判据，
## 结果玩家停车不动、只想环视看看车时也会被判定为卡住并瞬移到检查点 ——
## 实测复现：静止 4 秒后车被挪动 2.36m，表现为"车一直跳、像被重置"。
## 现在要求同时满足：确实在给油（说明玩家想动却动不了），或者速度刚发生骤降（说明撞上了东西）。
func _check_recovery(delta: float) -> void:
	if not auto_recover or _immunity > 0.0:
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
	# 卡住 -> 才退回最近检查点（这是"想动却动不了"，需要换位置）
	if flipped:
		print("[车辆] 翻车，原地扶正（保留位置与朝向）")
		recover_upright()
		_stuck_time = 0.0
	elif _stuck_time >= recover_delay:
		print("[车辆] 想动却停住 %.1fs，退回最近检查点" % _stuck_time)
		if _track != null:
			reset_to_track()
		else:
			reset_to_checkpoint()
		_stuck_time = 0.0


func _update_drive() -> void:
	# W = accelerate = +1；S = brake_reverse = -1
	var throttle := Input.get_axis("brake_reverse", "accelerate")
	_braking = Input.is_action_pressed("handbrake")
	_driving = absf(throttle) > 0.05 and not _braking

	# 方向说明（实测得出，与直觉相反但很重要）：
	# 本车几何上车头在本地 -Z（前翼 z=-1.66 一侧）。
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

	# 音量：**停车且没给油时彻底静音**。
	# 占位音源是合成的锯齿波，原来怠速也给 -5 dB 的底噪，听上去就是
	# "车都停下来了还在响"，很出戏。现在按"速度或油门"取较大者来定音量，
	# 两者都接近 0 就淡出到 -60 dB。
	var speed01 := clampf(linear_velocity.length() / 15.0, 0.0, 1.0)
	var gas01 := 1.0 if _driving else 0.0
	var level := maxf(speed01, gas01)
	var target_db := -60.0 if level < 0.02 else lerpf(-20.0, -6.0, level)
	_engine_sound.volume_db = lerpf(_engine_sound.volume_db, target_db, 4.0 * delta)


## 翻车或冲出赛道时按 R 复位到最近的检查点
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		request_reset()


## R 键的入口（带保护，不要直接调 reset_to_track）。
##
## 保护逻辑：车还在路面上（离中心线 < 3m）且没有翻车时，R 只做"原地扶正"，
## 不传送 —— 否则玩家想摆正车头却会被瞬移到中心线上，手感很糟。
func request_reset() -> void:
	if _reset_cooldown > 0.0:
		return
	var near := _nearest_track_point()
	var dev := float(near.get("dist", 999.0)) if not near.is_empty() else 999.0
	var flipped := _is_flipped()
	if dev < NEAR_TRACK_RESET_DIST and not flipped:
		print("[车辆] R：离中心线 %.2fm 且未翻车 → 只扶正，不传送" % dev)
		recover_upright()
		return
	print("[车辆] R：离中心线 %.2fm 翻车=%s → 复位回赛道" % [dev, flipped])
	reset_to_track()


func _is_flipped() -> bool:
	var up := global_transform.basis.y.normalized()
	return up.dot(Vector3.UP) < cos(deg_to_rad(flip_angle))


## 复位回赛道：落点取"离我最近的中心线点"，姿态对齐该点切线，速度清零。
##
## 为什么不复用 reset_to_checkpoint：检查点是**门**，按直线距离找最近的门在外侧
## 场地上会选错；而且门的朝向只保证横跨路面，落点不保证在赛道内侧。
## 中心线查询是几何上唯一正确的答案，任何位置都能算。
func reset_to_track() -> void:
	var near := _nearest_track_point()
	if near.is_empty():
		# 赛道数据源不可用时的退路：老逻辑
		reset_to_checkpoint()
		return
	var target: Vector3 = near["pos"]
	var fwd: Vector3 = near["forward"]
	_arc_hint = float(near["arc"])
	global_transform.basis = Basis.looking_at(fwd, Vector3.UP)
	global_position = target + Vector3.UP * 0.8
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	steering = 0.0
	_steer = 0.0
	_stuck_time = 0.0
	_out_time = 0.0
	_reset_cooldown = 0.5
	_grant_immunity()
	print("[车辆] 已复位到赛道：弧长 %.1fm 落点=%s" % [float(near["arc"]), global_position])


## 复位后的短暂无敌：不与其它车辆碰撞，也不触发检查点/计圈，
## 避免刚回到赛道上就被后车顶飞、或被判定成压线刷圈。
func _grant_immunity() -> void:
	_immunity = reset_immunity_time
	_set_ghost(true)
	print("[车辆] 复位无敌 %.1fs（忽略与车辆的碰撞、不触发检查点）" % reset_immunity_time)


func _set_ghost(on: bool) -> void:
	set_collision_mask_value(VEHICLE_LAYER, not on)


## 复位无敌期间为 true。检查点用它来跳过触发（见 checkpoint.gd）。
func is_reset_immune() -> bool:
	return _immunity > 0.0


## 出界兜底：车跑到围墙通道之外就自动拉回赛道。
##
## 速度越快余量越小：高速飞出时哪怕 0.2s 也会飞很远，所以要立刻复位；
## 低速（撞墙蹭着走、倒车贴边）则给一点宽限，避免误伤正常驾驶。
func _check_out_of_bounds(delta: float) -> void:
	if not auto_reset_out_of_bounds or _track == null or _reset_cooldown > 0.0:
		return
	var near := _nearest_track_point()
	if near.is_empty():
		return
	_arc_hint = float(near["arc"])
	var dev := float(near["dist"])
	var speed := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
	var fast := speed >= fast_escape_speed
	var limit := _rail_half_width() + (fast_escape_margin if fast else out_of_bounds_margin)
	var delay := 0.0 if fast else out_of_bounds_delay
	if dev > limit:
		_out_time += delta
		if _out_time >= delay:
			print("[车辆] 出界兜底触发：离中心线 %.2fm > %.2fm，速度 %.1f m/s → 拉回赛道"
				% [dev, limit, speed])
			reset_to_track()
	else:
		_out_time = 0.0


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
