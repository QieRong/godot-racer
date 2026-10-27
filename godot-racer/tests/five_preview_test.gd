extends SceneTree
var output := ""
var passed := 0
var failed := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, description: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("FIVE_PREVIEW_ASSERT %s %s" % ["PASS" if ok else "FAIL", description])

func run() -> void:
	var state := root.get_node("GameState")
	state.settings_path = output.path_join("settings.cfg")
	for level in range(5):
		state.chosen_level = level
		state.ai_enabled = true
		change_scene_to_file("res://scenes/main.tscn")
		var deadline := Time.get_ticks_msec() + 50000
		while Time.get_ticks_msec() < deadline:
			await process_frame
			if current_scene != null and state.phase_name() == "RACING": break
		check(state.phase_name() == "RACING", "L%d 实际装配发车" % (level+1))
		if state.phase_name() != "RACING": break
		var scene := current_scene
		var track: Node3D = scene.get_node("Track")
		var scenery: Node3D = scene.get_node_or_null("TrackScenery")
		check(scenery != null and scenery.asset_instances > 20, "L%d 主题实例已装配" % (level+1))
		check(scene.get("_opponents").size() == 1 and track.is_world_ready(), "L%d 路面/对手就绪" % (level+1))
		await create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("L%d-drive.png" % (level+1)))
		var lower := Vector3(INF,0,INF)
		var upper := Vector3(-INF,0,-INF)
		for i in range(1000):
			var point: Vector3 = track.centerline_point(i * track.road_length() / 1000.0)
			lower.x = minf(lower.x,point.x);lower.z = minf(lower.z,point.z)
			upper.x = maxf(upper.x,point.x);upper.z = maxf(upper.z,point.z)
		var center := (lower+upper)*0.5
		var camera := Camera3D.new()
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = maxf(upper.z-lower.z+100.0,(upper.x-lower.x+100.0)*0.6)
		camera.far = 10000.0
		scene.add_child(camera)
		camera.global_position = center+Vector3.UP*1800.0
		camera.look_at(center,Vector3.FORWARD);camera.make_current()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("L%d-overview.png" % (level+1)))
		state.enter_menu()
		current_scene = null
		scene.free()
		await process_frame
		await process_frame
	change_scene_to_file("res://scenes/menu.tscn")
	await create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("menu.png"))
	check(state.level_count() == 5, "返回菜单仍能枚举五关")
	var music := state.find_child("MenuMusic",false,false)
	if music != null: await music.shutdown_and_wait()
	var scene := current_scene
	current_scene = null
	scene.free()
	await process_frame
	await process_frame
	print("FIVE_PREVIEW_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed == 0 else 1)
