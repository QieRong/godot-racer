extends SceneTree
const Variants := preload("res://scripts/race_variants.gd")
const Track := preload("res://scripts/track_generator.gd")
const Field := preload("res://scripts/obstacle_field.gd")
const Elevation := preload("res://scripts/track_elevation.gd")
var passed := 0
var failed := 0
var output := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("VARIANT_GEO_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	var base: Resource = load("res://data/levels/level_2.tres")
	var records: Array = []
	for combination in range(9):
		var variant := Variants.make(base, 12345, combination)
		var cfg: Resource = variant.config
		var track := Track.new()
		track.level_config = cfg
		root.add_child(track)
		track.build_world()
		check(track.is_world_ready(), "组合%d实际道路构建" % combination)
		if not track.is_world_ready(): track.free(); continue
		var field := Field.new()
		root.add_child(field)
		field.build(cfg, track)
		await physics_frame
		await physics_frame
		var worst_road := 0.0
		var misses := 0
		# 全圈左右轮迹/中心取射线，抓路面朝向和其它边坡侵入本段道路。
		for i in range(150):
			var arc := float(i)*track.road_length()/150.0
			for lateral in [-3.0, 0.0, 3.0]:
				var frame := track.surface_frame(arc, lateral)
				var query := PhysicsRayQueryParameters3D.create(frame.origin+Vector3.UP*20.0, frame.origin-Vector3.UP*2.0, 1)
				query.exclude = [field.get_node("ObstacleBody").get_rid()]
				var hit := track.get_world_3d().direct_space_state.intersect_ray(query)
				if hit.is_empty(): misses += 1
				else: worst_road = maxf(worst_road, absf(Vector3(hit.position).y-frame.origin.y))
		check(misses == 0 and worst_road < 0.04, "组合%d全圈450条真实道路碰撞射线，误差%.4fm 漏%d" % [combination, worst_road, misses])
		var consistent := true
		var body: Node = field.get_node("ObstacleBody")
		for i in range(body.get_child_count()):
			var collision := body.get_child(i) as CollisionShape3D
			var visual := field.get_child(i+1) as MeshInstance3D
			consistent = consistent and collision.transform.is_equal_approx(visual.transform)
		check(consistent and body.get_child_count() == 2, "组合%d两障碍碰撞与视觉完全同变换" % combination)
		var report := Elevation.measure(track.get("_curve"))
		check(report.max_grade <= 0.08 and report.max_height <= 16.01 and report.max_height >= 5.99,
			"组合%d实际高度与硬坡度" % combination)
		check(track.has_method("scenery_ground_point"), "组合%d路边主题物应贴到边坡，不悬空" % combination)
		if track.has_method("scenery_ground_point"):
			var p: Vector3 = track.scenery_ground_point(track.road_length()*0.3, 16.0)
			var query := PhysicsRayQueryParameters3D.create(p+Vector3.UP*20.0, p-Vector3.UP*2.0, 1)
			query.exclude = [field.get_node("ObstacleBody").get_rid()]
			var hit := track.get_world_3d().direct_space_state.intersect_ray(query)
			check(not hit.is_empty() and absf(Vector3(hit.position).y-p.y) < 0.04, "组合%d主题物基部与真实边坡相交" % combination)
		records.append({"combination": combination, "summary": variant.summary,
			"max_grade": report.max_grade, "max_height": report.max_height,
			"road_ray_misses": misses, "road_height_error": worst_road})
		field.free()
		track.free()
		await process_frame
	# 预检折线允许但五次平顺后超8%的剖面，必须由最终曲线硬门拒绝。
	var bad := base.duplicate()
	bad.elevation_profile = "0:0, 0.10:0, 0.18:16, 0.50:0, 1:0"
	var rejected := Track.new()
	rejected.level_config = bad
	root.add_child(rejected)
	rejected.build_world()
	check(not rejected.is_world_ready() and rejected.build_error.contains("超过硬上限"), "最终坡度超限拒绝装配，无椭圆回退")
	rejected.free()
	if not output.is_empty(): FileAccess.open(output.path_join("variants-geometry.json"), FileAccess.WRITE).store_string(JSON.stringify(records, "  "))
	print("VARIANT_GEO_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
