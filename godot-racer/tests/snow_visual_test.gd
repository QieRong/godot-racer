extends SceneTree
## 真场景视觉专项；不替代原weather步频判据或真人舒适度验收。
var output := ""
var passed := 0
var failed := 0
var samples: Array = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("SNOW_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func capture(label: String, assess_snow_region: bool = true) -> void:
	if DisplayServer.window_get_mode()==DisplayServer.WINDOW_MODE_MINIMIZED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	await create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(output.path_join(label + ".png"))
	var clipped := 0
	var count := 0
	var luminance := 0.0
	var low := 1.0
	var high := 0.0
	for y in range(int(image.get_height()*0.32), int(image.get_height()*0.40)):
		for x in range(int(image.get_width()*0.83), int(image.get_width()*0.99)):
			var pixel := image.get_pixel(x,y)
			var value := (pixel.r+pixel.g+pixel.b)/3.0
			if minf(pixel.r,minf(pixel.g,pixel.b)) >= 250.0/255.0: clipped += 1
			count += 1
			luminance += value
			low = minf(low,value)
			high = maxf(high,value)
	var ratio := float(clipped)/maxi(count,1)
	samples.append({"label":label,"size":[image.get_width(),image.get_height()],
		"region":"right snow x83%-99%, y32%-40%", "clipped_ratio":ratio,
		"mean_rgb":luminance/maxi(count,1),"range":high-low})
	if assess_snow_region:
		check(ratio < 0.20 and luminance/maxi(count,1)>=0.50 and luminance/maxi(count,1)<0.90,
			label+" 路旁局部保留灰度（纯白占比%.2f%%、均值%.3f）" % [ratio*100.0,luminance/maxi(count,1)])

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = 4
	state.settings_path = output.path_join("settings.cfg")
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec()+50000
	while Time.get_ticks_msec()<deadline:
		await process_frame
		if current_scene!=null and state.phase_name()=="RACING": break
	check(current_scene!=null and state.phase_name()=="RACING", "雪地实际装配并发车")
	if failed: quit(1); return
	var scene := current_scene
	var ground: MeshInstance3D = scene.get_node("Track").find_child("GroundMesh",true,false)
	var ground_material := ground.get_active_material(0) as StandardMaterial3D
	print("SNOW_GROUND_DIAGNOSTIC ",ground_material.albedo_color," ",ground_material.albedo_texture,
		" emission=",ground_material.emission_enabled," shading=",ground_material.shading_mode)
	for car in scene.find_children("*","VehicleBody3D",true,false):
		car.set_physics_process(false)
		car.freeze = true
	var player: VehicleBody3D = scene.get_node("RaceCar")
	var particles: GPUParticles3D = player.get_node("WeatherParticles")
	var mesh: QuadMesh = particles.draw_pass_1
	var particle_material: StandardMaterial3D = mesh.material
	var process_material: ParticleProcessMaterial = particles.process_material
	check(particles.amount==1100 and particles.emitting, "保留1100粒雪花及发射状态")
	check(mesh.size.x>=0.10 and mesh.size.x<=0.16 and process_material.color.a<=0.75,
		"雪花缩小至0.10-0.16m并降低不透明度")
	var texture := particle_material.albedo_texture
	check(texture!=null, "雪花具有边缘渐隐纹理")
	if texture!=null:
		var mask := texture.get_image()
		check(mask.get_pixel(0,0).a<0.05 and mask.get_pixel(mask.get_width()/2,mask.get_height()/2).a>0.8,
			"渐隐纹理中心可见、角落透明")
	var foliage := 0
	var caps := 0
	var isolated := true
	for node in scene.get_node("TrackScenery").get_children():
		if not node is MultiMeshInstance3D: continue
		var source: Material = node.multimesh.mesh.surface_get_material(0)
		if source==null: continue
		var material_name := source.resource_name
		if material_name.begins_with("leaf_"):
			foliage += 1
			var override := node.material_override as StandardMaterial3D
			isolated = isolated and override!=null and override!=source
			if override!=null: isolated = isolated and override.albedo_color.g<0.5
		if material_name in ["snow","snow_shadow"]:
			caps += 1
			var override := node.material_override as StandardMaterial3D
			isolated = isolated and override!=null and override!=source
			if override!=null: isolated = isolated and override.albedo_color.r<0.7
	check(foliage>0 and caps>0 and isolated, "雪树叶片/雪帽有独立低亮材质覆盖")
	var banks := scene.get_node("TrackScenery").get_node_or_null("SnowBanks")
	check(banks!=null and int(banks.get_meta("instance_count",0))>0
		and int(banks.get_meta("instance_count",0))<=40, "复用已有雪堆、总数不超过40")
	if banks!=null:
		check(banks.find_children("*","CollisionObject3D",true,false).is_empty(), "雪堆只作视觉不新增碰撞")
		var clear := true
		var track: Node3D = scene.get_node("Track")
		for batch in banks.get_children():
			var bounds: AABB = batch.multimesh.mesh.get_aabb()
			for i in range(batch.multimesh.instance_count):
				var transform: Transform3D = batch.global_transform*batch.multimesh.get_instance_transform(i)
				var center: Vector3 = transform*bounds.get_center()
				var near: Dictionary = track.nearest_on_centerline(center,-1.0)
				clear = clear and float(near.dist)>track.rail_half_width()+2.5
				for corner in range(8):
					var point: Vector3 = transform*bounds.get_endpoint(corner)
					var query := PhysicsRayQueryParameters3D.create(point+Vector3.UP*50.0,
						Vector3(point.x,-5.0,point.z),1)
					var hit: Dictionary = track.get_world_3d().direct_space_state.intersect_ray(query)
					if not hit.is_empty() and hit.collider.name=="RoadBody": clear = false
		check(clear,"雪堆实际包围盒角点不占路面、中心避开空气墙")
	var forest := scene.get_node("TrackScenery").get_node_or_null("SnowForest")
	check(forest!=null and int(forest.get_meta("instance_count",0))>=12
		and int(forest.get_meta("instance_count",0))<=80, "远景有12-80株复用雪松、只作视觉")
	if forest!=null:
		var clear := forest.find_children("*","CollisionObject3D",true,false).is_empty()
		var track: Node3D = scene.get_node("Track")
		for batch in forest.get_children():
			for i in range(batch.multimesh.instance_count):
				var transform: Transform3D = batch.global_transform*batch.multimesh.get_instance_transform(i)
				var near: Dictionary = track.nearest_on_centerline(transform.origin,-1.0)
				clear = clear and float(near.dist)>track.rail_half_width()+6.0
		check(clear,"远景雪松无碰撞且避开相邻赛道空气墙")
	await create_timer(2.0).timeout
	await capture("snow-drive-720")
	DisplayServer.window_set_size(Vector2i(1920,1080))
	await capture("snow-drive-1080")
	var track: Node3D = scene.get_node("Track")
	var seam_camera := Camera3D.new()
	scene.add_child(seam_camera)
	var seam_point: Vector3 = track.centerline_point(0.0)
	var seam_forward: Vector3 = track.centerline_forward(0.0)
	seam_camera.global_position = seam_point-seam_forward*22.0+Vector3.UP*10.0
	seam_camera.look_at(seam_point+seam_forward*8.0,Vector3.UP)
	seam_camera.make_current()
	await capture("snow-start-seam-1080",false)
	var arc: float = track.road_length()*0.25
	var point: Vector3 = track.centerline_point(arc)
	var forward: Vector3 = track.centerline_forward(arc)
	var camera := Camera3D.new()
	camera.far = 1200.0
	scene.add_child(camera)
	camera.global_position = point-forward*25.0+Vector3.UP*15.0
	camera.look_at(point+forward*50.0,Vector3.UP)
	camera.make_current()
	await capture("snow-forest-quarter-1080",false)
	FileAccess.open(output.path_join("snow-visual-summary.json"),FileAccess.WRITE).store_string(
		JSON.stringify({"passed":passed,"failed":failed,"foliage_batches":foliage,
			"snow_cap_batches":caps,"banks":0 if banks==null else banks.get_meta("instance_count"),
			"forest":0 if forest==null else forest.get_meta("instance_count"),"samples":samples},"  "))
	var music := state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	current_scene = null
	scene.free()
	await process_frame
	print("SNOW_VISUAL_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
