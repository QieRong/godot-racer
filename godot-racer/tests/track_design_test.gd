extends SceneTree
## 捕捉：旧椭圆冒充新路线；坏布局回退；异常短曲线仍生成世界。
const Layout := preload("res://scripts/track_layout.gd")
const Track := preload("res://scripts/track_generator.gd")
var passed := 0
var failed := 0
var output := ""

class ShortTrack extends "res://scripts/track_generator.gd":
	func _build_curve_from_layout() -> Curve3D:
		var c := Curve3D.new()
		c.add_point(Vector3.ZERO)
		c.add_point(Vector3.RIGHT)
		return c

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, description: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("TRACK_DESIGN_ASSERT %s %s" % ["PASS" if ok else "FAIL", description])

func run() -> void:
	var cfg: Resource = load("res://data/levels/level_2.tres")
	var parsed: Dictionary = Layout.parse(cfg.layout)
	check(parsed.ok and not parsed.has_ellipse and cfg.closure_mode == "solve", "完整路段序列，拒绝椭圆及半圈对称")
	var left := 0
	var right := 0
	var turns: Array = []
	if parsed.ok:
		for seg in parsed.segments:
			var angle: float = seg.angle_deg
			if angle > 0.0: left += 1
			if angle < 0.0: right += 1
			if angle != 0.0: turns.append(signf(angle))
	check(left >= 3 and right >= 5 and turns.size() >= 8, "真实参考的八弯节奏，含两组左右组合")
	var result: Dictionary = Layout.build(cfg.layout, cfg.closure_mode, 2.0, 9.2)
	check(result.ok, "现行闭环、曲率和护栏判据通过")
	if result.ok:
		check(result.length >= 2700.0 and result.length <= 3300.0, "实际 Curve3D 长度 2700—3300m")
		check(result.min_radius >= 40.0, "最终曲线最小半径至少40m")
		var c: Curve3D = Layout.make_curve(result.points, true, 0.5)
		var points: Array = []
		var planar := true
		for i in range(int(c.get_baked_length()) + 1):
			var q := c.sample_baked(float(i))
			points.append([q.x, q.y, q.z])
			planar = planar and absf(q.y) < 0.001
		check(planar, "001 高度恒0，无坡度")
		var dump := result.duplicate()
		dump.erase("points")
		dump["centerline_1m"] = points
		dump["layout"] = cfg.layout
		FileAccess.open(output.path_join("geometry.json"), FileAccess.WRITE).store_string(JSON.stringify(dump, "\t"))
	for bad in ["", "bogus:1", "straight:50, arc:60:90", "straight:40, arc:60:360", "ellipse:0:5"]:
		var t: Node3D = Track.new()
		t.set("strict_layout", true)
		t.layout = bad
		var curve: Curve3D = t.call("_build_curve")
		check(curve == null, "严格布局拒绝缺失/非法构建，绝不返回旧椭圆：" + bad)
		t.free()
	var short_track := ShortTrack.new()
	short_track.set("strict_layout", true)
	short_track.layout = "straight:1"
	root.add_child(short_track)
	short_track.build_world()
	check(not short_track.is_world_ready() and short_track.get_node_or_null("RoadBody") == null,
		"异常短曲线不能生成世界或开放发车")
	short_track.free()
	var legacy := Track.new()
	legacy.layout = ""
	var old: Curve3D = legacy.call("_build_curve")
	check(old != null and old.get_baked_length() > 100.0, "其他旧关卡默认兼容路径保留")
	legacy.free()
	print("TRACK_DESIGN_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
