extends SceneTree
## 真实输入动作→车轮输出与直道物理减速回归；初速注入仅用于测试摆位。
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var passed := 0
var failed := 0
var car: VehicleBody3D

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("DRIVE_INPUT_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func release_input() -> void:
	for action in ["accelerate", "brake_reverse", "handbrake"]:
		Input.action_release(action)

func wheels_braking() -> bool:
	for child in car.get_children():
		if child is VehicleWheel3D and child.brake <= 0.0: return false
	return true

func drive_case(speed: float, action: String, strength := 1.0) -> void:
	release_input()
	car.linear_velocity = -car.global_basis.z * speed
	Input.action_press(action, strength)
	car.call("_update_drive")

func measure(pose: Transform3D, braking: bool) -> float:
	release_input()
	car.global_transform = pose
	car.linear_velocity = -pose.basis.z * 20.0
	car.angular_velocity = Vector3.ZERO
	car.sleeping = false
	if braking: Input.action_press("brake_reverse")
	car.set_physics_process(true)
	for i in range(120): await physics_frame
	car.set_physics_process(false)
	var speed := Vector2(car.linear_velocity.x, car.linear_velocity.z).length()
	release_input()
	return speed

func run() -> void:
	var state := root.get_node("GameState")
	state.ai_enabled = false
	state.race_variants_enabled = false
	state.chosen_level = 0
	Engine.max_fps = 0
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING": break
	check(current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING", "正式场景装配与倒计时发车")
	if failed > 0: quit(1); return
	car = current_scene.get_node("RaceCar")
	for i in range(180): await physics_frame
	car.set_physics_process(false)
	car.set("auto_recover", false)
	car.set("auto_reset_out_of_bounds", false)
	var pose := car.global_transform
	drive_case(20.0, "brake_reverse")
	check(wheels_braking(), "前进72km/h按S给全轮制动力")
	check(is_zero_approx(car.get_node("WheelRearLeft").engine_force), "制动时不同时给驱动力")
	drive_case(0.0, "brake_reverse")
	var reverse_force: float = car.get_node("WheelRearLeft").engine_force
	check(reverse_force > 0.0 and not wheels_braking(), "停车按S进入倒车")
	drive_case(-3.0, "brake_reverse")
	check(car.get_node("WheelRearLeft").engine_force > 0.0, "倒车中按S继续倒车")
	drive_case(-8.0, "brake_reverse")
	check(is_zero_approx(car.get_node("WheelRearLeft").engine_force), "保留原倒车6m/s驱动力上限")
	drive_case(-3.0, "accelerate")
	check(wheels_braking(), "倒车时按W先制动")
	drive_case(20.0, "brake_reverse", 0.5)
	check(wheels_braking(), "模拟量半行程制动生效")
	var half_brake: float = car.get_node("WheelFrontLeft").brake
	drive_case(20.0, "brake_reverse")
	check(car.get_node("WheelFrontLeft").brake > half_brake, "全行程制动力大于半行程")
	drive_case(20.0, "handbrake")
	check(wheels_braking(), "空格制动保留")
	release_input()
	car.call("_update_drive")
	check(is_equal_approx(car.get_node("WheelFrontLeft").brake, float(car.get("engine_brake"))), "松键恢复既有发动机制动")
	Input.action_press("accelerate")
	Input.action_press("brake_reverse")
	car.call("_update_drive")
	check(is_zero_approx(car.get_node("WheelRearLeft").engine_force), "W/S同时按下不产生驱动力")
	release_input()
	car.start_locked = true
	drive_case(0.0, "accelerate")
	check(is_zero_approx(car.get_node("WheelRearLeft").engine_force), "发车锁不接受油门")
	car.start_locked = false
	release_input()
	var coasting := await measure(pose, false)
	var braking := await measure(pose, true)
	check(braking < coasting - 1.0, "真实直道1秒：S减速强于滑行 coast=%.3f brake=%.3f m/s" % [coasting, braking])
	check(car.grounded_wheel_count() >= 3, "减速观察结束仍有至少三轮接地")
	car = null
	var active := current_scene
	var ids := AudioExit.capture_tree(active)
	current_scene = null
	active.free()
	check(await AudioExit.wait_all_released(self, ids), "音频实际回收后退出")
	print("DRIVE_INPUT_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
