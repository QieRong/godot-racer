extends Node3D
## 独立相机输出，原 ChaseCamera 始终保留；C/V/环视/航拍/摄影不交给插件。

var requested := false
var _using_phantom := false
var _chase: Camera3D
var _car: VehicleBody3D
var _camera: Camera3D
var _pcam: Node3D
var _host: Node

func setup(chase: Camera3D, car: VehicleBody3D) -> void:
	_chase = chase
	_car = car

func _ready() -> void:
	process_priority = 200
	_camera = Camera3D.new()
	_camera.name = "PhantomOutput"
	_camera.fov = _chase.fov
	add_child(_camera)
	_pcam = load("res://addons/phantom_camera/scripts/phantom_camera/phantom_camera_3d.gd").new()
	_pcam.name = "L2SmoothFollow"
	_pcam.follow_mode = 2
	_pcam.follow_target = _car
	_pcam.follow_offset = _car.global_basis * _chase.offset_third
	_pcam.follow_damping = true
	_pcam.follow_damping_value = Vector3(0.16, 0.22, 0.16)
	_pcam.look_at_mode = 2
	_pcam.look_at_target = _car
	_pcam.look_at_offset = Vector3(0, 0.8, 0)
	_pcam.look_at_damping = true
	_pcam.look_at_damping_value = 0.12
	_pcam.tween_resource.duration = 0.0
	add_child(_pcam)
	_host = load("res://addons/phantom_camera/scripts/phantom_camera_host/phantom_camera_host.gd").new()
	_host.name = "PhantomCameraHost"
	_host.interpolation_mode = 1
	_camera.add_child(_host)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("racer_phantom_trial") and not event.is_echo():
		requested = not requested
		print("[Phantom Camera] L2 对照：", "开" if requested else "关（原镜头）")
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	var use_trial: bool = requested and GameState.phase_name() == "RACING" \
		and _chase._mode == 2 and not _chase._rear_active \
		and not Input.is_action_pressed("camera_orbit") \
		and absf(_chase._yaw) < 0.001 and absf(_chase._pitch) < 0.001
	_pcam.follow_offset = _car.global_basis * _chase.offset_third
	if use_trial != _using_phantom:
		_using_phantom = use_trial
		if use_trial:
			_camera.global_transform = _chase.global_transform
			_camera.make_current()
		else:
			_chase.make_current()
	_host.set_process(use_trial)
	_host.set_physics_process(use_trial)
	_pcam.set_process(use_trial)
	_pcam.set_physics_process(use_trial)
