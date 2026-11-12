extends Node
## 复用既有碰撞反馈判据，只影响当前单人镜头的视图偏移。

var _shake: Node

func setup(car: VehicleBody3D) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 400
	car.get_node("VehicleFeedback").body_impact.connect(_on_impact)

func _on_impact(speed_change: float) -> void:
	if not GameState.camera_shake_enabled or GameState.phase_name() != "RACING":
		return
	var camera := get_viewport().get_camera_3d()
	if _shake != null and _shake.camera != camera:
		_shake.stop()
		_shake.queue_free()
		_shake = null
	if _shake == null:
		_shake = load("res://addons/whumpkit_lite/whumpkit_shake_3d.gd").new()
		_shake.name = "WhumpkitCollisionShake"
		_shake.auto_process = false
		_shake.ignore_time_scale = false
		_shake.max_offset = Vector2(0.10, 0.07)
		# ChaseCamera 和 Phantom 每帧负责朝向；仅用视图平移避免旋转相互覆盖。
		_shake.max_angles = Vector3.ZERO
		_shake.decay = 2.4
		camera.add_child(_shake)
	_shake.add_trauma(clampf(0.4 + (speed_change - 5.0) * 0.035, 0.4, 0.7))

func _process(delta: float) -> void:
	if _shake == null:
		return
	if not GameState.camera_shake_enabled or GameState.phase_name() != "RACING" \
			or _shake.camera != get_viewport().get_camera_3d():
		_shake.stop()
	else:
		_shake.step(delta)
