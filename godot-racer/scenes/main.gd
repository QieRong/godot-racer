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
			await _check_stuck()
		"wallslide":
			await _check_wallslide()
		"stress":
			await _check_stress()
		"openrouter":
			await _check_openrouter()
		"models":
			await _check_models()
		"opponents":
			await _check_opponents()
		"friction":
			await _check_friction()
		"steerbench":
			await _checks_bench.run_steerbench()
		"brakebench":
			await _checks_bench.run_brakebench()
		"phys":
			await _check_phys()
		"weather":
			await _check_weather()
		"aistart":
			await _check_ai_start()
		"obstacles":
			await _check_obstacles()
		"avoid":
			await _check_avoid()
		"aidiag":
			await _check_ai_diag()
		"pause":
			await _check_pause()
		"flip":
			await _check_flip()
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


## 卡墙验收：以 5°/10°/20° 角怼向墙，全油门跑 4 秒，要求车能继续前进（不卡死）。
## 这是用户报的"快回到起点卡墙"的回归测试。
func _check_wallslide() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var road_half := float(track.call("road_half_width"))
	var rail_half := float(track.call("rail_half_width"))
	_car.set("auto_recover", true)          # 允许楔入救援生效，但不允许出界兜底干扰
	_car.set("auto_reset_out_of_bounds", false)
	var fails := 0
	var cases := 0
	var worst_visual := 0.0
	var rail_thick := 0.35
	var rt = track.get("rail_visual_thickness")
	if rt != null:
		rail_thick = float(rt)
	print("[自检] 卡墙验收：3 个角度 × 内外两侧，全油门怼墙 4 秒，要求结束时速度 > 12 km/h")
	print("[自检]   同时量「车尾穿模」：要求车**视觉模型**的横向最远处 ≤ 护栏碰撞面 %.2fm + 墙厚 %.2fm"
		% [rail_half, rail_thick])
	for arc: float in [1630.0, 400.0]:
		for side_sign: float in [-1.0, 1.0]:
			for deg: float in [5.0, 10.0, 20.0]:
				cases += 1
				var c0 := Vector3(track.call("centerline_point", arc))
				var f0 := Vector3(track.call("centerline_forward", arc))
				var s0 := Vector3(f0.z, 0.0, -f0.x).normalized() * side_sign
				# 摆在离墙 1.5m 处，车头朝"沿赛道方向偏 deg 度指向墙"
				var start: Vector3 = c0 + s0 * (rail_half - 1.5) + Vector3.UP * 0.6
				_car.global_position = start
				_car.linear_velocity = Vector3.ZERO
				_car.angular_velocity = Vector3.ZERO
				var heading := (f0 + s0 * tan(deg_to_rad(deg))).normalized()
				_car.global_transform.basis = Basis.looking_at(heading, Vector3.UP)
				_car.set("_reset_cooldown", 0.0)
				for i in range(6):
					await get_tree().physics_frame
				var min_speed := INF
				var wedge_rescues := 0
				var case_visual := 0.0
				for i in range(int(Engine.physics_ticks_per_second) * 4):
					Input.action_press("accelerate")
					await get_tree().physics_frame
					var sp: float = _car.linear_velocity.length() * 3.6
					min_speed = minf(min_speed, sp)
					case_visual = maxf(case_visual, _visual_lateral_extent(track))
					# 楔入救援日志出现次数（从日志里数不方便，这里直接看位移是否被推过）
				Input.action_release("accelerate")
				worst_visual = maxf(worst_visual, case_visual)
				var end_speed: float = _car.linear_velocity.length() * 3.6
				var near := track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary
				var ok := end_speed > 12.0
				var poke := case_visual - rail_half
				if not ok:
					fails += 1
				print("[自检]   %s侧 %2.0f° 怼墙：结束速度 %5.1f km/h 最低 %5.1f 偏离 %.2fm 视觉最远 %.2fm（探出墙面 %+.2fm）  %s"
					% ["内" if side_sign < 0.0 else "外", deg, end_speed, min_speed,
					   float(near["dist"]), case_visual, poke,
					   "✔ 能继续开" if ok else "✘ 卡住了"])
	# 穿模判据：视觉探出量必须小于墙厚（探进墙里 = 被墙体挡住，看不见）
	if worst_visual > rail_half + rail_thick + 0.02:
		fails += 1
		printerr("[自检]   ✘ 车尾穿模：视觉最远 %.2fm > 墙面 %.2fm + 墙厚 %.2fm（会从墙背面露出来）"
			% [worst_visual, rail_half, rail_thick])
	else:
		print("[自检]   车尾穿模检查 ✔ 全程视觉最远 %.2fm，探出墙面 %.2fm < 墙厚 %.2fm（藏在墙体里）"
			% [worst_visual, worst_visual - rail_half, rail_thick])
	print("[自检] 卡墙验收：%d/%d 通过%s" % [cases - fails, cases, " ✔" if fails == 0 else " ✘ 有卡墙"])
	_car.set("auto_reset_out_of_bounds", true)


## 车**视觉模型**相对中心线的最大横向距离（用来验"车尾穿模"）。
##
## 为什么要单独量视觉而不是碰撞：碰撞盒是 1.6×3.4，视觉包围盒是 1.73×3.74，
## 车斜着贴墙时视觉角点会比碰撞角点多探出最多约 0.18m —— 如果护栏只是一张
## 零厚度的面，这 0.18m 会从墙的背面露出来，相机在墙外就正好看见"车尾扎进墙里"。
func _visual_lateral_extent(track: Node) -> float:
	if _car == null or track == null:
		return 0.0
	var near: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
	var c: Vector3 = near.get("pos", _car.global_position)
	var fwd: Vector3 = near.get("forward", Vector3.FORWARD)
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	if side.length() < 0.001:
		return 0.0
	side = side.normalized()
	var worst := 0.0
	var stack: Array = [_car.get_node_or_null("CarModel")]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n == null:
			continue
		if n is VisualInstance3D:
			var vi: VisualInstance3D = n
			var g: AABB = vi.global_transform * vi.get_aabb()
			for i in range(8):
				var lat := absf((g.get_endpoint(i) - c).dot(side))
				worst = maxf(worst, lat)
		for ch in n.get_children():
			stack.append(ch)
	return worst


## 卡墙诊断：用户报"跑完一圈快回到起点时会卡墙"。
## 这里不放任何修复，只**测量事实**：
##   ① 用射线在多个弧长处量出内/外墙的真实位置，看墙有没有洞或厚度异常；
##   ② 把车摆到"贴墙"的各种深度，朝墙里推 2 秒，看它能穿进墙多深、会不会卡住；
##   ③ 报告卡住时的完整几何关系（车中心/车外缘 vs 内墙）。
func _check_stuck() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var total := float(track.call("road_length"))
	var rail_half := float(track.call("rail_half_width"))
	var road_half := float(track.call("road_half_width"))
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.new()
	params.collision_mask = 1
	params.collide_with_areas = false

	# ---- ① 量墙：从中心线朝两侧打，报告命中距离（含墙的"内表面"位置）----
	print("[自检] ① 墙体实测（中心线为 0，正值=外侧/负值=内侧）")
	var worst_inner := 0.0
	var worst_outer := 0.0
	var d := 0.0
	while d < total:
		var pos := Vector3(track.call("centerline_point", d))
		var fwd := Vector3(track.call("centerline_forward", d))
		var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
		# 朝外侧打
		params.from = pos + Vector3.UP * 0.5
		params.to = params.from + side * 60.0
		var ho := space.intersect_ray(params)
		# 朝内侧打
		params.to = params.from - side * 60.0
		var hi := space.intersect_ray(params)
		if not ho.is_empty():
			worst_outer = maxf(worst_outer, absf((params.from.distance_to(ho["position"])) - rail_half))
		if not hi.is_empty():
			worst_inner = maxf(worst_inner, absf((params.from.distance_to(hi["position"])) - rail_half))
		d += 5.0
	print("[自检]   外侧墙位置偏差最大 %.3fm，内侧墙位置偏差最大 %.3fm（都应在 %.1fm 附近）"
		% [worst_outer, worst_inner, rail_half])

	# ---- ② 贴墙推：把车摆到离中心线 road_half-0.5 处并朝墙里推 ----
	print("[自检] ② 贴墙推进测试（起点区弧长 0 附近，朝内墙推 2 秒）")
	var arc0 := 1630.0
	var c0 := Vector3(track.call("centerline_point", arc0))
	var f0 := Vector3(track.call("centerline_forward", arc0))
	var s0 := Vector3(f0.z, 0.0, -f0.x).normalized()
	for depth: float in [0.0, 0.5, 1.0]:
		var start_pos: Vector3 = c0 - s0 * (road_half - 0.5 - depth) + Vector3.UP * 0.6
		_car.global_position = start_pos
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		# 朝内墙方向摆正车头
		_car.global_transform.basis = Basis.looking_at(-s0, Vector3.UP)
		_car.set("auto_recover", false)
		_car.set("auto_reset_out_of_bounds", false)
		for i in range(4):
			await get_tree().physics_frame
		for i in range(int(Engine.physics_ticks_per_second) * 2):
			Input.action_press("accelerate")
			await get_tree().physics_frame
			# 每 0.5 秒打一次状态：车到底被什么挡住了
			if i % 60 == 0:
				var pf: Vector3 = _car.global_position
				var nf := track.call("nearest_on_centerline", pf, -1.0) as Dictionary
				var upv := _car.global_transform.basis.y.normalized()
				var lean := rad_to_deg(acos(clampf(upv.dot(Vector3.UP), -1.0, 1.0)))
				print("[自检]     t=%.1fs pos=%s 速度=%.1fkm/h 偏离=%.2fm 侧倾=%.1f° 转向=%.2f"
					% [float(i) / Engine.physics_ticks_per_second, pf,
					   _car.linear_velocity.length() * 3.6, float(nf["dist"]), lean, _car.steering])
				# 从车中心朝"墙那一侧"和"朝下"各打一条射线，看它贴着/压着什么
				var sp := get_world_3d().direct_space_state
				var pr := PhysicsRayQueryParameters3D.new()
				pr.collision_mask = 1
				pr.exclude = [_car.get_rid()]
				pr.collide_with_areas = false
				# 朝下
				pr.from = pf
				pr.to = pf + Vector3.DOWN * 3.0
				var hd := sp.intersect_ray(pr)
				# 朝内墙方向
				var f2 := Vector3(track.call("centerline_forward", float(nf["arc"])))
				var s2 := Vector3(f2.z, 0.0, -f2.x).normalized()
				pr.from = pf + Vector3.UP * 0.5
				pr.to = pr.from - s2 * 12.0
				var hw := sp.intersect_ray(pr)
				print("[自检]       朝下命中=%s   朝内墙命中=%s"
					% ["无" if hd.is_empty() else "%.2fm @ %s" % [pf.distance_to(hd["position"]), hd["collider"]],
					   "无" if hw.is_empty() else "%.2fm @ %s" % [(pf + Vector3.UP * 0.5).distance_to(hw["position"]), hw["collider"]]])
		Input.action_release("accelerate")
		var p: Vector3 = _car.global_position
		var rel := p - Vector3(track.call("centerline_point", arc0))
		var lateral := rel.dot(s0)          # 负 = 内侧
		var near := track.call("nearest_on_centerline", p, -1.0) as Dictionary
		# 车外缘（朝墙那一侧）离中心线多远
		var outer_edge := absf(lateral) + 0.95
		print("[自检]   起始偏移 %.2fm → 推到 %s：车中心横向 %.2fm，车外缘 %.2fm；内墙在 %.2fm；速度 %.1fkm/h；偏离中心线 %.2fm"
			% [road_half - 0.5 - depth, p, lateral, outer_edge, -rail_half,
			   _car.linear_velocity.length() * 3.6, float(near["dist"])])
		if outer_edge > rail_half:
			print("[自检]   ⚠ 车外缘已越过内墙 %.2fm（说明车被挤进/穿过墙了）"
				% (outer_edge - rail_half))

	# ---- ③ 结论 ----
	print("[自检] ③ 判定：若②里出现'车外缘越过内墙'且速度接近 0，就是卡墙；"
		+ "若①的偏差很小，说明墙本身没洞，问题在碰撞求解（需要换更硬的墙或加脱困）")
	_car.set("auto_recover", true)
	_car.set("auto_reset_out_of_bounds", true)


# 自动驾驶族（11 个 DRIVE_* 常量 + drive_* 追线/恢复方法 + pose_facing）已迁至
# scripts/autopilot.gd（SPLIT-AUTOPILOT-002 纯迁移，行为零变化）。
# 本文件残留引用：常量走 Autopilot.<NAME>，方法走 _autopilot.drive_*，
# 位姿构造走 Autopilot.pose_facing(...) —— 均不复制第二份。

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


## 卡住取证：用**车体真实碰撞盒**朝 6 个方向各扫一次，报告"最先撞到谁"。
##
## 为什么必须有这一问（2026-10 实测教训）：L4 上反复出现"车静止、满油门、
## 四轮接地"的卡死，而 `obstacle_field.pick_clear_lane()` 认为那条车道**是通的**
## —— 也就是说挡住它的东西**不在 `obstacles[]` 里**。光看坐标区分不了
## 「石头 / 护栏 / 检查点 / 别的物理体 / 根本没有东西」，必须去问物理世界。
##
## 口径与 `ai_opponent._probe_collision_geometry()` 一致（同一套 `cast_motion` +
## 射线指名），只保留"被谁挡住"这一问。**只在卡住时跑一次**，不进正常路径。
func _probe_blocker() -> void:
	var body := _car.get_node_or_null("BodyCollision") as CollisionShape3D
	if body == null:
		print("[自检]       [卡住取证] 找不到 BodyCollision 节点，跳过")
		return
	var bshape := body.shape as BoxShape3D
	if bshape == null:
		print("[自检]       [卡住取证] BodyCollision 不是 BoxShape3D，跳过")
		return
	var bt := body.global_transform
	var space := _car.get_world_3d().direct_space_state
	var dirs := {"前(-Z)": -bt.basis.z, "后(+Z)": bt.basis.z, "右(+X)": bt.basis.x,
		"左(-X)": -bt.basis.x, "上(+Y)": Vector3.UP, "下(-Y)": Vector3.DOWN}
	print("[自检]       [卡住取证] 车体盒 size=%s 世界中心=%s" % [str(bshape.size), str(bt.origin)])
	for k in dirs.keys():
		var d: Vector3 = (dirs[k] as Vector3).normalized()
		var pq := PhysicsShapeQueryParameters3D.new()
		pq.shape = bshape
		pq.transform = bt
		pq.collision_mask = 1
		pq.collide_with_bodies = true
		pq.collide_with_areas = false
		pq.exclude = [_car.get_rid()]
		pq.motion = d * 8.0
		var fr: PackedFloat32Array = space.cast_motion(pq)
		var frac := 1.0 if fr.size() < 2 else minf(fr[0], fr[1])
		var dist := 8.0 * frac
		# 形状投射只给比例、不给对象，所以再用一条射线问"是谁"。
		# 终点必须**越过**接触面（dist + 0.15），落在面上会打空（AI 那边踩过这个坑）。
		var who := "—"
		var rq := PhysicsRayQueryParameters3D.new()
		rq.from = bt.origin
		rq.to = bt.origin + d * (dist + 0.15)
		rq.collision_mask = 1
		rq.exclude = [_car.get_rid()]
		var hit := space.intersect_ray(rq)
		if not hit.is_empty():
			var col = hit.get("collider")
			who = ("%s" % (col.name if col != null else "?"))
		print("[自检]       [卡住取证] %s：最近实体 %.2fm（%s）" % [k, dist, who])


# 上面 _probe_blocker 与 drive_* 方法原先夹在一起：drive_* 已迁出
# （scripts/autopilot.gd，SPLIT-AUTOPILOT-002 纯迁移）；_probe_blocker
# **刻意留在本文件** —— 它是 _check_lap 卡住取证的六向碰撞扫描，
# 不属于自动驾驶控制逻辑（当初就夹在两个 drive 函数之间，勿顺手扫走）。



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
				_probe_blocker()
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
## AI（OpenRouter）可用时会用 AI 生成的极端用例；**不可用时自动走本地随机，不报错**。
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
	# 注意：这里**不能**立刻 queue_free(driver) —— 后面可能还要用它的 OpenRouter 客户端
	# 问一次归因，而 queue_free 在本帧末尾就会真正释放它（实测会变成 "previously freed"）。
	var client: Node = driver.get("_openrouter")
	if client != null:
		driver.remove_child(client)
		add_child(client)   # 改挂到本场景，driver 释放后它依然活着
	print("[自检] 压测结果：帧数=%d 卡死事件=%d 最大偏离=%.2fm AI用例=%d"
		% [report.get("frames", 0), report.get("stuck_events", 0),
		   report.get("max_deviation", 0.0), report.get("ai_cases_used", 0)])
	if report.has("ai_note"):
		printerr("[自检] %s" % report["ai_note"])
	if int(report.get("ai_failures", 0)) > 0:
		printerr("[自检] AI 用例兜底失败 %d 例" % int(report["ai_failures"]))
	for p in report.get("stuck_positions", []):
		print("[自检]   卡死位置：%s" % p)

	# AI 归因（可选）：只在我们**真的失败了**且 AI 可用时才问，避免无谓消耗额度。
	var stuck := int(report.get("stuck_events", 0))
	var ai_failed := int(report.get("ai_failures", 0))
	if (stuck > 0 or ai_failed > 0) and client != null and bool(client.get("available")):
		var log_lines := PackedStringArray()
		for p in report.get("stuck_positions", []):
			log_lines.append("stuck_positions: %s" % p)
		if ai_failed > 0:
			log_lines.append("ai_cases_failed: %d" % ai_failed)
		log_lines.append("frames=%d max_deviation=%.2f" % [report.get("frames", 0), report.get("max_deviation", 0.0)])
		var advice := str(await client.call("diagnose", "\n".join(log_lines)))
		if not advice.is_empty():
			print("[自检] AI 归因：\n%s" % advice)
		else:
			printerr("[自检] AI 归因不可用：%s" % str(client.get("last_error")))

	if stuck == 0 and ai_failed == 0:
		print("[自检] 压测验收 ✔ 没有卡死事件，AI 极端用例兜底全部通过")
	else:
		printerr("[自检] 压测验收 ✘ 卡死 %d 次 / AI 用例兜底失败 %d 例" % [stuck, ai_failed])
	driver.queue_free()
	if client != null:
		client.queue_free()


## OpenRouter 连通性自检：读本地 cfg（或环境变量），走配置的代理发一条最小请求。
##
## 这是**探针**不是验收：所有配置/网络类失败只打印原因、不报错退出，
## 因为它要能反复跑来定位问题（代理没起 / key 无效 / 模型名错 / 限流）。
func _check_openrouter() -> void:
	var script: GDScript = load("res://scripts/openrouter_client.gd")
	var client: Node = script.new()
	add_child(client)
	var key_len := int(str(client.get("api_key")).length())
	var proxy := str(client.get("proxy_url"))
	var model := str(client.get("model"))
	print("[自检] OpenRouter 配置：key=%s（%d 字符） 代理=%s 模型=%s"
		% ["已读到" if key_len > 0 else "缺失", key_len,
		   proxy if not proxy.is_empty() else "（直连）", model])
	if key_len == 0:
		printerr("[自检] ✘ 没读到 API key。请创建 godot-racer/openrouter.local.cfg"
			+ "（可复制 openrouter.cfg.example），或设环境变量 OPENROUTER_API_KEY")
		client.queue_free()
		return
	print("[自检] 正在发测试请求（网络层超时 45 秒）…")
	var report: Dictionary = await client.call("test_connection")
	if bool(report.get("ok", false)):
		print("[自检] ✔ 连通性测试通过：%s" % report.get("detail", ""))
	else:
		printerr("[自检] ✘ 连通性测试失败：%s" % report.get("detail", ""))
		var raw := str(report.get("raw", ""))
		if not raw.is_empty():
			print("[自检]   服务端原始返回（前 400 字符）：%s" % raw.substr(0, 400))
	client.queue_free()


## 模型目录自检：**用接口的事实决定备用模型**，不靠记忆写死模型名。
##
## 为什么需要它：实测 `meta-llama/llama-3.1-8b-instruct:free` 已下架（HTTP 404），
## 一个消失的备用模型等于没有备用 —— 主模型一超时就直接降级。
## 这里列出当前真实存在的免费模型，并逐个探活，输出"可用的最快那个"。
func _check_models() -> void:
	var script: GDScript = load("res://scripts/openrouter_client.gd")
	var client: Node = script.new()
	add_child(client)
	if int(str(client.get("api_key")).length()) == 0:
		printerr("[自检] ✘ 没读到 API key，无法查询模型目录")
		client.queue_free()
		return
	print("[自检] 正在拉取模型目录…")
	var free_ids: Array = await client.call("list_free_models")
	if free_ids.is_empty():
		printerr("[自检] ✘ 没拿到免费模型列表：%s" % str(client.get("last_error")))
		client.queue_free()
		return
	print("[自检] 当前免费模型 %d 个：%s"
		% [free_ids.size(), ", ".join(PackedStringArray(free_ids.slice(0, 25)))])
	print("[自检] 正在探活前 5 个（跳过当前主模型 %s）…" % str(client.get("model")))
	var probed: Array = await client.call("probe_models", free_ids, 5)
	var best := ""
	var best_time := 1e9
	for p in probed:
		if bool(p.get("ok", false)) and float(p.get("elapsed", 1e9)) < best_time:
			best = str(p.get("model", ""))
			best_time = float(p.get("elapsed", 0.0))
	if best.is_empty():
		printerr("[自检] ✘ 探活的候选全部不可用（这通常意味着限流或出口有问题，而不是模型名错）")
	else:
		print("[自检] ✔ 建议的备用模型（最快可用）：%s（%.1fs）" % [best, best_time])
		print("[自检]   写进 openrouter.local.cfg：fallback_model=%s" % best)
	client.queue_free()


## AI 对手验收：要求每台对手都能**自己跑完至少 1 圈**，且不卡死、不出界。
##
## 判定"卡死"不用速度小 —— AI 自己的自救会掩盖问题，所以这里统计的是
## **AI 自身的自救次数**（rescue_count）。自救次数 = 0 才说明它真的开得干净。
## 同时实测物理帧耗时，因为 4 台车 × 4 轮是这阶段最大的性能风险。
##
## 用法：godot --path <工程> -- --check=opponents --level=4
func _check_opponents() -> void:
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
		return
	var ready_ok := 0
	for o in _opponents:
		if o.has_method("progress"):
			ready_ok += 1
	if ready_ok != _opponents.size():
		printerr("[自检] ✘ 只有 %d/%d 台对手初始化成功" % [ready_ok, _opponents.size()])
		return
	# 物理耗时基线：加对手之前已经测过（现在记在 opponent_spawner.gd 里），这里再测一次"对手怠速"作对照
	var hz := float(Engine.physics_ticks_per_second)
	var t_idle: Dictionary = await _sample_physics_ms(120, 180)
	var t_idle_avg := float(t_idle.get("avg", 0.0))
	var t_idle_max := float(t_idle.get("max", 0.0))
	# 对照测完再发车，否则②测到的其实是"已经在跑"的对手
	_opponent_spawner.arm_opponents()
	print("[自检] 对手验收：%d 台，目标各自跑完 ≥1 圈，限时 %.0f 秒" % [_opponents.size(), 180.0])
	var track := get_node_or_null("Track")
	var total_len := float(track.call("road_length")) if track != null else 0.0
	var max_frames := int(hz * 180.0)
	var t0 := Time.get_ticks_msec()
	var f := 0
	var min_laps := 0
	while f < max_frames:
		await get_tree().physics_frame
		f += 1
		min_laps = 9999
		for o in _opponents:
			min_laps = mini(min_laps, int(o.call("laps_done")))
		if min_laps >= 1:
			break
	var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
	var t_with: Dictionary = await _sample_physics_ms(120, 60)
	print("[自检] 对手用时 %.1f 秒（%d 帧），最小完成圈数 = %d" % [elapsed, f, min_laps])
	var all_ok := min_laps >= 1
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
		else:
			line += "  ✔"
		print(line)
	print("[自检] 对手验收通过判据：每台 ≥1 圈、零自救、未出界")
	print("[自检] 物理开销请单独用 --check=phys 测（本检查里的采样点冷热态不一致，不可比）")
	if all_ok:
		print("[自检] 对手验收 ✔ 全部对手都能独立跑完 ≥1 圈、零自救、未出界")
	else:
		printerr("[自检] 对手验收 ✘ 见上方 ✘ 行")


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


## 物理开销测量（**可做 A/B 的版本**）。
##
## 为什么单独做一个检查，而不是塞进 --check=opponents：
## 原来我在对手生成前后各测一次来算"增量"，但两次采样点一个在赛道刚建好时（冷态：
## 几千个静态体刚注册、着色器刚编译），一个在几百帧后（热态），**冷热态不可比**。
## 实测就出现了"0 台对手 3.61ms、4 台对手 3.04ms"这种自相矛盾的数字。
##
## 现在：充分预热（丢掉 300 帧）后连测 240 帧，同一套流程跑不同关卡，
## 得到的就是**同一热态下**的可比数字：
##   godot --path <工程> -- --check=phys --level=0   # 0 台对手（基线）
##   godot --path <工程> -- --check=phys --level=4   # 4 台对手
func _check_phys() -> void:
	var cfg: LevelConfig = GameState.current_level()
	# 让对手真的跑起来，测的才是"有对手在实际行驶"的开销
	_opponent_spawner.arm_opponents()
	var hz := float(Engine.physics_ticks_per_second)
	# 预热：丢掉 300 帧（赛道刚建好时静态体注册/着色器编译会让前若干帧异常重）
	for i in range(300):
		await get_tree().physics_frame
	# 主指标 = **实际达成的物理步频**。
	# 为什么不用 Performance.TIME_PHYSICS_PROCESS 下结论：同一套配置连测 5 次
	# 得到 3.04 / 3.31 / 3.81 / 5.53 / 6.36 ms，波动 2 倍，噪声盖过了对手的真实开销，
	# 甚至出现过"4 台对手比 0 台还便宜"的荒谬结论。步频是端到端事实，
	# 而且直接回答我们真正关心的问题：120Hz 稳不稳。
	print("[自检] 物理开销：关卡=%s 对手=%d 台 玩家=1 台（目标 %d Hz）"
		% [cfg.display_name if cfg != null else "?", _opponents.size(), int(hz)])
	var achieved_min := 1e9
	var achieved_max := 0.0
	var ms_max := 0.0
	var ms_sum := 0.0
	var ms_n := 0
	for round_i in range(3):
		var frames := 600
		var t0 := Time.get_ticks_usec()
		for i in range(frames):
			await get_tree().physics_frame
			var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			ms_sum += ms
			ms_n += 1
			ms_max = maxf(ms_max, ms)
		var dt := float(Time.get_ticks_usec() - t0) / 1_000_000.0
		var achieved := float(frames) / maxf(dt, 0.0001)
		achieved_min = minf(achieved_min, achieved)
		achieved_max = maxf(achieved_max, achieved)
		print("[自检]   第 %d 轮：%d 帧用了 %.2f 秒 → 实际 %.1f Hz" % [round_i + 1, frames, dt, achieved])
	var avg_ms := ms_sum / float(maxi(ms_n, 1))
	# 场景规模用**自己数出来**的节点数，不用 Performance 的 PHYSICS_3D_ACTIVE_OBJECTS /
	# COLLISION_PAIRS —— 这两个监视器在本项目实测恒为 0（拿不到有效值），
	# 打印一个恒为 0 的指标只会误导人。
	var vehicles := 1 + _opponents.size()
	var statics := 0
	var track := get_node_or_null("Track")
	if track != null:
		for c in track.get_children():
			if c is StaticBody3D:
				statics += 1
	print("[自检]   实际步频：最低 %.1f Hz / 最高 %.1f Hz（目标 %d Hz）"
		% [achieved_min, achieved_max, int(hz)])
	print("[自检]   物理耗时（仅供参考，逐帧读数噪声大）：均 %.2f ms / 峰 %.2f ms（预算 8.33 ms）"
		% [avg_ms, ms_max])
	print("[自检]   场景规模：车轮体 %d 台 = %d 个轮子，赛道静态体 %d 个"
		% [vehicles, vehicles * 4, statics])
	if achieved_min >= hz - 2.0:
		print("[自检]   物理开销 ✔ 稳定维持 %d Hz（未掉帧）" % int(hz))
	else:
		printerr("[自检]   ✘ 物理步频掉到 %.1f Hz，低于目标 %d Hz —— 物理确实吃不消"
			% [achieved_min, int(hz)])


## AI 行为诊断：**定量回答"AI 到底动不动"**。
##
## 为什么要单独做这个检查：
##   原来我用 --check=aistart 验"并排发车"，但那个检查在 check 模式下
##   **走的是和真实游玩不同的发车路径**，所以它一直报 ✔ 而游玩里 AI 会抢跑。
##   这里的做法是**完全不显式发车**，只按玩家的油门，让真实那条自动发车链路
##   自己触发 —— 于是它同时能暴露"抢跑"和"不动"两类问题。
##
## 采样内容：armed / 速度 / 离中心线 / 横向与纵向离玩家 / 自救次数。
## 判据：① 玩家没动时 armed 必须还是 false（否则抢跑）
##       ② 发车后不允许出现连续 >1.5s 的速度 <5km/h（否则就是"不动"）
##       ③ 自救次数为 0（否则说明它在靠兜底硬撑）
func _check_ai_diag() -> void:
	if _opponents.is_empty():
		var c0: LevelConfig = GameState.current_level()
		print("[自检] AI 诊断：本关「%s」没有对手，跳过 ⊘"
			% [c0.display_name if c0 != null else "?"])
		return
	var ai: Node = _opponents[0]
	var track := get_node_or_null("Track")
	var hz := float(Engine.physics_ticks_per_second)
	var ok := true
	# 诊断要报"物理上限"，所以要么用 racing_line.gd 的同一份公式，要么就**别报** ——
	# 在这里另写一遍 sqrt(a_lat·R) 就是本项目最忌讳的"两套逻辑漂移"（验收一套、游戏一套）。
	# 加载失败时下面的列照常打印，只是物理上限显示"?"，不会让整个诊断挂掉。
	var racing: GDScript = load("res://scripts/racing_line.gd")
	var cfg: LevelConfig = GameState.current_level()

	var armed0 := bool(ai.get("armed"))
	print("[自检] AI 诊断开始（走真实游玩路径，不显式发车）")
	print("[自检]   玩家未动时：armed=%s  期望 false（true 说明抢跑）" % str(armed0))
	if armed0:
		printerr("[自检]   ✘ 抢跑：玩家还没动，AI 已经发车了")
		ok = false

	# 玩家起步（真实链路：玩家速度 ≥ ai_start_speed_kmh 时才应该发车）
	#
	# ⚠ 这里也必须过 `_drive_recover`。玩家实测的"掉头后倒着开"**就是在这条路径上**
	#   （aidiag 起步时撞上并排的静止 AI → 点积 -1.00、后轮 force=-4000、倒滑 7 秒）。
	#   原来这条路径直接 `Input.action_press("accelerate")`，所以带病跑了很久。
	var ai_track := get_node_or_null("Track")
	var ai_pos: Vector3 = _car.global_position
	var ai_stuck := 0.0
	var ai_recover := 0.0
	var ai_recover_events := 0
	Input.action_press("accelerate")
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
	var tgt_frames := 0           # 参与统计的总帧数（发车后 2s 起）
	var below80 := 0              # 最终目标 < 80 km/h 的帧数（哨兵的鲁棒性度量，见下）
	while t < 22.0:
		await get_tree().physics_frame
		t += 1.0 / hz
		# 恢复优先：它接管时必须跳过下面的油门（否则两边打架）
		var ai_rec: Dictionary = _autopilot.drive_recover(ai_track, ai_pos, ai_stuck, ai_recover, hz)
		ai_pos = ai_rec["last_pos"]
		ai_stuck = float(ai_rec["stuck_sec"])
		ai_recover = float(ai_rec["recover_sec"])
		if bool(ai_rec["handled"]):
			ai_recover_events += 1
			continue
		Input.action_press("accelerate")
		var armed := bool(ai.get("armed"))
		var kmh := float(ai.call("speed_kmh"))
		if armed and arm_time < 0.0:
			arm_time = t
			print("[自检]   AI 于 %.2fs 发车（此时玩家 %.1f km/h）"
				% [t, _car.linear_velocity.length() * 3.6])
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
				ok = false
		# ---- 主记账：**逐物理帧**累加 ----
		#
		# ⚠ 为什么不能用 2.5s 的报告帧当采样点（实测逼出来的）：第一版把统计写在
		#   报告块里，结果**改前**那次"最大目标"读到了 **117.8** —— 报告帧恰好落在
		#   少数几个没被噪声饱和的时刻上，哨兵判据（≥80）就这么绿了。
		#   用报告帧当采样点等于把结论押在"采样落点"上；逐帧累加才与落点无关。
		if armed and t >= maxf(arm_time, 0.0) + 2.0:
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
			# 逐点的"不得超物理上限"（只在物理上限有限时判定；
			# 直道返回 INF = "此处不限制"，不是"上限极大"）
			if is_finite(phys):
				pairs += 1
				if final_tgt - phys > worst_gap:
					worst_gap = final_tgt - phys
					worst_gap_t = t
				# 占比只统计"物理上限有限"的点：直道上分母是 INF，
				# 硬把它算进来会让占比被直道刷高，看起来达标而弯道其实全废。
				if phys > 1.0:
					ratio_samples += 1
					if final_tgt >= phys * AI_TARGET_NEAR_PHYS_FRAC:
						near_phys += 1
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
	Input.action_release("accelerate")

	# ---- 玩家在 aidiag 里有没有被撞掉头：玩家实测「方向相反」的直接量化 ----
	# 为什么必须在这里也报：玩家看到的"方向相反"就是这一步 —— aidiag 让玩家按真实
	# 游玩链路起步，而旁边并排停着一台**静止的** AI，撞上就会被拧掉头
	# （实测日志：点积 -1.00、后轮 force=-4000、以 18~23 km/h 倒滑 7 秒）。
	# 原来这项检查只报 AI 的速度，所以"玩家车倒着开"在验收里完全不可见。
	var ai_near: Dictionary = ai_track.call("nearest_on_centerline", _car.global_position, -1.0)
	var ai_fwd_t: Vector3 = ai_near.get("forward", Vector3.FORWARD)
	ai_fwd_t.y = 0.0
	var ai_nose: Vector3 = -_car.global_transform.basis.z
	ai_nose.y = 0.0
	var ai_head := 0.0
	if ai_fwd_t.length() > 0.001 and ai_nose.length() > 0.001:
		ai_head = rad_to_deg(acos(clampf(ai_nose.normalized().dot(ai_fwd_t.normalized()), -1.0, 1.0)))
	print("[自检]   玩家车头方向：与赛道夹角 %.1f°（判据 <%.0f°）、掉头恢复动作 %d 帧"
		% [ai_head, Autopilot.DRIVE_BACKWARDS_DEG, ai_recover_events])
	if ai_head >= Autopilot.DRIVE_BACKWARDS_DEG:
		printerr("[自检]   ✘ 22 秒结束时玩家车与赛道夹角仍 %.1f° —— 掉头纠正没把它拉回来" % ai_head)
		ok = false
	elif ai_recover_events > int(hz * AI_RECOVER_WARN_SEC):
		printerr("[自检]   ✘ 掉头恢复动作持续 %d 帧（>%.1fs）—— 恢复在打转，不是一次修好"
			% [ai_recover_events, AI_RECOVER_WARN_SEC])
		ok = false
	else:
		print("[自检]   ✔ 没有长时间掉头（起步碰撞后已被拉回）")

	var resc := int(ai.call("rescue_count")) if ai.has_method("rescue_count") else -1
	print("[自检] AI 诊断结果：")
	print("[自检]   抢跑检查：玩家未动时 armed=%s" % str(armed0))
	if arm_time < 0.0:
		printerr("[自检]   ✘ 22 秒内 AI 从未发车 —— 这就是「不动」")
		ok = false
	else:
		print("[自检]   发车时刻：%.2fs" % arm_time)
		print("[自检]   发车后速度：最低 %.1f / 最高 %.1f km/h（采样 %d 帧）"
			% [min_kmh, max_kmh, samples])
		print("[自检]   最长低速段：%.2fs（<5km/h，起始于 t=%.1fs）"
			% [float(worst_low) / hz, worst_from])
		if samples < int(hz * 5.0):
			printerr("[自检]   ✘ 有效采样太少（%d 帧），诊断不可信" % samples)
			ok = false
		elif float(worst_low) / hz > 1.5:
			printerr("[自检]   ✘ 出现连续 %.2fs 的「不动」（<5km/h）"
				% [float(worst_low) / hz])
			ok = false
		else:
			print("[自检]   ✔ 没有超过 1.5s 的停顿")
	print("[自检]   自救次数：%d（>0 说明它在靠兜底硬撑）" % resc)
	if resc > 0:
		ok = false
	if ok:
		print("[自检] AI 诊断 ✔ 不抢跑、不发车后停顿、不依赖自救")
	else:
		printerr("[自检] AI 诊断 ✘ 见上方 ✘ 行（把这段日志连同速度曲线一起看）")

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
	print("[自检] AI 目标速度 vs 物理上限（任务 15 判据，逐 2.5s 采样）：")
	if live_bend_arc >= 0.0:
		print("[自检]   退化向量：arc=%.1fm 第一段 |a|=%.2fm → 旧口径 %.1f° / 新口径 %.1f°"
			% [live_bend_arc, live_bend_a, live_bend_before, live_bend_after])
		if live_bend_a > AI_BEND_GUARD_SEG:
			printerr("[自检]   ✘ 第一段参考向量 %.2fm 仍 > 守卫值 %.1fm —— 退化向量守卫没接上"
				% [live_bend_a, AI_BEND_GUARD_SEG])
			ok = false
		else:
			print("[自检]   ✔ 第一段参考向量 %.2fm ≤ 守卫值 %.1fm：那段退化线段已被排除，不再参与求夹角"
				% [live_bend_a, AI_BEND_GUARD_SEG])
	else:
		print("[自检]   ⚠ 本次没取到退化向量实测样本（AI 一直没进直道？）—— 该条判据本次不生效")

	var pinned_pct := 100.0 * float(below80) / maxf(float(tgt_frames), 1.0)
	print("[自检]   发车后最终目标：最大 %.1f km/h（出现在 t=%.1fs，当时物理上限 %.1f）；< %.0f km/h 的帧占 %d/%d = %.1f%%"
		% [tgt_max, tgt_max_t, phys_at_max, AI_TARGET_PINNED_KMH, below80, tgt_frames, pinned_pct])
	# ① 快速哨兵：改前实测最大 118.0（阈值 110）→ 红；改后直道 130+ → 绿。
	# ⚠ 写法上刻意**不**说"改前被钉在 43.2"—— 那句话只对多数帧成立，
	#   最大值那几帧改前也能到 118（噪声折角偶尔自己就小了）。见 AI_TARGET_MIN_KMH 的注释。
	if tgt_max < AI_TARGET_MIN_KMH:
		printerr("[自检]   ✘ 最终目标最大只到 %.1f km/h（< %.0f）—— 「AI 速度接近最高限速」没有达成"
			% [tgt_max, AI_TARGET_MIN_KMH])
		ok = false
	else:
		print("[自检]   ✔ 最终目标最大 %.1f ≥ %.0f km/h（改前 L1 实测最大只有 %.1f）"
			% [tgt_max, AI_TARGET_MIN_KMH, AI_TARGET_RED_MAX_KMH])
	# ② 被钉住的帧占比：改前实测 71.2% 的帧 < 80 km/h → 红；改后应接近 0。
	# 这一条才是"改前必红"的稳健判据（① 靠最大值，改前能侥幸过）。
	if tgt_frames > 0 and pinned_pct > AI_TARGET_PINNED_PCT:
		printerr("[自检]   ✘ 被钉住的帧占 %.1f%%（> %.0f%%）—— 最终目标长期低于 %.0f km/h，策略下限仍在压着 AI"
			% [pinned_pct, AI_TARGET_PINNED_PCT, AI_TARGET_PINNED_KMH])
		ok = false
	elif tgt_frames > 0:
		print("[自检]   ✔ 被钉住的帧只占 %.1f%% ≤ %.0f%%（改前实测 71.2%%）"
			% [pinned_pct, AI_TARGET_PINNED_PCT])
	# ② 天花板：任何一点都不得超物理上限（含 a_lat 缩放是否接线：a_lat 取自 AI 自己的字段）
	if pairs > 0:
		if worst_gap > 0.05:
			printerr("[自检]   ✘ 有采样点超物理上限：最多超出 %.1f km/h（t=%.1fs）—— min 接反了？"
				% [worst_gap, worst_gap_t])
			ok = false
		else:
			print("[自检]   ✔ %d 个采样点全部 ≤ 物理上限（最大超出 %.2f km/h）" % [pairs, worst_gap])
	else:
		printerr("[自检]   ✘ 本次没有「物理上限有限」的采样点（全程直道？）—— 天花板判据本次不生效")
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
			ok = false
		else:
			print("[自检]   ✔ 贴着限制跑的帧占 %.1f%% ≥ %.0f%%（改前实测两条都是 0%%）"
				% [best_pct, AI_TARGET_NEAR_CAP_PCT])
	# 辅助读数（**不计入通过/失败**）：离**物理上限**有多近 —— 回答"AI 有没有被地面限制住"。
	# 在 L1 这种抓地力充足、策略仍然保守的关卡上它是低值，那是正常（物理上限是天花板，不是目标）。
	if ratio_samples > 0:
		print("[自检]   （辅助读数）最终目标 ≥ 物理上限 × %.0f%% 的帧：%d/%d = %.1f%%"
			% [AI_TARGET_NEAR_PHYS_FRAC * 100.0, near_phys, ratio_samples,
			   100.0 * float(near_phys) / float(ratio_samples)])
	if ok:
		print("[自检] AI 目标速度判定 ✔ 目标已达最高限速量级、且从未超过物理上限")
	else:
		printerr("[自检] AI 目标速度判定 ✘ 见上方 ✘ 行（这一组就是任务 15 的需求指标）")


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


## AI 避让玩家验收：**把玩家当成路障摆在 AI 的车道上，AI 必须绕过去且不撞上**。
##
## 为什么要这么测：避让逻辑最容易做成"看起来在躲"但实际还是蹭上了。
## 所以判据必须是硬的：
##   ① AI 与玩家之间**始终**保持 ≥ 车身净距（记录全程最小中心距）；
##   ② AI 的横向位置确实发生了偏移（真的绕了，而不是刚好错开）；
##   ③ AI 最终超过了玩家的位置（绕过去继续跑，而不是停下僵住）。
func _check_avoid() -> void:
	if _opponents.is_empty():
		print("[自检] 本关没有对手，避让验收 ⊘ 跳过")
		return
	if _car == null:
		printerr("[自检] 没有玩家车，避让验收无法进行")
		return
	var ai: Node = _opponents[0]
	var track := get_node_or_null("Track")
	var hz := float(Engine.physics_ticks_per_second)
	# 先把对手发车、跑起来
	_opponent_spawner.arm_opponents()
	var ai_lane := float(ai.get("lane_offset"))
	print("[自检] 避让验收：把玩家当成路障摆在 AI 车道（横向 %+.2fm）前方，看 AI 会不会绕开" % ai_lane)
	# 让 AI 先跑起来并稳定在它的车道上
	for i in range(int(hz * 2.0)):
		await get_tree().physics_frame
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
		await get_tree().physics_frame
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
func _check_obstacles() -> void:
	var track := get_node_or_null("Track")
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
	var space := get_world_3d().direct_space_state
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
	var holder := get_node_or_null("Obstacles")
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


## 并排发车验收：**玩家不动，对手必须一动不动；玩家一动，对手才一起动**。
##
## 为什么单独验：这条是"并排起跑"的核心行为，但它很容易做错成
## "关卡一加载对手就冲出去了"（原来 arm_opponents 就是在加载时发的车），
## 这种错在 --check=opponents 里看不出来 —— 那个检查自己会显式发车。
func _check_ai_start() -> void:
	if _opponents.is_empty():
		print("[自检] 本关没有对手，并排发车验收 ⊘ 跳过")
		return
	var hz := float(Engine.physics_ticks_per_second)
	var ok := true
	# ① 玩家静止时，对手必须原地不动
	print("[自检] 并排发车验收：先让玩家静止 %.1f 秒，看对手是否原地等待" % 1.5)
	for i in range(int(hz * 1.5)):
		await get_tree().physics_frame
	var ai0: Node = _opponents[0]
	var ai_speed_idle := float(ai0.call("speed_kmh"))
	var player_speed := _car.linear_velocity.length() * 3.6
	var armed_now := bool(ai0.get("armed"))
	print("[自检]   玩家 %.2f km/h，对手 %.2f km/h，armed=%s"
		% [player_speed, ai_speed_idle, str(armed_now)])
	if ai_speed_idle > 1.0 or armed_now:
		printerr("[自检]   ✘ 玩家还没动，对手就已经发动了")
		ok = false
	else:
		print("[自检]   ✔ 对手原地等待，没有抢跑")
	# ② 检查并排：横向偏移应等于设计值，纵向应齐头
	var gap := _car.global_position.distance_to(ai0.global_position)
	var rail_half := float(get_node_or_null("Track").call("rail_half_width"))
	print("[自检]   两车中心距 %.2f m（设计值 = 并排横向 %.2f m）"
		% [gap, float(ai0.get("lane_offset"))])
	# ③ 玩家给油起步，对手应当跟着动
	print("[自检]   现在玩家全油门起步…")
	Input.action_press("accelerate")
	var started_frame := -1
	var f := 0
	while f < int(hz * 8.0):
		await get_tree().physics_frame
		f += 1
		if _ai_started and started_frame < 0:
			started_frame = f
		if started_frame >= 0 and float(ai0.call("speed_kmh")) > 15.0:
			break
	Input.action_release("accelerate")
	var final_ai := float(ai0.call("speed_kmh"))
	var final_player := _car.linear_velocity.length() * 3.6
	if started_frame < 0:
		printerr("[自检]   ✘ 玩家已起步，但对手始终没有发动")
		ok = false
	else:
		print("[自检]   ✔ 玩家起步后第 %d 帧（%.2f 秒）对手发动，当前 玩家 %.0f / 对手 %.0f km/h"
			% [started_frame, float(started_frame) / hz, final_player, final_ai])
	if final_ai < 10.0:
		printerr("[自检]   ✘ 对手发动后速度只有 %.1f km/h，看起来没真的跑起来" % final_ai)
		ok = false
	if rail_half <= 0.0:
		printerr("[自检]   ✘ 拿不到护栏半宽，并排距离无法校验")
		ok = false
	if ok:
		print("[自检] 并排发车验收 ✔ 对手原地等待 → 玩家起步 → 对手同步发动")
	else:
		printerr("[自检] 并排发车验收 ✘ 见上方 ✘ 行")


## 天气粒子的最低对比度（相对亮度差）。低于这个值肉眼就基本看不见。
## 参考：纯白(1.0) 与 中灰(0.45) 的差约 0.55；原来的"白雪花 vs 惨白天空"只有约 0.07。
const MIN_WEATHER_CONTRAST := 0.25


## 感知亮度（Rec.709 权重）。用来把"颜色差多少"变成一个数。
func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


## 天气验收：粒子**该有的时候有、该没有的时候没有**，且**不拖垮帧率**。
##
## 为什么要单独验收：天气很容易"看起来做了但实际没生效"（节点建了但 emitting=false、
## 或者晴天也挂着粒子）。所以这里既查存在性，也查帧率影响。
func _check_weather() -> void:
	var cfg: LevelConfig = GameState.current_level()
	var want := cfg.weather_type != "clear"
	var node := _car.get_node_or_null("WeatherParticles") if _car != null else null
	print("[自检] 天气验收：本关天气=%s（%s），期望粒子=%s"
		% [cfg.weather_type, cfg.weather_label(), "有" if want else "无"])
	var ok := true
	if want and node == null:
		printerr("[自检]   ✘ 期望有天气粒子，但没找到 WeatherParticles 节点")
		ok = false
	elif not want and node != null:
		printerr("[自检]   ✘ 晴天不应有天气粒子，却找到了节点")
		ok = false
	elif want:
		var p := node as GPUParticles3D
		var pm := p.process_material as ParticleProcessMaterial
		print("[自检]   粒子数 %d，寿命 %.1fs，发射盒 %s，emitting=%s，local_coords=%s"
			% [p.amount, p.lifetime, str(pm.emission_box_extents), str(p.emitting), str(p.local_coords)])
		if not p.emitting:
			printerr("[自检]   ✘ emitting = false，粒子不会出现")
			ok = false
		if p.amount <= 0:
			printerr("[自检]   ✘ amount = 0")
			ok = false
		# 必须查 draw_pass_1：光看 emitting/amount 会漏掉"配好了但根本不渲染"。
		# 这个检查是补上的 —— 第一版只查了前两项，结果 draw_pass_1 是空的
		# （我把网格挂成了子 MeshInstance3D），日志一切正常但画面一个粒子都没有。
		if p.draw_pass_1 == null:
			printerr("[自检]   ✘ draw_pass_1 为空：粒子已配置但**不会被画出来**")
			ok = false
		else:
			print("[自检]   draw_pass_1 = %s（粒子外观正常）" % p.draw_pass_1.get_class())
		if p.process_material == null:
			printerr("[自检]   ✘ process_material 为空，粒子不会运动")
			ok = false
		# 对比度：把"看不看得清"变成一个可校验的数。
		# 雪花/雨丝要打在天空上，所以拿**粒子颜色**和**环境背景色**的相对亮度差来判。
		# 为什么必须定量：雪天第一版是白雪花打惨白天空，粒子和节点全都正常、
		# 日志一切正常，就是肉眼看不见 —— 这种问题只有量化才守得住。
		var flake := pm.color
		var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
		if we != null and we.environment != null:
			var sky := we.environment.background_color
			var lf := _luminance(flake)
			var ls := _luminance(sky)
			var contrast := absf(lf - ls)
			print("[自检]   对比度：粒子亮度 %.2f vs 天空亮度 %.2f → 差 %.2f（要求 ≥ %.2f）"
				% [lf, ls, contrast, MIN_WEATHER_CONTRAST])
			if contrast < MIN_WEATHER_CONTRAST:
				printerr("[自检]   ✘ 对比度不足，粒子在画面上会看不清（粒子和背景太接近）")
				ok = false
			else:
				print("[自检]   ✔ 对比度足够，粒子在天空上看得见")
	else:
		print("[自检]   晴天：无粒子节点，符合预期")
	# 帧率影响：天气粒子是纯 GPU 的，不应显著影响物理步频
	var hz := float(Engine.physics_ticks_per_second)
	for i in range(120):
		await get_tree().physics_frame
	var t0 := Time.get_ticks_usec()
	for i in range(600):
		await get_tree().physics_frame
	var dt := float(Time.get_ticks_usec() - t0) / 1_000_000.0
	var achieved := 600.0 / maxf(dt, 0.0001)
	print("[自检]   物理步频在天气粒子下：%.1f Hz（目标 %d Hz）" % [achieved, int(hz)])
	if achieved < hz - 2.0:
		printerr("[自检]   ✘ 步频掉到 %.1f Hz" % achieved)
		ok = false
	if ok:
		print("[自检] 天气验收 ✔ 粒子和环境配置符合本关天气，且未拖垮帧率")
	else:
		printerr("[自检] 天气验收 ✘ 见上方 ✘ 行")


## 天气抓地力验收：**证明倍率真的进了物理**，而不只是换了个环境颜色。
##
## 做法：同一初始条件下（加速到 60km/h、直线、满舵一段）分别用 ×1.0 和低倍率跑，
## 比较**实际达成的侧向加速度** v·ω 与**侧滑角**（速度方向与车头方向的夹角）。
##
## ⚠ 这里纠正过一个错误的指标：第一版量的是"相对初始航向的横向位移"并叫它"侧滑"，
## 结果抓到高抓地力反而位移更大（2.762m vs 0.510m），看起来像"倍率反了"。
## 其实那正是正确的物理 —— 抓地力高时车**真的转过去了**（并把速度刮到 3km/h），
## 抓地力低时车推头直着冲出去（横向位移自然小）。位移量的是"转了多少"，
## 不是"滑了多少"，名字和判据都用错了。现在改用 v·ω（向心加速度）：
## 同样的打舵输入下，抓地力越高能达成的侧向加速度越大。
func _check_friction() -> void:
	var cfg: LevelConfig = GameState.current_level()
	var mult := cfg.friction_multiplier if cfg != null else 1.0
	# 扫一串倍率，看侧向加速度是否**单调**随抓地力上升。
	# 为什么用扫描而不是"两档比一个 25% 阈值"：单点比较太脆（实测 ×1.00 vs ×0.25
	# 只差 26%，刚好压在阈值线上，稍微抖一下就会翻）。单调性在 5 个点上同时成立，
	# 既难假阳性，还能直接看出倍率的梯度是否有实际手感差异。
	var mults := [1.0, 0.75, 0.5, 0.33, 0.2]
	print("[自检] 抓地力验收：扫描倍率 %s（本关配置 ×%.2f）"
		% [str(mults), mult])
	var accels: Array[float] = []
	var yaws: Array[float] = []
	for m in mults:
		var r: Dictionary = await _friction_probe(m)
		accels.append(float(r.get("lateral_accel", 0.0)))
		yaws.append(float(r.get("yaw_deg", 0.0)))
		print("[自检]   ×%.2f：侧向加速度 %5.1f m/s²，转过 %4.0f°，侧滑角 %4.1f°，末速 %3.0f km/h，离路面中心线 %.2fm"
			% [m, r.get("lateral_accel", 0.0), r.get("yaw_deg", 0.0),
			   r.get("slip_deg", 0.0), r.get("speed", 0.0), r.get("off_road", 0.0)])
	if accels[0] < 0.5:
		printerr("[自检] 抓地力验收 ✘ ×1.00 下侧向加速度只有 %.2f m/s²，探针本身没生效" % accels[0])
		return
	# 判据一：单调性（倍率降低，侧向加速度不得上升）
	var monotonic := true
	for i in range(1, accels.size()):
		if accels[i] > accels[i - 1] + 0.5:      # 0.5 m/s² 容差，避免被噪声判死
			monotonic = false
			printerr("[自检]   ✘ 非单调：×%.2f 的 %.1f > ×%.2f 的 %.1f"
				% [mults[i], accels[i], mults[i - 1], accels[i - 1]])
	# 判据二：两端差距要足够大，否则说明倍率对手感几乎没影响
	var spread := (accels[0] - accels[accels.size() - 1]) / maxf(accels[0], 0.01)
	print("[自检]   单调性：%s；两端差距：%.1f → %.1f m/s²（降 %.0f%%）"
		% ["✔ 成立" if monotonic else "✘ 不成立", accels[0], accels[accels.size() - 1], spread * 100.0])
	if monotonic and spread >= 0.10:
		print("[自检] 抓地力验收 ✔ 倍率确实进了物理：倍率越低侧向加速度越小，且梯度可感知")
	elif monotonic:
		print("[自检] 抓地力验收 △ 单调性成立但梯度偏小（降 %.0f%%）" % [spread * 100.0])
		printerr("[自检]   提示：轮胎 wheel_friction_slip 基准值本来就很高（前 3.0 / 后 2.6），"
			+ "倍率再低也还剩不少抓地力，天气手感可能不明显")
	else:
		printerr("[自检] 抓地力验收 ✘ 倍率没有单调影响物理，链路可能断了")


## 抓地力探针：**确定性摆放**后满舵 0.7 秒，测实际达成的侧向加速度（v·ω）。
##
## ⚠ 这条探针返工过两次，两次都是"夹具不可复现"，值得记下来：
##   第一版量"横向位移"当侧滑 —— 量到的其实是"转了多少"，名字和判据都错了。
##   第二版用 reset_to_track() 摆车 —— 那个函数把人送到"最后一个检查点"，
##     每次落点都不一样（还可能带着上一轮的姿态），于是同一倍率测出的侧向加速度
##     在 20~33 m/s² 之间乱跳，扫描出来的曲线完全不单调，根本得不出结论。
##   现在：固定摆在起终点直道、朝赛道前进方向、**速度直接给到 60km/h**
##     （省掉加速段，加速段的终点速度受弯道和撞墙影响，是最大的噪声源），
##     并临时关掉 auto_recover，防止探针中途被出界兜底搬走。
func _friction_probe(mult: float) -> Dictionary:
	var track := get_node_or_null("Track")
	if track == null or _car == null:
		return {"lateral_accel": 0.0, "slip_deg": 0.0, "yaw_deg": 0.0, "speed": 0.0}
	var hz := float(Engine.physics_ticks_per_second)
	_car.call("apply_level_setup", GameState.effective_speed(), 99, mult)
	var total := maxf(1.0, float(track.call("road_length")))
	var sf = track.get("start_finish_t")
	var d := total * float(sf) if sf != null else 0.0
	var fwd: Vector3 = track.call("centerline_forward", d)
	fwd.y = 0.0
	fwd = fwd.normalized()
	var prev_recover = _car.get("auto_recover")
	_car.set("auto_recover", false)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	_car.global_transform = Autopilot.pose_facing(track.call("centerline_point", d) + Vector3(0, 0.6, 0), fwd)
	_car.linear_velocity = fwd * (60.0 / 3.6)
	var start_pos: Vector3 = _car.global_position
	await get_tree().physics_frame
	var yaw0 := _car.global_rotation.y
	Input.action_press("accelerate")
	Input.action_press("steer_left")
	var lat_sum := 0.0
	var lat_peak := 0.0
	var slip_sum := 0.0
	var slip_n := 0
	var steer_frames := int(hz * 0.7)
	for i in range(steer_frames):
		await get_tree().physics_frame
		var vel := _car.linear_velocity
		var planar := Vector2(vel.x, vel.z).length()
		# 侧向加速度 = v · ω（向心加速度），抓地力越高能达成的越大
		var lat := planar * absf(_car.angular_velocity.y)
		lat_sum += lat
		lat_peak = maxf(lat_peak, lat)
		if planar > 3.0:
			var nose := -_car.global_transform.basis.z
			nose.y = 0.0
			var vdir := Vector3(vel.x, 0.0, vel.z)
			if nose.length() > 0.001:
				slip_sum += rad_to_deg(nose.normalized().angle_to(vdir.normalized()))
				slip_n += 1
	Input.action_release("steer_left")
	Input.action_release("accelerate")
	var res := {
		"lat_avg": lat_sum / float(maxi(steer_frames, 1)),
		"lateral_accel": lat_peak,
		"slip_deg": slip_sum / float(maxi(slip_n, 1)),
		"yaw_deg": rad_to_deg(absf(angle_difference(yaw0, _car.global_rotation.y))),
		"speed": _car.linear_velocity.length() * 3.6,
		# 探针本身要能自证有效：跑完还在路面上才算数
		"off_road": _car.global_position.distance_to(
			track.call("nearest_on_centerline", _car.global_position, -1.0).get("pos", start_pos)),
	}
	_car.set("auto_recover", prev_recover)
	var cfg: LevelConfig = GameState.current_level()
	_car.call("apply_level_setup", GameState.effective_speed(),
		cfg.laps_to_finish if cfg != null else 2,
		cfg.friction_multiplier if cfg != null else 1.0)
	_car.call("reset_to_track")
	return res


# 位姿构造已迁至 scripts/autopilot.gd（SPLIT-AUTOPILOT-002 纯迁移，行为零变化；
# 纯函数，static func pose_facing，本文件调用点走 Autopilot.pose_facing(...)）



# 转向台架（--check=steerbench）与刹车台架（--check=brakebench）验收族已迁至
# scripts/checks/bench.gd（SPLIT-CHECKS-BENCH-002 纯迁移，行为零变化）；
# 分发口走 await _checks_bench.run_steerbench() / run_brakebench()。

# ======================== 翻车恢复验收（--check=flip）========================
#
# 玩家的原话是"翻车被扶正之后，车贴着地横向滑，速度不低但完全不可控"。
# 这个状态（**四轮全不接地 + 车身基本水平 + 仍在动**）现有代码里没有任何判定管它：
#   - 翻车判定看的是 up·UP（腹部贴地时≈1，判不出）
#   - 卡住判定看的是"速度低"（腹部滑行时 27km/h，也判不出）
# 所以本项检查分两步：① 用**物理状态硬数据**把能复现的姿态找出来（探针，打状态表）；
# ② 再断言恢复时间。找不到复现姿态就明确报"未复现"，绝不假装通过。

## 用例 B 的侧滑速度（km/h）。取 27 是因为日志里实测就是这个量级。
const BELLY_TEST_KMH := 27.0
## 每个候选姿态最多观察多少秒
const BELLY_TEST_SECONDS := 8.0
## 连续"四轮全不接地"要达到这么久，才算真的复现了腹部贴地
const BELLY_ONSET := 1.0
## 连续"四轮接地"要达到这么久，才算真的恢复了（单帧接地不算 —— 实测会抖）
const BELLY_RECOVER := 0.6
## 姿态在多少度以内算"基本水平"（不是腾空翻车）
const FLIP_UPRIGHT_ANGLE := 25.0

## 本项验收里成功复现腹部贴地的候选姿态数
var _flip_reproduced := 0
## 本项验收的失败计数
var _flip_fails := 0


## 采样车的接地/姿态状态。全部来自物理状态与射线，**不读脚本内部变量** ——
## 这样"轮子是不是真的不接地"是独立证据，而不是拿实现给自己打分。
func _flip_state() -> Dictionary:
	var up: Vector3 = _car.global_transform.basis.y.normalized()
	var wheels := 0
	var contact := 0
	var rayhit := 0
	var space := get_world_3d().direct_space_state
	for child in _car.get_children():
		if child is VehicleWheel3D:
			var w: VehicleWheel3D = child
			wheels += 1
			if w.is_in_contact():
				contact += 1
			var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				w.global_position,
				w.global_position + Vector3.DOWN * (w.wheel_radius + 0.6),
				1, [_car.get_rid()])
			if not space.intersect_ray(q).is_empty():
				rayhit += 1
	return {
		"wheels": wheels,
		"contact": contact,
		"rayhit": rayhit,
		"up_dot": up.dot(Vector3.UP),
		"y": _car.global_position.y,
		"kmh": Vector2(_car.linear_velocity.x, _car.linear_velocity.z).length() * 3.6,
	}


## 用例 A：底朝天。翻 180° 放到路面上，要求 ≤2s 原地扶正且四轮接地。
func _flip_case_inverted(track: Node, arc: float) -> void:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	# 第二个参数传 DOWN：基的 Y 轴朝下 = 整车倒扣，车头仍沿赛道方向
	_car.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.DOWN), c + Vector3.UP * 0.9)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	var t := 0.0
	var recovered := -1.0
	while t < 4.0:
		await get_tree().physics_frame
		t += tick
		var s := _flip_state()
		if float(s["up_dot"]) > cos(deg_to_rad(FLIP_UPRIGHT_ANGLE)) and int(s["contact"]) == 4:
			recovered = t
			break
	if recovered > 0.0 and recovered <= 2.0:
		print("[自检]   用例 A 底朝天：%.2fs 扶正且四轮接地 ✔" % recovered)
		return
	_flip_fails += 1
	var why := "4 秒内没恢复"
	if recovered > 0.0:
		why = "恢复太慢 %.2fs（>2.0s）" % recovered
	print("[自检]   用例 A 底朝天：✘ %s" % why)


## 用例 C 的一个真实姿态：摆好 → 给 27km/h 侧向速度 → 观察"恢复"还是"一直贴地滑"。
##
## ⚠ 实测结论（960 帧/姿态，逐帧统计）：从这些姿态出发，**四轮全不接地最多只维持
##   0.2~0.33 秒**（占全程 1~7%），车很快就落回四个轮子 —— 也就是说**合成姿态复现不出
##   "持续贴地滑行"**。所以本函数现在的定位是**证据收集**：它把接地时序图打出来，
##   真的复现出来就必须 ≤2s 恢复；复现不出来就明确写"未能复现"，绝不当成通过。
##   持续状态由用例 B（belly_test_hover 夹具）稳定构造并断言。
##
## roll_deg / pitch_deg：绕前进轴 / 绕右轴旋转；height：车体中心离路面的高度（米）。
func _flip_case_belly(track: Node, arc: float, roll_deg: float, pitch_deg: float,
		height: float, label: String) -> void:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var b := Basis.looking_at(fwd, Vector3.UP)
	if absf(roll_deg) > 0.01:
		b = b.rotated(fwd, deg_to_rad(roll_deg))
	if absf(pitch_deg) > 0.01:
		b = b.rotated(b.x.normalized(), deg_to_rad(pitch_deg))
	_car.global_transform = Transform3D(b, c + Vector3.UP * height)
	_car.linear_velocity = side * (BELLY_TEST_KMH / 3.6)
	_car.angular_velocity = Vector3.ZERO

	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	var t := 0.0
	var frames := 0
	var zero_frames := 0
	var run_zero := 0.0          # 当前这一段的连续 0/4 时长
	var max_zero := 0.0          # 最长的一段连续 0/4
	var run_four := 0.0          # 当前这一段的连续 4/4 时长
	var onset_armed := -1.0      # 当前 0/4 段的起点
	var onset := -1.0            # 贴地成立（连续达 BELLY_ONSET）之后的段落起点
	var recovered := -1.0        # 恢复用时（连续 4/4 达 BELLY_RECOVER 那刻）
	var bin_frames := 0
	var bin_zero := 0
	var pattern := ""
	while t < BELLY_TEST_SECONDS:
		await get_tree().physics_frame
		t += tick
		var s := _flip_state()
		var level_ok: bool = float(s["up_dot"]) > cos(deg_to_rad(FLIP_UPRIGHT_ANGLE))
		var near_surface: bool = (float(s["y"]) - c.y) < 1.0
		var moving: bool = float(s["kmh"]) > 5.0
		frames += 1
		bin_frames += 1
		if int(s["contact"]) == 0:
			zero_frames += 1
			bin_zero += 1
		# 贴地段：四轮全不接地 + 车身水平 + 还贴着路面 + 还在动（排除腾空飞跃）
		if int(s["contact"]) == 0 and level_ok and near_surface and moving:
			if run_zero <= 0.0:
				onset_armed = t
			run_zero += tick
			if run_zero >= BELLY_ONSET and onset < 0.0:
				onset = onset_armed
			max_zero = maxf(max_zero, run_zero)
		else:
			run_zero = 0.0
		# 恢复：必须**连续**接地够久才算，单帧接地不算（实测会抖）
		if int(s["contact"]) == 4 and level_ok:
			run_four += tick
			if onset > 0.0 and recovered < 0.0 and run_four >= BELLY_RECOVER:
				recovered = t - onset
		else:
			run_four = 0.0
		# 每 0.25s 按多数票压成一个字符，一眼看出抖不抖
		if bin_frames >= int(0.25 / tick):
			var ch := "0"
			if bin_zero * 2 < bin_frames:
				ch = "4"
			pattern += ch
			bin_frames = 0
			bin_zero = 0
		if recovered > 0.0 and t > onset + recovered + 0.75:
			break

	var frac := 0.0
	if frames > 0:
		frac = float(zero_frames) / float(frames)
	print("[自检]   候选「%s」观察 %.1fs：帧数 %d，0/4 占比 %.0f%%，最长连续 0/4 = %.2fs"
		% [label, t, frames, frac * 100.0, max_zero])
	print("[自检]     接地时序（每字符 0.25s：0=四轮全不接地，4=四轮接地）：%s" % pattern)
	if max_zero < BELLY_ONSET:
		print("[自检]   候选「%s」：**未能复现**（连续 0/4 最长仅 %.2fs < %.1fs 门限）→ 不计入判定"
			% [label, max_zero, BELLY_ONSET])
		return
	_flip_reproduced += 1
	if recovered > 0.0 and recovered <= 2.0:
		print("[自检]   候选「%s」：贴地后 %.2fs 恢复四轮接地 ✔（判据 ≤2.0s）" % [label, recovered])
		return
	_flip_fails += 1
	if recovered > 0.0:
		print("[自检]   候选「%s」：✘ 恢复太慢 %.2fs（>2.0s）" % [label, recovered])
	else:
		print("[自检]   候选「%s」：✘ 观察 %.1fs 内四轮从未连续接地 %.1fs 以上 —— 一直贴地滑（占比 %.0f%%）"
			% [label, t, BELLY_RECOVER, frac * 100.0])


## 用例 B：**合成**腹部贴地状态（四轮全不接地 + 车身水平 + 贴着路面 + 27km/h 在动）。
##
## 为什么要合成：用例 C 的 6 个真实姿态实测只能让"四轮全不接地"维持 0.2~0.33s
## （车很快落回四个轮子），复现不出"持续贴地滑行"。这里用车的 belly_test_hover 夹具
## 把车托在路面上方，从而**稳定地**产生那个状态。
##   - 被测量的量（接地数 / 姿态 / 速度 / 离路面高度）**全是真实物理读数**，没有伪造；
##   - 夹具只负责"托住"，不参与判定；
##   - 断言分两段：① 状态成立后 ≤2s 必须触发恢复；② 关掉夹具后必须真的落回四轮接地。
##     第二段是关键 —— 只把车抬高、不补向上速度的话，第二段会失败。
func _flip_case_hover(track: Node, arc: float) -> void:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	_car.set("belly_test_hover", true)
	_car.set("belly_recovery_count", 0)
	_car.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), c + Vector3.UP * 0.8)
	# ⚠ 速度必须**沿赛道方向**给：第一版给的是侧向速度，结果车在 1 秒内横着撞上护栏、
	# 速度从 24km/h 掉到 1.2km/h，状态根本维持不住（实测数据）。
	# 腹部贴地判定与方向无关，所以沿赛道给速度更稳、更能稳定复现这个状态。
	_car.linear_velocity = fwd * (BELLY_TEST_KMH / 3.6)
	_car.angular_velocity = Vector3.ZERO

	var t := 0.0
	var zero_run := 0.0
	var onset := -1.0
	var fired_at := -1.0
	var max_zero := 0.0
	var next_diag := 0.5
	while t < 5.0:
		await get_tree().physics_frame
		t += tick
		var s := _flip_state()
		if int(s["contact"]) == 0 and float(s["up_dot"]) > cos(deg_to_rad(FLIP_UPRIGHT_ANGLE)):
			zero_run += tick
			max_zero = maxf(max_zero, zero_run)
			if zero_run >= BELLY_ONSET and onset < 0.0:
				onset = t - zero_run          # 状态真正成立的那一刻
		else:
			zero_run = 0.0
		if t >= next_diag:
			next_diag += 0.5
			# 把**车自己**的判据读数打出来：不猜，直接看它为什么没触发
			print("[自检]     t=%.2fs 接地 %d/4 belly_time=%.2f auto=%s immunity=%.2f y=%.2f 路面y=%.2f up·UP=%.2f %.1f km/h"
				% [t, int(s["contact"]), float(_car.get("_belly_time")),
				   str(_car.get("auto_recover")), float(_car.get("_immunity")),
				   float(s["y"]), c.y, float(s["up_dot"]), float(s["kmh"])])
		if int(_car.get("belly_recovery_count")) > 0:
			fired_at = t - onset
			break
	_car.set("belly_test_hover", false)

	# 第二段：夹具关掉后必须真的落回四个轮子
	var t2 := 0.0
	var run_four := 0.0
	var landed := -1.0
	while t2 < 3.0:
		await get_tree().physics_frame
		t2 += tick
		if int(_flip_state()["contact"]) == 4:
			run_four += tick
			if run_four >= BELLY_RECOVER:
				landed = t2
				break
		else:
			run_four = 0.0

	var fired_txt := "未触发"
	if fired_at > 0.0:
		fired_txt = "%.2fs" % fired_at
	var landed_txt := "未落地"
	if landed > 0.0:
		landed_txt = "%.2fs" % landed
	print("[自检]   用例 B 合成腹部贴地：状态持续 %.2fs，恢复触发 %s，夹具关闭后落地 %s"
		% [max_zero, fired_txt, landed_txt])
	if fired_at > 0.0 and fired_at <= 2.0 and landed > 0.0:
		print("[自检]   用例 B 合成腹部贴地 ✔")
		return
	_flip_fails += 1
	var why := "5 秒内没有触发恢复（belly_recovery_count 一直是 0）"
	if fired_at > 2.0:
		why = "恢复触发太慢 %.2fs（判据 ≤2.0s）" % fired_at
	elif fired_at > 0.0:
		why = "触发了恢复，但夹具关闭后 3 秒内没能落回四轮接地"
	print("[自检]   用例 B 合成腹部贴地：✘ %s" % why)


## 一次搜索试验。mode：
##   "wall" —— 以 angle_deg 斜向护栏全冲（先让悬挂稳定，再给速度）
##   "flip" —— 沿赛道冲起来后强制翻转（复刻"撞完翻车"那一刻）
##   "drop" —— 从 2.5/4.5m 高处砸到路面（复刻"飞出去砸底盘"，最可能压死悬挂）
##
## ⚠ 必须先 settle 再测量：实测刚瞬移/摆好姿态后的 ~0.33s 内四个轮子都报"不接地"，
##   那是物理 settle 瞬态、不是贴地滑行。不去掉它的话，每一组都会报"0/4 最长 0.33s"，
##   看起来像发现了什么，其实只是噪声。
## 返回 {found, max_zero, recovered, kmh, y, min_kmh}
func _flip_hunt_trial(track: Node, arc: float, angle_deg: float, kmh: float,
		mode: String, seconds: float) -> Dictionary:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var heading := (fwd + side * tan(deg_to_rad(angle_deg))).normalized()
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	_car.set("belly_recovery_count", 0)
	_car.set("auto_recover", true)
	var start_y := 0.55
	if mode == "drop":
		start_y = 2.5
	_car.global_transform = Transform3D(Basis.looking_at(heading, Vector3.UP), c + Vector3.UP * start_y)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO

	# 先落地稳定，再给冲撞速度（drop 模式例外：砸下去本身就是事件）
	if mode != "drop":
		var settle := 0.45
		var ts := 0.0
		while ts < settle:
			await get_tree().physics_frame
			ts += tick
		_car.linear_velocity = heading * (kmh / 3.6)

	var t := 0.0
	var run_zero := 0.0
	var max_zero := 0.0
	var onset := -1.0
	var recovered := -1.0
	var flipped_done := false
	var min_kmh := 1e9
	while t < seconds:
		await get_tree().physics_frame
		t += tick
		if mode == "flip" and not flipped_done and t > 0.4:
			var b := _car.global_transform.basis
			_car.global_transform = Transform3D(b.rotated(b.z.normalized(), PI),
				_car.global_position + Vector3.UP * 0.5)
			flipped_done = true
		var s := _flip_state()
		var level_ok: bool = float(s["up_dot"]) > cos(deg_to_rad(FLIP_UPRIGHT_ANGLE))
		# near_surface 同时起到"排除正常腾空/下落"的作用（高空砸地的空中段不算贴地）
		var near_surface: bool = (float(s["y"]) - c.y) < 1.5
		if int(s["contact"]) == 0 and level_ok and near_surface and float(s["kmh"]) > 5.0:
			if run_zero <= 0.0:
				onset = t
			run_zero += tick
			max_zero = maxf(max_zero, run_zero)
		else:
			run_zero = 0.0
		min_kmh = minf(min_kmh, float(s["kmh"]))
		if onset > 0.0 and recovered < 0.0 and int(_car.get("belly_recovery_count")) > 0:
			recovered = t - onset
	var last := _flip_state()
	return {
		"found": max_zero >= BELLY_ONSET, "max_zero": max_zero, "recovered": recovered,
		"kmh": float(last["kmh"]), "y": float(last["y"]), "min_kmh": min_kmh,
	}


## 把一次搜索试验的结论打出来；搜到"持续贴地"就必须按 2 秒判据断言恢复。
func _report_hunt_finding(label: String, r: Dictionary) -> void:
	_flip_reproduced += 1
	var rec := float(r["recovered"])
	if rec > 0.0 and rec <= 2.0:
		print("[自检]     ★ 搜到持续贴地：%s（0/4 最长 %.2fs）→ %.2fs 恢复 ✔"
			% [label, float(r["max_zero"]), rec])
		return
	_flip_fails += 1
	if rec > 0.0:
		print("[自检]     ✘ 搜到持续贴地：%s（0/4 最长 %.2fs）但恢复太慢 %.2fs（判据 ≤2.0s）"
			% [label, float(r["max_zero"]), rec])
	else:
		print("[自检]     ✘ 搜到持续贴地：%s（0/4 最长 %.2fs）且**未触发恢复**（末速度 %.1f km/h y=%.2f）"
			% [label, float(r["max_zero"]), float(r["kmh"]), float(r["y"])])


## 用例 D：自动搜复现 —— 用多种"撞墙 / 翻车"方式去撞出持续贴地滑行。
##
## 为什么必须有这一步：用例 B 的合成夹具只能证明"判定与恢复逻辑是对的"，
## **不能证明真实游玩里到底会不会进这个状态**。所以这里做一次**有界**的自动搜索：
## 以 5 个角度 × 2 个速度怼护栏，外加 2 组高速强制翻转，逐帧找"持续 0/4"。
##   找到 → 立刻按 2 秒判据断言恢复（这就是回归保护）；
##   找不到 → 如实报告"本次没搜到"，并说明这不等于真实游玩不会进这个状态。
##
## 搜到的组合会在日志里以 ★ 标出，并带上 0/4 持续时长与恢复用时。
func _flip_case_hunt(track: Node, arc: float) -> void:
	const HUNT_SECONDS := 4.0
	var angles := [5.0, 12.0, 25.0, 45.0, 70.0]
	var speeds := [60.0, 110.0]
	var prev_oob = _car.get("auto_reset_out_of_bounds")
	_car.set("auto_reset_out_of_bounds", false)
	var trials := 0
	var found := 0
	print("[自检]   用例 D 自动搜复现：%d 组（角度 × 速度）怼护栏 + 2 组高速翻转 + 4 组高空砸地，每组最多 %.0fs"
		% [angles.size() * speeds.size(), HUNT_SECONDS])
	for ang: float in angles:
		for kmh: float in speeds:
			trials += 1
			var r := await _flip_hunt_trial(track, arc, ang, kmh, "wall", HUNT_SECONDS)
			if bool(r["found"]):
				found += 1
				_report_hunt_finding("撞墙 %.0f° @ %.0fkm/h" % [ang, kmh], r)
			else:
				print("[自检]     试 %2.0f° @ %3.0fkm/h → 未出现持续贴地（0/4 最长 %.2fs，最低速 %.0f km/h）"
					% [ang, kmh, float(r["max_zero"]), float(r["min_kmh"])])
	for kmh: float in [80.0, 130.0]:
		trials += 1
		var r2 := await _flip_hunt_trial(track, arc, 0.0, kmh, "flip", HUNT_SECONDS)
		if bool(r2["found"]):
			found += 1
			_report_hunt_finding("高速翻转 @ %.0fkm/h" % kmh, r2)
		else:
			print("[自检]     试 高速翻转 @ %3.0fkm/h → 未出现持续贴地（0/4 最长 %.2fs）"
				% [kmh, float(r2["max_zero"])])
	for kmh: float in [0.0, 60.0]:
		for ang2: float in [0.0, 20.0]:
			trials += 1
			var r3 := await _flip_hunt_trial(track, arc, ang2, kmh, "drop", HUNT_SECONDS)
			if bool(r3["found"]):
				found += 1
				_report_hunt_finding("2.5m 砸地 %.0f° @ %.0fkm/h" % [ang2, kmh], r3)
			else:
				print("[自检]     试 2.5m 砸地 %2.0f° @ %3.0fkm/h → 未出现持续贴地（0/4 最长 %.2fs）"
					% [ang2, kmh, float(r3["max_zero"])])
	_car.set("auto_reset_out_of_bounds", prev_oob)
	if found > 0:
		print("[自检]   用例 D 结论：%d 组里搜到持续贴地 %d 组，每一组都已断言 ≤2s 恢复"
			% [trials, found])
	else:
		print("[自检]   用例 D 结论：%d 组都没搜到持续贴地 —— 如实报告" % trials)
		print("[自检]     ⚠ 这不等于真实游玩不会进这个状态：本次搜索只覆盖了"
			+ "直线怼墙与高速翻转，真实成因（例如特定地形/多车挤压）可能不在这里面。")


## 翻车恢复验收：用例 A（真实底朝天）+ 用例 B（合成腹部贴地，硬断言）
## + 用例 C（6 个真实姿态的复现尝试，证据收集）+ 用例 D（撞墙/翻车自动搜复现）。
func _check_flip() -> void:
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	# 关掉出界兜底：否则车滑远了会被瞬移回赛道，"到底有没有扶正"就被掩盖了
	var prev_oob = _car.get("auto_reset_out_of_bounds")
	_car.set("auto_reset_out_of_bounds", false)
	_car.set("auto_recover", true)
	_flip_reproduced = 0
	_flip_fails = 0
	var total := float(track.call("road_length"))
	var arc := 260.0
	if total < 400.0:
		arc = total * 0.3
	print("[自检] 翻车恢复验收：起点弧长 %.0fm（赛道全长 %.0fm）" % [arc, total])
	print("[自检]   用例 A 真实底朝天 → ≤2s 扶正；用例 B 合成腹部贴地 → ≤2s 触发恢复并落地")
	print("[自检]   用例 C 6 个真实姿态：收集证据（复现出持续贴地就必须 ≤2s 恢复）")
	print("[自检]   用例 D 自动搜复现：多种角度/速度撞墙 + 高速翻转，找真实成因")
	await _flip_case_inverted(track, arc)
	await _flip_case_hover(track, arc)
	await _flip_case_belly(track, arc, 0.0, 0.0, 0.55, "水平 · 落地高度+0.55")
	await _flip_case_belly(track, arc, 0.0, 0.0, 0.40, "水平 · 落地高度+0.40")
	await _flip_case_belly(track, arc, 0.0, 0.0, 0.25, "水平 · 落地高度+0.25")
	await _flip_case_belly(track, arc, 20.0, 0.0, 0.50, "滚转 20°")
	await _flip_case_belly(track, arc, 35.0, 0.0, 0.45, "滚转 35°")
	await _flip_case_belly(track, arc, 0.0, -18.0, 0.50, "俯仰 -18°")
	await _flip_case_hunt(track, arc)
	_car.set("auto_reset_out_of_bounds", prev_oob)
	_car.set("belly_test_hover", false)
	_car.call("reset_to_track")
	if _flip_fails == 0:
		print("[自检] 翻车恢复验收 ✔ 用例 A/B 全过；用例 C 复现持续贴地 %d/6 个（0 个只说明合成姿态造不出持续贴地，不代表没问题）"
			% _flip_reproduced)
	else:
		printerr("[自检] 翻车恢复验收 ✘ 失败 %d 项（用例 C 复现 %d/6 个）"
			% [_flip_fails, _flip_reproduced])


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
