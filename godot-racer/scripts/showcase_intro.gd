extends Node
## 唯一入场时间线；仅控制展示世界，不等待/更改比赛流程。

signal finished

var running := false
var duration := 2.5
var pulse_count := 0
var can_skip := false
var can_rotate := false
var _lift: Node3D
var _podium: Node3D
var _car: Node3D
var _car_meshes: Array[MeshInstance3D] = []
var _environment: Environment
var _lights: Array[DirectionalLight3D] = []
var _tween: Tween
var _quick := false


func configure(lift: Node3D, podium: Node3D, car: Node3D, environment: Environment,
		lights: Array[DirectionalLight3D], quick: bool) -> void:
	_lift = lift
	_podium = podium
	_car = car
	for mesh in car.find_children("*", "MeshInstance3D", true, false):
		_car_meshes.append(mesh)
	_environment = environment
	_lights = lights
	play(quick)


func play(quick: bool) -> void:
	if _tween != null: _tween.kill()
	_quick = quick
	duration = 0.35 if quick else 2.5
	pulse_count = 0
	running = true
	_pose(0.0)
	_tween = create_tween()
	_tween.tween_method(_pose, 0.0, duration, duration)
	_tween.tween_callback(_complete)


func _pose(time: float) -> void:
	var light_mix: float
	var car_mix: float
	var edges := Vector3.ONE
	if _quick:
		_lift.position.y = 0.0
		light_mix = smoothstep(0.0, duration, time)
		car_mix = smoothstep(0.07, duration, time)
		edges *= lerpf(0.2, 1.0, light_mix)
	else:
		var lift_mix := clampf((time - 0.25) / 0.85, 0.0, 1.0)
		_lift.position.y = lerpf(-0.9, 0.0, 1.0 - pow(1.0 - lift_mix, 3.0))
		# 先让空展台升起落定，再显现车辆；隐藏阶段不提前露出车模。
		light_mix = smoothstep(0.25, 1.1, time)
		car_mix = smoothstep(1.1, 1.55, time)
		edges = Vector3(lerpf(0.06, 1.0, smoothstep(0.0, 1.05, time)),
			smoothstep(0.95, 1.3, time), smoothstep(1.15, 1.55, time))
		if time >= 1.55 and pulse_count == 0:
			pulse_count = 1
		if _podium.has_method("set_pulse"):
			_podium.set_pulse(clampf((time - 1.55) / 0.55, 0.0, 1.0), time >= 1.55 and time < 2.1)
	_lift.visible = true
	_car.visible = car_mix > 0.001
	for mesh in _car_meshes: mesh.transparency = 1.0 - car_mix
	can_rotate = _car.visible
	can_skip = car_mix >= 0.1
	_environment.ambient_light_energy = lerpf(0.015, 0.65, light_mix)
	for i in range(_lights.size()):
		_lights[i].light_energy = lerpf(0.0, 1.1 if i == 0 else 0.65, light_mix)
	_podium.set_edge_strengths(edges)
	if _podium.has_method("set_brand_strength"):
		_podium.set_brand_strength(light_mix if _quick else smoothstep(1.55, 2.1, time))


func skip_to_drag() -> void:
	if not running or not can_skip: return
	if _tween != null: _tween.kill()
	# 保持当前位置，0.15秒平滑落定；拖拽许可即时交给展车控制器。
	_tween = create_tween()
	_tween.tween_property(_lift, "position:y", 0.0, 0.15).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(settle)


func settle() -> void:
	if _tween != null: _tween.kill()
	_pose(duration)
	_complete()


func _complete() -> void:
	var was_running := running
	running = false
	can_skip = true
	can_rotate = true
	_lift.position.y = 0.0
	if _podium.has_method("set_pulse"): _podium.set_pulse(1.0, false)
	if was_running: finished.emit()


func _exit_tree() -> void:
	if _tween != null:
		_tween.kill()
		_tween = null
