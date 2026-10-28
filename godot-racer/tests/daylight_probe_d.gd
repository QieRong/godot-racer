extends SceneTree
## 只在当前诊断场景切换材质/日光，生产配置不改；保留三组同机位画面。
var output := ""
var rows: Array = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func capture(label: String) -> void:
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(output.path_join(label+".png"))
	var white := 0
	var count := 0
	var sum := 0.0
	for y in range(240,290):
		for x in range(1050,1260):
			var c := image.get_pixel(x,y)
			if minf(c.r,minf(c.g,c.b))>250.0/255.0: white+=1
			sum+=(c.r+c.g+c.b)/3.0;count+=1
	rows.append({"label":label,"white_ratio":float(white)/count,"mean_rgb":sum/count})

func matte(node: Node) -> void:
	if node is MeshInstance3D and node.material_override is StandardMaterial3D:
		var mat := node.material_override.duplicate() as StandardMaterial3D
		mat.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
		mat.metallic=0.0;mat.metallic_texture=null
		node.material_override=mat
	if node is MultiMeshInstance3D:
		var mesh := node.multimesh.mesh.duplicate() as ArrayMesh
		if mesh!=null:
			for i in range(mesh.get_surface_count()):
				var source: Material = node.material_override if node.material_override!=null else mesh.surface_get_material(i)
				if source is StandardMaterial3D:
					var material := source.duplicate() as StandardMaterial3D
					material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
					material.metallic=0.0;material.metallic_texture=null
					mesh.surface_set_material(i,material)
			node.multimesh.mesh=mesh
			node.material_override=null
	for child in node.get_children(): matte(child)

func run() -> void:
	var state := root.get_node("GameState")
	state.settings_path=output.path_join("settings.cfg")
	for level in range(2):
		state.chosen_level=level
		change_scene_to_file("res://scenes/main.tscn")
		while current_scene==null or state.phase_name()!="RACING": await process_frame
		var scene := current_scene
		for car in scene.find_children("*","VehicleBody3D",true,false):
			car.set_physics_process(false);car.freeze=true
		await create_timer(2.0).timeout
		var env: Environment = scene.get_node("WorldEnvironment").environment
		var sun: DirectionalLight3D = scene.get_node("Sun")
		print("DAYLIGHT_BASE L",level+1," sun=",sun.light_energy," ambient=",env.ambient_light_energy)
		await capture("L%d-A-original" % (level+1))
		matte(scene.get_node("Track"));matte(scene.get_node("TrackScenery"))
		await capture("L%d-B-matte-only" % (level+1))
		sun.light_energy=0.8;env.ambient_light_energy=0.35
		await capture("L%d-C-matte-lower-light" % (level+1))
		var ground: MeshInstance3D = scene.get_node("Track").find_child("GroundMesh",true,false)
		ground.material_override.albedo_color=Color(0.18,0.24,0.10)
		await capture("L%d-D-lower-ground" % (level+1))
		sun.light_energy=0.0;env.ambient_light_energy=0.0
		await capture("L%d-E-zero-light-control" % (level+1))
		state.enter_menu();current_scene=null;scene.free();await process_frame
	var file := FileAccess.open(output.path_join("diagnostic.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"  "))
	var music := state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	print("DAYLIGHT_PROBE_COMPLETE")
	quit()
