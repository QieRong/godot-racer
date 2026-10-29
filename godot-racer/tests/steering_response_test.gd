extends SceneTree
## 隔离真实玩家输入→前轮转角链；同一物理帧内同步采样，不冒充实际转弯/防翻车。
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var output := ""
var passed := 0
var failed := 0
var car: VehicleBody3D
var rows: Array[Dictionary] = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("STEERING_RESPONSE_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func response(speed_kmh: float, grip: float) -> Dictionary:
	car.apply_level_setup(200.0, 2, grip)
	car.global_basis = Basis.IDENTITY
	car.linear_velocity = Vector3.FORWARD * speed_kmh / 3.6
	car.set("_steer", 0.0)
	car.steering = 0.0
	key(KEY_A, true)
	var samples: Array[float] = []
	for i in range(60):
		car.call("_update_steering", 1.0 / 120.0)
		samples.append(car.steering)
	var limit := absf(samples[-1])
	var rise_frames := 0
	for value in samples:
		rise_frames += 1
		if value >= limit * 0.90: break
	key(KEY_A, false)
	key(KEY_D, true)
	var reverse_frames := 0
	for i in range(120):
		car.call("_update_steering", 1.0 / 120.0)
		reverse_frames += 1
		if car.steering <= -limit * 0.90: break
	key(KEY_D, false)
	var center_frames := 0
	for i in range(120):
		car.call("_update_steering", 1.0 / 120.0)
		center_frames += 1
		if absf(car.steering) <= limit * 0.10: break
	return {"speed_kmh": speed_kmh, "grip": grip, "limit_radians": limit,
		"rise_ms": rise_frames * 1000.0 / 120.0,
		"reverse_ms": reverse_frames * 1000.0 / 120.0,
		"center_ms": center_frames * 1000.0 / 120.0}

func run() -> void:
	var state := root.get_node("GameState")
	state.ai_enabled = false
	state.chosen_level = 0
	state.settings_path = output.path_join("settings.cfg")
	Engine.max_fps = 0
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING": break
	check(current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING",
		"真实场景装配发车")
	if failed > 0: quit(1); return
	car = current_scene.get_node("RaceCar")
	for i in range(180): await physics_frame
	car.set_physics_process(false)
	car.start_locked = false
	check(car.grounded_wheel_count() == 4, "输入隔离采样前真实四轮接地，不能冻结后丢失接地状态")
	for grip in [1.0, 0.7, 0.55]:
		for speed in [0.0, 20.0, 40.0, 60.0, 80.0, 120.0, 150.0, 180.0]:
			var row := response(speed, grip)
			rows.append(row)
			check(row.limit_radians > 0.0, "有效低/高速转角 %s" % JSON.stringify(row))
			check(row.limit_radians > 0.0 and row.rise_ms <= 83.34 and row.center_ms <= 83.34 and row.reverse_ms <= 141.67,
				"低/高速按下/回中≤83.34ms、反向≤141.67ms %s" % JSON.stringify(row))
	FileAccess.open(output.path_join("response.json"), FileAccess.WRITE).store_string(JSON.stringify(rows, "\t"))
	car = null
	var active := current_scene
	var audio_ids := AudioExit.capture_tree(active)
	current_scene = null
	active.free()
	check(await AudioExit.wait_all_released(self, audio_ids), "实际音频回执回收后退出")
	print("STEERING_RESPONSE_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
