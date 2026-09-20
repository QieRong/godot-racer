extends Node3D
## 障碍物场：按关卡配置在路面内生成静态障碍 + 动态滑动路障。
##
## 三条硬约束（都有验收检查兜着）：
##  ① **性能**：静态障碍的碰撞**全部合并进一个 StaticBody3D**，
##     绝不允许变成几十个独立物理节点（AGENTS.md 的性能红线）。
##  ② **不许堵死赛道**：任何时刻、任何位置都要给车留出
##     `车宽 + 0.5m` 的通行缝隙，否则 `--check=lap` 直接报废。
##  ③ **可复现**：位置用固定种子的 RNG，同一关卡每次生成完全相同 ——
##     否则压测/验收的失败点无法复现。
##
## 关于 AI：障碍物的横向位置**刻意避开 AI 的巡航车道**（见 `clear_lane_for()`），
## 因为 AI 只巡线、不做避障。与其让 AI 一头撞上去再靠自救脱困，
## 不如把障碍摆在它的车道之外 —— 对玩家才是真正的"可选线路被压缩"。

## 固定种子：保证同一关卡每次生成的障碍位置一致
const SEED := 20260919
## 单个障碍离路缘至少要留的余量（米）
const EDGE_MARGIN := 0.6
## 必须给车留出的通行缝隙 = 车宽 + 这个值（米）
const PASS_EXTRA := 0.5
## 车宽（米），与 ai_opponent.gd 的 BODY_HALF_WIDTH 同一来源
const CAR_WIDTH := 1.75
## AI 巡航车道（与 ai_opponent.gd 的 lane_offset 默认值一致）。
## 障碍物要避开以这个值为中心的走廊。
const AI_LANE := 2.4
const AI_LANE_HALF := 0.9

var track: Node3D = null
## 每项：{arc, lateral, half_width, kind}
## 静态与动态都在这里，供 AI 查询与验收统计
var obstacles: Array = []

var _static_body: StaticBody3D = null
## 每项：{node: AnimatableBody3D, arc, center, travel, half_width, speed, phase}
var _dynamic: Array = []
var _total_len := 1.0


## 由 main.gd 在赛道就绪后调用
func build(cfg: LevelConfig, p_track: Node3D) -> void:
	track = p_track
	if track == null or cfg == null:
		return
	_total_len = maxf(1.0, float(track.call("road_length")))
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var road_half := float(track.call("road_half_width"))
	# 车半宽从"必须留出的缝隙"反推，保证和 ai_opponent.gd 用同一个口径
	var car_half := CAR_WIDTH * 0.5

	# ---- 静态障碍：合并进一个 StaticBody3D ----
	var n_static: int = maxi(0, cfg.obstacle_count)
	if n_static > 0:
		_static_body = StaticBody3D.new()
		_static_body.name = "ObstacleBody"
		_static_body.collision_layer = 1        # 和地面/护栏同层：车会撞到
		_static_body.collision_mask = 0
		add_child(_static_body)
	for i in range(n_static):
		# 沿赛道均匀铺开，再加一点种子化抖动（避免整齐得像栅栏）
		var arc := _total_len * float(i + 1) / float(n_static + 1) + rng.randf_range(-18.0, 18.0)
		arc = fposmod(arc, _total_len)
		var half_w := 0.75 if cfg.obstacle_kind == "barrier" else 0.95
		var lat := _pick_lateral(road_half, half_w, car_half, rng)
		_place_static(arc, lat, half_w, cfg.obstacle_kind, rng)
		obstacles.append({"arc": arc, "lateral": lat, "half_width": half_w,
			"kind": cfg.obstacle_kind, "dynamic_index": -1})

	# ---- 动态障碍：横向来回滑动 ----
	var n_dyn: int = maxi(0, cfg.dynamic_obstacle_count)
	for i in range(n_dyn):
		var arc := _total_len * float(i + 1) / float(n_dyn + 1) + rng.randf_range(-12.0, 12.0)
		arc = fposmod(arc, _total_len)
		var half_w := 0.8
		# 动态路障在一段区间里滑动，滑动范围必须保证最内侧位置也留得出缝隙
		var travel := minf(1.6, maxf(0.8, road_half * 0.35))
		var outermost := road_half - half_w - EDGE_MARGIN
		var center := outermost - travel * 0.5
		# 校验：滑到最内侧时，另一侧还要有足够缝隙
		var innermost := center - travel * 0.5
		var free_other := (innermost - half_w) + road_half
		if free_other < CAR_WIDTH + PASS_EXTRA:
			printerr("[障碍] 动态路障 #%d 会堵死赛道（另一侧只剩 %.2fm < %.2fm），已跳过"
				% [i, free_other, CAR_WIDTH + PASS_EXTRA])
			continue
		_place_dynamic(arc, center, travel, half_w, 0.7 + rng.randf() * 0.5)
		obstacles.append({"arc": arc, "lateral": center, "half_width": half_w,
			"kind": "barrier_dyn", "dynamic_index": _dynamic.size() - 1})

	print("[障碍] 已生成 %d 个静态（合并为 1 个物理节点）+ %d 个动态滑动路障；路宽 %.1fm"
		% [n_static, _dynamic.size(), road_half * 2.0])


## 选一个横向位置：**避开 AI 的巡航走廊**，同时给玩家留出足够缝隙。
## 具体做法：在"路的一侧"选点，优先选远离 AI 车道的那一侧（AI 在 +2.4m，所以选左侧）。
func _pick_lateral(road_half: float, half_w: float, car_half: float, rng: RandomNumberGenerator) -> float:
	var limit := road_half - half_w - EDGE_MARGIN
	if limit <= 0.2:
		return 0.0
	# AI 走廊的左边界
	var ai_left := AI_LANE - AI_LANE_HALF
	# 候选上限 = AI 走廊左侧再留出车身 + 缝隙
	var safe_max := ai_left - car_half - PASS_EXTRA
	if safe_max < 0.0:
		safe_max = 0.0
	var hi := minf(limit, safe_max)
	# 在 [0, hi] 里取点（正数是右侧；取负号放到左边也不影响，这里统一用正数区间
	# 再由符号决定朝哪边，保持"同一侧"以免两个障碍夹住中间）
	var mag := rng.randf_range(0.0, maxf(hi, 0.05))
	return mag


func _place_static(arc: float, lateral: float, half_w: float, kind: String, rng: RandomNumberGenerator) -> void:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var pos := c + side * lateral
	# 碰撞体
	var shape := BoxShape3D.new()
	var h := 1.1 if kind == "barrier" else 0.8
	shape.size = Vector3(half_w * 2.0, h * 2.0, half_w * 2.0)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(pos.x, h, pos.z)
	_static_body.add_child(cs)
	# 视觉
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(half_w * 2.0, h * 2.0, half_w * 2.0)
	mesh.mesh = bm
	mesh.position = Vector3(pos.x, h, pos.z)
	mesh.rotation.y = rng.randf_range(0.0, TAU)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.32, 0.30) if kind == "rock" else Color(0.85, 0.35, 0.12)
	mesh.material_override = mat
	add_child(mesh)


## 动态路障用 AnimatableBody3D：它在 _process 里被脚本挪动，
## Godot 会正确处理"移动的碰撞体推开车"这件事（StaticBody3D 做不到）。
func _place_dynamic(arc: float, center: float, travel: float, half_w: float, speed: float) -> void:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var body := AnimatableBody3D.new()
	body.sync_to_physics = true
	body.collision_layer = 1
	body.collision_mask = 0
	var h := 1.0
	var shape := BoxShape3D.new()
	shape.size = Vector3(half_w * 2.0, h * 2.0, 0.6)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0, h, 0)
	body.add_child(cs)
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(half_w * 2.0, h * 2.0, 0.6)
	mesh.mesh = bm
	mesh.position = Vector3(0, h, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.75, 0.15)
	mesh.material_override = mat
	body.add_child(mesh)
	body.position = c + side * center
	body.rotation.y = atan2(fwd.x, fwd.z)
	add_child(body)
	_dynamic.append({
		"node": body, "arc": arc, "center": center, "travel": travel,
		"half_width": half_w, "speed": speed, "phase": 0.0,
		"side": side, "base": c,
	})


func _process(delta: float) -> void:
	if _dynamic.is_empty():
		return
	for d in _dynamic:
		var it: Dictionary = d
		it["phase"] = float(it["phase"]) + delta * float(it["speed"])
		# 正弦往复：位置连续、不会瞬移，避免把贴着的车弹飞
		var off := sin(float(it["phase"])) * float(it["travel"]) * 0.5
		var node: AnimatableBody3D = it["node"]
		node.position = it["base"] + (it["side"] as Vector3) * (float(it["center"]) + off)


## 给 AI 用：返回"在 arc 前方 horizon 米内、这条车道是否被障碍挡住"，
## 若挡住则返回一个可用的替代车道偏移；否则原样返回 current_lane。
##
## 这是必要的，因为 AI 只巡线、不做避障。与其让它一头撞上去再靠自救脱困，
## 不如在接近时换到空的那一侧 —— 也让 AI 看起来"会闪"。
func clear_lane_for(arc: float, horizon: float, current_lane: float, car_half: float) -> float:
	if obstacles.is_empty():
		return current_lane
	var lane := current_lane
	for o in obstacles:
		var it: Dictionary = o
		var d := fposmod(float(it["arc"]) - arc, _total_len)
		if d > horizon:
			continue
		var olat := float(it["lateral"])
		var ohalf := float(it["half_width"])
		if absf(olat - lane) >= ohalf + car_half + 0.35:
			continue        # 这条车道是通的
		# 被挡住：换到障碍的另一侧
		var road_half := float(track.call("road_half_width"))
		var left_room := (olat - ohalf) + road_half      # 障碍左侧可用宽度
		var right_room := road_half - (olat + ohalf)     # 障碍右侧可用宽度
		var need := car_half * 2.0 + PASS_EXTRA
		if left_room >= right_room and left_room >= need:
			lane = olat - ohalf - car_half - 0.35
		elif right_room >= need:
			lane = olat + ohalf + car_half + 0.35
		# 夹到路面内
		lane = clampf(lane, -(road_half - car_half - 0.2), road_half - car_half - 0.2)
	return lane


func obstacle_count() -> int:
	return obstacles.size()


func dynamic_count() -> int:
	return _dynamic.size()


## 供小地图用：返回每个障碍**当前**的世界坐标 + 是否在动。
## 动态路障的位置每帧都在变，所以必须实时取节点位置，不能缓存 arc/lateral。
func marker_positions() -> Array:
	var out: Array = []
	for o in obstacles:
		var it: Dictionary = o
		var di := int(it.get("dynamic_index", -1))
		if di >= 0 and di < _dynamic.size():
			var node: Node3D = (_dynamic[di] as Dictionary)["node"]
			out.append({"pos": node.position, "dynamic": true})
		else:
			var arc := float(it["arc"])
			var c: Vector3 = track.call("centerline_point", arc)
			var fwd: Vector3 = track.call("centerline_forward", arc)
			var side := Vector3(fwd.z, 0.0, -fwd.x)
			out.append({"pos": c + side * float(it["lateral"]), "dynamic": false})
	return out
