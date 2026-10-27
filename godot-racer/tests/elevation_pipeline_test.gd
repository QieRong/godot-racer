extends SceneTree
const Layout := preload("res://scripts/track_layout.gd")
const Track := preload("res://scripts/track_generator.gd")
const Field := preload("res://scripts/obstacle_field.gd")
const PROFILE := "0:0, 0.08:0, 0.30:16, 0.56:0, 0.78:8, 0.92:0, 1:0"
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("ELEV_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	# 若恢复400m虚构长度的预检，这个合法长坡会被误拒。
	var parse_args: Array = [PROFILE, 0.08]
	var layout_script: GDScript = load("res://scripts/track_layout.gd")
	for method in layout_script.get_script_method_list():
		if method.name == "parse_elevation" and method.args.size() >= 3: parse_args.append(2970.0)
	var parsed: Dictionary = layout_script.callv("parse_elevation", parse_args)
	check(parsed.ok, "16m长坡按真实2970m长度准入，最终曲线另判坡度")
	check(not Layout.parse_elevation("0:0, 0.5:16, 1:1", 0.08).ok, "首尾异高仍拒绝")
	var cfg: Resource = load("res://data/levels/level_2.tres").duplicate()
	var has_profile := false
	for prop in cfg.get_property_list():
		if prop.name == "elevation_profile": has_profile = true
	check(has_profile, "关卡高度剖面能够传入真实生成器")
	if has_profile:
		cfg.set("elevation_profile", PROFILE)
		cfg.set("max_grade", 0.08)
	var track := Track.new()
	track.level_config = cfg
	root.add_child(track)
	track.build_world()
	check(track.is_world_ready(), "L2坡道实际装配")
	var highest := -INF
	var peak_arc := 0.0
	var max_grade := 0.0
	for i in range(int(track.road_length())):
		var a: Vector3 = track.centerline_point(float(i))
		var b: Vector3 = track.centerline_point(float(i) + 1.0)
		if a.y > highest:
			highest = a.y
			peak_arc = float(i)
		var horizontal := Vector2(b.x-a.x, b.z-a.z).length()
		if horizontal > 0.001: max_grade = maxf(max_grade, absf(b.y-a.y) / horizontal)
	check(highest > 15.95 and highest <= 16.01, "最终道路确实升至16m，而非仅解析文本")
	check(max_grade > 0.02 and max_grade <= 0.08, "最终曲线按水平距离量坡且不超过8%")
	var field := Field.new()
	root.add_child(field)
	cfg.obstacle_count = 1
	field.build(cfg, track)
	# 使用真正赛道的高处，抓住静态障碍把pos.y丢弃的错误。
	field._place_static(peak_arc, 0.0, 0.75, "barrier", RandomNumberGenerator.new())
	var cs := field.get_node("ObstacleBody").get_child(1) as CollisionShape3D
	var visual := field.get_child(field.get_child_count()-1) as MeshInstance3D
	check(absf(cs.position.y - (highest + 1.1 + track.road_lift)) < 0.03, "坡顶障碍碰撞底面贴合路面")
	check(cs.transform.is_equal_approx(visual.transform), "障碍视觉与碰撞共用同一变换")
	await physics_frame
	await physics_frame
	var summit: Vector3 = track.centerline_point(peak_arc)
	var query := PhysicsRayQueryParameters3D.create(summit + Vector3.UP*3.0, summit - Vector3.UP*2.0, 1)
	query.exclude = [field.get_node("ObstacleBody").get_rid()]
	var hit := track.get_world_3d().direct_space_state.intersect_ray(query)
	print("ELEV_RAY highest=%.5f summit=%s hit=%s" % [highest, summit, hit])
	var reverse := PhysicsRayQueryParameters3D.create(summit-Vector3.UP*2.0, summit+Vector3.UP*3.0, 1)
	reverse.exclude = query.exclude
	print("ELEV_REVERSE_RAY %s" % track.get_world_3d().direct_space_state.intersect_ray(reverse))
	check(not hit.is_empty() and absf(Vector3(hit.get("position", Vector3.ZERO)).y - highest - track.road_lift) < 0.03,
		"坡顶真实道路碰撞与中心线同高")
	field.free()
	track.free()
	var planar := Layout.build(cfg.layout, cfg.closure_mode, 2.0, 9.2)
	var curve := Layout.make_curve(planar.points, true)
	var elevation: GDScript = load("res://scripts/track_elevation.gd")
	check(not elevation.call("apply", curve, PROFILE.replace(":16", ":20"), 0.08).ok, "本版高度超过16m明确拒绝")
	check(not elevation.call("apply", curve, "0:0, 0.3:-1, 0.6:0, 1:0", 0.08).ok, "本版不生成被零高度地面遮住的负高度路面")
	print("ELEV_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
