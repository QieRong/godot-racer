extends Camera3D
## 第三人称平滑跟随摄像机
##
## 挂在场景根下的 Camera3D 上（不要挂在车身下面，否则车翻镜头也跟着翻），
## 在检查器里把 target 指向你的 VehicleBody3D。

@export var target: Node3D
## 相对车身的偏移。**车头在车体本地 -Z 侧**，三条独立证据：
##   1) race_car.tscn：WheelFront* 在 z=-1.05，WheelRear* 在 z=+1.05
##   2) race_car.glb：Nose_Wing 在模型 x=-1.66，Wing_Main 在 x=+1.68
##   3) CarModel 的 90° 旋转把模型 -X 映射到车体 -Z
## 所以摄像机要放在 **+Z** 侧才是"跟在车尾后方"。
## 注意：这里原先是 -6.0，注释还断言"车头朝 +Z"——那是反的，
## 结果镜头被挂在车鼻子前面回头看车，表现就是"镜头朝向和车头不一致"。
@export var offset := Vector3(0.0, 2.2, 6.0)
## 注视点相对车身的偏移，抬高一点让车处于画面下方
@export var look_at_offset := Vector3(0.0, 0.8, 0.0)
## 位置跟随速度：越小越"拖"，越大越跟脚
@export var position_smooth := 6.0
## 注视点平滑速度
@export var look_smooth := 10.0
## 高速时镜头略微拉远，增强速度感
@export var speed_pullback := 1.4

@export_group("鼠标环视")
@export var orbit_enabled := true
@export var orbit_sensitivity := 0.006
@export var pitch_min := -0.5
@export var pitch_max := 0.9
## 松开右键后镜头回正到车尾的速度（弧度/秒）。
## 没有这个的话，环视后镜头会一直停在车侧面，开起来很别扭。
## 2.5 太快（约 143°/秒，回正过猛像被甩），1.2 约 69°/秒比较自然。
@export var recenter_speed := 1.2

var _yaw := 0.0
var _pitch := 0.0
var _current := Vector3.ZERO
var _look := Vector3.ZERO


func _ready() -> void:
	# 诊断日志：相机"看不到车"这类问题几乎都是 target 没解析到，
	# 所以把解析结果直接打出来，别靠猜。
	print("[相机] _ready 执行，target=%s" % str(target))
	if target == null:
		printerr("[相机] target 未设置！在检查器里把 target 指向 VehicleBody3D 节点。相机将停在原地。")
		set_process(false)
		return
	print("[相机] target 解析成功：%s  位置=%s" % [target.name, target.global_position])
	# 开场就让镜头待在车后，避免从原点飞过去
	_current = target.global_position + target.global_transform.basis * offset
	global_position = _current
	_look = target.global_position
	print("[相机] 初始位置设为 %s" % global_position)


func _unhandled_input(event: InputEvent) -> void:
	if not orbit_enabled or target == null:
		return
	# 按住右键拖动可环视；左键留给 UI
	if event is InputEventMouseMotion and Input.is_action_pressed("camera_orbit"):
		_yaw -= event.relative.x * orbit_sensitivity
		_pitch = clampf(_pitch - event.relative.y * orbit_sensitivity, pitch_min, pitch_max)


func _process(delta: float) -> void:
	if target == null:
		return

	# 松开右键后，yaw/pitch 平滑回正到"车尾正后方"
	if orbit_enabled and not Input.is_action_pressed("camera_orbit"):
		_yaw = move_toward(_yaw, 0.0, recenter_speed * delta)
		_pitch = move_toward(_pitch, 0.0, recenter_speed * delta)

	var basis_target := target.global_transform.basis
	var speed := 0.0
	if target is VehicleBody3D:
		speed = target.linear_velocity.length()
	var extra := Vector3(0.0, 0.0, speed / 40.0 * speed_pullback)

	# 车身坐标系下的偏移 + 鼠标环视旋转
	var orbit := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	var desired := target.global_position + (basis_target * orbit) * (offset + extra)

	# 用 1-exp(-k*dt) 做帧率无关的指数平滑
	_current = _current.lerp(desired, 1.0 - exp(-position_smooth * delta))
	global_position = _current

	# 注视点同样平滑，否则镜头会跟着车身抖动一起抖
	var look_target := target.global_position + basis_target * look_at_offset
	_look = _look.lerp(look_target, 1.0 - exp(-look_smooth * delta))
	look_at(_look, Vector3.UP)
