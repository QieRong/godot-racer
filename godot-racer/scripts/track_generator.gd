extends Node3D
## 环形赛道生成器 —— 用 Curve3D 程序化生成闭合赛道
##
## 为什么用代码生成而不是手摆节点：
##   1. 想改赛道形状只改一圈控制点，不用重新拖几百个节点
##   2. 路面网格、碰撞体、护栏、检查点、发车位**全部从同一条曲线导出**，
##      永远不会出现"护栏和路面错位""检查点不在赛道上"这类问题
##   3. 这是 Godot 里最接近"一条数据源驱动整条赛道"的做法
##
## 参考：kuba--/f1 的模块化路段拼装思路 + KenneyNL/Starter-Kit-Racing 的
## track-straight/corner 模块化设计。这里用曲线参数化代替拼模块，改形更方便。

@export_group("赛道形状")
## 赛道宽度（米）
@export var road_width := 14.0
## 隔多远采样一个点（米）。越小越平滑，但三角形更多
@export var sample_step := 2.0
## 路面抬离地面多少，避免与地面 Z-fighting
@export var road_lift := 0.02

@export_group("护栏")
@export var add_guardrails := true
## 护栏**视觉**高度。1.1m 时高速赛车会骑上墙卡死，所以给到 1.8m
@export var rail_height := 1.8
@export var rail_thickness := 0.4
## 护栏比路面外沿再往外放多少
@export var rail_offset := 1.2

@export_group("隐形空气墙")
## 是否在护栏上方加高碰撞体（车翻不过去、飞不出去）
@export var add_air_wall := true
## 空气墙碰撞高度。远高于视觉护栏，形成一圈外围笼子。
## 12m 的依据：平路上车要翻过墙需要约 15m/s 的垂直初速度，而本赛道没有跳台，
## 实际不可能达到。所以只靠"高墙"就能防翻越，不需要顶盖。
@export var air_wall_height := 12.0
## 空气墙是否加顶盖。
## 默认关闭：一是高墙已足够，二是 12m 高的顶盖会挡住相机视线、把天空盖掉。
## 只有当赛道存在跳台、车可能被弹飞时才需要打开。
@export var air_wall_ceiling := false

@export_group("检查点")
## 沿赛道摆几个检查点（不含起终点）
@export var checkpoint_count := 3
## 起终点线放在曲线的哪个位置（0~1）
@export var start_finish_t := 0.0
## 起终点线沿赛道方向的**厚度**（米）。
## 它不是一个"面"，而是一块横跨路面的长方形贴片，所以车必须停在它的后边缘之后。
@export var start_line_depth := 1.6

var _curve: Curve3D
var _road_mesh: ArrayMesh
var _road_length := 0.0
## 赛道中心线到原点的最大距离，用于自动决定地面尺寸
var _curve_max_extent := 0.0
## 起终点线的世界位置与赛道前进方向（供赛车出生点计算"车尾在线的后面"）
var start_line_center := Vector3.ZERO
var start_line_forward := Vector3.FORWARD

const ROAD_MAT_ALBEDO := Color(0.16, 0.16, 0.18)
const RAIL_MAT_ALBEDO := Color(0.85, 0.15, 0.12)
const START_LINE_ALBEDO := Color(0.92, 0.92, 0.92)


func _ready() -> void:
	_curve = _build_curve()
	_road_length = _curve.get_baked_length()
	print("[赛道] 曲线长度 = %.1f m，采样步长 %.1f m -> 约 %d 个断面"
		% [_road_length, sample_step, int(_road_length / sample_step)])

	_build_road()
	_build_ground()
	if add_guardrails:
		_build_guardrails()
	_build_start_line()
	_build_checkpoints()
	print("[赛道] 生成完成")


## 赛道中心线：用椭圆参数方程生成**连续曲率**的环形赛道。
##
## 为什么不用"直线+圆角矩形"（我前两版的做法）：
##   那种形状在直线与圆弧的接点处曲率突变，车辆高速通过时会被弹飞 ——
##   实测车在接点处 y 从 -0.06 瞬间跳到 +0.79（整车腾空）后失控。
##   椭圆的曲率处处连续，是最宽容的赛道形状，适合新手车与新手玩家。
## 想改大小，只改下面两个半轴。曲线首尾自动相接。
const TRACK_RADIUS_X := 320.0
const TRACK_RADIUS_Z := 200.0
const TRACK_SEGMENTS := 64

func _build_curve() -> Curve3D:
	var c := Curve3D.new()
	for i in range(TRACK_SEGMENTS):
		var a := TAU * float(i) / float(TRACK_SEGMENTS)
		c.add_point(Vector3(cos(a) * TRACK_RADIUS_X, 0.0, sin(a) * TRACK_RADIUS_Z))
	_curve_max_extent = maxf(TRACK_RADIUS_X, TRACK_RADIUS_Z)
	return c


## 取曲线上某个弧长处的点（自动环绕，保证闭合处不断裂）
func _sample_at(distance: float) -> Vector3:
	var d := fposmod(distance, _road_length)
	return _curve.sample_baked(d)


## 沿曲线扫出路面网格（首尾相接成闭合环）
func _build_road() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var steps := int(_road_length / sample_step)
	var half := road_width * 0.5
	var ring: Array = []

	for i in range(steps):
		var d := float(i) / float(steps) * _road_length
		var pos := _sample_at(d)
		var ahead := _sample_at(d + 0.5)
		var fwd := (ahead - pos)
		fwd.y = 0.0
		fwd = fwd.normalized()
		# 路面横向 = 前进方向右转 90°
		var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
		ring.append({
			"l": pos - side * half + Vector3.UP * road_lift,
			"r": pos + side * half + Vector3.UP * road_lift,
		})

	# 三角形条带，最后一环接回第一环 -> 闭合赛道
	for i in range(ring.size()):
		var a: Dictionary = ring[i]
		var b: Dictionary = ring[(i + 1) % ring.size()]
		_tri(st, a["l"], b["l"], b["r"], float(i), float(i + 1))
		_tri(st, a["l"], b["r"], a["r"], float(i), float(i + 1))

	st.generate_normals()
	st.generate_tangents()
	_road_mesh = st.commit()

	var mi := MeshInstance3D.new()
	mi.name = "RoadMesh"
	mi.mesh = _road_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ROAD_MAT_ALBEDO
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	add_child(mi)

	# 路面碰撞体：ConcavePolygonShape3D。
	# 注意：高面数 trimesh 会让 VehicleBody3D 严重掉帧（官方 issue #52888），
	# 所以采样步长别调太小。默认 2m -> 约 578 个三角面，够用。
	var body := StaticBody3D.new()
	body.name = "RoadBody"
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	shape.name = "RoadShape"
	var faces := PackedVector3Array()
	for i in range(ring.size()):
		var a: Dictionary = ring[i]
		var b: Dictionary = ring[(i + 1) % ring.size()]
		faces.append(a["l"]); faces.append(b["l"]); faces.append(b["r"])
		faces.append(a["l"]); faces.append(b["r"]); faces.append(a["r"])
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(faces)
	shape.shape = concave
	body.add_child(shape)
	add_child(body)


## 用一圈围墙把赛道兜住（防止冲出赛道掉进虚空）。
##
## 关键：护栏必须带碰撞！只画网格的话车会直接穿出去掉下去 ——
## 实测无限速直线行驶时，车约 140 km/h 冲进第一个弯就穿场飞出。
##
## 本函数同时产出两组几何，且**共用同一套坐标计算**，保证视觉与碰撞严丝合缝：
##   - 视觉：rail_height 高的红色护墙（好看）
##   - 碰撞：air_wall_height 高的空气墙 + 可选顶盖（隐形，但拦得住翻越与飞出）
##
## 物理节点划分（性能）：整圈空气墙是**一条闭合三角带 → 一个 StaticBody3D**，
## 内外两侧共用同一个形状，所以不存在"一个路段一个物理节点"的开销。
##
## ⚠ 两处踩过的坑（都在这里修掉了，别再退回去）：
##  1) 环点**不能**按 `d = i * step_len` 均匀取。`Curve3D.sample_baked(d)` 的 d 不是
##     真实弧长：实测 d=1631.11 与绕回的 1635.12 之间参数差 4.01 m，实际位移却是
##     **23.63 m**。均匀取点会在缝处留下真实缺口（射线探针实测两侧都打不到墙）。
##  2) 墙面**不能**沿"起点切线方向"拉一条直弦。椭圆上弦长 ≠ 弧长，弯道外侧每段会短
##     一截，实测每 ~21 m 就漏一个 0.1~0.8 m 的口子（射线探针 119 条打空）。
##     正确做法：在**每个环点**上直接算墙的位置，相邻环点的墙点连线成条带 ——
##     相邻段天然共用一条边，数学上不可能有缝。
func _build_guardrails() -> void:
	var half := road_width * 0.5 + rail_offset
	# 目标段长（沿赛道方向的实际距离）
	var want_step := maxf(sample_step * 2.0, 4.0)

	# 沿曲线采一圈环点（自适应真实距离前进，见坑 1）
	var ring: Array = []
	var ring_pos: Array[Vector3] = []

	var d := 0.0
	var total := _road_length
	var guard := 0
	while guard < 8192:
		guard += 1
		var pos := _sample_at(d)
		var ahead := _sample_at(d + 0.5)
		var fwd := (ahead - pos)
		fwd.y = 0.0
		if fwd.length() < 0.001:
			fwd = Vector3.FORWARD
		fwd = fwd.normalized()
		ring.append({
			"pos": pos,
			"fwd": fwd,
			"side": Vector3(fwd.z, 0.0, -fwd.x).normalized(),
		})
		ring_pos.append(pos)
		if d >= total:
			break
		# 自适应前进：小块试探，攒够 want_step 的真实位移就落下一个环点
		var travelled := 0.0
		var probe := 0.0
		var last := pos
		while travelled < want_step and d + probe < total * 1.01:
			probe += 0.25
			var q := _sample_at(d + probe)
			travelled += last.distance_to(q)
			last = q
		var nd := d + maxf(probe, 0.25)
		if nd >= total - 0.05:
			nd = total      # 收尾精确落在曲线终点（= 起点），闭环
		d = nd

	var steps := ring_pos.size()
	var step_len := total / float(steps)

	# 闭合自检：环点首尾必须真正重合（否则围栏一定缺一段）
	var closure_gap := ring_pos[steps - 1].distance_to(ring_pos[0])
	if closure_gap > 0.05:
		push_error("[赛道] 护栏环闭合异常：末点到首点 %.2f m（段长 %.2f m），围栏会有缺口"
			% [closure_gap, step_len])
	else:
		print("[赛道] 护栏环闭合检查：末点↔首点 %.2f m（段长 %.2f m），闭环 ✔"
			% [closure_gap, step_len])

	# 每个环点上的墙点（左右各一个）。相邻环点的墙点连线成条带（见坑 2）。
	var ring_wall: Array = []      # 每项 {"l": Vector3, "r": Vector3}
	for i in range(steps):
		var p: Vector3 = ring_pos[i]
		var side: Vector3 = ring[i]["side"]
		ring_wall.append({"l": p + side * half, "r": p - side * half})

	# 段间接缝自检：相邻两段共用环点，接缝应恒为 0。
	# 跳过最后一段（i = steps-2 → steps-1）：环点末点与首点重合（闭环），
	# 那一段是退化段，不是缝，不能算进来。
	#
	# 注意别用"墙段长度 - 中心线弦长"来判缝：弯道外侧的墙段本来就比中心线弦长
	# （外侧是外弧），那样算出来的差值不是缝，是曲率 —— 我踩过这个坑。
	# 真正的验收标准是几何闭环（下面这条）+ `--check=enclosure` 的射线全周无缺口。
	var worst_endpoint := 0.0
	for i in range(steps - 2):
		var a: Vector3 = ring_wall[i]["l"]
		var b: Vector3 = ring_wall[i + 1]["l"]
		worst_endpoint = maxf(worst_endpoint, a.distance_to(b))
	if worst_endpoint > step_len * 3.0:
		push_error("[赛道] 护栏条带自检异常：相邻墙点间距 %.2f m 远超段长 %.2f m"
			% [worst_endpoint, step_len])

	# ---------------- 视觉护栏 ----------------
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wall_h := air_wall_height if add_air_wall else rail_height
	var faces := PackedVector3Array()
	# 环点末点与首点重合（闭环），所以 (i, i+1) 到 steps-1 就自然收口
	var seg_count := steps - 1
	for i in range(seg_count):
		var cur: Dictionary = ring_wall[i]
		var nxt: Dictionary = ring_wall[i + 1]
		for sign_i: float in [-1.0, 1.0]:
			var base: Vector3 = cur["l"] if sign_i > 0.0 else cur["r"]
			var next_base: Vector3 = nxt["l"] if sign_i > 0.0 else nxt["r"]
			# 视觉面
			_tri_raw(st, base, next_base, next_base + Vector3.UP * rail_height)
			_tri_raw(st, base, next_base + Vector3.UP * rail_height, base + Vector3.UP * rail_height)
			# 碰撞面（空气墙）：内外两侧都放（双面），车从任何一侧撞都被拦
			var top: Vector3 = base + Vector3.UP * wall_h
			var next_top: Vector3 = next_base + Vector3.UP * wall_h
			faces.append(base); faces.append(next_base); faces.append(next_top)
			faces.append(base); faces.append(next_top); faces.append(top)
			faces.append(next_base); faces.append(base); faces.append(top)
			faces.append(next_base); faces.append(top); faces.append(next_top)
			# 顶盖（可选）：两侧墙顶相连，真正封住走廊上方。会挡相机视线，默认关闭。
			if air_wall_ceiling:
				var inner: Vector3 = cur["r"] if sign_i > 0.0 else cur["l"]
				var next_inner: Vector3 = nxt["r"] if sign_i > 0.0 else nxt["l"]
				var itop: Vector3 = inner + Vector3.UP * wall_h
				var next_itop: Vector3 = next_inner + Vector3.UP * wall_h
				faces.append(top); faces.append(next_top); faces.append(next_itop)
				faces.append(top); faces.append(next_itop); faces.append(itop)
				faces.append(next_top); faces.append(top); faces.append(itop)
				faces.append(next_top); faces.append(itop); faces.append(next_itop)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "Guardrails"
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = RAIL_MAT_ALBEDO
	mat.roughness = 0.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	add_child(mi)

	# ---------------- 碰撞：空气墙 ----------------
	# 整圈**合成一个** StaticBody3D（ConcavePolygonShape3D 本来就是一条带，
	# 没有必要按段拆节点）。高度远大于视觉护栏，所以"看不见的墙"从视觉护墙顶上继续往上。
	var wall_body := StaticBody3D.new()
	wall_body.name = "AirWall"
	wall_body.collision_layer = 1
	wall_body.collision_mask = 0
	var wall_shape := CollisionShape3D.new()
	var wall_concave := ConcavePolygonShape3D.new()
	wall_concave.set_faces(faces)
	wall_shape.shape = wall_concave
	wall_body.add_child(wall_shape)
	add_child(wall_body)
	print("[赛道] 护栏已生成：视觉高 %.1fm，碰撞高 %.1fm，顶盖=%s，%d 段 %d 个三角面，物理节点 1 个（整圈合并）"
		% [rail_height, wall_h, air_wall_ceiling, seg_count, faces.size() / 3])


## 起终点线：一块白色横条，横跨路面
func _build_start_line() -> void:
	var d := start_finish_t * _road_length
	var pos := _sample_at(d)
	var ahead := _sample_at(d + 0.5)
	var fwd := (ahead - pos)
	fwd.y = 0.0
	fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()

	var mi := MeshInstance3D.new()
	mi.name = "StartLine"
	var q := QuadMesh.new()
	q.size = Vector2(road_width, start_line_depth)
	mi.mesh = q
	# 让面朝上：绕 X 轴 -90°，再绕 Y 对齐赛道方向
	mi.transform = Transform3D(Basis(Vector3.UP, atan2(fwd.x, fwd.z)) * Basis(Vector3.RIGHT, deg_to_rad(-90.0)), pos + Vector3.UP * (road_lift + 0.01))
	var mat := StandardMaterial3D.new()
	mat.albedo_color = START_LINE_ALBEDO
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)
	# 记下起终点线的位置与朝向，供赛车出生点计算
	start_line_center = pos
	start_line_forward = fwd


## 沿曲线均匀摆检查点（Area3D），并把起终点标成 is_start_finish
func _build_checkpoints() -> void:
	var total := checkpoint_count + 1        # +1 是起终点
	for i in range(total):
		var is_sf := (i == 0)
		# 起终点在 start_finish_t，其余均匀分布
		var t := fmod(start_finish_t + float(i) / float(total), 1.0)
		var d := t * _road_length
		var pos := _sample_at(d)
		var ahead := _sample_at(d + 0.5)
		var fwd := (ahead - pos)
		fwd.y = 0.0
		fwd = fwd.normalized()

		var area := Area3D.new()
		area.name = "StartFinish" if is_sf else "Checkpoint%d" % i
		area.set_script(load("res://scripts/checkpoint.gd"))
		area.set("is_start_finish", is_sf)
		area.set("order_index", i)
		area.position = pos + Vector3.UP * 1.5
		# 门朝赛道方向：碰撞盒的 X 横跨路面，Z 沿赛道（很薄）
		area.transform = Transform3D(Basis(Vector3.UP, atan2(fwd.x, fwd.z)), area.position)
		area.collision_layer = 4
		area.collision_mask = 2

		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(road_width, 6.0, 1.0)
		shape.shape = box
		area.add_child(shape)
		add_child(area)
		print("[赛道] 检查点 %-14s t=%.2f pos=%s" % [area.name, t, pos])


## 生成一圈地面，尺寸按赛道包络自动放大。
## 注意：地面必须远大于赛道 —— 实测车辆冲出赛道后在场外继续行驶，
## 若地面不够大就会从边缘掉进虚空并无限下落（速度涨到 200+ km/h）。
func _build_ground() -> void:
	# 给足缓冲：赛道半宽约 105m，地面给到 ±450m
	var half := maxf(_curve_extent() + 350.0, 420.0)
	var size := half * 2.0
	var body := StaticBody3D.new()
	body.name = "Ground"
	# 碰撞留在第 1 层（车和射线的 mask 都只查这一层，改了车就会掉进虚空 ——
	# 实测把 collision_layer 挪到第 18 层后，四个轮子全部"接地=false"直接坠落）。
	# 只把**视觉**层挪到第 18 层：小地图相机不渲染该层，所以小地图里没有草地，
	# 路面环和深色底板的对比才拉得开。物理完全不受影响。
	body.collision_layer = 1
	body.collision_mask = 0

	var mi := MeshInstance3D.new()
	mi.name = "GroundMesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(size, 0.4, size)
	mi.mesh = box_mesh
	mi.position = Vector3(0, -0.2, 0)
	# 视觉层 = 第 18 层：小地图相机不渲染它（否则整张小地图都是草地绿）
	mi.layers = 1 << 17
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.28, 0.42, 0.24)     # 草地绿
	mat.roughness = 1.0
	mi.material_override = mat
	body.add_child(mi)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 0.4, size)
	shape.shape = box
	shape.position = Vector3(0, -0.2, 0)
	body.add_child(shape)
	add_child(body)
	print("[赛道] 地面尺寸 = %.0f x %.0f m" % [size, size])


func _curve_extent() -> float:
	return _curve_max_extent


# ============ 对外只读接口（供车辆复位与 HUD 小地图使用）============
# 这些是"赛道数据源"的唯一出口：复位要中心线切线、小地图要赛道折线，
# 都从这里拿，避免 vehicle.gd / hud.gd 各写一份椭圆公式（那种重复迟早会不同步）。

## 路面半宽（米）
func road_half_width() -> float:
	return road_width * 0.5


## 护栏中心线离赛道中心线的距离（米）
func rail_half_width() -> float:
	return road_width * 0.5 + rail_offset


## 赛道中心线周长（米）
func road_length() -> float:
	return _road_length


## 中心线采样点（d 单位：米，自动环绕）
func centerline_point(d: float) -> Vector3:
	return _sample_at(d)


## 中心线在 d 处的前进方向（水平单位向量）
func centerline_forward(d: float) -> Vector3:
	var f := _sample_at(d + 0.5) - _sample_at(d)
	f.y = 0.0
	if f.length() < 0.001:
		return Vector3.FORWARD
	return f.normalized()


## 反查"某个世界坐标最接近中心线上的哪个弧长"。
##
## 用**上一次的结果做局部搜索**（±40m，步长 1m，再二分到 0.25m）而不是全周扫描：
## 车每帧只移动不到 1m，局部搜索既快又不会跳弧长（全周扫描在椭圆两长轴附近
## 会出现两个几乎等距的点，导致弧长来回跳，复位方向会突然反向）。
## 带 40m 窗口兜底：车被瞬移（复位/出界）后窗口不覆盖时，退化为全周粗扫描找起点。
func nearest_on_centerline(p: Vector3, hint_arc: float = -1.0) -> Dictionary:
	if _curve == null:
		return {"pos": p, "forward": Vector3.FORWARD, "arc": 0.0, "dist": 1e9}
	var total := _road_length
	var coarse := 2.0
	var best_arc := 0.0
	var best_d := INF

	var use_local := hint_arc >= 0.0 and hint_arc < total
	if use_local:
		var k := int(40.0 / coarse)
		for i in range(-k, k + 1):
			var d := fposmod(hint_arc + float(i) * coarse, total)
			var q := _sample_at(d)
			var dd := Vector2(p.x - q.x, p.z - q.z).length_squared()
			if dd < best_d:
				best_d = dd
				best_arc = d
		# 局部窗口若明显不够好（例如刚被瞬移），回落到全周粗扫描
		if sqrt(best_d) > 60.0:
			use_local = false
	if not use_local:
		var step := maxf(total / 512.0, 2.0)
		var d2 := 0.0
		while d2 < total:
			var q := _sample_at(d2)
			var dd := Vector2(p.x - q.x, p.z - q.z).length_squared()
			if dd < best_d:
				best_d = dd
				best_arc = d2
			d2 += step

	# 在粗解附近细化到 0.25m（保证复位落点横向误差只有几厘米）
	var span := coarse
	var fine := 0.25
	while span > fine:
		span *= 0.5
		for s: float in [-1.0, 1.0]:
			var d3 := fposmod(best_arc + s * span, total)
			var q3 := _sample_at(d3)
			var dd3 := Vector2(p.x - q3.x, p.z - q3.z).length_squared()
			if dd3 < best_d:
				best_d = dd3
				best_arc = d3

	var pos := _sample_at(best_arc)
	return {
		"pos": pos,
		"forward": centerline_forward(best_arc),
		"arc": best_arc,
		"dist": sqrt(best_d),
	}


## 中心线折线（供小地图画赛道轮廓）。count 越大越平滑。
func centerline_polyline(count: int = 256) -> PackedVector3Array:
	var out := PackedVector3Array()
	if _curve == null:
		return out
	for i in range(count):
		out.append(_sample_at(float(i) / float(count) * _road_length))
	return out


## 检查点门的世界位置与顺序（供小地图标记）
func checkpoint_marks() -> Array:
	var out: Array = []
	for node in get_tree().get_nodes_in_group("checkpoints"):
		var n := node as Node3D
		if n == null:
			continue
		out.append({
			"pos": n.global_position,
			"order": int(n.get("order_index")),
			"start_finish": bool(n.get("is_start_finish")),
		})
	return out


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ta: float, tb: float) -> void:
	st.set_uv(Vector2(0.0, ta * 20.0)); st.add_vertex(a)
	st.set_uv(Vector2(1.0, tb * 20.0)); st.add_vertex(b)
	st.set_uv(Vector2(1.0, tb * 20.0)); st.add_vertex(c)


func _tri_raw(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
