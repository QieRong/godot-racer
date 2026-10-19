extends Node3D
## 起点龙门架（2026-10-19 用户反馈；D3 拍板：跨线而立、立柱带碰撞、撞上不穿模）。
##
## 资源：res://models/environment/desert_ruin_gate.glb（安装指南登记：216 三角形、
## 包围盒 4.80×4.44×1.36 m，Y-up 米制、底部约 y=0）。GLB **纯网格无碰撞体** ——
## 碰撞由本模块自建：每根立柱一个 BoxShape3D（StaticBody3D，场地层 1，车 mask=3
## 都会撞），盒体与视觉立柱同址同厚。为什么必须同厚：视觉比碰撞大会「车头陷进
## 网格才被盒体挡住」（视觉穿模），碰撞比视觉大会「离网格还有距离就被空气挡住」。
##
## 几何保证（正常驾驶不可能碰到）：X 缩放公式令**立柱内侧面 = 路面边缘 + 0.20m**：
##     s = (road_w + 2c) / (S_m − 2·t_m)
##     S_m=4.80（模型跨径）  t_m=实测立柱厚度  c=0.20（净距）
## 推导：模型腿内侧面在 ±(S_m/2 − t_m)，缩放 s 后要等于 road_w/2 + c。
## 横梁在高处（模型高 4.44m，车含翻车 <3m 碰不到），不建碰撞。
##
## 仓库约定：无 class_name（消费方 preload）/ setup() 注入 track / 不 get_node /
## 模块内 await = 0 / 任一步拿不到数据 → push_warning 后静默跳过（不炸验收）。
## 小地图不画：网格放第 18 渲染层（小地图相机只画第 17 层，minimap.gd）。

const GATE_SCENE := "res://models/environment/desert_ruin_gate.glb"
const GATE_SPAN_X := 4.80           # 模型包围盒 X（米）= 原始跨径（安装指南登记值）
const GATE_POST_T_FALLBACK := 0.50  # 立柱厚度兜底值（米）：实测失败时用，日志会声明
const GATE_CLEARANCE_M := 0.20      # 立柱内侧面距路面边缘净距（米）
const GATE_COLLIDE_H := 3.60        # 立柱碰撞盒高（米）：覆盖立柱、不含横梁
const GATE_COLLIDE_D := 1.20        # 立柱碰撞盒纵深（米）
const GATE_GROUND_LAYER := 1        # 场地层：玩家/AI 车 mask=3（地面+车辆）都会撞上
const GATE_RENDER_LAYER := 1 << 17  # 第 18 层：小地图相机（第 17 层）不绘制

var _track: Node3D = null


## 一次性注入赛道（main 在 _after_world_ready 调用）。本模块不反向认识场景树。
func setup(track: Node3D) -> void:
	_track = track


func _ready() -> void:
	_build()


func _build() -> void:
	if _track == null:
		push_warning("[龙门架] 未注入 Track，跳过（不影响验收）")
		return
	var lc: Variant = _track.get("start_line_center")
	var lf: Variant = _track.get("start_line_forward")
	var rw: Variant = _track.get("road_width")
	if not (lc is Vector3) or not (lf is Vector3) or not (rw is float):
		push_warning("[龙门架] Track 缺 start_line_center/forward 或 road_width，跳过")
		return
	var packed: PackedScene = load(GATE_SCENE)
	if packed == null:
		push_warning("[龙门架] 无法加载 %s，跳过" % GATE_SCENE)
		return
	var gate: Node3D = packed.instantiate()
	# ① 实测立柱厚度 t_m（局部 AABB 中心 |x| 超过跨径 35% 的网格的最大 X 尺寸）
	var t_m := _measure_post_thickness(gate)
	# ② 解算 X 缩放：令立柱内侧面 = 路宽/2 + CLEARANCE（推导见文件头）
	var road_w := float(rw)
	var s := (road_w + 2.0 * GATE_CLEARANCE_M) / maxf(0.5, GATE_SPAN_X - 2.0 * t_m)
	var t_v := t_m * s                                       # 视觉立柱厚 = 碰撞盒厚
	var post_x := (GATE_SPAN_X * 0.5 - t_m * 0.5) * s        # 立柱中心横向坐标
	# ③ 摆放：骑在起跑线上（跨线而立），基座贴路面（start_line_center 含高度剖面）
	var fwd := (lf as Vector3)
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var lift: Variant = _track.get("road_lift")
	var lift_y := float(lift) if (lift is float) else 0.0
	gate.name = "StartGantry"
	gate.transform = Transform3D(Basis(side * s, Vector3.UP, fwd),
		(lc as Vector3) + Vector3.UP * lift_y)
	for m in gate.find_children("*", "MeshInstance3D", true, false):
		m.layers = GATE_RENDER_LAYER
	add_child(gate)
	# ④ 碰撞：每根立柱一个静态盒，与视觉同址同厚（D3 硬性要求：不穿模）
	for sign in [1.0, -1.0]:
		var body := StaticBody3D.new()
		body.name = "StartGantryPost%s" % ("R" if sign > 0.0 else "L")
		body.collision_layer = GATE_GROUND_LAYER
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(t_v, GATE_COLLIDE_H, GATE_COLLIDE_D)
		shape.shape = box
		body.add_child(shape)
		add_child(body)
		body.position = side * (sign * post_x) + Vector3.UP * (GATE_COLLIDE_H * 0.5)
	print("[龙门架] 已就位：路宽 %.1f → 跨径 %.2f（缩放 ×%.2f，立柱厚 %.2f%s），立柱内侧面离路面 %.2fm，带碰撞（场地层 %d）"
		% [road_w, GATE_SPAN_X * s, s, t_v,
			"（兜底值）" if t_m == GATE_POST_T_FALLBACK else "",
			GATE_CLEARANCE_M, GATE_GROUND_LAYER])


## 实测立柱厚度：取局部 AABB 中心 |x| 超过跨径 35% 的网格的最大 X 尺寸。
## 单网格模型（立柱与横梁一体）或嵌套变换测不到 → 返回 0，由调用方走兜底值。
func _measure_post_thickness(gate: Node3D) -> float:
	var best := 0.0
	for m in gate.find_children("*", "MeshInstance3D", true, false):
		var aabb: AABB = m.transform * m.get_aabb()
		if absf(aabb.get_center().x) > GATE_SPAN_X * 0.35 and aabb.size.x > best:
			best = aabb.size.x
	if best <= 0.05:
		print("[龙门架] 立柱厚度实测失败（单网格模型？）→ 用兜底值 %.2fm，请以截图核对"
			% GATE_POST_T_FALLBACK)
		return GATE_POST_T_FALLBACK
	return best
