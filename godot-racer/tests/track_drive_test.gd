extends SceneTree
const Recorder := preload("res://tests/track_trace_recorder.gd")
var passed := 0
var failed := 0
var output := ""
var bad_scene := false
var selected_level := 1

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
		if arg == "--bad-scene": bad_scene = true
		if arg.begins_with("--level="): selected_level = int(arg.trim_prefix("--level="))
	call_deferred("run")

func check(ok: bool, description: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("TRACK_DRIVE_ASSERT %s %s" % ["PASS" if ok else "FAIL", description])

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = selected_level
	state.ai_enabled = true
	state.settings_path = output.path_join("settings.cfg")
	if OS.get_cmdline_user_args().has("--accelerated"): Engine.max_fps = 0
	if bad_scene: state.call("current_level").layout = "bogus:1"
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene == null: continue
		if current_scene.get_node_or_null("TrackBuildError") != null: break
		if current_scene.get("_setup_done") and state.call("phase_name") == "RACING": break
	var scene := current_scene
	if bad_scene:
		var box: AcceptDialog = scene.get_node_or_null("TrackBuildError")
		check(box != null and box.visible, "坏布局显示明确错误")
		check(not scene.get("_setup_done") and state.call("phase_name") == "LOADING", "坏布局不进入倒计时/比赛")
		check(scene.get_node("RaceCar").start_locked and scene.get_node("RaceCar").freeze, "坏布局锁住玩家车辆")
		check(scene.get("_opponents").is_empty() and not scene.get_node("Track").is_world_ready(), "不生成旧路与对手")
		if box != null:
			await process_frame
			check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "错误界面鼠标可见")
			box.canceled.emit()
			await process_frame
			check(box.visible and state.call("phase_name") == "LOADING", "关闭错误提示不会进入比赛")
			if DisplayServer.get_name() != "headless":
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output.path_join("build-error.png"))
			box.confirmed.emit()
			deadline = Time.get_ticks_msec() + 10000
			while Time.get_ticks_msec() < deadline:
				await process_frame
				if current_scene != null and current_scene.scene_file_path == "res://scenes/menu.tscn": break
			check(current_scene != null and current_scene.scene_file_path == "res://scenes/menu.tscn", "错误按钮实际返回菜单")
	else:
		check(scene.get("_setup_done") and state.call("phase_name") == "RACING", "真实装配与倒计时进入比赛")
		var cars: Array = scene.get("_opponents")
		check(cars.size() == 1, "真实生成一台AI")
		if cars.size() == 1:
			var track: Node3D = scene.get_node("Track")
			var geometry: Array = []
			for i in range(int(track.road_length()) + 1):
				var point: Vector3 = track.centerline_point(float(i))
				geometry.append([point.x, point.y, point.z])
			var gates: Array = []
			for node in track.get_children():
				if node is Area3D:
					var p: Vector3 = node.global_position
					var f: Vector3 = node.global_basis.z
					gates.append({"order": int(node.order_index), "pos": [p.x,p.y,p.z], "forward": [f.x,f.y,f.z]})
			var shape: BoxShape3D = cars[0].get_node("BodyCollision").shape
			FileAccess.open(output.path_join("actual-road.json"), FileAccess.WRITE).store_string(JSON.stringify({
				"centerline": geometry, "length": track.road_length(), "gates": gates,
				"layout": track.layout, "half_width": track.road_half_width(),
				"level": selected_level+1, "target_laps": state.current_level().laps_to_finish, "actor": "ai",
				"body_half_width": shape.size.x * 0.5, "body_half_length": shape.size.z * 0.5,
				"physics_hz": Engine.physics_ticks_per_second, "render_target": state.render_fps}))
			var recorder := Recorder.new()
			recorder.setup(cars[0], track, state, output)
			scene.add_child(recorder)
			if OS.get_cmdline_user_args().has("--accelerated"): Engine.max_fps = 0
			await recorder.completed
			await process_frame
			check(int(cars[0].call("laps_done")) >= 2, "AI核心完成两圈；独立过门与轨迹另验")
			check(cars[0].call("rescue_count") == 0, "全程零自救")
			check(not recorder.stalled, "无开放通道连续10s不足5m")
			check(recorder.frame < 600 * Engine.physics_ticks_per_second, "AI模拟时间小于600s，不代替真人时长")
			if DisplayServer.get_name() != "headless":
				var camera := Camera3D.new()
				camera.projection = Camera3D.PROJECTION_ORTHOGONAL
				camera.size = 800.0
				camera.far = 10000.0
				scene.add_child(camera)
				camera.global_position = Vector3(-188.5, 1600.0, 57.9)
				camera.look_at(Vector3(-188.5, 0.0, 57.9), Vector3.FORWARD)
				camera.make_current()
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output.path_join("actual-godot-overview.png"))
	paused = false
	var music := state.find_child("MenuMusic", false, false)
	if music != null: await music.call("shutdown_and_wait")
	var active := current_scene
	current_scene = null
	if active != null: active.free()
	await process_frame
	await process_frame
	print("TRACK_DRIVE_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
