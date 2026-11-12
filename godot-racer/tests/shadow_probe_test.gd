extends SceneTree
## 仅诊断真实画面；90秒装配观察不代替既有30秒生命周期验收门。
var output := ""
var level := 1

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.get_slice("=", 1)
		if arg.begins_with("--level="): level = int(arg.get_slice("=", 1))
	call_deferred("run")

func shot(label: String) -> void:
	for i in range(3): await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(label + ".png"))
	print("SHADOW_PROBE_SHOT ", label)

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
		print("SHADOW_PROBE_ASSEMBLY_FAIL ", Time.get_ticks_msec() - started)
		quit(1)
		return
	print("SHADOW_PROBE_ASSEMBLY_MS ", Time.get_ticks_msec() - started)
	var scene := current_scene
	var car: VehicleBody3D = scene.get_node("RaceCar")
	car.freeze = true
	var camera: Camera3D = scene.get_node("ChaseCamera")
	await create_timer(4.0).timeout
	camera.set_process(false)
	var original := camera.global_transform
	for i in range(4):
		camera.global_position = original.origin + Vector3(0.03 * i, 0, 0)
		await shot("baseline-%d" % i)
	camera.global_transform = original
	var lights := scene.find_children("*", "Light3D", true, false)
	var shadow_states: Array[bool] = []
	for light in lights:
		shadow_states.append(light.shadow_enabled)
		print("SHADOW_PROBE_LIGHT ", light.get_path(), " energy=", light.light_energy,
			" shadow=", light.shadow_enabled, " basis=", light.global_basis)
		light.shadow_enabled = false
	await shot("no-shadows")
	for i in range(lights.size()): lights[i].shadow_enabled = shadow_states[i]
	for name in ["TerrainAndGroundTransitions", "GroundMesh", "ElevationVerges", "StartGantry", "SceneryDressing"]:
		var item := scene.find_child(name, true, false) as Node3D
		if item != null:
			item.visible = false
			await shot("hide-" + name)
			item.visible = true
	for name in ["GroundMesh", "ElevationVerges", "RoadMesh"]:
		var item := scene.find_child(name, true, false) as GeometryInstance3D
		if item != null:
			var original_shadow := item.cast_shadow
			item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			await shot("no-cast-" + name)
			item.cast_shadow = original_shadow
	var preview := scene.get_node_or_null("Track/Sun") as DirectionalLight3D
	if preview != null:
		var energy := preview.light_energy
		preview.light_energy = 0.0
		await shot("no-preview-sun")
		preview.light_energy = energy
	# C真实赛道截图，保留同一镜头的前/后方向及帮助的两种分辨率证据。
	camera.set_process(true)
	await shot("camera-forward")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_C
	key.pressed = true
	Input.parse_input_event(key)
	await shot("camera-rear")
	key.pressed = false
	Input.parse_input_event(key)
	await shot("camera-restored")
	var help: Control = load("res://scripts/menu_overlay.gd").new()
	help.setup(state, Color.SKY_BLUE, "help")
	var canvas := CanvasLayer.new()
	root.add_child(canvas)
	canvas.add_child(help)
	for size in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		root.size = size
		await shot("help-%dx%d" % [size.x, size.y])
	canvas.free()
	var music := state.find_child("MenuMusic", false, false)
	if music != null: await music.call("shutdown_and_wait")
	current_scene = null
	scene.free()
	await process_frame
	await process_frame
	print("SHADOW_PROBE_COMPLETE")
	quit()
