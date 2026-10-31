extends RefCounted
## AI 对手生成（实例化 race_car.tscn 后换控制器脚本）与发车时机控制。
## `--check=opponents` / `--check=phys` / `--check=avoid` 的显式发车，
## 以及游玩时的发车链路，**共用这一份**。
##
## ⚠ 发车时口的演变（2026-10-18 Phase 01，竞速系统策划案 R5）：
##   · 旧规则①（迁移前）：加载即 arm → AI 抢跑，且验收路径走不到 → "验收绿、游戏错"；
##   · 旧规则②（2026-10-13 ~ 10-17）：main._process 轮询玩家速度 ≥4km/h 才发车
##     （maybe_start_opponents，随 SPLIT-OPPONENT-001 迁入本模块）；
##   · 新规则（2026-10-18 起）：**同步发车** —— 唯一入口是 main 的 _on_race_go()
##     （倒计时"出发！"触发，与玩家解锁同一帧），maybe_start_opponents 已删除。
##   aistart / aidiag 两项验收改验新语义（D1 用户批准，判据串与项数不变）。
##
## 2026-10-13 SPLIT-OPPONENT-001：从 scenes/main.gd 整块拆出，**纯迁移、行为零变化** ——
## 常量数值、逻辑、print 文案（连 `[main]` 前缀都原样留着，改前缀会让 A/B 日志整片不同）、
## 注释全部照搬，没有第二份实现。
## 迁了什么：
##   · 3 个函数（原 main.gd 的 _spawn_opponents / _arm_opponents / _maybe_start_opponents；
##     其中 _maybe_start_opponents 已于 2026-10-18 Phase 01 同步发车时退役，见上文），
##     去掉下划线前缀成为公开方法，与 autopilot.gd / l4_debug_diag.gd 的公开 API 风格一致；
##   · 状态：_opponents（对手数组）、_ai_started（发车闩锁）。
##
## ⚠ 三处硬耦合是怎么解开的（本次最难的地方，逐条定死，以后别悄悄改回去）：
##
##   ① **_opponents 不是私有**：main.gd 的 checks 族（ADR-001 永久居民：_check_opponents、
##      _check_phys、_check_avoid、_check_ai_start、_check_ai_diag，以及 _check_lap 尾部）
##      有 20+ 处直接读它。这里由**本模块持有唯一真身**，main.gd 那边保留同名成员、
##      但改成**只读 getter 代理**（值来自下面的 `opponents` 属性）——
##      于是 20+ 个读点一个字都不用改，也不可能出现"两边各存一份数组"的漂移。
##      （备选方案"main 持有数组、模块只管生成并回填"已否决：那样 arm / maybe_start
##        每次都得把数组当参数传回来，调用点一样多，还多出一个"谁负责 append"的歧义。）
##
##   ② **add_child(holder)**：容器挂载由注入进来的 Callable `_mount` 转交 main 完成，
##      本模块不持有节点所有权、也不认识场景树（因此这里没有 get_node）。
##      ⚠ 顺序不能倒：**必须先 mount，再往 holder 里 add_child(ai)**。
##      holder 若还没进树，`holder.add_child(ai)` 会把 AI 的 _ready 推迟到 holder
##      入树那一刻，于是 setup() 反而跑在 _ready **之前**（原来是 _ready 先跑、setup 后跑）——
##      这种"看起来无所谓"的顺序调换正是纯迁移最容易夹带的行为变化。
##
##   ③ 性能采样由诊断入口调用 main._sample_physics_ms；本模块不保存无读取方的基线。
##
## ⚠ 为什么没有 class_name（与 environment.gd / engine_audio.gd / l4_debug_diag.gd /
##   autopilot.gd 同一约定）：本项目的验收闸门（parse-check / run-check / run-all-checks）
##   在**无编辑器**环境里跑 Godot，而 class_name 的全局注册表
##   （.godot/global_script_class_cache.cfg）**只有编辑器会重建**。2026-10-12
##   实测：新增 class_name 后 --check-only 与游戏运行双双报
##   `Identifier "X" not declared in the current scope`。因此消费方一律用
##   `const OpponentSpawner := preload("res://scripts/opponent_spawner.gd")` 引用本模块。

# ---------------------------------------------------------------- 模块自有常量
## 对手容器的稳定节点名，供场景诊断与清理定位；用常量保持唯一来源。
const HOLDER_NAME := "Opponents"

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car）。由 setup() 注入。
var _car: VehicleBody3D = null
## 障碍场（main.gd 的 _obstacle_field）。由 setup() 注入；无障碍关卡时为 null。
var _obstacle_field: Node3D = null
## 把对手容器挂进场景树的回调（main.gd 的 add_child）。由 setup() 注入。
## 为什么是回调而不是直接拿节点：本模块不得持有 main / 反向认识场景树。
var _mount: Callable = Callable()
## `should_spawn()` 顺带预加载好的资源（`spawn_opponents` 直接用）。
## Godot 的 load() 自带缓存，这里只是把它们存在调度过程中，不是第二份实现。
var _base_scene: PackedScene = null
var _ai_script: GDScript = null

# ---------------------------------------------------------------- 本模块持有的状态
## 本关的 AI 对手（ai_opponents 台）。空数组 = 本关没有对手。
var _opponents: Array = []
## 对手是否已经随玩家起跑（避免每帧重复发车/重复打印）
var _ai_started := false


## 注入外部引用（main.gd 在 _after_world_ready 里、障碍物建好之后调用一次）。
##
## ⚠ 为什么必须在障碍物**之后**：AI 摆车道时要查询障碍位置，晚注入一拍只是拿到 null，
## 早注入则会让 AI 拿着"还没有障碍"的旧引用跑完全程。
func setup(car: VehicleBody3D, field: Node3D, mount: Callable) -> void:
	_car = car
	_obstacle_field = field
	_mount = mount


## 对手数组的只读取值口。main.gd 的同名成员就是代理到这里（见文件头决策 ①）。
var opponents: Array:
	get:
		return _opponents


## 发车闩锁的只读取值口。公开 API（无下划线前缀，不触发 UNUSED 警告）：
## main.gd 与 ai.gd 的同名代理曾代理到这里，两者 2026-10-18 因零读取方删除
## （死代理 + UNUSED_PRIVATE_CLASS_VARIABLE 警告）；这个口子保留 ——
## 阶段二实时名次要判断"AI 是否已随玩家发车"，届时直接读它。
var ai_started: bool:
	get:
		return _ai_started


## 本关是否该生成对手：**含所有跳过原因的打印**，并顺带把资源预加载好。
## 返回要生成的台数（0 = 不生成；返回 0 之前该说的话已经按原样说过一次）。
##
## 先完成条件与资源检查，再生成对手；正常开赛不等待性能诊断。
func should_spawn(cfg: LevelConfig, track: Node3D) -> int:
	if cfg == null:
		return 0
	# 玩家在主菜单可以把 AI 对手整个关掉。数量只问 GameState 这一个出口，
	# 免得 main.gd / 菜单各写一份判断而漂移。
	var want := GameState.effective_ai_count()
	if want <= 0:
		if cfg.ai_opponents > 0 and not GameState.ai_enabled:
			print("[main] 玩家已在菜单关闭 AI 对手：本关（本来 %d 台）不生成" % cfg.ai_opponents)
		return 0
	# `--noai`：同一条赛道、同样的对手配置，只是不生成对手。
	# 这样 --check=phys 才能做**只差对手**的干净 A/B（换关卡比会混入赛道几何的影响）。
	if "--noai" in OS.get_cmdline_user_args():
		print("[main] 检测到 --noai：本关不生成 AI 对手（用于物理开销 A/B）")
		return 0
	# track 由 main 传入（原 `get_node_or_null("Track")`）：本模块不访问场景树。
	if track == null:
		printerr("[main] 没有 Track，无法生成 AI 对手")
		return 0
	_base_scene = load("res://scenes/race_car.tscn")
	_ai_script = load("res://scripts/ai_opponent.gd")
	if _base_scene == null or _ai_script == null:
		printerr("[main] 无法加载 AI 对手所需资源（race_car.tscn / ai_opponent.gd）")
		return 0
	return want


## 生成 AI 对手：**实例化 race_car.tscn 后换控制器脚本**。
##
## 为什么不新建一个 ai_car.tscn：车轮硬点/悬挂/摩擦那些数值是实测调出来的
## （race_car.tscn 里有长注释逐条记录），抄一份迟早两边漂移。
## 也不复制关卡参数 —— 极速与抓地力都由本函数从关卡配置算好注入。
##
## ⚠ 顺序陷阱：必须在 add_child **之前** set_script。否则实例里自带的 vehicle.gd
## 会先跑完 _ready（把玩家输入、计圈、复位逻辑全挂到 AI 车上）。
##
## 调用前置条件：`should_spawn()` 已返回 > 0（资源已预加载，所有跳过分支也已打印）。
func spawn_opponents(cfg: LevelConfig, track: Node3D, want: int) -> void:
	var holder := Node3D.new()
	holder.name = HOLDER_NAME
	# 挂载容器回调 main 完成；⚠ 必须在下面 add_child(ai) 之前（见文件头决策 ②）。
	_mount.call(holder)
	var speed := GameState.effective_speed() * cfg.ai_speed_scale
	for i in range(want):
		var ai: VehicleBody3D = _base_scene.instantiate()
		# ① 先换脚本，再进树
		ai.set_script(_ai_script)
		# ② 剥掉只属于玩家的附加物：PhysicsMonitor 会刷屏，EngineSound 会几台一起响
		for extra in ["PhysicsMonitor", "EngineSound"]:
			var n := ai.get_node_or_null(extra)
			if n != null:
				ai.remove_child(n)
				n.queue_free()
		var model := ai.get_node_or_null("CarModel")
		if model != null:
			model.set_script(null)     # 去掉出生自检打印
		ai.name = "AiCar%d" % i
		# ③ 车辆之间要能撞：mask = 地面(层1) + 车辆(层2)。
		#    玩家车的 mask 也要含层2 才撞得起来（vehicle.gd 的 VEHICLE_LAYER 就是 2，
		#    复位无敌 _set_ghost 一直在切这一位，只是之前 mask 没开，等于没接线）。
		ai.collision_layer = 2
		ai.collision_mask = 3
		holder.add_child(ai)
		ai.call("setup", track, i, speed, GameState.effective_laps(), cfg.friction_multiplier, _car,
			cfg.min_corner_radius)
		# 把障碍物场交给 AI：它接近被挡的车道时会换边（AI 不做逐帧避障规划，
		# 只是"这条线被挡了就换到空的那侧"，够用且不会卡死）
		if _obstacle_field != null:
			ai.set("obstacle_field", _obstacle_field)
		# 把玩家交给 AI：它需要主动避让玩家（不再"撞上就撞上"）
		ai.set("player", _car)
		# 故意**不**在这里发车：验收脚本要先测"对手怠速"的物理开销，
		# 而且发车时机应该由游戏流程（发车倒计时/检查）决定，不该写死在生成里。
		_opponents.append(ai)
	print("[main] 已生成 %d 台 AI 对手（极速 %.0f km/h = 本关建议 %.0f × 倍率 %.2f，抓地力 ×%.2f）"
		% [want, speed, GameState.effective_speed(),
		   cfg.ai_speed_scale, cfg.friction_multiplier])


## 让所有对手发车。生成时故意不发车，由这里（游戏流程 / 验收脚本）决定时机。
##
## Phase 01（2026-10-18 同步发车）起，游玩时唯一的调用方是 main 的"出发！"
## 回调 _on_race_go() —— 与玩家解锁、相位切换在**同一帧**完成，AI 不再等待
## 玩家速度（旧规则 maybe_start_opponents 已退役，见文件头）。验收族
## （opponents / avoid / aidiag）仍然自己显式调用本函数。
## 幂等：_ai_started 闩锁保证重复调用只发一次车。
func arm_opponents() -> void:
	if _ai_started:
		return
	_ai_started = true
	for o in _opponents:
		o.set("armed", true)
