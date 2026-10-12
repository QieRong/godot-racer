extends RefCounted
## 关卡环境：天气/夜晚的视觉侧（雾、色调、太阳）+ 天气粒子（雨/雪/沙尘）。
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
	build_weather_particles(cfg, car)


## 天气粒子（雨/雪/沙尘）。晴天不生成任何节点。
##
## 挂法：粒子系统作为**玩家车的子节点**，但 `local_coords = false` ——
## 这样发射盒跟着车走（玩家身边永远有雨），而已经生成的粒子留在世界空间，
## 高速行驶时会自然拉出向后掠过的效果，而不是像贴在车头的静态噪点。
##
## 渲染层不用管：小地图相机的 cull_mask 只有 MAP_LAYER，天然看不到这些粒子。
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
	car.add_child(p)
	print("[main] 天气粒子已生成：%s（%d 粒，寿命 %.1fs）"
		% [cfg.weather_label(), p.amount, p.lifetime])
