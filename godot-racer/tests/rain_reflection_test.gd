extends SceneTree
## 固定镜头和涟漪时钟：验证真实光源高光、无光不自亮、圆环不画进底色。
var output := ""
var passed := 0
var failed := 0
var metrics: Dictionary = {}
const REGION := Rect2i(800,420,420,270)

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if ok: passed+=1
	else: failed+=1
	print("RAIN_REFLECTION_ASSERT %s %s" % ["PASS" if ok else "FAIL",label])

func capture(label: String) -> Image:
	await create_timer(0.25).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(output.path_join(label+".png"))
	return image

func difference(a: Image, b: Image) -> Dictionary:
	var changed := 0
	var total := 0.0
	var peak := 0.0
	for y in range(REGION.position.y,REGION.end.y):
		for x in range(REGION.position.x,REGION.end.x):
			var p := a.get_pixel(x,y)
			var q := b.get_pixel(x,y)
			var delta := Vector3(p.r-q.r,p.g-q.g,p.b-q.b).length()
			if delta>1.0/255.0: changed+=1
			total+=delta
			peak=maxf(peak,delta)
	return {"changed":changed,"mean_delta":total/float(REGION.get_area()),"max_delta":peak}

func run() -> void:
	var state := root.get_node("GameState")
	state.settings_path=output.path_join("settings.cfg")
	state.chosen_level=2
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec()+50000
	while current_scene==null or state.phase_name()!="RACING":
		await process_frame
		if Time.get_ticks_msec()>deadline: quit(1);return
	var scene := current_scene
	for car in scene.find_children("*","VehicleBody3D",true,false):
		car.set_physics_process(false);car.freeze=true
	var particles: Node3D = scene.get_node("RaceCar/WeatherParticles")
	particles.visible=false
	await create_timer(1).timeout
	var camera: Camera3D = scene.get_node("ChaseCamera")
	camera.set_process(false)
	DisplayServer.window_set_size(Vector2i(1280,720))
	var pool: Node = scene.get_node("TrackScenery/StreetLighting")
	pool.set_process(false)
	var env: Environment = scene.get_node("WorldEnvironment").environment
	var sun: DirectionalLight3D = scene.get_node("Sun")
	check(env.reflected_light_source==Environment.REFLECTION_SOURCE_DISABLED,
		"禁用全景天空反射，夜空不充当路面高光")
	check(is_zero_approx(sun.light_specular) and sun.light_energy<=0.4,"夜景方向补光只有漫反射，不产生无灯镜面亮斑")
	var legacy_sun: DirectionalLight3D = scene.get_node("Track/Sun")
	check(is_zero_approx(legacy_sun.light_energy),"赛道子场景的预览太阳也已关闭，不能漏掉第二光源")
	var lights: Array[Light3D] = []
	for light in pool.get_children():
		if light is Light3D and light.visible: lights.append(light)
	check(lights.size()==4,"真实四灯池参与对照")
	var road: MeshInstance3D = scene.get_node("Track").find_child("RoadMesh",true,false)
	var material := road.material_override as ShaderMaterial
	material.set_shader_parameter("ripple_clock",0.2)
	var lit_a := await capture("rain-lit-ripple-a")
	material.set_shader_parameter("ripple_clock",0.9)
	var lit_b := await capture("rain-lit-ripple-b")
	metrics["lit_ripples"]=difference(lit_a,lit_b)
	check(int(metrics.lit_ripples.changed)>20,"受光湿路面涟漪改变实际高光/明暗：%d像素" % metrics.lit_ripples.changed)
	for light in lights: light.visible=false
	material.set_shader_parameter("ripple_clock",0.2)
	var no_lamps := await capture("rain-no-lamps")
	metrics["lamp_response"]=difference(lit_a,no_lamps)
	check(int(metrics.lamp_response.changed)>100,"关路灯后对应路面光照实际消失")
	var specular: float = material.get_shader_parameter("surface_specular")
	material.set_shader_parameter("surface_specular",0.0)
	var no_lamp_specular_off := await capture("rain-no-lamps-no-specular")
	metrics["unlit_specular"]=difference(no_lamps,no_lamp_specular_off)
	check(int(metrics.unlit_specular.changed)==0,"无路灯时切换镜面参数不产生亮斑，不能仅验证光源属性")
	for light in lights: light.visible=true
	var lamp_specular_off := await capture("rain-lit-no-specular")
	metrics["lit_specular"]=difference(lit_a,lamp_specular_off)
	check(int(metrics.lit_specular.changed)>20,"受光水面有实际镜面贡献，非单纯漫反射亮块")
	material.set_shader_parameter("surface_specular",specular)
	# 隔离底色：unshaded只读同一Shader的ALBEDO，法线/灯光不应改变它。
	var albedo_only := material.duplicate() as ShaderMaterial
	var shader := Shader.new()
	shader.code=material.shader.code.replace("render_mode cull_disabled;","render_mode cull_disabled, unshaded;")
	albedo_only.shader=shader
	road.material_override=albedo_only
	albedo_only.set_shader_parameter("ripple_clock",0.2)
	var albedo_a := await capture("rain-albedo-only-a")
	albedo_only.set_shader_parameter("ripple_clock",0.9)
	var albedo_b := await capture("rain-albedo-only-b")
	metrics["albedo_ripples"]=difference(albedo_a,albedo_b)
	check(int(metrics.albedo_ripples.changed)==0,"涟漪不向底色叠加自带淡色圆环")
	road.material_override=material
	env.ambient_light_energy=0.0
	env.fog_enabled=false # 排除雾色混合，隔离材质自身是否发光。
	for light in scene.find_children("*","Light3D",true,false): light.light_energy=0.0
	var darkness := await capture("rain-no-direct-or-ambient-light")
	var peak := 0.0
	for y in range(REGION.position.y,REGION.end.y):
		for x in range(REGION.position.x,REGION.end.x):
			peak=maxf(peak,darkness.get_pixel(x,y).get_luminance())
	metrics["no_light_peak_luminance"]=peak
	check(peak<0.01,"所有直接光/环境光关闭后，路面不自发亮：峰值%.4f" % peak)
	FileAccess.open(output.path_join("reflection.json"),FileAccess.WRITE).store_string(
		JSON.stringify({"passed":passed,"failed":failed,"region":str(REGION),"metrics":metrics},"  "))
	state.enter_menu();current_scene=null;scene.free();await process_frame
	var music := state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	preload("res://scripts/theme_sky.gd").clear_cached_textures()
	await process_frame
	await RenderingServer.frame_post_draw
	print("RAIN_REFLECTION_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
