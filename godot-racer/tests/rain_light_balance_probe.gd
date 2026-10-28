extends SceneTree
var output := ""
func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
	call_deferred("run")
func run() -> void:
	var state := root.get_node("GameState")
	state.settings_path=output.path_join("settings.cfg");state.chosen_level=2
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec()+50000
	while current_scene==null or state.phase_name()!="RACING":
		await process_frame
		if Time.get_ticks_msec()>deadline: quit(1);return
	var scene := current_scene
	for car in scene.find_children("*","VehicleBody3D",true,false):
		car.set_physics_process(false);car.freeze=true
	await create_timer(1).timeout
	scene.get_node("ChaseCamera").set_process(false)
	DisplayServer.window_set_size(Vector2i(1280,720))
	var env: Environment = scene.get_node("WorldEnvironment").environment
	var sun: DirectionalLight3D = scene.get_node("Sun")
	var road: MeshInstance3D = scene.get_node("Track").find_child("RoadMesh",true,false)
	for mode in range(3):
		sun.light_specular=0.0
		sun.light_energy=[0.65,0.35,0.0][mode]
		env.ambient_light_color=Color(0.70,0.74,0.80)
		env.ambient_light_energy=[1.1,1.5,2.5][mode]
		road.material_override.set_shader_parameter("road_color",Color(0.12,0.15,0.18) if mode==0 else Color(0.16,0.19,0.22))
		road.material_override.set_shader_parameter("accent_color",Color(0.16,0.19,0.22) if mode==0 else Color(0.19,0.23,0.26))
		await create_timer(0.4).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("rain-balance-%d.png" % mode))
	state.enter_menu();current_scene=null;scene.free();await process_frame
	var music := state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	preload("res://scripts/theme_sky.gd").clear_cached_textures()
	await process_frame;await RenderingServer.frame_post_draw
	print("RAIN_BALANCE_PROBE_COMPLETE");quit(0)
