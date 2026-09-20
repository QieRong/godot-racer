extends Node3D
## 主场景装配：把检查点信号接到 HUD，并给引擎声临时合成一个音源
##
## 这样设计是为了让你不用手动连线就能跑起来：
##   - Track 下所有 Area3D（含 StartFinish）的 car_passed 自动连到 HUD
##   - EngineSound 若没挂音频流，就用 AudioStreamGenerator 实时合成引擎声，
##     你把 freesound 下的 engine loop 拖到 EngineSound.stream 后，这段会自动让位

@onready var _car: VehicleBody3D = $RaceCar
@onready var _hud: CanvasLayer = $HUD

# 截图模式的内部状态（只有带 --shot 启动时才用）
var _shot_mode := false
var _shot_frames := 150
var _shot_hold := 0
var _shot_steer := 0
var _shot_view := -1
var _shot_out := ""
var _shot_frame := 0

# 验收模式状态（只有带 --check 启动时才用）
var _check := ""
var _check_frame := 0
var _check_running := false
## 检查里重载了场景时置 true：让旧场景不要 quit()，把流程交给新场景
var _keep_alive_after_check := false

## 本关的 AI 对手（ai_opponents 台）。空数组 = 本关没有对手。
var _opponents: Array = []
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
## 加对手**之前**测到的物理帧耗时（毫秒）。-1 表示没测到。
var _physics_ms_no_ai := -1.0
## 对手是否已经随玩家起跑（避免每帧重复发车/重复打印）
var _ai_started := false
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
	_setup_placeholder_engine_sound()
	# AI 对手要等赛道建好才能摆发车格（赛道是延迟构建的）。
	#
	# ⚠ 必须 await：_spawn_opponents 里有 await（要测无对手时的物理耗时基线），
	# 于是它变成协程。不 await 的话这里会**立刻往下走**、检查脚本在对手还没
	# 生成出来的时候就开始跑（实测表现是"本关 ai_opponents = 4，没有对手可测"）。
	# 这类"协程没 await"的坑本文件已经踩过两次（另一次是 load() 类型推断）。
	# 障碍物必须在对手**之前**建好：AI 生成时就要查询车道是否被挡。
	_build_obstacles(track, GameState.current_level())
	await _spawn_opponents(GameState.current_level())
	if _parse_check_args():
		_setup_done = true
		return
	# ⚠ 这里**故意不发车**：发车时机只有一处 —— _process 里的
	# _maybe_start_opponents()（玩家速度达到阈值才发）。
	#
	# 原来这里有一句 `_arm_opponents()`，导致**关卡一加载 AI 就抢跑**，
	# 违反"玩家一动 AI 才动"的规则；更糟的是它在 _parse_check_args() 的 return
	# **之后**，所以 --check=aistart 根本走不到这一行 ——
	# **验收通过，游戏却是错的**。这是本项目最该记的一次教训：
	# 验收和真实游玩走了两条不同的代码路径。
	_parse_shot_args()
	_setup_done = true


## 生成 AI 对手：**实例化 race_car.tscn 后换控制器脚本**。
##
## 为什么不新建一个 ai_car.tscn：车轮硬点/悬挂/摩擦那些数值是实测调出来的
## （race_car.tscn 里有长注释逐条记录），抄一份迟早两边漂移。
## 也不复制关卡参数 —— 极速与抓地力都由本函数从关卡配置算好注入。
##
## ⚠ 顺序陷阱：必须在 add_child **之前** set_script。否则实例里自带的 vehicle.gd
## 会先跑完 _ready（把玩家输入、计圈、复位逻辑全挂到 AI 车上）。
func _spawn_opponents(cfg: LevelConfig) -> void:
	if cfg == null:
		return
	# 玩家在主菜单可以把 AI 对手整个关掉。数量只问 GameState 这一个出口，
	# 免得 main.gd / 菜单各写一份判断而漂移。
	var want := GameState.effective_ai_count()
	if want <= 0:
		if cfg.ai_opponents > 0 and not GameState.ai_enabled:
			print("[main] 玩家已在菜单关闭 AI 对手：本关（本来 %d 台）不生成" % cfg.ai_opponents)
		return
	# `--noai`：同一条赛道、同样的对手配置，只是不生成对手。
	# 这样 --check=phys 才能做**只差对手**的干净 A/B（换关卡比会混入赛道几何的影响）。
	if "--noai" in OS.get_cmdline_user_args():
		print("[main] 检测到 --noai：本关不生成 AI 对手（用于物理开销 A/B）")
		return
	var track := get_node_or_null("Track")
	if track == null:
		printerr("[main] 没有 Track，无法生成 AI 对手")
		return
	var base_scene: PackedScene = load("res://scenes/race_car.tscn")
	var ai_script: GDScript = load("res://scripts/ai_opponent.gd")
	if base_scene == null or ai_script == null:
		printerr("[main] 无法加载 AI 对手所需资源（race_car.tscn / ai_opponent.gd）")
		return
	var holder := Node3D.new()
	holder.name = "Opponents"
	# 真·基线：在**一台对手都还没加进来**的时候测物理耗时。
	# 之前我把"对手怠速"当成基线，那是错的 —— 报告出来的增量会严重偏小。
	_physics_ms_no_ai = await _avg_physics_ms(120, 60)
	add_child(holder)
	var speed := GameState.effective_speed() * cfg.ai_speed_scale
	for i in range(want):
		var ai: VehicleBody3D = base_scene.instantiate()
		# ① 先换脚本，再进树
		ai.set_script(ai_script)
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
		ai.call("setup", track, i, speed, cfg.laps_to_finish, cfg.friction_multiplier, _car)
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
func _arm_opponents() -> void:
	for o in _opponents:
		o.set("armed", true)


## 玩家一动，对手才跟着发动（并排起跑）。
##
## 为什么用**实际速度**而不是"按下了油门"：
##   ① 按键判定在暂停、失焦、手柄断连时不可靠；
##   ② 玩家被别的车推着走也算已经起步；
##   ③ 速度是"真的动起来了"这个事实本身，不需要再解释输入语义。
func _maybe_start_opponents() -> void:
	if _ai_started or _opponents.is_empty() or _car == null:
		return
	var kmh := _car.linear_velocity.length() * 3.6
	if kmh >= ai_start_speed_kmh:
		_ai_started = true
		_arm_opponents()
		print("[main] 玩家已起步（%.1f km/h）→ %d 台 AI 对手同时发动"
			% [kmh, _opponents.size()])


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
	_apply_environment(cfg)
	print("[main] 关卡已加载：%s（%s）椭圆 %.0f×%.0f 路宽 %.0f 抓地力 ×%.2f 极速 %.0f"
		% [cfg.display_name, cfg.difficulty, cfg.radius_x, cfg.radius_z,
		   cfg.road_width, cfg.friction_multiplier, GameState.effective_speed()])


## 天气/夜晚：只动环境（雾、色调、太阳），物理侧的抓地力在车辆里改。
func _apply_environment(cfg: LevelConfig) -> void:
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null:
		return
	var env := we.environment
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	match cfg.weather_type:
		"rain":
			env.background_mode = Environment.BG_COLOR
			env.background_color = Color(0.06, 0.08, 0.12)
			env.fog_enabled = true
			env.fog_light_color = Color(0.10, 0.12, 0.16)
			if sun != null:
				sun.light_energy = 0.35
				sun.light_color = Color(0.7, 0.78, 0.95)
		"snow":
			env.background_mode = Environment.BG_COLOR
			# 雪天背景**刻意压暗成中灰**，而不是原来的惨白（0.72/0.78/0.86）。
			# 原因：白雪花打在惨白天空上等于隐形 —— 这不是"粒子没生成"，
			# 而是对比度不够。真实世界的雪在阴天下能看清，正是因为天空是灰的、
			# 雪花接近白。压暗天空之后，雪花才真的"看得见"。
			env.background_color = Color(0.40, 0.45, 0.53)
			env.fog_enabled = true
			env.fog_light_color = Color(0.52, 0.57, 0.64)
			if sun != null:
				sun.light_energy = 0.7
				sun.light_color = Color(0.86, 0.90, 1.0)
		"sand":
			env.background_mode = Environment.BG_COLOR
			env.background_color = Color(0.62, 0.52, 0.34)
			env.fog_enabled = true
			env.fog_light_color = Color(0.72, 0.62, 0.42)
			if sun != null:
				sun.light_energy = 0.9
				sun.light_color = Color(1.0, 0.92, 0.72)
		_:
			env.fog_enabled = false
	if cfg.fog_density > 0.0:
		env.fog_enabled = true
		env.fog_density = cfg.fog_density
	if cfg.is_night:
		if sun != null:
			sun.light_energy = 0.12
		env.ambient_light_energy = 0.25
	_build_weather_particles(cfg)


## 天气粒子（雨/雪/沙尘）。晴天不生成任何节点。
##
## 挂法：粒子系统作为**玩家车的子节点**，但 `local_coords = false` ——
## 这样发射盒跟着车走（玩家身边永远有雨），而已经生成的粒子留在世界空间，
## 高速行驶时会自然拉出向后掠过的效果，而不是像贴在车头的静态噪点。
##
## 渲染层不用管：小地图相机的 cull_mask 只有 MAP_LAYER，天然看不到这些粒子。
func _build_weather_particles(cfg: LevelConfig) -> void:
	if cfg.weather_type == "clear":
		return
	if _car == null:
		return
	# 重复进入关卡时先清掉旧的
	var old := _car.get_node_or_null("WeatherParticles")
	if old != null:
		old.queue_free()
	var p := GPUParticles3D.new()
	p.name = "WeatherParticles"
	p.local_coords = false
	p.emitting = true
	p.amount = 700
	var mat := ParticleProcessMaterial.new()
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	mat.emission_box_extents = Vector3(26.0, 11.0, 26.0)
	var mesh: Mesh
	var color := Color(1, 1, 1, 0.6)
	match cfg.weather_type:
		"rain":
			p.lifetime = 1.4
			mat.direction = Vector3(0, -1, 0)
			mat.spread = 4.0
			mat.initial_velocity_min = 22.0
			mat.initial_velocity_max = 30.0
			mat.gravity = Vector3(0, -20.0, 0)
			var qm := QuadMesh.new()
			# 雨丝：细长竖条。billboard 让它始终正对镜头，所以永远看得到宽度。
			qm.size = Vector2(0.07, 1.8)
			mesh = qm
			color = Color(0.72, 0.82, 0.98, 0.75)
		"snow":
			p.lifetime = 6.0
			mat.direction = Vector3(0, -1, 0)
			mat.spread = 45.0
			mat.initial_velocity_min = 0.8
			mat.initial_velocity_max = 2.2
			mat.gravity = Vector3(0, -0.9, 0)
			var qs := QuadMesh.new()
			# 雪花用**接近白**，靠"压暗雪天背景"来制造对比度（见 _apply_environment 里
			# 雪天背景那段注释）。之前反过来做（把雪花压暗去迁就惨白天空），
			# 结果两头都是灰的，对比度依然不够、画面还很脏。
			qs.size = Vector2(0.30, 0.30)
			mesh = qs
			color = Color(0.97, 0.98, 1.0, 0.95)
			p.amount = 1100
		_:   # sand
			p.lifetime = 2.4
			mat.direction = Vector3(1, 0, 0)
			mat.spread = 24.0
			mat.initial_velocity_min = 9.0
			mat.initial_velocity_max = 17.0
			mat.gravity = Vector3(0, -0.6, 0)
			var qd := QuadMesh.new()
			qd.size = Vector2(0.3, 0.2)
			mesh = qd
			color = Color(0.80, 0.68, 0.44, 0.7)
	# 粒子一开始就把整个体积铺满，否则开局几秒内只有发射盒附近有东西
	p.preprocess = 3.0
	mat.color = color
	p.process_material = mat
	# ⚠ 关键修正：GPUParticles3D 的粒子外观必须用 **draw_pass_1** 指定。
	# 我第一版是"新建一个 MeshInstance3D 子节点挂上去" —— 那是错的：
	# 子节点只会作为一个普通网格在发射点渲染**一次**，不会给每个粒子画网格。
	# 症状很隐蔽：日志照样打印"天气粒子已生成：雨天（700 粒）"，
	# 但画面上一个雨点都没有（抓图后才看出来）。
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true      # 让 ParticleProcessMaterial.color 生效
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.disable_receive_shadows = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = m
	p.draw_pass_1 = mesh
	# 发射盒中心抬到车上方 8m：extents 11m 意味着粒子分布在 -3m ~ +19m，
	# 落到车两侧和挡风玻璃前都能看见，而不是全悬在镜头外。
	p.position = Vector3(0, 8, 0)
	_car.add_child(p)
	print("[main] 天气粒子已生成：%s（%d 粒，寿命 %.1fs）"
		% [cfg.weather_label(), p.amount, p.lifetime])


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
			await _check_layout()
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
	print("[自检] 卡墙验收：3 个角度 × 内外两侧，全油门怼墙 4 秒，要求结束时速度 > 12 km/h")
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
				for i in range(int(Engine.physics_ticks_per_second) * 4):
					Input.action_press("accelerate")
					await get_tree().physics_frame
					var sp: float = _car.linear_velocity.length() * 3.6
					min_speed = minf(min_speed, sp)
					# 楔入救援日志出现次数（从日志里数不方便，这里直接看位移是否被推过）
				Input.action_release("accelerate")
				var end_speed: float = _car.linear_velocity.length() * 3.6
				var near := track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary
				var ok := end_speed > 12.0
				if not ok:
					fails += 1
				print("[自检]   %s侧 %2.0f° 怼墙：结束速度 %5.1f km/h 最低 %5.1f 偏离 %.2fm  %s"
					% ["内" if side_sign < 0.0 else "外", deg, end_speed, min_speed,
					   float(near["dist"]), "✔ 能继续开" if ok else "✘ 卡住了"])
	print("[自检] 卡墙验收：%d/%d 通过%s" % [cases - fails, cases, " ✔" if fails == 0 else " ✘ 有卡墙"])
	_car.set("auto_reset_out_of_bounds", true)


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


## 自动驾驶跑完整圈：验证
##   ① 计时能正常开始、能正常完成一圈（上圈 != 最快圈的异常不能出现）
##   ② 全程**不会**被出界兜底/自动脱困莫名其妙地重置（用户报的"回到起点前一直重置"）
## 用最简单的追线控制器：目标是中心线前方 45m 的点，朝它打方向，全油门。
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
	while steps < max_steps:
		steps += 1
		# 当前弧长（用车自己的中心线查询，跟车一个口径）
		var near := track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary
		var arc := float(near["arc"])
		var aim := Vector3(track.call("centerline_point", arc + target_ahead))
		# 转向：目标在车头左侧还是右侧
		var fwd: Vector3 = -_car.global_transform.basis.z
		var to_target := aim - _car.global_position
		to_target.y = 0.0
		var right: Vector3 = _car.global_transform.basis.x
		var side := to_target.normalized().dot(right)
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		if side > 0.06:
			Input.action_press("steer_right")
		elif side < -0.06:
			Input.action_press("steer_left")
		Input.action_press("accelerate")
		await get_tree().physics_frame
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
	var last_lap := float(_car.get("lap_last"))
	var best_lap := float(_car.get("lap_best"))
	var reset_loop := _reset_loop_hit()
	print("[自检] 跑圈结束：用时 %.1fs 完成 %d 圈 复位次数=%d"
		% [float(steps) / Engine.physics_ticks_per_second, lap_printed, resets])
	print("[自检] 圈速：上圈=%.3f 最快=%.3f（不变式：最快 ≤ 上圈）" % [last_lap, best_lap])
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
	# 物理耗时基线：加对手之前已经测过（_physics_ms_no_ai），这里再测一次"对手怠速"作对照
	var hz := float(Engine.physics_ticks_per_second)
	var t_idle: Dictionary = await _sample_physics_ms(120, 180)
	var t_idle_avg := float(t_idle.get("avg", 0.0))
	var t_idle_max := float(t_idle.get("max", 0.0))
	# 对照测完再发车，否则②测到的其实是"已经在跑"的对手
	_arm_opponents()
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
	_arm_opponents()
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

	var armed0 := bool(ai.get("armed"))
	print("[自检] AI 诊断开始（走真实游玩路径，不显式发车）")
	print("[自检]   玩家未动时：armed=%s  期望 false（true 说明抢跑）" % str(armed0))
	if armed0:
		printerr("[自检]   ✘ 抢跑：玩家还没动，AI 已经发车了")
		ok = false

	# 玩家起步（真实链路：玩家速度 ≥ ai_start_speed_kmh 时才应该发车）
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
	while t < 22.0:
		await get_tree().physics_frame
		t += 1.0 / hz
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
		if t - last_report >= 2.5:
			last_report = t
			var near: Dictionary = track.call("nearest_on_centerline", ai.global_position, -1.0)
			var dev: float = float(near.get("dist", 0.0))
			# ⚠ 显式标注：ai 是 Node，global_position 是 Variant，
			# 用 := 推断会直接解析失败 → 整个 main.gd 加载不了。
			# 这个坑我在这个文件里已经踩了三次，所以 preflight 现在会真的跑
			# Godot 的解析器（见 lint-gdscript.ps1 的第三类检查）。
			var dist_to_player: float = ai.global_position.distance_to(_car.global_position)
			print("[自检]   t=%4.1fs  AI armed=%s 速度=%5.1f km/h 离中心线=%.2fm 离玩家=%.2fm 玩家=%.1f"
				% [t, str(armed), kmh, dev, dist_to_player, _car.linear_velocity.length() * 3.6])
	Input.action_release("accelerate")

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
	_arm_opponents()
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
## "关卡一加载对手就冲出去了"（原来 _arm_opponents 就是在加载时发的车），
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
	_car.global_transform = _pose_facing(track.call("centerline_point", d) + Vector3(0, 0.6, 0), fwd)
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


## 构造一个"车头（本地 -Z）朝向 dir"的水平位姿
func _pose_facing(pos: Vector3, dir: Vector3) -> Transform3D:
	var f := Vector3(dir.x, 0.0, dir.z).normalized()
	var z_axis := -f
	var x_axis := Vector3.UP.cross(z_axis).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	return Transform3D(Basis(x_axis, y_axis, z_axis), pos)


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


# =================== 赛道布局验收（--check=layout）===================
#
# 为什么必须先把这一段写出来（TDD）：
#   路段 DSL 是"文本 + 运行时解析"，它的代价就是**没有编译期类型检查**。
#   把代价补回来的唯一办法，是让每条规则都有一条**会自动跑的断言**。
#   所以本项检查分两段：
#     ① 解析器用例组：一批合法/非法的 DSL 串，逐个断言"能解析"或"必须报错"；
#     ② 逐关验收：读关卡自己的 layout，断言闭环、最小弯半径、曲率体检、往返唯一性。
#   解析器（scripts/track_layout.gd）还没写时，本项检查会**明确报红**而不是假通过。

## 解析器用例通过计数
var _layout_pass := 0
## 解析器用例失败计数
var _layout_fail := 0
## 布局验收的失败项（逐关几何）
var _layout_geom_fail := 0


func _check_layout() -> void:
	_layout_pass = 0
	_layout_fail = 0
	_layout_geom_fail = 0
	var mod: GDScript = load("res://scripts/track_layout.gd")
	# ⚠ 防"假绿"闸门（踩过一次，很难发现）：
	#   track_layout.gd 里只要有一处语法/作用域错误，load() 仍然返回一个**非 null** 的
	#   GDScript，但它**没有 parse/build 这些方法**。于是每个用例都用 `call()` 调一个
	#   不存在的方法 → 计数全是 0 → 最后打印"解析用例 0 个全过" → **验收显示通过**！
	#   所以这里必须显式确认模块真的可用、并且断言条数够多。
	if mod == null or not mod.has_method("parse") or not mod.has_method("build"):
		_layout_fail += 1
		printerr("[自检]   ✘ track_layout.gd 不可用（load 到了但缺少 parse/build：多半是脚本里有语法错误）")
		printerr("[自检] 赛道布局验收 ✘ 解析器不可用")
		return
	_check_layout_parser(mod)
	await _check_layout_level(mod)
	if _layout_pass < 40:
		_layout_fail += 1
		printerr("[自检]   ✘ 解析器用例只跑了 %d 条（应 ≥40）—— 用例没生效，本次结果无效" % _layout_pass)
	if _layout_fail == 0 and _layout_geom_fail == 0:
		print("[自检] 赛道布局验收 ✔ 解析用例 %d 个全过 + 本关布局全部达标" % _layout_pass)
	else:
		printerr("[自检] 赛道布局验收 ✘ 解析用例失败 %d 个、本关几何失败 %d 项"
			% [_layout_fail, _layout_geom_fail])


## 断言：这个串必须能解析，且分段数为 n
func _layout_ok(mod: GDScript, text: String, n: int, label: String) -> void:
	var r: Dictionary = mod.call("parse", text)
	if not bool(r.get("ok", false)):
		_layout_fail += 1
		print("[自检]   ✘ 合法串被拒：「%s」(%s) → %s" % [text, label, str(r.get("error", "?"))])
		return
	var segs: Array = r.get("segments", [])
	if segs.size() != n:
		_layout_fail += 1
		print("[自检]   ✘ 「%s」(%s) 分段数 %d ≠ 期望 %d" % [text, label, segs.size(), n])
		return
	_layout_pass += 1


## 断言：这个串必须**报错**（残留 token / 参数错 / 数值非法 / 拼错 kind …）
func _layout_err(mod: GDScript, text: String, label: String) -> void:
	var r: Dictionary = mod.call("parse", text)
	if bool(r.get("ok", false)):
		_layout_fail += 1
		print("[自检]   ✘ 非法串被接受：「%s」(%s) —— 解析器有漏洞，必须报错" % [text, label])
		return
	_layout_pass += 1


## 断言：这个串能闭环（残差 ≤0.1m），且曲率体检通过
func _layout_close_ok(mod: GDScript, text: String, mode: String, label: String) -> void:
	var r: Dictionary = mod.call("build", text, mode, 2.0)
	if not bool(r.get("ok", false)):
		_layout_fail += 1
		print("[自检]   ✘ 应当闭环却失败：「%s」(%s) → %s" % [text, label, str(r.get("error", "?"))])
		return
	var gap := float(r.get("closure_gap", 999.0))
	if gap > 0.1:
		_layout_fail += 1
		print("[自检]   ✘ 「%s」(%s) 闭环残差 %.3fm > 0.10m" % [text, label, gap])
		return
	_layout_pass += 1


## 断言：这个串必须被拒（净转角不对 / 无法闭环 / 曲率超限 / 护栏自交 …）
func _layout_build_err(mod: GDScript, text: String, mode: String, label: String) -> void:
	var r: Dictionary = mod.call("build", text, mode, 2.0)
	if bool(r.get("ok", false)):
		_layout_fail += 1
		print("[自检]   ✘ 应当报错却通过：「%s」(%s) 残差 %.3fm"
			% [text, label, float(r.get("closure_gap", 0.0))])
		return
	_layout_pass += 1


## ① 解析器用例组。合法与非法串都要覆盖，尤其是"残留 token"这一类。
func _check_layout_parser(mod: GDScript) -> void:
	print("[自检] 布局验收 ① 解析器用例组")
	# ---- 合法 ----
	_layout_ok(mod, "straight:120", 1, "单直道")
	_layout_ok(mod, " arc:70:90 ", 1, "前后空格")
	_layout_ok(mod, "straight:110, arc:70:90, straight:60, arc:70:90", 4, "L1 半条")
	_layout_ok(mod, "arc:70:-90", 1, "负角度=右转")
	_layout_ok(mod, "hairpin:24", 1, "发夹（只收半径）")
	_layout_ok(mod, "chicane:30:4", 1, "S 弯")
	_layout_ok(mod, "sweeper:95:100", 1, "高速弯")
	_layout_ok(mod, "ellipse:320:200", 1, "阶段1 对照用的椭圆")
	_layout_ok(mod, "ellipse:320:200:3:18", 1, "椭圆带 S 弯参数")
	# ---- 非法：残留 token / 分隔符 ----
	_layout_err(mod, "straight:120,", "尾随逗号（残留 token）")
	_layout_err(mod, "straight:120 arc:70:90", "缺逗号")
	_layout_err(mod, "straight:120，arc:70:90", "中文逗号")
	_layout_err(mod, "straight:120: arc:70:90", "多余冒号")
	_layout_err(mod, "straight:120, , arc:70:90", "空分段")
	_layout_err(mod, "", "空串")
	# ---- 非法：kind / 参数个数 ----
	_layout_err(mod, "straightt:120", "拼错 kind")
	_layout_err(mod, "直线:120", "中文 kind")
	_layout_err(mod, "straight", "缺参数")
	_layout_err(mod, "straight:120:5", "参数过多")
	_layout_err(mod, "arc:70", "arc 缺角度")
	_layout_err(mod, "arc:70:90:10", "arc 参数过多")
	_layout_err(mod, "hairpin:24:180", "hairpin 只收一个参数")
	_layout_err(mod, "chicane:30", "chicane 缺偏移")
	# ---- 非法：数值 ----
	_layout_err(mod, "straight:abc", "非数字")
	_layout_err(mod, "straight:0", "长度 0")
	_layout_err(mod, "straight:-5", "负长度")
	_layout_err(mod, "arc:0:90", "半径 0")
	_layout_err(mod, "arc:-70:90", "负半径")
	_layout_err(mod, "arc:70:400", "角度超过 270")
	_layout_err(mod, "arc:70:0", "角度 0")
	_layout_err(mod, "straight:nan", "NaN")
	_layout_err(mod, "straight:inf", "INF")
	_layout_err(mod, "chicane:30:120", "chicane 偏移 ≥ 4R（无解）")

	# ---- 闭环：必须能解的 ----
	print("[自检] 布局验收 ① 闭环与曲率")
	_layout_close_ok(mod, "straight:110, arc:70:90, straight:60, arc:70:90", "mirror180", "L1 半条点对称加倍")
	_layout_close_ok(mod, "straight:90, chicane:30:4, straight:50, hairpin:18", "mirror180", "L5 半条点对称加倍")
	# L3 的实际设计（长度由 tools/layout_closure.py 解出，残差 0.04m）
	_layout_close_ok(mod, "straight:164.0, arc:20.0:90, straight:38.5, chicane:30.0:4.0, arc:20.0:90, straight:160.0, arc:20.0:90, straight:60.0, arc:20.0:90",
		"solve", "L3 非对称（工具解算闭环）")
	# L4 的实际设计（工具解算，残差 0.05m）
	_layout_close_ok(mod, "straight:260.0, sweeper:110.0:120, straight:85.0, arc:80.0:80, straight:297.5, arc:70.0:120, straight:60.0, arc:60.0:40",
		"solve", "L4 非对称（工具解算闭环）")
	# ---- 闭环：必须报错的 ----
	_layout_build_err(mod, "straight:100, arc:50:90", "solve", "净转角只有 90°，不可能闭环")
	_layout_build_err(mod, "straight:100, arc:50:90, straight:100, arc:50:90, straight:100, arc:50:90, straight:100",
		"solve", "净转角 270°，差 90°")
	_layout_build_err(mod, "straight:100, hairpin:20, straight:130, hairpin:20", "solve",
		"两条直道互相平行（0° 与 180°）→ 只有 1 个自由度，无法闭环")
	# L2 的第一版手写设计：净转角对（360°）但位置完全没闭合（残差 340m）。
	# 这条用例证明"净转角对 ≠ 闭环"，也证明解算器不会去糊一个 340m 的残差。
	_layout_build_err(mod, "straight:220, sweeper:95:100, straight:60, sweeper:70:80, straight:35, hairpin:24, straight:90",
		"solve", "净转角对但残差 340m → 必须报「长度没算过」而不是解出负长度")
	_layout_build_err(mod, "straight:20, arc:8:90, straight:20, arc:8:90, straight:20, arc:8:90, straight:20, arc:8:90",
		"solve", "半径 8m → 每 2m 航向步长超限（曲率体检必须拦住）")
	_layout_build_err(mod, "straight:100, arc:4:180, straight:60, arc:4:180", "exact",
		"半径 4m → 航向步长与内护栏半径都不合法")


## ② 逐关验收：读本关的 layout 真串，做几何体检。
func _check_layout_level(mod: GDScript) -> void:
	var track := get_node_or_null("Track")
	if track == null:
		_layout_geom_fail += 1
		printerr("[CHECK] 找不到 Track 节点")
		return
	var cfg: LevelConfig = GameState.current_level()
	var raw = track.get("layout")
	var layout := str(raw)
	if raw == null or layout.is_empty():
		_layout_geom_fail += 1
		printerr("[自检]   ✘ 本关还没迁移到路段 DSL（track.layout 为空/不存在，读到「%s」）" % layout)
		return
	var mode := str(track.get("closure_mode"))
	if mode.is_empty() or mode == "<null>":
		mode = "solve"
	print("[自检] 布局验收 ② 本关 layout = 「%s」  闭环模式 = %s" % [layout, mode])
	var r: Dictionary = mod.call("build", layout, mode, 2.0)
	if not bool(r.get("ok", false)):
		_layout_geom_fail += 1
		printerr("[自检]   ✘ 本关布局不合法：%s" % str(r.get("error", "?")))
		return
	var gap := float(r.get("closure_gap", 999.0))
	var min_r := float(r.get("min_radius", 0.0))
	var step_deg := float(r.get("max_heading_step_deg", 999.0))
	var dkappa := float(r.get("max_dkappa", 999.0))
	print("[自检]   长度 %.1fm  闭环残差 %.4fm  最小弯半径 %.1fm  最大航向步长 %.2f°/2m  最大曲率跳变 %.4f/m"
		% [float(r.get("length", 0.0)), gap, min_r, step_deg, dkappa])
	# 诊断：点列规模与实际几何（长度算出 0 时靠这几行定位是"点列退化"还是"烘焙失败"）
	print("[自检]   点列：控制点 %d 个、采样点 %d 个；首点 %s 中点 %s 末点 %s"
		% [int(r.get("control_points", -1)), int(r.get("sample_points", -1)),
		   str(r["points"][0]), str(r["points"][r["points"].size() / 2]),
		   str(r["points"][r["points"].size() - 1])])
	if gap > 0.1:
		_layout_geom_fail += 1
		printerr("[自检]   ✘ 闭环残差 %.3fm > 0.10m" % gap)
	var floor_r := 15.0
	if cfg != null:
		# min_corner_radius 是逐关字段（阶段 3 才加进 LevelConfig）。取不到就用保守默认值，
		# **不能**直接 float(cfg.get(...))：属性不存在时 get() 返回 null，float(null) 会报错。
		var fr = cfg.get("min_corner_radius")
		if fr != null:
			floor_r = float(fr)
	if min_r < floor_r:
		_layout_geom_fail += 1
		printerr("[自检]   ✘ 最小弯半径 %.1fm < 本关下限 %.1fm" % [min_r, floor_r])
	if step_deg > 8.0:
		_layout_geom_fail += 1
		printerr("[自检]   ✘ 每 2m 航向步长 %.2f° > 8.0°（当年「接点曲率突变把车弹飞」就是这么来的）" % step_deg)
	if dkappa > 0.07:
		_layout_geom_fail += 1
		printerr("[自检]   ✘ 最大曲率跳变 %.4f/m > 0.070（直道↔圆弧接点太硬；阈值与 track_layout.gd 的 MAX_DKAPPA 保持一致）" % dkappa)
	# 弯道半径分档统计（便于核对设计意图）
	var hist: Dictionary = r.get("radius_histogram", {})
	if not hist.is_empty():
		var parts := PackedStringArray()
		for k in hist.keys():
			parts.append("%s×%d" % [str(k), int(hist[k])])
		print("[自检]   弯道半径分档：%s" % ", ".join(parts))
	# 往返唯一性：发夹弯两侧 XZ 距离很近，必须仍能认回自己的弧长
	_layout_round_trip(track)


## 往返唯一性：对每 2m 一个站，用中心线点反查弧长，必须认回自己（误差 ≤2m、朝向一致）。
## 这是发夹弯/连续 S 弯特有的风险：两侧 XZ 距离可能只有几十米，
## 反查一旦认到"对面那条腿"，复位就会把车头掉转 180°。
func _layout_round_trip(track: Node) -> void:
	var total := float(track.call("road_length"))
	var step := 2.0
	var count := 0
	var worst_arc := 0.0
	var worst_dot := 1.0
	var s := 0.0
	while s < total - step:
		var p: Vector3 = track.call("centerline_point", s)
		var fwd: Vector3 = track.call("centerline_forward", s)
		var near: Dictionary = track.call("nearest_on_centerline", p, s)
		var arc := float(near.get("arc", -1.0))
		var diff := absf(fposmod(arc - s + total * 0.5, total) - total * 0.5)
		var nfwd: Vector3 = near.get("forward", Vector3.FORWARD)
		var dot := nfwd.dot(fwd)
		worst_arc = maxf(worst_arc, diff)
		worst_dot = minf(worst_dot, dot)
		count += 1
		s += step
	print("[自检]   往返唯一性：%d 个站点，弧长最大偏差 %.2fm（判据 ≤2.0m），朝向最小点积 %.3f（判据 >0.90）"
		% [count, worst_arc, worst_dot])
	if worst_arc > 2.0 or worst_dot <= 0.9:
		_layout_geom_fail += 1
		printerr("[自检]   ✘ 反查唯一性不达标：发夹弯两侧存在歧义（复位可能把车头掉转 180°）")


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


## 截图模式。
##
## 为什么不挂在 --script 上：本机 Godot 4.4.1 里 **`--path` 与 `--script` 同时使用必崩**
## （signal 11，连一个只 print 然后 quit 的空脚本都崩；而单独用 --script 不带 --path
## 也时好时坏）。所以截图能力改挂在主场景里，走的是完全没问题的 `--path` 路径。
##
## 用法：
##   godot --path <工程> -- --shot --shot-frames=150 --shot-hold=120 --shot-out=<绝对路径>
##
## 注意**不能加 --headless**（4.4.1 里 --headless 不是有效参数，会被忽略并直接跑主场景）；
## 另外窗口化运行必须用 `start` 分离启动，前台直接跑会段错误。
## 窗口会真的出现几秒，到点存 PNG 后自动退出。
##   --shot-frames=N  第 N 帧截图（默认 150，约 2.5 秒）
##   --shot-hold=N    前 N 帧模拟按住 W（行驶状态，默认 0）
##   --shot-steer=N   前 N 帧模拟按住 A（打方向，默认 0。配合 hold=0 可让车停着打方向，
##                    用来单独检查前轮有没有偏转）
##   --shot-view=N    直接切到第 N 个视角（0 第一人称 / 1 第二人称 / 2 第三人称）
##   --shot-out=PATH  输出路径，默认写到工程目录的上一级 godot-shot.png
func _parse_shot_args() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--shot"):
		return
	_shot_mode = true
	for a in args:
		if a.begins_with("--shot-frames="):
			_shot_frames = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-hold="):
			_shot_hold = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-steer="):
			_shot_steer = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-view="):
			_shot_view = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-out="):
			_shot_out = a.split("=", true, 1)[1]
	if _shot_out.is_empty():
		_shot_out = ProjectSettings.globalize_path("res://").path_join("..").simplify_path().path_join("godot-shot.png")
	if _shot_view >= 0:
		var cam := get_node_or_null("ChaseCamera")
		if cam != null and cam.has_method("set_view_mode"):
			cam.call("set_view_mode", _shot_view)
	print("[截图] 开关已打开：第 %d 帧存到 %s（按住 W %d 帧 / 按住 A %d 帧 / 视角 %d）"
		% [_shot_frames, _shot_out, _shot_hold, _shot_steer, _shot_view])


func _process(_delta: float) -> void:
	# AudioStreamGenerator 是**流式**的：只在启动时灌一次的话，缓冲播完就彻底静音。
	# 实测症状就是"刚进去有一声轰鸣，几秒后没声了"。必须每帧续填。
	if _engine_playback != null:
		_fill_engine_buffer()

	# 玩家一起步，并排的对手就发动。
	# 必须放在验收模式的 return **之前**，否则验收里这条链路永远走不到。
	# aistart / aidiag 这两项检查就是要验**真实游玩的那条链路**，
	# 所以它们和正常游玩一样允许自动发车；其它检查自己控制发车时机（默认不自动发车）。
	if _check.is_empty() or _check == "aistart" or _check == "aidiag":
		_maybe_start_opponents()

	# 验收模式：跑检查、写日志、退出
	if not _check.is_empty():
		_check_tick()
		return

	if not _shot_mode:
		return
	_shot_frame += 1
	if _shot_frame <= _shot_hold:
		Input.action_press("accelerate")
	elif _shot_frame == _shot_hold + 1:
		Input.action_release("accelerate")
	# 正数 = 按住 A（左舵），负数 = 按住 D（右舵），0 = 不打方向
	if _shot_steer != 0:
		var act := "steer_left" if _shot_steer > 0 else "steer_right"
		var n := absi(_shot_steer)
		if _shot_frame <= n:
			Input.action_press(act)
		elif _shot_frame == n + 1:
			Input.action_release(act)
	if _shot_frame < _shot_frames:
		return

	_shot_mode = false
	# 顺便把关键状态打出来，便于和画面对照
	var car := get_node_or_null("RaceCar")
	if car is VehicleBody3D:
		print("[截图] 车 pos=%s  steering=%.3f rad  车速=%.1f km/h"
			% [(car as Node3D).global_position, (car as VehicleBody3D).steering,
			   (car as VehicleBody3D).linear_velocity.length() * 3.6])
	# 相机诊断：用来量"相机会不会自己往车尾凑"
	var cam := get_node_or_null("ChaseCamera")
	if cam is Camera3D and car is Node3D:
		var dist := (cam as Camera3D).global_position.distance_to((car as Node3D).global_position)
		print("[截图] 相机 pos=%s  离车 %.2f m  高度 %.2f m"
			% [(cam as Camera3D).global_position, dist, (cam as Camera3D).global_position.y])
	var img := get_viewport().get_texture().get_image()
	if img == null:
		printerr("[截图] 拿不到 viewport 图像")
	else:
		var err := img.save_png(_shot_out)
		print("[截图] save_png -> %d  尺寸=%s  路径=%s" % [err, img.get_size(), _shot_out])
	print("[截图] 累计推送音频帧 = %d（应远大于单个缓冲 0.5s×22050≈11025，说明是流式续填而非一次灌满）"
		% _engine_frames_pushed)
	print("[截图] 结束，退出")
	get_tree().quit()


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


## 底噪基频（怠速）。车体的 pitch_scale 会在这个基础上整体升降。
const ENGINE_BASE_HZ := 60.0

# 占位引擎声的流式缓冲状态
var _engine_playback: AudioStreamGeneratorPlayback = null
var _engine_mix_rate := 22050.0
var _engine_phase := 0.0
var _engine_frames_pushed := 0
var _engine_rng := RandomNumberGenerator.new()


## 没有引擎音频文件时，用生成器合成一个能出声的占位音源。
##
## **AudioStreamGenerator 是流式的**。原来的写法只在 _ready 里灌一次缓冲，
## 那 0.5 秒播完就再也没有数据了 —— 表现就是"刚进去有一声轰鸣，几秒后彻底静音"。
## 现在改成每帧在 _process 里续填（见 _fill_engine_buffer）。
func _setup_placeholder_engine_sound() -> void:
	var player: AudioStreamPlayer3D = _car.get_node_or_null("EngineSound")
	if player == null:
		return
	if player.stream is AudioStreamGenerator:
		var gen: AudioStreamGenerator = player.stream
		_engine_mix_rate = gen.mix_rate
		_engine_playback = player.get_stream_playback()
		if _engine_playback == null:
			return
		_engine_rng.seed = 20240517
		_fill_engine_buffer()
		print("[main] 已启用占位引擎声（Generator 流式合成，每帧续填缓冲）。想要真实轰鸣请给 EngineSound.stream 换 wav")


## 把当前所有空位填满：低频锯齿波（模拟气缸爆发）+ 一点噪声。
## 每帧调用，缓冲区就不会见底。
func _fill_engine_buffer() -> void:
	var frames := _engine_playback.get_frames_available()
	if frames <= 0:
		return
	for i in frames:
		_engine_phase += ENGINE_BASE_HZ / _engine_mix_rate
		if _engine_phase >= 1.0:
			_engine_phase -= 1.0
		var saw := _engine_phase * 2.0 - 1.0
		var noise := _engine_rng.randf_range(-0.15, 0.15)
		var sample := clampf(saw * 0.35 + noise, -1.0, 1.0)
		_engine_playback.push_frame(Vector2(sample, sample))
	_engine_frames_pushed += frames
