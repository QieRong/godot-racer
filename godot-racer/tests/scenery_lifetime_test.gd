extends SceneTree
const Track := preload("res://scripts/track_generator.gd")
const Scenery := preload("res://scripts/track_scenery.gd")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var track := Track.new()
	var cfg: Resource = load("res://data/levels/level_5.tres")
	track.level_config = cfg
	root.add_child(track);track.build_world()
	var scenery := Scenery.new()
	root.add_child(scenery);scenery.build(track,cfg)
	var reference: WeakRef = weakref(scenery)
	await process_frame
	scenery.free();track.free()
	for i in range(4): await process_frame
	print("SCENERY_LIFETIME_COMPLETE freed=%s" % str(reference.get_ref()==null))
	quit(0 if reference.get_ref()==null else 1)
