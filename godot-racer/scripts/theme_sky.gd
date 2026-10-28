extends RefCounted
## 一次烘焙的球面云层全景，运行时仅采样贴图；五关各自缓存，不逐帧重算云。
static var _textures: Dictionary = {}
const PALETTES := {
	"training":[Color(0.16,0.34,0.60),Color(0.59,0.72,0.80),Color(0.81,0.85,0.86),0.15],
	"sunny":[Color(0.20,0.43,0.73),Color(0.67,0.77,0.83),Color(0.88,0.87,0.81),0.22],
	"rain":[Color(0.018,0.027,0.052),Color(0.10,0.14,0.20),Color(0.16,0.19,0.24),-0.10],
	"sand":[Color(0.35,0.39,0.43),Color(0.64,0.55,0.39),Color(0.66,0.61,0.50),0.25],
	"snow":[Color(0.25,0.32,0.41),Color(0.52,0.59,0.66),Color(0.62,0.67,0.71),-0.04]
}

static func apply(cfg: Resource, env: Environment, sun: DirectionalLight3D) -> void:
	var key: String = preload("res://scripts/scenery_dressing.gd").theme_key(cfg)
	var palette: Array = PALETTES[key]
	if not _textures.has(key): _textures[key]=_bake(key,palette)
	var material := PanoramaSkyMaterial.new()
	material.panorama=_textures[key]
	var sky := Sky.new()
	sky.sky_material=material
	sky.radiance_size=Sky.RADIANCE_SIZE_128
	sky.process_mode=Sky.PROCESS_MODE_QUALITY
	sky.set_meta("theme",key)
	var previous_sky := env.sky
	if previous_sky != null and DisplayServer.get_name() != "headless":
		# 4.4.1 GLES3的Sky脏队列会在渲染更新中创建辐照纹理。
		# 首帧前被替换的占位Sky须活到该队列处理后，再由一次性绑定释放引用。
		RenderingServer.frame_post_draw.connect(_release_sky_after_draw.bind(previous_sky), CONNECT_ONE_SHOT)
	env.sky=sky
	env.background_mode=Environment.BG_SKY
	env.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_sky_contribution=0.0
	# 背景云层与场景补光分离；避免LDR天空反射把车轮/车身冲成整片白色。
	env.reflected_light_source=Environment.REFLECTION_SOURCE_DISABLED
	env.fog_sky_affect=0.12
	if key in ["training","sunny"]:
		env.ambient_light_color=Color(0.59,0.66,0.70)
		env.ambient_light_energy=0.40
		env.fog_enabled=true
		env.fog_density=0.0003
		env.fog_light_color=palette[1]
		if sun!=null: sun.light_energy=0.85
	elif key=="snow":
		env.ambient_light_color=Color(0.62,0.68,0.74)
		env.ambient_light_energy=0.50
	elif key=="sand":
		env.ambient_light_color=Color(0.68,0.62,0.51)
		env.ambient_light_energy=0.45
	elif key=="rain" and sun!=null:
		# 云层漫射补光保证驾驶可读性；主方向灯只有漫反射，不产生大面积高光。
		# Track子场景的独立预览太阳由track_scenery在雨夜关闭；不能遗漏第二光源。
		env.ambient_light_color=Color(0.70,0.74,0.80)
		env.ambient_light_energy=1.5
		sun.light_energy=0.35
		sun.light_specular=0.0
	# 雨夜保留environment.gd已批准的基础补光和四灯池。

static func _bake(key: String, palette: Array) -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.seed=27543+key.hash()
	noise.frequency=1.0
	noise.fractal_octaves=3
	var image := Image.create(1024,512,false,Image.FORMAT_RGB8)
	for y in range(512):
		var latitude := float(y)*PI/511.0
		var up := cos(latitude)
		for x in range(1024):
			var longitude := float(x)*TAU/1023.0
			var direction := Vector3(sin(latitude)*sin(longitude),up,sin(latitude)*cos(longitude))
			var color: Color = Color(palette[1]).lerp(palette[0],pow(maxf(up,0.0),0.55))
			var value := noise.get_noise_3dv(direction*Vector3(2.5,5.0,2.5))
			var high := noise.get_noise_3dv(direction*Vector3(6.0,2.0,6.0)+Vector3(8,3,1))
			var cloud := smoothstep(float(palette[3])-0.16,float(palette[3])+0.15,value+high*0.25)
			cloud*=smoothstep(0.01,0.16,up)*0.80
			color=color.lerp(palette[2],cloud)
			image.set_pixel(x,y,color)
	return ImageTexture.create_from_image(image)

static func clear_cached_textures() -> void:
	_textures.clear()

static func _release_sky_after_draw(_sky: Sky) -> void:
	pass # 一次性信号解绑时释放绑定的Sky；不更改材质或强行释放RID。
