extends SceneTree
const Track := preload("res://scripts/track_generator.gd")
const Field := preload("res://scripts/obstacle_field.gd")
var output := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func run() -> void:
	var records: Array = []
	for level in range(3,6):
		var cfg: Resource = load("res://data/levels/level_%d.tres" % level)
		var track := Track.new()
		track.level_config = cfg
		root.add_child(track);track.build_world()
		var field := Field.new()
		root.add_child(field);field.build(cfg,track)
		var boxes: Array = []
		for node in field.get_node("ObstacleBody").get_children():
			if node is CollisionShape3D:
				var p: Vector3 = node.global_position
				var size: Vector3 = node.shape.size
				boxes.append({"center":[p.x,p.y,p.z],"size":[size.x,size.y,size.z]})
		records.append({"level":level,"length":track.road_length(),"layout":cfg.layout,
			"boxes":boxes,"occupancy":field.obstacles})
		field.free();track.free()
	FileAccess.open(output.path_join("obstacles.json"),FileAccess.WRITE).store_string(JSON.stringify(records,"  "))
	await process_frame
	await process_frame
	print("OBSTACLE_SNAPSHOT_COMPLETE levels=3")
	quit()
