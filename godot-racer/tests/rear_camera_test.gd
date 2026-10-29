extends SceneTree
## 真实InputMap/按键与相机朝向专项；不更改驾驶状态，不代替真人体验。
var passed := 0
var failed := 0
var _car: Node3D
var _camera: Camera3D

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, detail: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("REAR_CAMERA_ASSERT %s %s" % ["PASS" if ok else "FAIL", detail])

func key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)

func settle() -> void:
	for i in range(4): await process_frame

func rear() -> bool:
	# 跟随镜头保留原有向下俯角；后视检验水平方位，不能把正常俯角误判为偏航。
	var forward := -_camera.global_basis.z
	forward.y = 0.0
	var back := _car.global_basis.z
	back.y = 0.0
	return forward.normalized().dot(back.normalized()) > 0.999

func run() -> void:
	var bindings: Array[InputEvent] = []
	if InputMap.has_action("camera_rear"): bindings = InputMap.action_get_events("camera_rear")
	check(bindings.any(func(e: InputEvent): return e is InputEventKey and e.physical_keycode == KEY_C),
		"InputMap真实绑定C")
	_car = Node3D.new()
	root.add_child(_car)
	_car.position = Vector3(19, 3, -8)
	_car.rotation.y = 0.7
	_camera = load("res://scripts/chase_camera.gd").new()
	_camera.target = _car
	_camera.toast_enabled = false
	root.add_child(_camera)
	for mode in range(3):
		_camera.call("set_view_mode", mode)
		await settle()
		var before := _camera.global_transform
		key(KEY_C, true)
		await settle()
		check(rear(), "视角%d按住C朝车后方" % mode)
		var local_position := _car.to_local(_camera.global_position)
		check(local_position.z > 1.66 if mode == 0 else local_position.z < -2.0,
			"视角%d镜头移至对应后视位置，避开车体" % mode)
		await settle()
		check(rear() and int(_camera.get("_mode")) == mode, "持续按住C保持后视且不改基础视角")
		key(KEY_C, false)
		await settle()
		check(_camera.global_position.distance_to(before.origin) < 0.01
			and _camera.global_basis.z.dot(before.basis.z) > 0.999, "松开C恢复原视角")
	# C与V及鼠标环视的组合输入。
	key(KEY_C, true)
	await settle()
	key(KEY_V, true)
	key(KEY_V, false)
	await settle()
	check(rear() and int(_camera.get("_mode")) == 0, "按住C时V切换基础视角且保持后视")
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_RIGHT
	mouse.pressed = true
	Input.parse_input_event(mouse)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(180, 60)
	Input.parse_input_event(motion)
	await settle()
	check(rear(), "C优先于右键环视")
	mouse.pressed = false
	Input.parse_input_event(mouse)
	paused = true
	key(KEY_C, false)
	await settle()
	paused = false
	await settle()
	check(not rear() and int(_camera.get("_mode")) == 0, "暂停期间松开C，恢复后不粘后视")
	for i in range(3):
		key(KEY_C, true)
		await settle()
		check(rear(), "连续按C第%d次生效" % i)
		key(KEY_C, false)
		await settle()
		check(not rear(), "连续松开C第%d次恢复" % i)
	var help: Control = load("res://scripts/menu_overlay.gd").new()
	check("按住 C 向后看" in String(help.call("_help_text")), "操作帮助明确按住C后视")
	if InputMap.has_action("camera_rear"):
		InputMap.action_erase_events("camera_rear")
		var remap := InputEventKey.new()
		remap.physical_keycode = KEY_B
		InputMap.action_add_event("camera_rear", remap)
		check("按住 B 向后看" in String(help.call("_help_text")), "帮助跟随InputMap重绑")
		InputMap.action_erase_events("camera_rear")
		for event in bindings: InputMap.action_add_event("camera_rear", event)
	help.free()
	_camera.queue_free()
	_car.queue_free()
	await process_frame
	print("REAR_CAMERA_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
