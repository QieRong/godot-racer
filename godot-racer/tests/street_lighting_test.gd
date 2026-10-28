extends SceneTree
## 验证最终MultiMesh灯头朝内、实际灯光照路、随车更新与场景回收；保留真实截图。
var output := ""
var passed := 0
var failed := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("STREET_LIGHT_ASSERT %s %s" % ["PASS" if ok else "FAIL",message])

func mesh_centers(scenery: Node3D, mesh: Mesh) -> Array[Vector3]:
	var points: Array[Vector3] = []
	for node in scenery.get_children():
		if node is not MultiMeshInstance3D or node.multimesh.mesh != mesh: continue
		for i in range(node.multimesh.instance_count):
			points.append(node.global_transform * node.multimesh.get_instance_transform(i) * mesh.get_aabb().get_center())
	return points

func lit_spots(node: Node) -> Array[SpotLight3D]:
	var result: Array[SpotLight3D] = []
	for child in node.get_children():
		if child is SpotLight3D and child.visible and child.light_energy > 0.0: result.append(child)
		result.append_array(lit_spots(child))
	return result

func independent_center(point: Vector3, line: Array[Vector3]) -> Vector3:
	# 几何镜像用最终曲线的1m折线投影；生产全局最近点的粗采样不适合量镜像误差。
	var best := Vector3.ZERO
	var distance := INF
	for i in range(1,line.size()):
		var start := Vector2(line[i-1].x,line[i-1].z)
		var step := Vector2(line[i].x,line[i].z)-start
		if step.length_squared()<0.000001: continue
		var t := clampf((Vector2(point.x,point.z)-start).dot(step)/step.length_squared(),0.0,1.0)
		var p := start+step*t
		var d := Vector2(point.x,point.z).distance_squared_to(p)
		if d<distance:
			distance=d
			best=Vector3(p.x,lerpf(line[i-1].y,line[i].y,t),p.y)
	return best

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = 2
	state.settings_path = output.path_join("settings.cfg")
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec()+40000
	while Time.get_ticks_msec()<deadline:
		await process_frame
		if current_scene != null and state.phase_name()=="RACING": break
	check(current_scene != null and state.phase_name()=="RACING", "雨夜街道实际装配发车")
	if failed: quit(1); return
	var scene := current_scene
	var player: VehicleBody3D = scene.get_node("RaceCar")
	player.freeze = true
	var track: Node3D = scene.get_node("Track")
	var scenery: Node3D = scene.get_node("TrackScenery")
	var model: Node = load("res://models/environment/street_lamp.glb").instantiate()
	var foot_mesh: Mesh = model.find_child("footplate_0",true,false).mesh
	var head_mesh: Mesh = model.find_child("emissive_lens_5",true,false).mesh
	var feet := mesh_centers(scenery,foot_mesh)
	var heads := mesh_centers(scenery,head_mesh)
	model.free()
	check(feet.size()>20 and heads.size()==feet.size(), "实际灯头与灯座一一对应")
	var wrong := 0
	var unmatched := 0
	var line: Array[Vector3] = []
	for i in range(ceili(track.road_length())+1):
		line.append(track.centerline_point(minf(float(i),track.road_length())))
	for foot in feet:
		var center := independent_center(foot,line)
		var inward := center-foot
		inward.y = 0.0
		var head := Vector3.ZERO
		var distance := INF
		for candidate in heads:
			var d := Vector2(candidate.x-foot.x,candidate.z-foot.z).length()
			if d<distance: distance=d;head=candidate
		var arm := head-foot
		arm.y=0.0
		if arm.normalized().dot(inward.normalized())<0.95: wrong+=1
		var mirror := center*2.0-foot
		var matched := false
		for other in feet:
			if Vector2(other.x-mirror.x,other.z-mirror.z).length()<1.0: matched=true;break
		if not matched: unmatched+=1
	check(wrong==0, "所有灯臂朝向道路内部：反向%d/%d" % [wrong,feet.size()])
	check(unmatched==0, "左右灯座沿道路成镜像对：缺配%d" % unmatched)
	await create_timer(2.2).timeout
	# 店前檐灯有独立的店前落点规则，原道路光轴判据只检查真实道路灯池。
	var spots := lit_spots(scenery.get_node("StreetLighting"))
	check(spots.size()>0 and spots.size()<=8, "实际启用SpotLight3D且近车灯池不超过8盏")
	check(lit_spots(scenery).size()<=8,"包含便利店檐灯的整场景活动射灯仍不超过8盏")
	var invalid := 0
	for light in spots:
		var direction := -light.global_basis.z
		if direction.y>=-0.01: invalid+=1;continue
		var hit: Vector3 = light.global_position+direction*(-light.global_position.y/direction.y)
		var near: Dictionary = track.nearest_on_centerline(hit,-1.0)
		if float(near.dist)>track.road_half_width() or light.global_position.distance_to(hit)>light.spot_range: invalid+=1
	check(not spots.is_empty() and invalid==0, "真实光轴落在路面且在灯光射程内")
	var env: Environment = scene.get_node("WorldEnvironment").environment
	check(env.ambient_light_source==Environment.AMBIENT_SOURCE_COLOR and env.ambient_light_energy>=0.5,
		"雨夜有明确基础环境光，保留夜色同时让路面可见")
	if DisplayServer.get_name()!="headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("rain-night-drive-720.png"))
		var pool: Node = scenery.get_node_or_null("StreetLighting")
		if pool != null: pool.set_process(false)
		for light in spots: light.visible=false
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("rain-night-lights-off-control.png"))
		for light in spots: light.visible=true
		DisplayServer.window_set_size(Vector2i(1920,1080))
		await create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("rain-night-drive-1080.png"))
		if pool != null: pool.set_process(true)
	var old_positions: Array[Vector3] = []
	for light in spots: old_positions.append(light.global_position)
	player.global_position=track.centerline_point(track.road_length()*0.5)+Vector3.UP*0.6
	await create_timer(0.4).timeout
	var moved := 0
	for light in lit_spots(scenery.get_node("StreetLighting")):
		if not old_positions.has(light.global_position): moved+=1
	check(moved>0, "车辆移到另一段后实际灯池更新")
	var reference: WeakRef = weakref(scenery)
	FileAccess.open(output.path_join("lighting-summary.json"),FileAccess.WRITE).store_string(JSON.stringify({
		"feet":feet.size(),"heads":heads.size(),"wrong_facing":wrong,"unmatched_pairs":unmatched,
		"active_spots":spots.size(),"invalid_spot_aim":invalid,"moved_spots":moved,
		"ambient_energy":env.ambient_light_energy,"passed":passed,"failed":failed},"  "))
	var music := state.find_child("MenuMusic",false,false)
	if music != null: await music.shutdown_and_wait()
	current_scene=null
	scene.free()
	await process_frame
	await process_frame
	check(reference.get_ref()==null,"退出场景释放路灯和灯池")
	print("STREET_LIGHT_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
