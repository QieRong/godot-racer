extends Node3D
## 起点龙门架（GANTRY-L4-001，2026-10-19 用户实机反馈第二轮修复）。
##
## ── 上一版错在哪（都已被运行时判据钉死，证据 godot-logs/gantry-l4-geocheck-red.log）──
## 1. **整模等比放大**：旧式 `s = (road_w + 2c) / (S_m − 2·t_m)` 假设"柱内缘 = S_m/2 − t_m"。
##    实测 desert_ruin_gate.glb 柱组内缘在 |x| = **1.07**（capital），不是 1.90；
##    `_measure_post_thickness` 又实测失败走兜底 t_m = 0.50 → 门被撑成 13.14m 跨，
##    柱子反而**杵进路面 2.07m**（L4 路宽 10m）。
## 2. **缩放其实只作用在 X 轴上**：`Basis(side * s, UP, fwd)` 只拉伸侧向 → 门仍是
##    4.44m 高、1.35m 厚，横梁被拉成细长条，观感与"门"越走越远。
## 3. **碰撞体根本没跟门架在一起**：碰撞体是**门架节点的兄弟**（挂在本模块下），
##    位置写成 `side * post_x`——那是**世界原点附近**，不是起跑线附近。
##    实测（起跑线在 (12, 0.5, -30)）碰撞盒横向落在 −34.39 ~ −20.8，
##    与视觉柱相差 27.6m：车从看得见的柱子里直接穿过去，D3"撞上不穿模"从未成立。
## 4. **柱头悬空**：模型先天废墟砌缝 masonry 顶 3.29 → capital 底 3.425（0.135m）。
##
## ── 本版做法：分件摆放（不缩放整模）──
##   · 统一缩放只由**门高**决定：`s = GATE_TARGET_HEIGHT_M / MODEL_HEIGHT_M`；
##   · 左右柱组各自沿 ±X **外推**，使"柱组最内缘（capital） = 路面边缘 + 净距"；
##   · 横梁组（lintel / lintel_top / joint）单独做 **X 拉伸**，盖住外推后的两柱外缘；
##   · 基座 foundation 是整条横跨 4.80m 的板 → 隐藏（见下）；
##   · 柱身（masonry）沿 Y 拉伸补掉 0.135m 砌缝，让柱头落在柱身上；
##   · 碰撞体做成**门架节点的子节点**（同源同坐标系），与视觉柱同址同厚。
##
## ⚠ 几何常量全部来自**运行时实测**（不是"安装指南登记值"）：用
##    tools/gantry-l4-probe.gd 在 Godot 4.4.1 里实例化 glb 后逐 MeshInstance3D 读
##    mesh AABB 得到，证据 godot-logs/gantry-l4-probe-raw.log。导入管线
##    （root_scale=1.0 / use_node_type_suffixes=true）未改写节点名与轴向，实测值与
##    静态解析一致，但**以运行时为准**是本模块的硬规矩 —— 换引擎版本要重跑探针。
##
## 仓库约定：无 class_name（消费方 preload）/ 依赖经 setup() 注入 / 模块内不
## get_node / 不 get_tree / 模块内 await = 0 / 拿不到数据 → push_warning 后静默跳过。
## 网格沿用第18渲染层，与既有装饰层一致。

## 门架模型：**编译期** preload（GANTRY-L4-001B 第 3 项）。
## 为什么不用运行时 load()：运行时 load 是在赛道就绪**之后**才把资源拉进来，门架
## 于是"进来后闪一下地出现"；preload 在脚本编译期就把 glb 准备好，模块 _ready()
## 里一步建完（判据 G13a 在源码层看住"运行时 load 数必须为 0"）。
## 顺带：preload 失败发生在**加载脚本时**，运行时不存在"加载不到"这条路径，
## 所以这里刻意不留 null 分支（留了就是永远跑不到的死代码）。
const GATE_PACKED := preload("res://models/environment/desert_ruin_gate.glb")

## ---- 整模实测（glb 局部坐标，米，Y-up）----
const MODEL_HEIGHT_M := 4.44        # 整模高（foundation 底 0 → lintel_top 顶 4.44）

## ---- 柱组实测（左组 cx=−1.63、右组 cx=+1.63，关于中心线对称）----
const POST_INNER_X := 1.07          # 柱组**最内**缘（capital 内侧）——定位用
const POST_OUTER_X := 2.19          # 柱组**最外**缘（capital 外侧）——横梁跨度用
const POST_CENTER_X := 1.63         # 柱组中心（foot/capital 同心）——碰撞盒中心用
const POST_THICKNESS_M := 0.98      # column_foot 宽（2.12−1.14）= **车可及高度内最宽** → 碰撞厚用
const POST_DEPTH_M := 1.03          # 柱组纵深（foot/capital 最厚 2×0.515）→ 碰撞深用

## ---- 柱身/柱头实测（补缝用）----
const SHAFT_BOTTOM_Y := 0.600       # masonry 底
const SHAFT_TOP_Y := 3.290          # masonry 顶
const FOOT_BOTTOM_Y := 0.295        # column_foot 底（实测 y[0.295, 0.605]）
const FOOT_TOP_Y := 0.605           # column_foot 顶（柱身该坐在它上面）
const GAP_CAPITAL_M := 0.135        # 先天砌缝（实测）：柱身顶 3.290 → 柱头底 3.425
## capital 底由"柱身顶 + 砌缝"推导（而不是再抄一个 3.425）：补缝公式一旦改动，
## 这里会跟着动，不会出现"常量写 3.425、公式按 3.29+0.135 算"的两份真相。
const CAPITAL_BOTTOM_Y := SHAFT_TOP_Y + GAP_CAPITAL_M   # = 3.425
const CAPITAL_TOP_Y := 3.675        # capital 顶 → 碰撞盒高

## ---- 横梁组实测 ----
const LINTEL_HALF_X := 2.175        # lintel 半跨
const LINTEL_TOP_HALF_X := 1.95     # lintel_top 半跨（joint 随 lintel 拉伸）

## ---- 摆放口径 ----
## 2026-10-21 用户批准：门高 5.5m，并沿起跑线前进方向前移 6m。
## 真实第三人称起跑画面可容纳门架上部轮廓；净高约 4.46m，保留 ≥3m 安全净空。
## 柱组仍独立外推到护栏外，不通过收窄净通道来缩小外观。
const GATE_TARGET_HEIGHT_M := 5.5
const GATE_FORWARD_OFFSET_M := 6.0
## 前移处有弯道：沿原起点方向的实测护栏包络会偏移；柱组再外让 0.15m。
## 保留真实环境 G10/G12 零相交判据，不通过放宽判据掩盖柱脚重叠。
const GATE_CLEARANCE_M := 0.35      # 相对赛道护栏名义外侧面（见 ③）
const GATE_LINTEL_OVERHANG_M := 0.10 # 横梁两端比柱外缘多出的挑檐（免与柱侧面共面 Z-fight）
const GATE_GROUND_LAYER := 1        # 场地层：玩家/AI 车 mask=3（地面+车辆）都会撞上
const GATE_RENDER_LAYER := 1 << 17  # 第18层：既有装饰层

## ---- 关卡门控 ----
## 只在第四关「荒漠遗迹」挂（data/levels/level_4.tres）。用 **0 起的关卡索引**
## （GameState.chosen_level 的口径，menu.gd 的 --level=N 同口径），不碰
## LevelConfig 字段契约、不靠 display_name 中文字符串。
const GANTRY_LEVEL_INDEX := 3

var _track: Node3D = null
var _level_index := -1


## 一次性注入：赛道（几何唯一真相源）+ 本关索引（门控）。本模块不反向认识场景树。
func setup(track: Node3D, level_index: int) -> void:
	_track = track
	_level_index = level_index


func _ready() -> void:
	_build()


func _build() -> void:
	if _level_index != GANTRY_LEVEL_INDEX:
		# 打印里刻意**不带关卡中文名**：门控只认索引，代码里出现中文名迟早会有人
		# 拿它去做字符串比较（那正是本轮要避免的第二份真相）。
		print("[龙门架] 本关索引 %d ≠ %d（仅第四关挂起点门架）→ 跳过"
			% [_level_index, GANTRY_LEVEL_INDEX])
		return
	if _track == null:
		push_warning("[龙门架] 未注入 Track，跳过（不影响验收）")
		return
	var lc: Variant = _track.get("start_line_center")
	var lf: Variant = _track.get("start_line_forward")
	var rw: Variant = _track.get("road_width")
	if not (lc is Vector3) or not (lf is Vector3) or not (rw is float):
		push_warning("[龙门架] Track 缺 start_line_center/forward 或 road_width，跳过")
		return
	var road_w := float(rw)
	var gate: Node3D = GATE_PACKED.instantiate()
	# ① 分件：按 mesh 名字前缀分组（名字经 Godot 导入后未改写，见探针日志）
	var shafts: Array[MeshInstance3D] = []
	var capitals: Array[MeshInstance3D] = []
	var beams: Array[MeshInstance3D] = []
	var foundation: MeshInstance3D = null
	for m in gate.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var n := mi.name
		if n.begins_with("foundation"):
			foundation = mi
		elif n.begins_with("capital"):
			capitals.append(mi)
		elif n.begins_with("lintel") or n.begins_with("joint"):
			beams.append(mi)
		elif n.begins_with("column_foot") or n.begins_with("masonry"):
			shafts.append(mi)
		else:
			push_warning("[龙门架] 未识别的网格 %s，按柱身处理（请重跑探针核对模型）" % n)
			shafts.append(mi)
	if shafts.is_empty() or capitals.is_empty() or beams.is_empty():
		push_warning("[龙门架] 分组失败（柱身 %d / 柱头 %d / 横梁 %d）→ 跳过，不摆半个门"
			% [shafts.size(), capitals.size(), beams.size()])
		return
	# ② 统一缩放：只由门高决定（旧版按净空反推 → 等式两边都用错了模型参数）
	var s := GATE_TARGET_HEIGHT_M / MODEL_HEIGHT_M
	# ③ 柱组内缘目标 = **护栏视觉外侧面** + 净距；外推量 dx 让 capital 内侧正好落在那里。
	#    用**最内缘**（capital 1.07）定位而不是砌块（1.21）→ 门架任何高度都不越过净距线。
	#
	#    ⚠ 上一版把柱子摆在「路面边缘 + 0.20」（L4 = ±5.20），而护栏碰撞面在 6.20、
	#    视觉外侧面在 6.55 → 护栏**整段埋进柱身**（用户报的"红色护栏横穿柱身"）。
	#    护栏尺寸**只能从赛道读**：rail_half_width() = 碰撞面 = 内侧面，
	#    rail_visual_thickness = 视觉厚度（往外那一层）。严禁把 6.20 / 6.55 / 1.2 /
	#    0.35 抄进本文件 —— 抄了就等于复制第二份公式，迟早和赛道漂移（唯一真相源铁律）。
	var rail_half := _rail_half_width()
	var rail_thick := _rail_visual_thickness()
	var x_in := rail_half + rail_thick + GATE_CLEARANCE_M
	var dx := maxf(0.0, x_in - POST_INNER_X * s)
	if dx <= 0.0:
		push_warning("[龙门架] 路宽 %.2f 窄于门洞，柱组无法外推到路外（净距 %.2f），已夹到 0"
			% [road_w, GATE_CLEARANCE_M])
	# ④ 摆放：在起跑线前方 6m；高度仍对齐起点路面。
	var fwd := (lf as Vector3)
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var lift: Variant = _track.get("road_lift")
	var lift_y := float(lift) if (lift is float) else 0.0
	gate.name = "StartGantry"
	# ⚠ 基向量**不带缩放**：整模不再被等比拉伸，缩放落在每个分件自己身上（见 ⑤⑥）。
	gate.transform = Transform3D(Basis(side, Vector3.UP, fwd),
		(lc as Vector3) + Vector3.UP * lift_y + fwd * GATE_FORWARD_OFFSET_M)
	# ⑤ 柱组：整体沿 ±X 外推 dx，统一缩放 s；柱身再沿 Y 拉伸补掉 0.135m 砌缝，
	#    使柱身顶 = FOOT_TOP_Y·s + SHAFT_H·k = CAPITAL_BOTTOM_Y·s（柱头落在柱身上）。
	var k_y := (CAPITAL_BOTTOM_Y - FOOT_TOP_Y) / (SHAFT_TOP_Y - SHAFT_BOTTOM_Y) * s
	for mi in shafts:
		mi.scale = Vector3(s, s, s)
		if mi.name.begins_with("masonry"):
			mi.scale.y = k_y
			mi.position.y = FOOT_TOP_Y * s - SHAFT_BOTTOM_Y * k_y
		elif mi.name.begins_with("column_foot"):
			# 柱脚**落地**：基座 foundation 隐藏后，柱组最低点停在 0.295·s ≈ 0.56m
			# → 整根柱子悬空（判据 G11 实测就是这个 0.565m）。这里像"柱身补缝"那样
			# 把柱脚沿 Y 拉到门架局部 y = 0（= 路面/地面高度）：柱脚顶保持
			# FOOT_TOP_Y·s 不动，只把底边往下拽，柱身照样坐在柱脚上。
			# 不放 foundation 回地面的理由见 ⑥（它是一整块横跨 4.80m 的板）。
			var k_foot := FOOT_TOP_Y * s / (FOOT_TOP_Y - FOOT_BOTTOM_Y)
			mi.scale.y = k_foot
			mi.position.y = -FOOT_BOTTOM_Y * k_foot
		mi.position.x = _side_sign(mi) * dx
	for mi in capitals:
		mi.scale = Vector3(s, s, s)
		mi.position.x = _side_sign(mi) * dx
	# ⑥ 基座：整条横跨 4.80m 的板，等比放大后是 9.19m 长、横跨整条路面的一块 ——
	#    **不许平铺在赛道上**。三选一里取"隐藏"：① 柱组自带 column_foot 基座块，
	#    少了它柱子照样稳稳落地；② 它唯一的作用（把两柱在地面连起来）在柱距拉开
	#    10.4m 后已无意义；③ 隐藏后那条 0.015m 基座缝也随之消失，不需要补。
	if foundation != null:
		foundation.visible = false
	# ⑦ 横梁组：单独做 X 拉伸，两端盖住外推后的柱外缘 + 10cm 挑檐
	var l_half := POST_OUTER_X * s + dx + GATE_LINTEL_OVERHANG_M
	for mi in beams:
		var half0 := LINTEL_TOP_HALF_X if mi.name.begins_with("lintel_top") else LINTEL_HALF_X
		mi.scale = Vector3(l_half / half0, s, s)
	for mi in gate.find_children("*", "MeshInstance3D", true, false):
		mi.layers = GATE_RENDER_LAYER
	add_child(gate)
	# ⑧ 碰撞：每根柱一个静态盒，**挂在门架节点下**（旧版挂在模块下、坐标落在世界
	#    原点附近，实测离视觉柱 27.6m → 车直接穿过柱子）。厚用"车可及高度内最宽"的
	#    column_foot（0.98）：宁可早 0.13m 挡住，也不许车头陷进网格（D3 不穿模）。
	var post_h := CAPITAL_TOP_Y * s
	var post_thick := POST_THICKNESS_M * s
	var post_depth := POST_DEPTH_M * s
	var post_cx := POST_CENTER_X * s + dx
	for sign in [1.0, -1.0]:
		var body := StaticBody3D.new()
		body.name = "StartGantryPost%s" % ("R" if sign > 0.0 else "L")
		body.collision_layer = GATE_GROUND_LAYER
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(post_thick, post_h, post_depth)
		shape.shape = box
		body.add_child(shape)
		gate.add_child(body)
		body.position = Vector3(sign * post_cx, post_h * 0.5, 0.0)
	print("[龙门架] 已就位（第四关）：门高 %.2fm（缩放 ×%.3f）· 门洞跨 %.2fm / 净高 %.2fm"
		% [GATE_TARGET_HEIGHT_M, s, x_in * 2.0, 3.60 * s])
	print("[龙门架] 护栏（从赛道读）：内侧面 ±%.3f / 视觉外侧面 ±%.3f（厚 %.3f）"
		% [rail_half, rail_half + rail_thick, rail_thick])
	print("[龙门架] 柱内缘 ±%.3f（护栏外侧面 + 净距 %.2f）· 外缘 ±%.3f · 柱厚 %.3f（碰撞同址同厚，场地层 %d）"
		% [x_in, GATE_CLEARANCE_M, POST_OUTER_X * s + dx, post_thick, GATE_GROUND_LAYER])
	print("[龙门架] 柱脚落地：底 = 世界 y %.3f（= 门架原点，与路面顶同高）· 柱脚顶 %.3f"
		% [gate.position.y, gate.position.y + FOOT_TOP_Y * s])


## 护栏内侧面（= 碰撞面）离赛道中心线的距离。
##
## 唯一真相源是 TrackGenerator.rail_half_width()（= road_width*0.5 + rail_offset）。
## 本模块**不复制**那份公式（复制一份就等于制造第二份真相，赛道改了这里不会跟着改），
## 取不到才逐级退化并告警 —— 与 scripts/checks/env_phys.gd 读护栏尺寸的口径一致。
func _rail_half_width() -> float:
	if _track != null and _track.has_method("rail_half_width"):
		return float(_track.call("rail_half_width"))
	var ro: Variant = _track.get("rail_offset")
	if ro != null:
		push_warning("[龙门架] Track 无 rail_half_width()，退化为 road_width*0.5 + rail_offset（口径可能不同步）")
		return float(_track.get("road_width")) * 0.5 + float(ro)
	push_warning("[龙门架] Track 无 rail_half_width() 也无 rail_offset，退化为路宽半宽（护栏位置可能不准）")
	return float(_track.get("road_width")) * 0.5


## 护栏**视觉**厚度（往赛道外侧的那一层）。读不到才用 0.35 兜底并告警
## （0.35 是 track_generator.gd 的 @export 默认值，兜底值必须与它一致）。
func _rail_visual_thickness() -> float:
	var rt: Variant = _track.get("rail_visual_thickness")
	if rt != null:
		return float(rt)
	push_warning("[龙门架] Track 无 rail_visual_thickness，用 0.35 兜底（护栏厚度可能不准）")
	return 0.35


## 柱组在门的哪一侧：由**实测 AABB 中心的 x 符号**决定（不依赖名字里的 −1/1 后缀，
## 免得导入器改名字就翻车）。
func _side_sign(mi: MeshInstance3D) -> float:
	return -1.0 if (mi.transform * mi.get_aabb()).get_center().x < 0.0 else 1.0
