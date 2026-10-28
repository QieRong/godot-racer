extends SceneTree
const Variants := preload("res://scripts/race_variants.gd")
const Track := preload("res://scripts/track_generator.gd")
const Field := preload("res://scripts/obstacle_field.gd")
const Elevation := preload("res://scripts/track_elevation.gd")
var passed := 0
var failed := 0
var output := ""
var records: Array = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("FIVE_GEO_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	for level in range(1, 6):
		var base: Resource = load("res://data/levels/level_%d.tres" % level)
		base.set_level_index(level)
		var layouts: Array[String] = []
		for combination in range(9):
			var label := "L%d组合%d" % [level, combination]
			var variant := Variants.make(base, 12345, combination)
			check(variant.get("ok", false), label+"配置有效")
			if not variant.get("ok", false): continue
			var cfg: Resource = variant.config
			var track := Track.new()
			track.level_config = cfg
			root.add_child(track)
			track.build_world()
			check(track.is_world_ready(), label+"实际构建道路mesh/碰撞")
			if not track.is_world_ready(): track.free(); continue
			var field := Field.new()
			root.add_child(field)
			field.build(cfg, track)
			await physics_frame
			await physics_frame
			var body: StaticBody3D = field.get_node("ObstacleBody")
			var errors := 0.0
			var misses := 0
			for i in range(150):
				var arc := float(i)*track.road_length()/150.0
				for lateral in [-3.0, 0.0, 3.0]:
					var frame := track.surface_frame(arc, lateral)
					var query := PhysicsRayQueryParameters3D.create(frame.origin+Vector3.UP*20.0, frame.origin-Vector3.UP*2.0, 1)
					query.exclude = [body.get_rid()]
					var hit := track.get_world_3d().direct_space_state.intersect_ray(query)
					if hit.is_empty(): misses += 1
					else: errors = maxf(errors, absf(Vector3(hit.position).y-frame.origin.y))
			check(misses == 0 and errors < 0.04, label+"全圈450条真实道路射线，误差%.4fm/漏%d" % [errors, misses])
			var aligned: bool = body.get_child_count() == cfg.obstacle_count
			var clear := true
			for i in range(body.get_child_count()):
				var collision := body.get_child(i) as CollisionShape3D
				var visual := field.get_child(i+1) as MeshInstance3D
				aligned = aligned and collision.transform.is_equal_approx(visual.transform)
				var obstacle: Dictionary = field.obstacles[i]
				var surface := track.surface_frame(float(obstacle.arc), float(obstacle.lateral))
				var box := collision.shape as BoxShape3D
				var bottom := collision.position-collision.basis.y*box.size.y*0.5
				aligned = aligned and bottom.distance_to(surface.origin) < 0.005
				var free_width := track.road_half_width()+absf(float(obstacle.lateral))-float(obstacle.half_width)
				clear = clear and free_width >= Field.CAR_WIDTH+Field.PASS_EXTRA
				clear = clear and float(obstacle.arc) > 100.0 and track.road_length()-float(obstacle.arc) > 100.0
			check(aligned, label+"全部障碍视觉/碰撞同变换且底面贴实际坡道")
			check(clear and field.dynamic_count() == 0, label+"起终点净空与最小通行宽度保留")
			var report := Elevation.measure(track.get("_curve"))
			check(report.min_height >= -0.001 and report.max_height >= 5.99 and report.max_height <= 16.001
				and report.max_grade > 0.005 and report.max_grade <= 0.08, label+"实际高差%.2fm/最大坡度%.2f%%" % [report.max_height, report.max_grade*100.0])
			check(track.get_node_or_null("ElevationVergeBody") != null and track.get_node_or_null("ElevationVerges") != null,
				label+"道路两侧真实边坡已生成")
			var layout_key := JSON.stringify(field.obstacles)
			if combination < 3:
				check(not layouts.has(layout_key), label+"实际障碍坐标随布局种子变化")
				layouts.append(layout_key)
			records.append({"level": level, "combination": combination, "summary": variant.summary,
				"max_grade": report.max_grade, "max_height": report.max_height, "road_ray_misses": misses,
				"road_height_error": errors, "obstacle_aligned": aligned, "passage_clear": clear})
			field.free()
			track.free()
			await process_frame
	if not output.is_empty():
		FileAccess.open(output.path_join("five-geometry.json"), FileAccess.WRITE).store_string(JSON.stringify(records, "  "))
	print("FIVE_GEO_COMPLETE PASS=%d FAIL=%d COMBINATIONS=%d" % [passed, failed, records.size()])
	quit(0 if failed == 0 and records.size() == 45 else 1)
