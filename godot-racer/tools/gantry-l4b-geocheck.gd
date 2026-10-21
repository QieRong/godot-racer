extends SceneTree
## 【判据 · GANTRY-L4-001B】起点龙门架「整门零穿模」体检（先红 → 后绿）。
##
## 与上一版（GANTRY-L4-001 的 gantry-l4-geocheck.gd）的**唯一实质差别**：赛道从桩换成真的。
##   上一版 `_stub_track()` 里硬编码 `start_line_center := Vector3(12, 0.5, -30)`、
##   `road_lift := 0.02`，桩上**既没有护栏（rail_half_width() / rail_visual_thickness）
##   也没有地面节点** → 「护栏净距」「柱底贴地」这两条在桩赛道上根本验不了，会假绿。
##   本版一律用**真实第四关赛道**（实例化 track.tscn + 注入 level_4.tres），并且
##   路面 / 护栏 / 地面 / 空气墙的几何一律**现场实测**（读网格与碰撞体的顶点投到
##   起跑线局部系），**不靠属性名、不靠文档里登记的数字**。
##
## 判据清单（2026-10-21 用户批准更新 G7/G9，其余判据保留）：
##   G1  非第四关（索引 0）不产生任何门架节点
##   G2  第四关（索引 3）挂出门架
##   G3  车可及高度（< 3.0m）内，可见门架实体不进路面
##   G4  碰撞盒不进路面
##   G5  碰撞盒与「车可及高度上的柱身」同址同厚
##   G6  柱头落在柱身上（模型先天 0.135m 砌缝已补掉）
##   G7  门高 5.5m（2026-10-21 用户批准，替代旧 8~9m）
##   G8  门洞净高 ≥ 3.0m
##   G9  门架在真实起跑线沿前进方向 6m（2026-10-21 用户批准）
##   G10 护栏净距：底面低于护栏顶的**可见**门架网格，横向区间不得与护栏区间相交
##   G11 柱底贴地：柱身最低点与**实测地面顶**的高差 |Δ| ≤ 0.05m（悬空与埋土同判）
##   G12 逐对扫描：门架实体 × {路面, 护栏, 地面, 空气墙} 判相交
##       ⚠ 空气墙**没有视觉网格**（它只是一张 ConcavePolygonShape3D 碰撞面），横梁
##         从高处穿过它不构成视觉穿模 → 这一对只打印 INFO，**不判红**。
##   G13 首帧就位：G13a 门架场景走**编译期 preload**（运行时 load 数须为 0）
##                G13b 模块内 await 数 = 0
##                G13c 模块入树后**同帧**内门架节点已存在（说明是 _ready() 内建的）
##
## 运行：
##   godot --headless --path godot-racer --script res://tools/gantry-l4b-geocheck.gd
## 退出码：0 = 全绿；1 = 有判据失败；2 = 判据无法执行（环境没建起来）。

const CAR_SAFE_H := 3.0        # 车含翻车的可及高度
const GATE_NODE := "StartGantry"
const LEVEL_L4 := 3            # 第四关（0 起索引）
const NEAR_Z := 6.0            # 局部横断面：只取门架目标位置前后 ±6m
const NEAR_R := 25.0           # 水平半径：挡掉椭圆**对面**那一侧的几何（见 _near_extents）
const TOUCH := 0.001           # 相交死区（浮点噪声）
const GROUND_TOL := 0.05       # 柱底与地面顶允许的高差（悬空 / 埋土同判）
const BIG := 1.0e8
const APPROVED_HEIGHT_M := 5.5
const APPROVED_FORWARD_M := 6.0

var _fails: Array[String] = []
var _passes := 0
var _frame := 0
var _stage := 0
var _spawn_frame := -1

var _track: Node3D = null
var _cases: Array = []
var _env: Array = []           # 实测环境：[{name, lat_min, lat_max, y_min, y_max, visual, tol, n}]
var _rail: Array = []          # 护栏（视觉）两条侧带的实测区间
var _rail_top := 0.0           # 实测护栏顶面高度
var _ground_top := 0.0
var _ground_measured := false
var _road_half := 5.0
var _road_top := 0.02

var _origin := Vector3.ZERO    # 起跑线中心（赛道局部系的零点）
var _side := Vector3.RIGHT     # 横向单位向量
var _fwd := Vector3.FORWARD    # 赛道前进方向
## 被测模块路径。默认就是交付件；红跑时可以用 --gantry-src= 指向"改动前"的快照，
## 这样红绿两跑用的是**同一套判据**，被测代码不同 —— 不需要来回改交付文件。
var _src_path := "res://scripts/start_gantry.gd"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--gantry-src="):
			_src_path = a.split("=", true, 1)[1]
	print("GEO 被测模块：%s" % _src_path)
	var cfg: Resource = load("res://data/levels/level_4.tres")
	print("GEO 第四关 %s：road_width = %.2f（路面半宽 %.2f）"
		% [cfg.get("display_name"), float(cfg.get("road_width")), float(cfg.get("road_width")) * 0.5])
	print("GEO 判据版本 GANTRY-L4-001B：真实赛道 + 实测环境几何（路面/护栏/地面/空气墙）")


# ⚠ 必须分帧：`root.add_child()` 之后_ready 虽然同步，但**赛道生成**要花掉一整帧，
#   而门架模块必须在赛道就绪之后才能注入（start_line_* / road_width 已落定）。
func _process(_delta: float) -> bool:
	_frame += 1
	if _stage == 0:
		_build_track()
		_stage = 1
		return false
	if _stage == 1:
		if _frame > 900:
			print("GEO 超时：真实赛道始终未就绪，判据无法执行")
			quit(2)
			return true
		if _track == null or not bool(_track.call("is_world_ready")):
			return false
		print("GEO 真实赛道已就绪（第 %d 帧）" % _frame)
		if not _measure_env():
			print("GEO 环境几何实测失败，判据无法执行")
			quit(2)
			return true
		_spawn(0)
		_spawn(LEVEL_L4)
		_spawn_frame = _frame
		_stage = 2
		return false
	if _stage == 2:
		if _frame < _spawn_frame + 2:
			return false
		_check_source()
		for c in _cases:
			_check(int(c["level"]), c["module"] as Node3D)
		print("GEO 汇总：PASS=%d FAIL=%d" % [_passes, _fails.size()])
		for f in _fails:
			print("  FAIL %s" % f)
		quit(1 if _fails.size() > 0 else 0)
		return true
	return false


# ---------------------------------------------------------------- 真实赛道
func _build_track() -> void:
	var cfg: Resource = load("res://data/levels/level_4.tres")
	_track = load("res://scenes/track.tscn").instantiate()
	_track.name = "Track"
	# ⚠ 顺序不能反：track_generator 默认 `defer_build_to_owner = true`（等 main.gd 设完
	#   参数再 build_world），本夹具没有 main.gd，所以**入树前**先关开关 + 挂上
	#   level_config，让它在 _ready() 里自己 build_world()（build_world 内部还会再
	#   apply_to_track 一次，幂等）。
	_track.set("defer_build_to_owner", false)
	_track.set("level_config", cfg)
	if cfg != null and cfg.has_method("set_level_index"):
		cfg.call("set_level_index", 4)      # 地面贴图按索引拼约定路径，不设会退回 L1 草地绿
	root.add_child(_track)                   # ← _ready() → build_world()（同步完成）


# ---------------------------------------------------------------- 环境几何实测
## 把路面 / 护栏 / 地面 / 空气墙的**顶点**投到「起跑线局部系」：
##   lat = 到起跑线中心的横向距离（沿 side）· y = 世界高度 · z = 沿赛道方向。
## 只保留 |z| ≤ NEAR_Z 的顶点（起跑线附近的局部横断面）。
##
## ⚠ 为什么还要按 lat 的正负**分侧**：护栏 / 空气墙是左右两条带，合成一个
##   [-6.55, 6.55] 的区间会把中间 12.4m 的路面也算成「墙」，判据会假红。
##
## ⚠ 为什么还得再卡一个**水平半径**（只卡 |z| 是不够的）：|z| ≤ NEAR_Z 是一片
##   **无限长的**板（沿 lat 方向无限延伸），椭圆对面那一侧只要投影落在板上就会被
##   算进来 —— 实测第一版就是这么把路面量成 [-596.7, 5.0]、护栏量成 [-598.1, -6.2]。
func _near_extents(faces: PackedVector3Array, xf: Transform3D) -> Array:
	var out: Array = []
	for _i in range(2):
		out.append({"lat_min": BIG, "lat_max": -BIG, "y_min": BIG, "y_max": -BIG, "n": 0})
	for p in faces:
		var w: Vector3 = xf * p
		var rel := w - _origin
		if Vector2(rel.x, rel.z).length() > NEAR_R:
			continue
		if absf(rel.dot(_fwd)) > NEAR_Z:
			continue
		var lat := rel.dot(_side)
		var e: Dictionary = out[0] if lat >= 0.0 else out[1]
		e["lat_min"] = minf(float(e["lat_min"]), lat)
		e["lat_max"] = maxf(float(e["lat_max"]), lat)
		e["y_min"] = minf(float(e["y_min"]), w.y)
		e["y_max"] = maxf(float(e["y_max"]), w.y)
		e["n"] = int(e["n"]) + 1
	return out


func _find_mesh(parent: Node, name_part: String) -> MeshInstance3D:
	for m in parent.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi != null and mi.name.to_lower().contains(name_part.to_lower()):
			return mi
	return null


func _measure_env() -> bool:
	var c: Variant = _track.get("start_line_center")
	var f: Variant = _track.get("start_line_forward")
	if not (c is Vector3) or not (f is Vector3):
		push_warning("GEO 真实赛道缺 start_line_center / start_line_forward")
		return false
	_origin = c
	_fwd = f
	_fwd.y = 0.0
	if _fwd.length() < 0.001:
		_fwd = Vector3.FORWARD
	_fwd = _fwd.normalized()
	# 环境采样随获批门架位置前移，检查实际摆放处，不能继续只量旧起跑线。
	_origin += _fwd * APPROVED_FORWARD_M
	_side = Vector3(_fwd.z, 0.0, -_fwd.x)
	_road_half = float(_track.get("road_width")) * 0.5
	_road_top = float(_track.get("road_lift"))
	print("GEO 门架目标 %s · 前进 %s · 横向 %s · 路面半宽 %.3f · 路面顶 y=%.3f"
		% [_v(_origin), _v(_fwd), _v(_side), _road_half, _road_top])

	_env = []
	# ---- 地面：用网格 AABB 的顶面（一整块 BoxMesh，轴对齐，变换后取 end.y 即真值）----
	var gm := _find_mesh(_track, "ground")
	if gm == null:
		push_warning("GEO 找不到地面网格（Ground*），G11 无法实测")
		_ground_measured = false
	else:
		var box: AABB = gm.global_transform * gm.get_aabb()
		_ground_top = box.end.y
		_ground_measured = true
		print("GEO 实测地面顶 y = %.4f（节点 %s，AABB %s）" % [_ground_top, gm.name, _aabb(box)])
	_env.append({"name": "地面", "lat_min": -BIG, "lat_max": BIG, "y_min": -BIG,
		"y_max": _ground_top, "visual": true, "tol": GROUND_TOL, "n": 0})

	# ---- 路面 ----
	var rm := _find_mesh(_track, "road")
	if rm == null or rm.mesh == null:
		push_warning("GEO 找不到路面网格（RoadMesh）")
		return false
	var r2 := _near_extents(rm.mesh.get_faces(), rm.global_transform)
	var road := _merge(r2)
	if int(road["n"]) == 0:
		push_warning("GEO 路面在起跑线 ±%.0fm 内没有顶点" % NEAR_Z)
		return false
	_env.append({"name": "路面", "lat_min": road["lat_min"], "lat_max": road["lat_max"],
		"y_min": road["y_min"], "y_max": road["y_max"], "visual": true, "tol": TOUCH,
		"n": road["n"]})

	# ---- 护栏（视觉）：左右两条带 ----
	var gr := _find_mesh(_track, "guardrail")
	if gr == null or gr.mesh == null:
		push_warning("GEO 找不到护栏网格（Guardrails）")
		return false
	_rail = _near_extents(gr.mesh.get_faces(), gr.global_transform)
	_rail_top = maxf(float(_rail[0]["y_max"]), float(_rail[1]["y_max"]))
	for i in range(2):
		var e: Dictionary = _rail[i]
		if int(e["n"]) == 0:
			continue
		_env.append({"name": "护栏(%s侧)" % ("+" if i == 0 else "-"), "lat_min": e["lat_min"],
			"lat_max": e["lat_max"], "y_min": e["y_min"], "y_max": e["y_max"],
			"visual": true, "tol": TOUCH, "n": e["n"]})

	# ---- 空气墙：只有碰撞面（ConcavePolygonShape3D），**没有视觉网格** ----
	var walls := _track.find_children("AirWall", "StaticBody3D", true, false)
	for b in walls:
		for cs in (b as Node).find_children("*", "CollisionShape3D", true, false):
			var shape := (cs as CollisionShape3D).shape as ConcavePolygonShape3D
			if shape == null:
				continue
			var w2 := _near_extents(shape.get_faces(), (b as Node3D).global_transform)
			for i in range(2):
				var e2: Dictionary = w2[i]
				if int(e2["n"]) == 0:
					continue
				_env.append({"name": "空气墙(%s侧)" % ("+" if i == 0 else "-"),
					"lat_min": e2["lat_min"], "lat_max": e2["lat_max"],
					"y_min": e2["y_min"], "y_max": e2["y_max"], "visual": false,
					"tol": TOUCH, "n": e2["n"]})

	print("GEO 实测环境几何（起跑线 ±%.0fm 局部横断面）：" % NEAR_Z)
	for e3 in _env:
		var d: Dictionary = e3
		print("   %-12s 横向 [%8.3f, %8.3f]  竖向 [%7.3f, %7.3f]  顶点 %d  视觉=%s"
			% [d["name"], float(d["lat_min"]), float(d["lat_max"]),
				float(d["y_min"]), float(d["y_max"]), int(d["n"]), d["visual"]])
	# 与赛道**属性口径**交叉核对（属性是唯一真相源，实测是摆出来的事实，两者必须一致）
	if _track.has_method("rail_half_width"):
		var rh := float(_track.call("rail_half_width"))
		var rt: Variant = _track.get("rail_visual_thickness")
		var th := float(rt) if rt != null else 0.35
		print("GEO 交叉核对：rail_half_width()=%.3f + rail_visual_thickness=%.3f = %.3f"
			% [rh, th, rh + th])
		print("GEO 交叉核对：实测护栏带 横向 [%8.3f, %8.3f] / [%8.3f, %8.3f]，顶 y=%.3f"
			% [float(_rail[0]["lat_min"]), float(_rail[0]["lat_max"]),
				float(_rail[1]["lat_min"]), float(_rail[1]["lat_max"]), _rail_top])
	return true


func _merge(sides: Array) -> Dictionary:
	var out := {"lat_min": BIG, "lat_max": -BIG, "y_min": BIG, "y_max": -BIG, "n": 0}
	for e in sides:
		var d: Dictionary = e
		if int(d["n"]) == 0:
			continue
		out["lat_min"] = minf(float(out["lat_min"]), float(d["lat_min"]))
		out["lat_max"] = maxf(float(out["lat_max"]), float(d["lat_max"]))
		out["y_min"] = minf(float(out["y_min"]), float(d["y_min"]))
		out["y_max"] = maxf(float(out["y_max"]), float(d["y_max"]))
		out["n"] = int(out["n"]) + int(d["n"])
	return out


# ---------------------------------------------------------------- 摆门
func _spawn(level_index: int) -> void:
	var mod: Node3D = load(_src_path).new()
	mod.name = "GantryMod%d" % level_index
	var c := Callable(mod, "setup")
	if c.get_argument_count() >= 2:
		c.call(_track, level_index)
	else:
		c.call(_track)
	root.add_child(mod)
	if level_index == LEVEL_L4:
		# G13c：add_child 返回后**同帧**内门架节点必须已经存在 —— 说明它是在 _ready()
		# 里建完的，而不是"再等一帧才冒出来"（用户报的"进来后闪一下的出现"）。
		_ok(mod.get_node_or_null(GATE_NODE) != null,
			"G13c 门架在模块入树后首帧即存在（_ready 内完成构建，节点名 %s）" % GATE_NODE)
	_cases.append({"level": level_index, "module": mod})


# ---------------------------------------------------------------- 判据
func _check(level_index: int, mod: Node3D) -> void:
	var tag := "L%d(idx=%d)" % [level_index + 1, level_index]
	var gate: Node3D = mod.get_node_or_null(GATE_NODE)
	var meshes: Array = mod.find_children("*", "MeshInstance3D", true, false)
	var bodies: Array = mod.find_children("*", "StaticBody3D", true, false)
	print("GEO %s gate=%s mesh=%d staticbody=%d" % [tag, gate != null, meshes.size(), bodies.size()])
	if level_index != LEVEL_L4:
		_ok(meshes.size() == 0 and bodies.size() == 0,
			"G1 非第四关不产生门架（mesh=%d 碰撞体=%d，均须 0）" % [meshes.size(), bodies.size()])
		return
	_ok(gate != null and meshes.size() > 0, "G2 第四关必须挂出门架（mesh=%d）" % meshes.size())
	if gate == null:
		return
	var side := _side_of(gate)
	var origin: Vector3 = gate.global_position
	# ---- 门架全部**可见**网格的实测区间（局部系：lat × y）----
	var parts: Array = []
	for m in meshes:
		var mi := m as MeshInstance3D
		if not mi.visible:
			continue
		parts.append(_extent(mi, side, origin))
	var top := -BIG
	var lintel_bottom := BIG
	for p in parts:
		var d: Dictionary = p
		top = maxf(top, float(d["y_max"]))
		if str(d["name"]).begins_with("lintel"):
			lintel_bottom = minf(lintel_bottom, float(d["y_min"]))
	# G9 用户批准的新位置：起跑线前方 6m；左右及高度仍来自真实赛道。
	var want: Vector3 = (_track.get("start_line_center") as Vector3) \
		+ Vector3.UP * float(_track.get("road_lift")) + _fwd * APPROVED_FORWARD_M
	_ok(origin.is_equal_approx(want),
		"G9 门架在真实起跑线前方 6m（原点 %s，应为 %s）" % [_v(origin), _v(want)])
	# G3 车可及高度内不进路面
	var worst_in := 0.0
	var worst_name := ""
	for p in parts:
		var d: Dictionary = p
		if float(d["y_min"]) >= CAR_SAFE_H:
			continue
		var into := _into_road(d, _road_half)
		if into > worst_in:
			worst_in = into
			worst_name = d["name"]
	_ok(worst_in <= TOUCH, "G3 车可及高度内无门架实体进路面（路面半宽 %.3f；最深 %s，深入 %.3f）"
		% [_road_half, worst_name if worst_name != "" else "无", worst_in])
	# G4 / G5 碰撞
	var box_min := BIG
	var box_max := -BIG
	var worst_box := 0.0
	var worst_box_name := ""
	for b in bodies:
		var e := _body_extent(b as StaticBody3D, side, origin)
		box_min = minf(box_min, float(e["lat_min"]))
		box_max = maxf(box_max, float(e["lat_max"]))
		var into := _into_road(e, _road_half)
		if into > worst_box:
			worst_box = into
			worst_box_name = (b as StaticBody3D).name
	if bodies.is_empty():
		_ok(false, "G4 第四关门架立柱必须带碰撞体（实测 0 个）")
	else:
		_ok(worst_box <= TOUCH, "G4 碰撞盒不进路面（%s 最深深入 %.3f，须 0）"
			% [worst_box_name if worst_box_name != "" else "无", worst_box])
	# G10：护栏净距（用**实测护栏带**，不是文档登记值）
	var worst_rail := 0.0
	var worst_rail_name := ""
	for p in parts:
		var d: Dictionary = p
		if float(d["y_min"]) >= _rail_top:
			continue        # 横梁在高处，本来就要从护栏顶上跨过去
		for r in _rail:
			var rd: Dictionary = r
			if int(rd["n"]) == 0:
				continue
			var ov := _overlap_lat(d, rd)
			if ov > worst_rail:
				worst_rail = ov
				worst_rail_name = d["name"]
	_ok(worst_rail <= TOUCH, "G10 护栏净距：底面低于护栏顶 %.3f 的门架网格不压护栏（最深重叠 %s %.3fm）"
		% [_rail_top, worst_rail_name if worst_rail_name != "" else "无", worst_rail])
	# G12：逐对扫描（路面 / 护栏 / 地面 / 空气墙）
	for e4 in _env:
		var env: Dictionary = e4
		var worst := 0.0
		var who := ""
		for p in parts:
			var d2: Dictionary = p
			var ov2 := _overlap2(d2, env)
			if ov2 > worst:
				worst = ov2
				who = d2["name"]
		if bool(env["visual"]):
			_ok(worst <= float(env["tol"]),
				"G12 门架 × %s：不相交（最深 %s %.3fm，阈值 %.3f）"
				% [env["name"], who if who != "" else "无", worst, float(env["tol"])])
		else:
			# ⚠ 空气墙没有视觉网格，只有一张碰撞面：横梁从高处穿过它是**物理**相交、
			#   **视觉**上什么也没有 → 不算穿模，这一对只登记，不判红。
			print("  INFO G12 门架 × %s：相交 %.3fm（%s）—— 空气墙无视觉网格，"
				% [env["name"], worst, who if who != "" else "无"]
				+ "高处横梁穿过它不构成视觉穿模，本对只登记不判红")
	var vis_min := BIG
	var vis_max := -BIG
	for p in parts:
		var d: Dictionary = p
		if float(d["y_min"]) >= CAR_SAFE_H:
			continue
		vis_min = minf(vis_min, float(d["lat_min"]))
		vis_max = maxf(vis_max, float(d["lat_max"]))
	if vis_min < BIG * 0.5:
		var vc := (vis_min + vis_max) * 0.5
		var vt := vis_max - vis_min
		var bc := (box_min + box_max) * 0.5
		var bt := box_max - box_min
		_ok(absf(bc - vc) <= 0.15 and bt >= vt - 0.05 and bt <= vt + 0.40,
			"G5 碰撞与视觉同址同厚（视觉中心 %.3f/厚 %.3f vs 碰撞中心 %.3f/厚 %.3f）"
			% [vc, vt, bc, bt])
	# G6 柱身→柱头缝
	var shaft_top := -BIG
	var cap_bottom := BIG
	for p in parts:
		var d: Dictionary = p
		var n := str(d["name"])
		if n.begins_with("masonry"):
			shaft_top = maxf(shaft_top, float(d["y_max"]))
		elif n.begins_with("capital"):
			cap_bottom = minf(cap_bottom, float(d["y_min"]))
	if shaft_top < -BIG * 0.5 or cap_bottom > BIG * 0.5:
		_ok(false, "G6 找不到柱身/柱头网格（masonry/capital），判据无法执行")
	else:
		_ok(absf(cap_bottom - shaft_top) <= 0.02,
			"G6 柱头落在柱身上（柱身顶 %.3f vs 柱头底 %.3f，缝 %.3f ≤ 0.02）"
			% [shaft_top, cap_bottom, cap_bottom - shaft_top])
	# G7 / G8
	var height := top - origin.y
	_ok(absf(height - APPROVED_HEIGHT_M) <= 0.01,
		"G7 用户批准门高 5.5m（实测 %.3f，误差 ≤ 0.01m）" % height)
	_ok(lintel_bottom >= CAR_SAFE_H,
		"G8 门洞净高 ≥ %.1fm（实测横梁底面 %.3f）" % [CAR_SAFE_H, lintel_bottom])
	# G11 柱底贴地（实测地面顶）
	var lowest := BIG
	var low_name := ""
	for p in parts:
		var d: Dictionary = p
		if float(d["y_min"]) < lowest:
			lowest = float(d["y_min"])
			low_name = d["name"]
	if not _ground_measured:
		_ok(false, "G11 柱底贴地：地面高度未实测（找不到地面网格），判据无法执行")
	else:
		_ok(absf(lowest - _ground_top) <= GROUND_TOL,
			"G11 柱底贴地：门架最低点 %.3f（%s）vs 实测地面顶 %.3f，差 %+.3f（|Δ| ≤ %.2f）"
			% [lowest, low_name, _ground_top, lowest - _ground_top, GROUND_TOL])


# ---------------------------------------------------------------- G13 源码判据
func _check_source() -> void:
	var f := FileAccess.open(_src_path, FileAccess.READ)
	if f == null:
		_ok(false, "G13a 读不到 %s 源码，判据无法执行" % _src_path)
		return
	var raw := f.get_as_text()
	f.close()
	var code := _strip_comment_lines(raw)
	var n_pre := _count_ident(code, "preload", true)
	var n_load := _count_ident(code, "load", true)
	var n_await := _count_ident(code, "await", false)
	_ok(n_pre >= 1 and n_load == 0,
		"G13a 门架场景走编译期 preload（preload %d 处 / 运行时 load %d 处，须 ≥1 / 0）"
		% [n_pre, n_load])
	_ok(n_await == 0, "G13b 模块内 await = 0（实测 %d）" % n_await)


## 去掉**整行**注释后再数标识符：注释里提到旧写法（比如"运行时 load"）不该算数。
## 行尾的尾注释不剥（剥就要做字符串状态机），所以本项目的注释一律写在整行里。
func _strip_comment_lines(text: String) -> String:
	var keep: Array[String] = []
	for line in text.split("\n"):
		if not line.strip_edges().begins_with("#"):
			keep.append(line)
	return "\n".join(keep)


## 数"独立的"标识符出现次数：前一个字符不能是标识符字符或 `.`（否则 preload 里的
## load 会被算进去）。
func _count_ident(code: String, word: String, need_paren: bool) -> int:
	var n := 0
	var i := 0
	var w := word.length()
	while i < code.length():
		i = code.find(word, i)
		if i < 0:
			break
		var prev := "" if i == 0 else code.substr(i - 1, 1)
		var after := "" if i + w >= code.length() else code.substr(i + w, 1)
		var ok := not _is_ident_char(prev)
		if need_paren:
			ok = ok and after == "("
		else:
			ok = ok and (after == " " or after == "\t" or after == "\n" or after == "(")
		if ok:
			n += 1
		i += w
	return n


func _is_ident_char(c: String) -> bool:
	if c == "" or c == "_" or c == ".":
		return true
	return "0123456789".contains(c) or c.to_upper() != c.to_lower()


# ---------------------------------------------------------------- 几何工具
## 该实体**探进路面多少米**（0 = 完全在路面外）。必须判区间相交：
## 只比 lat_min 是错的（左侧柱 lat_min 是负的，一比就"侵入"）。
func _into_road(e: Dictionary, half: float) -> float:
	if float(e["lat_min"]) >= half or float(e["lat_max"]) <= -half:
		return 0.0
	return minf(half - float(e["lat_min"]), float(e["lat_max"]) + half)


func _overlap_lat(a: Dictionary, b: Dictionary) -> float:
	return minf(float(a["lat_max"]), float(b["lat_max"])) \
		- maxf(float(a["lat_min"]), float(b["lat_min"]))


## 二维（横向 × 竖向）区间相交的"最小重叠量"：任一维不交即为 0。
func _overlap2(a: Dictionary, b: Dictionary) -> float:
	var lo := maxf(float(a["lat_min"]), float(b["lat_min"]))
	var hi := minf(float(a["lat_max"]), float(b["lat_max"]))
	if hi - lo <= TOUCH:
		return 0.0
	var ylo := maxf(float(a["y_min"]), float(b["y_min"]))
	var yhi := minf(float(a["y_max"]), float(b["y_max"]))
	if yhi - ylo <= TOUCH:
		return 0.0
	return minf(hi - lo, yhi - ylo)


func _side_of(gate: Node3D) -> Vector3:
	return gate.global_transform.basis.x.normalized()


## ⚠ 必须变换**局部 AABB 的 8 个角**，不能 `global_transform * get_aabb()` 再取端点：
##   后者得到的是世界轴对齐包围盒，门架是绕 Y 旋转的，先包再取角会把盒子撑大
##   （实测把基础板横向从 6.57m 虚增到 7.22m），判据会失真。
func _extent(mi: MeshInstance3D, side: Vector3, origin: Vector3) -> Dictionary:
	var a: AABB = mi.get_aabb()
	var t: Transform3D = mi.global_transform
	var lat_min := BIG
	var lat_max := -BIG
	var y_min := BIG
	var y_max := -BIG
	# ⚠ lat 相对门架原点量（横向），y 必须是**世界绝对高度** —— 环境几何（路面/护栏/
	#   地面/空气墙）的 y 也是绝对的，两边口径必须一致，否则整套判据会差一个
	#   road_lift（0.02m）：柱底会被量成"贴地"而实际悬在路面顶上。
	for i in range(8):
		var w: Vector3 = t * a.get_endpoint(i)
		var lat := (w - origin).dot(side)
		lat_min = minf(lat_min, lat)
		lat_max = maxf(lat_max, lat)
		y_min = minf(y_min, w.y)
		y_max = maxf(y_max, w.y)
	return {"name": mi.name, "lat_min": lat_min, "lat_max": lat_max,
		"y_min": y_min, "y_max": y_max}


func _body_extent(b: StaticBody3D, side: Vector3, origin: Vector3) -> Dictionary:
	var out := {"lat_min": BIG, "lat_max": -BIG, "y_min": BIG, "y_max": -BIG}
	for s in b.find_children("*", "CollisionShape3D", true, false):
		var cs := s as CollisionShape3D
		var box := cs.shape as BoxShape3D
		if box == null:
			continue
		var t: Transform3D = b.global_transform * cs.transform
		for i in range(8):
			var w: Vector3 = t * (box.size * 0.5 * _sign_vec(i))
			var lat := (w - origin).dot(side)
			out["lat_min"] = minf(float(out["lat_min"]), lat)
			out["lat_max"] = maxf(float(out["lat_max"]), lat)
			out["y_min"] = minf(float(out["y_min"]), w.y)
			out["y_max"] = maxf(float(out["y_max"]), w.y)
	return out


func _sign_vec(i: int) -> Vector3:
	return Vector3(1.0 if (i & 1) == 0 else -1.0,
		1.0 if (i & 2) == 0 else -1.0,
		1.0 if (i & 4) == 0 else -1.0)


func _ok(cond: bool, text: String) -> void:
	if cond:
		_passes += 1
		print("  PASS %s" % text)
	else:
		_fails.append(text)
		print("  FAIL %s" % text)


func _v(p: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [p.x, p.y, p.z]


func _aabb(b: AABB) -> String:
	return "[%.2f %.2f %.2f] ~ [%.2f %.2f %.2f]" % [
		b.position.x, b.position.y, b.position.z, b.end.x, b.end.y, b.end.z]
