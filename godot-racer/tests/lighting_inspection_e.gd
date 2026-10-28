extends SceneTree
var output := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func capture(label: String) -> void:
	await create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(label+".png"))

func run() -> void:
	var state := root.get_node("GameState")
	state.settings_path=output.path_join("settings.cfg")
	state.chosen_level=0
	change_scene_to_file("res://scenes/main.tscn")
	while current_scene==null or state.phase_name()!="RACING": await process_frame
	var scene := current_scene
	for car in scene.find_children("*","VehicleBody3D",true,false):
		car.set_physics_process(false);car.freeze=true
	var env: Environment = scene.get_node("WorldEnvironment").environment
	var sun: DirectionalLight3D = scene.get_node("Sun")
	print("LIGHTING_STATE sun=",sun.light_energy," color=",sun.light_color,
		" ambient=",env.ambient_light_energy," color=",env.ambient_light_color,
		" reflected=",env.reflected_light_source," fogsky=",env.fog_sky_affect)
	var group := scene.get_node("TrackScenery/SceneryDressing/barracks_hut_01")
	for node in group.get_children():
		for i in range(node.multimesh.mesh.get_surface_count()):
			var m: StandardMaterial3D = node.multimesh.mesh.surface_get_material(i)
			print("HOUSE_MATERIAL ",m.resource_name," ",m.albedo_color," shading=",m.shading_mode,
				" spec=",m.specular_mode," emission=",m.emission_enabled," ",m.emission)
	await create_timer(2.0).timeout
	await capture("A-current")
	env.reflected_light_source=Environment.REFLECTION_SOURCE_DISABLED
	env.fog_sky_affect=0.12
	await capture("B-reflection-off-sky-visible")
	sun.light_energy=0.60;env.ambient_light_energy=0.18
	await capture("C-lower-light")
	env.ambient_light_sky_contribution=0.0
	env.ambient_light_energy=0.40;sun.light_energy=0.85
	await capture("E-no-sky-diffuse")
	var seen: Dictionary = {}
	for node in scene.get_node("TrackScenery/SceneryDressing").find_children("*","MultiMeshInstance3D",true,false):
		for i in range(node.multimesh.mesh.get_surface_count()):
			var m: StandardMaterial3D = node.multimesh.mesh.surface_get_material(i)
			if seen.has(m.get_instance_id()): continue
			seen[m.get_instance_id()]=true
			m.albedo_color*=Color(0.60,0.60,0.60,1)
	await capture("D-lower-prop-color")
	var music := state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	current_scene=null;scene.free();await process_frame
	print("LIGHTING_INSPECTION_COMPLETE")
	quit()
