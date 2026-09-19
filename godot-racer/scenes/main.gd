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

## 本关的 AI 对手（ai_opponents 台）。空数组 = 本关没有对手。
var _opponents: Array = []
## 加对手**之前**测到的物理帧耗时（毫秒）。-1 表示没测到。
var _physics_ms_no_ai := -1.0
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
	await _spawn_opponents(GameState.current_level())
	if _parse_check_args():
		_setup_done = true
		return
	# 正常游玩：对手立即发车。验收模式则在上面就 return 了 ——
	# 它需要先测"对手怠速"的物理开销，由检查自己决定何时发车。
	_arm_opponents()
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
	if cfg == null or cfg.ai_opponents <= 0:
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
	for i in range(cfg.ai_opponents):
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
		ai.call("setup", track, i, speed, cfg.laps_to_finish, cfg.friction_multiplier)
		# 故意**不**在这里发车：验收脚本要先测"对手怠速"的物理开销，
		# 而且发车时机应该由游戏流程（发车倒计时/检查）决定，不该写死在生成里。
		_opponents.append(ai)
	print("[main] 已生成 %d 台 AI 对手（极速 %.0f km/h = 本关建议 %.0f × 倍率 %.2f，抓地力 ×%.2f）"
		% [cfg.ai_opponents, speed, GameState.effective_speed(),
		   cfg.ai_speed_scale, cfg.friction_multiplier])


## 让所有对手发车。生成时故意不发车，由这里（游戏流程 / 验收脚本）决定时机。
func _arm_opponents() -> void:
	for o in _opponents:
		o.set("armed", true)


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
			env.background_color = Color(0.72, 0.78, 0.86)
			env.fog_enabled = true
			env.fog_light_color = Color(0.85, 0.88, 0.94)
			if sun != null:
				sun.light_energy = 0.8
				sun.light_color = Color(0.88, 0.92, 1.0)
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
		_:
			print("[CHECK] 未知的检查项：%s" % _check)
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
	var laps_ok := lap_printed >= 2 and not is_equal_approx(last_lap, best_lap)
	print("[自检] 跑圈结束：用时 %.1fs 完成 %d 圈 复位次数=%d"
		% [float(steps) / Engine.physics_ticks_per_second, lap_printed, resets])
	print("[自检] 圈速：上圈=%.3f 最快=%.3f（跑满 2 圈后两者应不同）" % [last_lap, best_lap])
	if lap_printed >= 2 and resets == 0 and laps_ok:
		print("[自检] 跑圈验收 ✔ 连续多圈计时正常、无意外重置")
	elif lap_printed < 2:
		printerr("[自检] 跑圈验收 ✘ 6 分钟内没跑完 2 圈（完成 %d 圈）" % lap_printed)
	else:
		printerr("[自检] 跑圈验收 ✘ 复位 %d 次 / 圈速异常（上圈=%.3f 最快=%.3f）"
			% [resets, last_lap, best_lap])


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
		print("[自检] 本关「%s」的 ai_opponents = %d，没有对手可测。"
			% [cfg.display_name if cfg != null else "?", cfg.ai_opponents if cfg != null else 0])
		print("[自检] 对手验收 ⊘ 跳过（用 --level=5 这类有对手的关卡来跑）")
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


## 天气抓地力验收：**证明倍率真的进了物理**，而不只是换了个环境颜色。
##
## 做法：同一初始条件下（同速度、直线、满舵）分别用 ×1.0 和低倍率跑一段，
## 比较**横向滑移/车头实际转过的角度**：抓地力低时车会更滑、转向响应更差。
## 判定：两次结果的差异必须 ≥ 25%，否则说明倍率没生效（或链路断了）。
func _check_friction() -> void:
	var cfg: LevelConfig = GameState.current_level()
	var mult := cfg.friction_multiplier if cfg != null else 1.0
	var lo := clampf(mult * 0.5, 0.2, 1.0) if mult > 0.45 else 0.2
	print("[自检] 抓地力验收：对比 ×1.00 与 ×%.2f（本关配置 ×%.2f）" % [lo, mult])
	var hi_res := await _friction_probe(1.0)
	var lo_res := await _friction_probe(lo)
	var hi_lat := float(hi_res.get("lateral", 0.0))
	var lo_lat := float(lo_res.get("lateral", 0.0))
	print("[自检]   ×1.00：侧滑 %.3f m，用时 %.2f s，末速 %.0f km/h"
		% [hi_lat, hi_res.get("time", 0.0), hi_res.get("speed", 0.0)])
	print("[自检]   ×%.2f：侧滑 %.3f m，用时 %.2f s，末速 %.0f km/h"
		% [lo, lo_lat, lo_res.get("time", 0.0), lo_res.get("speed", 0.0)])
	if hi_lat < 0.05 and lo_lat < 0.05:
		printerr("[自检] 抓地力验收 ✘ 两种倍率都没有产生侧滑，探针本身可能没生效")
		return
	var ratio := lo_lat / maxf(hi_lat, 0.001)
	var diff := absf(ratio - 1.0)
	print("[自检]   侧滑比（低/高）= %.3f，差异 %.0f%%（要求 ≥ 25%%）" % [ratio, diff * 100.0])
	if diff >= 0.25:
		print("[自检] 抓地力验收 ✔ 倍率确实改变了物理表现")
	else:
		printerr("[自检] 抓地力验收 ✘ 差异只有 %.0f%%，倍率很可能没进物理" % [diff * 100.0])


## 抓地力探针：把车放回起点，全油门直线加速到约 60 km/h，然后**满舵 1.2 秒**，
## 测量这段时间内车相对初始航向的横向漂移距离。
func _friction_probe(mult: float) -> Dictionary:
	var track := get_node_or_null("Track")
	if track == null or _car == null:
		return {"lateral": 0.0, "time": 0.0, "speed": 0.0}
	_car.call("apply_level_setup", GameState.effective_speed(), 99, mult)
	_car.call("reset_to_track")
	await get_tree().physics_frame
	await get_tree().physics_frame
	var start := _car.global_position
	var fwd := -_car.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	# 加速阶段
	Input.action_press("accelerate")
	var hz := float(Engine.physics_ticks_per_second)
	var t_start := Time.get_ticks_msec()
	for i in range(int(hz * 3.0)):
		await get_tree().physics_frame
		if _car.linear_velocity.length() * 3.6 > 60.0:
			break
	# 满舵阶段：只打方向，不松油
	Input.action_press("steer_left")
	for i in range(int(hz * 1.2)):
		await get_tree().physics_frame
	Input.action_release("steer_left")
	Input.action_release("accelerate")
	var elapsed := (Time.get_ticks_msec() - t_start) / 1000.0
	var delta := _car.global_position - start
	delta.y = 0.0
	# 横向分量 = 位移在"初始航向的垂直方向"上的投影
	var right := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var lateral := absf(delta.dot(right))
	var res := {"lateral": lateral, "time": elapsed,
		"speed": _car.linear_velocity.length() * 3.6, "start": start}
	# 复位，避免影响后续检查
	var cfg: LevelConfig = GameState.current_level()
	_car.call("apply_level_setup", GameState.effective_speed(),
		cfg.laps_to_finish if cfg != null else 2,
		cfg.friction_multiplier if cfg != null else 1.0)
	_car.call("reset_to_track")
	return res


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
