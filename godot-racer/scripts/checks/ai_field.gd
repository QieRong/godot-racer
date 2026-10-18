extends RefCounted
## AI×场地交互验收族（`--check=avoid` / `obstacles`）：避让玩家路障、
## 障碍物位置与碰撞与通行缝隙。main.gd 的 `match _check:` 分发口经
## `await _checks_ai_field.run_avoid()` / `_checks_ai_field.run_obstacles()` 进入本模块。
##
## 2026-10-18 SPLIT-CHECKS-AI-006：从 scripts/checks/ai.gd 二次拆出，**纯迁移、
## 行为零变化** —— 两个函数连注释逐字节照搬（avoid / obstacles 的日志 A/B 要逐行
## 比对），没有第二份实现。
## 为什么拆：Phase 01（同步发车）给 ai.gd 增加了 85 行（free-run 测量窗口 +
## aistart/aidiag 新语义），937 → 1022 行，越过「单文件 ≤1000 行」契约
## （AGENTS §2.4：越限一律先拆再提交）。avoid 与 obstacles 的共同点是**都读场地**
## （一个把玩家当路障摆在 AI 车道前、一个查障碍场几何/碰撞/通行缝隙），与 ai.gd
## 剩余三族（对手跑圈 / 诊断 / 并排发车，都读对手与发车状态）关注点不同，
## 拆开面自然，不需要造新抽象。
## 迁了什么：
##   · 2 个函数：`run_avoid` / `run_obstacles`（原样照搬；本族没有内部辅助函数，
##     两个入口一一对应、可 audit）；
##   · 0 个常量：这两个函数不读任何 AI_* 判据常量（阈值全是函数内局部量，
##     如车宽 1.75 / 接触余量 0.05 / 绕行 0.35 / 缝隙 0.5）—— 已 grep 实证；
##   · 注入面 6 个：车 / 赛道 / 障碍场 / 对手生成实例 / 物理世界 / physics_frame。
##
## ⚠ 三处关键决策（逐条定死，以后别悄悄改回去）：
##
##   ① **车 / 赛道 / 障碍场 / 物理世界经 setup() 注入，模块不 get_node**：
##      与 ai.gd 决策①同款（§2.4：禁反向持有场景）。`get_world_3d()` 由 main
##      递入 World3D 本体，`.direct_space_state` 仍在**原来那一行**取
##      （不预取快照，时序零变化）。
##
##   ② **physics_frame 经 Callable 注入**：迁移前（函数体还在 main.gd / ai.gd 时）
##      帧循环里是 `await get_tree().physics_frame`；模块是 RefCounted、不在场景树上，
##      没有 get_tree()，由 main 把 `_shot_physics_frame`（返回 physics_frame 信号本体）
##      以 Callable 递进来。模块里 `await _physics_frame.call()` 与迁移前
##      `await get_tree().physics_frame` 是**同一个 Signal**，协程恢复时机不变
##      （ai.gd 决策②同款，2026-10-13 实证）。
##
##   ③ **await 数 = 2，一拍不加**：全在 `run_avoid` 的两处帧循环（先跑 2s 让 AI
##      稳定在车道上 + 观察 14s 绕过全过程）。`run_obstacles` 是纯几何 + 射线查询、
##      **零 await**（所以 main.gd 分发口对它是同步调用；调用点加 await 会报
##      REDUNDANT_AWAIT，2026-10-18 实测）。协程深度与迁移前一致 ——
##      多一层协程 = physics_frame 恢复时机差 1 物理帧 → 日志发散
##      （ai.gd 决策④，opponent_spawner 实证 25856 行）。
##
## ⚠ 为什么没有 class_name（与十三个先例模块同一约定）：验收闸门在**无编辑器**环境
##   跑 Godot，全局类缓存（.godot/global_script_class_cache.cfg）只有编辑器会重建；
##   2026-10-12 实测新增 class_name 后 `--check-only` 与游戏运行双双报
##   `Identifier not declared`。消费方一律
##   `const ChecksAiField := preload("res://scripts/checks/ai_field.gd")`。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car = $RaceCar）。avoid 把它当成"路障"摆到 AI 车道前
## （用完 reset_to_track 放回赛道）。字段名沿用 main 的成员名 → 族内代码零 diff。
var _car: VehicleBody3D = null
## 赛道（迁移前是 _check_* 里 get_node_or_null("Track") 的静态兄弟节点）。由 setup() 注入。
var _track: Node = null
## 障碍物场（main.gd 的 _obstacle_field；无障碍关卡为 null）。由 setup() 注入。
## ⚠ run_obstacles 的 null 检查保留原语义：无障碍关卡打印"本来就没有障碍"后
##   正常跳过（⊘），不是错误。
var _obstacle_field: Node3D = null
## 对手生成模块**实例本身**（main.gd 的 _opponent_spawner）：_opponents / armed
## 状态都在它身上（SPLIT-OPPONENT-001）。avoid 要 arm_opponents() 把 AI 先跑起来，
## 第二份实例会拿到空状态、A/B 与取证全部失真。
var _opponent_spawner = null
## 本关物理世界（main.gd 的 get_world_3d()）：run_obstacles 的射线探针要
## direct_space_state。注入 World3D 而不是趁手的节点 —— 模块仍不认识场景树，
## 且 `.direct_space_state` 仍在**原来的那一行**取（不预取快照，时序零变化）。
var _world_3d: World3D = null
## physics_frame 信号提供者（main.gd 的 _shot_physics_frame）。由 setup() 注入；
## 模块里 `await _physics_frame.call()` 取代 `await get_tree().physics_frame`，
## 是同一个 Signal，协程恢复时机不变（文件头决策 ②③）。
var _physics_frame: Callable = Callable()

# ---------------------------------------------------------------- 只读代理（真身在 _opponent_spawner）
## 本关的 AI 对手（ai_opponents 台）。空数组 = 本关没有对手。
## ⚠ 只读代理：真身在 _opponent_spawner.opponents（SPLIT-OPPONENT-001）。保留同名
## 可以让派生的族内代码零 diff，也杜绝"两边各存一份数组"的漂移（与 ai.gd 的同名
## 代理同一约定，见 opponent_spawner.gd 文件头决策 ①）。
var _opponents: Array:
	get:
		return _opponent_spawner.opponents


## 注入外部引用（main.gd 在 _after_world_ready 里障碍物与自动驾驶都接好之后调用一次）。
##
## ⚠ 为什么必须在 `_build_obstacles` **之后**：run_obstacles 要查障碍场几何、
## avoid 要把玩家摆上 AI 车道（AI 摆车道也要查障碍），早注入只会拿到 null
## （与拆分前 ai.gd setup 同款约束）。
func setup(car: VehicleBody3D, track: Node, obstacle_field: Node3D,
		opponent_spawner, world_3d: World3D, physics_frame: Callable) -> void:
	_car = car
	_track = track
	_obstacle_field = obstacle_field
	_opponent_spawner = opponent_spawner
	_world_3d = world_3d
	_physics_frame = physics_frame


## AI 避让玩家验收：**把玩家当成路障摆在 AI 的车道上，AI 必须绕过去且不撞上**。
##
## 为什么要这么测：避让逻辑最容易做成"看起来在躲"但实际还是蹭上了。
## 所以判据必须是硬的：
##   ① AI 与玩家之间**始终**保持 ≥ 车身净距（记录全程最小中心距）；
##   ② AI 的横向位置确实发生了偏移（真的绕了，而不是刚好错开）；
##   ③ AI 最终超过了玩家的位置（绕过去继续跑，而不是停下僵住）。
func run_avoid() -> void:
	if _opponents.is_empty():
		print("[自检] 本关没有对手，避让验收 ⊘ 跳过")
		return
	if _car == null:
		printerr("[自检] 没有玩家车，避让验收无法进行")
		return
	var ai: Node = _opponents[0]
	var track := _track
	var hz := float(Engine.physics_ticks_per_second)
	# 先把对手发车、跑起来
	_opponent_spawner.arm_opponents()
	var ai_lane := float(ai.get("lane_offset"))
	print("[自检] 避让验收：把玩家当成路障摆在 AI 车道（横向 %+.2fm）前方，看 AI 会不会绕开" % ai_lane)
	# 让 AI 先跑起来并稳定在它的车道上
	for i in range(int(hz * 2.0)):
		await _physics_frame.call()
	var ai_arc_before := float(ai.call("progress"))
	# 把玩家摆到 AI 前方 28m、正好在 AI 的车道上（= 挡住它）
	var ai_arc := 0.0
	var ai_near: Dictionary = track.call("nearest_on_centerline", ai.global_position, -1.0)
	ai_arc = float(ai_near.get("arc", 0.0))
	var block_arc := fposmod(ai_arc + 28.0, float(track.call("road_length")))
	var c: Vector3 = track.call("centerline_point", block_arc)
	var fwd: Vector3 = track.call("centerline_forward", block_arc)
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	_car.global_position = c + side * ai_lane + Vector3(0, 0.6, 0)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	_car.set("auto_recover", false)     # 别让兜底把"路障"搬走
	print("[自检]   玩家路障已就位：弧长 %.1f（AI 前方 28m），横向 %+.2fm" % [block_arc, ai_lane])
	# 观察 AI 接近并绕过的全过程
	var min_dist := 1e9
	var max_lat_dev := 0.0
	var passed := false
	var contact_frames := 0
	var blocked_pos: Vector3 = c + side * ai_lane
	var frames := int(hz * 14.0)
	for i in range(frames):
		await _physics_frame.call()
		# ⚠ 这里必须写显式类型：ai 是 Node（_opponents 是 Array），
		# 它的 global_position 是 Variant，用 := 推断会直接解析失败
		# （报 "Cannot infer the type of d"），进而让整个 main.gd 加载不了。
		# 和 load().new() 那个坑是同一类问题。
		var d: float = ai.global_position.distance_to(_car.global_position)
		min_dist = minf(min_dist, d)
		# AI 相对中心线的横向偏移，用来判断"有没有真的绕"
		var an: Dictionary = track.call("nearest_on_centerline", ai.global_position, -1.0)
		var ac: Vector3 = an.get("pos", ai.global_position)
		var afwd: Vector3 = an.get("forward", Vector3.FORWARD)
		var aside := Vector3(afwd.z, 0.0, -afwd.x)
		var a_lat: float = (ai.global_position - ac).dot(aside)
		max_lat_dev = maxf(max_lat_dev, absf(a_lat - ai_lane))
		# 通过判定：AI 的弧长跑到了玩家路障之后
		var prog := fposmod(float(an.get("arc", 0.0)) - block_arc, float(track.call("road_length")))
		if prog > 12.0 and prog < 180.0:
			passed = true
			break
		# 接触判定：中心距小于车身净距就说明蹭上了
		if d < 1.75 + 0.05:
			contact_frames += 1
	_car.set("auto_recover", true)
	# 把玩家放回赛道，别影响后续
	_car.call("reset_to_track")
	var gap := min_dist - 1.75
	print("[自检]   结果：全程最小中心距 %.2fm（净距 %+.2fm，车宽 1.75）；最大横向绕行 %.2fm；通过=%s"
		% [min_dist, gap, max_lat_dev, str(passed)])
	var ok := true
	if contact_frames > 0:
		printerr("[自检]   ✘ 发生了 %d 帧车身重叠（中心距 < 1.75m）—— 撞上了，没有真的避开"
			% contact_frames)
		ok = false
	else:
		print("[自检]   ✔ 全程没有车身重叠")
	if max_lat_dev < 0.35:
		printerr("[自检]   ✘ 横向只让开 %.2fm，看不出「绕行」（可能只是刚好没撞）" % max_lat_dev)
		ok = false
	else:
		print("[自检]   ✔ 确实横向让开了 %.2fm" % max_lat_dev)
	if not passed:
		printerr("[自检]   ✘ 14 秒内 AI 没能绕过玩家路障（可能停住僵住了）")
		ok = false
	else:
		print("[自检]   ✔ AI 成功绕过玩家路障继续行驶")
	if ok:
		print("[自检] 避让验收 ✔ AI 会主动绕开玩家，且不接触")
	else:
		printerr("[自检] 避让验收 ✘ 见上方 ✘ 行")


## 障碍物验收。三个必须成立的事实：
##   ① 每个障碍都在**路面内**（不是悬在草地上或埋在护栏里）；
##   ② 每个障碍**真的有碰撞**（用射线打它，必须命中 —— 只建了视觉不算数）；
##   ③ 任何时刻都给车留出 ≥ 车宽+0.5m 的通行缝隙（否则赛道被堵死，`--check=lap` 会报废）；
## 外加性能红线：静态障碍的物理节点必须**合并成 1 个**。
func run_obstacles() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	if _obstacle_field == null:
		var cfg0: LevelConfig = GameState.current_level()
		print("[自检] 本关「%s」obstacle_count=%d dynamic=%d，本来就没有障碍，验收 ⊘ 跳过"
			% [cfg0.display_name if cfg0 != null else "?",
			   cfg0.obstacle_count if cfg0 != null else 0,
			   cfg0.dynamic_obstacle_count if cfg0 != null else 0])
		return
	var space := _world_3d.direct_space_state
	var road_half := float(track.call("road_half_width"))
	var rail_half := float(track.call("rail_half_width"))
	var obstacles: Array = _obstacle_field.get("obstacles")
	var ok := true
	print("[自检] 障碍物验收：共 %d 个（动态 %d 个）；路面半宽 %.2fm，护栏 %.2fm"
		% [obstacles.size(), int(_obstacle_field.call("dynamic_count")), road_half, rail_half])

	# ---- ① 位置是否在路面内 ----
	var out_of_road := 0
	for o in obstacles:
		var it: Dictionary = o
		var lat := absf(float(it["lateral"]))
		var half_w := float(it["half_width"])
		if lat + half_w > road_half + 0.01:
			out_of_road += 1
			printerr("[自检]   ✘ %s 外沿 %.2fm 超出路面半宽 %.2fm"
				% [it["kind"], lat + half_w, road_half])
	if out_of_road == 0:
		print("[自检]   ✔ 全部障碍都在路面内")
	else:
		ok = false

	# ---- ② 是否真的有碰撞（射线探针，硬证据）----
	var missed := 0
	for i in range(obstacles.size()):
		var it: Dictionary = obstacles[i]
		var arc := float(it["arc"])
		var c: Vector3 = track.call("centerline_point", arc)
		var fwd: Vector3 = track.call("centerline_forward", arc)
		var side := Vector3(fwd.z, 0.0, -fwd.x)
		var center := c + side * float(it["lateral"])
		# 从上方 3m 垂直往下打
		var q := PhysicsRayQueryParameters3D.create(center + Vector3(0, 3.0, 0), center)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			missed += 1
			printerr("[自检]   ✘ 第 %d 个障碍（%s @弧长 %.1f）射线没打到碰撞体 —— 只有视觉没有碰撞"
				% [i, it["kind"], arc])
	if missed == 0:
		print("[自检]   ✔ 全部 %d 个障碍都被射线命中（碰撞真实存在）" % obstacles.size())
	else:
		ok = false

	# ---- ③ 通行缝隙：每个障碍所在弧长处，必须还剩 ≥ 车宽+0.5m ----
	var blocked := 0
	var car_width := 1.75
	var need := car_width + 0.5
	for o in obstacles:
		var it: Dictionary = o
		var lat := float(it["lateral"])
		var half_w := float(it["half_width"])
		# 障碍把路面切成左右两块，取较大的一块作为可通行宽度
		var left_room := road_half - (lat + half_w)
		var right_room := (lat - half_w) + road_half
		var best := maxf(left_room, right_room)
		if best < need:
			blocked += 1
			printerr("[自检]   ✘ 弧长 %.1fm 处可通行宽度只有 %.2fm < %.2fm（会堵死赛道）"
				% [float(it["arc"]), best, need])
	if blocked == 0:
		print("[自检]   ✔ 每个障碍处都留出了 ≥ %.2fm 的通行缝隙（车宽 %.2f + 0.5）" % [need, car_width])
	else:
		ok = false

	# ---- ④ 性能：静态障碍必须合并成 1 个物理节点 ----
	# ⚠ 必须排除 AnimatableBody3D：它在 Godot 里**继承自 StaticBody3D**，
	# 用 `c is StaticBody3D` 会把动态路障也算进来，于是"合并成 1 个"这条
	# 明明满足了却被误判成违反性能红线（实测 6 静态+2 动态 报成 3 个节点）。
	var holder := _obstacle_field
	var bodies := 0
	if holder != null:
		for c in holder.get_children():
			if c is StaticBody3D and not (c is AnimatableBody3D):
				bodies += 1
	print("[自检]   静态障碍物理节点数 = %d（必须为 1；动态路障是 AnimatableBody3D，不计）" % bodies)
	if bodies > 1:
		printerr("[自检]   ✘ 静态障碍没有合并，违反性能红线")
		ok = false
	elif bodies == 1:
		print("[自检]   ✔ 静态障碍已合并为单个物理节点")

	# ---- ⑤ 动态路障滑动时也不能堵死 ----
	var dyn_ok := true
	for i in range(int(_obstacle_field.call("dynamic_count"))):
		var dyn: Array = _obstacle_field.get("_dynamic")
		if i >= dyn.size():
			break
		var d: Dictionary = dyn[i]
		var travel := float(d["travel"])
		var center := float(d["center"])
		var half_w := float(d["half_width"])
		# 最靠路中间的位置 = center - travel/2
		var innermost := center - travel * 0.5
		var free_other := (innermost - half_w) + road_half
		if free_other < need:
			dyn_ok = false
			printerr("[自检]   ✘ 动态路障 #%d 滑到最内侧时另一侧只剩 %.2fm < %.2fm"
				% [i, free_other, need])
	if _obstacle_field.call("dynamic_count") > 0:
		if dyn_ok:
			print("[自检]   ✔ 动态路障的滑动范围不会堵死赛道")
		else:
			ok = false

	if ok:
		print("[自检] 障碍物验收 ✔ 位置/碰撞/通行缝隙/合并节点 全部通过")
	else:
		printerr("[自检] 障碍物验收 ✘ 见上方 ✘ 行")
