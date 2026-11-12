extends SceneTree
## 本轮试玩问题的单次真实渲染检查；走正式主场景、航拍、倒计时和发车。
var passed := 0
var failed := 0
const OUT := "D:/桌面/DSH-Work/racer-migration-4.7.2-20261103/screenshots/"
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	print("PLAYTEST_RUNTIME %s %s" % ["PASS" if ok else "FAIL", message])
	if ok: passed += 1
	else: failed += 1
func wait_phase(gs: Node, wanted: String) -> bool:
	for i in range(2400):
		await process_frame
		if gs.phase_name() == wanted: return true
	return false
func snapshot(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var err := root.get_texture().get_image().save_png(OUT + file_name)
	check(err == OK, "真实游戏截图 " + file_name)
func run() -> void:
	var gs := root.get_node("GameState")
	gs.chosen_level = 1
	gs.record_results_enabled = false
	gs.race_variants_enabled = false
	var main: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	if not await wait_phase(gs, "INTRO"):
		check(false, "进入正式航拍"); quit(1); return
	var car: VehicleBody3D = main.get_node("RaceCar")
	var audio: AudioStreamPlayer3D = car.get_node("EngineSound")
	check(audio.stream_paused and is_equal_approx(audio.volume_db, -80.0), "航拍期间引擎暂停且静音")
	check(car.get_node("CarModel").scene_file_path == "res://models/player_red_racer.glb", "真正的玩家车辆使用AM07适配GLB")
	check(car.find_children("*", "VehicleWheel3D", true, false).size() == 4, "模型没有生成额外物理车轮")
	var entries: Array = car.get("_wheel_visuals")
	var mesh_count := 0
	for entry in entries: mesh_count += entry.meshes.size()
	check(entries.size() == 4 and mesh_count == 12, "四角十二个轮胎/轮圈/轮毂驱动节点完整")
	check(is_equal_approx(car.mass, 1200.0) and car.get_node("BodyCollision").shape.size.is_equal_approx(Vector3(1.6, .7, 3.4)), "质量与车体碰撞尺寸保持原值")
	var model := car.get_node("CarModel") as Node3D
	var nose := model.find_child("Nose_Wing", true, false) as Node3D
	var wing := model.find_child("Wing_Main", true, false) as Node3D
	var model_forward := car.global_basis.inverse() * (nose.global_position - wing.global_position)
	model_forward.y = 0.0
	check(model_forward.normalized().dot(Vector3.FORWARD) > .99, "模型车头与物理车头一致（投影到车体水平面）")
	var sample := main.get_node("L2ScenerySample")
	check(sample.hills > 0 and sample.facilities == 1, "L2已装配Terrain3D丘陵和Cyclops维修看台")
	var opponents: Array = main.get("_opponents")
	check(opponents.size() == 1 and opponents[0].get_node("CarModel").scene_file_path == "res://models/race_car.glb", "AI继续使用原共享模型")
	main.get("_race_intro").call("_finish")
	if not await wait_phase(gs, "RACING"):
		check(false, "正式倒计时结束并发车"); quit(1); return
	for i in range(12): await physics_frame
	check(not car.get("start_locked") and not car.freeze, "正式GO解锁玩家，沿用原发车流程")
	check(not audio.stream_paused, "正式驾驶恢复引擎播放")
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(10, 10)
	Input.parse_input_event(motion)
	await process_frame
	check(Input.mouse_mode == Input.MOUSE_MODE_HIDDEN, "驾驶时移动鼠标也保持隐藏")
	var trace: Node = main.get("_ghost_trace")
	var hud: CanvasLayer = main.get_node("HUD")
	var speed_box: Rect2 = hud.transform * Rect2(551, 603, 264, 74)
	check(not trace.status.get_global_rect().intersects(speed_box), "幽灵提示与速度面板不重叠")
	Input.action_press("steer_left")
	for i in range(30): await physics_frame
	check(car.steering > .1, "真实输入产生前轮转向")
	var aligned := true
	for entry in entries:
		for node in entry.meshes:
			aligned = aligned and node.global_position.distance_to(entry.wheel.global_position) < .002
	check(aligned, "十二个驱动网格跟随真实悬挂轮心")
	check(car.call("grounded_wheel_count") == 4, "四轮正常接地")
	var camera: Camera3D = main.get_node("ChaseCamera")
	for view_mode in range(3):
		camera.call("set_view_mode", view_mode)
		for i in range(3): await process_frame
		check(camera.current and camera.global_position.distance_to(car.global_position) > .5, "V视角%d可用" % view_mode)
	await snapshot("am07-l2-rear.png")
	Input.action_press("camera_rear")
	for i in range(8): await process_frame
	await snapshot("am07-l2-front.png")
	Input.action_release("camera_rear")
	Input.action_release("steer_left")
	var pause: Node = main.get_node("PauseMenu")
	pause.pause()
	for i in range(3): await process_frame
	check(gs.phase_name() == "PAUSED" and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "暂停后鼠标恢复可用")
	pause.resume()
	for i in range(3): await process_frame
	check(gs.phase_name() == "RACING" and Input.mouse_mode == Input.MOUSE_MODE_HIDDEN, "恢复驾驶后鼠标再次隐藏")
	print("PLAYTEST_RUNTIME_SUMMARY PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
