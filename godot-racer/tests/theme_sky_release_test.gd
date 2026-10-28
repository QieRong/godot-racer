extends SceneTree
## 真实渲染环境重配与释放；退出后的纹理诊断必须由调用方一并检查。
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: failed += 1
	print("SKY_RELEASE_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.make_current()
	var we := WorldEnvironment.new()
	world.add_child(we)
	var source := Environment.new()
	source.sky = Sky.new()
	source.sky.sky_material = ProceduralSkyMaterial.new()
	source.background_mode = Environment.BG_SKY
	we.environment = source
	var sun := DirectionalLight3D.new()
	world.add_child(sun)
	var car := Node3D.new()
	world.add_child(car)
	for i in range(4): await process_frame
	var old_sky := source.sky
	var environment_script := preload("res://scripts/environment.gd")
	var cfg: LevelConfig = root.get_node("GameState").current_level()
	environment_script.apply_environment(cfg, we, sun, car)
	check(we.environment != source, "每场独立Environment")
	check(source.sky == old_sky and source.background_mode == Environment.BG_SKY, "源环境未被修改")
	check(we.environment.sky != old_sky and we.environment.sky.has_meta("theme"), "已装配主题天空")
	for i in range(4): await process_frame
	var memory_before := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
	# 同一场景重新配置会替换旧主题天空，不能留下临时深复制Sky。
	environment_script.apply_environment(cfg, we, sun, car)
	for i in range(4): await process_frame
	check(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) <= memory_before + 65536,
		"重配环境后纹理占用有界")
	# 正式场景在首帧渲染前替换占位天空；不保留该源资源才能覆盖真实装配时序。
	var cold_memory := 0.0
	for iteration in range(2):
		we.environment = Environment.new()
		we.environment.sky = Sky.new()
		we.environment.sky.sky_material = ProceduralSkyMaterial.new()
		environment_script.apply_environment(cfg, we, sun, car)
		for i in range(4): await process_frame
		var used := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)
		if iteration == 0: cold_memory = used
		else: check(used <= cold_memory + 65536, "首帧前替换占位天空不累积纹理")
	we.environment = null
	old_sky = null
	source = null
	world.queue_free()
	preload("res://scripts/theme_sky.gd").clear_cached_textures()
	for i in range(4): await process_frame
	print("SKY_RELEASE_COMPLETE FAIL=", failed)
	quit(0 if failed == 0 else 1)
