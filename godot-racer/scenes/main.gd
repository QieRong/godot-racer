extends Node3D
## 主场景装配：把检查点信号接到 HUD，并给引擎声临时合成一个音源
##
## 这样设计是为了让你不用手动连线就能跑起来：
##   - Track 下所有 Area3D（含 StartFinish）的 car_passed 自动连到 HUD
##   - EngineSound 若没挂音频流，就用 AudioStreamGenerator 实时合成引擎声，
##     你把 freesound 下的 engine loop 拖到 EngineSound.stream 后，这段会自动让位

@onready var _car: VehicleBody3D = $RaceCar
@onready var _hud: CanvasLayer = $HUD

## 天气/环境纯函数模块（SPLIT-ENV-001 从本文件拆出）。用 preload 而不是 class_name：
## 无编辑器环境下 class_name 依赖编辑器才重建的 .godot 全局类缓存，新增 class_name
## 会让 parse-check 与游戏运行双双解析失败 —— 原因详见 environment.gd 文件头。
const EnvironmentFX := preload("res://scripts/environment.gd")
const FinishMenu := preload("res://scripts/finish_menu.gd")
const RacePosition := preload("res://scripts/race_position.gd")
var _race_position: CanvasLayer = null
var _player_finish_pending := false

## 占位引擎声模块（SPLIT-ENV-002 从本文件拆出）。同样用 preload 而不是 class_name，
## 原因同 EnvironmentFX：无编辑器环境下 class_name 依赖编辑器才重建的全局类缓存。
const EngineAudio := preload("res://scripts/engine_audio.gd")
var _engine_audio := EngineAudio.new()

## 天气环境音（雨声）模块实例（REL-STEP2C 新增在 environment.gd 的**实例侧**）。
## 与 _engine_audio 同一约定：本文件每场景持一个实例，模块不反向持有场景，
## 车由本文件注入 —— 所以"重复进同一关"拿到的是**新实例 + 新车**，天然不会共用一个
## 播放器；同一棵树里重复 apply 则由模块自己按名字复用（见 environment.gd 的防叠音说明）。
var _weather_audio := EnvironmentFX.new()

## [DEBUG-L4] 变道走廊 / 卡死时间线诊断模块（SPLIT-L4DIAG-001 从本文件拆出）。
## 同样用 preload 而不是 class_name，原因同 EnvironmentFX：无编辑器环境下
## class_name 依赖编辑器才重建的全局类缓存。全部只读，不参与任何判定。
const L4DebugDiag := preload("res://scripts/l4_debug_diag.gd")
var _l4_diag := L4DebugDiag.new()

## 验收自动驾驶模块（SPLIT-AUTOPILOT-002 从本文件拆出）：追线 / 选道避障 /
## 卡住自救 / 掉头纠正 + pose_facing 纯函数。同样用 preload 而不是 class_name，
## 原因同 EnvironmentFX：无编辑器环境下 class_name 依赖编辑器才重建的全局类缓存。
## 注入：_after_world_ready 里 _autopilot.setup(_car, _obstacle_field, _l4_diag)。
const Autopilot := preload("res://scripts/autopilot.gd")
var _autopilot := Autopilot.new()

## 对手生成模块（SPLIT-OPPONENT-001 从本文件拆出）：实例化 race_car.tscn 换控制器脚本、
## 发车时机控制（Phase 01 起：唯一发车入口是本文件的 _on_race_go 回调，策划案 §5.2）
## 与物理基线记账。同样用 preload 而不是 class_name，原因同 EnvironmentFX：无编辑器
## 环境下 class_name 依赖编辑器才重建的全局类缓存。
## 注入：_after_world_ready 里 _opponent_spawner.setup(_car, _obstacle_field,
## _avg_physics_ms 的 Callable, add_child 的 Callable）。
const OpponentSpawner := preload("res://scripts/opponent_spawner.gd")
var _opponent_spawner := OpponentSpawner.new()

## 发车倒计时模块（Phase 01 竞速系统策划案 R2，2026-10-18 新增）：3-2-1 倒计时 UI。
## 装配完成后由 _after_world_ready 挂载（仅互动路径），"出发！"时发 finished 信号，
## 连到本文件的唯一发车回调 _on_race_go。同样 preload 而不是 class_name。
const StartCountdown := preload("res://scripts/start_countdown.gd")
## 倒计时 UI 实例（互动路径才有；自动化路径为 null）
var _countdown: CanvasLayer = null

## 截图模式模块（SPLIT-SCREENSHOT-001 从本文件拆出）：--shot 族的命令行解析、
## 逆方向摆位（wrongway_warp）与 _process 里的截图主体（存 PNG / 诊断打印 / 退出）。
## 同样用 preload 而不是 class_name，原因同 EnvironmentFX：无编辑器环境下
## class_name 依赖编辑器才重建的全局类缓存。
## 注入：_after_world_ready 里 _screenshot_mode.setup(...)（车 / 赛道 / 相机 /
## 自动驾驶 / 引擎声 + 3 个场景能力 Callable）。
const ScreenshotMode := preload("res://scripts/screenshot_mode.gd")
var _screenshot_mode := ScreenshotMode.new()

## 赛道布局验收模块（SPLIT-CHECKS-LAYOUT-001 从本文件拆出）：--check=layout 全族 ——
## 解析器用例组（①路段 DSL / ③高度剖面 / ④限速刹车 / ⑤AI 最终目标速度）、②逐关几何
## 体检与往返唯一性。同样用 preload 而不是 class_name，原因同 EnvironmentFX：
## 无编辑器环境下 class_name 依赖编辑器才重建的 .godot 全局类缓存。
## 注入：_after_world_ready 里 _checks_layout.setup(track, LAYOUT_ELEV_CASES,
## LAYOUT_RACING_CASES) —— 两个条数常量是 ADR-001 永久居民（check-docs.ps1 直接从
## main.gd 原文取值，不随本族外迁），参数注入而非在模块里复制第二份（§5.3 单一来源）。
const ChecksLayout := preload("res://scripts/checks/layout.gd")
var _checks_layout := ChecksLayout.new()

## 台架验收模块（SPLIT-CHECKS-BENCH-002 从本文件拆出）：--check=steerbench 与
## --check=brakebench 两族（逐帧采样台架：舵角×初速度矩阵 / 分档减速度实测）。
## 同样用 preload 而不是 class_name，原因同 EnvironmentFX：无编辑器环境下
## class_name 依赖编辑器才重建的 .godot 全局类缓存。
## 注入：_after_world_ready 里 _checks_bench.setup(_car, track,
## Callable(self, "_shot_physics_frame")) —— 车/赛道注入；physics_frame 信号经
## Callable 递入（模块不持有场景，§2.4；与 screenshot_mode 同款约定）。
const ChecksBench := preload("res://scripts/checks/bench.gd")
var _checks_bench := ChecksBench.new()

## AI 验收模块（SPLIT-CHECKS-AI-003 从本文件拆出）：--check=opponents / aidiag /
## aistart 三族（对手跑圈、AI 行为诊断 + 任务 15 目标速度判据、并排发车）。
## ⚠ 2026-10-18 SPLIT-CHECKS-AI-006：avoid / obstacles 两族已迁往
## scripts/checks/ai_field.gd（Phase 01 后 ai.gd 越过 1000 行契约）。同样用 preload
## 而不是 class_name，原因同 EnvironmentFX：无编辑器环境下 class_name 依赖编辑器
## 才重建的 .godot 全局类缓存。
## 注入：_after_world_ready 里 _checks_ai.setup(...) —— 车/赛道注入（模块不 get_node）；
## 对手生成与自动驾驶注入**本文件持有的实例**（状态在实例上，第二份会拿到空）；
## physics_frame 与 _sample_physics_ms 采样器经 Callable 递入。
const ChecksAi := preload("res://scripts/checks/ai.gd")
var _checks_ai := ChecksAi.new()

## AI×场地交互验收模块（SPLIT-CHECKS-AI-006 从 ai.gd 二次拆出）：--check=avoid /
## obstacles 两族（避让玩家路障、障碍物位置/碰撞/通行缝隙）。同样用 preload 而不是
## class_name，原因同 EnvironmentFX：无编辑器环境下 class_name 依赖编辑器才重建的
## .godot 全局类缓存。
## 注入：_after_world_ready 里 _checks_ai_field.setup(...) —— 车/赛道/障碍场/物理世界
## 注入（模块不 get_node，§2.4）；对手生成注入**本文件持有的实例**（armed 状态在实例上，
## 第二份会拿到空状态）；physics_frame 经 Callable 递入（同 ai.gd 决策②）。
const ChecksAiField := preload("res://scripts/checks/ai_field.gd")
var _checks_ai_field := ChecksAiField.new()

## 环境物理验收模块（SPLIT-CHECKS-ENVPHYS-004 从本文件拆出）：--check=weather / phys /
## friction / wallslide / stuck / flip 六族（天气粒子与环境对比度、物理步频开销测量、
## 抓地力倍率是否真的进了物理、卡墙能否继续开 + 车尾穿模、卡墙几何取证、翻车恢复）。
## 同样用 preload 而不是 class_name，原因同 EnvironmentFX：无编辑器环境下
## class_name 依赖编辑器才重建的 .godot 全局类缓存。
## 注入：_after_world_ready 里 _checks_envphys.setup(...) —— 车/赛道/世界环境/物理世界
## 注入（模块不 get_node，§2.4）；physics_frame 经 Callable 递入（同 screenshot_mode /
## bench）；对手生成注入**本文件持有的实例**（状态在实例上，第二份会拿到空）。
## 另有 probe_blocker()（卡住取证，非分发入口）：_check_lap 的调用点走
## _checks_envphys.probe_blocker()。
const ChecksEnvPhys := preload("res://scripts/checks/env_phys.gd")
var _checks_envphys := ChecksEnvPhys.new()

## 基础验收模块（SPLIT-CHECKS-BASIC-005a 从本文件拆出）：--check=enclosure / reset / oob /
## minimap / resetkey / escape / pause 七族（围墙封闭 / 复位落点 / 出界兜底 / 小地图 /
## R 键保护与无敌帧 / 起点缺口原点复现 / ESC 暂停）。同样用 preload 而不是 class_name，
## 原因同 EnvironmentFX：无编辑器环境下 class_name 依赖编辑器才重建的 .godot 全局类缓存。
## 注入：_after_world_ready 里 _checks_basic.setup(...) —— 车/赛道/小地图/暂停菜单/障碍场/
## 物理世界注入（模块不 get_node，§2.4）；SceneTree（非信号 tree 能力）与 physics_frame
## Callable 递入（physics_frame 同 screenshot_mode / bench）；mark_keep_alive 是"置
## _keep_alive_after_check"的场景能力 Callable（模块不得直接写 main 成员）。
const ChecksBasic := preload("res://scripts/checks/basic.gd")
var _checks_basic := ChecksBasic.new()

## 跑圈/压测/反向验收模块（SPLIT-CHECKS-BASIC-005b 从本文件拆出）：--check=lap / stress /
## reverse 三族。同样用 preload 而不是 class_name，原因同 EnvironmentFX：无编辑器环境下
## class_name 依赖编辑器才重建的 .godot 全局类缓存。
## 注入：_after_world_ready 里 _checks_lap.setup(...) —— 车/赛道/HUD/障碍场注入（模块不
## get_node，§2.4）；[DEBUG-L4] 诊断、自动驾驶、对手生成、env_phys 模块注入**本文件持有的
## 实例**（状态在实例上，第二份会拿到空）；physics_frame / add_child 经 Callable 递入；
## REVERSE_CASES 条数传入而非复制（ADR-001 永久居民，§5.3）。
const ChecksLap := preload("res://scripts/checks/lap.gd")
var _checks_lap := ChecksLap.new()
const CheckEvidence := preload("res://scripts/checks/evidence.gd")
var _check_evidence := CheckEvidence.new()

# 验收模式状态（只有带 --check 启动时才用）
var _check := ""
var _check_frame := 0
var _check_running := false
## 检查里重载了场景时置 true：让旧场景不要 quit()，把流程交给新场景
var _keep_alive_after_check := false

## 本关的 AI 对手（ai_opponents 台）。空数组 = 本关没有对手。
##
## ⚠ 这是**只读代理**：真身在 _opponent_spawner（SPLIT-OPPONENT-001 把对手生成族连同
## 这个数组一起迁走了）。本文件有 20+ 处读点（checks 族是 ADR-001 永久居民），做成同名的
## 只读 getter 可以让它们一个字都不用改，同时杜绝"两边各存一份数组"的漂移 ——
## 写入（append / 清空）只允许发生在模块里，本文件企图赋值会直接解析失败。
var _opponents: Array:
	get:
		return _opponent_spawner.opponents
## 障碍物场（没有障碍的关卡为 null）
var _obstacle_field: Node3D = null


## 生成障碍物。必须在 AI 之前调用 —— AI 摆车道时要查询障碍位置。
func _build_obstacles(track: Node3D, cfg: LevelConfig) -> void:
	if track == null or cfg == null:
		return
	if cfg.obstacle_count <= 0 and cfg.dynamic_obstacle_count <= 0:
		return
	var script: GDScript = load("res://scripts/obstacle_field.gd")
	if script == null:
		printerr("[main] 无法加载 obstacle_field.gd")
		return
	_obstacle_field = script.new()
	_obstacle_field.name = "Obstacles"
	add_child(_obstacle_field)
	_obstacle_field.call("build", cfg, track)
	# 把障碍物场也交给**玩家车**：它的复位落点要查占用。
	# 为什么必须给（2026-10 实测）：`vehicle.reset_to_track()` 原本落在"最近的**中心线**点"，
	# 而 L4 的石头横向 ∈ [0, 0.125]m（`_pick_lateral()` 的 `safe_max`）→ 石头横跨中心线，
	# 于是复位 = **把车放回石头里** → 再卡 → 再复位。日志里 `reset_to_track` 连续两次
	# 落在弧长 1209.8 / 1210.5（同一个点）。与上面给 AI 的注入是**同一个节点、同一份真相**。
	if _car != null:
		_car.set("obstacle_field", _obstacle_field)
## 加对手**之前**测到的物理帧耗时（毫秒，-1 表示没测到）：随对手生成族一起迁到了
## scripts/opponent_spawner.gd（SPLIT-OPPONENT-001），需要看这个值取
## `_opponent_spawner` 侧即可 —— 本文件不再持有一份，免得两边不一致。
## （曾有一个 `_ai_started` 只读代理与此并列，2026-10-18 删：全仓零读取方，
##   留着就是 UNUSED_PRIVATE_CLASS_VARIABLE 警告 + 死代码；真身与只读取值口
##   都在 opponent_spawner.gd，ai.gd 的同名代理同期删除。）
## 场景装配（赛道 + 对手）是否已完成。
## 检查脚本必须等它为 true 再跑 —— 否则会在对手还没生成时就开始验收。
var _setup_done := false


func _ready() -> void:
	if _is_automation_run():
		# 自动化路径（--check / --shot）：与 Phase 01 之前逐帧等价 —— _ready 即
		# RACING，装配期就能驾驶/摆位（截图模式从第一帧就按 W，不能有输入锁）。
		GameState.begin_race()
	else:
		# 互动路径：清成绩进 LOADING，装配期锁死驾驶输入（策划案 R4）。
		# ⚠ 为什么 LOADING 不暂停树：装配要 await physics_frame 测物理基线，
		#   暂停会让那些 await 永不返回（装配死锁）——"装配期别动"由
		#   vehicle.gd 的 start_locked 负责，不靠暂停。
		GameState.prepare_race()
		_car.start_locked = true
	_apply_level_config()
	# 检查点、小地图依赖都要等赛道生成完（赛道是延迟构建的）
	_after_world_ready()


## 本次启动是否自动化路径（--check= / --shot）。
## 为什么在 _ready 用参数嗅探而不是等 _after_world_ready 里的 _parse_check_args()：
## 赛前输入锁必须在**第一个物理帧之前**置上（LOADING 期按键不应驱动车），
## 而 _parse_check_args 在 await 之后才跑。先例：GameState.request_exit()
## 用同一段前缀判断"自动退出不弹确认框"；rel_final_mode_guard_test 同款。
func _is_automation_run() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--check=") or a.begins_with("--shot"):
			return true
	return false


func _after_world_ready() -> void:
	var track := get_node_or_null("Track")
	if track != null and track.has_method("await_world_ready"):
		await track.call("await_world_ready")
	_connect_checkpoints()
	_engine_audio.setup(_car)
	# AI 对手要等赛道建好才能摆发车格（赛道是延迟构建的）。
	#
	# ⚠ 必须 await：_opponent_spawner.spawn_opponents 里有 await（要测无对手时的物理耗时基线），
	# 于是它变成协程。不 await 的话这里会**立刻往下走**、检查脚本在对手还没
	# 生成出来的时候就开始跑（实测表现是"本关 ai_opponents = 4，没有对手可测"）。
	# 这类"协程没 await"的坑本文件已经踩过两次（另一次是 load() 类型推断）。
	# 障碍物必须在对手**之前**建好：AI 生成时就要查询车道是否被挡。
	_build_obstacles(track, GameState.current_level())
	# [DEBUG-L4] 诊断模块接线（SPLIT-L4DIAG-001）：障碍物建好后才拿得到 _obstacle_field。
	# body_half / avoid_horizon 是下面自动驾驶侧的车身常量，传入而不是在模块里复制第二份。
	_l4_diag.setup(_car, _obstacle_field, Autopilot.DRIVE_BODY_HALF, Autopilot.DRIVE_AVOID_HORIZON)
	# 自动驾驶模块接线（SPLIT-AUTOPILOT-002）：car / field / diag 一次性注入。
	# diag 必须是 _l4_diag 这个实例本身 —— [DEBUG-L4] 诊断状态全在它身上，
	# preload 第二份会拿到空状态，A/B 与取证全部失真。
	_autopilot.setup(_car, _obstacle_field, _l4_diag)
	# 截图模式模块接线（SPLIT-SCREENSHOT-001）：车 / 赛道 / 相机原是下面
	# get_node_or_null 的静态兄弟节点，改为注入；自动驾驶与引擎声注入**本文件持有的实例**
	# （不 preload 第二份：frames_pushed 等状态在实例上，第二份拿到空状态）；
	# 再注入 3 个场景能力 Callable（取 viewport 图像 / 退出 / physics_frame 信号）——
	# 模块不持有场景，与 opponent_spawner 的 _mount 回调同一约定。
	_screenshot_mode.setup(_car, track, _autopilot, _engine_audio,
		get_node_or_null("ChaseCamera"), Callable(self, "_shot_capture_image"),
		Callable(self, "_shot_quit_app"), Callable(self, "_shot_physics_frame"))
	# 赛道布局验收模块接线（SPLIT-CHECKS-LAYOUT-001）：Track 由本文件注入（模块不
	# get_node，§2.4）；两个用例条数常量传入而非复制（ADR-001 永久居民）。
	_checks_layout.setup(track, LAYOUT_ELEV_CASES, LAYOUT_RACING_CASES, _check_evidence)
	# 台架验收模块接线（SPLIT-CHECKS-BENCH-002）：车 / 赛道由本文件注入（模块不
	# get_node，§2.4）；physics_frame 信号经 Callable 递入（同 screenshot_mode）。
	_checks_bench.setup(_car, track, Callable(self, "_shot_physics_frame"), _check_evidence)
	# AI 验收模块接线（SPLIT-CHECKS-AI-003）：车/赛道注入（模块不 get_node，§2.4）；
	# 对手生成/自动驾驶注入本文件持有的**实例**（状态在实例上）；physics_frame 与
	# _sample_physics_ms 采样器经 Callable 递入（同 screenshot_mode / bench）。
	# Phase 01 追加 _on_race_go 发车回调：aistart / aidiag 经它触发与游玩同一条
	# 发车路径（D1 批准改验同步发车语义，判据串与项数不变）。
	# ⚠ 2026-10-18：_obstacle_field 与 get_world_3d() 两个参数随 avoid/obstacles
	# 迁往 _checks_ai_field（SPLIT-CHECKS-AI-006），本调用 9 参 → 7 参。
	_checks_ai.setup(_car, track, _opponent_spawner, _autopilot,
		Callable(self, "_shot_physics_frame"), Callable(self, "_sample_physics_ms"),
		Callable(self, "_on_race_go"), _check_evidence, _ai_tape_config())
	# AI×场地交互验收模块接线（SPLIT-CHECKS-AI-006）：车/赛道/障碍场/物理世界注入
	# （模块不 get_node，§2.4）；对手生成注入本文件持有的**实例**（armed 状态在实例上，
	# 第二份会拿到空状态）；physics_frame 经 Callable 递入（同 ai.gd 决策②）。
	# ⚠ 顺序仍在 _build_obstacles 之后：avoid 要把玩家摆上 AI 车道、obstacles 要查
	# 障碍几何，早注入只会拿到 null。
	_checks_ai_field.setup(_car, track, _obstacle_field, _opponent_spawner,
		get_world_3d(), Callable(self, "_shot_physics_frame"), _check_evidence)
	# 环境物理验收模块接线（SPLIT-CHECKS-ENVPHYS-004）：车/赛道/世界环境/物理世界注入（模块不
	# get_node，§2.4）；physics_frame 经 Callable 递入（同 screenshot_mode / bench）；对手生成
	# 注入本文件持有的**实例**（状态在实例上，第二份会拿到空）。
	_checks_envphys.setup(_car, track,
		get_node_or_null("WorldEnvironment") as WorldEnvironment, get_world_3d(),
		_opponent_spawner, Callable(self, "_shot_physics_frame"), _check_evidence)
	# 基础验收模块接线（SPLIT-CHECKS-BASIC-005a）：车/赛道/小地图/暂停菜单/障碍场/物理世界由
	# 本文件注入（模块不 get_node，§2.4）；SceneTree（非信号 tree 能力）与 physics_frame
	# Callable 递入（同 screenshot_mode / bench）；mark_keep_alive 是"置 _keep_alive_after_check"
	# 的场景能力 Callable（模块不得直接写 main 成员）。
	_checks_basic.setup(_car, track, get_node_or_null("Minimap"),
		get_node_or_null("PauseMenu"), _obstacle_field, get_world_3d(),
		get_tree(), Callable(self, "_shot_physics_frame"), Callable(self, "_mark_keep_alive"), _check_evidence)
	# 跑圈/压测/反向验收模块接线（SPLIT-CHECKS-BASIC-005b）：车/赛道/HUD/障碍场注入（模块不
	# get_node，§2.4）；诊断/自动驾驶/对手生成/env_phys 注入本文件持有的**实例**（状态在实例上，
	# 第二份会拿到空）；physics_frame / add_child 经 Callable 递入；REVERSE_CASES 条数传入。
	_checks_lap.setup(_car, track, _hud, _l4_diag, _autopilot, _obstacle_field,
		_opponent_spawner, _checks_envphys, get_tree(),
		Callable(self, "_shot_physics_frame"), Callable(self, "_mount_check_node"),
		REVERSE_CASES, _check_evidence)

	# 对手生成模块接线（SPLIT-OPPONENT-001）：必须在障碍物建好**之后**（AI 要查障碍），
	# 且必须在生成之前。注入的两样东西都是"别人的能力"，模块自己一个都没有：
	#   · _mount_opponent_holder：把对手容器挂进场景树 —— 只有本场景有权做这件事；
	#   · _car / _obstacle_field：AI 组装时要写入的目标引用。
	_opponent_spawner.setup(_car, _obstacle_field, Callable(self, "_mount_opponent_holder"))
	# 生成分三步，**顺序不能改**：先裁决（含所有跳过原因的打印）→ 再采样物理基线 →
	# 最后真正生成。track 作为参数传入（原来模块里要自己 get_node("Track")，
	# 违反"不认识场景树"）。
	#
	# ⚠ 为什么那一拍 `await` 必须留在**本文件这一层协程**：这是本次 A/B 抓到过的真差别。
	#   让 main 去 await 模块里的协程、模块再去 await 采样器，await 就深了一层，
	#   Godot 协程在 physics_frame 上的恢复时机随之差 **1 个物理帧** —— 现象是场景刚就绪
	#   就偏半帧，跑圈日志从第 137 行（t=2.3s，车速 0.15 vs 0.17 m/s）起全程发散。
	#   模块因此刻意不写 await（由 split-opponent-structcheck.ps1 机器看住）。
	var want_opponents := _opponent_spawner.should_spawn(GameState.current_level(), track)
	if want_opponents > 0:
		# 真·基线：在**一台对手都还没加进来**的时候测物理耗时。
		# 之前我把"对手怠速"当成基线，那是错的 —— 报告出来的增量会严重偏小。
		_opponent_spawner.set_baseline_ms(await _avg_physics_ms(
			OpponentSpawner.BASELINE_FRAMES, OpponentSpawner.BASELINE_SETTLE))
		_opponent_spawner.spawn_opponents(GameState.current_level(), track, want_opponents)
	if _parse_check_args():
		_setup_done = true
		return
	# ⚠ 这里**故意不发车**：发车时机只有一处 —— 倒计时到点的 _on_race_go()
	# （互动路径）或各验收族自己的 arm_opponents()（自动化路径）。
	#
	# 历史教训（2026-10-18 Phase 01 之前的旧规则，留档）：原来这里有一句
	# _opponent_spawner.arm_opponents()，导致**关卡一加载 AI 就抢跑**；更糟的是
	# 它在 _parse_check_args() 的 return **之后**，所以 --check=aistart 根本走不到
	# 这一行 —— **验收通过，游戏却是错的**。后来改成"_process 轮询玩家速度
	# ≥4km/h 才发车"，2026-10-18 又随同步发车需求退役（玩家不按键 AI 也发车）。
	# 这条脉络印证本项目用返工换来的铁律：验收与真实游玩必须共用同一条发车路径。
	_screenshot_mode.parse_args()
	if not _screenshot_mode.mode:
		# 互动路径：装配完成 → 进 COUNTDOWN（树暂停）→ 挂倒计时 UI。
		# "出发！"由倒计时 finished 信号触发唯一发车回调（策划案 §5.2）。
		_race_position = RacePosition.new()
		_race_position.setup(_car, track, _opponents)
		add_child(_race_position)
		for ai in _opponents:
			ai.race_finished.connect(_on_ai_finished.bind(ai))
		_car.race_finished.connect(_on_race_finished)
		GameState.enter_countdown()
		_mount_countdown()
	_setup_done = true


## 挂载倒计时 UI（Phase 01）。作为 main 的子节点入树；process_mode = ALWAYS，
## 树暂停期间照常显示与计时。互动路径专用（自动化路径不挂）。
func _mount_countdown() -> void:
	if _countdown != null and is_instance_valid(_countdown):
		return
	_countdown = StartCountdown.new()
	add_child(_countdown)
	if not _countdown.finished.is_connected(_on_race_go):
		_countdown.finished.connect(_on_race_go)


## 唯一发车回调（"出发！"）：倒计时 finished 信号连到它；自动化验收（aistart /
## aidiag）经注入的同一个 Callable 触发它 —— 游玩与验收共用同一条发车路径。
##
## 三步在**同一个回调内**完成 → 下一个物理帧同时生效（策划案 §5.2 的"同步"定义）：
##   ① 玩家解锁（start_locked = false）—— 倒计时里按住的方向键不释放，直接给油（E6）
##   ② 全部 AI 发车（arm_opponents，幂等）
##   ③ GameState 切 RACING + 解冻 + 盖总时间起点 race_start_ms（start_race，R15）
## ⚠ ③ 不能用 begin_race()：它会 release_drive_input() 吞掉按住的方向键。
func _on_race_go() -> void:
	_car.start_locked = false
	_opponent_spawner.arm_opponents()
	GameState.start_race()
	_check_evidence.event("GO", "race", {"player_start_locked": _car.start_locked,
		"opponent_count": _opponents.size()})
	print("[main] 出发！玩家与 %d 台对手同步发车（总时间从此刻起算）" % _opponents.size())


func _on_race_finished(total_laps: int) -> void:
	if GameState.phase_name() != "RACING" or _player_finish_pending \
			or _car.laps_target <= 0 or total_laps < _car.laps_target:
		return
	_player_finish_pending = true
	_race_position.record_finish(_car, total_laps)
	# 物理帧里玩家与 AI 都可能压线：等本帧所有回调结束再结算，才不会漏掉同帧并列。
	if Engine.is_in_physics_frame():
		call_deferred("_finalize_player_race", total_laps)
	else:
		_finalize_player_race(total_laps)


func _on_ai_finished(total_laps: int, ai: VehicleBody3D) -> void:
	if GameState.phase_name() == "RACING" and _race_position != null \
			and total_laps >= int(ai.get("laps_target")):
		_race_position.record_finish(ai, total_laps)


func _finalize_player_race(total_laps: int) -> void:
	if not GameState.finish_race(total_laps, _car.lap_last, _car.lap_best, _car.laps_target):
		_player_finish_pending = false
		return
	var entries: Array = _race_position.standings()
	var player_rank := 1
	for entry in entries:
		if entry.get("id") == "player":
			player_rank = int(entry.get("rank", 1))
			# 物理帧完成信号可能延后到 idle 才结算；总时间仍锁在信号当刻。
			GameState.finish_snapshot["total"] = float(entry.get("total", GameState.finish_snapshot["total"]))
			break
	GameState.finish_snapshot["position"] = player_rank
	GameState.finish_snapshot["field_size"] = entries.size()
	GameState.finish_snapshot["outcome"] = _race_position.player_outcome(entries)
	GameState.finish_snapshot["entrants"] = entries
	var finish := FinishMenu.new()
	finish.result = GameState.finish_snapshot.duplicate()
	add_child(finish)


## 把对手容器挂进本场景。**由 opponent_spawner.gd 通过注入的 Callable 回调**（SPLIT-OPPONENT-001）。
##
## 为什么要留这一个回调而不让模块自己 add_child：模块不得持有场景树所有权。
## ⚠ 而为什么必须是"回调式"而不是"模块返回 holder、本文件再挂"：那样容器会先脱离
## 树被塞满 AI，`holder.add_child(ai)` 就把 AI 的 _ready 推迟到容器入树那一刻，
## 于是 setup() 反而跑在 _ready **之前**（原来是 _ready 先、setup 后）—— 这是纯迁移
## 最容易悄悄夹带的时序变化。详见 opponent_spawner.gd 文件头决策 ②。
func _mount_opponent_holder(n: Node3D) -> void:
	add_child(n)


## 截图模块取 viewport 一帧图像的回调（SPLIT-SCREENSHOT-001 注入）。
## 为什么是回调：模块是 RefCounted、不在场景树上，没有 get_viewport()；
## 而"抓一帧图"是场景能力，与 opponent_spawner 的 _mount 回调同一约定。
func _shot_capture_image() -> Image:
	return get_viewport().get_texture().get_image()


## 截图模块退出进程的回调（SPLIT-SCREENSHOT-001 注入）。
func _shot_quit_app() -> void:
	get_tree().quit()


## 截图模块等一帧的回调（SPLIT-SCREENSHOT-001 注入）：返回 physics_frame 信号本体，
## 模块里 `await _physics_frame.call()` 与迁移前 `await get_tree().physics_frame`
## 是同一个 Signal，协程恢复时机不变（wrongway_warp 的两处 await 之一）。
func _shot_physics_frame() -> Signal:
	return get_tree().physics_frame


## 把检查夹具节点挂进本场景的回调（SPLIT-CHECKS-BASIC-005b 注入）：run_stress 要
## `add_child(鲁莽玩家 driver)`。同 _mount_opponent_holder 的约定 —— 模块不得持有场景树
## 所有权；改成"模块自己 add_child"会拿不到场景，改成"模块建好、本文件再挂"又会推后时序。
func _mount_check_node(n: Node) -> void:
	add_child(n)


## 置 _keep_alive_after_check 的场景能力回调（SPLIT-CHECKS-BASIC-005a 注入）：暂停验收点
## "重新开始"会 reload_current_scene，本场景不能退出进程（否则新场景还没跑它的检查就被
## quit() 掉），把收尾交给新场景。模块不得直接写 main 成员，故经 Callable 递入。
func _mark_keep_alive() -> void:
	_keep_alive_after_check = true


## 把 GameState 里选中的关卡配置注入赛道、车辆与环境。
##
## ⚠ 这里有个顺序陷阱（实测踩过）：Track 是 Main 的**兄弟节点**且排在前面，
## Track._ready() 比 Main._ready() **先**跑。所以不能在这里 set 赛道参数 ——
## 实测五个关卡的曲线长度全是 1635.1m（参数完全没生效）。
## 正确做法：把 config 交给 Track，让它**自己**在 ready/构建时应用；
## 因为 Main 的 script 优先级高于实例场景，这里的 _ready 一定早于 Track.build_world()。
func _apply_level_config() -> void:
	var cfg: LevelConfig = GameState.current_level()
	if cfg == null:
		push_warning("[main] 没有关卡配置，使用赛道默认参数（标准椭圆）")
		return
	var track := get_node_or_null("Track")
	if track == null:
		return
	# 交棒给 Track，并**显式驱动它生成**。
	#
	# 为什么必须显式调用而不是指望 Track._ready() 读到参数：
	#   Track 是 track.tscn 的实例场景，其脚本优先级（实例场景 < 父场景脚本）低于本脚本，
	#   但 Godot 触发 _ready 的顺序又是"按节点顺序"，结果 Track._ready() 仍然先跑完、
	#   用默认参数把赛道生成好了 —— 实测五个关卡的曲线长度全是 1635.1m。
	#   现在把生成动作从 _ready 里挪出来（build_world 幂等），由这里在 set 完参数后触发。
	track.set("level_config", cfg)
	track.call_deferred("build_world")
	if _car != null:
		_car.apply_level_setup(GameState.effective_speed(), cfg.laps_to_finish, cfg.friction_multiplier)
	# 天气/环境整块已迁至 scripts/environment.gd（SPLIT-ENV-001 纯迁移，行为零变化）
	EnvironmentFX.apply_environment(cfg,
		get_node_or_null("WorldEnvironment") as WorldEnvironment,
		get_node_or_null("Sun") as DirectionalLight3D, _car)
	# 天气环境音（雨声）：只雨天挂载，走 Ambient 总线。非雨天由模块内部释放掉残留。
	# 放在视觉之后：两者读同一份 cfg.weather_type，视觉先落，音频紧随，口径一致。
	_weather_audio.apply_weather_audio(cfg, _car)
	print("[main] 关卡已加载：%s（%s）椭圆 %.0f×%.0f 路宽 %.0f 抓地力 ×%.2f 极速 %.0f"
		% [cfg.display_name, cfg.difficulty, cfg.radius_x, cfg.radius_z,
		   cfg.road_width, cfg.friction_multiplier, GameState.effective_speed()])




## 暂停 / 恢复 / 离树时同步天气环境音（雨声）。
##
## 为什么走**通知**而不是在 _process 里轮询：树一暂停，本节点的 _process 就**不再被
## 调用**（process_mode 是 INHERIT），根本没机会轮询；而暂停恰恰是最需要停雨声的时刻。
## NOTIFICATION_PAUSED / UNPAUSED 是 SceneTree 在 `get_tree().paused` 翻转时沿树投递的，
## 两个方向都收得到。
##
## 结算面板将来只要也用 `get_tree().paused = true`（与暂停菜单同一机制），雨声会跟着一起
## 停 —— 不用回这里补代码。反过来，若哪天加的结算界面**不**置 paused，就得显式调
## _weather_audio.set_paused(true)，那是新代码的责任，不能指望这里兜住。
func _notification(what: int) -> void:
	if what == NOTIFICATION_PAUSED:
		_weather_audio.set_paused(true)
	elif what == NOTIFICATION_UNPAUSED:
		_weather_audio.set_paused(false)
	elif what == NOTIFICATION_EXIT_TREE:
		# 切关 / 回菜单：显式释放。播放器本身是车的子节点、会随车销毁，这里是双保险
		# （车被复用而场景没重建时，旧播放器不会跟着新实例一起走）。
		_weather_audio.release()


## 自动验收模式：跑完检查写日志并退出，不需要人看画面。
##
## 用法：godot --path <工程> -- --check=enclosure
##   enclosure: 沿整条中心线每 0.1m 朝两侧各发一条射线，验证围墙全周封闭。
##              有任意一处打不到碰撞体就报错（这是"起点旁边没封住"的回归测试）。
func _parse_check_args() -> bool:
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--check="):
			_check = a.split("=", true, 1)[1]
	# [DEBUG-L4] 诊断模块的门限（SPLIT-L4DIAG-001）：只有 lap 模式才输出。
	# 放在这里是因为 _check 只在本函数解析，且它比 _after_world_ready 里的
	# _l4_diag.setup() 晚一步跑（setup 只注入引用，不依赖 _check）。
	_l4_diag.check_name = _check
	if _check.is_empty():
		return false
	print("[CHECK] 验收模式=%s 启动" % _check)
	var evidence_identity: Dictionary = {}
	# 登记器未启用时该环境变量为空；空串进 JSON.parse_string 会打一条
	# "Parse JSON failed" 噪音（非登记运行每次必现），先判空再解析。
	var identity_raw := OS.get_environment("AC13_RUN_IDENTITY")
	var supplied_identity: Variant = JSON.parse_string(identity_raw) if not identity_raw.is_empty() else null
	if supplied_identity is Dictionary:
		evidence_identity = supplied_identity
	evidence_identity["check"] = _check
	_check_evidence.setup(_car, get_node_or_null("Track"), _opponents, evidence_identity,
		Callable(self, "_evidence_proxy_observer"))
	_check_frame = 0
	return true


func _check_tick() -> void:
	# 场景装配没完成就绝不开始验收：
	# _after_world_ready 里有 await（等赛道构建、测物理基线），期间 _process 照跑。
	# 少了这道闸，检查会在"对手还没生成"的状态下开测并给出假结论。
	if not _setup_done:
		return
	_check_frame += 1
	# 等物理与场景稳定（顺便让墙面全部注册进物理服务器）
	if _check_frame < 40:
		return
	# 多帧检查用 await 推进，期间不能再进入本函数，否则会和 _check_done 抢着退出
	if _check_running:
		return
	_check_running = true
	match _check:
		"enclosure":
			_checks_basic.run_enclosure()
		"reset":
			await _checks_basic.run_reset()
		"oob":
			await _checks_basic.run_out_of_bounds()
		"minimap":
			await _checks_basic.run_minimap()
		"resetkey":
			await _checks_basic.run_reset_key()
		"escape":
			await _checks_basic.run_escape()
		"lap":
			await _checks_lap.run_lap()
		"stuck":
			await _checks_envphys.run_stuck()
		"wallslide":
			await _checks_envphys.run_wallslide()
		"stress":
			await _checks_lap.run_stress()
		"opponents":
			await _checks_ai.run_opponents()
		"friction":
			await _checks_envphys.run_friction()
		"steerbench":
			await _checks_bench.run_steerbench()
		"brakebench":
			await _checks_bench.run_brakebench()
		"phys":
			await _checks_envphys.run_phys()
		"weather":
			await _checks_envphys.run_weather()
		"aistart":
			await _checks_ai.run_ai_start()
		"obstacles":
			# run_obstacles 是非协程（函数体内无 await）—— 调用点加 await 会报
			# REDUNDANT_AWAIT，且那一拍本是 no-op，同步调用行为完全一致。
			# ⚠ 2026-10-18 SPLIT-CHECKS-AI-006：该族已迁至 _checks_ai_field。
			_checks_ai_field.run_obstacles()
		"avoid":
			await _checks_ai_field.run_avoid()
		"aidiag":
			await _checks_ai.run_ai_diag()
		"pause":
			await _checks_basic.run_pause()
		"flip":
			await _checks_envphys.run_flip()
		"layout":
			# run() 是非协程：SPLIT-CHECKS-LAYOUT-001 决策②已清掉其内部 await
			# （含 _check_layout_level 那一拍），调用点同步执行即可。
			_checks_layout.run()
		"reverse":
			await _checks_lap.run_reverse()
		_:
			print("[CHECK] 未知的检查项：%s" % _check)
	# 有些检查会**重载场景**（比如暂停验收要验"重新开始"）。
	# 这时旧场景不能退出进程 —— 否则刚重建的新场景还没跑它的检查就被 quit() 掉了
	# （实测：日志里能看到新赛道建好，紧接着就是"完成，退出"，阶段2 从来没跑过）。
	if _keep_alive_after_check:
		print("[CHECK] 场景已重载，交由新场景继续检查（本次不退出）")
		return
	_check_done()


func _evidence_proxy_observer(body: VehicleBody3D):
	var observer := L4DebugDiag.new()
	observer.setup(body, _obstacle_field, Autopilot.DRIVE_BODY_HALF, Autopilot.DRIVE_AVOID_HORIZON)
	return observer


func _check_done() -> void:
	print("[CHECK] 完成，退出")
	await get_tree().process_frame
	_checks_ai.finish_tape_evidence()
	_check_evidence.finish(_check)
	get_tree().quit()


func _ai_tape_config() -> Dictionary:
	var mode := "replay"
	# 默认走**已冻结**输入带（正式验收口径）；校准稿只用于 -AiTapeMode calibrate 生成候选。
	# ⚠ 冻结清单绑定了本文件的源码哈希：改动 main.gd / vehicle.gd / autopilot.gd /
	#   game_state.gd / race_car.tscn / project.godot / level_1.tres 会让绑定失效，
	#   必须重新执行「校准生成 → 冻结」两步，不能拿旧冻结带继续跑。
	var manifest := "res://data/checks/frozen/scenario.json"
	var output := "user://aidiag-calibration.json"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--ai-tape-mode="):
			mode = argument.split("=", true, 1)[1]
		elif argument.begins_with("--ai-tape-manifest="):
			manifest = argument.split("=", true, 1)[1]
		elif argument.begins_with("--ai-tape-output="):
			output = argument.split("=", true, 1)[1]
	var project_path := ProjectSettings.globalize_path("res://").trim_suffix("/")
	var repo_path := project_path.get_base_dir()
	var sources := {"04-Godot启动器/run-all-checks.ps1": repo_path.path_join("04-Godot启动器/run-all-checks.ps1"),
		"04-Godot启动器/check-readme.ps1": repo_path.path_join("04-Godot启动器/check-readme.ps1")}
	for module in ["layout", "bench", "ai", "ai_field", "env_phys", "basic", "lap"]:
		var path := "godot-racer/scripts/checks/%s.gd" % module
		sources[path] = repo_path.path_join(path)
	var deadline := ChecksAi.AI_INTERACTION_SEC + ChecksAi.AI_FREE_RUN_SEC
	return {"mode": mode, "manifest_path": manifest, "calibration_output": output,
		"channels": ["accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake"],
		"calibration_lookahead_m": 45.0, "geometry_audit_step_m": 1.0,
		"level_config_path": GameState.current_level().resource_path,
		"contract_sources": sources, "free_run_gap_m": ChecksAi.AI_FREE_RUN_GAP_M,
		"required_tape_frames": ceili(deadline * Engine.physics_ticks_per_second),
		"frame_origin_and_input_phase": "first physics_frame signal callback after GO, before node physics; local frame zero",
		"window_rule_version": "existing-natural-gap-30m-before-interaction-end; unchanged-warmup-2s; no-isolation-fallback/1",
		"observation_deadline": {"source": "AI_INTERACTION_SEC + AI_FREE_RUN_SEC", "seconds": deadline,
			"nominal_physics_frames": ceili(deadline * Engine.physics_ticks_per_second)}}


# --check=reset 已迁至 scripts/checks/basic.gd 的 run_reset()
# （SPLIT-CHECKS-BASIC-005a 纯迁移，行为零变化）。


# 卡墙验收族（_check_wallslide + _visual_lateral_extent）已迁至
# scripts/checks/env_phys.gd 的 run_wallslide()（SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。


# 卡墙诊断族（_check_stuck）已迁至 scripts/checks/env_phys.gd 的 run_stuck()
# （SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。


# 自动驾驶族（11 个 DRIVE_* 常量 + drive_* 追线/恢复方法 + pose_facing）已迁至
# scripts/autopilot.gd（SPLIT-AUTOPILOT-002 纯迁移，行为零变化）。
# 本文件残留引用：常量走 Autopilot.<NAME>，方法走 _autopilot.drive_*，
# 位姿构造走 Autopilot.pose_facing(...) —— 均不复制第二份。

# aidiag 的 9 个 AI_* 判据常量（AI_RECOVER_WARN_SEC / AI_TARGET_* / AI_BEND_GUARD_SEG）
# 已迁至 scripts/checks/ai.gd（SPLIT-CHECKS-AI-003 纯迁移，行为零变化）—— 不复制第二份。


# 卡住取证（_probe_blocker）已迁至 scripts/checks/env_phys.gd 的 probe_blocker()
# （SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）；下面 _check_lap 的卡住取证调用点
# 改走 _checks_envphys.probe_blocker()。



# --check=lap 已迁至 scripts/checks/lap.gd 的 run_lap()
# （SPLIT-CHECKS-BASIC-005b 纯迁移，行为零变化）。


# 兜底判定（_reset_loop_hit）与压测族（_check_stress）已迁至 scripts/checks/lap.gd 的
# _reset_loop_hit() / run_stress()（SPLIT-CHECKS-BASIC-005b 纯迁移，行为零变化）。


# --check=openrouter / --check=models 已随 OpenRouter 功能整体移除（2026-10-14）。
# 这两项曾是开发期联网探针（连通性自检 / 查询免费模型目录），与游玩无关；
# 移除后 match _check: 的检查项由 26 降为 24。移除理由与范围见 push-log 与 HANDOVER。


# --check=opponents 已迁至 scripts/checks/ai.gd 的 run_opponents()
# （SPLIT-CHECKS-AI-003 纯迁移，行为零变化）。


## 取物理帧耗时的平均值与峰值（毫秒）。
##
## 为什么要先"稳定"再采样：4 台车是**从空中 1.2m 落下**的，悬挂落地那几十帧
## 物理开销天然很高。第一版把"落地抖动期"也算进平均，结果测出"对手怠速 7.82ms
## 比行驶中 2.70ms 还贵"这种自相矛盾的数字。现在每个阶段先空转 settle 帧丢掉。
##
## 用 Performance.TIME_PHYSICS_PROCESS：引擎每帧花在 3D 物理上的时间。
## 峰值比平均更重要 —— 掉帧是被最慢的那一帧决定的。
func _avg_physics_ms(frames: int, settle := 60) -> float:
	var r: Dictionary = await _sample_physics_ms(frames, settle)
	return float(r.get("avg", 0.0))


func _sample_physics_ms(frames: int, settle := 60) -> Dictionary:
	for i in range(maxi(0, settle)):
		await get_tree().physics_frame
	var total := 0.0
	var peak := 0.0
	var n := maxi(1, frames)
	for i in range(n):
		await get_tree().physics_frame
		var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		total += ms
		peak = maxf(peak, ms)
	return {"avg": total / float(n), "max": peak}


# 物理开销测量（--check=phys）已迁至 scripts/checks/env_phys.gd 的 run_phys()
# （SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。


# --check=aidiag 已迁至 scripts/checks/ai.gd 的 run_ai_diag()
# （SPLIT-CHECKS-AI-003 纯迁移，行为零变化）。


# 暂停验收族（_check_pause + _menu_press_escape）已迁至 scripts/checks/basic.gd 的
# run_pause() / _menu_press_escape()（SPLIT-CHECKS-BASIC-005a 纯迁移，行为零变化）。


# --check=obstacles / avoid 已迁至 scripts/checks/ai_field.gd 的
# run_obstacles() / run_avoid()（2026-10-18 SPLIT-CHECKS-AI-006 从 ai.gd 二次拆出，
# 纯迁移、行为零变化）；--check=aistart 在 scripts/checks/ai.gd 的 run_ai_start()
# （SPLIT-CHECKS-AI-003 纯迁移，行为零变化）。


# 天气验收族（_check_weather + _luminance + MIN_WEATHER_CONTRAST）已迁至
# scripts/checks/env_phys.gd 的 run_weather()（SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。


# 抓地力验收族（_check_friction + _friction_probe）已迁至
# scripts/checks/env_phys.gd 的 run_friction()（SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。


# 位姿构造已迁至 scripts/autopilot.gd（SPLIT-AUTOPILOT-002 纯迁移，行为零变化；
# 纯函数，static func pose_facing，本文件调用点走 Autopilot.pose_facing(...)）



# 转向台架（--check=steerbench）与刹车台架（--check=brakebench）验收族已迁至
# scripts/checks/bench.gd（SPLIT-CHECKS-BENCH-002 纯迁移，行为零变化）；
# 分发口走 await _checks_bench.run_steerbench() / run_brakebench()。

# 翻车恢复验收族（--check=flip：_check_flip + 7 个 helper）已迁至
# scripts/checks/env_phys.gd 的 run_flip()（SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。


## 布局验收 ③ 的用例条数。为什么把这个数字写死并断言：
##   阶段 1 吃过一次**假绿** —— 解析用例跑了 0 条却打印"全过"。
##   只断言 `_layout_pass < 40` 是不够的：剖面用例就算**一条都没跑**，43 条路段用例
##   也会把总数顶在 40 以上，检查照样绿。所以剖面这 10 条要单独计数、单独卡。
## ⚠ SPLIT-CHECKS-LAYOUT-001：本常量是 ADR-001 永久居民 —— check-docs.ps1 直接
##   从 main.gd 原文取值，不随 layout 族外迁；模块经 setup() 注入同值（§5.3）。
const LAYOUT_ELEV_CASES := 10


## 限速 / 刹车距离用例条数。与剖面组同理：单独计数、单独卡，防止"一条没跑也打印全过"。
## ⚠ SPLIT-CHECKS-LAYOUT-001：同上，ADR-001 永久居民，经 setup() 注入模块，
##   不在 scripts/checks/layout.gd 里复制第二份。
const LAYOUT_RACING_CASES := 6


## ==================== 方向反向提示验收（--check=reverse）====================
#
# 需求（2026-09 项目所有者给出精确规格）：赛道只允许**顺时针**行驶；
# 玩家撞墙后车头被弹反时要提示他调头；**倒车不视为"开反了"**。
#
# 判定逻辑在 `track_layout.wrong_way_state()`（纯函数）。纯函数用例族（6 条，逐条对应
# 规格里的场景）+ 真车/真物理/真 HUD 端到端（人为把车头转 180°，以 ~60 km/h 前进）
# 已迁至 scripts/checks/lap.gd 的 run_reverse() / _check_reverse_e2e()
# （SPLIT-CHECKS-BASIC-005b 纯迁移，行为零变化）。
#
# ⚠ REVERSE_CASES 是 ADR-001 永久居民 —— check-docs.ps1 直接从 main.gd 原文取条目数，
#   不随 reverse 族外迁；由 setup() 注入 lap 模块（§5.3 单一来源）。
#   原 `_reverse_cases` / `_reverse_failed` 两个计数状态随族迁入 lap.gd。
const REVERSE_CASES := 6


# reverse 纯函数用例族（_reverse_call + _rev_dot + _reverse_case）已迁至
# scripts/checks/lap.gd（SPLIT-CHECKS-BASIC-005b 纯迁移，行为零变化）。


# --check=reverse 主流程（_check_reverse）、端到端（_check_reverse_e2e）与
# _find_wrong_way_panel 已迁至 scripts/checks/lap.gd 的 run_reverse() /
# _check_reverse_e2e() / _find_wrong_way_panel()（SPLIT-CHECKS-BASIC-005b 纯迁移，行为零变化）。


# 原点复现验收族（_check_escape）与检查点查找 helper（_cp）已迁至
# scripts/checks/basic.gd 的 run_escape() / _cp()（SPLIT-CHECKS-BASIC-005a 纯迁移，行为零变化）。


# R 键保护 + 复位无敌帧验收（_check_reset_key）已迁至 scripts/checks/basic.gd 的 run_reset_key()
# （SPLIT-CHECKS-BASIC-005a 纯迁移，行为零变化）。


# 小地图验收族（_check_minimap + _check_minimap_obstacles）已迁至 scripts/checks/basic.gd 的
# run_minimap() / _check_minimap_obstacles()（SPLIT-CHECKS-BASIC-005a 纯迁移，行为零变化）。


# 出界兜底验收（_check_out_of_bounds）与围墙封闭验收（_check_enclosure）已迁至
# scripts/checks/basic.gd 的 run_out_of_bounds() / run_enclosure()
# （SPLIT-CHECKS-BASIC-005a 纯迁移，行为零变化）。


func _physics_process(_delta: float) -> void:
	_check_evidence.sample()


func _process(_delta: float) -> void:
	# 引擎声占位音源的流式缓冲每帧续填（已迁至 scripts/engine_audio.gd，SPLIT-ENV-002）
	_engine_audio.tick()

	# 旧规则（2026-10-18 Phase 01 退役）：这里每帧轮询"玩家速度 ≥ ai_start_speed_kmh
	# 才 maybe_start_opponents()"。同步发车后 AI 不再等玩家 —— 发车唯一入口是
	# _on_race_go()（倒计时 finished → 三步同帧）；aistart / aidiag 两项验收改走
	# 同一个入口（D1 已批准，判据串不变、项数不变）。

	# 验收模式：跑检查、写日志、退出
	if not _check.is_empty():
		_check_tick()
		return

	if not _screenshot_mode.mode:
		return
	_screenshot_mode.tick()


## 把所有检查点的 car_passed 信号接到 HUD 的 _on_car_passed
func _connect_checkpoints() -> void:
	var connected := 0
	for node in get_tree().get_nodes_in_group("checkpoints"):
		# 用 has_signal 判断，避免 node.get() 返回 Variant 触发类型推断告警
		if not node.has_signal("car_passed"):
			continue
		var cp := node as Area3D
		if cp == null:
			continue
		if not cp.car_passed.is_connected(_hud._on_car_passed):
			cp.car_passed.connect(_hud._on_car_passed)
			connected += 1
	print("[main] 已连接检查点数量: ", connected)
