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

## 占位引擎声模块（SPLIT-ENV-002 从本文件拆出）。同样用 preload 而不是 class_name，
## 原因同 EnvironmentFX：无编辑器环境下 class_name 依赖编辑器才重建的全局类缓存。
const EngineAudio := preload("res://scripts/engine_audio.gd")
var _engine_audio := EngineAudio.new()

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
## 发车时机（玩家速度达到阈值才发）+ 物理基线记账。同样用 preload 而不是 class_name，
## 原因同 EnvironmentFX：无编辑器环境下 class_name 依赖编辑器才重建的全局类缓存。
## 注入：_after_world_ready 里 _opponent_spawner.setup(_car, _obstacle_field,
## _avg_physics_ms 的 Callable, add_child 的 Callable)。
const OpponentSpawner := preload("res://scripts/opponent_spawner.gd")
var _opponent_spawner := OpponentSpawner.new()

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
## avoid / obstacles / aistart 五族（对手跑圈、AI 行为诊断 + 任务 15 目标速度判据、
## 避让玩家路障、障碍物位置/碰撞/通行缝隙、并排发车）。同样用 preload 而不是
## class_name，原因同 EnvironmentFX：无编辑器环境下 class_name 依赖编辑器才重建的
## .godot 全局类缓存。
## 注入：_after_world_ready 里 _checks_ai.setup(...) —— 车/赛道/障碍场/物理世界注入
## （模块不 get_node）；对手生成与自动驾驶注入**本文件持有的实例**（状态在实例上，
## 第二份会拿到空）；physics_frame 与 _sample_physics_ms 采样器经 Callable 递入。
const ChecksAi := preload("res://scripts/checks/ai.gd")
var _checks_ai := ChecksAi.new()

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
## 对手是否已经随玩家起跑（避免每帧重复发车/重复打印）。同样是**只读代理**，真身在
## 模块里 —— 这个闩锁只有 maybe_start_opponents 一处会写，和 _opponents 同理不做第二份。
var _ai_started: bool:
	get:
		return _opponent_spawner.ai_started

## 玩家速度超过这个值就认为"已起步"，对手跟着发动（km/h）。
## 4 km/h 足够低（几乎是刚离地就触发），又不会被物理抖动的残余速度误触发。
@export var ai_start_speed_kmh := 4.0
## 场景装配（赛道 + 对手）是否已完成。
## 检查脚本必须等它为 true 再跑 —— 否则会在对手还没生成时就开始验收。
var _setup_done := false


func _ready() -> void:
	_apply_level_config()
	# 检查点、小地图依赖都要等赛道生成完（赛道是延迟构建的）
	_after_world_ready()


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
	_checks_layout.setup(track, LAYOUT_ELEV_CASES, LAYOUT_RACING_CASES)
	# 台架验收模块接线（SPLIT-CHECKS-BENCH-002）：车 / 赛道由本文件注入（模块不
	# get_node，§2.4）；physics_frame 信号经 Callable 递入（同 screenshot_mode）。
	_checks_bench.setup(_car, track, Callable(self, "_shot_physics_frame"))
	# AI 验收模块接线（SPLIT-CHECKS-AI-003）：车/赛道/障碍场/物理世界注入（模块不 get_node，
	# §2.4）；对手生成/自动驾驶注入本文件持有的**实例**（状态在实例上）；physics_frame 与
	# _sample_physics_ms 采样器经 Callable 递入（同 screenshot_mode / bench）。
	_checks_ai.setup(_car, track, _obstacle_field, _opponent_spawner, _autopilot,
		get_world_3d(), Callable(self, "_shot_physics_frame"), Callable(self, "_sample_physics_ms"))
	# 环境物理验收模块接线（SPLIT-CHECKS-ENVPHYS-004）：车/赛道/世界环境/物理世界注入（模块不
	# get_node，§2.4）；physics_frame 经 Callable 递入（同 screenshot_mode / bench）；对手生成
	# 注入本文件持有的**实例**（状态在实例上，第二份会拿到空）。
	_checks_envphys.setup(_car, track,
		get_node_or_null("WorldEnvironment") as WorldEnvironment, get_world_3d(),
		_opponent_spawner, Callable(self, "_shot_physics_frame"))

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
	# ⚠ 这里**故意不发车**：发车时机只有一处 —— _process 里的
	# _opponent_spawner.maybe_start_opponents()（玩家速度达到阈值才发）。
	#
	# 原来这里有一句 `_opponent_spawner.arm_opponents()`，导致**关卡一加载 AI 就抢跑**，
	# 违反"玩家一动 AI 才动"的规则；更糟的是它在 _parse_check_args() 的 return
	# **之后**，所以 --check=aistart 根本走不到这一行 ——
	# **验收通过，游戏却是错的**。这是本项目最该记的一次教训：
	# 验收和真实游玩走了两条不同的代码路径。
	_screenshot_mode.parse_args()
	_setup_done = true


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
	print("[main] 关卡已加载：%s（%s）椭圆 %.0f×%.0f 路宽 %.0f 抓地力 ×%.2f 极速 %.0f"
		% [cfg.display_name, cfg.difficulty, cfg.radius_x, cfg.radius_z,
		   cfg.road_width, cfg.friction_multiplier, GameState.effective_speed()])




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
			_check_enclosure()
		"reset":
			await _check_reset()
		"oob":
			await _check_out_of_bounds()
		"minimap":
			await _check_minimap()
		"resetkey":
			await _check_reset_key()
		"escape":
			await _check_escape()
		"lap":
			await _check_lap()
		"stuck":
			await _checks_envphys.run_stuck()
		"wallslide":
			await _checks_envphys.run_wallslide()
		"stress":
			await _check_stress()
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
			await _checks_ai.run_obstacles()
		"avoid":
			await _checks_ai.run_avoid()
		"aidiag":
			await _checks_ai.run_ai_diag()
		"pause":
			await _check_pause()
		"flip":
			await _checks_envphys.run_flip()
		"layout":
			await _checks_layout.run()
		"reverse":
			await _check_reverse()
		_:
			print("[CHECK] 未知的检查项：%s" % _check)
	# 有些检查会**重载场景**（比如暂停验收要验"重新开始"）。
	# 这时旧场景不能退出进程 —— 否则刚重建的新场景还没跑它的检查就被 quit() 掉了
	# （实测：日志里能看到新赛道建好，紧接着就是"完成，退出"，阶段2 从来没跑过）。
	if _keep_alive_after_check:
		print("[CHECK] 场景已重载，交由新场景继续检查（本次不退出）")
		return
	_check_done()


func _check_done() -> void:
	print("[CHECK] 完成，退出")
	await get_tree().process_frame
	get_tree().quit()


## 复位验收：把车放到赛道外的 8 个方位，调用 reset_to_track()，
## 要求每次都落回赛道路面内（离中心线 < 路面半宽）。
func _check_reset() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var road_half := float(track.call("road_half_width"))
	var bearings: Array[Vector3] = [
		Vector3(120, 0.6, 120), Vector3(-120, 0.6, 120),
		Vector3(120, 0.6, -120), Vector3(-120, 0.6, -120),
		Vector3(360, 0.6, 0), Vector3(-360, 0.6, 0),
		Vector3(0, 0.6, 260), Vector3(0, 0.6, -260),
	]
	var fails := 0
	print("[自检] 复位验收：8 个赛道外方位，逐个瞬移后调用 reset_to_track()")
	for i in range(bearings.size()):
		var p: Vector3 = bearings[i]
		_car.global_position = p
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		_car.call("reset_to_track")
		var after: Vector3 = _car.global_position
		var near := track.call("nearest_on_centerline", after, -1.0) as Dictionary
		var dev := float(near.get("dist", 999.0))
		var ok := dev < road_half
		if not ok:
			fails += 1
		print("[自检]   方位%d 从 %s → %s  离中心线 %.2fm  %s"
			% [i + 1, p, after, dev, "✔" if ok else "✘ 不在路面上"])
		await get_tree().physics_frame
	print("[自检] 复位验收：%d/%d 成功%s" % [bearings.size() - fails, bearings.size(),
		" ✔" if fails == 0 else " ✘"])


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



func _check_lap() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
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
			await get_tree().physics_frame
			continue
		# 转向 + 全油门：走**共享**的 _autopilot.drive_track（与 aidiag 同一份，
		# 不许在这里再写一遍 —— 玩家实测的"倒着开"就是两份漂移出来的）
		_autopilot.drive_track(track, target_ahead)
		await get_tree().physics_frame
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
			print("[自检]   ⚠ 检测到瞬移（疑似复位）第 %d 次：%s → %s  离中心线 %.2fm"
				% [resets, last_pos, now_pos, float(near["dist"])])
		last_pos = now_pos
		# 计圈事件
		var last_lap := float(_car.get("lap_last"))
		var best_lap := float(_car.get("lap_best"))
		if last_lap > 0.0 and laps.size() < 3 and (laps.is_empty() or laps[laps.size() - 1] != "%.3f" % last_lap):
			laps.append("%.3f" % last_lap)
			lap_printed += 1
			print("[自检]   ✔ 第 %d 圈完成：%.3f 秒" % [lap_printed, last_lap])
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
			await get_tree().physics_frame
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
		elif flip_fixed_at > 2.0:
			printerr("[自检] 跑圈验收 ✘ 掉头纠正太慢：用了 %.1fs 才回到 60° 以内（判据 ≤2s）"
				% flip_fixed_at)
		else:
			print("[自检] 跑圈验收 ✔ 掉头纠正演练通过：%.1fs 内把车头掰回 60° 以内（最坏 %.0f°）"
				% [flip_fixed_at, flip_worst])

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
	if not heading_ok:
		printerr("[自检] 跑圈验收 ✘ 车头方向异常：最坏夹角 %.1f°、朝后帧占 %.2f%% —— 掉头纠正没生效"
			% [worst_heading, back_pct])
	elif stuck_events > 0:
		printerr("[自检] 跑圈验收 ✘ 出现 %d 次卡住事件 —— 卡墙自救没生效（见上方「卡住事件」行）"
			% stuck_events)
	else:
		print("[自检] 跑圈验收 ✔ 车头方向正常（未掉头）、无卡住事件")
	# 判据要分开，别把几件事混成一个"圈速异常"。
	# 踩过的坑：本检查在只跑满 1 圈后若触发**复位循环**也会跳出循环，此时
	# "上圈==最快"是必然的，但报出来的却是"圈速异常"，看起来像计时坏了，
	# 实际根因是车被反复复位。根因说错会把排查方向带偏。
	#
	# ⚠ 2026-09 修正：原来判"上圈 == 最快"就报异常 —— **那是错的**。
	#   最后一圈正好也是最快圈时，两者本来就相等（实测 3 圈：36.914 → 36.900，
	#   上圈=最快=36.900）。真正的不变式是 **最快 ≤ 上圈** 且圈数够；
	#   要抓"计时坏了"，判据应该是"圈数不足"与"圈速 ≤0"，不是数值相等。
	if resets > 0:
		printerr("[自检] 跑圈验收 ✘ 期间发生 %d 次疑似复位（见上方「检测到瞬移」行）" % resets)
	elif reset_loop:
		printerr("[自检] 跑圈验收 ✘ 中途触发复位循环（只跑了 %d 圈）：根因是车被反复复位，"
			% lap_printed + "不是计时问题 —— 见上方「检测到瞬移」行")
	elif lap_printed < 2:
		printerr("[自检] 跑圈验收 ✘ 只跑完 %d 圈（不足 2 圈，无法比较圈速）" % lap_printed)
	elif last_lap <= 0.0 or best_lap <= 0.0:
		printerr("[自检] 跑圈验收 ✘ 圈速非正（上圈=%.3f 最快=%.3f）：计时没在跑" % [last_lap, best_lap])
	elif best_lap > last_lap + 0.001:
		printerr("[自检] 跑圈验收 ✘ 圈速异常：最快 %.3f 竟然大于上圈 %.3f（最快圈没被更新）"
			% [best_lap, last_lap])
	else:
		print("[自检] 跑圈验收 ✔ 连续多圈计时正常、无意外重置")


## 兜底被自动停用（说明出现复位死循环）时返回 true
func _reset_loop_hit() -> bool:
	return not bool(_car.get("auto_reset_out_of_bounds"))


## 压测验收：本地确定性"鲁莽玩家"跑一段，统计卡死次数。
## 用例优先读落盘的确定性极端用例（`data/ai_test_cases.json`），读不到则走本地随机；不联网、不报错。
func _check_stress() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
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
	add_child(driver)
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
	else:
		printerr("[自检] 压测验收 ✘ 卡死 %d 次 / 用例兜底失败 %d 例" % [stuck, case_failed])
	driver.queue_free()


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


## 暂停菜单验收：ESC 能暂停、能选"重新开始"、重开后状态是干净的。
##
## 这条链路以前从没被验证过 —— 代码写得挺完整，但"没人按过 ESC"。
## 所以这里**喂真实按键事件**（Input.parse_input_event）而不是直接调 pause()，
## 走的就是玩家按 ESC 的那条路：ui_cancel → _unhandled_input → pause()。
##
## 分两阶段：点"重新开始"会 reload_current_scene，本脚本会在新场景里**再跑一次**
## （--check 参数还在命令行里）。所以用 GameState 的 meta 当跨场景标记
## （autoload 不随场景重载销毁），第二阶段只做"重开后状态是否干净"的确认。
func _check_pause() -> void:
	var menu := get_node_or_null("PauseMenu")
	# ---------- 第二阶段：刚刚点了"重新开始"，现在验证新场景是干净的 ----------
	if GameState.has_meta("pause_restart_pending"):
		GameState.remove_meta("pause_restart_pending")
		var ok2 := true
		print("[自检] 暂停验收·阶段2：重开后的新场景已就绪，检查初始状态")
		if get_tree().paused:
			printerr("[自检]   ✘ 重开后游戏仍处于暂停状态")
			ok2 = false
		else:
			print("[自检]   ✔ 重开后未处于暂停")
		var laps := int(_car.get("laps_done")) if _car != null else -1
		var lap_last := float(_car.get("lap_last")) if _car != null else -1.0
		var pos := _car.global_position if _car != null else Vector3.ZERO
		print("[自检]   新场景：圈数=%d 上圈=%.3f 位置=%s" % [laps, lap_last, pos])
		if laps != 0 or lap_last > 0.001:
			printerr("[自检]   ✘ 重开后计圈状态没清零（圈数=%d 上圈=%.3f）" % [laps, lap_last])
			ok2 = false
		else:
			print("[自检]   ✔ 计圈状态已清零（重新开始是「干净」的）")
		var m2 := get_node_or_null("PauseMenu")
		if m2 != null and bool(m2.get("visible")):
			printerr("[自检]   ✘ 重开后暂停菜单仍然可见")
			ok2 = false
		else:
			print("[自检]   ✔ 暂停菜单已隐藏")
		if ok2:
			print("[自检] 暂停验收 ✔ ESC 暂停 → 选「重新开始」→ 新场景状态干净")
		else:
			printerr("[自检] 暂停验收 ✘ 见上方 ✘ 行")
		return

	# ---------- 第一阶段：验证 ESC 暂停 + 菜单内容 ----------
	var ok := true
	if menu == null:
		printerr("[自检] 暂停验收 ✘ 找不到 PauseMenu 节点")
		return
	# ① ESC 是否真的映射到 ui_cancel（这是"按 ESC 有没有用"的前提）
	var esc_mapped := false
	for e in InputMap.action_get_events("ui_cancel"):
		if e is InputEventKey:
			var k: InputEventKey = e
			if k.physical_keycode == KEY_ESCAPE or k.keycode == KEY_ESCAPE:
				esc_mapped = true
	print("[自检] 暂停验收：ui_cancel 绑定 ESC = %s" % str(esc_mapped))
	if not esc_mapped:
		printerr("[自检]   ✘ ESC 没有映射到 ui_cancel，玩家按 ESC 不会有反应")
		ok = false
	# ② 初始状态
	print("[自检]   初始：paused=%s 菜单可见=%s" % [str(get_tree().paused), str(menu.visible)])
	if get_tree().paused or bool(menu.get("visible")):
		printerr("[自检]   ✘ 初始状态就不对（应该是未暂停且菜单隐藏）")
		ok = false
	# ③ 喂一个真实的 ESC 按键事件
	_menu_press_escape()
	for i in range(4):
		await get_tree().process_frame
	print("[自检]   按下 ESC 后：paused=%s 菜单可见=%s"
		% [str(get_tree().paused), str(menu.get("visible"))])
	if not get_tree().paused:
		printerr("[自检]   ✘ ESC 没有让游戏暂停")
		ok = false
	if not bool(menu.get("visible")):
		printerr("[自检]   ✘ ESC 没有让暂停菜单显示出来")
		ok = false
	# ④ 菜单里必须有四个选项，且文字要好认
	var labels: Array[String] = []
	for b in (menu.get("_buttons") as Array):
		if b is Button:
			labels.append((b as Button).text)
	print("[自检]   菜单选项：%s" % str(labels))
	for want in ["继续游戏", "重新开始", "返回选关", "退出游戏"]:
		if not (want in labels):
			printerr("[自检]   ✘ 缺少选项「%s」" % want)
			ok = false
	if not (("重新开始" in labels) and ("返回选关" in labels)):
		printerr("[自检]   ✘ 玩家没法重开或返回选关")
		ok = false
	# ⑤ 再按一次 ESC 应该恢复。
	# ⚠ 这一步必须**以第③步真的暂停成功为前提**：否则"恢复"会假通过
	# —— 从没暂停过，检查"现在没暂停"当然成立。第一版就是这么骗过自己的。
	if not get_tree().paused:
		printerr("[自检]   ✘ 跳过恢复检查：前面就没暂停成功，此时的「未暂停」不算数")
	else:
		_menu_press_escape()
		for i in range(4):
			await get_tree().process_frame
		print("[自检]   再按 ESC：paused=%s 菜单可见=%s"
			% [str(get_tree().paused), str(menu.get("visible"))])
		if get_tree().paused or bool(menu.get("visible")):
			printerr("[自检]   ✘ 再按 ESC 没有恢复游戏")
			ok = false
		else:
			print("[自检]   ✔ 再按 ESC 已恢复")
	if not ok:
		printerr("[自检] 暂停验收 ✘（阶段1：ESC 暂停）")
		return
	# ⑥ 点"重新开始"：走真实的按钮回调，然后跨场景验证（阶段2）
	print("[自检]   阶段1 通过，现在模拟点击「重新开始」…")
	GameState.set_meta("pause_restart_pending", true)
	_keep_alive_after_check = true     # 重载后由新场景收尾，本场景不要退出
	var pressed_restart := false
	for b in (menu.get("_buttons") as Array):
		if b is Button and (b as Button).text == "重新开始":
			(b as Button).emit_signal("pressed")
			pressed_restart = true
			break
	if not pressed_restart:
		printerr("[自检]   ✘ 找不到「重新开始」按钮，无法验证重开")
		GameState.remove_meta("pause_restart_pending")
		printerr("[自检] 暂停验收 ✘")


## 造一个真实的 ESC 按下事件喂给**视口**，走玩家按 ESC 的同一条链路。
##
## 为什么用 push_input 而不是 Input.parse_input_event：
##   parse_input_event 是"模拟操作系统级输入"，实测在验收环境里喂进去之后
##   PauseMenu._unhandled_input **收不到**（paused 一直是 false，看起来像
##   "ESC 暂停坏了"）。push_input 直接推进 Viewport 的输入管线，
##   也就是 _input/_unhandled_input 真正监听的那一条，才能测到真实行为。
func _menu_press_escape() -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_ESCAPE
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	get_viewport().push_input(ev)


# --check=avoid / obstacles / aistart 已迁至 scripts/checks/ai.gd 的
# run_avoid() / run_obstacles() / run_ai_start()（SPLIT-CHECKS-AI-003 纯迁移，行为零变化）。


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
# 判定逻辑在 `track_layout.wrong_way_state()`（纯函数），本检查只做两件事：
#   ① 6 条**纯函数**用例（下面那张表，逐条对应规格里的场景）
#   ② 真车 + 真物理 + 真 HUD 的端到端（人为把车头转 180°，以 ~60 km/h 前进）
#
# ⚠ 为什么纯函数用例要单独计数（`REVERSE_CASES`）而不是并进 --check=layout：
#   规格要求"打独立计数器：[自检] reverse 用例跑了 6/6 条，绿 X 条"，
#   并且要 has_method 探针防"函数不存在导致的假绿"（本项目踩过：`call()` 打到
#   不存在的方法会把调用点之后的语句整段跳过，连失败计数都不执行）。
const REVERSE_CASES := 6
var _reverse_cases := 0
var _reverse_failed := 0


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
		printerr("[自检]   ✘ reverse 用例「%s」无法判定：track_layout.gd 还没有 wrong_way_state" % label)
		return
	var got := bool(d.get("wrong_way", false))
	if got != want:
		_reverse_failed += 1
		printerr("[自检]   ✘ reverse 用例「%s」：期望 %s，实际 %s（was=%s 夹角=%.0f° 速度=%.1f km/h 倒车=%s）"
			% [label, str(want), str(got), str(was), angle_deg, speed_kmh, str(reversing)])
		return
	print("[自检]   ✔ reverse 用例「%s」= %s（夹角 %.0f°，%.0f km/h）"
		% [label, str(got), angle_deg, speed_kmh])


## `--check=reverse` 主流程。
func _check_reverse() -> void:
	_reverse_cases = 0
	_reverse_failed = 0
	var mod: GDScript = load("res://scripts/track_layout.gd")
	# 防假绿：模块必须真的可用、且真的有那个方法（见上面 const 的注释）
	if mod == null or not mod.has_method("wrong_way_state"):
		printerr("[自检] reverse 验收 ✘ track_layout.gd 不可用或缺少 wrong_way_state（实现未落地）")
		printerr("[自检]   reverse 用例跑了 0/%d 条，绿 0 条" % REVERSE_CASES)
		return

	# 门限取自**本关配置**（规格：不得硬编码、必须可配置且可被 --check=reverse 读取）
	var cfg: LevelConfig = GameState.current_level()
	var enter_deg := cfg.reverse_angle_enter_deg if cfg != null else 120.0
	var exit_deg := cfg.reverse_angle_exit_deg if cfg != null else 105.0
	var speed_kmh := cfg.reverse_speed_threshold_kmh if cfg != null else 15.0
	print("[自检] reverse 验收：门限取自本关配置「%s」—— 进入 %.0f°、退出 %.0f°、速度 %.0f km/h"
		% [cfg.display_name if cfg != null else "?", enter_deg, exit_deg, speed_kmh])
	print("[自检] reverse 用例组（%d 条，逐条对应规格表）" % REVERSE_CASES)

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
	print("[自检] reverse 用例跑了 %d/%d 条，绿 %d 条" % [_reverse_cases, REVERSE_CASES, green])

	# ---- 端到端：真车 + 真物理 + 真 HUD ----
	var e2e_ok := await _check_reverse_e2e(cfg)

	if _reverse_cases == REVERSE_CASES and _reverse_failed == 0 and e2e_ok:
		print("[自检] reverse 验收 ✔ %d/%d 条用例全绿 + 端到端提示正常" % [REVERSE_CASES, REVERSE_CASES])
	else:
		printerr("[自检] reverse 验收 ✘ 用例 %d/%d 条、绿 %d 条；端到端 %s"
			% [_reverse_cases, REVERSE_CASES, green, "通过" if e2e_ok else "失败"])


## 「方向反了」端到端：①车头转 180° 以 ~60 km/h 前进 → 提示亮
##                   ②按 S 倒车 → **不**提示（规格明确要求）
## 返回是否全部通过。
func _check_reverse_e2e(cfg: LevelConfig) -> bool:
	var track := get_node_or_null("Track")
	if track == null or _car == null:
		printerr("[自检]   ✘ 端到端跳过：找不到 Track 或玩家车")
		return false
	# ⚠ 提示条现在挂在 **HUD 下的独立 CanvasLayer**（WrongWayLayer）里，
	#   不再是 HUD 的直接子节点 —— 所以按名字递归找，不写死路径。
	#   写死路径的代价实测过：加了那层之后这里立刻变成"找不到 WrongWayPanel"。
	var panel := _find_wrong_way_panel()
	if panel == null:
		printerr("[自检]   ✘ 端到端失败：HUD 里找不到 WrongWayPanel（提示条没建出来）")
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
		await get_tree().physics_frame
	var lit := 0
	var frames := 0
	var spd_max := 0.0
	for i in range(int(hz * 3.0)):
		frames += 1
		Input.action_release("brake_reverse")
		Input.action_press("accelerate")
		await get_tree().physics_frame
		spd_max = maxf(spd_max, _car.linear_velocity.length() * 3.6)
		var w = _car.get("wrong_way")
		if w != null and bool(w):
			lit += 1
		if panel.visible != (w != null and bool(w)):
			printerr("[自检]   ✘ 端到端①：提示条与判定不一致（car=%s panel=%s）"
				% [str(w), str(panel.visible)])
			ok = false
			break
	Input.action_release("accelerate")
	print("[自检]   端到端①：车头 180° 前进 %.1fs（最高 %.0f km/h）：提示亮 %d/%d 帧，panel.visible=%s"
		% [float(frames) / hz, spd_max, lit, frames, str(panel.visible)])
	if lit < int(hz * 0.5):
		printerr("[自检]   ✘ 端到端①：提示几乎没亮（%d 帧）—— 判定没接上或阈值不对" % lit)
		ok = false

	# ---- ② 按 S 倒车：规格要求**不**提示（倒车救车是允许的）----
	var back_lit := 0
	var back_frames := 0
	for i in range(int(hz * 3.0)):
		back_frames += 1
		Input.action_release("accelerate")
		Input.action_press("brake_reverse")
		await get_tree().physics_frame
		var w2 = _car.get("wrong_way")
		if w2 != null and bool(w2):
			back_lit += 1
	Input.action_release("brake_reverse")
	print("[自检]   端到端②：按 S 倒车 %.1fs：提示亮 %d/%d 帧（要求 0）"
		% [float(back_frames) / hz, back_lit, back_frames])
	if back_lit > 0:
		printerr("[自检]   ✘ 端到端②：倒车被误报成「方向反了」（亮了 %d 帧）—— 违反「倒车不属于反方向」" % back_lit)
		ok = false
	return ok


## 按名字递归找「方向反了」提示条（它挂在 HUD 下的独立 CanvasLayer 里）。
## 为什么不写死路径 `HUD/WrongWayPanel`：那层是为"暂停时也能隐藏"加的，
## 加完立刻就让写死的路径失效了（实测报"找不到 WrongWayPanel"）。
## 这类"结构一变、路径就断"的引用，一律用递归查找。
func _find_wrong_way_panel() -> Control:
	var hud := get_node_or_null("HUD")
	if hud == null:
		return null
	return hud.find_child("WrongWayPanel", true, false) as Control


## 原点复现验收：从起点起步、满油门 + 打满方向**直冲原来那个缺口**，
## 全程记录离中心线的最大偏离，要求始终没穿出围墙通道。
## 这是用户报的"起点旁边能从旁边开出去"的回归测试。
func _check_escape() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var rail_half := float(track.call("rail_half_width"))
	# 摆回起点区（起终点门后 2.5m），关掉自动兜底，免得它把车拉走掩盖问题
	var gate := _cp(0)
	if gate != null:
		_car.global_position = gate.global_position - Vector3(0, 0, 2.5)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	_car.set("auto_recover", false)
	_car.set("auto_reset_out_of_bounds", false)
	print("[自检] 原点复现：从 %s 起步，满油门 + 打满方向冲 12 秒，看能否穿出围墙（护栏在 %.1fm）"
		% [_car.global_position, rail_half])
	var max_dev := 0.0
	var max_speed := 0.0
	var frames := 0
	# 左舵、右舵各试一轮（原来那个口子在缝的一侧）
	for direction: int in [1, -1]:
		_car.global_position = gate.global_position - Vector3(0, 0, 2.5) if gate != null else _car.global_position
		_car.linear_velocity = Vector3.ZERO
		for i in range(int(Engine.physics_ticks_per_second) * 12):
			Input.action_press("accelerate")
			Input.action_press("steer_left" if direction > 0 else "steer_right")
			await get_tree().physics_frame
			frames += 1
			var near := track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary
			max_dev = maxf(max_dev, float(near.get("dist", 0.0)))
			max_speed = maxf(max_speed, _car.linear_velocity.length())
			if bool(_car.call("is_reset_immune")):
				break
		Input.action_release("accelerate")
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		print("[自检]   %s满舵 12 秒结束：当前偏离 %.2fm"
			% ["左" if direction > 0 else "右",
			   float((track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary).get("dist", 0.0))])
	print("[自检] 原点复现：%d 帧内最大偏离中心线 %.2fm（护栏 %.1fm），最高速度 %.1f m/s  %s"
		% [frames, max_dev, rail_half, max_speed,
		   "✔ 没能穿出去" if max_dev < rail_half else "✘ 有穿墙风险"])


func _cp(order: int) -> Node3D:
	for node in get_tree().get_nodes_in_group("checkpoints"):
		if int(node.get("order_index")) == order:
			return node as Node3D
	return null


## R 键保护 + 复位无敌帧验收
func _check_reset_key() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	# 1) 车贴着中心线且未翻车：按 R 应该只扶正、**不传送**
	_car.global_position = Vector3(320.0, 0.55, 0.0)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	for i in range(5):
		await get_tree().physics_frame
	var before: Vector3 = _car.global_position
	_car.call("request_reset")
	await get_tree().physics_frame
	var after: Vector3 = _car.global_position
	var moved := before.distance_to(after)
	print("[自检] R 键保护：车在中心线旁按 R → 位移 %.2fm  %s"
		% [moved, "✔ 只扶正未传送" if moved < 0.6 else "✘ 不该传送"])

	# 2) 翻车时按 R 应该复位（这里直接用"离中心线很远"来触发复位分支）
	_car.global_position = Vector3(360.0, 0.6, 0.0)
	await get_tree().physics_frame
	_car.call("request_reset")
	await get_tree().physics_frame
	var near := track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary
	print("[自检] 界外按 R → 落点离中心线 %.2fm  %s"
		% [float(near.get("dist", 999.0)),
		   "✔ 已回赛道" if float(near.get("dist", 999.0)) < float(track.call("road_half_width")) else "✘"])

	# 3) 无敌帧：复位后应处于无敌，之后应自动恢复。
	# 注意物理帧在这台工程里是 120Hz（project.godot: physics_ticks_per_second=120），
	# 所以"等 N 个 physics_frame"其实是 N/120 秒 —— 我第一版按 60 算，等少了，误判成没恢复。
	var physics_hz := float(Engine.physics_ticks_per_second)
	# reset_immunity_time 是车上的导出属性（main.gd 里没有这个符号，别直接引用）
	var immune_time := float(_car.get("reset_immunity_time"))
	var immune_now := bool(_car.call("is_reset_immune"))
	var samples: Array[String] = []
	var waited := 0.0
	while waited < immune_time + 0.8:
		await get_tree().physics_frame
		waited += 1.0 / physics_hz
		if int(waited * 2.0) != int((waited - 1.0 / physics_hz) * 2.0):
			samples.append("%.1fs=%s" % [waited, str(_car.call("is_reset_immune"))])
	var immune_after := bool(_car.call("is_reset_immune"))
	print("[自检] 复位无敌帧：刚复位 immune=%s（应 true）；%.1fs 后 immune=%s（应 false）  %s"
		% [immune_now, waited, immune_after,
		   "✔" if (immune_now and not immune_after) else "✘"])
	print("[自检]   物理帧率=%dHz 采样：%s" % [Engine.physics_ticks_per_second, " ".join(samples)])


## 小地图验收：确认小地图世界搭起来了、相机对得上、车点在动。
func _check_minimap() -> void:
	var mm := get_node_or_null("Minimap")
	if mm == null:
		printerr("[CHECK] 找不到 Minimap 节点")
		return
	var board := mm.get_node_or_null("Board") as MeshInstance3D
	var ring := mm.get_node_or_null("RoadRing") as MeshInstance3D
	var marker := mm.get_node_or_null("CarMarker") as Node3D
	print("[自检] 小地图节点：Board=%s RoadRing=%s CarMarker=%s"
		% ["有" if board != null else "缺", "有" if ring != null else "缺",
		   "有" if marker != null else "缺"])
	if board != null:
		var bm := board.mesh as BoxMesh
		print("[自检]   底板 size=%s 位置=%s" % [bm.size, board.position])
	if ring != null:
		print("[自检]   路面环 顶点数=%d 位置=%s" % [ring.mesh.get_surface_count(), ring.position])
	for n in mm.get_children():
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			var aabb: AABB = mi.get_aabb()
			print("[自检]   %s 世界AABB pos=%s size=%s" % [mi.name, aabb.position, aabb.size])
	var vp := mm.get_node_or_null("SubViewport") as SubViewport
	if vp != null:
		print("[自检]   SubViewport size=%s update=%d world=%s children=%d"
			% [vp.size, vp.render_target_update_mode, vp.world_3d, vp.get_child_count()])
		var cam := vp.get_node_or_null("TopCam") as Camera3D
		if cam != null:
			print("[自检]   TopCam pos=%s size=%.1f cull_mask=%d" % [cam.global_position, cam.size, cam.cull_mask])
	# 车点是否跟着车动：等几帧看它有没有挪位
	if marker != null and _car != null:
		var before: Vector3 = marker.global_position
		var car_before: Vector3 = _car.global_position
		_car.global_position = car_before + Vector3(40.0, 0.0, 40.0)
		for i in range(3):
			await get_tree().process_frame
		var after: Vector3 = marker.global_position
		print("[自检]   车点跟随：车 %s → %s ；车点 %s → %s  %s"
			% [car_before, _car.global_position, before, after,
			   "✔" if after.distance_to(before) > 30.0 else "✘ 没动"])
		_car.global_position = car_before
	# ---- 障碍物标记：必须有、必须在相机的可视范围内、必须在 MAP_LAYER ----
	# 为什么用"硬校验"而不是看截图：小地图只有 200 来像素，红点小到肉眼难分辨，
	# "截图上好像有"不能算证据。这里直接量标记的世界坐标有没有落在相机视野内。
	await _check_minimap_obstacles(mm)


## 校验小地图上的障碍物标记（数量 / 图层 / 是否落在相机视野内）。
func _check_minimap_obstacles(mm: Node) -> void:
	var obs := get_node_or_null("Obstacles")
	if obs == null:
		print("[自检]   障碍物标记：本关没有障碍物节点，跳过 ⊘")
		return
	var positions: Array = obs.call("marker_positions")
	var markers: Array = mm.get("obstacle_markers")
	print("[自检]   障碍物标记：障碍 %d 个，小地图标记 %d 个"
		% [positions.size(), markers.size()])
	if positions.is_empty():
		print("[自检]   障碍物标记：本关障碍数为 0，跳过 ⊘")
		return
	if markers.size() != positions.size():
		printerr("[自检]   ✘ 标记数量与障碍数量不一致")
		return
	var vp := mm.get_node_or_null("SubViewport") as SubViewport
	var cam: Camera3D = null
	if vp != null:
		cam = vp.get_node_or_null("TopCam") as Camera3D
	var inside := 0
	var wrong_layer := 0
	# 相机是正交俯视：用 size（正交高度）和 viewport 宽高比算可视矩形
	var half_h := 0.0
	var half_w := 0.0
	if cam != null and vp != null:
		half_h = cam.size * 0.5
		half_w = half_h * float(vp.size.x) / maxf(float(vp.size.y), 1.0)
	var cpos := cam.global_position if cam != null else Vector3.ZERO
	for i in range(markers.size()):
		var holder := markers[i] as Node3D
		if holder == null or not is_instance_valid(holder):
			continue
		# 标记是个 Node3D 容器，取它第一个 MeshInstance3D 来判图层
		var sample: MeshInstance3D = null
		for c in holder.get_children():
			if c is MeshInstance3D:
				sample = c
				break
		if sample != null and sample.layers != (1 << 16):
			wrong_layer += 1
		var p := holder.global_position
		if cam == null or (absf(p.x - cpos.x) <= half_w and absf(p.z - cpos.z) <= half_h):
			inside += 1
	if wrong_layer == 0:
		print("[自检]   ✔ 全部标记都在小地图图层（1<<16），主视角不会看到")
	else:
		printerr("[自检]   ✘ %d 个标记的渲染层不对，会漏进主视角" % wrong_layer)
	if cam == null:
		print("[自检]   找不到 TopCam，无法校验视野 ⊘")
	elif inside == markers.size():
		print("[自检]   ✔ 全部 %d 个障碍标记都落在小地图相机视野内（半宽 %.0f 半高 %.0f）"
			% [inside, half_w, half_h])
	else:
		printerr("[自检]   ✘ 只有 %d/%d 个障碍标记在视野内，其余会看不见"
			% [inside, markers.size()])


## 出界兜底验收：把车放到界外静置，等自动拉回。
func _check_out_of_bounds() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var road_half := float(track.call("road_half_width"))
	var p := Vector3(360.0, 0.6, 0.0)
	_car.global_position = p
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	print("[自检] 出界兜底：把车放到 %s（界外）静置，等待自动拉回…" % p)
	var frames := 0
	var fired := false
	while frames < 60 * 6:
		frames += 1
		await get_tree().physics_frame
		var after: Vector3 = _car.global_position
		if after.distance_to(p) > 5.0:
			fired = true
			var near := track.call("nearest_on_centerline", after, -1.0) as Dictionary
			print("[自检] 出界兜底：第 %.1fs 被拉回 → %s  离中心线 %.2fm %s"
				% [float(frames) / 60.0, after, float(near.get("dist", 999.0)),
				   "✔" if float(near.get("dist", 999.0)) < road_half else "✘"])
			break
	if not fired:
		printerr("[自检] 出界兜底 ✘ 6 秒内没有被拉回")


func _check_enclosure() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var total := float(track.get("_road_length"))
	var rail_half := float(track.call("rail_half_width"))
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.new()
	params.collision_mask = 1          # 只打 terrain（空气墙/路面都在 layer 1）
	params.collide_with_areas = false
	var step := 0.1
	var d := 0.0
	var samples := 0
	var misses := 0
	var first_miss := -1.0
	var last_miss := -1.0
	var hit_dist_min := INF
	var hit_dist_max := 0.0
	# 把缺口按"连续区间 + 侧别"汇总，一眼看出是散点还是成段
	var runs: Array = []
	var cur_side := ""
	var cur_start := -1.0
	var cur_end := -1.0
	while d < total:
		var pos := Vector3(track.call("centerline_point", d))
		var fwd := Vector3(track.call("centerline_forward", d))
		var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
		for s: float in [-1.0, 1.0]:
			# 从**中心线**朝一侧打出去（不是从墙的位置起打：起点正好落在墙面上时
			# 射线会与墙面共面而打空，那是测量方法的假阳性，不是真的缺口）
			var origin: Vector3 = pos + Vector3.UP * 0.6
			params.from = origin
			params.to = origin + side * s * 60.0
			samples += 1
			var sname := "左" if s > 0.0 else "右"
			var hit := space.intersect_ray(params)
			if hit.is_empty():
				misses += 1
				if first_miss < 0.0:
					first_miss = d
				last_miss = d
				if cur_side == sname and d - cur_end <= step * 1.5:
					cur_end = d
				else:
					if cur_start >= 0.0:
						runs.append([cur_side, cur_start, cur_end])
					cur_side = sname
					cur_start = d
					cur_end = d
			else:
				var hd := origin.distance_to(hit["position"])
				hit_dist_min = minf(hit_dist_min, hd)
				hit_dist_max = maxf(hit_dist_max, hd)
		d += step
	if cur_start >= 0.0:
		runs.append([cur_side, cur_start, cur_end])
	print("[自检] 命中距离范围 %.2f ~ %.2f m（护栏中心线应在 %.2f m 附近）"
		% [hit_dist_min, hit_dist_max, rail_half])
	print("[自检] 缺口共 %d 段（按侧别/连续性合并）：" % runs.size())
	for r in runs:
		print("[自检]   %s侧 弧长 %.1f ~ %.1f m（长 %.1f m）" % [r[0], r[1], r[2], float(r[2]) - float(r[1]) + step])
	print("[自检] 围墙封闭：弧长 %.1fm 上每 %.1fm 两侧各一条射线，共 %d 条，缺口 %d 条"
		% [total, step, samples, misses])
	if misses == 0:
		print("[自检] 围墙封闭 ✔ 全周无缺口（含起终点缝）")
	else:
		printerr("[自检] 围墙封闭 ✘ 有 %d 条射线打不到墙，弧长 %.1f ~ %.1f m"
			% [misses, first_miss, last_miss])
	# 顺便报一下物理节点数，确认没有按段拆节点
	var body_count := 0
	for c in track.get_children():
		if c is StaticBody3D:
			body_count += 1
	print("[自检] 赛道下 StaticBody3D 物理节点数 = %d（应远小于路段数）" % body_count)


func _process(_delta: float) -> void:
	# 引擎声占位音源的流式缓冲每帧续填（已迁至 scripts/engine_audio.gd，SPLIT-ENV-002）
	_engine_audio.tick()

	# 玩家一起步，并排的对手就发动。
	# 必须放在验收模式的 return **之前**，否则验收里这条链路永远走不到。
	# aistart / aidiag 这两项检查就是要验**真实游玩的那条链路**，
	# 所以它们和正常游玩一样允许自动发车；其它检查自己控制发车时机（默认不自动发车）。
	if _check.is_empty() or _check == "aistart" or _check == "aidiag":
		_opponent_spawner.maybe_start_opponents(ai_start_speed_kmh)

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
