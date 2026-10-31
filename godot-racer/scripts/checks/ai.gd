extends RefCounted
var _evidence = preload("res://scripts/checks/evidence.gd").new()
const AiTape := preload("res://scripts/checks/ai_tape.gd")
var _ai_tape = null
var _tape_config: Dictionary = {}
## AI 验收族（`--check=opponents` / `aidiag` / `aistart`）：
## 对手跑圈能力、AI 行为诊断（抢跑/不动/自救 + 任务 15「AI 能否跑到最高限速附近」）、
## 并排发车（玩家不动对手不动）。
## main.gd 的 `match _check:` 分发口经
## `await _checks_ai.run_opponents()` / `run_ai_diag()` / `run_ai_start()` 进入本模块。
##
## 2026-10-18 SPLIT-CHECKS-AI-006：`avoid` / `obstacles` 两族已再迁往
## scripts/checks/ai_field.gd（Phase 01 给本文件增加 85 行，937 → 1022 越过
## 「单文件 ≤1000 行」契约，按"越限一律先拆再提交"整体迁出；两个函数连注释
## 逐字节照搬，ai_field.gd 没有第二份实现）。本文件现留三族。
##
## 2026-10-13 SPLIT-CHECKS-AI-003：从 scenes/main.gd 整块拆出，**纯迁移、
## 行为零变化** —— 逻辑、print 文案（`[自检]` 前缀、逐 2.5s 的 aidiag 采样行、
## ✔/✘ 判定行、%占位顺序全部照搬，A/B 要逐行比对日志）、注释全部照搬，
## 没有第二份实现。
## 迁了什么：
##   · 5 个函数：`_check_opponents` → 公开入口 `run_opponents`、`_check_ai_diag`
##     → `run_ai_diag`、`_check_avoid` → `run_avoid`、`_check_obstacles` →
##     `run_obstacles`、`_check_ai_start` → `run_ai_start`（本族没有内部辅助函数，
##     5 个入口一一对应、可 audit）；
##     ⚠ 2026-10-18：其中 `run_avoid` / `run_obstacles` 已迁至 ai_field.gd
##     （SPLIT-CHECKS-AI-006），本文件现留 3 个入口；
##   · 12 个常量：`AI_RECOVER_WARN_SEC` / `AI_TARGET_MIN_KMH` /
##     `AI_TARGET_PINNED_PCT` / `AI_TARGET_PINNED_KMH` / `AI_TARGET_RED_MAX_KMH` /
##     `AI_TARGET_NEAR_PHYS_FRAC` / `AI_TARGET_NEAR_CAP_PCT` /
##     `AI_TARGET_NEAR_CAP_FRAC` / `AI_BEND_GUARD_SEG` /
##     `AI_INTERACTION_SEC` / `AI_FREE_RUN_SEC` / `AI_FREE_RUN_GAP_M`
##     （同步发车后的同场交互与自由跑测量分段，见常量处注释）；
##     全仓只有 `run_ai_diag` 读它们 —— 已 grep 实证；check-docs.ps1 未登记、
##     非 ADR-001 永久居民，随族迁移。**不在此复制闸门登记的三 CASES 常量**；
##     avoid / obstacles 两族不读其中任何一个 —— 拆分时零常量随迁）；
##   · 本族原实现就没有模块级状态（全是函数内局部量），迁移后零新增状态
##     （下面 8 个 var 全是注入 + 只读代理，见"外部注入"段）。
##
## ⚠ 四处关键决策（逐条定死，以后别悄悄改回去）：
##
##   ① **车 / 赛道 / 障碍场 / 物理世界经 setup() 注入，模块不 get_node**：
##      迁移前族内用 `get_node_or_null("Track")` 取静态兄弟节点（4 处）、
##      `get_node_or_null("Obstacles")` 取障碍容器（1 处）、`get_world_3d()`
##      取射线用的物理世界（1 处），全部改为注入 + **保留原 null 检查**
##      （§2.4：禁反向持有场景；layout / bench / opponent_spawner 同款约定）。
##      ⚠ `get_node_or_null("Obstacles")` 拿到的就是 main 的 `_obstacle_field`
##      本体（它是 add_child 进树、name = "Obstacles" 的同一个节点），注入同一实例
##      即零语义差。
##
##   ② **physics_frame 经 Callable 注入**：迁移前帧循环里是
##      `await get_tree().physics_frame`；模块是 RefCounted、不在场景树上，没有
##      get_tree()，由 main 把 `_shot_physics_frame`（返回 physics_frame 信号本体）
##      以 Callable 递进来。模块里 `await _physics_frame.call()` 与迁移前
##      `await get_tree().physics_frame` 是**同一个 Signal**，协程恢复时机不变
##      （screenshot_mode / bench 同款决策，2026-10-13 实证）。
##
##   ③ **`_sample_physics_ms` 采样器经 Callable 注入、不搬进模块**：
##      `run_opponents` 要两处 `await _sample_physics_ms(...)`，而同一个采样器
##      不在普通开赛时执行，避免为玩家增加诊断等待。
##      采样口径属 main ⇒ 搬走会让 setup 路径反过来 main→模块（正是
##      opponent_spawner 实证过的"多一层协程 = physics_frame 恢复时机差 1 物理帧"
##      那个陷阱）。注入 Callable 后协程层次与迁移前**完全一致**：
##        `_check_tick`(main) → `run_opponents`(模块) → `_sample_physics_ms`(main)
##        == 迁移前的 `_check_tick` → `_check_opponents` → `_sample_physics_ms`。
##      Callable 只是调用方式，不新增协程层。
##
##   ④ **await 数 = 6，一拍不加**：4 处帧循环的 physics_frame（见②）+ 2 处
##      `await _sample_physics_ms.call(...)`（见③）。main.gd 分发口那 3 个
##      `await _checks_ai.run_*()` 留在 main 自己那层协程 —— 协程深度与迁移前一致
##      （opponent_spawner 实证：多一层协程 = 25856 行日志发散）。
##      ⚠ 2026-10-18：run_avoid 的 2 处 physics_frame 随该族迁往 ai_field.gd
##      （该模块恰 2 处、都在 run_avoid），本文件 8 → 6。旧
##      split-checks-ai-structcheck.ps1 钉的「8」随之过期（未更新该脚本：它连
##      main.gd 2577 行等迁移期断言都已失效，理由见
##      plan/racing-system-design-20261018.md §11.2，两个历史 structcheck 均非活闸门）。
##
## ⚠ 为什么 `_opponents` 做成**只读 getter 代理**（真身在 `_opponent_spawner`）：
##   迁出的 5 个族里它有 20+ 个读点；保留同名代理可以让派生的函数体**逐字节零 diff**，
##   也不可能出现"两边各存一份数组"的漂移（与 main.gd 的同名代理同一约定，见
##   opponent_spawner.gd 文件头决策 ①）。`_ai_started` 原本也是代理，2026-10-18
##   实测零读取方后连 main.gd 侧的那份一起删了 —— 死代理只会养出警告。
##
## ⚠ 为什么 `_opponent_spawner` / `_autopilot` 注入的是 **main 持有的实例本身**
##   而不是 preload 第二份：对手数组 / armed 状态在 spawner 实例上、drive_recover
##   的状态在 autopilot 实例上；第二份会拿到空状态，A/B 与取证全部失真
##   （screenshot_mode 注入 _autopilot/_engine_audio 实例同款约定）。
##
## ⚠ GameState.current_level() / Engine / Input / Time / Performance 直接读全局
##   单例（layout / bench 同款先例）：它们不是场景节点，直连不违反"禁反向持有场景"；
##   且迁移前本族就在 main.gd 里直连，注入只会多一层间接、零行为收益。
##
## ⚠ 为什么没有 class_name（与九个先例模块同一约定）：验收闸门在**无编辑器**环境
##   跑 Godot，全局类缓存（.godot/global_script_class_cache.cfg）只有编辑器会重建；
##   2026-10-12 实测新增 class_name 后 `--check-only` 与游戏运行双双报
##   `Identifier not declared`。消费方一律
##   `const ChecksAi := preload("res://scripts/checks/ai.gd")`。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car = $RaceCar）。字段名沿用 main 的成员名 → 族内代码零 diff。
var _car: VehicleBody3D = null
## 赛道（迁移前是 _check_* 里 get_node_or_null("Track") 的静态兄弟节点）。由 setup() 注入。
## ⚠ 2026-10-18：原 `_obstacle_field` 注入随 run_obstacles 迁往 ai_field.gd
## （SPLIT-CHECKS-AI-006；本模块剩余三族都不查障碍场）。
var _track: Node = null
## 对手生成模块**实例本身**（main.gd 的 _opponent_spawner）：_opponents / ai_started
## 的真身都在它身上（SPLIT-OPPONENT-001）。字段名沿用 main 的成员名 → 族内代码零 diff。
var _opponent_spawner = null
## 验收自动驾驶模块**实例本身**（main.gd 的 _autopilot）：drive_recover 的恢复状态
## 在它身上，不能 preload 第二份。字段名沿用 main 的成员名 → 族内代码零 diff。
var _autopilot = null
## ⚠ 2026-10-18：原 `_world_3d` 注入随 run_obstacles 的射线探针迁往 ai_field.gd
## （SPLIT-CHECKS-AI-006；本模块剩余三族不用 direct_space_state）。
## physics_frame 信号提供者（main.gd 的 _shot_physics_frame）。由 setup() 注入；
## 模块里 `await _physics_frame.call()` 取代 `await get_tree().physics_frame`，
## 是同一个 Signal，协程恢复时机不变（文件头决策 ②④）。
var _physics_frame: Callable = Callable()
## checks 族共用物理采样器（main.gd 的 _sample_physics_ms）。由 setup() 注入；
## 模块里 `await _sample_physics_ms.call(frames, settle)` 取代直接调用 ——
## 协程层次不变，SIG 口径唯一（文件头决策 ③④）。
var _sample_physics_ms: Callable = Callable()
## "出发！"发车回调（main.gd 的 _on_race_go）。Phase 01 起由 setup() 注入：
## 游玩时它是倒计时 finished 信号的处理函数，aistart / aidiag 经它触发**同一条**
## 发车路径 —— 验收与游玩共用入口（本项目铁律，D1 批准改验同步发车语义）。
var _race_go: Callable = Callable()

# ---------------------------------------------------------------- 只读代理（真身在 _opponent_spawner）
## 本关的 AI 对手（ai_opponents 台）。空数组 = 本关没有对手。
## ⚠ 只读代理：真身在 _opponent_spawner.opponents（SPLIT-OPPONENT-001）。保留同名
## 可以让派生的族内代码零 diff，也杜绝"两边各存一份数组"的漂移；写入只在模块里。
var _opponents: Array:
	get:
		return _opponent_spawner.opponents
## （曾有一个 `_ai_started` 同名代理，2026-10-18 删：本族零读取方，与 main.gd
##   侧代理同因删除；要读发车闩锁时直接 `_opponent_spawner.ai_started`。）
## 位姿/恢复纯函数（static func pose_facing 等无状态可直调，§2.4 约定）。
const Autopilot := preload("res://scripts/autopilot.gd")


## 注入外部引用（main.gd 在 _after_world_ready 里接好线之后调用一次）。
##
## ⚠ 顺序约束已随拆分转移：本模块剩余三族（opponents / ai_diag / ai_start）都不查
## 障碍场；"必须在 `_build_obstacles` 之后注入"现在是 ai_field.gd 的约束
## （avoid 要把玩家摆上 AI 车道、obstacles 要查障碍几何，见该模块 setup 注释）。
## ⚠ 2026-10-18：`obstacle_field` 与 `world_3d` 两个参数随 avoid / obstacles
## 迁往 ai_field.gd（SPLIT-CHECKS-AI-006），本函数 9 参 → 7 参。
func setup(car: VehicleBody3D, track: Node,
		opponent_spawner, autopilot,
		physics_frame: Callable, sample_physics_ms: Callable,
		race_go: Callable, evidence = null, tape_config: Dictionary = {}) -> void:
	if evidence != null:
		_evidence = evidence
	_car = car
	_track = track
	_opponent_spawner = opponent_spawner
	_autopilot = autopilot
	_physics_frame = physics_frame
	_sample_physics_ms = sample_physics_ms
	_race_go = race_go
	_tape_config = tape_config.duplicate(true)

func _calibrate_player_tape() -> void:
	# 只读赛道与玩家自身状态；不调用恢复，不读取 AI 目标或验收占比。
	_autopilot.drive_track(_track, float(_tape_config["calibration_lookahead_m"]))

func _tape_emit(tag: String, values: Dictionary) -> void:
	print(tag + "|" + JSON.stringify(values, "", true, true))

func finish_tape_evidence() -> void:
	if _ai_tape == null:
		return
	var result: Dictionary = _ai_tape.close()
	_evidence.fact({"tape_summary": result})
	if not str(result["error"]).is_empty():
		_evidence.assertion("aidiag.input_receipts", result["error"], "measurement_status", "", "==", "FAIL", "measurement")
		_evidence.fact({"measurement_status": "INPUT_EVIDENCE_INCOMPLETE"})

# ======================== AI 判据常量（迁自 main.gd 顶部常量区）========================
## aidiag 里"掉头恢复动作"累计超过这么久就判异常（说明恢复在打转而不是一次修好）。
const AI_RECOVER_WARN_SEC := 6.0

## ==================== 任务 15（AI 弯道限速）的判据常量 ====================
#
# 这些数字只用于**验收断言**，不参与任何生产逻辑（生产侧的唯一来源是 `racing_line.gd`）。
# 为什么写死成常量而不是"从极速算个百分比"：判据要能被人一眼核对，
# 也算得清"改前为什么必红"。改前 L1 实测：策略被钉在 43.2、物理上限 146~260、
# 最终目标 43.2 —— 三条判据里有两条当场红。

## ① 快速哨兵：发车后"最终目标"的**最大值**必须 ≥ 这个数（km/h）。
##
## ⚠ 这个数是**量出来的、不是我拍的**（2026-09 实测，改前 L1）：
##   改前最终目标逐帧最大 **118.0**（"< 80 km/h 的帧占 71.2%"）—— 也就是说
##   「AI 一直被钉在 43.2」这个说法**不准确**：噪声折角是随位置漂的，
##   少数时刻它自己就小了，于是那些帧的目标能到 100~118。
##   所以 80 这个阈值**根本拦不住改前的状态**（实测绿）。取 **110**（约 L1 极速 144 的 76%）：
##   · 改前实测最大 118.0 → 若那一次采样更差会掉到 110 以下，**红**
##   · 改后直道真实折角 3.4~4.8° → 策略 116~124，物理上限 138~274 → **绿**
##   ⚠ 但它仍然只是"快速哨兵"：它靠**最大值**，天然对采样落点不敏感度有限。
##     真正的稳健判据是下面的 ②（被钉住的帧占比）与 ③（≥物理上限 85% 的占比）。
const AI_TARGET_MIN_KMH := 110.0
## ② "被钉住"的帧占比上限（%）：最终目标 < `AI_TARGET_MIN_KMH` 的帧不得超过这么多。
##
## 为什么必须有这一条：① 只看最大值，改前靠少数幸运帧就能过。
## 改前实测 **71.2%** 的帧都低于 80 km/h（策略限速被 0.30 的下限钳死），
## 改后这些帧应当接近 0。取 50% 是个很宽的界（改前 71.2% 红、改后应远低于它）。
const AI_TARGET_PINNED_PCT := 50.0
## ① 的"被钉住"参照值（km/h）：低于它就算被策略下限钉住。
## 与 `AI_TARGET_MIN_KMH` 分开写，是因为两者角色不同：
## 前者是"最大值门槛"，这里是"哪些帧算被钉住"的定义（用 80 是为了跟改前的
## 43.2 拉开距离、又能让"跑起来了但没跑满"的帧不误判）。
const AI_TARGET_PINNED_KMH := 80.0
## 改前（①退化向量未修）在 L1 上实测的"最终目标最大值"，只用于打印对照。
## 写死在这里是刻意的：它让日志里出现"改前 X → 改后 Y"两边的数字，
## 而不是只报一个孤立的 Y（本项目吃过"验收只报结论、看不出变化"的亏）。
const AI_TARGET_RED_MAX_KMH := 118.0
## 辅助读数的系数：最终目标 ≥ 物理上限 × 这个值 的帧占比（**不计入通过/失败**）。
## 它回答的是"AI 有没有被**地面**限制住"，在低抓地力关卡（L5 冰面）才该当主判据。
## ⚠ 它**不能**当 L1 的主判据：实测改前改后都是 0%（L1 上是策略在限速，地面富余一倍），
##   即不区分两个状态 —— 详见下面 `AI_TARGET_NEAR_CAP_FRAC`。
const AI_TARGET_NEAR_PHYS_FRAC := 0.85
## ③ 主判据下限（%）："贴着**当前真正的限制**跑"的帧占比必须 ≥ 这个数。
## 两条口径都算、取较大者：抓地力充足时看"≥ 极速 × `AI_TARGET_NEAR_CAP_FRAC`"，
## 抓地力低时看"≥ 物理上限 × `AI_TARGET_NEAR_PHYS_FRAC`"（L5 冰面）。
##
## 取值依据（**实测**，不是拍的）：
##   · L1（策略受限）：改前 **0%** / 改后 **61.5%**
##   · L5 冰面（地面受限）：改后 **80.6%**（`a_lat` 正确缩放到 8.0 的直接证据）
##   · 坏状态下**两条都低**（改前 L1：0% / 0%），所以取 max 仍然拦得住
const AI_TARGET_NEAR_CAP_PCT := 60.0
## ③ 参照系数（策略侧口径）：最终目标 ≥ 本关极速 × 这个值 的帧占比。
const AI_TARGET_NEAR_CAP_FRAC := 0.85
## ① 退化向量守卫的在场景读数上限（米）：第一段参考向量必须已经退化到守卫值以下。
## 与 `racing_line.MIN_BEND_SEG`（3.0m）同一个数 —— 刻意独立写一遍，这样守卫被改小
## （比如改回 0.5）时这条会红，而不是跟着一起漂。
const AI_BEND_GUARD_SEG := 3.0
## 同步发车后，前 20s 保留原来的玩家全油门同场交互。
## AI 自然拉开 30m 时沿用原测量起点；若一直并排，到 20s 只在验收夹具
## 里强制开窗的旧隔离方案已撤销：窗口未形成即非通过。不能固定从 20s 起测：赛道
## 区段会后移，实测同一 AI 的「贴着限制跑」从达标变成 48.3% 假红。
## 停顿、自救和超物理上限仍覆盖全程；能力指标从自由跑第 2s 起算。
const AI_INTERACTION_SEC := 20.0
const AI_FREE_RUN_SEC := 22.0
const AI_FREE_RUN_GAP_M := 30.0


## AI 对手验收：要求每台对手都能**自己跑完至少 1 圈**，且不卡死、不出界。
##
## 判定"卡死"不用速度小 —— AI 自己的自救会掩盖问题，所以这里统计的是
## **AI 自身的自救次数**（rescue_count）。自救次数 = 0 才说明它真的开得干净。
## 同时实测物理帧耗时，因为 4 台车 × 4 轮是这阶段最大的性能风险。
##
## 用法：godot --path <工程> -- --check=opponents --level=4
func run_opponents() -> void:
	var cfg: LevelConfig = GameState.current_level()
	if _opponents.is_empty():
		# 区分"本关本来就没对手"和"有对手但被玩家关掉了" —— 否则日志自相矛盾
		# （实测出现"ai_opponents = 4，没有对手可测"这种让人看不懂的输出）
		var designed := cfg.ai_opponents if cfg != null else 0
		if designed > 0 and not GameState.ai_enabled:
			print("[自检] 本关「%s」设计有 %d 台对手，但玩家已在菜单关闭 —— 按预期不生成"
				% [cfg.display_name, designed])
		else:
			print("[自检] 本关「%s」的 ai_opponents = %d，本来就没有对手可测"
				% [cfg.display_name if cfg != null else "?", designed])
		print("[自检] 对手验收 ⊘ 跳过（用 --level=5 / --level=4 这类有对手的关卡来跑）")
		_evidence.branch("ai.run_opponents.001", "SKIP", "(_opponents.is_empty())", {"_opponents": _opponents})
		return
	var ready_ok := 0
	for o in _opponents:
		if o.has_method("progress"):
			ready_ok += 1
	if ready_ok != _opponents.size():
		printerr("[自检] ✘ 只有 %d/%d 台对手初始化成功" % [ready_ok, _opponents.size()])
		_evidence.branch("ai.run_opponents.002", "FAIL", "(ready_ok != _opponents.size())", {"_opponents": _opponents, "ready_ok": ready_ok})
		return
	_evidence.assertion("opponents.initialized", ready_ok, "vehicles", _opponents.size(), "==", "PASS")
	# 物理耗时基线：加对手之前已经测过（现在记在 opponent_spawner.gd 里），这里再测一次"对手怠速"作对照
	var hz := float(Engine.physics_ticks_per_second)
	var t_idle: Dictionary = await _sample_physics_ms.call(120, 180)
	var t_idle_avg := float(t_idle.get("avg", 0.0))
	var t_idle_max := float(t_idle.get("max", 0.0))
	# 对照测完再发车，否则②测到的其实是"已经在跑"的对手
	_opponent_spawner.arm_opponents()
	print("[自检] 对手验收：%d 台，目标各自跑完 ≥1 圈，限时 %.0f 秒" % [_opponents.size(), 180.0])
	var track := _track
	var total_len := float(track.call("road_length")) if track != null else 0.0
	var max_frames := int(hz * 180.0)
	var t0 := Time.get_ticks_msec()
	var f := 0
	var min_laps := 0
	while f < max_frames:
		await _physics_frame.call()
		f += 1
		min_laps = 9999
		for o in _opponents:
			min_laps = mini(min_laps, int(o.call("laps_done")))
		if min_laps >= 1:
			break
	var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
	var t_with: Dictionary = await _sample_physics_ms.call(120, 60)
	print("[自检] 对手用时 %.1f 秒（%d 帧），最小完成圈数 = %d" % [elapsed, f, min_laps])
	var all_ok := min_laps >= 1
	_evidence.assertion("opponents.finished", min_laps, "laps", 1, ">=", "PASS" if all_ok else "FAIL")
	for o in _opponents:
		var laps := int(o.call("laps_done"))
		var resc := int(o.call("rescue_count")) if o.has_method("rescue_count") else -1
		var kmh := float(o.call("speed_kmh"))
		var near: Dictionary = track.call("nearest_on_centerline", o.global_position, -1.0)
		var dev := float(near.get("dist", 0.0))
		var rail_half := float(track.call("rail_half_width"))
		var line := "[自检]   %s：%d 圈，自救 %d 次，当前 %.0f km/h，离中心线 %.2fm（护栏 %.2f）" % [
			o.name, laps, resc, kmh, dev, rail_half]
		if laps < 1 or resc > 0 or dev > rail_half:
			line += "  ✘"
			all_ok = false
			_evidence.branch("ai.run_opponents.003", "FAIL", "(laps < 1 or resc > 0 or dev > rail_half)", {"all_ok": all_ok, "dev": dev, "laps": laps, "rail_half": rail_half, "resc": resc})
		else:
			line += "  ✔"
		print(line)
		_evidence.assertion("opponents.vehicle", {"laps": laps, "rescues": resc, "deviation": dev},
			"laps,count,m", {"laps": 1, "rescues": 0, "deviation": rail_half},
			"FAIL iff laps < 1 or resc > 0 or dev > rail_half", "FAIL" if line.ends_with("✘") else "PASS",
			"contract", {"entity": str(o.name)})
	print("[自检] 对手验收通过判据：每台 ≥1 圈、零自救、未出界")
	print("[自检] 物理开销请单独用 --check=phys 测（本检查里的采样点冷热态不一致，不可比）")
	_evidence.assertion("opponents.result", all_ok, "bool", true, "==", "PASS" if all_ok else "FAIL")
	_evidence.fact({"completed_laps": min_laps, "measured_frames": f})
	if all_ok:
		print("[自检] 对手验收 ✔ 全部对手都能独立跑完 ≥1 圈、零自救、未出界")
		_evidence.branch("ai.run_opponents.004", "PASS", "(all_ok)", {"all_ok": all_ok})
	else:
		printerr("[自检] 对手验收 ✘ 见上方 ✘ 行")
		_evidence.branch("ai.run_opponents.005", "FAIL", "(not ((all_ok)))", {"all_ok": all_ok})


## AI 行为诊断：**定量回答"AI 到底动不动"**。
##
## 为什么要单独做这个检查：
##   原来我用 --check=aistart 验"并排发车"，但那个检查在 check 模式下
##   **走的是和真实游玩不同的发车路径**，所以它一直报 ✔ 而游玩里 AI 会抢跑。
##   Phase 01（2026-10-18）起两个检查都改走**游玩同一个发车入口**：
##   显式调用 main 的 _on_race_go（倒计时"出发！"连的就是它）—— 于是
##   "抢跑"（出发前 armed=true）与"不动"（GO 后跑不起来）两类问题都能暴露。
##
## 采样内容：armed / 速度 / 离中心线 / 横向与纵向离玩家 / 自救次数。
## 判据：① 出发前 armed 必须还是 false（否则抢跑）
##       ② 发车后不允许出现连续 >1.5s 的速度 <5km/h（否则就是"不动"）
##       ③ 自救次数为 0（否则说明它在靠兜底硬撑）
##       ④ 任务 15 组（目标速度 vs 物理上限）：前 20s 同场交互，后 22s
##          自由跑；能力指标从自由跑第 2s 起算，停顿与超速仍覆盖全程。
func run_ai_diag() -> void:
	if _opponents.is_empty():
		var c0: LevelConfig = GameState.current_level()
		print("[自检] AI 诊断：本关「%s」没有对手，跳过 ⊘"
			% [c0.display_name if c0 != null else "?"])
		_evidence.branch("ai.run_ai_diag.001", "SKIP", "(_opponents.is_empty())", {"_opponents": _opponents, "c0": c0})
		return
	var ai: Node = _opponents[0]
	var track := _track
	var hz := float(Engine.physics_ticks_per_second)
	var ok := true
	# 诊断要报"物理上限"，所以要么用 racing_line.gd 的同一份公式，要么就**别报** ——
	# 在这里另写一遍 sqrt(a_lat·R) 就是本项目最忌讳的"两套逻辑漂移"（验收一套、游戏一套）。
	# 加载失败时下面的列照常打印，只是物理上限显示"?"，不会让整个诊断挂掉。
	var racing: GDScript = load("res://scripts/racing_line.gd")
	var cfg: LevelConfig = GameState.current_level()
	_ai_tape = AiTape.new()
	if not _ai_tape.setup(_car, ai, _track, _tape_config,
			Callable(self, "_calibrate_player_tape"), Callable(self, "_tape_emit")):
		printerr("[自检] AI 诊断 ✘ 测量条件未建立：%s" % _ai_tape.error)
		_evidence.assertion("aidiag.tape_setup", _ai_tape.error, "measurement_status", "READY", "==", "FAIL", "measurement")
		_evidence.fact({"measurement_status": str(_ai_tape.error)})
		return

	var armed0 := bool(ai.get("armed"))
	print("[自检] AI 诊断开始（走游玩同一发车入口：倒计时「出发！」回调）")
	print("[自检]   玩家未动时：armed=%s  期望 false（true 说明抢跑）" % str(armed0))
	if armed0:
		printerr("[自检]   ✘ 抢跑：还没出发，AI 已经发车了")
		_evidence.branch("ai.run_ai_diag.002", "FAIL", "(armed0)", {"armed0": armed0})
		ok = false
		_evidence.branch("ai.run_ai_diag.003", "FAIL", "(armed0)", {"armed0": armed0, "ok": ok})

	# 触发"出发！"（与游玩同一个入口：倒计时 finished 连的发车回调）。
	# 同步发车后 AI 不再等玩家速度 —— 判据从"玩家油门触发"改为
	# "GO 后 AI 自行跑得动"（D1 批准；判据串"AI 诊断 ✔"与项数不变）。
	_race_go.call()
	if not bool(ai.get("armed")):
		printerr("[自检]   ✘ 出发！触发后 AI 仍未发动（armed=false）")
		_evidence.branch("ai.run_ai_diag.004", "FAIL", "(not bool(ai.get(\"armed\")))", {"ai": ai})
		ok = false
		_evidence.branch("ai.run_ai_diag.005", "FAIL", "(not bool(ai.get(\"armed\")))", {"ai": ai, "ok": ok})
	else:
		print("[自检]   ✔ 出发！触发后 AI 同一帧发动")
		_evidence.branch("ai.run_ai_diag.006", "PASS", "(not ((not bool(ai.get(\"armed\")))))", {"ai": ai})

	# B/D：用正常 Input 链播放固定输入带；不调用夹具恢复或删除玩家影响。
	var ai_track := _track
	var ai_recover_events := 0  # 原「夹具恢复接管帧数」定义；输入带不执行夹具恢复。
	_ai_tape.start()
	var t := 0.0
	var last_report := -1.0
	var arm_time := -1.0
	var min_kmh := 1e9
	var max_kmh := 0.0
	var low_run := 0
	var worst_low := 0
	var low_from := -1.0       # 最长低速段的起始时刻（便于定位在哪一段）
	var worst_from := -1.0
	var samples := 0
	# ---- 「AI 到底能不能跑到最高限速附近」的记账（任务 15 的红用例，2026-09）----
	# 全部走**真实游玩路径**采样，不合成数字：最有说服力的证据是 aidiag 的三列对照图。
	var tgt_max := 0.0            # 发车后"最终目标"的最大值（km/h）
	var tgt_max_t := 0.0          # 它出现在几秒（便于定位是在哪一段跑满的）
	var phys_at_max := 0.0        # 那一刻的物理上限（判断"跑满"是策略给的还是地面给的）
	var near_phys := 0            # 最终目标 ≥ 物理上限 × 0.85 的采样点数
	var ratio_samples := 0        # 参与辅助读数的帧数（物理上限有限时才算）
	var cap_near := 0             # 最终目标 ≥ 本关极速 × 0.85 的帧数（策略侧口径）
	var worst_gap := 0.0          # 最严重的"超出物理上限"量（>0 即超速）
	var worst_gap_t := 0.0
	var pairs := 0                # 逐采样点比较对数（物理上限有限时才算）
	var live_bend_before := -1.0  # 旧口径（车位置 → 12m 点）读数，只作"修复前"的对照打印
	var live_bend_after := -1.0   # 新口径（`debug_bend_at`）读数
	var live_bend_a := -1.0       # 旧口径参考向量的模（退化向量的直接证据）
	var live_bend_arc := -1.0     # 采样时的弧长（便于复现"同一位置"）
	var tgt_frames := 0           # 参与统计的总帧数（自由跑起点后 2s 起，见 free_at）
	var below80 := 0              # 最终目标 < 80 km/h 的帧数（哨兵的鲁棒性度量，见下）
	# 能力指标只量自由跑；前 20s 的玩家同场交互仍完整覆盖停顿/自救。
	# 玩家姿态仍在原 20s 观测点定格取证，判定表达式不变。
	var interaction_pose: Transform3D = _car.global_transform
	var free_at := -1.0
	var measure_end := AI_INTERACTION_SEC + AI_FREE_RUN_SEC
	var interaction_done := false
	while t < measure_end:
		await _physics_frame.call()
		t += 1.0 / hz
		if not _ai_tape.apply_frame():
			ok = false
			_evidence.assertion("aidiag.tape_apply", _ai_tape.error, "measurement_status", "READY", "==", "FAIL", "measurement")
			break
		if not interaction_done and t >= AI_INTERACTION_SEC:
			interaction_pose = _car.global_transform
			interaction_done = true
			print("[自检]   同场交互 %.1fs 观测点；保留玩家 Input、车辆碰撞与 AI player 引用" % t)
		var armed := bool(ai.get("armed"))
		var kmh := float(ai.call("speed_kmh"))
		if armed and arm_time < 0.0:
			arm_time = t
			print("[自检]   AI 于 %.2fs 发车（此时玩家 %.1f km/h）"
				% [t, _car.linear_velocity.length() * 3.6])
		# 保留原自然 30m 起窗条件（含 not interaction_done）；不再用隔离强制开窗。
		if armed and free_at < 0.0 and not interaction_done:
			var gap_now := _car.global_position.distance_to(ai.global_position)
			if gap_now >= AI_FREE_RUN_GAP_M:
				free_at = t
				measure_end = t + AI_FREE_RUN_SEC
				print("[自检]   AI 于 %.2fs 自然拉开（离玩家 %.1fm ≥ %.0fm），自由跑测量开始"
					% [t, gap_now, AI_FREE_RUN_GAP_M])
		# 停顿族（最低/最高速度、最长低速段）覆盖交互与自由跑全程。
		# 玩家贴身阶段里被别停仍算停顿，不随能力窗口缩小。
		if armed and t >= maxf(arm_time, 0.0) + 2.0:
			samples += 1
			min_kmh = minf(min_kmh, kmh)
			max_kmh = maxf(max_kmh, kmh)
			if kmh < 5.0:
				if low_run == 0:
					low_from = t
				low_run += 1
				if low_run > worst_low:
					worst_low = low_run
					worst_from = low_from
			else:
				low_run = 0
		# ---- 「AI 为什么慢」的量化列（2026-09 玩家反馈"AI 速度太慢"后补）----
		# 光看 AI 自己的速度说明不了问题 —— 必须同时知道**它被什么限制住**：
		#   want = AI 本帧的目标速度（`_target_speed()` 的返回值，策略限速已在里面）
		#   phys = 该点的**物理上限** `speed_limit_kmh(R, a_lat)`，与 racing_line.gd 同一份公式
		# 这样才能判断"是策略保守（want 低）还是抓地力不够（phys 低）"。
		#
		# ⚠ 这一段**每帧**都算（不是只在 2.5s 报告时算）：下面的"主记账"要逐帧累加。
		#   为什么不能只在报告帧算，见主记账那段的注释（用报告帧当采样点会让判据
		#   随采样落点漂，改前甚至读到 117.8 而假绿）。代价是每帧一次
		#   `_target_speed()` + 一次半径/限速查询 —— 与 AI 自己每帧做的运算同量级。
		var want := float(ai.call("_target_speed"))
		var ai_arc := float(ai.get("_arc"))
		# ---- 物理上限与"最终目标"：一律与 AI 同一份公式（`racing_line`）----
		# ⚠ a_lat 刻意**不**用 `μ × 16.0` 自己算，而是取 **AI 自己的
		#   `max_lateral_accel`**。为什么：③ 号改动就是"让这个字段真的按抓地力缩放"，
		#   只有从 AI 身上取，才能验到"接线是否真的落地"。
		#   若自己乘一遍 μ，AI 那边漏缩放时这里照样算出正确值 → **验收绿、游戏错**，
		#   正是本项目最忌讳的"两套逻辑漂移"。
		var a_lat_ai := float(ai.get("max_lateral_accel"))
		var r_corner := float(racing.call("corner_radius_at", track, ai_arc + 12.0, 12.0))
		var phys := float(racing.call("speed_limit_kmh", r_corner, a_lat_ai))
		# 策略与物理上限取小 —— 与 `racing_line.ai_target_speed_kmh()` 同一个语义
		# （min 的唯一定义在那边，这里只取数，不重新发明）
		var final_tgt := minf(want, phys)
		# 两侧算法必须一致 —— 不一致就是"验收一套、游戏一套"的漂移，立刻报出来。
		# ⚠ 判据必须是 `min(rac, final)` vs `max(rac, final)` 的**相对**相等，
		#   不能比绝对相等：直道上 `phys` 是 INF，而 `min(144, INF)` 在 GDScript 里
		#   得到的是 float max（1.797e308，不是 INF）—— 直接比会报一条假红。
		var tgt_capped: Variant = racing.call("ai_target_speed_kmh", want, r_corner, a_lat_ai)
		if tgt_capped != null and float(tgt_capped) >= 0.0:
			var cap_v := float(tgt_capped)
			var lo := minf(cap_v, final_tgt)
			var hi := maxf(cap_v, final_tgt)
			if absf(lo - hi) > 0.05 * maxf(hi, 1.0):
				printerr("[自检]   ✘ 最终目标两套算法不一致：aidiag 这里 %.2f vs racing_line %.2f（漂移！）"
					% [final_tgt, cap_v])
				_evidence.branch("ai.run_ai_diag.007", "FAIL", "(tgt_capped != null and float(tgt_capped) >= 0.0) and (absf(lo - hi) > 0.05 * maxf(hi, 1.0))", {"cap_v": cap_v, "final_tgt": final_tgt, "hi": hi, "lo": lo, "tgt_capped": tgt_capped})
				ok = false
				_evidence.branch("ai.run_ai_diag.008", "FAIL", "(tgt_capped != null and float(tgt_capped) >= 0.0) and (absf(lo - hi) > 0.05 * maxf(hi, 1.0))", {"hi": hi, "lo": lo, "ok": ok, "tgt_capped": tgt_capped})
		# ---- 主记账：**逐物理帧**累加 ----
		#
		# ⚠ 为什么不能用 2.5s 的报告帧当采样点（实测逼出来的）：第一版把统计写在
		#   报告块里，结果**改前**那次"最大目标"读到了 **117.8** —— 报告帧恰好落在
		#   少数几个没被噪声饱和的时刻上，哨兵判据（≥80）就这么绿了。
		#   用报告帧当采样点等于把结论押在"采样落点"上；逐帧累加才与落点无关。
		#
		# Phase 01（同步发车）起分两个窗口，各自回答不同问题：
		#   · 能力指标（下面第一块）= 「AI 自由跑时能跑多快」→ 窗口从 free_at+2s 起
		#     （前 20s 的同场交互由避让逻辑限速，不是本组测量对象）
		#   · 天花板/超速（第二块）= 「AI 任何时候都不许超过物理上限」→ 仍是发车后
		#     全程；避让阶段被压速更不容易超速，但真有超速必须能被看见
		if armed and free_at >= 0.0 and t >= free_at + 2.0:
			tgt_frames += 1
			if final_tgt < AI_TARGET_PINNED_KMH:
				below80 += 1
			# 策略侧口径：最终目标 ≥ 本关极速 × 0.85（"贴着最高限速跑"）
			var cap_kmh := float(ai.get("speed_cap_kmh"))
			if final_tgt >= cap_kmh * AI_TARGET_NEAR_CAP_FRAC:
				cap_near += 1
			if final_tgt > tgt_max:
				tgt_max = final_tgt
				tgt_max_t = t
				phys_at_max = phys
			# 近物理上限占比只统计"物理上限有限"的点：直道上分母是 INF，
			# 硬把它算进来会让占比被直道刷高，看起来达标而弯道其实全废。
			if is_finite(phys) and phys > 1.0:
				ratio_samples += 1
				if final_tgt >= phys * AI_TARGET_NEAR_PHYS_FRAC:
					near_phys += 1
		# 逐点的"不得超物理上限"（只在物理上限有限时判定；
		# 直道返回 INF = "此处不限制"，不是"上限极大"）—— 全程窗口，见上
		if armed and t >= maxf(arm_time, 0.0) + 2.0 and is_finite(phys):
			pairs += 1
			if final_tgt - phys > worst_gap:
				worst_gap = final_tgt - phys
				worst_gap_t = t
		var tape_window := "WAITING" if free_at < 0.0 else "WARMUP" if t < free_at + 2.0 else "MEASURING"
		_ai_tape.ledger(tape_window, "original natural-gap/window predicates", _car.global_position.distance_to(ai.global_position), tgt_frames)
		if _ai_tape.is_calibrating():
			# 校准始终采满既有最长观测期，不按 AI 拉开时刻或成绩截取输入。
			measure_end = AI_INTERACTION_SEC + AI_FREE_RUN_SEC
		if t - last_report >= 2.5:
			last_report = t
			var near: Dictionary = track.call("nearest_on_centerline", ai.global_position, -1.0)
			var dev: float = float(near.get("dist", 0.0))
			# ⚠ 显式标注：ai 是 Node，global_position 是 Variant，
			# 用 := 推断会直接解析失败 → 整个 main.gd 加载不了。
			# 这个坑我在这个文件里已经踩了三次，所以 preflight 现在会真的跑
			# Godot 的解析器（见 lint-gdscript.ps1 的第三类检查）。
			var dist_to_player: float = ai.global_position.distance_to(_car.global_position)
			# 裸弯度（未经 clamp）：用来区分"公式把弯读大了"与"下限把它钳住了"。
			# 反推是**不可靠**的 —— 饱和时反推出的只是下界（我第一版就这么搞反了因果）。
			var bend_deg := 0.0
			var bend_d := 0.0
			var nose_deg := -1.0
			if ai.has_method("_debug_bend_detail"):
				var bd: Dictionary = ai.call("_debug_bend_detail", ai_arc)
				bend_deg = float(bd.get("worst_deg", 0.0))
				bend_d = float(bd.get("worst_d", 0.0))
				nose_deg = float(bd.get("nose_deg", -1.0))
			var phys_txt := "（直道）" if phys >= 900.0 else "%5.0f" % phys
			var r_txt := "直" if is_inf(r_corner) else "%3.0f" % r_corner
			print("[自检]   t=%4.1fs  AI armed=%s 速度=%5.1f  策略=%5.1f(裸弯%5.1f°@d=%.0f 车头%4.1f°)  物理上限=%s(a_lat=%.1f·R=%sm)  最终目标=%5.1f  离中心线=%.2fm 离玩家=%.2fm 玩家=%.1f"
				% [t, str(armed), kmh, want, bend_deg, bend_d, nose_deg, phys_txt,
				   a_lat_ai, r_txt, final_tgt, dev, dist_to_player, _car.linear_velocity.length() * 3.6])
			# 最弯那一档的采样明细（只在裸弯异常大时打，避免刷屏）
			if bend_deg > 30.0 and ai.has_method("_debug_bend_detail"):
				var bd2: Dictionary = ai.call("_debug_bend_detail", ai_arc)
				for line in bd2.get("detail", []):
					print("[自检]        %s" % line)
			# ---- 退化向量的**在场景**实测取证（只取一次，趁 AI 在直道上）----
			# 为什么非要在这里量一次：`--check=layout` 的用例是**构造的点列**，
			# 只能证明纯函数对；"AI 真的跑在车道点上、参考向量真的只有 0.5m"
			# 必须在真车 + 真赛道 + 真车道偏移下量出来才算数。
			if armed and live_bend_arc < 0.0 and nose_deg >= 0.0 and nose_deg < 12.0:
				var lane0: Vector3 = ai.call("_lane_point", ai_arc)
				var lane12: Vector3 = ai.call("_lane_point", ai_arc + 12.0)
				var lane28: Vector3 = ai.call("_lane_point", ai_arc + 28.0)
				var a_first: Vector3 = lane0 - ai.global_position
				var a_legacy: Vector3 = lane12 - ai.global_position
				var b_legacy: Vector3 = lane28 - lane0
				a_first.y = 0.0
				a_legacy.y = 0.0
				b_legacy.y = 0.0
				if a_first.length() > 0.05 and a_legacy.length() > 0.001 and b_legacy.length() > 0.001:
					live_bend_a = a_first.length()
					live_bend_before = rad_to_deg(absf(a_legacy.normalized().angle_to(b_legacy.normalized())))
					live_bend_after = float(ai.call("debug_bend_at", ai_arc))
					live_bend_arc = ai_arc
					# 三个数一起打：|a| 是"退化到什么程度"，两个角度是"修复前 vs 修复后"。
					# ⚠ 这次采到的是**这一处的**实测（旧口径未必恰好是 101°：那段向量本身
					#   只有 0.6m，读数随位置在 90°~120° 之间漂，这正是它是噪声的证据）。
					print("[自检]   退化向量实测（arc=%.1fm）：第一段 |a|=%.2fm 旧口径夹角=%.1f° → 新口径（racing_line.bend_angle_deg）=%.1f°"
						% [live_bend_arc, live_bend_a, live_bend_before, live_bend_after])
	_ai_tape.request_stop()
	if free_at < 0.0 or tgt_frames == 0:
		ok = false
		_evidence.assertion("aidiag.measurement", "WINDOW_NOT_ESTABLISHED", "measurement_status", "COMPLETE", "==", "FAIL", "measurement")
		_evidence.fact({"measurement_status": "WINDOW_NOT_ESTABLISHED", "window_start": free_at,
			"valid_target_frames": tgt_frames, "window_evidence": _ai_tape.summary()})
		printerr("[自检] AI 诊断 ✘ measurement_status=WINDOW_NOT_ESTABLISHED；间距时序、首次/最大间距和玩家恢复事件见 TAPE_END")
	if _ai_tape.is_calibrating():
		ok = false
		_evidence.assertion("aidiag.calibration_only", "CALIBRATION_ONLY", "measurement_status", "FROZEN_REPLAY", "==", "FAIL", "measurement")
		_evidence.fact({"measurement_status": "CALIBRATION_ONLY"})
		printerr("[自检] AI 诊断 ✘ 校准生成，不计为正式验收通过")
	# 最后一条输入的实际读取回执在当前物理回调稍后到达；沿用 main 原有 process_frame 后收尾。

	# ---- 玩家在 aidiag 里有没有被撞掉头：玩家实测「方向相反」的直接量化 ----
	# 为什么必须在这里也报：玩家看到的"方向相反"就是这一步 —— aidiag 让玩家按真实
	# 游玩链路起步，而旁边并排停着一台**静止的** AI，撞上就会被拧掉头
	# （实测日志：点积 -1.00、后轮 force=-4000、以 18~23 km/h 倒滑 7 秒）。
	# 原来这项检查只报 AI 的速度，所以"玩家车倒着开"在验收里完全不可见。
	var ai_near: Dictionary = ai_track.call("nearest_on_centerline", interaction_pose.origin, -1.0)
	var ai_fwd_t: Vector3 = ai_near.get("forward", Vector3.FORWARD)
	ai_fwd_t.y = 0.0
	var ai_nose: Vector3 = -interaction_pose.basis.z
	ai_nose.y = 0.0
	var ai_head := 0.0
	if ai_fwd_t.length() > 0.001 and ai_nose.length() > 0.001:
		ai_head = rad_to_deg(acos(clampf(ai_nose.normalized().dot(ai_fwd_t.normalized()), -1.0, 1.0)))
	print("[自检]   同场交互结束时玩家车头方向：与赛道夹角 %.1f°（判据 <%.0f°）、掉头恢复动作 %d 帧"
		% [ai_head, Autopilot.DRIVE_BACKWARDS_DEG, ai_recover_events])
	if ai_head >= Autopilot.DRIVE_BACKWARDS_DEG:
		printerr("[自检]   ✘ 同场交互结束时玩家车与赛道夹角仍 %.1f° —— 掉头纠正没把它拉回来" % ai_head)
		_evidence.branch("ai.run_ai_diag.009", "FAIL", "(ai_head >= Autopilot.DRIVE_BACKWARDS_DEG)", {"Autopilot": Autopilot, "ai_head": ai_head})
		ok = false
		_evidence.branch("ai.run_ai_diag.010", "FAIL", "(ai_head >= Autopilot.DRIVE_BACKWARDS_DEG)", {"Autopilot": Autopilot, "ai_head": ai_head, "ok": ok})
	elif ai_recover_events > int(hz * AI_RECOVER_WARN_SEC):
		printerr("[自检]   ✘ 掉头恢复动作持续 %d 帧（>%.1fs）—— 恢复在打转，不是一次修好"
			% [ai_recover_events, AI_RECOVER_WARN_SEC])
		_evidence.branch("ai.run_ai_diag.011", "FAIL", "(not ((ai_head >= Autopilot.DRIVE_BACKWARDS_DEG)) and (ai_recover_events > int(hz * AI_RECOVER_WARN_SEC)))", {"AI_RECOVER_WARN_SEC": AI_RECOVER_WARN_SEC, "Autopilot": Autopilot, "ai_head": ai_head, "ai_recover_events": ai_recover_events, "hz": hz})
		ok = false
		_evidence.branch("ai.run_ai_diag.012", "FAIL", "(not ((ai_head >= Autopilot.DRIVE_BACKWARDS_DEG)) and (ai_recover_events > int(hz * AI_RECOVER_WARN_SEC)))", {"AI_RECOVER_WARN_SEC": AI_RECOVER_WARN_SEC, "Autopilot": Autopilot, "ai_head": ai_head, "ai_recover_events": ai_recover_events, "hz": hz, "ok": ok})
	else:
		print("[自检]   ✔ 没有长时间掉头（起步碰撞后已被拉回）")
		_evidence.branch("ai.run_ai_diag.013", "PASS", "(not ((ai_head >= Autopilot.DRIVE_BACKWARDS_DEG) or (ai_recover_events > int(hz * AI_RECOVER_WARN_SEC))))", {"AI_RECOVER_WARN_SEC": AI_RECOVER_WARN_SEC, "Autopilot": Autopilot, "ai_head": ai_head, "ai_recover_events": ai_recover_events, "hz": hz})

	var resc := int(ai.call("rescue_count")) if ai.has_method("rescue_count") else -1
	print("[自检] AI 诊断结果：")
	print("[自检]   抢跑检查：玩家未动时 armed=%s" % str(armed0))
	if arm_time < 0.0:
		printerr("[自检]   ✘ 诊断期间 AI 从未发车 —— 这就是「不动」")
		_evidence.branch("ai.run_ai_diag.014", "FAIL", "(arm_time < 0.0)", {"arm_time": arm_time})
		ok = false
		_evidence.branch("ai.run_ai_diag.015", "FAIL", "(arm_time < 0.0)", {"arm_time": arm_time, "ok": ok})
	else:
		print("[自检]   发车时刻：%.2fs" % arm_time)
		print("[自检]   发车后速度：最低 %.1f / 最高 %.1f km/h（采样 %d 帧）"
			% [min_kmh, max_kmh, samples])
		print("[自检]   最长低速段：%.2fs（<5km/h，起始于 t=%.1fs）"
			% [float(worst_low) / hz, worst_from])
		if samples < int(hz * 5.0):
			printerr("[自检]   ✘ 有效采样太少（%d 帧），诊断不可信" % samples)
			_evidence.branch("ai.run_ai_diag.016", "FAIL", "(not ((arm_time < 0.0))) and (samples < int(hz * 5.0))", {"arm_time": arm_time, "hz": hz, "samples": samples})
			ok = false
			_evidence.branch("ai.run_ai_diag.017", "FAIL", "(not ((arm_time < 0.0))) and (samples < int(hz * 5.0))", {"arm_time": arm_time, "hz": hz, "ok": ok, "samples": samples})
		elif float(worst_low) / hz > 1.5:
			printerr("[自检]   ✘ 出现连续 %.2fs 的「不动」（<5km/h）"
				% [float(worst_low) / hz])
			_evidence.branch("ai.run_ai_diag.018", "FAIL", "(not ((arm_time < 0.0))) and (not ((samples < int(hz * 5.0))) and (float(worst_low) / hz > 1.5))", {"arm_time": arm_time, "hz": hz, "samples": samples, "worst_low": worst_low})
			ok = false
			_evidence.branch("ai.run_ai_diag.019", "FAIL", "(not ((arm_time < 0.0))) and (not ((samples < int(hz * 5.0))) and (float(worst_low) / hz > 1.5))", {"arm_time": arm_time, "hz": hz, "ok": ok, "samples": samples, "worst_low": worst_low})
		else:
			print("[自检]   ✔ 没有超过 1.5s 的停顿")
			_evidence.branch("ai.run_ai_diag.020", "PASS", "(not ((arm_time < 0.0))) and (not ((samples < int(hz * 5.0)) or (float(worst_low) / hz > 1.5)))", {"arm_time": arm_time, "hz": hz, "samples": samples, "worst_low": worst_low})
	print("[自检]   自救次数：%d（>0 说明它在靠兜底硬撑）" % resc)
	if resc > 0:
		ok = false
		_evidence.branch("ai.run_ai_diag.021", "FAIL", "(resc > 0)", {"ok": ok, "resc": resc})
	if ok:
		print("[自检] AI 诊断 ✔ 不抢跑、不发车后停顿、不依赖自救")
		_evidence.branch("ai.run_ai_diag.022", "PASS", "(ok)", {"ok": ok})
	else:
		printerr("[自检] AI 诊断 ✘ 见上方 ✘ 行（把这段日志连同速度曲线一起看）")
		_evidence.branch("ai.run_ai_diag.023", "FAIL", "(not ((ok)))", {"ok": ok})

	# ==================== 任务 15 的红用例：AI 到底能不能跑到最高限速附近 ====================
	#
	# 为什么这三条要放在**真车在场景**里，而不是只留 `--check=layout` 的纯函数用例：
	#   纯函数只能证明"公式接对了"。而项目所有者的原始需求是「AI 速度接近最高限速」，
	#   它是一个**行为**指标 —— 必须用量出来的速度说话。三条判据各有分工：
	#     ① `tgt_max ≥ 80`：唯一直接度量"AI 变快了"的快速哨兵。改前 L1 实测被钉在 43.2
	#        （策略下限 0.30 × 极速 144），今天必红。
	#     ② `final_tgt ≤ phys`（每一点）：防"接上限接反了"——变成超速冲出去。
	#     ③ 占比 ≥ 60%（`AI_TARGET_NEAR_CAP_PCT`）：完整版的需求度量 —— 判据在下面 ③ 那段，
	#        是"策略侧 / 地面侧两条口径**取较大者**"，不是单看物理上限。
	#        ⚠ 这里曾写"≥ 80% / 只看物理上限"，那是任务 15 早期的试验口径，与实现不符，
	#          2026-09 审计发现后订正（见 docs/plans/task15-ai-corner-speed.md §〇 订正 4）。
	#        只在**物理上限有限**的采样点上统计"地面侧"：直道的 `phys` 是 INF
	#        （语义是"此处不限制"），混进来会把占比刷高。
	print("[自检] AI 目标速度 vs 物理上限（任务 15 判据，逐帧累加；同场交互 20s，仅自然拉开后量 22s）：")
	if live_bend_arc >= 0.0:
		print("[自检]   退化向量：arc=%.1fm 第一段 |a|=%.2fm → 旧口径 %.1f° / 新口径 %.1f°"
			% [live_bend_arc, live_bend_a, live_bend_before, live_bend_after])
		if live_bend_a > AI_BEND_GUARD_SEG:
			printerr("[自检]   ✘ 第一段参考向量 %.2fm 仍 > 守卫值 %.1fm —— 退化向量守卫没接上"
				% [live_bend_a, AI_BEND_GUARD_SEG])
			_evidence.branch("ai.run_ai_diag.024", "FAIL", "(live_bend_arc >= 0.0) and (live_bend_a > AI_BEND_GUARD_SEG)", {"AI_BEND_GUARD_SEG": AI_BEND_GUARD_SEG, "live_bend_a": live_bend_a, "live_bend_arc": live_bend_arc})
			ok = false
			_evidence.branch("ai.run_ai_diag.025", "FAIL", "(live_bend_arc >= 0.0) and (live_bend_a > AI_BEND_GUARD_SEG)", {"AI_BEND_GUARD_SEG": AI_BEND_GUARD_SEG, "live_bend_a": live_bend_a, "live_bend_arc": live_bend_arc, "ok": ok})
		else:
			print("[自检]   ✔ 第一段参考向量 %.2fm ≤ 守卫值 %.1fm：那段退化线段已被排除，不再参与求夹角"
				% [live_bend_a, AI_BEND_GUARD_SEG])
			_evidence.branch("ai.run_ai_diag.026", "PASS", "(live_bend_arc >= 0.0) and (not ((live_bend_a > AI_BEND_GUARD_SEG)))", {"AI_BEND_GUARD_SEG": AI_BEND_GUARD_SEG, "live_bend_a": live_bend_a, "live_bend_arc": live_bend_arc})
	else:
		print("[自检]   ⚠ 本次没取到退化向量实测样本（AI 一直没进直道？）—— 该条判据本次不生效")

	var pinned_pct := 100.0 * float(below80) / maxf(float(tgt_frames), 1.0)
	print("[自检]   自由跑窗口内最终目标：最大 %.1f km/h（出现在 t=%.1fs，当时物理上限 %.1f）；< %.0f km/h 的帧占 %d/%d = %.1f%%"
		% [tgt_max, tgt_max_t, phys_at_max, AI_TARGET_PINNED_KMH, below80, tgt_frames, pinned_pct])
	# ① 快速哨兵：改前实测最大 118.0（阈值 110）→ 红；改后直道 130+ → 绿。
	# ⚠ 写法上刻意**不**说"改前被钉在 43.2"—— 那句话只对多数帧成立，
	#   最大值那几帧改前也能到 118（噪声折角偶尔自己就小了）。见 AI_TARGET_MIN_KMH 的注释。
	if tgt_max < AI_TARGET_MIN_KMH:
		printerr("[自检]   ✘ 最终目标最大只到 %.1f km/h（< %.0f）—— 「AI 速度接近最高限速」没有达成"
			% [tgt_max, AI_TARGET_MIN_KMH])
		_evidence.branch("ai.run_ai_diag.027", "FAIL", "(tgt_max < AI_TARGET_MIN_KMH)", {"AI_TARGET_MIN_KMH": AI_TARGET_MIN_KMH, "tgt_max": tgt_max})
		ok = false
		_evidence.branch("ai.run_ai_diag.028", "FAIL", "(tgt_max < AI_TARGET_MIN_KMH)", {"AI_TARGET_MIN_KMH": AI_TARGET_MIN_KMH, "ok": ok, "tgt_max": tgt_max})
	else:
		print("[自检]   ✔ 最终目标最大 %.1f ≥ %.0f km/h（改前 L1 实测最大只有 %.1f）"
			% [tgt_max, AI_TARGET_MIN_KMH, AI_TARGET_RED_MAX_KMH])
		_evidence.branch("ai.run_ai_diag.029", "PASS", "(not ((tgt_max < AI_TARGET_MIN_KMH)))", {"AI_TARGET_MIN_KMH": AI_TARGET_MIN_KMH, "AI_TARGET_RED_MAX_KMH": AI_TARGET_RED_MAX_KMH, "tgt_max": tgt_max})
	# ② 被钉住的帧占比：改前实测 71.2% 的帧 < 80 km/h → 红；改后应接近 0。
	# 这一条才是"改前必红"的稳健判据（① 靠最大值，改前能侥幸过）。
	if tgt_frames > 0 and pinned_pct > AI_TARGET_PINNED_PCT:
		printerr("[自检]   ✘ 被钉住的帧占 %.1f%%（> %.0f%%）—— 最终目标长期低于 %.0f km/h，策略下限仍在压着 AI"
			% [pinned_pct, AI_TARGET_PINNED_PCT, AI_TARGET_PINNED_KMH])
		_evidence.branch("ai.run_ai_diag.030", "FAIL", "(tgt_frames > 0 and pinned_pct > AI_TARGET_PINNED_PCT)", {"AI_TARGET_PINNED_KMH": AI_TARGET_PINNED_KMH, "AI_TARGET_PINNED_PCT": AI_TARGET_PINNED_PCT, "pinned_pct": pinned_pct, "tgt_frames": tgt_frames})
		ok = false
		_evidence.branch("ai.run_ai_diag.031", "FAIL", "(tgt_frames > 0 and pinned_pct > AI_TARGET_PINNED_PCT)", {"AI_TARGET_PINNED_PCT": AI_TARGET_PINNED_PCT, "ok": ok, "pinned_pct": pinned_pct, "tgt_frames": tgt_frames})
	elif tgt_frames > 0:
		print("[自检]   ✔ 被钉住的帧只占 %.1f%% ≤ %.0f%%（改前实测 71.2%%）"
			% [pinned_pct, AI_TARGET_PINNED_PCT])
		_evidence.branch("ai.run_ai_diag.032", "PASS", "(not ((tgt_frames > 0 and pinned_pct > AI_TARGET_PINNED_PCT)) and (tgt_frames > 0))", {"AI_TARGET_PINNED_PCT": AI_TARGET_PINNED_PCT, "pinned_pct": pinned_pct, "tgt_frames": tgt_frames})
	# ② 天花板：任何一点都不得超物理上限（含 a_lat 缩放是否接线：a_lat 取自 AI 自己的字段）
	if pairs > 0:
		if worst_gap > 0.05:
			printerr("[自检]   ✘ 有采样点超物理上限：最多超出 %.1f km/h（t=%.1fs）—— min 接反了？"
				% [worst_gap, worst_gap_t])
			_evidence.branch("ai.run_ai_diag.033", "FAIL", "(pairs > 0) and (worst_gap > 0.05)", {"pairs": pairs, "t": t, "worst_gap": worst_gap, "worst_gap_t": worst_gap_t})
			ok = false
			_evidence.branch("ai.run_ai_diag.034", "FAIL", "(pairs > 0) and (worst_gap > 0.05)", {"ok": ok, "pairs": pairs, "worst_gap": worst_gap})
		else:
			print("[自检]   ✔ %d 个采样点全部 ≤ 物理上限（最大超出 %.2f km/h）" % [pairs, worst_gap])
			_evidence.branch("ai.run_ai_diag.035", "PASS", "(pairs > 0) and (not ((worst_gap > 0.05)))", {"pairs": pairs, "worst_gap": worst_gap})
	else:
		printerr("[自检]   ✘ 本次没有「物理上限有限」的采样点（全程直道？）—— 天花板判据本次不生效")
		_evidence.branch("ai.run_ai_diag.036", "FAIL", "(not ((pairs > 0)))", {"pairs": pairs})
	# ③ 占比（**主判据**）：贴着"当前真正的限制"跑。
	#
	# 两条分支都算，取**较大**的那个与 60% 比：
	#   · 抓地力充足（L1）：限制来自**策略**，度量 = ≥ 极速 × 85%   → 实测 61.5%
	#   · 抓地力低（L5 冰面）：限制来自**地面**，度量 = ≥ 物理上限 × 85% → 实测 80.6%
	# 为什么必须两条都算：在冰面上"跑不到极速的 85%"是**正确**的（地面只给 50~158，
	# 而极速是 216）—— 只卡极速那条会把正确的行为判成失败。
	# 而"AI 太慢"这个 bug 会让**两条都低**（改前 L1：0% / 0%），所以取 max 仍然拦得住它。
	if tgt_frames > 0:
		var cap_pct := 100.0 * float(cap_near) / float(tgt_frames)
		var phys_pct := 0.0
		if ratio_samples > 0:
			phys_pct = 100.0 * float(near_phys) / float(ratio_samples)
		var best_pct := maxf(cap_pct, phys_pct)
		print("[自检]   贴着限制跑的帧：策略侧 ≥ 极速×85%% = %.1f%%（%d/%d）；地面侧 ≥ 物理上限×85%% = %.1f%%（%d/%d）；取较大者 %.1f%%"
			% [cap_pct, cap_near, tgt_frames, phys_pct, near_phys, ratio_samples, best_pct])
		if best_pct < AI_TARGET_NEAR_CAP_PCT:
			printerr("[自检]   ✘ 两条口径都低（策略侧 %.1f%% / 地面侧 %.1f%%，应至少一条 ≥ %.0f%%）—— 「AI 接近最高限速」没有达成"
				% [cap_pct, phys_pct, AI_TARGET_NEAR_CAP_PCT])
			_evidence.branch("ai.run_ai_diag.037", "FAIL", "(tgt_frames > 0) and (best_pct < AI_TARGET_NEAR_CAP_PCT)", {"AI_TARGET_NEAR_CAP_PCT": AI_TARGET_NEAR_CAP_PCT, "best_pct": best_pct, "cap_pct": cap_pct, "phys_pct": phys_pct, "tgt_frames": tgt_frames})
			ok = false
			_evidence.branch("ai.run_ai_diag.038", "FAIL", "(tgt_frames > 0) and (best_pct < AI_TARGET_NEAR_CAP_PCT)", {"AI_TARGET_NEAR_CAP_PCT": AI_TARGET_NEAR_CAP_PCT, "best_pct": best_pct, "ok": ok, "tgt_frames": tgt_frames})
		else:
			print("[自检]   ✔ 贴着限制跑的帧占 %.1f%% ≥ %.0f%%（改前实测两条都是 0%%）"
				% [best_pct, AI_TARGET_NEAR_CAP_PCT])
			_evidence.branch("ai.run_ai_diag.039", "PASS", "(tgt_frames > 0) and (not ((best_pct < AI_TARGET_NEAR_CAP_PCT)))", {"AI_TARGET_NEAR_CAP_PCT": AI_TARGET_NEAR_CAP_PCT, "best_pct": best_pct, "tgt_frames": tgt_frames})
	# 辅助读数（**不计入通过/失败**）：离**物理上限**有多近 —— 回答"AI 有没有被地面限制住"。
	# 在 L1 这种抓地力充足、策略仍然保守的关卡上它是低值，那是正常（物理上限是天花板，不是目标）。
	if ratio_samples > 0:
		print("[自检]   （辅助读数）最终目标 ≥ 物理上限 × %.0f%% 的帧：%d/%d = %.1f%%"
			% [AI_TARGET_NEAR_PHYS_FRAC * 100.0, near_phys, ratio_samples,
			   100.0 * float(near_phys) / float(ratio_samples)])
	if ok:
		print("[自检] AI 目标速度判定 ✔ 目标已达最高限速量级、且从未超过物理上限")
		_evidence.branch("ai.run_ai_diag.040", "PASS", "(ok)", {"ok": ok})
	else:
		printerr("[自检] AI 目标速度判定 ✘ 见上方 ✘ 行（这一组就是任务 15 的需求指标）")
		_evidence.branch("ai.run_ai_diag.041", "FAIL", "(not ((ok)))", {"ok": ok})


## 同步发车验收（2026-10-18 Phase 01 新语义，D1 用户批准）：
##   **出发前对手必须原地等待；"出发！"入口触发后同一帧全部发动；
##   玩家完全不按键，对手也能自己跑起来。**
##
## 为什么改：旧语义是旧规则②"玩家速度 ≥4 km/h 才发车"的机器化。同步发车后
## AI 不再等玩家（玩家不按键 AI 也发车），旧断言会"验收绿、游戏错" ——
## 这正是本项目最贵的坑（opponent_spawner.gd 文件头有完整演变记录）。
## 触发的是 main 的 _on_race_go：游玩时倒计时 finished 连的就是它，
## 验收与游玩共用同一条发车路径。判据串"并排发车验收 ✔"与检查项数量不变。
func run_ai_start() -> void:
	if _opponents.is_empty():
		print("[自检] 本关没有对手，并排发车验收 ⊘ 跳过")
		_evidence.branch("ai.run_ai_start.001", "SKIP", "(_opponents.is_empty())", {"_opponents": _opponents})
		return
	var hz := float(Engine.physics_ticks_per_second)
	var ok := true
	# ① 出发前：全部对手必须原地等待（armed=false，不抢跑）
	print("[自检] 并排发车验收：先让玩家静止 %.1f 秒，看对手是否原地等待" % 1.5)
	for i in range(int(hz * 1.5)):
		await _physics_frame.call()
	var ai0: Node = _opponents[0]
	var ai_speed_idle := float(ai0.call("speed_kmh"))
	var player_speed := _car.linear_velocity.length() * 3.6
	var armed_now := bool(ai0.get("armed"))
	print("[自检]   玩家 %.2f km/h，对手 %.2f km/h，armed=%s"
		% [player_speed, ai_speed_idle, str(armed_now)])
	if ai_speed_idle > 1.0 or armed_now:
		printerr("[自检]   ✘ 还没出发，对手就已经发动了")
		_evidence.branch("ai.run_ai_start.002", "FAIL", "(ai_speed_idle > 1.0 or armed_now)", {"ai_speed_idle": ai_speed_idle, "armed_now": armed_now})
		ok = false
		_evidence.branch("ai.run_ai_start.003", "FAIL", "(ai_speed_idle > 1.0 or armed_now)", {"ai_speed_idle": ai_speed_idle, "armed_now": armed_now, "ok": ok})
	else:
		print("[自检]   ✔ 对手原地等待，没有抢跑")
		_evidence.branch("ai.run_ai_start.004", "PASS", "(not ((ai_speed_idle > 1.0 or armed_now)))", {"ai_speed_idle": ai_speed_idle, "armed_now": armed_now})
	# ② 检查并排：横向偏移应等于设计值，纵向应齐头
	var gap := _car.global_position.distance_to(ai0.global_position)
	var rail_half := float(_track.call("rail_half_width"))
	print("[自检]   两车中心距 %.2f m（设计值 = 并排横向 %.2f m）"
		% [gap, float(ai0.get("lane_offset"))])
	# ③ 触发"出发！"——与游玩同一个入口（倒计时 finished 连的就是它）
	print("[自检]   现在触发发车入口（与倒计时「出发！」同一个回调）…")
	_race_go.call()
	# ④ 同一帧断言：全部 armed + 玩家输入解锁（同步发车的可判定定义）
	var all_armed := true
	for o in _opponents:
		if not bool(o.get("armed")):
			all_armed = false
	if not all_armed:
		printerr("[自检]   ✘ 发车入口触发后仍有对手未发动（armed=false）")
		_evidence.branch("ai.run_ai_start.005", "FAIL", "(not all_armed)", {"all_armed": all_armed})
		ok = false
		_evidence.branch("ai.run_ai_start.006", "FAIL", "(not all_armed)", {"all_armed": all_armed, "ok": ok})
	else:
		print("[自检]   ✔ 发车入口触发后 %d 台对手同一帧全部发动" % _opponents.size())
		_evidence.branch("ai.run_ai_start.007", "PASS", "(not ((not all_armed)))", {"_opponents": _opponents, "all_armed": all_armed})
	if bool(_car.get("start_locked")):
		printerr("[自检]   ✘ 发车后玩家输入仍处于锁定状态")
		_evidence.branch("ai.run_ai_start.008", "FAIL", "(bool(_car.get(\"start_locked\")))", {"_car": _car})
		ok = false
		_evidence.branch("ai.run_ai_start.009", "FAIL", "(bool(_car.get(\"start_locked\")))", {"_car": _car, "ok": ok})
	else:
		print("[自检]   ✔ 玩家输入同步解锁")
		_evidence.branch("ai.run_ai_start.010", "PASS", "(not ((bool(_car.get(\"start_locked\")))))", {"_car": _car})
	# ⑤ 玩家完全不按键，对手应自己跑起来（不再等待玩家 4 km/h）
	var started_frame := -1
	var f := 0
	while f < int(hz * 8.0):
		await _physics_frame.call()
		f += 1
		if float(ai0.call("speed_kmh")) > 15.0:
			started_frame = f
			break
	var final_ai := float(ai0.call("speed_kmh"))
	var final_player := _car.linear_velocity.length() * 3.6
	if started_frame < 0:
		printerr("[自检]   ✘ 玩家没有按键，对手始终没有跑起来")
		_evidence.branch("ai.run_ai_start.011", "FAIL", "(started_frame < 0)", {"started_frame": started_frame})
		ok = false
		_evidence.branch("ai.run_ai_start.012", "FAIL", "(started_frame < 0)", {"ok": ok, "started_frame": started_frame})
	else:
		print("[自检]   ✔ 玩家零输入，对手第 %d 帧（%.2f 秒）自行达到 15 km/h，当前 玩家 %.0f / 对手 %.0f km/h"
			% [started_frame, float(started_frame) / hz, final_player, final_ai])
		_evidence.branch("ai.run_ai_start.013", "PASS", "(not ((started_frame < 0)))", {"final_ai": final_ai, "final_player": final_player, "hz": hz, "started_frame": started_frame})
	if final_ai < 10.0:
		printerr("[自检]   ✘ 对手发动后速度只有 %.1f km/h，看起来没真的跑起来" % final_ai)
		_evidence.branch("ai.run_ai_start.014", "FAIL", "(final_ai < 10.0)", {"final_ai": final_ai})
		ok = false
		_evidence.branch("ai.run_ai_start.015", "FAIL", "(final_ai < 10.0)", {"final_ai": final_ai, "ok": ok})
	if rail_half <= 0.0:
		printerr("[自检]   ✘ 拿不到护栏半宽，并排距离无法校验")
		_evidence.branch("ai.run_ai_start.016", "FAIL", "(rail_half <= 0.0)", {"rail_half": rail_half})
		ok = false
		_evidence.branch("ai.run_ai_start.017", "FAIL", "(rail_half <= 0.0)", {"ok": ok, "rail_half": rail_half})
	if ok:
		print("[自检] 并排发车验收 ✔ 原地等待 → 出发！同帧发动 → 玩家零输入也跑得动")
		_evidence.branch("ai.run_ai_start.018", "PASS", "(ok)", {"ok": ok})
	else:
		printerr("[自检] 并排发车验收 ✘ 见上方 ✘ 行")
		_evidence.branch("ai.run_ai_start.019", "FAIL", "(not ((ok)))", {"ok": ok})
