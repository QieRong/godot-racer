extends SceneTree
const Track := preload("res://scripts/track_generator.gd")
const Scenery := preload("res://scripts/track_scenery.gd")
var output := ""
var passed := 0
var failed := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed+=1
	else: failed+=1
	print("BOUNDARY_ASSERT %s %s" % ["PASS" if ok else "FAIL",message])

func collision_hash(track: Node, name: String) -> String:
	var shape: ConcavePolygonShape3D = track.get_node(name).get_child(0).shape
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(shape.get_faces().to_byte_array())
	return context.finish().hex_encode()

func run() -> void:
	var reports: Array = []
	for level in range(1,6):
		var cfg: Resource=load("res://data/levels/level_%d.tres" % level)
		var track:=Track.new()
		track.level_config=cfg
		root.add_child(track)
		track.build_world()
		var scenery:=Scenery.new()
		root.add_child(scenery)
		scenery.build(track,cfg)
		await physics_frame
		await physics_frame
		var visual: Node3D=track.get_node_or_null("Guardrails")
		check(visual==null or not visual.visible,"L%d 高红墙不再可见" % level)
		var curb_batches:=0
		var curb_instances:=0
		for node in scenery.get_children():
			if node is MultiMeshInstance3D and node.multimesh.mesh is BoxMesh:
				if node.multimesh.mesh.size.is_equal_approx(Vector3(0.45,0.06,2.1)):
					curb_batches+=1
					curb_instances+=node.multimesh.instance_count
		check(curb_batches==2 and curb_instances>track.road_length()*0.9,"L%d 双侧红白路缘仍在" % level)
		var posts: MultiMeshInstance3D=scenery.get_node_or_null("BoundaryDelineators/Posts")
		var count:=0 if posts==null else posts.multimesh.instance_count
		check(count>40,"L%d 空气墙边界有低矮反光桩" % level)
		var matched:=0
		if posts!=null:
			for i in range(count):
				var t: Transform3D=posts.global_transform*posts.multimesh.get_instance_transform(i)
				var side:=t.basis.x.normalized()
				var query:=PhysicsRayQueryParameters3D.create(t.origin-side*2.0,t.origin+side*2.0,1)
				var hit: Dictionary=track.get_world_3d().direct_space_state.intersect_ray(query)
				if i<2:
					print("BOUNDARY_RAY_DEBUG L%d post=%s side=%s hit=%s" % [level,t.origin,side,str(hit)])
				if not hit.is_empty() and hit.collider.name=="AirWall" and Vector3(hit.position).distance_to(t.origin)<0.2:
					matched+=1
		check(count>0 and matched==count,"L%d 每根桩的实际位置由原空气墙射线核对：%d/%d" % [level,matched,count])
		var bodies:=scenery.find_children("*","CollisionObject3D",true,false).size()
		check(bodies==0,"L%d 主题及反光桩不新增碰撞体" % level)
		reports.append({"level":level,"road_width":track.road_width,"length":track.road_length(),
			"wall_half":track.rail_half_width(),"road_collision":collision_hash(track,"RoadBody"),
			"wall_collision":collision_hash(track,"AirWall"),"posts":count,"matched_posts":matched,
			"curb_instances":curb_instances})
		scenery.free()
		track.free()
		await process_frame
	FileAccess.open(output.path_join("boundary-geometry.json"),FileAccess.WRITE).store_string(JSON.stringify(reports,"  "))
	print("BOUNDARY_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
