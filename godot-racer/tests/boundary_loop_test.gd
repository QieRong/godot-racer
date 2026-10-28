extends SceneTree
## 实际路缘网格端点按顺序闭环核验，含起点前后的末段；不改碰撞。
const Track := preload("res://scripts/track_generator.gd")
const Scenery := preload("res://scripts/track_scenery.gd")
var output := ""
var passed := 0
var failed := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, text: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("BOUNDARY_LOOP_ASSERT %s %s" % ["PASS" if ok else "FAIL",text])

func run() -> void:
	var reports: Array = []
	for level in range(1,6):
		var track := Track.new()
		track.level_config = load("res://data/levels/level_%d.tres" % level)
		root.add_child(track)
		track.build_world()
		var scenery := Scenery.new()
		root.add_child(scenery)
		scenery.build(track,track.level_config)
		await physics_frame
		await physics_frame
		var batches: Array[MultiMesh] = []
		for node in scenery.get_children():
			if node is MultiMeshInstance3D and node.multimesh.mesh is BoxMesh:
				if node.multimesh.mesh.size.is_equal_approx(Vector3(0.45,0.06,2.1)):
					batches.append(node.multimesh)
		var worst := INF
		var seam := INF
		if batches.size()==2:
			var count: int = (batches[0].instance_count+batches[1].instance_count)/2
			worst = 0.0
			seam = 0.0
			for side in range(2):
				for index in range(count):
					var following: int = (index+1)%count
					var a: Transform3D = batches[index%2].get_instance_transform(floori(float(index)/2.0)*2+side)
					var b: Transform3D = batches[following%2].get_instance_transform(floori(float(following)/2.0)*2+side)
					var end: Vector3 = a.origin+a.basis.z*1.05
					var start: Vector3 = b.origin-b.basis.z*1.05
					var gap := end.distance_to(start)
					worst = maxf(worst,gap)
					if following==0: seam = maxf(seam,gap)
					if level==5 and side==0 and following==0:
						print("CURB_SEAM_DIAGNOSTIC ",a.origin," -> ",b.origin," end=",end," start=",start,
							" length=",track.road_length()," count=",count)
		check(worst<=0.08,"L%d 双侧路缘逐段端点闭合，最大差%.3fm" % [level,worst])
		check(seam<=0.08,"L%d 起点前后路缘接缝闭合，差%.3fm" % [level,seam])
		var posts: MultiMesh = scenery.get_node("BoundaryDelineators/Posts").multimesh
		var max_spacing := 0.0
		var pairs: int = posts.instance_count/2
		for side in range(2):
			for index in range(pairs):
				var a := posts.get_instance_transform(index*2+side).origin
				var b := posts.get_instance_transform(((index+1)%pairs)*2+side).origin
				max_spacing = maxf(max_spacing,a.distance_to(b))
		check(max_spacing<=12.5,"L%d 两侧反光桩含接缝加密覆盖，最大间距%.2fm" % [level,max_spacing])
		var positions: Array = []
		for i in range(posts.instance_count):
			var point := posts.get_instance_transform(i).origin
			positions.append([point.x,point.y,point.z])
		reports.append({"level":level,"curb_endpoint_gap":worst,"start_seam_gap":seam,
			"max_post_spacing":max_spacing,"post_pairs":pairs,"post_positions":positions})
		scenery.free()
		track.free()
		await process_frame
	FileAccess.open(output.path_join("boundary-loop.json"),FileAccess.WRITE).store_string(JSON.stringify(reports,"  "))
	print("BOUNDARY_LOOP_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
