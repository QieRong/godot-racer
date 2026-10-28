extends SceneTree
## 同机位隔离材质：诊断专用，不改生产资源。
var output := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func capture(label: String) -> void:
	await create_timer(0.35).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(label+".png"))

func run() -> void:
	var state := root.get_node("GameState")
	state.settings_path=output.path_join("settings.cfg")
	for level in [2,4]:
		state.chosen_level=level
		change_scene_to_file("res://scenes/main.tscn")
		var deadline := Time.get_ticks_msec()+50000
		while current_scene==null or state.phase_name()!="RACING":
			await process_frame
			if Time.get_ticks_msec()>deadline: quit(1);return
		var scene := current_scene
		for car in scene.find_children("*","VehicleBody3D",true,false):
			car.set_physics_process(false);car.freeze=true
		var camera: Camera3D = scene.get_node("ChaseCamera")
		await create_timer(1).timeout
		camera.set_process(false)
		DisplayServer.window_set_size(Vector2i(1280,720))
		var road: MeshInstance3D = scene.get_node("Track").find_child("RoadMesh",true,false)
		var shader := road.material_override as ShaderMaterial
		await capture("L%d-before" % (level+1))
		var color: Color = shader.get_shader_parameter("road_color")
		var standard := StandardMaterial3D.new()
		standard.albedo_color=color
		standard.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
		road.material_override=standard
		await capture("L%d-standard-same-color" % (level+1))
		road.material_override=shader
		shader.set_shader_parameter("road_color",Color(0.17,0.18,0.19) if level==4 else Color(0.08,0.10,0.12))
		shader.set_shader_parameter("accent_color",Color(0.20,0.21,0.22) if level==4 else Color(0.11,0.13,0.15))
		await capture("L%d-test-palette" % (level+1))
		state.enter_menu();current_scene=null;scene.free();await process_frame
	var music := state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	preload("res://scripts/theme_sky.gd").clear_cached_textures()
	await process_frame
	await RenderingServer.frame_post_draw
	print("ROAD_PALETTE_PROBE_COMPLETE")
	quit(0)
