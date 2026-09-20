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


## 本关要用的赛道参数（由 main.gd 在**生成之前**注入）。
## 为什么必须这样传：Track 是 Main 的**兄弟节点**且排在其前面，所以 Track._ready()
## 比 Main._ready() **先**执行。如果在 Main._ready() 里 set("radius_x", ...) 就太晚了 ——
## 实测五个关卡的曲线长度全是 1635.1m，参数完全没生效。
## 正确做法：Main 先把 config 交给这里，由**本函数自己**在 ready 时生成赛道。
var level_config: Resource = null

## 赛道数据是否已经生成完毕。
##
## 顺序问题（被坑了三次，这里写清楚）：
##   Track 是 track.tscn 的**实例场景**，它的 _ready() 一定在父场景脚本 main.gd 的
##   _ready() **之前**跑完（Godot 触发 ready 跟脚本优先级无关，按节点顺序来）。
##   所以"在 main.gd 里 set(radius_x) 再指望 Track 读到"是不可能的 ——
##   实测五个关卡曲线长度全是 1635.1m。
##
## 解决办法：本脚本**不在 _ready 里生成**，改为由 main.gd 设好参数后调用
## `build_world.call_deferred()`。同时把"曲线已建好"当成就绪信号：
## 车辆/小地图可以 `await await_world_ready()` 再依赖赛道数据，避免读到空曲线
## （实测漏了这步时，车会被放到世界原点、检查点也连不上）。
##
## 注意：本脚本主要靠 `main.tscn` 里的 Track 实例使用；但**直接实例化本脚本生成赛道**
## （tree.tscn 没有 Track 的场景，或临时调试）时，把 defer_build_to_owner 设为 false，
## 它会自己在 _ready 里生成。
@export var defer_build_to_owner := true

var _built := false


func _ready() -> void:
	if not defer_build_to_owner:
		build_world()


## 赛道是否已生成（车辆/小地图用它判断能不能开始依赖赛道数据）
func is_world_ready() -> bool:
	return _built and _curve != null


## 等赛道生成完成。用于车辆出生点计算这类**必须在生成之后**才能做的事。
func await_world_ready() -> void:
	var guard := 0
	while not is_world_ready() and guard < 600:
		guard += 1
		await get_tree().process_frame


## 生成整条赛道。可被 main.gd 用 build_world.call_deferred() 触发
## （因为 main.gd 的优先级更高：父/主脚本 _ready 在子/实例场景之前跑）。
func build_world() -> void:
	if _built:
		return
	_built = true
	if level_config != null:
		level_config.call("apply_to_track", self)
		print("[赛道] 已应用关卡参数：椭圆 %.0f×%.0f 路宽 %.0f S弯 %.0f×%.1f波"
			% [radius_x, radius_z, road_width, s_curve_amplitude, s_curve_waves])
	_curve = _build_curve()
	_road_length = _curve.get_baked_length()
	# 闸门：曲线长度是"整条赛道能不能存在"的前提。实测有一次它变成 0
	# （Curve3D 属性赋值失败导致曲线对象失效），表现是车掉进虚空、小地图全黑，
	# 而日志里看上去一切正常。所以这里必须**吼出来**，不能任它静默往下走。
	if _road_length < 50.0:
		push_error("[赛道] ⚠ 曲线长度异常（%.1fm）：路面/护栏/检查点都不会生成，车会掉进虚空。" % _road_length
			+ "请检查 _build_curve 的生成路径（layout 解析 / Curve3D 构造）。")
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
##
## 现在这些参数是**导出属性**（由 LevelConfig 注入），不再写死 —— 这是"多个关卡
## 共用一个场景"的关键：关卡换形状只改数据，不动代码。
@export_group("赛道形状（由关卡配置注入）")
## 椭圆长半轴（米）
@export var radius_x := 320.0
## 椭圆短半轴（米）
@export var radius_z := 200.0
## S 弯扰动幅度（米）：在椭圆半径上叠加正弦扰动，把弯道变成连续 S 弯
@export var s_curve_amplitude := 0.0
## S 弯波数（沿整圈几个波）
@export var s_curve_waves := 3.0

const TRACK_SEGMENTS := 64

## 本关的**路段 DSL**（由 LevelConfig 注入）。空串 = 退回椭圆公式（阶段 1 的兼容路径，
## 阶段 3 逐关迁移完成后连同 radius_x/radius_z/s_curve_* 一起删除）。
##
## 格式见 scripts/track_layout.gd 的文件头；例：
##   "straight:110, arc:70:90, straight:60, arc:70:90"（mirror180 模式只写半条）
##   "straight:164, arc:20:90, straight:38.5, chicane:30:4, arc:20:90, straight:160, ..."
@export var layout := ""
## 闭环模式："solve"（全条写出、解算收口）/ "mirror180"（只写半条、点对称加倍）
@export var closure_mode := "solve"


func _build_curve() -> Curve3D:
	if not layout.is_empty():
		return _build_curve_from_layout()
	return _build_curve_legacy()


## 用路段 DSL 生成中心线。
##
## 关键点：**几何生成与验收用的是同一份逻辑**（track_layout.gd）——
## 生成走一条路、验收走另一条路，正是本项目吃过最大亏的坑（验收报 ✔ 而游戏是错的）。
func _build_curve_from_layout() -> Curve3D:
	var script: GDScript = load("res://scripts/track_layout.gd")
	if script == null:
		push_error("[赛道] 加载不到 track_layout.gd，layout 无法生效，退回椭圆公式")
		return _build_curve_legacy()
	var r: Dictionary = script.call("build", layout, closure_mode, sample_step, rail_half_width())
	if not bool(r.get("ok", false)):
		push_error("[赛道] layout 不合法，已退回椭圆公式（请修 layout）：%s" % str(r.get("error", "?")))
		return _build_curve_legacy()
	var pts: PackedVector3Array = r["points"]
	# ⚠⚠ 这里踩过两个把游戏搞成"虚空"的坑，别再改回去：
	#   ① **Godot 4 的 Curve3D 没有 `cubic_interp` 属性**（能配的只有 bake_interval）。
	#      写它 → 「Invalid assignment of property 'cubic_interp'」→ 曲线对象失效 →
	#      `get_baked_length()` 拿到 null → 长度 0 → 路面/护栏/检查点全不生成 →
	#      车掉进虚空、小地图全黑（用户实测现象）。
	#   ② **Curve3D 默认是折线**：手柄为零时控制点之间是直线段，所以必须用
	#      track_layout.make_curve() 造曲线（它会按 Catmull-Rom 给手柄，曲线才 C¹ 连续）。
	#      生成与验收共用同一个函数，避免"两条路径"漂移。
	var c: Curve3D = script.call("make_curve", pts, true, 0.5)
	if c == null:
		push_error("[赛道] track_layout.make_curve 返回 null，退回椭圆公式")
		return _build_curve_legacy()
	var probe := c.get_baked_length()
	if probe < 10.0:
		push_error("[赛道] layout 生成的曲线长度只有 %.2fm（异常，正常应 >100m）：已退回椭圆公式。" % probe
			+ "请检查 track_layout 的点列与 Curve3D 烘焙设置。")
		return _build_curve_legacy()
	var mx := 0.0
	for p in pts:
		mx = maxf(mx, maxf(absf(p.x), absf(p.z)))
	_curve_max_extent = mx
	print("[赛道] layout 生效：%s" % layout)
	print("[赛道] 闭环模式 %s（%s）：控制点 %d 个，控制点构成的曲线长 %.1fm，闭环残差 %.4fm，最小半径 %.1fm，每 2m 最大航向步长 %.2f°"
		% [str(r.get("mode_used", closure_mode)), "点对称加倍" if bool(r.get("doubled", false)) else "解算/精确",
		   int(r.get("control_points", pts.size())), float(r.get("length", 0.0)),
		   float(r.get("closure_gap", -1.0)), float(r.get("min_radius", 0.0)),
		   float(r.get("max_heading_step_deg", 0.0))])
	return c


## 椭圆公式（旧路径）。保留到阶段 3 逐个关卡迁移完为止。
func _build_curve_legacy() -> Curve3D:
	var c := Curve3D.new()
	for i in range(TRACK_SEGMENTS):
		var a := TAU * float(i) / float(TRACK_SEGMENTS)
		var p := Vector3(cos(a) * radius_x, 0.0, sin(a) * radius_z)
		# S 弯：沿半径方向叠加正弦扰动（连续曲率，不会像折线那样把车弹飞）
		if s_curve_amplitude > 0.001:
			var r := p.length()
			if r > 0.001:
				var wobble := sin(a * s_curve_waves) * s_curve_amplitude
				p = p + (p / r) * wobble
		c.add_point(p)
	_curve_max_extent = maxf(radius_x, radius_z) + s_curve_amplitude
	return c


## 取曲线上某个弧长处的点（自动环绕，保证闭合处不断裂）。
## 赛道还没生成时返回原点，避免"null 上调用 sample_baked"刷屏 ——
## 调用方（车辆/小地图）应当先 await await_world_ready() 再用。
func _sample_at(distance: float) -> Vector3:
	if _curve == null:
		return Vector3.ZERO
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
	# 路面贴图（开发期由 Agnes 生成、打包进游戏；**禁止运行时生图**）。
	# 找不到就退回纯色 —— 素材缺失绝不能让赛道建不出来。
	var tarmac := _load_tex("res://assets/textures/road_tarmac.png")
	if tarmac != null:
		mat.albedo_texture = tarmac
		# 同地面：albedo_color 会和贴图相乘，有贴图就归白，否则会被着色
		mat.albedo_color = Color.WHITE
		# UV 已经在 _tri() 里按真实米数写好了，这里不需要再缩放
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		print("[赛道] 路面贴图已应用：road_tarmac.png（每 %.0fm 一个循环）" % ROAD_TILE_METERS)
	else:
		print("[赛道] 路面贴图缺失，退回纯色（assets/textures/road_tarmac.png）")
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


## 护栏默认摩擦（米）。
##
## 这里踩过一个很关键的坑：护栏原来**没有 physics_material**，用的是 Godot 默认摩擦
## 1.0 —— 相当于墙面有强粘性。车以浅角度贴上内凹的墙时，车头会楔进去 0.2m 左右，
## 然后前后受力互相抵消，油门推不出来（实测：满油门车速停在 0.3~3 km/h、转向 0°、
## 车外缘越过墙面 0.21m）。表现就是用户报的"跑完一圈快回到起点会卡墙"。
## 降到 0.05 让车贴着墙能顺滑滑走；留一点 bounce 避免贴墙时被"吸"住。
const RAIL_FRICTION := 0.05
const RAIL_BOUNCE := 0.05


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
	# 低摩擦材质：让车贴墙时能滑走，而不是被咬住（见 RAIL_FRICTION 的说明）
	var wall_mat := PhysicsMaterial.new()
	wall_mat.friction = RAIL_FRICTION
	wall_mat.bounce = RAIL_BOUNCE
	wall_body.physics_material_override = wall_mat
	var wall_shape := CollisionShape3D.new()
	var wall_concave := ConcavePolygonShape3D.new()
	wall_concave.set_faces(faces)
	wall_shape.shape = wall_concave
	wall_body.add_child(wall_shape)
	add_child(wall_body)
	print("[赛道] 空气墙材质：friction=%.2f bounce=%.2f（默认 1.0 会把车粘住/咬住）"
		% [RAIL_FRICTION, RAIL_BOUNCE])
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
	mat.albedo_color = Color(0.28, 0.42, 0.24)     # 草地绿（没有贴图时的兜底）
	mat.roughness = 1.0
	# 地面贴图按关卡主题走：开发期由 Agnes 生成并打包进游戏，不运行时生成。
	# 缺素材就保持纯色 —— 不能因为少一张图就让赛道建不出来。
	var gtex := _load_tex(ground_texture_path)
	if gtex != null:
		mat.albedo_texture = gtex
		# ⚠ 有贴图时必须把 albedo_color 归白。
		# albedo_color 和 albedo_texture 是**相乘**的：留着上面的草地绿
		# (0.28,0.42,0.24) 会把雪地贴图染成暗绿（实测截图就是一片脏绿，
		# 完全看不出是雪地）。纯色兜底才需要那个绿。
		mat.albedo_color = Color.WHITE
		# 地面是一整块 BoxMesh，UV 只有 0~1，直接用会拉成一片糊。
		# 所以靠 uv1_scale 把它平铺：地面尺寸约 840~1400m，按 48 倍
		# 折算每个循环约 20~30m，视觉上颗粒接近真实碎石/草地。
		mat.uv1_scale = Vector3(48.0, 48.0, 1.0)
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		print("[赛道] 地面贴图已应用：%s（uv1_scale=48，地面 %.0fm）" % [ground_texture_path, size])
	else:
		print("[赛道] 地面贴图缺失，退回纯色草地绿：%s" % ground_texture_path)
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


## 本关的地面贴图路径。由 LevelConfig 注入（track_generator 不认识关卡数据）。
var ground_texture_path := ""


## 安全加载贴图：**加载失败返回 null，绝不让赛道建不出来**。
## 素材是开发期产物，可能缺失/被清理；比赛逻辑不该依赖它存在。
func _load_tex(path: String) -> Texture2D:
	if path.is_empty():
		return null
	if not ResourceLoader.exists(path):
		return null
	var t = load(path)
	if t is Texture2D:
		return t
	return null


## 路面贴图一个循环覆盖多少米。太小会变成噪点，太大看着糊。
const ROAD_TILE_METERS := 9.0
## 路面环采样步长（米）。与 build_world 里的采样步长保持一致，
## 用来把"第 i 个断面"换算成**真实米数**。
const ROAD_SAMPLE_STEP := 2.0


## 写一个路面三角形。
##
## UV 必须按**真实米数**算，不能按断面序号：
## 原来写的是 `ta * 20.0`（每 2m 一个断面 → 每 0.1m 就重复一遍贴图），
## 纯色时看不出来，一贴图就变成一片噪点。现在 v = 米数/9m、u = 横向 0~1。
func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ta: float, tb: float) -> void:
	var va := ta * ROAD_SAMPLE_STEP / ROAD_TILE_METERS
	var vb := tb * ROAD_SAMPLE_STEP / ROAD_TILE_METERS
	st.set_uv(Vector2(0.0, va)); st.add_vertex(a)
	st.set_uv(Vector2(1.0, vb)); st.add_vertex(b)
	st.set_uv(Vector2(1.0, vb)); st.add_vertex(c)


func _tri_raw(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
