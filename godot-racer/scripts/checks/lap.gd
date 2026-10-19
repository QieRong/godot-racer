extends RefCounted
var _evidence = preload("res://scripts/checks/evidence.gd").new()
## 跑圈 / 压测 / 反向验收族（`--check=lap` / `stress` / `reverse`）：验收自动驾驶跑圈
## （圈速 + 车头方向 + 卡住事件 + 掉头纠正演练，含 [DEBUG-L4] 时间线取证）、本地确定性鲁莽
## 玩家压测、方向反向提示（6 条纯函数用例 + 真车端到端）。main.gd 的 `match _check:` 分发口经
## `await _checks_lap.run_lap()` / `run_stress()` / `run_reverse()` 进入本模块。
##
## 2026-10-14 SPLIT-CHECKS-BASIC-005b：从 scenes/main.gd 整块拆出，**纯迁移、行为零变化**
## —— 逻辑、print 文案（`[自检]` 前缀、缩进、✔/✘ 判定行、%占位顺序全部照搬，A/B 要逐行
## 比对日志）、注释全部照搬，没有第二份实现。
## 迁了什么：`_check_lap` → 公开入口 `run_lap`、`_check_stress` → `run_stress`、
## `_check_reverse` → `run_reverse`；私有 helper 保持原名与私有性：`_reset_loop_hit` /
## `_reverse_call` / `_rev_dot` / `_reverse_case` / `_check_reverse_e2e` / `_find_wrong_way_panel`。
## ⚠ `_find_wrong_way_panel` 随**本族**迁入（**与计划书把它放 basic 相反** —— 它只被
## `_check_reverse_e2e` 调用，计划书的 helper 归属与实际调用方向交叉，放消费方一侧避免两模块
## 互相注入对方 Callable 形成环，或被迫复制第二份）。
##
## ⚠ 三条关键决策（逐条定死，以后别悄悄改回去）：
##
##   ① **车 / 赛道 / [DEBUG-L4] 诊断 / 自动驾驶 / 障碍场 / 对手生成 / env_phys 模块经
##      setup() 注入，模块不 get_node**：迁移前各 `_check_*` 入口用
##      `get_node_or_null("Track")` 取静态兄弟节点，改为注入 + 保留原 null 检查
##      （§2.4：禁反向持有场景；layout / bench / ai / env_phys 同款约定）。玩家车沿用
##      `_car` 字段名（main.gd 成员同名），注入后族内代码零 diff。
##      ⚠ `_l4_diag` / `_autopilot` / `_opponent_spawner` / `_checks_envphys` 注入的是
##      **main 持有的那一个实例**（诊断状态 / 驾驶状态 / 对手数组 / 卡住取证全在实例上，
##      preload 第二份会拿到空状态，A/B 与取证全部失真 —— 同 ai.gd / env_phys 的注入约定）。
##      `_opponents` 是只读代理（真身在 `_opponent_spawner`，§5.3 不复制第二份数组）。
##
##   ② **frame 信号与场景能力经注入提供**：迁移前帧循环里是 `await get_tree().physics_frame`；
##      模块是 RefCounted、不在场景树上，没有 get_tree()。照 env_phys / bench / ai 约定，把
##      `physics_frame` 经 main 的 `_shot_physics_frame`（返回 physics_frame 信号本体）以
##      Callable 递入，模块里 `await _physics_frame.call()` 与迁移前
##      `await get_tree().physics_frame` 是**同一个 Signal**，协程恢复时机不变
##      （opponent_spawner 实证：多一层协程 = physics_frame 恢复差 1 物理帧 = 25856 行日志
##      发散）。另有 1 个「场景能力」Callable：`_add_child`（`run_stress` 要把鲁莽玩家
##      driver 挂进场景树，同 opponent_spawner 的 mount 回调约定）。非信号的 tree 能力
##      （分组查询等）走注入的 `SceneTree` 引用 —— 与 ai.gd 注入 `World3D` 同属「注入引擎
##      对象而非场景节点」，不是 get_node、也不反向持有场景（§2.4）。
##
##   ③ **await 数 = 8，一拍不加**：迁移前本族真实 await 8 处 —— 6 处帧循环的 physics_frame
##      （注入后为 `await _physics_frame.call()`：run_lap 3 / run_reverse_e2e 3）+ 1 处
##      `await driver.call("stress_test", dur)`（run_stress 内，本族私有 driver）+ 1 处
##      `await _check_reverse_e2e(cfg)`（run_reverse 内，本族私有）。main.gd 分发口的
##      `await _checks_lap.run_*()` 留在 main 自己那层协程 —— 协程深度与迁移前一致。由
##      split-checks-lap-structcheck.ps1 把这些形态钉死。
##
## ⚠ `REVERSE_CASES` 是 ADR-001 永久居民（check-docs.ps1 直接从 main.gd 原文取值），
##   **不随本族外迁**，由 setup() 注入（§5.3 单一来源）；本模块**不得**再定义第二份。
##   `LAYOUT_ELEV_CASES` / `LAYOUT_RACING_CASES` 同属永久居民，随各自模块 setup 注入。
##
## ⚠ GameState / Input / Engine 直接读全局（layout.gd / bench.gd 同款先例）：GameState 是
##   autoload 单例、不是场景节点，直连不违反「禁反向持有场景」。`Autopilot.pose_facing` 是
##   static func，无状态可直调（§2.4 约定）。
##
## ⚠ 为什么没有 class_name（与全部先例模块同一约定）：验收闸门在**无编辑器**环境跑
##   Godot，全局类缓存（.godot/global_script_class_cache.cfg）只有编辑器会重建；
##   2026-10-12 实测新增 class_name 后 `--check-only` 与游戏运行双双报
##   `Identifier not declared`。消费方一律
##   `const ChecksLap := preload("res://scripts/checks/lap.gd")`。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car = $RaceCar）。字段名沿用 main 的成员名 → 族内代码零 diff。
var _car: VehicleBody3D = null
## 赛道（迁移前是各 _check_* 里 get_node_or_null("Track") 的静态兄弟节点）。由 setup() 注入。
var _track: Node = null
## HUD CanvasLayer（迁移前是 `_find_wrong_way_panel` 里 get_node_or_null("HUD")）。由 setup() 注入。
var _hud: CanvasLayer = null
## [DEBUG-L4] 诊断模块（run_lap 的时间线/撞车/卡住/汇总只读记账）。注入 main 持有实例。
var _l4_diag = null
## 自动驾驶模块（run_lap 的追线 / 恢复 / 摆位）。注入 main 持有实例（状态在实例上）。
var _autopilot = null
## 障碍物场（run_lap 卡住时列前方障碍）。由 setup() 注入（与 main 的 _obstacle_field 同一节点）。
var _obstacle_field: Node3D = null
## 对手生成模块（run_lap 只读对手数组）。注入 main 持有实例（状态在实例上）。
var _opponent_spawner = null
## 对手数组只读代理：真身在 _opponent_spawner（不复制第二份数组，§5.3）。
var _opponents: Array:
	get:
		return _opponent_spawner.opponents
## env_phys 验收模块（run_lap 卡住时调 probe_blocker() 做取证）。注入 main 持有实例。
var _checks_envphys = null
## 场景树（非信号能力：分组查询等）。由 setup() 注入。
var _tree: SceneTree = null
## physics_frame 信号提供者（main.gd 的 _shot_physics_frame）。由 setup() 注入；
## 模块里 `await _physics_frame.call()` 取代 `await get_tree().physics_frame`，
## 是同一个 Signal，协程恢复时机不变（文件头决策 ②③）。
var _physics_frame: Callable = Callable()
## 把节点挂进场景树的能力（run_stress 的 driver）。场景能力 Callable 注入，见文件头决策 ②。
var _add_child: Callable = Callable()
## 反向用例总条数（ADR-001 永久居民 REVERSE_CASES，经 setup() 注入，不在本模块复制第二份）。
var _reverse_cases_total := 0
## 反向纯函数用例：已跑 / 已失败（本族原实现就有，随迁）。
var _reverse_cases := 0
var _reverse_failed := 0
## 摆位纯函数（static func pose_facing，无状态可直调，§2.4 约定）。
const Autopilot := preload("res://scripts/autopilot.gd")


## 注入外部引用（main.gd 在 _after_world_ready 里调用一次）。
func setup(car: VehicleBody3D, track: Node, hud: CanvasLayer, l4_diag, autopilot,
		obstacle_field: Node3D, opponent_spawner, checks_envphys, tree: SceneTree,
		physics_frame: Callable, add_child: Callable, reverse_cases: int, evidence = null) -> void:
	if evidence != null:
		_evidence = evidence
	_car = car
	_track = track
	_hud = hud
	_l4_diag = l4_diag
	_autopilot = autopilot
	_obstacle_field = obstacle_field
	_opponent_spawner = opponent_spawner
	_checks_envphys = checks_envphys
	_tree = tree
	_physics_frame = physics_frame
	_add_child = add_child
	_reverse_cases_total = reverse_cases


# ======================== 跑圈验收（--check=lap）========================
#
func run_lap() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		_evidence.branch("lap.run_lap.001", "FAIL", "(track == null)", {"track": track})
		return
	var total := float(track.call("road_length"))
	# 记录复位次数与计圈事件
	var resets := 0
	var laps: Array[String] = []
	var last_pos: Vector3 = _car.global_position
	# 用弧长采样点做目标点，需要把弧长增量换算成"前方 45m"
	var target_ahead := 45.0
	print("[自检] 自动驾驶跑圈：目标=中心线前方 %.0fm，全油门，最多跑 6 分钟" % target_ahead)
	var steps := 0
	var max_steps := int(Engine.physics_ticks_per_second) * 360
	var lap_printed := 0
	# ---- 「车头方向 / 卡住」两项断言的记账（见 _autopilot.drive_recover 的说明）----
	var hz := float(Engine.physics_ticks_per_second)
	var drive_pos: Vector3 = _car.global_position
	var stuck_sec := 0.0
	var recover_sec := 0.0
	var back_frames := 0
	var worst_heading := 0.0
	var stuck_events := 0
	while steps < max_steps:
		steps += 1
		# 先问恢复逻辑：它接管时**必须跳过**下面的正常油门/转向，否则两边打架
		var rec: Dictionary = _autopilot.drive_recover(track, drive_pos, stuck_sec, recover_sec, hz)
		drive_pos = rec["last_pos"]
		stuck_sec = float(rec["stuck_sec"])
		recover_sec = float(rec["recover_sec"])
		if bool(rec["handled"]):
			await _physics_frame.call()
			continue
		# 转向 + 全油门：走**共享**的 _autopilot.drive_track（与 aidiag 同一份，
		# 不许在这里再写一遍 —— 玩家实测的"倒着开"就是两份漂移出来的）
		_autopilot.drive_track(track, target_ahead)
		await _physics_frame.call()
		# 本帧的赛道位置（车头方向与偏离都从这里取；`near` 是这一帧唯一的数据源）
		var near: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
		# ---- 断言 ①：车头方向（与赛道前进方向的夹角）----
		# 这是玩家实测"方向相反"的量化形式：夹角 >100° 就是明确掉头了。
		var fwd_t := Vector3(near.get("forward", Vector3.FORWARD))
		fwd_t.y = 0.0
		var nose := -_car.global_transform.basis.z
		nose.y = 0.0
		var cur_head := -1.0
		if fwd_t.length() > 0.001 and nose.length() > 0.001:
			cur_head = rad_to_deg(acos(clampf(nose.normalized().dot(fwd_t.normalized()), -1.0, 1.0)))
			worst_heading = maxf(worst_heading, cur_head)
			if cur_head > Autopilot.DRIVE_BACKWARDS_DEG:
				back_frames += 1
		# [DEBUG-L4] 时间线：每物理帧采一条（实验 2）。只读，不参与判定。
		_l4_diag.push(track, cur_head)
		# [DEBUG-L4] 撞车识别（计划 §8）：**只读**。一帧内速度崩掉 >25 km/h（或 >40 → <12）就是硬撞。
		# 为什么用速度而不是碰撞回调：本项目已知 Area3D / 接触信号不可靠，而「速度一帧崩掉」
		# 是物理事实（既有实测减速度 180~200 m/s²，轮胎在任何摩擦系数下都给不出）。
		var spd_now := _car.linear_velocity.length() * 3.6
		_l4_diag.note_speed(track, spd_now)
		# ---- 断言 ②：卡住（速度小 **且** 位移小 —— 只看速度会把贴墙慢速过弯误判成卡住）----
		if _car.linear_velocity.length() * 3.6 < Autopilot.DRIVE_STUCK_KMH \
				and drive_pos.distance_to(_car.global_position) < 0.005:
			stuck_sec += 1.0 / hz
			if stuck_sec >= Autopilot.DRIVE_STUCK_SEC:
				stuck_events += 1
				_evidence.event("STUCK", "player", {"count": stuck_events, "definition": "existing_lap_probe"})
				print("[自检]   ⚠ 卡住事件 #%d：t=%.1fs 速度 %.2f km/h 位置 %s 离中心线 %.2fm"
					% [stuck_events, float(steps) / hz, _car.linear_velocity.length() * 3.6,
					   _car.global_position, float(near["dist"])])
				# [DEBUG-L4] 结构化记录（实验 1）+ T±30 帧时间线（实验 2）
				_l4_diag.stuck_record(track, near, cur_head, stuck_events)
				# 卡住必须留下"被谁挡住"的取证，否则只能靠猜（本项目的硬规矩）。
				_checks_envphys.probe_blocker()
				if _obstacle_field != null and _obstacle_field.has_method("debug_ahead"):
					# 起点取**卡住点往前 6m**：车长 3.74m，卡在石头尾部时只列前方会漏掉它。
					var rows: Array = _obstacle_field.call("debug_ahead",
						float(near["arc"]) - 6.0, Autopilot.DRIVE_AVOID_HORIZON + 6.0, 0.0, Autopilot.DRIVE_BODY_HALF)
					if rows.is_empty():
						print("[自检]       [障碍] 卡住点前后 %.0fm 内**没有任何障碍**"
							% (Autopilot.DRIVE_AVOID_HORIZON + 6.0))
					for r in rows:
						print("[自检]       [障碍] %s" % r)
				stuck_sec = 0.0
		else:
			stuck_sec = 0.0
		# 统计"这一帧之前有没有发生过复位"：靠位置突变识别
		var now_pos: Vector3 = _car.global_position
		if last_pos.distance_to(now_pos) > 25.0:
			resets += 1
			_evidence.event("RESET_PROXY", "player", {"count": resets, "definition": "existing_position_jump_probe"})
			print("[自检]   ⚠ 检测到瞬移（疑似复位）第 %d 次：%s → %s  离中心线 %.2fm"
				% [resets, last_pos, now_pos, float(near["dist"])])
		last_pos = now_pos
		# 计圈事件
		var last_lap := float(_car.get("lap_last"))
		var best_lap := float(_car.get("lap_best"))
		if last_lap > 0.0 and laps.size() < 3 and (laps.is_empty() or laps[laps.size() - 1] != "%.3f" % last_lap):
			laps.append("%.3f" % last_lap)
			lap_printed += 1
			_evidence.event("LAP_COMPLETED", "player", {"count": lap_printed, "last_lap": last_lap})
			print("[自检]   ✔ 第 %d 圈完成：%.3f 秒" % [lap_printed, last_lap])
			_evidence.branch("lap.run_lap.002", "PASS", "(last_lap > 0.0 and laps.size() < 3 and (laps.is_empty() or laps[laps.size() - 1] != \"%.3f\" % last_lap))", {"lap_printed": lap_printed, "laps": laps, "last_lap": last_lap})
		# 至少跑满 3 圈才停：只有 1 圈时"上圈==最快"是正常的，不能当异常
		if lap_printed >= 3 or (lap_printed >= 1 and _reset_loop_hit()):
			break
	Input.action_release("accelerate")
	Input.action_release("steer_left")
	Input.action_release("steer_right")
	# 倒车键也必须收：它是_掉头恢复_按下的，漏掉它会让**下一位**用同一辆车的检查
	# 一开局就"两个方向同时按住"→ 轴值恒 0 → 车根本不会动（本文件踩过一次）。
	Input.action_release("brake_reverse")
	var last_lap := float(_car.get("lap_last"))
	var best_lap := float(_car.get("lap_best"))
	var reset_loop := _reset_loop_hit()
	print("[自检] 跑圈结束：用时 %.1fs 完成 %d 圈 复位次数=%d"
		% [float(steps) / Engine.physics_ticks_per_second, lap_printed, resets])
	_evidence.fact({"completed_laps": lap_printed, "reset_count": resets,
		"stuck_count": stuck_events, "measured_frames": steps})
	print("[自检] 圈速：上圈=%.3f 最快=%.3f（不变式：最快 ≤ 上圈）" % [last_lap, best_lap])
	# ---- 断言 ③：**故意把车掉头**，验证纠正逻辑真的能把它掰回来 ----
	# 为什么必须人为制造：碰撞（玩家实测的那个掉头）依赖起步时撞上并排的 AI，
	# 在 --check=lap 里 AI 不发车 → 撞不到 → 上面两条判据永远测不到"掉头纠正"。
	# 靠碰撞复现等于**把结论押在偶发事件上**；这里直接把车头拧到与赛道相反，
	# 于是"纠正有没有生效"变成确定性事实（改坏了一定红）。
	print("[自检] 掉头纠正演练：把车头人为拧到与赛道夹角 180°，看它能否掰回来")
	# ⚠ 必须先摆到**干净的位置**再演练（实测教训）：第一版直接拿"跑完 3 圈后车在哪"
	#   当演练起点，结果那次车正好楔在路边（车轮空转、0.0 km/h、20s 没位移），
	#   演练全程在原地打转、heading 读数还因为最近点漂移而乱跳（180→100°），
	#   于是"红"来自起点太脏而不是来自恢复逻辑 —— 这种红比绿更浪费人。
	#   所以先回中心线、清零速度、再拧头。
	var d_near: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
	var d_fwd: Vector3 = d_near.get("forward", Vector3.FORWARD)
	_car.global_transform = Autopilot.pose_facing(Vector3(d_near.get("pos", _car.global_position))
		+ Vector3(0, 1.0, 0), d_fwd)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	var flip_near: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
	var flip_fwd: Vector3 = flip_near.get("forward", Vector3.FORWARD)
	flip_fwd.y = 0.0
	if flip_fwd.length() > 0.001:
		flip_fwd = flip_fwd.normalized()
		# 保留车的位置，只把车头反过来（-flip_fwd 就是赛道反方向）
		_car.global_transform = Autopilot.pose_facing(_car.global_position, -flip_fwd)
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		var flip_pos: Vector3 = _car.global_position
		var flip_stuck := 0.0
		var flip_recover := 0.0
		var flip_frames := 0
		var flip_fixed_at := -1.0
		var flip_worst := 0.0
		var flip_max := int(hz * 20.0)
		while flip_frames < flip_max:
			flip_frames += 1
			var frec: Dictionary = _autopilot.drive_recover(track, flip_pos, flip_stuck, flip_recover, hz)
			flip_pos = frec["last_pos"]
			flip_stuck = float(frec["stuck_sec"])
			flip_recover = float(frec["recover_sec"])
			if not bool(frec["handled"]):
				# 恢复交回正常追线后，继续照着"前方 45m"开，好让车真正走回赛道方向
				var fn: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
				var faim := Vector3(track.call("centerline_point", float(fn["arc"]) + target_ahead))
				var fto := faim - _car.global_position
				fto.y = 0.0
				var fright: Vector3 = _car.global_transform.basis.x
				var fside := fto.normalized().dot(fright)
				Input.action_release("steer_left")
				Input.action_release("steer_right")
				if fside > 0.06:
					Input.action_press("steer_right")
				elif fside < -0.06:
					Input.action_press("steer_left")
				Input.action_press("accelerate")
			await _physics_frame.call()
			# 量当前夹角
			var fn2: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
			var ft: Vector3 = fn2.get("forward", Vector3.FORWARD)
			ft.y = 0.0
			var fnose: Vector3 = -_car.global_transform.basis.z
			fnose.y = 0.0
			if ft.length() > 0.001 and fnose.length() > 0.001:
				var fd := rad_to_deg(acos(clampf(fnose.normalized().dot(ft.normalized()), -1.0, 1.0)))
				flip_worst = maxf(flip_worst, fd)
				if fd < 60.0 and flip_fixed_at < 0.0:
					flip_fixed_at = float(flip_frames) / hz
		Input.action_release("accelerate")
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		if flip_fixed_at < 0.0:
			printerr("[自检] 跑圈验收 ✘ 掉头纠正演练失败：20s 内车头始终没回到 60° 以内（最坏 %.0f°）"
				% flip_worst)
			_evidence.branch("lap.run_lap.003", "FAIL", "(flip_fwd.length() > 0.001) and (flip_fixed_at < 0.0)", {"flip_fixed_at": flip_fixed_at, "flip_fwd": flip_fwd, "flip_worst": flip_worst})
		elif flip_fixed_at > 2.0:
			printerr("[自检] 跑圈验收 ✘ 掉头纠正太慢：用了 %.1fs 才回到 60° 以内（判据 ≤2s）"
				% flip_fixed_at)
			_evidence.branch("lap.run_lap.004", "FAIL", "(flip_fwd.length() > 0.001) and (not ((flip_fixed_at < 0.0)) and (flip_fixed_at > 2.0))", {"flip_fixed_at": flip_fixed_at, "flip_fwd": flip_fwd})
		else:
			print("[自检] 跑圈验收 ✔ 掉头纠正演练通过：%.1fs 内把车头掰回 60° 以内（最坏 %.0f°）"
				% [flip_fixed_at, flip_worst])
			_evidence.branch("lap.run_lap.005", "PASS", "(flip_fwd.length() > 0.001) and (not ((flip_fixed_at < 0.0) or (flip_fixed_at > 2.0)))", {"flip_fixed_at": flip_fixed_at, "flip_fwd": flip_fwd, "flip_worst": flip_worst})

		_evidence.assertion("lap.recovery", flip_fixed_at, "s", {"min": 0.0, "max": 2.0},
			"FAIL iff value < 0.0 or value > 2.0", "FAIL" if flip_fixed_at < 0.0 or flip_fixed_at > 2.0 else "PASS")
	# ---- 两项判据：车头方向 / 卡住（2026-09 玩家实测反馈「方向相反 + 卡墙」）----
	# 为什么要放进 --check=lap：原来这项检查**只验圈速**，于是"车被撞掉头后倒着开"
	# 照样全绿（实测 L1 三圈 36.7~40.8s、复位 0，而车有 5 帧点积 = -1.00）。
	# 圈速正常 ≠ 车在正常地开 —— 这两条判据就是补这个盲区。
	var back_pct := 100.0 * float(back_frames) / float(maxi(steps, 1))
	print("[自检] 车头方向：最坏夹角 %.1f°（判据 <%.0f°）、朝后帧 %d 帧（%.2f%%）"
		% [worst_heading, Autopilot.DRIVE_BACKWARDS_DEG, back_frames, back_pct])
	# [DEBUG-L4] 本轮汇总：目标车道翻转 + 横向速率分布（只报数，不参与判定）。
	# 为什么放在这条断言**之前**：它是本轮取证的原始读数，必须与「卡住事件」同一屏可见。
	_l4_diag.summary_report()
	print("[自检] 卡住事件：%d 次（判据 0；判据为速度<%.0f km/h 且 3s 内位移<5cm）"
		% [stuck_events, Autopilot.DRIVE_STUCK_KMH])
	var heading_ok := worst_heading < Autopilot.DRIVE_BACKWARDS_DEG or back_pct < 5.0
	_evidence.assertion("lap.heading_stuck", {"worst_heading": worst_heading, "back_pct": back_pct,
		"stuck_events": stuck_events}, "deg,%,count", {"heading": Autopilot.DRIVE_BACKWARDS_DEG,
		"back_pct": 5.0, "stuck_events": 0}, "FAIL iff not (heading < limit or back_pct < 5.0) or stuck_events > 0",
		"FAIL" if not heading_ok or stuck_events > 0 else "PASS")
	# ⚠ 「本次有没有真的压到过」——这个检查如果不记，就会出现**假绿**（实测踩到）：
	#   第一版跑完打印「车头方向：最坏夹角 9.0°、朝后 0 帧」全绿，看起来修好了；
	#   真实原因却是 `--check=lap` 里 AI **从来没发车**（本检查不调 `_opponent_spawner.arm_opponents()`），
	#   起步时旁边没有车 → 根本没有碰撞 → 根本不会掉头。
	#   玩家看到的掉头是 aidiag 里"起步撞上并排的静止 AI"撞出来的（点积 -1.00 有日志）。
	#   所以判据必须能区分「测了且通过」与「压根没测到」，否则这个绿灯毫无意义。
	var armed_ever := false
	for o in _opponents:
		if bool(o.get("armed")):
			armed_ever = true
			break
	if _opponents.is_empty():
		print("[自检] 注：本关没有 AI 对手 —— 碰撞场景未被覆盖，本条绿灯只说明「没掉过头」")
	elif not armed_ever:
		print("[自检] ⚠ 注：AI 全程未发车（本检查不调 arm_opponents）→ 起步碰撞场景未被覆盖，"
			+ "本条绿灯**弱**；要看碰撞后的掉头纠正请用 --check=aidiag")
	else:
		print("[自检] ✔ 本次 AI 已发车，起步碰撞场景已被覆盖")
		_evidence.branch("lap.run_lap.006", "PASS", "(not ((_opponents.is_empty()) or (not armed_ever)))", {"_opponents": _opponents, "armed_ever": armed_ever})
	if not heading_ok:
		printerr("[自检] 跑圈验收 ✘ 车头方向异常：最坏夹角 %.1f°、朝后帧占 %.2f%% —— 掉头纠正没生效"
			% [worst_heading, back_pct])
		_evidence.branch("lap.run_lap.007", "FAIL", "(not heading_ok)", {"back_pct": back_pct, "heading_ok": heading_ok, "worst_heading": worst_heading})
	elif stuck_events > 0:
		printerr("[自检] 跑圈验收 ✘ 出现 %d 次卡住事件 —— 卡墙自救没生效（见上方「卡住事件」行）"
			% stuck_events)
		_evidence.branch("lap.run_lap.008", "FAIL", "(not ((not heading_ok)) and (stuck_events > 0))", {"heading_ok": heading_ok, "stuck_events": stuck_events})
	else:
		print("[自检] 跑圈验收 ✔ 车头方向正常（未掉头）、无卡住事件")
		_evidence.branch("lap.run_lap.009", "PASS", "(not ((not heading_ok) or (stuck_events > 0)))", {"heading_ok": heading_ok, "stuck_events": stuck_events})
	# 判据要分开，别把几件事混成一个"圈速异常"。
	# 踩过的坑：本检查在只跑满 1 圈后若触发**复位循环**也会跳出循环，此时
	# "上圈==最快"是必然的，但报出来的却是"圈速异常"，看起来像计时坏了，
	# 实际根因是车被反复复位。根因说错会把排查方向带偏。
	#
	# ⚠ 2026-09 修正：原来判"上圈 == 最快"就报异常 —— **那是错的**。
	#   最后一圈正好也是最快圈时，两者本来就相等（实测 3 圈：36.914 → 36.900，
	#   上圈=最快=36.900）。真正的不变式是 **最快 ≤ 上圈** 且圈数够；
	#   要抓"计时坏了"，判据应该是"圈数不足"与"圈速 ≤0"，不是数值相等。
	_evidence.assertion("lap.laps_reset", {"resets": resets, "reset_loop": reset_loop,
		"laps": lap_printed, "last_lap": last_lap, "best_lap": best_lap}, "count,bool,laps,s,s",
		{"resets": 0, "reset_loop": false, "min_laps": 2, "min_time": 0.0, "rounding": 0.001},
		"FAIL iff resets > 0 or reset_loop or laps < 2 or last <= 0 or best <= 0 or best > last + 0.001",
		"FAIL" if resets > 0 or reset_loop or lap_printed < 2 or last_lap <= 0.0 or best_lap <= 0.0 or best_lap > last_lap + 0.001 else "PASS")
	if resets > 0:
		printerr("[自检] 跑圈验收 ✘ 期间发生 %d 次疑似复位（见上方「检测到瞬移」行）" % resets)
		_evidence.branch("lap.run_lap.010", "FAIL", "(resets > 0)", {"resets": resets})
	elif reset_loop:
		printerr("[自检] 跑圈验收 ✘ 中途触发复位循环（只跑了 %d 圈）：根因是车被反复复位，"
			% lap_printed + "不是计时问题 —— 见上方「检测到瞬移」行")
		_evidence.branch("lap.run_lap.011", "FAIL", "(not ((resets > 0)) and (reset_loop))", {"lap_printed": lap_printed, "reset_loop": reset_loop, "resets": resets})
	elif lap_printed < 2:
		printerr("[自检] 跑圈验收 ✘ 只跑完 %d 圈（不足 2 圈，无法比较圈速）" % lap_printed)
		_evidence.branch("lap.run_lap.012", "FAIL", "(not ((resets > 0) or (reset_loop)) and (lap_printed < 2))", {"lap_printed": lap_printed, "reset_loop": reset_loop, "resets": resets})
	elif last_lap <= 0.0 or best_lap <= 0.0:
		printerr("[自检] 跑圈验收 ✘ 圈速非正（上圈=%.3f 最快=%.3f）：计时没在跑" % [last_lap, best_lap])
		_evidence.branch("lap.run_lap.013", "FAIL", "(not ((resets > 0) or (reset_loop) or (lap_printed < 2)) and (last_lap <= 0.0 or best_lap <= 0.0))", {"best_lap": best_lap, "lap_printed": lap_printed, "last_lap": last_lap, "reset_loop": reset_loop, "resets": resets})
	elif best_lap > last_lap + 0.001:
		printerr("[自检] 跑圈验收 ✘ 圈速异常：最快 %.3f 竟然大于上圈 %.3f（最快圈没被更新）"
			% [best_lap, last_lap])
		_evidence.branch("lap.run_lap.014", "FAIL", "(not ((resets > 0) or (reset_loop) or (lap_printed < 2) or (last_lap <= 0.0 or best_lap <= 0.0)) and (best_lap > last_lap + 0.001))", {"best_lap": best_lap, "lap_printed": lap_printed, "last_lap": last_lap, "reset_loop": reset_loop, "resets": resets})
	else:
		print("[自检] 跑圈验收 ✔ 连续多圈计时正常、无意外重置")
		_evidence.branch("lap.run_lap.015", "PASS", "(not ((resets > 0) or (reset_loop) or (lap_printed < 2) or (last_lap <= 0.0 or best_lap <= 0.0) or (best_lap > last_lap + 0.001)))", {"best_lap": best_lap, "lap_printed": lap_printed, "last_lap": last_lap, "reset_loop": reset_loop, "resets": resets})


## 兜底被自动停用（说明出现复位死循环）时返回 true
func _reset_loop_hit() -> bool:
	return not bool(_car.get("auto_reset_out_of_bounds"))


# ======================== 压测验收（--check=stress）========================
#
## 压测验收：本地确定性"鲁莽玩家"跑一段，统计卡死次数。
## 用例优先读落盘的确定性极端用例（`data/ai_test_cases.json`），读不到则走本地随机；不联网、不报错。
func run_stress() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		_evidence.branch("lap.run_stress.001", "FAIL", "(track == null)", {"track": track})
		return
	var dur := 25.0
	# 注意：不能用 `var driver := load(...).new()` —— load() 返回 Variant，
	# GDScript 推断不出类型会直接**解析错误**，进而让整个 main.gd 加载失败
	# （表现就是关卡参数失效、赛道不生成、车一路掉落，实测踩过）。
	var driver_script: GDScript = load("res://scripts/ai_test_driver.gd")
	var driver: Node = driver_script.new()
	driver.set("car", _car)
	driver.set("track", track)
	driver.set("mode", 0)          # RECKLESS
	_add_child.call(driver)
	print("[自检] 压测开始：本地确定性鲁莽驾驶 %.0f 秒（固定种子，可复现）" % dur)
	var report: Dictionary = await driver.call("stress_test", dur)
	driver.call("stop")
	print("[自检] 压测结果：帧数=%d 卡死事件=%d 最大偏离=%.2fm 用例=%d"
		% [report.get("frames", 0), report.get("stuck_events", 0),
		   report.get("max_deviation", 0.0), report.get("cases_used", 0)])
	if int(report.get("case_failures", 0)) > 0:
		printerr("[自检] 用例兜底失败 %d 例" % int(report["case_failures"]))
	for p in report.get("stuck_positions", []):
		print("[自检]   卡死位置：%s" % p)

	var stuck := int(report.get("stuck_events", 0))
	var case_failed := int(report.get("case_failures", 0))
	if stuck == 0 and case_failed == 0:
		print("[自检] 压测验收 ✔ 没有卡死事件，极端用例兜底全部通过")
		_evidence.branch("lap.run_stress.002", "PASS", "(stuck == 0 and case_failed == 0)", {"case_failed": case_failed, "stuck": stuck})
	else:
		printerr("[自检] 压测验收 ✘ 卡死 %d 次 / 用例兜底失败 %d 例" % [stuck, case_failed])
		_evidence.branch("lap.run_stress.003", "FAIL", "(not ((stuck == 0 and case_failed == 0)))", {"case_failed": case_failed, "stuck": stuck})
	driver.queue_free()


# ======================== 方向反向提示验收（--check=reverse）========================
#
# 需求（2026-09 项目所有者给出精确规格）：赛道只允许**顺时针**行驶；
# 玩家撞墙后车头被弹反时要提示他调头；**倒车不视为"开反了"**。
#
# 判定逻辑在 `track_layout.wrong_way_state()`（纯函数），本检查只做两件事：
#   ① 6 条**纯函数**用例（下面那张表，逐条对应规格里的场景）
#   ② 真车 + 真物理 + 真 HUD 的端到端（人为把车头转 180°，以 ~60 km/h 前进）
#
# ⚠ 为什么纯函数用例要单独计数（`REVERSE_CASES`）而不是并进 --check=layout：
#   规格要求"打独立计数器：[自检] reverse 用例跑了 6/6 条，绿 X 条"，
#   并且要 has_method 探针防"函数不存在导致的假绿"（本项目踩过：`call()` 打到
#   不存在的方法会把调用点之后的语句整段跳过，连失败计数都不执行）。
#   ⚠ SPLIT-CHECKS-BASIC-005b：`REVERSE_CASES` 是 ADR-001 永久居民，**留守 main.gd**，
#   经 setup() 注入为 `_reverse_cases_total`，本模块不复制第二份。
#
## 探针调 `track_layout.wrong_way_state`。返回空字典表示"函数还不存在"。
## **必须先探针再调用**：见 `_layout_elev_call` 的注释（假绿陷阱）。
func _reverse_call(mod: GDScript, was: bool, dot: float, speed_kmh: float,
		reversing: bool, enter_deg: float, exit_deg: float) -> Dictionary:
	if not mod.has_method("wrong_way_state"):
		return {}
	return mod.call("wrong_way_state", was, dot, speed_kmh, reversing, enter_deg, exit_deg)


## 角度（度）→ 点积。用例里直接写角度更贴规格表，换算只在这里做一次。
func _rev_dot(angle_deg: float) -> float:
	return cos(deg_to_rad(angle_deg))


## 一条 reverse 用例：给定（上一状态、车头夹角、速度、是否倒车、进入/退出阈值），
## 断言状态机输出的 `wrong_way`。
func _reverse_case(mod: GDScript, label: String, was: bool, angle_deg: float,
		speed_kmh: float, want: bool, reversing := false,
		enter_deg := 120.0, exit_deg := 105.0) -> void:
	_reverse_cases += 1
	var d := _reverse_call(mod, was, _rev_dot(angle_deg), speed_kmh, reversing, enter_deg, exit_deg)
	if d.is_empty():
		_reverse_failed += 1
		_evidence.branch("lap._reverse_case.001", "FAIL", "(d.is_empty())", {"_reverse_failed": _reverse_failed, "d": d})
		printerr("[自检]   ✘ reverse 用例「%s」无法判定：track_layout.gd 还没有 wrong_way_state" % label)
		_evidence.branch("lap._reverse_case.002", "FAIL", "(d.is_empty())", {"d": d, "label": label})
		return
	var got := bool(d.get("wrong_way", false))
	if got != want:
		_reverse_failed += 1
		_evidence.branch("lap._reverse_case.003", "FAIL", "(got != want)", {"_reverse_failed": _reverse_failed, "got": got, "want": want})
		printerr("[自检]   ✘ reverse 用例「%s」：期望 %s，实际 %s（was=%s 夹角=%.0f° 速度=%.1f km/h 倒车=%s）"
			% [label, str(want), str(got), str(was), angle_deg, speed_kmh, str(reversing)])
		_evidence.branch("lap._reverse_case.004", "FAIL", "(got != want)", {"angle_deg": angle_deg, "got": got, "label": label, "reversing": reversing, "speed_kmh": speed_kmh, "want": want, "was": was})
		return
	print("[自检]   ✔ reverse 用例「%s」= %s（夹角 %.0f°，%.0f km/h）"
		% [label, str(got), angle_deg, speed_kmh])
	_evidence.branch("lap._reverse_case.005", "PASS", "original accumulated result; source godot-racer/scripts/checks/lap.gd:466", {"angle_deg": angle_deg, "got": got, "label": label, "speed_kmh": speed_kmh})


## `--check=reverse` 主流程。
func run_reverse() -> void:
	_reverse_cases = 0
	_reverse_failed = 0
	var mod: GDScript = load("res://scripts/track_layout.gd")
	# 防假绿：模块必须真的可用、且真的有那个方法（见上面 const 的注释）
	if mod == null or not mod.has_method("wrong_way_state"):
		printerr("[自检] reverse 验收 ✘ track_layout.gd 不可用或缺少 wrong_way_state（实现未落地）")
		_evidence.branch("lap.run_reverse.001", "FAIL", "(mod == null or not mod.has_method(\"wrong_way_state\"))", {"mod": mod})
		printerr("[自检]   reverse 用例跑了 0/%d 条，绿 0 条" % _reverse_cases_total)
		return

	# 门限取自**本关配置**（规格：不得硬编码、必须可配置且可被 --check=reverse 读取）
	var cfg: LevelConfig = GameState.current_level()
	var enter_deg := cfg.reverse_angle_enter_deg if cfg != null else 120.0
	var exit_deg := cfg.reverse_angle_exit_deg if cfg != null else 105.0
	var speed_kmh := cfg.reverse_speed_threshold_kmh if cfg != null else 15.0
	print("[自检] reverse 验收：门限取自本关配置「%s」—— 进入 %.0f°、退出 %.0f°、速度 %.0f km/h"
		% [cfg.display_name if cfg != null else "?", enter_deg, exit_deg, speed_kmh])
	print("[自检] reverse 用例组（%d 条，逐条对应规格表）" % _reverse_cases_total)

	# ---- 用例 1：正向行驶，速度 60 km/h，夹角 0° → 不显示 ----
	_reverse_case(mod, "①正向 0°/60km/h → 不显示", false, 0.0, 60.0, false, false, enter_deg, exit_deg)
	# ---- 用例 2：反向行驶（车头 180°），速度 60 km/h → 显示 ----
	_reverse_case(mod, "②反向 180°/60km/h → 显示", false, 180.0, 60.0, true, false, enter_deg, exit_deg)
	# ---- 用例 3：车头反向，但速度 5 km/h（低于阈值 15）→ 不显示 ----
	_reverse_case(mod, "③反向 180° 但仅 5km/h（<15）→ 不显示", false, 180.0, 5.0, false, false, enter_deg, exit_deg)
	# ---- 用例 4：车头 130°（越过进入阈值 120°），速度 60 → 显示 ----
	_reverse_case(mod, "④130°（越过进入阈值 120°）/60km/h → 显示", false, 130.0, 60.0, true, false, enter_deg, exit_deg)
	# ---- 用例 5：从 130° 转回 110°（介于进入/退出之间）→ **仍显示**（迟滞）----
	# `was=true` 表示上一帧已经在提示；110° 还没越过退出阈值 105° → 必须保持
	_reverse_case(mod, "⑤130°→110°（迟滞死区内）→ 仍显示", true, 110.0, 60.0, true, false, enter_deg, exit_deg)
	# ---- 用例 6：从 130° 转回 90°（越过退出阈值 105°）→ 隐藏 ----
	_reverse_case(mod, "⑥130°→90°（越过退出阈值 105°）→ 隐藏", true, 90.0, 60.0, false, false, enter_deg, exit_deg)

	var green := _reverse_cases - _reverse_failed
	print("[自检] reverse 用例跑了 %d/%d 条，绿 %d 条" % [_reverse_cases, _reverse_cases_total, green])

	# ---- 端到端：真车 + 真物理 + 真 HUD ----
	var e2e_ok := await _check_reverse_e2e(cfg)

	if _reverse_cases == _reverse_cases_total and _reverse_failed == 0 and e2e_ok:
		print("[自检] reverse 验收 ✔ %d/%d 条用例全绿 + 端到端提示正常" % [_reverse_cases_total, _reverse_cases_total])
		_evidence.branch("lap.run_reverse.002", "PASS", "(_reverse_cases == _reverse_cases_total and _reverse_failed == 0 and e2e_ok)", {"_reverse_cases": _reverse_cases, "_reverse_cases_total": _reverse_cases_total, "_reverse_failed": _reverse_failed, "e2e_ok": e2e_ok})
	else:
		printerr("[自检] reverse 验收 ✘ 用例 %d/%d 条、绿 %d 条；端到端 %s"
			% [_reverse_cases, _reverse_cases_total, green, "通过" if e2e_ok else "失败"])
		_evidence.branch("lap.run_reverse.003", "FAIL", "(not ((_reverse_cases == _reverse_cases_total and _reverse_failed == 0 and e2e_ok)))", {"_reverse_cases": _reverse_cases, "_reverse_cases_total": _reverse_cases_total, "_reverse_failed": _reverse_failed, "e2e_ok": e2e_ok, "green": green})


## 「方向反了」端到端：①车头转 180° 以 ~60 km/h 前进 → 提示亮
##                   ②按 S 倒车 → **不**提示（规格明确要求）
## 返回是否全部通过。
func _check_reverse_e2e(cfg: LevelConfig) -> bool:
	var track := _track
	if track == null or _car == null:
		printerr("[自检]   ✘ 端到端跳过：找不到 Track 或玩家车")
		_evidence.branch("lap._check_reverse_e2e.001", "FAIL", "(track == null or _car == null)", {"_car": _car, "track": track})
		return false
	# ⚠ 提示条现在挂在 **HUD 下的独立 CanvasLayer**（WrongWayLayer）里，
	#   不再是 HUD 的直接子节点 —— 所以按名字递归找，不写死路径。
	#   写死路径的代价实测过：加了那层之后这里立刻变成"找不到 WrongWayPanel"。
	var panel := _find_wrong_way_panel()
	if panel == null:
		printerr("[自检]   ✘ 端到端失败：HUD 里找不到 WrongWayPanel（提示条没建出来）")
		_evidence.branch("lap._check_reverse_e2e.002", "FAIL", "(panel == null)", {"panel": panel})
		return false
	var hz := float(Engine.physics_ticks_per_second)
	var ok := true

	# ---- ① 车头转 180°，全油门前进 ----
	var n0: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
	var f0: Vector3 = n0.get("forward", Vector3.FORWARD)
	f0.y = 0.0
	_car.global_transform = Autopilot.pose_facing(Vector3(n0.get("pos", _car.global_position))
		+ Vector3(0, 1.0, 0), -f0)          # 车头拧到赛道反方向
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	for i in range(20):
		await _physics_frame.call()
	var lit := 0
	var frames := 0
	var spd_max := 0.0
	for i in range(int(hz * 3.0)):
		frames += 1
		Input.action_release("brake_reverse")
		Input.action_press("accelerate")
		await _physics_frame.call()
		spd_max = maxf(spd_max, _car.linear_velocity.length() * 3.6)
		var w = _car.get("wrong_way")
		if w != null and bool(w):
			lit += 1
		if panel.visible != (w != null and bool(w)):
			printerr("[自检]   ✘ 端到端①：提示条与判定不一致（car=%s panel=%s）"
				% [str(w), str(panel.visible)])
			_evidence.branch("lap._check_reverse_e2e.003", "FAIL", "(panel.visible != (w != null and bool(w)))", {"panel": panel, "w": w})
			ok = false
			_evidence.branch("lap._check_reverse_e2e.004", "FAIL", "(panel.visible != (w != null and bool(w)))", {"ok": ok, "panel": panel, "w": w})
			break
	Input.action_release("accelerate")
	print("[自检]   端到端①：车头 180° 前进 %.1fs（最高 %.0f km/h）：提示亮 %d/%d 帧，panel.visible=%s"
		% [float(frames) / hz, spd_max, lit, frames, str(panel.visible)])
	if lit < int(hz * 0.5):
		printerr("[自检]   ✘ 端到端①：提示几乎没亮（%d 帧）—— 判定没接上或阈值不对" % lit)
		_evidence.branch("lap._check_reverse_e2e.005", "FAIL", "(lit < int(hz * 0.5))", {"hz": hz, "lit": lit})
		ok = false
		_evidence.branch("lap._check_reverse_e2e.006", "FAIL", "(lit < int(hz * 0.5))", {"hz": hz, "lit": lit, "ok": ok})

	# ---- ② 按 S 倒车：规格要求**不**提示（倒车救车是允许的）----
	var back_lit := 0
	var back_frames := 0
	for i in range(int(hz * 3.0)):
		back_frames += 1
		Input.action_release("accelerate")
		Input.action_press("brake_reverse")
		await _physics_frame.call()
		var w2 = _car.get("wrong_way")
		if w2 != null and bool(w2):
			back_lit += 1
	Input.action_release("brake_reverse")
	print("[自检]   端到端②：按 S 倒车 %.1fs：提示亮 %d/%d 帧（要求 0）"
		% [float(back_frames) / hz, back_lit, back_frames])
	if back_lit > 0:
		printerr("[自检]   ✘ 端到端②：倒车被误报成「方向反了」（亮了 %d 帧）—— 违反「倒车不属于反方向」" % back_lit)
		_evidence.branch("lap._check_reverse_e2e.007", "FAIL", "(back_lit > 0)", {"back_lit": back_lit})
		ok = false
		_evidence.branch("lap._check_reverse_e2e.008", "FAIL", "(back_lit > 0)", {"back_lit": back_lit, "ok": ok})
	return ok


## 按名字递归找「方向反了」提示条（它挂在 HUD 下的独立 CanvasLayer 里）。
## 为什么不写死路径 `HUD/WrongWayPanel`：那层是为"暂停时也能隐藏"加的，
## 加完立刻就让写死的路径失效了（实测报"找不到 WrongWayPanel"）。
## 这类"结构一变、路径就断"的引用，一律用递归查找。
## ⚠ 本 helper 只被本族的 `_check_reverse_e2e` 调用，故随本族迁入 lap.gd（见文件头）。
func _find_wrong_way_panel() -> Control:
	var hud := _hud
	if hud == null:
		return null
	return hud.find_child("WrongWayPanel", true, false) as Control
