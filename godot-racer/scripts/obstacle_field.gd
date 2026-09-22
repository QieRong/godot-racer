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
## 关于 AI：静态障碍的横向位置**刻意避开 AI 的巡航车道**（见 `_pick_lateral()`），
## 因为这条走廊是 AI 的默认行驶线。但**"避开巡航道"不等于"AI 不会撞上"**：
## AI 为了躲动态滑动路障会临时换道，换到的位置完全可能正好压在静态障碍上
## （L4 实测：静态石头全落在中心线 ±0.125m 内，动态路障一扫过 AI 车道，
## AI 就往中心线闪避 → 骑上石头 → 卡死）。
## 所以占用判定必须由 `pick_clear_lane()` 对**全部**障碍统一做，见该函数的注释。

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
## 判定"某条车道是否被障碍占用"时，在"车半宽 + 障碍半宽"之外再加的余量（米）。
## 与旧 `clear_lane_for()` 里的 0.35 同一个口径，只是现在**统一成一个常量**，
## 免得"生成障碍时算一次、AI 查询时又按另一个值算"这种无声漂移。
const OBSTACLE_MARGIN := 0.35
## 换道后，车与障碍之间要留的额外横向余量（米）。
## 比 OBSTACLE_MARGIN 略小：候选车道是"贴着障碍边缘生成"的，
## 若两个值相等，生成的候选点会正好落在占用边界上（`<` 判据下勉强通过，余量为 0）。
const LANE_MARGIN := 0.25

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


## 占用该车道的**最近**障碍还有多远（米）；没有则返回 -1。
## 用途：AI 找不到安全车道时，按这个距离决定"减速等待"要等到哪一点。
func nearest_blocker_dist(lane: float, arc: float, horizon: float, car_half: float) -> float:
	var band := car_half + OBSTACLE_MARGIN
	var best := -1.0
	for o in obstacles:
		var it: Dictionary = o
		if not _occupies(it, lane, arc, horizon, band):
			continue
		var d := fposmod(float(it["arc"]) - arc, _total_len)
		if best < 0.0 or d < best:
			best = d
	return best


## 某个障碍**当前**的横向位置（米，正数 = 赛道前进方向的右侧）。
##
## ⚠ 为什么不能直接用 `obstacles[i]["lateral"]`：动态滑动路障的横向位置**每帧都在变**
##   （`_process` 里按正弦往复），而 `lateral` 存的是它的**行程中心**。
##   拿中心当位置会让 AI 在相位错开时算错最多 ±travel/2 米 —— L4 的 travel=1.6m，
##   也就是 0.8m，比"车半宽 + 余量"还大，足以把"其实挡住了"判成"没挡"。
func real_lateral(o: Dictionary) -> float:
	var di := int(o.get("dynamic_index", -1))
	if di >= 0 and di < _dynamic.size():
		var node: Node3D = (_dynamic[di] as Dictionary)["node"]
		return _lateral_of(node.global_position)
	return float(o["lateral"])


## 世界坐标 → 该点相对中心线的横向偏移（米）。
## 口径与 ai_opponent._avoid_player_lane / 车道定义完全一致（forward 的右侧为正）。
func _lateral_of(pos: Vector3) -> float:
	if track == null or not track.has_method("nearest_on_centerline"):
		return 0.0
	var near: Dictionary = track.call("nearest_on_centerline", pos, -1.0)
	var c: Vector3 = near.get("pos", pos)
	var fwd: Vector3 = near.get("forward", Vector3.FORWARD)
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	return (pos - c).dot(side)


## 该车道在 [arc, arc+horizon] 上是否被**任意**障碍占用。
##
## 这是"候选车道必须真正验证安全"的判定本体：用**当前实际横向位置**（动态路障每帧在动），
## 并且**逐个障碍**检查 —— 只看第一个挡路的障碍、挪一下就以为通了，正是 L4 卡死的成因。
func lane_blocked(lane: float, arc: float, horizon: float, car_half: float) -> bool:
	var band := car_half + OBSTACLE_MARGIN
	for o in obstacles:
		if _occupies(o, lane, arc, horizon, band):
			return true
	return false


## 找出 [arc, arc+horizon] 内占用该车道的**全部**障碍，按距离升序。
## 每项：{lateral, half_width, kind, dist, dynamic}
func blockers_for(lane: float, arc: float, horizon: float, car_half: float) -> Array:
	var band := car_half + OBSTACLE_MARGIN
	var out: Array = []
	for o in obstacles:
		var it: Dictionary = o
		if not _occupies(it, lane, arc, horizon, band):
			continue
		out.append({
			"lateral": real_lateral(it),
			"half_width": float(it["half_width"]),
			"kind": String(it["kind"]),
			"dist": fposmod(float(it["arc"]) - arc, _total_len),
			"dynamic": int(it.get("dynamic_index", -1)) >= 0,
		})
	out.sort_custom(func(a, b): return float(a["dist"]) < float(b["dist"]))
	return out


func _occupies(o: Dictionary, lane: float, arc: float, horizon: float, band: float) -> bool:
	var it: Dictionary = o
	var d := fposmod(float(it["arc"]) - arc, _total_len)
	if d < 0.0 or d > horizon:
		return false
	var dlat := absf(real_lateral(it) - lane)
	return dlat < float(it["half_width"]) + band


## 给 AI 用的换道方案：在车道上找一个"整段 [arc, arc+horizon] 全通"的候选车道。
##
## 与旧的 `clear_lane_for()` 的三个关键区别（L4 卡死就是旧写法的直接后果）：
##   ① **看全部障碍**、并且要求候选车道对 horizon 内**每一个**障碍都通
##      （旧写法只看第一个挡路的，挪一下就走）；
##   ② 用**实时**横向位置（旧写法用动态路障的行程中心，相位错开时最多错 0.8m）；
##   ③ 找不到安全车道时返回 `{"found": false}`，由 AI 自己去**减速等待**，
##      而不是硬塞一个照样会撞的车道进去。
##
## `prefer_lane`：优先尝试的车道（通常是"避让玩家之后想要的那条"）；
## 候选按"离 prefer_lane 最近的先试"排序，所以能不动就不动。
##
## 离开道路的候选会被 `lane_limit` 夹掉 —— 那属于"赛道边界"这一项占用，
## 不需要再单独判定一次碰撞。
func pick_clear_lane(prefer_lane: float, arc: float, horizon: float,
		car_half: float, lane_limit: float) -> Dictionary:
	if obstacles.is_empty():
		return {"found": true, "lane": prefer_lane}
	var lim := maxf(0.0, lane_limit)
	var cands: Array = [clampf(prefer_lane, -lim, lim)]
	# 候选来源：障碍的两侧"刚好够宽"的空位 + 路两侧的边线。
	# 刻意**不**硬编码任何关卡数值 —— 全部由障碍实际位置与路宽推出来。
	for o in obstacles:
		var it: Dictionary = o
		var d := fposmod(float(it["arc"]) - arc, _total_len)
		if d > horizon:
			continue
		var lat := real_lateral(it)
		var hw := float(it["half_width"])
		cands.append(lat - hw - car_half - LANE_MARGIN)
		cands.append(lat + hw + car_half + LANE_MARGIN)
	cands.append(-lim)
	cands.append(lim)
	# 去重 + 按"离 prefer_lane 近"排序：能保持当前车道就不动。
	var uniq: Array = []
	for c in cands:
		var v := clampf(float(c), -lim, lim)
		var dup := false
		for u in uniq:
			if absf(float(u) - v) < 0.05:
				dup = true
				break
		if not dup:
			uniq.append(v)
	uniq.sort_custom(func(a, b): return absf(a - prefer_lane) < absf(b - prefer_lane))
	for v in uniq:
		if not lane_blocked(float(v), arc, horizon, car_half):
			return {"found": true, "lane": float(v)}
	return {"found": false, "lane": prefer_lane}


## 诊断用（`--check=opponents` 的卡死自救里调用）：把 horizon 内的障碍逐条摊开。
## 为什么需要：卡死日志里只有"坐标 + 离中心线"，区分不了
## 「车道算错了」和「车道对、但横向位置是过期数据」—— 这两种修法完全不同。
func debug_ahead(arc: float, horizon: float, lane: float, car_half: float) -> Array:
	var band := car_half + OBSTACLE_MARGIN
	var out: Array = []
	for o in obstacles:
		var it: Dictionary = o
		var d := fposmod(float(it["arc"]) - arc, _total_len)
		if d < 0.0 or d > horizon:
			continue
		var lat := real_lateral(it)
		var hw := float(it["half_width"])
		out.append("%s arc=%.1f 前方%.1fm 实时横向=%+.2f 半宽=%.2f 与车道%+.2f 的横向差=%+.2f（占用阈值 %.2f）→ %s"
			% [String(it["kind"]), float(it["arc"]), d, lat, hw, lane, lat - lane, hw + band,
			   "占用" if absf(lat - lane) < hw + band else "通行"])
	return out


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
