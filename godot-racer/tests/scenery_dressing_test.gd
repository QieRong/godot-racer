extends SceneTree
## 真实渲染五关布景，检查实际MultiMesh分布与道路净空；不替代性能或U。
var output := ""
var passed := 0
var failed := 0
var summary: Array = []
var single_level := -1
const EXPECTED := [
	["barracks_hut_01","training_storage_shed_01","training_watchtower_01"],
	["country_house_01","small_barn_01","farm_windmill_01"],
	["city_building_low_01","city_building_mid_01","bus_shelter_01","electrical_cabinet_01","vending_machine_blank_01","konbini_aoi_01"],
	["sandstone_boulder","desert_cactus_01","ruin_wall_01","desert_rock_arch_01","desert_mesa_01","desert_cliff_module_01"],
	["ice_boulder_01","snow_cabin_01","snow_mountain_ridge_01"]]

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
		if arg.begins_with("--single-level="): single_level=int(arg.trim_prefix("--single-level="))
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("DRESSING_ASSERT %s %s" % ["PASS" if ok else "FAIL",message])

func capture(label: String) -> void:
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(label+".png"))

func inspect_groups(dressing: Node3D, track: Node3D, level: int) -> void:
	var far_instances := 0
	var batches := 0
	var all_clear := true
	var matte := true
	var training_colors := true
	var distances: Array[float] = []
	var scales: Array[float] = []
	var actual: Array[String] = []
	var line := PackedVector2Array()
	for i in range(ceili(track.road_length()/3.0)+1):
		var p: Vector3 = track.centerline_point(minf(float(i)*3.0,track.road_length()))
		line.append(Vector2(p.x,p.z))
	for group in dressing.get_children():
		actual.append(str(group.name))
		var first_mesh: Mesh
		for batch in group.get_children():
			if not batch is MultiMeshInstance3D: continue
			if first_mesh==null: first_mesh=batch.multimesh.mesh
			batches += 1
			var bounds: AABB = batch.multimesh.mesh.get_aabb()
			for surface in range(batch.multimesh.mesh.get_surface_count()):
				var material := batch.multimesh.mesh.surface_get_material(surface) as StandardMaterial3D
				matte=matte and material!=null and material.specular_mode==BaseMaterial3D.SPECULAR_DISABLED
				if level==1 and material!=null and material.resource_name=="cream":
					training_colors=training_colors and material.albedo_color.r>material.albedo_color.g \
						and material.albedo_color.g>material.albedo_color.b
			for i in range(batch.multimesh.instance_count):
				var xf: Transform3D = batch.global_transform*batch.multimesh.get_instance_transform(i)
				var center: Vector3 = xf*bounds.get_center()
				# 独立3m折线，变换后包围盒半径保守覆盖整个网格的XZ投影。
				var radius := 0.0
				for corner in range(8):
					var delta: Vector3 = xf*bounds.get_endpoint(corner)-center
					radius=maxf(radius,Vector2(delta.x,delta.z).length())
				var distance := INF
				var p2 := Vector2(center.x,center.z)
				for j in range(1,line.size()):
					var step := line[j]-line[j-1]
					var t := clampf((p2-line[j-1]).dot(step)/maxf(step.length_squared(),0.00001),0,1)
					distance=minf(distance,p2.distance_to(line[j-1]+step*t))
				all_clear=all_clear and distance-radius>track.rail_half_width()+1.0
				if batch.multimesh.mesh==first_mesh and group.get_meta("tier","")=="far": far_instances+=1
				if level==4 and group.name=="sandstone_boulder":
					distances.append(distance)
					scales.append(xf.basis.get_scale().length())
	actual.sort()
	var expected: Array = EXPECTED[level-1].duplicate()
	expected.sort()
	check(actual==expected,"L%d 实际模型白名单匹配主题，无串用" % level)
	check(far_instances>=5,"L%d 实际装配至少5个远景模型" % level)
	check(all_clear,"L%d 所有装饰网格保守包围半径避开道路/空气墙" % level)
	check(matte,"L%d 装饰使用独立哑光材质" % level)
	if level==1: check(training_colors,"训练营采用独立暖灰米色墙面覆盖")
	check(batches>0 and batches<250,"L%d 布景批次有界：%d" % [level,batches])
	check(dressing.find_children("*","CollisionObject3D",true,false).is_empty(),"L%d 布景无新增碰撞" % level)
	if level==4:
		distances.sort();scales.sort()
		check(distances.size()>20 and distances[-1]-distances[0]>20.0,
			"沙漠岩石不沿固定路边距离排列，离路深度跨度>20m")
		check(scales.size()>20 and scales[-1]/scales[0]>1.5,"沙漠岩石尺寸有变化")
	summary.append({"level":level,"far_mesh_instances":far_instances,"batches":batches,"clear":all_clear})

func run() -> void:
	var state := root.get_node("GameState")
	state.settings_path=output.path_join("settings.cfg")
	for level in range(5):
		if single_level>=0 and level!=single_level: continue
		state.chosen_level=level
		change_scene_to_file("res://scenes/main.tscn")
		var deadline := Time.get_ticks_msec()+50000
		while Time.get_ticks_msec()<deadline:
			await process_frame
			if current_scene!=null and state.phase_name()=="RACING": break
		check(current_scene!=null and state.phase_name()=="RACING","L%d 实际装配发车" % (level+1))
		if current_scene==null or state.phase_name()!="RACING": quit(1);return
		var scene := current_scene
		var track: Node3D = scene.get_node("Track")
		for car in scene.find_children("*","VehicleBody3D",true,false):
			car.set_physics_process(false);car.freeze=true
		var dressing: Node3D = scene.get_node("TrackScenery").get_node_or_null("SceneryDressing")
		check(dressing!=null,"L%d 新模型布景存在" % (level+1))
		if dressing!=null: inspect_groups(dressing,track,level+1)
		var relief := scene.get_node("TrackScenery").get_node_or_null("GroundRelief")
		check(relief!=null and int(relief.get_meta("landforms",0))>=12,
			"L%d 有主题地面起伏与材质过渡" % (level+1))
		var env: Environment = scene.get_node("WorldEnvironment").environment
		check(env.background_mode==Environment.BG_SKY and env.sky!=null
			and env.sky.has_meta("theme"),"L%d 使用独立主题天空" % (level+1))
		check(env.fog_sky_affect<0.25,"L%d 雾不覆盖全部云层" % (level+1))
		var curbs := 0
		var curb_matte := true
		for batch in scene.get_node("TrackScenery").get_children():
			if batch is MultiMeshInstance3D and batch.multimesh.mesh is BoxMesh:
				var box: BoxMesh = batch.multimesh.mesh
				if absf(box.size.x-0.45)<0.001:
					curbs+=1
					curb_matte=curb_matte and box.material.specular_mode==BaseMaterial3D.SPECULAR_DISABLED
		check(curbs==2 and curb_matte,"L%d 红白路缘独立哑光且保留两色批次" % (level+1))
		if level!=2:
			var road: MeshInstance3D = track.find_child("RoadMesh",true,false)
			var road_material := road.material_override as ShaderMaterial
			check(road_material!=null and float(road_material.get_shader_parameter("surface_specular"))==0.0,
				"L%d 干燥路面不出现大面积镜面白斑" % (level+1))
		await create_timer(2.0).timeout
		DisplayServer.window_set_size(Vector2i(1280,720))
		await capture("L%d-start-720" % (level+1))
		if level<2:
			var image := root.get_texture().get_image()
			var saturated := 0
			for y in range(240,290):
				for x in range(1050,1260):
					var color := image.get_pixel(x,y)
					if maxf(color.r,maxf(color.g,color.b))>0.98: saturated+=1
			check(float(saturated)/10500.0<0.15,"L%d 路旁局部无大片颜色削顶" % (level+1))
		var player: VehicleBody3D = scene.get_node("RaceCar")
		for fraction in [0.25,0.60]:
			var arc: float = fraction*track.road_length()
			player.global_position=track.centerline_point(arc)+Vector3.UP*0.6
			var f: Vector3 = track.centerline_forward(arc)
			player.global_rotation=Vector3(0,atan2(-f.x,-f.z),0)
			var camera: Camera3D = scene.get_node("ChaseCamera")
			camera.set_view_mode(2)
			DisplayServer.window_set_size(Vector2i(1920,1080))
			await capture("L%d-arc%d-1080" % [level+1,int(fraction*100)])
		var lower := Vector3(INF,0,INF)
		var upper := Vector3(-INF,0,-INF)
		for i in range(400):
			var point: Vector3 = track.centerline_point(float(i)*track.road_length()/400.0)
			lower.x=minf(lower.x,point.x);lower.z=minf(lower.z,point.z)
			upper.x=maxf(upper.x,point.x);upper.z=maxf(upper.z,point.z)
		var center := (lower+upper)*0.5
		var overview := Camera3D.new()
		overview.projection=Camera3D.PROJECTION_ORTHOGONAL
		overview.size=maxf(upper.z-lower.z+400.0,(upper.x-lower.x+400.0)*0.6)
		overview.far=10000.0
		scene.add_child(overview)
		overview.global_position=center+Vector3.UP*1800.0
		overview.look_at(center,Vector3.FORWARD);overview.make_current()
		await capture("L%d-overview-1080" % (level+1))
		state.enter_menu();current_scene=null;scene.free()
		await process_frame
	var file := FileAccess.open(output.path_join("dressing.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":passed,"failed":failed,"levels":summary},"  "))
	var music := state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	preload("res://scripts/theme_sky.gd").clear_cached_textures()
	await process_frame
	await RenderingServer.frame_post_draw
	print("DRESSING_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
