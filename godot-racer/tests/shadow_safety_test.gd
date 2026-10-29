extends SceneTree
## 渲染/结构专项；不改变赛道公式、碰撞、驾驶或既有装配超时门。
var passed := 0
var failed := 0
var output := ""
var level := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.get_slice("=", 1)
		if arg.begins_with("--level="): level = int(arg.get_slice("=", 1))
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("SHADOW_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func frame_image(label: String) -> Image:
	for i in range(4): await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(output.path_join(label + ".png"))
	return image

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = level
	state.settings_path = output.path_join("settings.cfg")
	state.ai_enabled = false
	root.size = Vector2i(1280, 720)
	change_scene_to_file("res://scenes/main.tscn")
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 90000:
		await process_frame
		if current_scene != null and current_scene.get("_setup_done") == true: break
	if current_scene == null or current_scene.get("_setup_done") != true:
		check(false, "诊断90秒装配失败；不替代30秒生命周期门")
		quit(1)
		return
	var scene := current_scene
	var track: Node3D = scene.get_node("Track")
	var ground := track.find_child("GroundMesh", true, false) as MeshInstance3D
	check(ground.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "大地面只接收阴影，避免贴地路肩自遮蔽")
	var verge := track.get_node("ElevationVerges") as MeshInstance3D
	var arrays := verge.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var duplicate_flat := 0
	for i in range(0, vertices.size(), 3):
		if maxf(vertices[i].y, maxf(vertices[i+1].y, vertices[i+2].y)) <= 0.02: duplicate_flat += 1
	check(duplicate_flat == 0, "可见路肩不保留与地面重合的平段三角形")
	check(verge.material_override.albedo_texture == ground.material_override.albedo_texture, "坡面使用本关地表贴图")
	var batches := scene.get_node("TrackScenery").find_children("*", "MultiMeshInstance3D", true, false)
	var models := 0
	var disabled := 0
	for batch in batches:
		if batch.get("multimesh") != null:
			models += 1
			if batch.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON: disabled += 1
	check(models > 0 and disabled == 0, "场景合批模型全部启用投影：%d批/%d关闭" % [models, disabled])
	var active_suns := 0
	for light in scene.find_children("*", "DirectionalLight3D", true, false):
		if light.light_energy > 0.0 and light.shadow_enabled: active_suns += 1
	check(active_suns == 1, "仅一个主方向光负责全场投影，独立预览太阳不叠加")
	var sun := scene.get_node("Sun") as DirectionalLight3D
	var weather: String = state.current_level().weather_type
	check(sun.shadow_enabled and (sun.shadow_opacity < 0.65 if weather in ["rain", "snow"] else sun.shadow_opacity >= 0.65),
		"雨雪阴影较淡，晴天保留明确投影")
	check(sun.shadow_blur > 1.0 if weather in ["rain", "snow"] else sun.shadow_blur >= 1.0, "雨雪阴影采用较柔边界")
	if DisplayServer.get_name() != "headless":
		# 镜头继承暂停：必须等真实GO，不能在倒计时暂停树中拿旧朝向截图。
		while state.call("phase_name") != "RACING" and Time.get_ticks_msec() - started < 90000:
			await process_frame
		check(state.call("phase_name") == "RACING", "真实GO后截图，镜头已恢复处理")
		for i in range(4): await process_frame
		var car: VehicleBody3D = scene.get_node("RaceCar")
		car.freeze = true
		var original := car.global_transform
		var camera: Camera3D = scene.get_node("ChaseCamera")
		for arc in [0.0, track.road_length() * 0.55, 0.0]:
			if arc == 0.0: car.global_transform = original
			else:
				var road_frame: Transform3D = track.surface_frame(arc, 0.0)
				car.global_transform = Transform3D(road_frame.basis * Basis(Vector3.UP, PI), road_frame.origin + Vector3.UP * 0.55)
			camera.call("set_view_mode", 2)
			var label := "start" if arc == 0.0 else "middle"
			if FileAccess.file_exists(output.path_join(label + ".png")): label = "return-start"
			await frame_image(label)
			camera.set_process(false)
			var pose := camera.global_transform
			for i in range(3):
				camera.global_position = pose.origin + Vector3(0.02 * i, 0, 0)
				await frame_image(label + "-jitter-%d" % i)
			camera.set_process(true)
		# 单独去掉模型投影，保留车影：人工图像对照能检验新增树/建筑阴影。
		for batch in batches: batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		await frame_image("models-no-shadow-control")
		for batch in batches: batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var t := Time.get_ticks_usec()
		for i in range(30): await process_frame
		print("SHADOW_RENDER_SAMPLE_MS ", float(Time.get_ticks_usec()-t)/30000.0)
	var music := state.find_child("MenuMusic", false, false)
	if music != null: await music.call("shutdown_and_wait")
	current_scene = null
	scene.free()
	await process_frame
	await process_frame
	print("SHADOW_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
