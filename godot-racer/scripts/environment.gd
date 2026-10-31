extends RefCounted
## 关卡环境：天气/夜晚的视觉侧（雾、色调、太阳）+ 天气粒子（雨/雪/沙尘）
## + 天气环境音（雨声，见文件末尾"天气环境音"一节）。
##
## 2026-10-12 SPLIT-ENV-001：从 scenes/main.gd 整块拆出，**纯迁移、行为零变化** ——
## 逻辑、数值常量、print 文案、注释全部原样搬入，没有第二份实现。
## 唯一的结构变化：原先直接读 Main 场景成员（WorldEnvironment / Sun / 玩家车）
## 的地方改为**参数传入**，本模块不持有任何场景状态（零共享成员）。
## 物理侧的抓地力仍在车辆里改，不归这里管。
##
## ⚠ 为什么没有 class_name（与 racing_line.gd 同一约定）：
##   本项目的验收闸门（parse-check / run-check / run-all-checks）在**无编辑器**环境里
##   跑 Godot，而 class_name 的全局注册表（.godot/global_script_class_cache.cfg）
##   **只有编辑器会重建**。2026-10-12 实测：新增 class_name 后 --check-only 与游戏
##   运行双双报 `Identifier "X" not declared in the current scope`（该机器的缓存是
##   9-23 的旧快照，删掉缓存连 LevelConfig 都解析不了）。因此消费方一律用
##   `const X := preload("res://scripts/environment.gd")` 引用本模块
##   （与 ai_opponent.gd 里的 RacingLine 完全同一 pattern），不依赖全局类缓存。

## 天气/夜晚：只动环境（雾、色调、太阳），物理侧的抓地力在车辆里改。
static func apply_environment(cfg: LevelConfig, we: WorldEnvironment, sun: DirectionalLight3D, car: Node3D) -> void:
	if we == null or we.environment == null:
		return
	# 每次比赛独立，防止雨夜/诊断中的环境参数串到随后晴天关卡。
	# 这里只改Environment标量并替换sky；不修改源环境的嵌套资源。
	# 深复制会创建同帧即被替换的临时Sky，在4.4.1 Compatibility下留下辐照纹理。
	we.environment=we.environment.duplicate(false)
	var env := we.environment
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
		if cfg.weather_type == "rain":
			# 雨夜保留冷色夜空；用明确的环境补光保证远处路面和黑色车身可读。
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.43,0.50,0.65)
			env.ambient_light_energy = 0.65
			if sun != null: sun.light_energy = 0.20
	preload("res://scripts/theme_sky.gd").apply(cfg,env,sun)
	build_weather_particles(cfg, car)


## 天气粒子（雨/雪/沙尘）。晴天不生成任何节点。
##
## 挂法：粒子系统作为**玩家车的子节点**，但 `local_coords = false` ——
## 这样发射盒跟着车走（玩家身边永远有雨），而已经生成的粒子留在世界空间，
## 高速行驶时会自然拉出向后掠过的效果，而不是像贴在车头的静态噪点。
##
## 天气粒子沿用主视角渲染层。
static func build_weather_particles(cfg: LevelConfig, car: Node3D) -> void:
	if cfg.weather_type == "clear":
		return
	if car == null:
		return
	# 重复进入关卡时先清掉旧的
	var old := car.get_node_or_null("WeatherParticles")
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
			qs.size = Vector2(0.14, 0.14)
			mesh = qs
			color = Color(0.97, 0.98, 1.0, 0.70)
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
	if cfg.weather_type == "rain":
		# 雨丝保留700粒与原颜色/速度，逐顶点受光，经过暖色檐灯时有真实明暗变化。
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.albedo_color = Color(0.82,0.88,0.95,0.55)
	if cfg.weather_type == "snow":
		m.albedo_texture = preload("res://scripts/snow_visuals.gd").flake_texture()
	mesh.material = m
	p.draw_pass_1 = mesh
	# 发射盒中心抬到车上方 8m：extents 11m 意味着粒子分布在 -3m ~ +19m，
	# 落到车两侧和挡风玻璃前都能看见，而不是全悬在镜头外。
	p.position = Vector3(0, 8, 0)
	car.add_child(p)
	print("[main] 天气粒子已生成：%s（%d 粒，寿命 %.1fs）"
		% [cfg.weather_label(), p.amount, p.lifetime])


## ==================== 天气环境音（雨声）====================
##
## 2026-10 REL-STEP2C：把 assets/audio/rain_loop.ogg 真正接进游戏，走 **Ambient** 总线
## （总线结构在 default_bus_layout.tres：Master 下挂 SFX / BGM / Ambient，初始均 0 dB；
## 引擎声归 SFX、雨声归 Ambient、BGM 本轮留空不接音乐）。
##
## 和上面的视觉/粒子侧放在同一个模块，是因为"哪种天气配什么效果"这份知识只该有一份 ——
## 拆成两个模块就要在两个地方各自解释一遍 weather_type。
##
## 这一次接线要盯死的三个 bug（按踩中概率排序）：
##
## ① **叠音**（最容易犯）：多次进入同一关会叠加多个 AudioStreamPlayer，声音越来越吵。
##    防法：播放器以**固定名字**挂在玩家车下，每次 apply 时**复用已存在的那一个**。
##    ⚠ 这里**不能**照抄粒子那套"先 queue_free 旧的、再 add_child 新的"：
##      queue_free 要到本帧末尾才真正摘除节点，紧接着 add_child 一个同名新节点，
##      下一次 get_node_or_null 命中的仍是那个"待删"的旧节点 —— 于是每次重入都
##      留下一个孤儿播放器。**复用才是防叠音，删了重建不是。**
##
## ② **只雨天播**：由 apply_weather_audio() 按 cfg.weather_type 裁决；非雨天走 release()，
##    把上一关（或上一次）留下的雨声一起收掉，不能让它跨关残留。
##
## ③ **暂停不停**：不能想当然地认为"暂停菜单弹出来了雨就该停"，也不要想当然地认为
##    "引擎会自己停"。这次**实测过**（4.4.1，方法见 tests/ 里的裸播放器探针）：
##      `get_tree().paused = true` → AudioStreamPlayer 的 playing **确实**翻成 false；
##      `paused = false` → 又自己翻回 true（before=true / during=false / after=true）。
##    但这是**引擎实现细节，不是契约**，换版本/换音频驱动都可能变。所以这里仍然显式翻
##    `stream_paused`（验收断言盯的就是它，机器可读、不依赖引擎内部行为），恢复时再补
##    一句"没在播就接着播"。宁可多一层保险，也别把"暂停一次雨声会不会永久没了"
##    押在一条没写进文档的引擎行为上。
##
## 约定与视觉侧一致：无 class_name、不 get_node 全局路径（只在注入进来的 car 上找自己
## 挂的节点，与 build_weather_particles 找 WeatherParticles 同一种用法）、不 get_tree、
## 不用 await。释放靠"播放器是车的子节点，车随场景销毁"，release() 是显式出口。

## 雨声播放器的挂点名。防叠音全靠它：同名即复用。
const RAIN_PLAYER_NAME := "RainAmbient"
## 雨声走 Ambient 总线（与引擎声的 SFX 分开，方便将来单独调环境音音量）。
const RAIN_BUS := "Ambient"
## 雨声素材。署名见仓库根 THIRD-PARTY-LICENSES.md（Sounds by SoundDino）。
const RAIN_STREAM_PATH := "res://assets/audio/rain_loop.ogg"

## 当前挂载的雨声播放器（同一场景至多一个）。
var _rain_player: AudioStreamPlayer = null
## "该不该出声"的意图标记。用来在恢复播放时判断要不要重新 play()
## （见 set_paused：Godot 4.4.1 实测，树暂停会把播放器的 playing 直接翻成 false）。
var _rain_should_play := false
## 暂停瞬间记下的播放位置，恢复时从这儿续上（不从头开始，免得每次暂停雨声都跳回起点）。
var _rain_position := 0.0


## 按关卡天气裁决环境音：**只有雨天**播雨声，其它天气一律释放。
##
## 每关加载时由 main.gd 的 _apply_level_config 调一次；重复调用是安全的（见 ①）。
func apply_weather_audio(cfg: LevelConfig, car: Node) -> void:
	if cfg == null:
		return
	if cfg.weather_type == "rain":
		_start_rain(car)
	else:
		release()


## 挂（或复用）雨声播放器。
func _start_rain(car: Node) -> void:
	if car == null:
		# 没有车就没有挂点。与粒子侧同一取舍：宁可不出声，也不往场景树里硬塞。
		push_warning("[environment] 雨天但玩家车为空，雨声未挂载")
		return
	# ---- 防叠音：先找已存在的同名播放器，找到就复用 ----
	var existing := car.get_node_or_null(RAIN_PLAYER_NAME) as AudioStreamPlayer
	if existing != null:
		_rain_player = existing
		_rain_should_play = true
		if not existing.playing:
			existing.play()
		return
	# 本实例还持有旧引用且它仍挂在这辆车上 —— 同样复用（场景内重入会走到这条）。
	if _rain_player != null and is_instance_valid(_rain_player) and _rain_player.get_parent() == car:
		_rain_should_play = true
		if not _rain_player.playing:
			_rain_player.play()
		return
	# 旧引用已经失效（车换过了）却被残留下来：清掉再建，绝不叠加。
	if _rain_player != null:
		release()
	var stream: AudioStream = load(RAIN_STREAM_PATH)
	if stream == null:
		push_warning("[environment] 雨声素材加载失败：%s" % RAIN_STREAM_PATH)
		return
	# 循环靠导入参数（`rain_loop.ogg.import` 的 loop=true）落地。若有人本地缓存没重导，
	# 这里兜底打开并**大声告警** —— 不静默兜底，日志里必须看得见"导入没生效"。
	if not bool(stream.get("loop")):
		push_warning("[environment] %s 导入后 loop 仍是 false，已在运行时兜底打开（请跑一次 godot --import）"
			% RAIN_STREAM_PATH)
		stream.set("loop", true)
	var p := AudioStreamPlayer.new()
	p.name = RAIN_PLAYER_NAME
	p.stream = stream
	p.bus = RAIN_BUS
	# 先入树再 play：不在树上的 AudioStreamPlayer 播不出声。
	car.add_child(p)
	p.play()
	_rain_player = p
	_rain_should_play = true
	_rain_position = 0.0
	print("[main] 雨声环境音已接入：%s（%s 总线，循环=%s）"
		% [RAIN_STREAM_PATH.get_file(), RAIN_BUS, str(bool(stream.get("loop")))])


## 暂停 / 结算时把雨声一起停住。由 main.gd 在 NOTIFICATION_PAUSED / UNPAUSED 里调用。
##
## ⚠ 恢复侧为什么不能只写 `stream_paused = false`：实测 `stream_paused = true` 之后
##   `playing` 就会报 false；若将来某版引擎"停了不自己恢复"，只解除 stream_paused 会留下
##   "状态看着在播、实际没声"的雨声。所以恢复时补一句 play()，并从暂停瞬间记下的位置
##   续播（不跳回起点）。当前 4.4.1 下这段是**兜底**（引擎自己就会恢复），留着是保险。
func set_paused(paused: bool) -> void:
	if _rain_player == null or not is_instance_valid(_rain_player):
		return
	if paused:
		if _rain_player.playing:
			_rain_position = _rain_player.get_playback_position()
		_rain_player.stream_paused = true
		return
	_rain_player.stream_paused = false
	if _rain_should_play and not _rain_player.playing:
		_rain_player.play(_rain_position)


## 切关 / 回菜单时释放雨声。
##
## 播放器是**玩家车的子节点**，车随场景销毁时它自然会没；这里是给"同一棵树里换关卡"
## 这种显式调用留的出口（main.gd 在 NOTIFICATION_EXIT_TREE 里调）。
func release() -> void:
	_rain_should_play = false
	_rain_position = 0.0
	if _rain_player == null:
		return
	if is_instance_valid(_rain_player):
		_rain_player.queue_free()
	_rain_player = null


## 自检用：把雨声当前状态摊成 Dictionary（tests/rel_step2c_audio_test.gd 读它做断言）。
## 不参与任何游戏逻辑 —— 存在的唯一理由是让"挂没挂 / 播没播 / 停没停"能被机器判定。
##
## ⚠ 它**证明不了**"听起来对不对"：音量配比、循环接缝有没有咔哒声只能人工听音。
func weather_audio_state() -> Dictionary:
	if _rain_player == null or not is_instance_valid(_rain_player):
		return {"mounted": false, "playing": false, "stream_paused": false, "bus": "", "loop": false}
	var s := _rain_player.stream
	return {
		"mounted": true,
		"playing": _rain_player.playing,
		"stream_paused": _rain_player.stream_paused,
		"bus": _rain_player.bus,
		"loop": false if s == null else bool(s.get("loop")),
	}
