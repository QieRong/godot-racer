extends SceneTree
const Pilot := preload("res://scripts/autopilot.gd")
const Track := preload("res://scripts/track_generator.gd")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var track := Track.new()
	track.level_config = load("res://data/levels/level_2.tres")
	root.add_child(track)
	track.build_world()
	var pilot := Pilot.new()
	var failed := 0
	for arc in [300.0, 900.0, 1700.0]:
		var pos: Vector3 = track.centerline_point(arc)
		var backward: Vector3 = -track.centerline_forward(arc)
		var result: Dictionary = pilot.drive_best_track_arc(track, pos, backward, arc)
		var distance := pos.distance_to(result.pos)
		var ok := distance < 1.0 and Vector3(result.fwd).dot(-backward) > 0.99
		if not ok: failed += 1
		print("RECOVERY_ASSERT %s local_pose %.3fm arc=%.1f" % ["PASS" if ok else "FAIL", distance, arc])
	track.free()
	print("RECOVERY_COMPLETE PASS=%d FAIL=%d" % [3-failed, failed])
	quit(0 if failed == 0 else 1)
