extends RefCounted
## 台架验收族（`--check=steerbench` / `--check=brakebench`）：转向台架（扫「舵角 ×
## 初速度」矩阵，逐帧量实际达成的横向加速度 v·ω）与刹车台架（0° 舵角 + 全轮制动，
## 按初速度分档量实际可达减速度 a_brake）。main.gd 的 `match _check:` 分发口经
## `await _checks_bench.run_steerbench()` / `await _checks_bench.run_brakebench()`
## 进入本模块。
##
## 2026-10-13 SPLIT-CHECKS-BENCH-002：从 scenes/main.gd 整块拆出，**纯迁移、
## 行为零变化** —— 逻辑、print 文案（连 `[台架帧]` / `[台架刹帧]` / `[自检] 台架`
## 前缀与逐帧 dump 格式都原样留着，A/B 要逐行比对日志）、注释全部照搬，
## 没有第二份实现。
## 迁了什么：
##   · 8 个函数：`_check_steerbench` → 公开入口 `run_steerbench`、`_check_brakebench`
##     → `run_brakebench`；其余 6 个（`_steerbench_sample` / `_steerbench_aggregate` /
##     `_steerbench_run` / `_brakebench_sample` / `_brakebench_aggregate` /
##     `_brakebench_run`）保持原名与私有性，逐一对应、可 audit；
##   · 11 个常量：4 个 `STEERBENCH_*` + 7 个 `BRAKEBENCH_*`（check-docs.ps1 未登记、
##     非 ADR-001 永久居民，随族迁移；**不在此复制闸门登记的三 CASES 常量**）；
##   · 本族原实现就没有模块级状态（全是函数内局部量），迁移后零新增状态。
##
## ⚠ 三处关键决策（逐条定死，以后别悄悄改回去）：
##
##   ① **车 / 赛道经 setup() 注入，模块不 get_node**：迁移前两个 `_check_*` 入口用
##      `get_node_or_null("Track")` 取静态兄弟节点，改为注入 + 保留原 null 检查
##      （§2.4：禁反向持有场景；layout / opponent_spawner 同款约定）。玩家车沿用
##      `_car` 字段名（main.gd 成员同名，迁移前 `_check_*` 就读 main 的 `_car`），
##      注入后族内代码零 diff。
##
##   ② **physics_frame 经 Callable 注入**：迁移前帧循环里是
##      `await get_tree().physics_frame`；模块是 RefCounted、不在场景树上，没有
##      get_tree()，由 main 把 `_shot_physics_frame`（返回 physics_frame 信号本体）
##      以 Callable 递进来。模块里 `await _physics_frame.call()` 与迁移前
##      `await get_tree().physics_frame` 是**同一个 Signal**，协程恢复时机不变
##      （screenshot_mode 同款决策，2026-10-13 实证）。
##
##   ③ **await 数 = 4，一拍不加**：2 处帧循环的 physics_frame（见②）+ 2 处族内
##      `await _steerbench_run(...)` / `await _brakebench_run(...)`（迁移前就在
##      `_check_*` 里）。main.gd 分发口的 `await _checks_bench.run_*()` 留在 main
##      自己那层协程 —— 协程深度与迁移前一致（opponent_spawner 实证：多一层协程 =
##      physics_frame 恢复时机差 1 物理帧 = 25856 行日志发散）。由
##      split-checks-bench-structcheck.ps1 把「4」与三种形态钉死。
##
## ⚠ GameState.current_level() / effective_speed() 直接读 autoload（layout.gd 同款
##   先例）：GameState 是全局单例、不是场景节点，直连不违反「禁反向持有场景」；
##   且迁移前这两族就在 main.gd 里直连，注入只会多一层间接、零行为收益。
##
## ⚠ 为什么没有 class_name（与七个先例模块同一约定）：验收闸门在**无编辑器**环境跑
##   Godot，全局类缓存（.godot/global_script_class_cache.cfg）只有编辑器会重建；
##   2026-10-12 实测新增 class_name 后 `--check-only` 与游戏运行双双报
##   `Identifier not declared`。消费方一律
##   `const ChecksBench := preload("res://scripts/checks/bench.gd")`。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car = $RaceCar）。字段名沿用 main 的成员名 → 族内代码零 diff。
var _car: VehicleBody3D = null
## 赛道（迁移前是 _check_* 里 get_node_or_null("Track") 的静态兄弟节点）。由 setup() 注入。
var _track: Node = null
## physics_frame 信号提供者（main.gd 的 _shot_physics_frame）。由 setup() 注入；
## 模块里 `await _physics_frame.call()` 取代 `await get_tree().physics_frame`，
## 是同一个 Signal，协程恢复时机不变（文件头决策 ②③）。
var _physics_frame: Callable = Callable()
## 摆位纯函数（static func pose_facing，无状态可直调，§2.4 约定）。
const Autopilot := preload("res://scripts/autopilot.gd")


## 注入外部引用（main.gd 在 _after_world_ready 里调用一次）。
func setup(car: VehicleBody3D, track: Node, physics_frame: Callable) -> void:
	_car = car
	_track = track
	_physics_frame = physics_frame

# ======================== 转向台架（--check=steerbench）========================
#
# 目的：量出「舵角 → 实际达成的横向加速度」这条**传递函数**。
#
# 为什么非得先量它（2026-10-11 第 5 轮失败的教训）：
#   第 5 轮把验收自动驾驶的打舵门限从"约 2.7m"收紧到 `0.06×L`，结果比例-继电控制
#   进了**极限环**：车满舵钉死在左侧护栏（4 km/h、离中心线 5.43m），日志从 1.4MB 涨到 7.8MB。
#   结论：**拿到这条传递函数之前，不许再改任何打舵判据**。
#
# 做法：复用 `_friction_probe()` 已被证明可复现的摆位（起终点直道 + 朝赛道前进方向 +
#   固定初速度），但把"靠 Input 饱和打满舵"换成 `steer_fixture_active` 夹具的**精确舵角**，
#   再扫「舵角 × 初速度」矩阵，**逐帧**记录 v / ω / 舵角 / 侧滑角 / 航向角 / 接地 / 离中心线。
#
# 判定：这是个**测量**，绿只代表"夹具可信、数据可用"，不代表关卡合格。pass/fail 只有两条：
#   ① 满舵 @ 最低速那格必须真的转起来（横向加速度 ≥ 3 m/s²），否则夹具没生效
#   ② 至少有一格拿到有效读数（全部被剔除 = 无效测量）
#
# 每格的**有效帧**（≥3 轮接地 且 在路面内）必须 ≥ 18 帧（0.15s）；不足的格会被**剔除**并单独报出
#   —— 那说明该(舵角,速度)组合在物理上留不住（是剔除，不是判红）。
#
# ⚠ 原判据"每格 3 次重复的相对标准差 ≤ 15%"（**格内 CV**）**已降级为信息量、不判红**（Step 1b′ 2026-10-11）：
#   仿真完全确定（同摆位 + 同初速 + 无随机数）⇒ 同格 3 次跑出**逐字节相同**的结果 ⇒ CV 恒 0，判据**空转**。
#   夹具是否可复现改由**跨进程** A/B/C 复现极差判定（04-Godot启动器/steerbench-repro.ps1，阈值 ≤1%）。

const STEERBENCH_WINDOW_SEC := 0.70
const STEERBENCH_REPEATS := 3
## 有效帧下限：120Hz 下 18 帧 = 0.15s。低于此说明这一格几乎全程在离地/出界。
## 为什么是 0.15s 就够：实测横向加速度的**上升时间只有 0.04~0.07s**，峰值在 0.10s 前就建立；
## 18 帧足以覆盖"上升 + 平台"。而窗口前段是"空中注入初速度后的下落"（无效帧）：
## ⚠ 摆位抬升 0.6 → 0.12 m（Step 1b′ 2026-10-11）后，这段下落从 ≈0.35s（≈42 帧）
##    缩到 ≈0.16s（≈19 帧），有效帧显著增加（改前只剩 23~30/84）。
const STEERBENCH_MIN_VALID_FRAMES := 18
## ⚠ **已降级为信息量（informational）**，不再参与 pass/fail（Step 1b′ 2026-10-11）。
## 原意："每格重复的相对标准差上限（15%）"当夹具可信红线；但仿真完全确定（同摆位 + 同初速 + 无随机数）
## ⇒ 同格 3 次跑出逐字节相同的结果 ⇒ CV 恒 0，红线**空转**、无判别力（Step 1 实测 A2/B2/C2 极差 0.02%）。
## 现在它只决定"要不要在摘要里打一条提示行"，**不判红**。
## 夹具可复现性改由**跨进程** A/B/C 复现极差判定（04-Godot启动器/steerbench-repro.ps1，阈值 ≤1%）。
const STEERBENCH_CV_LIMIT := 0.15


## 逐帧采一条读数（台架用）。字段名与 `_steerbench_aggregate` 一一对应。
func _steerbench_sample(i: int, hz: float, steer: float, v_kmh: float, yaw0: float, track: Node) -> Dictionary:
	var vel: Vector3 = _car.linear_velocity
	var planar := Vector2(vel.x, vel.z).length()
	var omega := _car.angular_velocity.y
	# 横向（向心）加速度 = v · ω。它是"实际达成的"侧向能力，不是指令值。
	var lat := planar * absf(omega)
	var slip := 0.0
	if planar > 3.0:
		var nose := -_car.global_transform.basis.z
		nose.y = 0.0
		var vdir := Vector3(vel.x, 0.0, vel.z)
		if nose.length() > 0.001 and vdir.length() > 0.001:
			slip = rad_to_deg(nose.normalized().angle_to(vdir.normalized()))
	var grounded := 0
	for child in _car.get_children():
		if child is VehicleWheel3D and (child as VehicleWheel3D).is_in_contact():
			grounded += 1
	var off := _car.global_position.distance_to(
		track.call("nearest_on_centerline", _car.global_position, -1.0).get("pos", _car.global_position))
	var yaw := rad_to_deg(absf(angle_difference(yaw0, _car.global_rotation.y)))
	var t := float(i + 1) / hz
	# 有效性：≥3 轮接地 且 还在路面内。
	# 为什么必须过滤：高速 + 大舵角时车会**冲出路面撞护栏/石头**，那一帧 ω 会飙到
	# ±6 rad/s，v·ω 直接算出 200+ m/s² 的**假读数** —— 首轮实测 160km/h 整列
	# 都是 230+，那不是底盘响应，是撞墙。
	var road_half := float(track.call("road_half_width"))
	# 出界（撞护栏/石头）与"离地"是两回事：前者要把这一格掐断，后者（空中注入后的下落）只是等一等。
	var offroad := off > road_half + 0.5
	var valid := grounded >= 3 and not offroad
	# ⚠ 这一行**刻意不加 `[自检]` 前缀**：逐帧 dump 有几千行，加上会被 run-check
	# 的摘要原样刷屏。它留在日志文件里供事后分析，摘要只看 `[自检] 台架` 那几行。
	print("[台架帧] steer=%+.3f v0=%3.0f t=%4.2fs v=%6.2f omega=%+7.4f lat=%6.2f steer_act=%+.3f slip=%5.1f yaw=%6.1f g=%d/4 off=%5.2f valid=%d"
		% [steer, v_kmh, t, planar, omega, lat, _car.steering, slip, yaw, grounded, off,
		   1 if valid else 0])
	return {
		"t": t, "v": planar, "omega": omega, "lat": lat,
		"steer_act": _car.steering, "slip": slip, "yaw": yaw,
		"grounded": grounded, "off": off, "offroad": offroad, "steer": steer, "v0": v_kmh, "valid": valid,
	}


## 把一段窗口的逐帧读数聚成一条格子结论。**只统计有效帧**（见 `_steerbench_sample`）。
func _steerbench_aggregate(samples: Array, steer: float, v_kmh: float) -> Dictionary:
	var empty := {"lat_avg": 0.0, "lat_peak": 0.0, "lat_steady": 0.0, "rise": -1.0,
		"delay": -1.0, "slip": 0.0, "yaw": 0.0, "v_end": 0.0,
		"grounded_min": 0, "off_max": 0.0, "valid_n": 0, "total_n": 0,
		"steer": steer, "v0": v_kmh}
	var n := samples.size()
	empty["total_n"] = n
	if n == 0:
		return empty
	var valid: Array = []
	for s in samples:
		if bool(s.get("valid", false)):
			valid.append(s)
	var vn := valid.size()
	empty["valid_n"] = vn
	if vn == 0:
		return empty
	var lat_sum := 0.0
	var lat_peak := 0.0
	var slip_sum := 0.0
	var grounded_min := 4
	var off_max := 0.0
	for s in valid:
		var l := float(s.get("lat", 0.0))
		lat_sum += l
		lat_peak = maxf(lat_peak, l)
		slip_sum += absf(float(s.get("slip", 0.0)))
		grounded_min = mini(grounded_min, int(s.get("grounded", 0)))
		off_max = maxf(off_max, float(s.get("off", 0.0)))
	# 稳态：只取有效帧的后 40%（前段是"舵角建立 + 车身滚转"的过程，不是稳态）
	var tail_from := int(float(vn) * 0.6)
	var tail_sum := 0.0
	var tail_n := 0
	for i in range(tail_from, vn):
		tail_sum += float(valid[i].get("lat", 0.0))
		tail_n += 1
	# 延迟 = 首次横向加速度 ≥ 1 m/s² 的时刻；上升时间 = 首次达到峰值 63% 的时刻
	var rise := -1.0
	var delay := -1.0
	for s in valid:
		var l := float(s.get("lat", 0.0))
		if delay < 0.0 and l >= 1.0:
			delay = float(s.get("t", 0.0))
		if rise < 0.0 and lat_peak > 0.0 and l >= lat_peak * 0.63:
			rise = float(s.get("t", 0.0))
	var last: Dictionary = valid[vn - 1]
	return {
		"lat_avg": lat_sum / float(vn),
		"lat_peak": lat_peak,
		"lat_steady": tail_sum / float(maxi(tail_n, 1)),
		"rise": rise, "delay": delay,
		"slip": slip_sum / float(vn),
		"yaw": float(last.get("yaw", 0.0)),
		"v_end": float(last.get("v", 0.0)),
		"grounded_min": grounded_min,
		"off_max": off_max,
		"valid_n": vn, "total_n": n,
		"steer": steer, "v0": v_kmh,
	}


## 跑一格：固定舵角 + 固定初速度，量一段窗口内的横向加速度。
##
## 摆位与 `_friction_probe()` 同源（起终点直道、朝赛道前进方向、固定初速度），
## 差别只在"舵角由夹具精确给定"，而不是靠 `Input` 打到饱和。
func _steerbench_run(steer: float, v_kmh: float, track: Node) -> Dictionary:
	var hz := float(Engine.physics_ticks_per_second)
	var total := maxf(1.0, float(track.call("road_length")))
	var sf = track.get("start_finish_t")
	var d := total * float(sf) if sf != null else 0.0
	var fwd: Vector3 = track.call("centerline_forward", d)
	fwd.y = 0.0
	fwd = fwd.normalized()

	# 摆位 + **当场（还在空中就）注入初速度** —— 与已验证过的 `_friction_probe()` 同做法。
	#
	# ⚠ 走过的弯路：原先写成"先等 12 帧四轮接地、落地后再注入"。实测那版**每格只有
	# 20~26 个有效帧**（窗口本该 84 帧）：车落地后把 `linear_velocity` 从 0 一步顶到
	# 11~44 m/s，接触求解器吃到巨大相对速度，**注入后约 0.15~0.2s 车就四轮离地** ——
	# 而那时离中心线只有 0.1~0.2m，根本不是冲出路面，是注入方式把车"顶"起来了。
	# 改回空中注入后不再出现；离地/出界的帧由 `_steerbench_sample` 的 `valid` 过滤掉。
	#
	# ⚠ 摆位抬升 0.6 → 0.12 m（Step 1b′ 2026-10-11）：`race_car.tscn` 注释写明
	# 「VehicleWheel3D 的 position 是悬挂硬点，平地静止时硬点高度 = wheel_radius + rest_length」
	# → 车身原点静止约在**轮触地高度**。所以摆在 `centerline_point + (0, 0.6, 0)`
	# 就是**从 0.6 m 落下**（≈0.35 s ≈ 42 帧 @120Hz），占掉 0.70 s 窗口的一半，
	# 有效帧只剩 23~30/84。降到 0.12 m 后下落 ≈0.16 s（≈19 帧），有效帧显著增加，
	# 「延迟/上升」这两个读数才有物理意义。
	# ⚠ 这是**缩小下落段、不是埋车**：0.12 m 仍高于触地高度，车仍是从空中落下，
	#    注入方式（空中给初速度）本身一个字没改 —— 只是把无效的下落帧砍掉。
	# ⚠ 同文件 `_friction_probe()`（约 L3395）里的 `+ Vector3(0, 0.6, 0)` **不动**：
	#    那一项测的是抓地力，本步范围只限 steerbench。
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	_car.global_transform = Autopilot.pose_facing(track.call("centerline_point", d) + Vector3(0, 0.12, 0), fwd)
	_car.linear_velocity = fwd * (v_kmh / 3.6)
	_car.set("steer_fixture_active", true)
	_car.set("steer_fixture_angle", steer)
	Input.action_press("accelerate")

	var yaw0 := _car.global_rotation.y
	var samples: Array = []
	var offroad_streak := 0
	for i in range(int(hz * STEERBENCH_WINDOW_SEC)):
		await _physics_frame.call()
		var smp := _steerbench_sample(i, hz, steer, v_kmh, yaw0, track)
		samples.append(smp)
		# ⚠ 掐断条件只能是"连续出界"，**不能**是"连续无效帧"：
		#   空中注入初速度后，窗口前段有约 0.3s 是下落（四轮未接地 → invalid），
		#   若按 invalid 计数，每格都会在第 6 帧被误判掐断、什么都测不到。
		if bool(smp.get("offroad", false)):
			offroad_streak += 1
			if offroad_streak >= 6:
				break    # 连续 6 帧（50ms）出路面 → 本格到此为止，别把撞墙帧算进来
		else:
			offroad_streak = 0

	Input.action_release("accelerate")
	_car.set("steer_fixture_active", false)
	_car.set("steer_fixture_angle", 0.0)
	return _steerbench_aggregate(samples, steer, v_kmh)


## 转向台架验收：扫「舵角 × 初速度」矩阵，量实际达成的横向加速度（v·ω）。
##
## 用法：godot --path <工程> -- --check=steerbench --level=3
func run_steerbench() -> void:
	var track := _track
	if track == null or _car == null:
		printerr("[自检] 台架 ✘ 找不到 Track 或 RaceCar")
		return

	var steers := [0.05, 0.10, 0.15, 0.20, 0.30, 0.45]
	var speeds := [40.0, 80.0, 120.0, 160.0]
	var repeats := STEERBENCH_REPEATS

	print("[自检] 台架 启动：舵角 %s rad × 初速度 %s km/h × 每格 %d 次"
		% [str(steers), str(speeds), repeats])
	print("[自检] 台架 摆位：起终点直道 + 朝赛道前进方向 + **空中注入初速度**（同 `_friction_probe`，下落段按无效帧过滤）；测量窗口 %.2fs"
		% [STEERBENCH_WINDOW_SEC])

	# 关掉出界兜底，免得台架中途被搬走（与 _friction_probe 同做法）
	var cfg: LevelConfig = GameState.current_level()
	var prev_recover = _car.get("auto_recover")
	_car.set("auto_recover", false)
	_car.call("apply_level_setup", GameState.effective_speed(), 99,
		cfg.friction_multiplier if cfg != null else 1.0)

	var cells: Array = []
	var valid_cells: Array = []
	var invalid_cells := 0
	var worst_cv := 0.0
	var worst_label := ""
	for v_kmh in speeds:
		for s in steers:
			var lats: Array[float] = []
			var one: Dictionary = {}
			for _r in range(repeats):
				one = await _steerbench_run(float(s), float(v_kmh), track)
				lats.append(float(one.get("lat_peak", 0.0)))
			var mean := 0.0
			for x in lats:
				mean += x
			mean /= float(maxi(lats.size(), 1))
			var sd := 0.0
			for x in lats:
				sd += (x - mean) * (x - mean)
			sd = sqrt(sd / float(maxi(lats.size() - 1, 1)))
			var cv := sd / maxf(mean, 0.01)
			one["mean"] = mean
			one["sd"] = sd
			one["cv"] = cv
			cells.append(one)
			# 有效帧太少 = 这一格在测量窗口内就留不住（高速 + 大舵角冲出路外）。
			# 它不进"夹具可信"统计，但要在摘要里**明确报出来** —— 它本身就是结论。
			var vn := int(one.get("valid_n", 0))
			var is_valid_cell := vn >= STEERBENCH_MIN_VALID_FRAMES
			if is_valid_cell:
				valid_cells.append(one)
				if cv > worst_cv:
					worst_cv = cv
					worst_label = "steer=%.2f v0=%.0f" % [float(s), float(v_kmh)]
			else:
				invalid_cells += 1
			var delay_txt := "—"
			if float(one.get("delay", -1.0)) >= 0.0:
				delay_txt = "%.2fs" % float(one.get("delay", -1.0))
			var rise_txt := "—"
			if float(one.get("rise", -1.0)) >= 0.0:
				rise_txt = "%.2fs" % float(one.get("rise", -1.0))
			var mark := ""
			if not is_valid_cell:
				mark = "  ← 有效帧不足，已剔除"
			print("[自检] 台架 steer=%+.3f v0=%3.0f → lat_peak 均值=%6.2f ± %5.2f（相对 %4.1f%%）稳态=%6.2f 延迟=%s 上升=%s 末速=%5.1f 侧滑=%4.1f° 有效帧=%d/%d 离中心线最大=%.2fm%s"
				% [float(s), float(v_kmh), mean, sd, cv * 100.0,
				   float(one.get("lat_steady", 0.0)), delay_txt, rise_txt,
				   float(one.get("v_end", 0.0)), float(one.get("slip", 0.0)),
				   vn, int(one.get("total_n", 0)), float(one.get("off_max", 0.0)), mark])

	# 汇总矩阵（横向加速度 m/s²）
	print("[自检] 台架 === 横向加速度矩阵 lat_peak 均值 (m/s²)：行=舵角 rad，列=初速度 km/h ===")
	var header := "[自检] 台架   舵角\\速度"
	for v_kmh in speeds:
		header += "%9.0f" % float(v_kmh)
	print(header)
	for s in steers:
		var row := "[自检] 台架 %9.3f" % float(s)
		for v_kmh in speeds:
			var m := 0.0
			for c in cells:
				var same_steer := absf(float(c.get("steer", 0.0)) - float(s)) < 1e-6
				var same_speed := absf(float(c.get("v0", 0.0)) - float(v_kmh)) < 1e-6
				if same_steer and same_speed:
					m = float(c.get("mean", 0.0))
					break
			row += "%9.2f" % m
		print(row)

	# 还原车辆状态
	_car.set("auto_recover", prev_recover)
	_car.call("apply_level_setup", GameState.effective_speed(),
		cfg.laps_to_finish if cfg != null else 2,
		cfg.friction_multiplier if cfg != null else 1.0)
	_car.call("reset_to_track")

	# 判定：绿 = 夹具可信（数据可用），不代表关卡合格。
	# ⚠ pass/fail 只有两条（Step 1b′ 2026-10-11 收窄）：
	#   ① 至少有一格有效读数（全被剔除 = 无效测量）
	#   ② 满舵+最低速那格真的转起来（≥3 m/s²，夹具生效）
	# 格内 CV **不再判红**（仿真确定 ⇒ CV 恒 0，判据空转），只在下面作**信息量**打印。
	var ok := true
	if valid_cells.is_empty():
		printerr("[自检] 台架 ✘ 没有任何一格拿到有效读数（全部在测量窗口内冲出路外）")
		ok = false
	else:
		# ① 满舵 + 最低速那格必须真的转起来，否则夹具没生效
		var low_ref := -1.0
		for c in valid_cells:
			var at_max_steer := absf(float(c.get("steer", 0.0)) - 0.45) < 1e-6
			var at_low_speed := absf(float(c.get("v0", 0.0)) - 40.0) < 1e-6
			if at_max_steer and at_low_speed:
				low_ref = float(c.get("mean", 0.0))
		if low_ref < 3.0:
			printerr("[自检] 台架 ✘ 满舵@40km/h 的横向加速度只有 %.2f m/s² —— 夹具没生效或舵角被吞掉" % low_ref)
			ok = false
		# ② 格内 CV：**仅信息量，不判红**（仿真完全确定 ⇒ 同格 3 次逐字节相同 ⇒ CV 恒 0，无判别力）；
		#    夹具可复现性改由**跨进程** A/B/C 极差判定（04-Godot启动器/steerbench-repro.ps1，≤1%）。
		if worst_cv > STEERBENCH_CV_LIMIT:
			print("[自检] 台架 注（信息量，不判红）：%s 的格内相对标准差 %.1f%% 超过参考线 %.0f%%"
				% [worst_label, worst_cv * 100.0, STEERBENCH_CV_LIMIT * 100.0])
		if ok:
			print("[自检] 台架 ✔ 夹具可用：有效格 %d 个；满舵@40km/h = %.2f m/s²；格内最大相对标准差 %.1f%%（位于 %s，仅信息量）"
				% [valid_cells.size(), low_ref, worst_cv * 100.0, worst_label])
	if invalid_cells > 0:
		print("[自检] 台架 注：%d 格因高速+大舵角**冲出路外**、有效帧不足被剔除（这本身有用：说明这些(舵角,速度)组合在物理上留不住）"
			% invalid_cells)
	print("[自检] 台架 提示：本项是测量，绿只代表夹具可信；传递函数结论看上面的矩阵与日志里的 [台架帧] 逐帧 dump")


# ======================== 刹车台架（--check=brakebench）========================
#
# 目的：按抓地力分档实测**实际可达减速度 a_brake** —— B 方案（把 racing_line.brake_distance()
# 接进 AI 限速链、替换 probe 分支的瞬时余隙二次式）的硬前置。当前文档里的 6.0 是单测假设值，
# 不实测就实施 B，等于把限速上限建立在错误的数上。
#
# 做法与 steerbench 同源：起终点直道 + 朝赛道前进方向 + **空中注入初速度**（+0.12m，下落段按
# 无效帧过滤）；差别只在 ① 舵角由夹具锁 **0°**（隔离纵向）② 注入即按住 handbrake 全轮制动，
# 逐帧记 v / 减速度 / 接地 / 离中心线，直到刹停、偏出路外或窗口耗尽。
#
# a_brake 定义（2026-10-12 签字）：稳态带 **v ∈ [0.30·v0, 0.70·v0]**（**每格独立**，用该格
# 自己的 v0）内、有效帧的平均减速度。窄带理由：高速档 0.15~0.85 的宽带会含进气动/轮胎非线性区；
# 0.30~0.70 与 steerbench「只取有效帧后 40% 稳态」的哲学一致。峰值、全程均值、实测停距另存。
#
# ⚠ 玩家手刹 ≠ AI 刹车（2026-10-12 代码核实）：
#   vehicle.gd:1010-1017 手刹 → 全轮 brake=brake_force=**30**；ai_opponent.gd:851-858 超速时
#   brake=clampf(over×2, 0, **55**) 全轮（发动机制动不叠加）。两者都是全轮线性刹车力。
#   本台架量的是**玩家手刹（30）**，是 AI 能力的**保守下界**：是否等效取决于瓶颈在哪——
#   若轮胎先饱和（a_brake ≈ 抓地容量），两者等效、读数可直接用于 B；若刹车力先到头
#   （a_brake 远低于容量），AI 的 55 按线性折算约为 a_brake×55/30（封顶容量）。
#   ⚠ 天花板模型（2026-10-12 烟测后修正）：真实轮胎系数**不是** friction_multiplier 本身——
#   vehicle.gd:_apply_friction 把它乘到 wheel_friction_slip 基础值上（race_car.tscn 前 3.0 / 后 2.6），
#   所以容量 = (前slip+后slip)/2 × g（静载分配下限，制动载荷前移只会更高）。
#   L4 烟测实测：a_brake=12.93 / 容量 23.35 = 55% → 刹车力受限档（初版误用 μ·g=8.34 得出 155% 假饱和）。
#
# 判定：这是**测量**，绿只代表"夹具可信、数据可用"，不代表关卡合格。两条：
#   ① 最高有效档 a_brake ≥ 2 m/s²（刹车真的在咬）。100 km/h 格可能因"0° 直行约 40m 就偏出
#      起终点弯（R≈142m）"被剔除 —— 那是几何限制不是判据失败：落到**最高有效档**并明确打印。
#   ② 至少一格有效帧 ≥ 18（0.15s）
# 复现性：格内重复因仿真完全确定而逐字节相同（同 steerbench 实测），判据空转；
#   跨进程 A/B/C 复现极差 ≤1% 由 04-Godot启动器/brakebench-repro.ps1 判定
#   （**刻意不注册进 run-all-checks.ps1**，否则破坏 check-readme 的「N 项 ↔ 文档计数」契约）。
#
# 用法：godot --path <工程> -- --check=brakebench --level=3   （建议带 --noai）
const BRAKEBENCH_REPEATS := 3
## 单格最长观察窗口：刹停即止。低抓地 + 高速时给足减速时间
## （100 km/h @2 m/s² 需 13.9s；取 12s 可覆盖到 ≈2.3 m/s²）。
const BRAKEBENCH_MAX_WINDOW_SEC := 12.0
## 有效帧下限：120Hz 下 18 帧 = 0.15s（同 steerbench 口径）。
const BRAKEBENCH_MIN_VALID_FRAMES := 18
## 稳态带（每格独立，乘该格自己的 v0）：窄带取稳态，峰值与全程另存。
const BRAKEBENCH_STEADY_LO := 0.30
const BRAKEBENCH_STEADY_HI := 0.70
## 判据①：最高有效档平均减速度下限（刹车真的在咬）。
const BRAKEBENCH_MIN_ABRAKE := 2.0
## 刹停门限（m/s）：完全到 0 会被接触求解器拖住，降到 0.5 即视为停稳。
const BRAKEBENCH_STOP_MPS := 0.5


## 逐帧采一条读数（刹车台架用）。字段名与 `_brakebench_aggregate` 一一对应。
func _brakebench_sample(i: int, hz: float, v_kmh: float, v_prev: float, prev_valid: bool, track: Node) -> Dictionary:
	var vel: Vector3 = _car.linear_velocity
	var planar := Vector2(vel.x, vel.z).length()
	var grounded := 0
	for child in _car.get_children():
		if child is VehicleWheel3D and (child as VehicleWheel3D).is_in_contact():
			grounded += 1
	var off := _car.global_position.distance_to(
		track.call("nearest_on_centerline", _car.global_position, -1.0).get("pos", _car.global_position))
	var road_half := float(track.call("road_half_width"))
	# 出界（偏出路/撞护栏）与"离地"（空中注入后的下落）是两回事：前者要把本格掐断，后者只是等一等
	var offroad := off > road_half + 0.5
	var valid := grounded >= 3 and not offroad
	# 减速度 = 相邻两帧平面速度差 / dt。**只在两帧都有效时才算**：
	# 空中注入后前 ~0.16s 是下落，落地那一下的巨大相对速度会污染出假峰值。
	var dt := 1.0 / hz
	var decel := -1.0
	if valid and prev_valid and v_prev > 0.0:
		decel = (v_prev - planar) / dt
	var t := float(i + 1) / hz
	# 稳态带：该格自己的 v0（每格独立），窄带取稳态
	var v0 := v_kmh / 3.6
	var in_band := planar >= v0 * BRAKEBENCH_STEADY_LO and planar <= v0 * BRAKEBENCH_STEADY_HI
	# ⚠ 这一行**刻意不加 `[自检]` 前缀**：逐帧 dump 有几千行，加上会被 run-check
	# 的摘要原样刷屏。它留在日志文件里供事后分析，摘要只看 `[自检] 台架刹` 那几行。
	print("[台架刹帧] v0=%3.0f t=%5.2fs v=%6.2f a=%7.3f g=%d/4 off=%5.2f valid=%d band=%d"
		% [v_kmh, t, planar, decel, grounded, off, 1 if valid else 0, 1 if in_band else 0])
	return {
		"t": t, "v": planar, "decel": decel, "grounded": grounded, "off": off,
		"offroad": offroad, "valid": valid, "band": in_band, "v0": v_kmh,
	}


## 把一段窗口的逐帧读数聚成一条格子结论。**只统计有效帧**（见 `_brakebench_sample`）。
func _brakebench_aggregate(samples: Array, v_kmh: float, rep: int) -> Dictionary:
	var empty := {"a_brake": 0.0, "a_peak": 0.0, "a_full": 0.0, "dist": 0.0,
		"t_brake": -1.0, "v_first": -1.0, "v_end": 0.0, "stopped": false,
		"grounded_min": 0, "off_max": 0.0, "valid_n": 0, "band_n": 0, "total_n": 0,
		"v0": v_kmh, "rep": rep}
	var n := samples.size()
	empty["total_n"] = n
	if n == 0:
		return empty
	var valid: Array = []
	for s in samples:
		if bool(s.get("valid", false)):
			valid.append(s)
	var vn := valid.size()
	empty["valid_n"] = vn
	if vn == 0:
		return empty
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var band_sum := 0.0
	var band_n := 0
	var full_sum := 0.0
	var full_n := 0
	var a_peak := 0.0
	var dist := 0.0
	var grounded_min := 4
	var off_max := 0.0
	var v_first := float(valid[0].get("v", 0.0))
	var t_first := float(valid[0].get("t", 0.0))
	for s in valid:
		var d := float(s.get("decel", -1.0))
		var vb := float(s.get("v", 0.0))
		if d >= 0.0:
			full_sum += d
			full_n += 1
			a_peak = maxf(a_peak, d)
			if bool(s.get("band", false)):
				band_sum += d
				band_n += 1
		# 停距：从**首个有效帧**（落地后）积分到最后一帧，与 brake_distance() 理论值对账用
		dist += vb * dt
		grounded_min = mini(grounded_min, int(s.get("grounded", 0)))
		off_max = maxf(off_max, float(s.get("off", 0.0)))
	var last: Dictionary = valid[vn - 1]
	return {
		"a_brake": band_sum / float(maxi(band_n, 1)),
		"a_peak": a_peak,
		"a_full": full_sum / float(maxi(full_n, 1)),
		"dist": dist,
		"t_brake": float(last.get("t", 0.0)) - t_first,
		"v_first": v_first,
		"v_end": float(last.get("v", 0.0)),
		"stopped": float(last.get("v", 0.0)) < BRAKEBENCH_STOP_MPS,
		"grounded_min": grounded_min,
		"off_max": off_max,
		"valid_n": vn, "band_n": band_n, "total_n": n,
		"v0": v_kmh, "rep": rep,
	}


## 跑一格：0° 舵角 + 固定初速度 + 全轮制动，量到刹停为止的减速度。
##
## 摆位与 `_steerbench_run()` 同源（起终点直道、朝赛道前进方向、+0.12m 空中注入初速度，
## 下落段按无效帧过滤），差别只在舵角锁 0、注入即刹。
func _brakebench_run(v_kmh: float, rep: int, track: Node) -> Dictionary:
	var hz := float(Engine.physics_ticks_per_second)
	var total := maxf(1.0, float(track.call("road_length")))
	var sf = track.get("start_finish_t")
	var d := total * float(sf) if sf != null else 0.0
	var fwd: Vector3 = track.call("centerline_forward", d)
	fwd.y = 0.0
	fwd = fwd.normalized()

	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	_car.global_transform = Autopilot.pose_facing(track.call("centerline_point", d) + Vector3(0, 0.12, 0), fwd)
	_car.linear_velocity = fwd * (v_kmh / 3.6)
	# 0° 舵角夹具：隔离纵向（复用 steerbench 已验证的验收夹具，**不动 vehicle.gd**）
	_car.set("steer_fixture_active", true)
	_car.set("steer_fixture_angle", 0.0)
	# 全轮制动：注入前一刻就按住（与玩家按空格等价），落地即刹
	Input.action_press("handbrake")

	var samples: Array = []
	var offroad_streak := 0
	var v_prev := -1.0
	var prev_valid := false
	for i in range(int(hz * BRAKEBENCH_MAX_WINDOW_SEC)):
		await _physics_frame.call()
		var smp := _brakebench_sample(i, hz, v_kmh, v_prev, prev_valid, track)
		samples.append(smp)
		v_prev = float(smp.get("v", 0.0))
		prev_valid = bool(smp.get("valid", false))
		# ⚠ 掐断条件只能是"连续出界"：空中注入后窗口前段 ~0.16s 是下落（invalid），
		#    按 invalid 计数会误掐（steerbench 踩过的坑，见 `_steerbench_run`）。
		if bool(smp.get("offroad", false)):
			offroad_streak += 1
			if offroad_streak >= 6:
				break    # 连续 6 帧（50ms）偏出路 → 本格到此为止，别把撞护栏帧算进来
		else:
			offroad_streak = 0
		# 刹停即止（完全到 0 会被接触求解器拖住，留 0.5 m/s 门限）
		if prev_valid and v_prev < BRAKEBENCH_STOP_MPS:
			break

	Input.action_release("handbrake")
	_car.set("steer_fixture_active", false)
	_car.set("steer_fixture_angle", 0.0)
	return _brakebench_aggregate(samples, v_kmh, rep)


## 刹车台架验收：按初速度分档实测 a_brake（实际可达减速度）。
##
## 用法：godot --path <工程> -- --check=brakebench --level=3
func run_brakebench() -> void:
	var track := _track
	if track == null or _car == null:
		printerr("[自检] 台架刹 ✘ 找不到 Track 或 RaceCar")
		return

	var speeds := [40.0, 60.0, 80.0, 100.0]
	var repeats := BRAKEBENCH_REPEATS

	# μ 自核：真值直接来自 .tres 加载链（LevelConfig.resource_path + friction_multiplier），
	# 不扫虚拟倍率、不引入假设值（不得沿用文档里的 6.0 / 0.7）。
	var cfg: LevelConfig = GameState.current_level()
	# 决策3（2026-10-12 签字）：样本来源（--noai 状态）打印在摘要首行，便于事后核对
	var noai := "--noai" in OS.get_cmdline_user_args()
	print("[自检] 台架刹 启动：初速度 %s km/h × 每格 %d 次；单格最长 %.1fs（刹停即止）；样本来源：%s"
		% [str(speeds), repeats, BRAKEBENCH_MAX_WINDOW_SEC,
		"无 AI 对手（--noai）" if noai else "⚠ 未带 --noai：AI 对手可能干扰直道上的台架车，样本须标注"])
	print("[自检] 台架刹 摆位：起终点直道 + 0° 舵角夹具 + **空中注入初速度**（同 steerbench）；注入即全轮制动（handbrake）")
	print("[自检] 台架刹 a_brake 定义：稳态带 v∈[%.2f·v0, %.2f·v0]（每格独立）内有效帧的平均减速度；峰值/全程另存"
		% [BRAKEBENCH_STEADY_LO, BRAKEBENCH_STEADY_HI])
	if cfg != null:
		print("[自检] 台架刹 μ 自核：%s  friction_multiplier=%.2f（真值来自 .tres 加载链）"
			% [cfg.resource_path, float(cfg.friction_multiplier)])
		print("[自检] 台架刹 注（模型修正 2026-10-12）：friction_multiplier 不是轮胎系数本身——vehicle.gd:_apply_friction 把它乘到 wheel_friction_slip 基础值（race_car.tscn 前 3.0 / 后 2.6）上；真实抓地容量在 apply_level_setup 之后按实际 slip 打印")
	else:
		print("[自检] 台架刹 μ 自核：未读到 LevelConfig，按默认 1.0")

	# 关掉出界兜底，免得台架中途被搬走（与 steerbench / _friction_probe 同做法）
	var prev_recover = _car.get("auto_recover")
	_car.set("auto_recover", false)
	_car.call("apply_level_setup", GameState.effective_speed(), 99,
		cfg.friction_multiplier if cfg != null else 1.0)

	# 抓地容量（2026-10-12 烟测后修正的天花板模型）：apply_level_setup 已把倍率乘进
	# wheel_friction_slip，这里直接读实际值。静载分配下容量 = (前slip+后slip)/2 × g；
	# 制动时载荷前移、前轮 slip 更大，真实容量只会更高，所以这是保守下限。
	var slip_max := 0.0
	var slip_min := 1e9
	for child in _car.get_children():
		if child is VehicleWheel3D:
			var s := float((child as VehicleWheel3D).wheel_friction_slip)
			slip_max = maxf(slip_max, s)
			slip_min = minf(slip_min, s)
	if slip_min > 1e8:
		slip_min = slip_max
	var grip_cap := (slip_max + slip_min) * 0.5 * 9.81
	print("[自检] 台架刹 抓地容量：前轮 slip=%.2f 后轮 slip=%.2f（= tscn 基础值 ×%.2f）→ 静载容量下限 =%.2f m/s²（制动载荷前移只会更高）"
		% [slip_max, slip_min, float(cfg.friction_multiplier) if cfg != null else 1.0, grip_cap])

	var cells: Array = []
	var valid_cells: Array = []
	var invalid_cells := 0
	var geo_cut := 0
	for v_kmh in speeds:
		for r in range(repeats):
			var one: Dictionary = await _brakebench_run(float(v_kmh), r + 1, track)
			cells.append(one)
			var vn := int(one.get("valid_n", 0))
			var bn := int(one.get("band_n", 0))
			# 有效格 = 有效帧够（判据②）；是否采到稳态帧另看 band_n（判据①用）
			var is_valid_cell := vn >= BRAKEBENCH_MIN_VALID_FRAMES
			if is_valid_cell:
				valid_cells.append(one)
				if bn < 3:
					geo_cut += 1
			else:
				invalid_cells += 1
			# 决策2（2026-10-12 签字）：被剔除的格必须显式打 ✘ 并注明原因，不许默默消失
			var mark := ""
			if not is_valid_cell:
				mark = "  ✘ 剔除：有效帧不足（%d < %d）" % [vn, BRAKEBENCH_MIN_VALID_FRAMES]
			elif bn < 3:
				mark = "  ✘ 剔除：几何剔除（0° 直行在进入稳态带前偏出起终点弯 R≈142m，物理留不住）"
			elif not bool(one.get("stopped", false)):
				mark = "  ⚠ 窗口耗尽未停稳（读数有效，仅提示）"
			print("[自检] 台架刹 v0=%3.0f 第%d次 → a_brake=%6.2f 峰值=%6.2f 全程=%6.2f 停距=%6.2fm 刹时=%5.2fs 首帧v=%5.2f 稳态帧=%d 有效帧=%d/%d%s"
				% [float(v_kmh), r + 1, float(one.get("a_brake", 0.0)), float(one.get("a_peak", 0.0)),
				   float(one.get("a_full", 0.0)), float(one.get("dist", 0.0)), float(one.get("t_brake", -1.0)),
				   float(one.get("v_first", -1.0)), bn, vn, int(one.get("total_n", 0)), mark])

	# 汇总矩阵（a_brake m/s²）
	print("[自检] 台架刹 === a_brake 矩阵 (m/s²)：行=初速度 km/h，列=重复次序 ===")
	var header := "[自检] 台架刹   初速度\\重复"
	for r in range(repeats):
		header += "%9d" % (r + 1)
	print(header)
	for v_kmh in speeds:
		var row := "[自检] 台架刹 %9.1f" % float(v_kmh)
		for r in range(repeats):
			var m := 0.0
			for c in cells:
				var same_v := absf(float(c.get("v0", 0.0)) - float(v_kmh)) < 1e-6
				var same_r := int(c.get("rep", 0)) == r + 1
				if same_v and same_r:
					m = float(c.get("a_brake", 0.0))
					break
			row += "%9.2f" % m
		print(row)

	# 还原车辆状态
	_car.set("auto_recover", prev_recover)
	_car.call("apply_level_setup", GameState.effective_speed(),
		cfg.laps_to_finish if cfg != null else 2,
		cfg.friction_multiplier if cfg != null else 1.0)
	_car.call("reset_to_track")

	# 判定：绿 = 夹具可信（数据可用），不代表关卡合格。
	var ok := true
	if valid_cells.is_empty():
		# ② 至少一格有效帧 ≥ 18
		printerr("[自检] 台架刹 ✘ 没有任何一格拿到有效读数（有效帧 < %d）" % BRAKEBENCH_MIN_VALID_FRAMES)
		ok = false
	else:
		# ① 最高有效档 a_brake ≥ 2 m/s²（刹车真的在咬）。
		#    ⚠ 100 km/h 格可能因"0° 舵角直行约 40m 就偏出起终点弯（R≈142m）"被剔除 ——
		#    那是几何限制不是判据失败：落到**最高有效档**并明确打印用了哪档。
		var top_v := -1.0
		var top_a := -1.0
		for c in valid_cells:
			if int(c.get("band_n", 0)) < 3:
				continue
			var cv := float(c.get("v0", 0.0))
			if cv > top_v:
				top_v = cv
				top_a = float(c.get("a_brake", 0.0))
		if top_v < 0.0:
			printerr("[自检] 台架刹 ✘ 所有有效格都没采到稳态帧（v∈[%.2f·v0, %.2f·v0]）—— 可能全部在进入稳态带前就偏出路外"
				% [BRAKEBENCH_STEADY_LO, BRAKEBENCH_STEADY_HI])
			ok = false
		else:
			if top_v < 100.0 - 1e-6:
				print("[自检] 台架刹 注：100 km/h 格无有效稳态读数（0° 直行的几何限制，非判据失败），判据①改用最高有效档 %.0f km/h"
					% top_v)
			# 决策1（2026-10-12 签字；当日烟测后修正天花板模型，见 section 头注）：
			#   抓地容量 = (前slip+后slip)/2 × g（friction_multiplier 已由 _apply_friction
			#   乘进 wheel_friction_slip，不是直接当轮胎系数用）。
			#   a_brake/容量 ≥90% → 轮胎饱和：手刹 30 与 AI 55 等效，B 方案直接用台架值
			#   <70%              → 刹车力受限：AI 的 55 可能更强（线性折算 ≈ a_brake×55/30，
			#                     封顶容量），B 方案签字时须单独评估，不得默认用台架值
			#   70%~90%           → 接近饱和未确认等效，按保守下界复核
			var sat := top_a / grip_cap if grip_cap > 0.0 else 0.0
			if sat >= 0.90:
				print("[自检] 台架刹 饱和判定：a_brake=%.2f / 抓地容量=%.2f = %.0f%%（≥90%%）→ 轮胎已饱和：玩家手刹 30 与 AI 刹车 55 等效，B 方案可直接用台架值"
					% [top_a, grip_cap, sat * 100.0])
			elif sat < 0.70:
				var ai_est := minf(top_a * 55.0 / 30.0, grip_cap)
				print("[自检] 台架刹 饱和判定：a_brake=%.2f / 抓地容量=%.2f = %.0f%%（<70%%）→ 刹车力受限：AI 的 55 可能更强（线性折算估算 ≈%.2f m/s²，未考虑轮胎非线性），B 方案签字时须单独评估，**不得默认用台架值**"
					% [top_a, grip_cap, sat * 100.0, ai_est])
			else:
				print("[自检] 台架刹 饱和判定：a_brake=%.2f / 抓地容量=%.2f = %.0f%%（70%%~90%%）→ 接近饱和未确认等效：B 方案签字时按保守下界复核"
					% [top_a, grip_cap, sat * 100.0])
			if top_a < BRAKEBENCH_MIN_ABRAKE:
				printerr("[自检] 台架刹 ✘ 最高有效档(%.0f km/h) a_brake 只有 %.2f m/s² —— 刹车没生效或读数被污染"
					% [top_v, top_a])
				ok = false
			if ok:
				print("[自检] 台架刹 ✔ 夹具可用：有效格 %d/%d；最高有效档 %.0f km/h a_brake = %.2f m/s²"
					% [valid_cells.size(), cells.size(), top_v, top_a])
	if invalid_cells > 0 or geo_cut > 0:
		print("[自检] 台架刹 注：剔除 %d 格（有效帧不足 %d / 几何剔除 %d）—— 本身是结论：这些初速度在 0° 直行下留不住"
			% [invalid_cells + geo_cut, invalid_cells, geo_cut])
	print("[自检] 台架刹 提示：本项是测量，绿只代表夹具可信；a_brake 真值看上面的矩阵与日志里的 [台架刹帧] 逐帧 dump")
	print("[自检] 台架刹 提示：跨进程复现判据（A/B/C 极差 ≤1%）用 04-Godot启动器/brakebench-repro.ps1（刻意不进 run-all-checks）")
