extends SceneTree
var passed := 0
var failed := 0
var output := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("VARIANT_RUNTIME_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func wait_racing(previous_id: int = 0) -> bool:
	var deadline := Time.get_ticks_msec()+30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.get_instance_id() != previous_id:
			if root.get_node("GameState").phase_name() == "RACING" and current_scene.get("_setup_done") == true: return true
	return false

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = 1
	state.settings_path = output.path_join("settings.cfg")
	state.apply_cli_args(PackedStringArray(["--race-variants", "--race-seed=12345", "--race-combination=8"]))
	change_scene_to_file("res://scenes/main.tscn")
	check(await wait_racing(), "组合8经过正式装配和倒计时")
	if failed > 0: quit(1); return
	var first: Dictionary = state.race_variant_summary()
	var scene := current_scene
	var track: Node3D = scene.get_node("Track")
	var player: VehicleBody3D = scene.get_node("RaceCar")
	check(track.elevation_report.max_height > 15.95 and scene.get("_obstacle_field").obstacle_count() == 2,
		"正式场景实际采用16m坡道及两障碍")
	check(absf(player.global_position.y-track.centerline_point(0.0).y) < 0.5, "起跑平段车辆正常接地")
	var arc: float = track.road_length()*0.30
	var p: Vector3 = track.centerline_point(arc)
	var frame: Transform3D = track.surface_frame(arc, track.road_half_width()+2.0)
	player.global_position = frame.origin+Vector3.UP*1.0
	player.reset_to_track()
	var near: Dictionary = track.nearest_on_centerline(player.global_position)
	check(absf(player.global_position.y-Vector3(near.pos).y-0.8) < 0.04 and Vector3(near.pos).y > 15.9,
		"坡顶调用正式复位落在高路面上方，不回零高度")
	if DisplayServer.get_name() != "headless":
		var camera := Camera3D.new()
		camera.far = 6000.0
		scene.add_child(camera)
		var f: Vector3 = track.centerline_forward(arc)
		var side := Vector3(f.z,0.0,-f.x)
		camera.global_position = p-f*80.0+side*40.0+Vector3.UP*28.0
		camera.look_at(p+f*35.0,Vector3.UP)
		camera.make_current()
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("slope-16m.png"))
	var old_id := scene.get_instance_id()
	state.restart_race()
	check(await wait_racing(old_id), "实际重试重新装配并走完整倒计时")
	check(state.race_variant_summary() == first, "真实重载后组合/种子/摘要保持不变")
	state.back_to_menu()
	var deadline := Time.get_ticks_msec()+10000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.scene_file_path == "res://scenes/menu.tscn": break
	check(state.phase_name() == "MENU" and state.race_variant_summary().is_empty(), "实际返回菜单释放本局组合")
	state.apply_cli_args(PackedStringArray(["--race-seed=54321", "--race-combination=0"]))
	change_scene_to_file("res://scenes/main.tscn")
	check(await wait_racing(), "返回后可开始另一组合")
	check(state.race_variant_summary().get("combination", -1) == 0, "新比赛不沿用上一局组合8")
	paused = false
	var music := state.find_child("MenuMusic", false, false)
	if music != null: await music.shutdown_and_wait()
	var active := current_scene
	current_scene = null
	if active != null: active.free()
	await process_frame
	print("VARIANT_RUNTIME_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
