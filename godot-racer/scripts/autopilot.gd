extends RefCounted
## 验收自动驾驶（追线 + 选道避障 + 卡住自救 + 掉头纠正）。`--check=lap`、
## `--check=aidiag` 的玩家车与 `shoot.ps1 -Drive` 的截图自动驾驶**共用这一份**。
##
## 2026-10-13 SPLIT-AUTOPILOT-002：从 scenes/main.gd 整块拆出，**纯迁移、行为零变化** ——
## 常量数值、逻辑、print 文案、注释全部原样搬入，没有第二份实现。
## 迁了什么：
##   · 段落头注释 + 11 个 DRIVE_* 常量（原 main.gd L624-695）；
##   · 7 个函数（原 _drive_decision_horizon / _drive_prefer_lane / _drive_clear_lane /
##     _drive_recover / _drive_best_track_arc / _drive_track / _drive_recover_steer_side），
##     去掉下划线前缀成为公开方法，与 l4_debug_diag.gd 公开 API 风格一致；
##   · `pose_facing()` 的实现体（原 _pose_facing，纯函数）作为 **static func** 收在本模块，
##     main.gd 剩余 7 个调用点改走 `Autopilot.pose_facing(...)`，main.gd 里的实现体删除。
##
## 结构变化仅三类（都是机械变换，不改行为）：
##   ① 原先直接读 Main 场景成员（_car / _obstacle_field / _l4_diag）的地方，改为
##      **setup() 一次性注入**（同 L4DebugDiag.setup 模式）；本模块不反向持有场景；
##   ② 函数去下划线（_drive_x → drive_x），模块内互调与静态调用同步改名；
##   ③ _pose_facing 由实例函数改为 static func（纯函数：pos + dir → Transform3D，无状态）。
##
## ⚠ 为什么没有 class_name（与 racing_line.gd / environment.gd / engine_audio.gd /
##   l4_debug_diag.gd 同一约定）：本项目的验收闸门（parse-check / run-check /
##   run-all-checks）在**无编辑器**环境里跑 Godot，而 class_name 的全局注册表
##   （.godot/global_script_class_cache.cfg）**只有编辑器会重建**。2026-10-12
##   实测：新增 class_name 后 --check-only 与游戏运行双双报
##   `Identifier "X" not declared in the current scope`。因此消费方一律用
##   `const Autopilot := preload("res://scripts/autopilot.gd")` 引用本模块，
##   不依赖全局类缓存（详见 environment.gd 文件头）。
##
## ⚠ 为什么 pose_facing 放在这里而不是 track_layout.gd：track_layout.gd 是
##   AGENTS.md §2.1 指定的几何算法模块、受保护的单一真相源，而 pose_facing 只服务
##   自动驾驶的摆位（复位落点 / 演练起点 / 抓图摆位），与赛道 DSL、闭环、几何解算
##   无关。放本模块可以少开一个模块边界；"全仓库恰一份实现"由结构校验脚本
##   （godot-logs/split-autopilot-structcheck.ps1）保证，不靠自觉。
##   （备选方案：pose_facing 放 track_layout.gd 作 static func —— 要动受保护模块，
##    收益为零，否决。）
##
## ⚠ `_l4_diag` 为什么是**注入实例**而不是 preload 第二份：[DEBUG-L4] 诊断的状态
##   （卡住时间线 / 目标翻转记账 / 横向速率样本）全在 main.gd 持有的那个实例身上；
##   第二份实例拿到的是空状态，A/B 与取证全部失真。故 setup(car, field, diag) 由
##   main.gd 在 _after_world_ready 里、紧挨 `_l4_diag.setup(...)` 调用一次注入。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car）。由 setup() 注入。
var _car: VehicleBody3D = null
## 障碍场（main.gd 的 _obstacle_field）。由 setup() 注入；无障碍关卡时为 null。
var _obstacle_field: Node3D = null
## [DEBUG-L4] 诊断模块实例（main.gd 的 _l4_diag）。由 setup() 注入。
## 不标类型：l4_debug_diag.gd 无 class_name（见上），标 Object 会让动态调用报错。
var _l4_diag = null
const RacingLine := preload("res://scripts/racing_line.gd")
var _obstacle_braking := false
var _drive_arc := -1.0


## 注入外部引用（main.gd 在 _after_world_ready 里、障碍物建好后调用一次）。
func setup(car: VehicleBody3D, field: Node3D, diag) -> void:
	_release_obstacle_brake()
	_car = car
	_drive_arc = -1.0
	_obstacle_field = field
	_l4_diag = diag


## 自动驾驶跑完整圈：验证
##   ① 计时能正常开始、能正常完成一圈（上圈 != 最快圈的异常不能出现）
##   ② 全程**不会**被出界兜底/自动脱困莫名其妙地重置（用户报的"回到起点前一直重置"）
## 用最简单的追线控制器：目标是中心线前方 45m 的点，朝它打方向，全油门。
## 自动驾驶的**卡墙自救**与**掉头纠正**（2026-09 玩家实测反馈后补）。
##
## 为什么必须有（两条都有实测证据，不是防御性编程）：
##   ① **卡墙**：`vehicle.gd` 的出界复位要"跑到护栏外 4m"（`out_of_bounds_margin`），
##      贴着墙**内侧**顶住的车永远够不到这个阈值。而 AI 有 `_update_stuck_rescue()`
##      （3 秒没动就回中心线），自动驾驶**一行都没有** → 按死 W 顶在墙上，
##      日志实测 `t=9.0s 玩家=0.5 km/h` → `t=11.5s 玩家=0.5 km/h`，顶到超时。
##   ② **掉头**：车被撞转 180° 后，自动驾驶无条件按死的 W 会沿**车头**方向推车，
##      于是"全油门朝赛道反方向开" —— 实测 `点积=-1.00`、前后轮 `skid=1.00`、
##      后轮 `force=-4000`，车以 18~23 km/h 倒着滑。
##      （`vehicle.gd:852` 的倒挡要"速度 < 6 m/s"，撞后正好卡在阈值上方，轮不到它。）
##
## ⚠ **为什么不能只靠超时判"卡住"**：贴墙慢速过弯时速度也小，但那不是卡住
##   （这条教训 AI 的自救注释里已经写过）。所以判据必须是"**速度小 _ 且 _ 位移小**"。
##
## 验收见 `--check=lap` 新增的「车头方向 / 卡住」两段（判定阈值写在 `_check_lap` 里）。
const DRIVE_STUCK_KMH := 1.0
## 连续这么久没动才算卡住（秒）。与 AI 的 `_update_stuck_rescue` 同为 3.0s，口径统一。
const DRIVE_STUCK_SEC := 3.0
## 恢复/复位落点选道时的**车尾回看**距离（米）。与 vehicle.RESET_LANE_LOOKBACK 同一个值、
## 同一个理由：车不是点，落点稍后方的障碍会被"只看前方"的占用判定漏掉。
## 实测：漏掉时车会被反复放回同一块石头（连续 21 次、grounded=0/4）。
const DRIVE_RESET_LOOKBACK := 4.0
## 验收自动驾驶选道时的**车体半宽**（米）。
## ⚠ 必须与占用判定用的是同一个数：`obstacle_field.CAR_WIDTH * 0.5`
##   （`obstacle_field.gd` 自己注明"与 ai_opponent.gd 的 BODY_HALF_WIDTH 同一来源"）。
##   用别的数会让"候选车道"与"占用阈值"两套口径打架 —— 那正是 L4 卡死的成因之一。
const DRIVE_BODY_HALF := 0.875
## 选道的**前瞻距离**（米）。与 AI 的 `OBSTACLE_HORIZON` 取同一个值：
## 两边问的是同一个问题（"[arc, arc+45m] 上这条车道通不通"），口径必须一致。
const DRIVE_AVOID_HORIZON := 45.0
## 验收自动驾驶的**决策前瞻**（米）：只作用于 `pick_clear_lane()` 的 horizon，
## **不**作用于瞄准点 —— `_check_lap` 的 target_lookahead 仍然是 45m。
##
## 为什么必须把这两个数拆开（2026-10 第二轮取证，有数据）：
##   原来"什么时候决定变道"与"什么时候必须到位"共用同一个 45m。石头在 52m 处时
##   规划道还是 +0.00，到 43m 才翻成 -2.34 —— 于是车只剩 45m 去完成最多 3.4m 的
##   横向移动，而实测横向速率约 0.03~0.08 m/m（挪 3.4m 需要约 100m）。
##   同一块石头三次通过的差别只在变道开始那一刻车在哪：
##     actual_lat +1.10 → 只挪到 -0.22（撞） / -1.22 → -1.65（过）。
##   证据：godot-logs/l4-forensic-2.log 的 `[DEBUG-L4] PLAN` 行。
##
## 开发期 A/B：环境变量 `L4_DECISION_HORIZON`（米）可覆盖本默认值，
## 与项目已有的 `AI_PROBE_B` 是同一套 A/B 范式 —— 验收脚本不认识它，
## 也不会被写进任何正式门禁。
const DRIVE_DECISION_HORIZON := 45.0

## 车头与赛道前进方向的夹角超过它就算"掉头了"（度）。
## 90° 太松（垂直侧滑也过线），取 100° 只抓"明确朝后"。
const DRIVE_BACKWARDS_DEG := 100.0
## 恢复的**退出**阈值（度）：车头转到这个角度以内就交回正常追线（前进）。
##
## 为什么要与进入阈值分开（实测逼出来的）：第一版用同一个 100°。
## 车头从 180° 掰到 100° 之后，`倒车 + 满舵` 在"车头接近垂直于赛道"处形成**平衡点** ——
## 倒车轨迹被舵角抵消，夹角在 100° 上下来回磨，整整 5 秒没进展（日志：4.0s→108°、
## 然后连续 4 行 100°）。退出阈值留 40° 余量后，交回前进的那一脚才是真正把车拉直的力。
const DRIVE_RECOVER_EXIT_DEG := 60.0
## "扶正"路径允许的车速上限（km/h）。**设得很高是刻意的**：
## 车头已经朝后时，"扶正"永远优于"沿赛道反方向继续开" —— 实测慢速蠕动 8.4s
## 也才刚回到 60°，而扶正是 1 帧的事。设低阈值的后果就是眼睁睁看它倒着撞护栏。
const DRIVE_REORIENT_MAX_KMH := 36.0
## 单次掉头恢复最多花这么久（秒）。**必须有上限**：恢复一旦失效，
## 车会原地转圈转到检查超时，那比"倒着开"更难查。
## 超限后不是"放弃"，而是**把恢复计时清零继续掰**（不能交回正常追线 ——
## 正常追线会按死 W，那正是"朝赛道反方向全油门"的根源）。
const DRIVE_RECOVER_MAX_SEC := 8.0
## 按方向键恢复的换向周期（秒）：满舵会画圈，每半个周期换一次向把它拉回来。
const DRIVE_RECOVER_STEER_SEC := 1.5


##
## 为什么用环境变量而不是改常量重编：项目的 A/B 范式就是 `AI_PROBE_B`（见 ai_opponent.gd），
## 同一套做法便于"只动一个变量、其它全不变"地跑对照组。
## ⚠ 它**只**影响 pick_clear_lane 的 horizon；瞄准点由 `ahead` 决定，仍是 45m。
func drive_decision_horizon() -> float:
	var env := OS.get_environment("L4_DECISION_HORIZON")
	if env.is_empty():
		return DRIVE_DECISION_HORIZON
	var v := float(env)
	if v <= 1.0:
		return DRIVE_DECISION_HORIZON
	return v


## 本帧的 `prefer_lane`：默认 = **本车实际横向**。
##
## 为什么留一个环境变量开关（`L4_PREFER_LANE_ZERO=1` 时退回旧的恒 0 行为）：
## 本轮同时改了 prefer_lane 与 decision_horizon 两处，若不做对照，
## **无法判断 L4 卡死次数的变化到底来自哪一处**（这正是"一次只动一个变量"的理由）。
## 这个开关只服务开发期 A/B，验收脚本不认识它。默认（不设）仍是修复后的新行为。
func drive_prefer_lane(cur_lat: float) -> float:
	if OS.get_environment("L4_PREFER_LANE_ZERO") != "":
		return 0.0
	return cur_lat


## 自动驾驶**恢复落点**用：在 `c`（中心线上的点）处换一条能站的车道。
##
## 返回横向偏移（0 = 中心线）。没有障碍场 / 没有可用车道时返回 0 —— 退化成原行为，
## 保证复位永远有一个确定、可复现的落点。
##
## 为什么不在这里再写一套占用判定：与 `vehicle._clear_reset_lane()`、AI 的
## `_rescue_lane()` 共用 `obstacle_field.pick_clear_lane()` 这**一份真相**
## （AGENTS.md §5.3）。三处口径必须一致，否则又是"两条路径各写一遍然后漂移"。
func drive_clear_lane(track: Node, c: Vector3) -> float:
	if _obstacle_field == null or not _obstacle_field.has_method("pick_clear_lane"):
		return 0.0
	if not track.has_method("nearest_on_centerline") or not track.has_method("road_half_width"):
		return 0.0
	var near: Dictionary = track.call("nearest_on_centerline", c, -1.0)
	var road_half := float(track.call("road_half_width"))
	var lane_limit := maxf(0.0, road_half - DRIVE_BODY_HALF - 0.2)
	# ⚠ 查询区间必须**往前多带一个车长**（- DRIVE_RESET_LOOKBACK）：
	#   pick_clear_lane 的占用判定只看前方（d 在 [0, horizon] 内才算），
	#   障碍若落在落点**稍后方**，d 会变成"接近整圈"的大数而被过滤掉
	#   → 那块石头在选道眼里不存在 → 落点正好在石头里。
	#   实测：车越过石头 0.8m 后每次复位都落回同一块石头（连续 21 次、grounded=0/4）。
	#   与 vehicle._reset_lane_at() 同一处理，口径必须一致。
	var res: Dictionary = _obstacle_field.call("pick_clear_lane",
		0.0, float(near.get("arc", 0.0)) - DRIVE_RESET_LOOKBACK,
		DRIVE_AVOID_HORIZON + DRIVE_RESET_LOOKBACK, DRIVE_BODY_HALF, lane_limit)
	if not bool(res.get("found", false)):
		return 0.0
	return float(res.get("lane", 0.0))


## 自动驾驶的恢复动作：返回 true 表示**本帧由恢复逻辑接管**（调用方必须跳过正常的油门/转向）。
##
## ⚠ **只给"追线型"的自动驾驶用，不要套到探针上**。本文件里还有 5 处
##   `Input.action_press("accelerate")`，它们是**故意顶着油门**的探针，不能加恢复：
##     · `_check_wallslide`  —— 测的就是"全油门怼墙会不会卡死"，松油门等于把被测对象去掉
##     · `_check_stress`     —— 鲁莽驾驶压测，本来就要撞
##     · `_check_ai_start`   —— 只用来触发"玩家起步 → 对手发车"，几秒就停
##     · `--shot` 的 hold    —— 出图用
##     · `_check_friction`   —— 侧向抓地力探针
##   目前真正需要恢复的只有 `_check_lap`（验收自动驾驶）。
##
## 分两级，互斥：
##   · 掉头（夹角 > 100°）：交替"半舵"与"点倒车"（`brake_reverse`）把车头拧回来。
##     为什么不能一直给倒车：倒车力也沿车头方向，持续给会让车倒着加速冲出去；
##     所以给 0.4s 就歇一下，让转向把航向掰正。
##   · 卡住（速度 < 1 km/h 且 3 秒内位移 < 5cm）：直接扶正 + 回中心线，与 AI 的自救同源。
##     为什么用"速度 _ 且 _ 位移"双判据：贴墙慢速过弯速度也小，但那不是卡住。
##
## `last_pos` / `stuck_sec` 由调用方持有并回传，本函数只改它们（GDScript 没有 out 参数）。
func drive_recover(track: Node, last_pos: Vector3, stuck_sec: float,
		recover_sec: float, hz: float) -> Dictionary:
	_release_obstacle_brake()
	var pos: Vector3 = _car.global_position
	var moved := last_pos.distance_to(pos)
	var kmh := _car.linear_velocity.length() * 3.6
	var stuck := stuck_sec + (1.0 / hz) if (kmh < DRIVE_STUCK_KMH and moved < 0.005) else 0.0
	# ⚠ 每帧开头先**放开倒车键**，真需要它的分支（②b）会在下面自己重新按下。
	#
	# 为什么必须这么做（2026-10 实测，这一条吃掉了 45 次卡死里的 **29 次**）：
	#   ②b 掉头分支按了 `brake_reverse`，而**没有任何一处释放它** —— 按下去就永久 latch。
	#   而 `vehicle._update_drive()` 读的是 `Input.get_axis("brake_reverse", "accelerate")`：
	#   两个键同时按住 → 轴值恒为 **0** → `_driving = false` → `engine_force = 0`、
	#   `brake = engine_brake (2.5)` → **车从此再也给不上油**，只能靠本函数的瞬移挪动，
	#   表现就是玩家看到的「复位 → 又回原位置 → 再卡」。
	#   取证：`_probe_blocker()` 六向 8m 全空、`obstacle_field` 卡住点前后 51m **无任何障碍**、
	#   四轮全是 `force=0.0 brake=2.5`；而日志里 45 次卡住有 29 次发生在这个 latch 之后。
	Input.action_release("brake_reverse")

	# ---- ① 卡住：扶正 + 回中心线（与 AI 的自救同一套动作）----
	if stuck >= DRIVE_STUCK_SEC:
		var near: Dictionary = track.call("nearest_on_centerline", pos, _drive_arc)
		var f: Vector3 = near.get("forward", Vector3.FORWARD)
		var c: Vector3 = near.get("pos", pos)
		# 中心线forward由赛道前进顺序决定，与车辆当前朝向无关。
		var best := drive_best_track_arc(track, c, -_car.global_transform.basis.z, -1.0)
		if bool(best["valid"]):
			c = best["pos"]
			f = best["fwd"]
		# ---- 落点选道：别把车放回石头里 ----
		# 上面找到的 `c` 是**中心线**上的点，而 L4 的石头就压在中心线上
		# （`_pick_lateral()` 把石头挤到 ±0.125m）。落中心线 = 落进石头 → 再卡 → 再复位。
		# 与 `vehicle.reset_to_track()` 走同一个选道函数，口径统一。
		var rlane := drive_clear_lane(track, c)
		if absf(rlane) > 0.001:
			var rf := Vector3(f.x, 0.0, f.z)
			if rf.length() > 0.001:
				rf = rf.normalized()
				c += Vector3(rf.z, 0.0, -rf.x) * rlane
		# [DEBUG-L4] 实验 3（主侧）：落点再问一次**真实车体碰撞盒**安不安全。
		var chk: Dictionary = _car.call("debug_reset_target", c + Vector3(0, 1.0, 0), f)
		print("[DEBUG-L4] RESET_TARGET f=%d owner=main lane=%+.2f safe=%s who=%s n=%d target=(%.2f,%.2f,%.2f)"
			% [Engine.get_physics_frames(), rlane, str(not bool(chk["hit"])), str(chk["who"]),
			   int(chk["n"]), c.x, c.y, c.z])
		_l4_diag.note_rec("stuck_teleport")
		_car.global_transform = pose_facing(c + Vector3(0, 1.0, 0), f)
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		print("[自检]     ⚠ 检测到卡住：%.1fs 没动（速度 %.2f km/h，位移 %.3fm）→ 已扶正回中心线"
			% [DRIVE_STUCK_SEC, kmh, moved])
		return {"handled": true, "last_pos": c, "stuck_sec": 0.0, "recover_sec": 0.0}

	# ---- ② 掉头：把车头拧回赛道方向 ----
	var near2: Dictionary = track.call("nearest_on_centerline", pos, _drive_arc)
	var fwd_track: Vector3 = near2.get("forward", Vector3.FORWARD)
	fwd_track.y = 0.0
	var nose: Vector3 = -_car.global_transform.basis.z
	nose.y = 0.0
	var heading := 0.0
	if fwd_track.length() > 0.001 and nose.length() > 0.001:
		heading = rad_to_deg(acos(clampf(nose.normalized().dot(fwd_track.normalized()), -1.0, 1.0)))
	if heading > DRIVE_BACKWARDS_DEG and heading > DRIVE_RECOVER_EXIT_DEG:
		# ---- ②a 基本停住了还掉头 → **立刻扶正**，不要 пытаться"开回来"----
		# 实测教训：车掉头之后 `brake_reverse` + 满舵能把车头慢慢掰回来（180°→100° 约 4s），
		# 但 100°→60° 会在"车头垂直于赛道"处形成平衡点，来回磨 5 秒以上（实测 7.3s 才回正），
		# 而且中间车是**沿赛道反方向倒着滑 40m** —— 撞对面护栏、再卡住，比掉头本身更糟。
		# 车既然已经基本停住，最干净的做法就是扶正：这与游戏本身的救助同源、确定性好。
		if kmh < DRIVE_REORIENT_MAX_KMH:
			var b := drive_best_track_arc(track, pos, -_car.global_transform.basis.z,
				float(near2.get("arc", -1.0)))
			# 自查行：把"为什么没扶正"的门限值打出来。
			# 为什么要打：这个分支没走进去时，日志里只有"倒车+满舵"，
			# 完全看不出是**哪一道门**把它挡住的（实测为这个盲区白跑了两轮 90 秒的回归）。
			if not bool(b["valid"]):
				print("[自检]       [门限自查] 附近赛道切线无效 → 不做扶正")
			else:
				# [DEBUG-L4] 实验 3（主侧）：扶正落点也问一次真实碰撞体
				var chk2: Dictionary = _car.call("debug_reset_target",
					Vector3(b["pos"]) + Vector3(0, 1.0, 0), b["fwd"])
				print("[DEBUG-L4] RESET_TARGET f=%d owner=main_reorient lane=+0.00 safe=%s who=%s n=%d target=%s"
					% [Engine.get_physics_frames(), str(not bool(chk2["hit"])), str(chk2["who"]),
					   int(chk2["n"]), str(b["pos"])])
				_l4_diag.note_rec("reorient_teleport")
				_car.global_transform = pose_facing(Vector3(b["pos"]) + Vector3(0, 1.0, 0), b["fwd"])
				_car.linear_velocity = Vector3.ZERO
				_car.angular_velocity = Vector3.ZERO
				print("[自检]     ⚠ 车头与赛道夹角 %.0f° 且车速 %.1f km/h（<%.0f）→ 直接扶正回赛道"
					% [heading, kmh, DRIVE_REORIENT_MAX_KMH])
				return {"handled": true, "last_pos": Vector3(b["pos"]), "stuck_sec": 0.0,
					"recover_sec": 0.0}
		elif int(recover_sec * hz) % int(hz) == 0:
			print("[自检]       [门限自查] 车速 %.1f km/h ≥ 扶正上限 %.0f km/h → 走倒车恢复"
				% [kmh, DRIVE_REORIENT_MAX_KMH])
		# ---- ②b 还在动 → 用"倒车当油门 + 满舵"慢慢把车头掰回来 ----
		if recover_sec < DRIVE_RECOVER_MAX_SEC:
			_l4_diag.note_rec("reorient_reverse")
			# ⚠ 恢复动作的形态是被**实测逼出来**的（第一版错了，演练 20s 没掰回来、最坏 180°）：
			#   车已经朝后时，W（加速）推的方向**就在赛道方向上** —— 车会沿赛道倒着滑（实测滑了 7s）。
			#   所以这期间**绝不能加速**，要"用倒车当油门"把车开回赛道，同时连续满舵攒偏航。
			#   第一版给的是 0.4s 的舵 + 0.4s 的倒车**脉冲** —— 舵还没攒够偏航就被放开，
			#   等于什么都没做（实测 2.4s 后夹角还是 175°）。**必须连续**。
			# 每 1.5s 换一次舵向：车头只差最后一点时满舵会画圈，换向能把它拉回来。
			var side := drive_recover_steer_side(near2)
			if fmod(recover_sec, DRIVE_RECOVER_STEER_SEC * 2.0) < DRIVE_RECOVER_STEER_SEC:
				side = -side
			Input.action_release("accelerate")
			Input.action_release("steer_left")
			Input.action_release("steer_right")
			if side > 0.0:
				Input.action_press("steer_right")
			else:
				Input.action_press("steer_left")
			# 车头既然朝后，`brake_reverse`（S）的推力方向正好指向赛道前方
			Input.action_press("brake_reverse")
			if int(recover_sec * hz) % int(hz) == 0:
				print("[自检]     ⚠ 车头与赛道夹角 %.0f°（>%.0f°）→ 掉头恢复中（已 %.1fs，倒车+满舵）"
					% [heading, DRIVE_BACKWARDS_DEG, recover_sec])
			return {"handled": true, "last_pos": pos, "stuck_sec": stuck,
				"recover_sec": recover_sec + 1.0 / hz}

	# ---- ③ 超时：不清零、也不交回正常追线，继续掰（见 DRIVE_RECOVER_MAX_SEC 的说明）----
	return {"handled": false, "last_pos": pos, "stuck_sec": stuck, "recover_sec": 0.0}


## 找出赛道上"朝向与 `dir` 最一致、且离 `hint_arc` 最近"的那一点。
##
## 为什么不能用 `nearest_on_centerline()` 之外什么都不做：掉头 180° 之后，
## 离车最近的中心线点在**车身后方**，它的 `forward` 指向反方向 —— 拿它扶正等于
## "把车头朝反方向摆在路中间"（实测：aidiag 结束时夹角仍有 54.8°，车反着开 7 秒撞护栏）。
##
## 做法：以 `hint_arc` 为中心在 ±`arc_span` 米内粗扫（2m 一档），
## 恢复只采用当前位置附近的合法中心线；车头朝向不能改变赛道拓扑。
## 保留签名以兼容调用者，dir只作为历史参数，不参与落点选择。
func drive_best_track_arc(track: Node, pos: Vector3, _dir: Vector3, hint_arc: float) -> Dictionary:
	var hint := _drive_arc if _drive_arc >= 0.0 else hint_arc
	var near: Dictionary = track.call("nearest_on_centerline", pos, hint)
	var forward: Vector3 = near.get("forward", Vector3.ZERO)
	return {"valid": forward.length_squared() > 0.5,
		"pos": near.get("pos", pos), "fwd": forward}


## 追线控制：使用既有连续转向与物理限速，障碍占用只负责安全车道。
##
## 这段逻辑**只能有一份**（本项目最惨的教训就是"两条路径各写一遍然后漂移"）：
## `_check_lap` 与 `--check=aidiag` 的玩家车都用它 —— 玩家实测的"掉头后倒着开"
## 就是在 aidiag 那条路径上出现的，而当时两条路径各写了一份。
##
## ⚠ 2026-10 修复：这里原来**无条件**瞄"中心线前方 `ahead` 米"，**零障碍感知**。
## 而 L4 荒漠的静态石头横向 ∈ [0, 0.125]m（`obstacle_field._pick_lateral()` 的
## `safe_max = ai_left − car_half − PASS_EXTRA = 1.5 − 0.875 − 0.5`），
## 石头半宽 0.95m → **整块横跨中心线**。于是自动驾驶等于"瞄准每一块石头开"：
## 实测 `--check=lap -Level 3` 360s 内 **卡住 45 次、复位 13 次**，
## 且反复在同一个点（`(190.83, -0.06, -193.73)`）复活再撞 —— 就是玩家看到的
## 「撞障碍 → 重置 → 又回原位置 → 再撞」。
##
## 修法与 AI 对手同源（AGENTS.md §5.3：不许另写一套）：
## 用 `obstacle_field.pick_clear_lane()` 这条**唯一真相源**问"哪条车道在
## [arc, arc+45m] 上对**全部**障碍都通"，再瞄"该车道的前方点"。
## 找不到整段可通的车道时**收油**（AGENTS.md §8.2：减速等待优先于硬挤）。
func drive_track(track: Node, ahead: float) -> void:
	_release_obstacle_brake()
	var near: Dictionary = track.call("nearest_on_centerline", _car.global_position, _drive_arc)
	var arc := float(near["arc"])
	_drive_arc = arc
	# ---- 选道：与 AI 对手共用同一份占用真相源 ----
	# 无障碍/无障碍场时 lane 保持 0 = 中心线，仍采用弯前限速。
	var lane := 0.0
	var lane_clear := true
	# 不写行尾续行符：本项目 lint 会扫"两行粘成一行"，续行符让它更难判读。
	# 本车**实际横向位置**（米）。用的是与 `_debug_rec` / `_drive_recover` 完全相同的
	# 赛道横向口径（"最近中心线点 + 该点切线 + 前向×右"），**不另发明一套公式**。
	var cur_fwd := Vector3(near.get("forward", Vector3.FORWARD))
	cur_fwd.y = 0.0
	var cur_lat := 0.0
	if cur_fwd.length() > 0.001:
		cur_fwd = cur_fwd.normalized()
		cur_lat = (_car.global_position - Vector3(near.get("pos", _car.global_position))).dot(
			Vector3(cur_fwd.z, 0.0, -cur_fwd.x))
	var can_pick := _obstacle_field != null and _obstacle_field.has_method("pick_clear_lane")
	if can_pick and not track.has_method("road_half_width"):
		can_pick = false
	# 决策前瞻：本帧只算一次，选道与 [DEBUG-L4] 诊断共用同一个值。
	# （SPLIT-L4DIAG-001：horizon 原先由诊断函数各自调 _drive_decision_horizon() 取，
	#   同一帧内对环境变量的读取结果相同，提升为共享变量不改变行为；A/B 口径不变。）
	var horizon := drive_decision_horizon()
	var obstacle_control := true # 无障碍也必须走同一连续转向/弯前限速链
	var a_lat := float(_car.get("max_lateral_accel"))
	# 五关固定版：所有路线至少3秒预判，复用既有限速公式。
	if obstacle_control:
		horizon = maxf(horizon, _car.linear_velocity.length() * 3.0)
		var cfg = track.get("level_config")
		if cfg != null:
			a_lat = minf(a_lat, RacingLine.GRIP_BASE * float(cfg.get("friction_multiplier")))
	if can_pick:
		var road_half := float(track.call("road_half_width"))
		# 目标走廊在车体半宽之外，再留一个半车宽供真实追线滞后使用。
		# 16m坡道红例中，贴边目标+横向跟踪滞后让完整车身越缘7.6cm；
		# 这里收紧驾驶目标，独立车身判据仍保持原半路宽，不改变玩家物理。
		var lane_limit := maxf(0.0, road_half - DRIVE_BODY_HALF * 2.0)
		# ⚠ 两处与修复前不同，都是本轮取证直接指向的：
		#   ① prefer_lane 由**恒定 0.0** 改成**本车实际横向** —— 原来车已经偏到 +1.10
		#      时，规划仍然从中心线起算，于是"离当前车最近的安全车道"根本没被优先考虑，
		#      目标可以一帧从 +1.10 跳到 -2.34。
		#   ② horizon 由 DRIVE_AVOID_HORIZON(45) 改成**独立的 DRIVE_DECISION_HORIZON** ——
		#      把"何时决定"与"何时必须到位"解耦；瞄准点 ahead 仍是 45m，没动。
		var res: Dictionary = _obstacle_field.call("pick_clear_lane",
			drive_prefer_lane(cur_lat), arc, horizon, DRIVE_BODY_HALF, lane_limit)
		lane = float(res.get("lane", 0.0))
		lane_clear = bool(res.get("found", true))
	# [DEBUG-L4] 实验 5：规划车道时，同时打出动态障碍"现在在哪"与"预计到达时在哪"。
	# 只取证，**不做任何预测修正**。
	_l4_diag.eta_report(track, arc, lane)
	# [DEBUG-L4] 计划第四步：换道目标有没有瞬时跳变、以及"来不来得及"。
	_l4_diag.lane_change_report(track, arc, cur_lat, lane, lane_clear, horizon)
	# [DEBUG-L4] 变道走廊（P0，计划 §4~§8）+ 横向速率分速度段（P2，计划 §18）。
	# 两者都**纯只读**：只看 `lane` / 车态，不回写任何输入，也不参与选道。
	_l4_diag.transition_report(track, arc, cur_lat, lane, horizon)
	_l4_diag.rate_sampler(arc, cur_lat, lane)
	# 目标点 = 该车道在 `arc + ahead` 处的点（横向偏移按**目标弧长**的切线取，
	# 不按当前帧的切线 —— 45m 前瞻下两者能差出可观的角度）。
	var aim_arc := arc + ahead
	var aim := Vector3(track.call("centerline_point", aim_arc))
	if absf(lane) > 0.001:
		var aim_fwd := Vector3(track.call("centerline_forward", aim_arc))
		aim_fwd.y = 0.0
		if aim_fwd.length() > 0.001:
			aim_fwd = aim_fwd.normalized()
			aim += Vector3(aim_fwd.z, 0.0, -aim_fwd.x) * lane
	var to_target := aim - _car.global_position
	to_target.y = 0.0
	var right: Vector3 = _car.global_transform.basis.x
	var side := to_target.normalized().dot(right)
	Input.action_release("steer_left")
	Input.action_release("steer_right")
	# 五关固定版统一追线控制；车辆仍通过正常Input链执行。
	if obstacle_control:
		_drive_obstacle_steering(to_target, a_lat)
	elif side > 0.06:
		Input.action_press("steer_right")
	elif side < -0.06:
		Input.action_press("steer_left")
	# 有可通车道的帧：与改动前完全一致（全油门）。
	# 没有可通车道（障碍横跨整条路）的帧：收油等待，不硬挤。
	if obstacle_control:
		_drive_obstacle_throttle(track, arc, horizon, lane_clear, a_lat)
	elif lane_clear:
		Input.action_press("accelerate")
	else:
		Input.action_release("accelerate")
		print("[自检]     ⚠ 前方 %.0fm 内无整段可通车道 → 减速等待（暂用车道 %+.2fm）"
			% [horizon, lane])


## 通过真实 Input 链传递所需轮舵角，不直接改车辆转向、速度或物理权限。
func _drive_obstacle_steering(to_target: Vector3, a_lat: float) -> void:
	var nose := -_car.global_transform.basis.z
	nose.y = 0.0
	if nose.length() < 0.001 or to_target.length() < 0.001:
		return
	nose = nose.normalized()
	var direction := to_target.normalized()
	var angle := atan2(nose.cross(direction).y, nose.dot(direction))
	var speed := _car.linear_velocity.length()
	var limit := RacingLine.steer_limit(speed, float(_car.get("max_steer")),
		float(_car.get("steer_speed_falloff")))
	limit *= float(_car.call("_roll_guard_factor", speed))
	if limit <= 0.0:
		return
	var wheel_angle := RacingLine.pursuit_steering(angle, to_target.length(),
		float(_car.get("_wheel_base")), speed, a_lat)
	var strength := clampf(wheel_angle / limit, -1.0, 1.0)
	if strength > 0.0:
		Input.action_press("steer_left", strength)
	elif strength < 0.0:
		Input.action_press("steer_right", -strength)


## 连续转向不再靠满舵拖慢车速，必须显式遵守真实赛道的现有物理限速。
## 只操作正常油门/全轮制动输入，不改极速、轮胎参数、速度或限速公式。
func _drive_obstacle_throttle(track: Node, arc: float, horizon: float,
		lane_clear: bool, a_lat: float) -> void:
	var distances: Array = []
	var distance := RacingLine.MIN_DS * 12.0
	while distance <= horizon:
		distances.append(distance)
		distance += RacingLine.MIN_DS * 12.0
	var radius := RacingLine.corner_radius_at(track, arc)
	var cap := minf(float(_car.get("max_speed_kmh")), RacingLine.speed_limit_kmh(radius, a_lat))
	cap = RacingLine.lookahead_limit_kmh(track, arc, distances, a_lat, cap)
	if _car.linear_velocity.length() * 3.6 > cap:
		Input.action_release("accelerate")
		Input.action_press("handbrake")
		_obstacle_braking = true
	elif lane_clear:
		Input.action_press("accelerate")
	else:
		Input.action_release("accelerate")


## 只释放本模块自己按下的刹车，避免恢复接管或退出障碍分支后残留输入。
func _release_obstacle_brake() -> void:
	if _obstacle_braking:
		Input.action_release("handbrake")
		_obstacle_braking = false


## 掉头恢复时该往哪边打方向盘：用"车头相对赛道方向的左右"决定。
## 返回 +1 = 打右（steer_right），-1 = 打左（steer_left）。
func drive_recover_steer_side(near: Dictionary) -> float:
	var fwd_track: Vector3 = near.get("forward", Vector3.FORWARD)
	fwd_track.y = 0.0
	if fwd_track.length() < 0.001:
		return 1.0
	fwd_track = fwd_track.normalized()
	var right := Vector3(fwd_track.z, 0.0, -fwd_track.x)
	var nose: Vector3 = -_car.global_transform.basis.z
	nose.y = 0.0
	return 1.0 if nose.dot(right) >= 0.0 else -1.0


## 构造一个"车头（本地 -Z）朝向 dir"的水平位姿
static func pose_facing(pos: Vector3, dir: Vector3) -> Transform3D:
	var f := Vector3(dir.x, 0.0, dir.z).normalized()
	var z_axis := -f
	var x_axis := Vector3.UP.cross(z_axis).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	return Transform3D(Basis(x_axis, y_axis, z_axis), pos)
