extends SceneTree
const Layout := preload("res://scripts/track_layout.gd")
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
	print("FIVE_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	var layouts: Array[String] = []
	var records: Array = []
	for level in range(1, 6):
		var cfg: Resource = load("res://data/levels/level_%d.tres" % level)
		check(not cfg.layout.contains("ellipse") and not layouts.has(cfg.layout), "L%d 独立真实来源分段路线" % level)
		layouts.append(cfg.layout)
		check(cfg.strict_layout and cfg.closure_mode == "solve", "L%d 完整闭环且失败拒绝发车" % level)
		check(cfg.s_curve_amplitude == 0 and cfg.dynamic_obstacle_count == 0, "L%d 固定平面固定障碍" % level)
		var result: Dictionary = Layout.build(cfg.layout, cfg.closure_mode, 2.0, cfg.road_width * 0.5 + 1.0)
		check(result.get("ok", false), "L%d 构建成功 %s" % [level, str(result.get("error", ""))])
		if not result.get("ok", false): continue
		var points: PackedVector3Array = result.points
		var planar := true
		for point in points:
			if absf(point.y) > 0.001: planar = false
		check(planar and result.min_radius >= cfg.min_corner_radius, "L%d 平面与最小半径" % level)
		check(result.closure_gap < 0.01, "L%d 实际闭环残差小于1cm" % level)
		records.append({"level": level, "length": result.length, "min_radius": result.min_radius,
			"closure_gap": result.closure_gap, "points": points.size(), "laps": cfg.laps_to_finish})
	if not output.is_empty():
		FileAccess.open(output.path_join("five-geometry.json"), FileAccess.WRITE).store_string(JSON.stringify(records, "  "))
	print("FIVE_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
