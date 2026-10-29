extends SceneTree
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var passed := 0
var failed := 0
var output := ""
var selected_level := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
		if arg.begins_with("--test-level="): selected_level = int(arg.trim_prefix("--test-level="))
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("FIVE_RUNTIME_ASSERT %s L%d %s" % ["PASS" if ok else "FAIL", selected_level+1, message])

func wait_racing(previous_id: int = 0) -> bool:
	var deadline := Time.get_ticks_msec()+30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.get_instance_id() != previous_id:
			if root.get_node("GameState").phase_name() == "RACING" and current_scene.get("_setup_done") == true: return true
	return false

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = selected_level
	state.settings_path = output.path_join("settings.cfg")
	# 不传--race-variants，覆盖普通BAT的默认配置路径。
	check(state.race_variants_enabled, "普通入口默认随机")
	change_scene_to_file("res://scenes/main.tscn")
	check(await wait_racing(), "实际装配、3/2/1与同步发车成功")
	if failed > 0: quit(1); return
	var first: Dictionary = state.race_variant_summary()
	var scene := current_scene
	var track: Node3D = scene.get_node("Track")
	var player: VehicleBody3D = scene.get_node("RaceCar")
	var peak_arc := 0.0
	var peak_height := 0.0
	for i in range(int(track.road_length())):
		var point: Vector3 = track.centerline_point(float(i))
		if point.y > peak_height:
			peak_arc = float(i)
			peak_height = point.y
	check(peak_height > 11.9 and scene.get("_obstacle_field").obstacle_count() == state.current_level().obstacle_count,
		"实际高路面及本关障碍已装配，高差%.2fm" % peak_height)
	check(absf(player.global_position.y-track.centerline_point(0.0).y) < 0.5, "起跑平段正常接地")
	player.freeze = true
	var frame: Transform3D = track.surface_frame(peak_arc, track.road_half_width()+2.0)
	player.global_position = frame.origin+Vector3.UP
	player.reset_to_track()
	var near: Dictionary = track.nearest_on_centerline(player.global_position)
	check(absf(player.global_position.y-Vector3(near.pos).y-0.8) < 0.04 and Vector3(near.pos).y > peak_height-0.1,
		"坡顶正式复位落在实际高路面，不掉回零高度")
	if DisplayServer.get_name() != "headless":
		var camera := Camera3D.new()
		camera.far = 6000.0
		scene.add_child(camera)
		var point: Vector3 = track.centerline_point(peak_arc)
		var forward: Vector3 = track.centerline_forward(peak_arc)
		var side := Vector3(forward.z, 0.0, -forward.x)
		camera.global_position = point-forward*100.0+side*65.0+Vector3.UP*25.0
		camera.look_at(point+forward*35.0, Vector3.UP)
		camera.make_current()
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("slope.png"))
	var old_id := scene.get_instance_id()
	state.restart_race()
	check(await wait_racing(old_id), "实际重试重新装配并完成倒计时")
	check(state.race_variant_summary() == first, "重试后同局组合、种子、摘要不变")
	state.back_to_menu()
	var deadline := Time.get_ticks_msec()+10000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.scene_file_path == "res://scenes/menu.tscn": break
	check(state.phase_name() == "MENU" and state.race_variant_summary().is_empty(), "真实返回菜单释放本局组合")
	state.apply_cli_args(PackedStringArray(["--race-seed=54321", "--race-combination=0"]))
	change_scene_to_file("res://scenes/main.tscn")
	check(await wait_racing(), "新比赛可重新装配另一组合")
	check(state.race_variant_summary().get("combination", -1) == 0, "新比赛未复用旧组合8")
	paused = false
	var music := state.find_child("MenuMusic", false, false)
	if music != null: await music.shutdown_and_wait()
	var active := current_scene
	var audio_ids := AudioExit.capture_tree(active)
	current_scene = null
	if active != null: active.free()
	check(await AudioExit.wait_all_released(self, audio_ids), "音频回执实际回收后退出")
	print("FIVE_RUNTIME_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
