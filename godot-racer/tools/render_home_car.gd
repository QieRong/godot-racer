extends SceneTree
## 独立离线展示渲染，不装配车辆/赛道，不修改原GLB或赛内材质。

const MODEL_PATH := "res://models/race_car.glb"
const OUTPUT_PATH := "res://assets/ui/racer_hero.png"
const IMAGE_SIZE := Vector2i(1536, 864)

var _view: SubViewport
var _frames := 0
var _started := 0
var _scheduled := false


func _initialize() -> void:
	_started = Time.get_ticks_msec()
	call_deferred("_boot")


func _boot() -> void:
	_view = SubViewport.new()
	_view.size = IMAGE_SIZE
	_view.own_world_3d = true
	_view.transparent_bg = true
	_view.msaa_3d = Viewport.MSAA_4X
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_view)
	var world := Node3D.new()
	_view.add_child(world)
	var packed: PackedScene = load(MODEL_PATH)
	if packed == null:
		push_error("CAR_HERO: 无法加载原赛车模型")
		quit(1)
		return
	var model: Node3D = packed.instantiate()
	world.add_child(model)
	_polish_material_copies(model)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.78, 0.84, 0.95)
	environment.ambient_light_energy = 0.65
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.30, 0.36, 0.48)
	sky_material.sky_horizon_color = Color(0.92, 0.94, 0.98)
	sky_material.ground_horizon_color = Color(0.70, 0.75, 0.82)
	sky_material.ground_bottom_color = Color(0.12, 0.15, 0.20)
	var sky := Sky.new()
	sky.sky_material = sky_material
	environment.sky = sky
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	world.add_child(world_environment)
	_add_light(world, Vector3(-50, -35, 0), Color(1.0, 0.95, 0.90), 1.4)
	_add_light(world, Vector3(-25, 130, 0), Color(0.60, 0.76, 1.0), 1.2)
	_add_light(world, Vector3(-70, 25, 0), Color(0.88, 0.93, 1.0), 0.6)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.7
	camera.position = Vector3(-4.8, 3.0, 6.5)
	world.add_child(camera)
	camera.look_at(Vector3(0, 0.45, 0))
	camera.current = true
	print("CAR_HERO_SOURCE=%s SIZE=%s" % [MODEL_PATH, str(IMAGE_SIZE)])


func _add_light(world: Node3D, angles: Vector3, color: Color, energy: float) -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = angles
	light.light_color = color
	light.light_energy = energy
	light.shadow_enabled = false
	world.add_child(light)


func _polish_material_copies(model: Node3D) -> void:
	var copies: Dictionary = {}
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		for surface in range(mesh.mesh.get_surface_count()):
			var material := mesh.get_active_material(surface) as StandardMaterial3D
			if material == null:
				continue
			if not copies.has(material):
				var copy := material.duplicate() as StandardMaterial3D
				if material.resource_name == "mat_body_red":
					copy.clearcoat_enabled = true
					copy.clearcoat = 0.65
					copy.clearcoat_roughness = 0.14
				copies[material] = copy
			mesh.set_surface_override_material(surface, copies[material])


func _process(_delta: float) -> bool:
	_frames += 1
	if Time.get_ticks_msec() - _started > 29000:
		push_error("CAR_HERO: 29秒看门狗退出")
		quit(2)
		return false
	if _view != null and _frames >= 12 and not _scheduled:
		_scheduled = true
		RenderingServer.frame_post_draw.connect(_capture, CONNECT_ONE_SHOT)
	return false


func _capture() -> void:
	var picture := _view.get_texture().get_image()
	picture.convert(Image.FORMAT_RGBA8)
	var path := ProjectSettings.globalize_path(OUTPUT_PATH)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var error := picture.save_png(path)
	print("CAR_HERO_DONE SAVE=%d SIZE=%s ALPHA_CORNER=%.3f ELAPSED_MS=%d" % [
		error, str(picture.get_size()), picture.get_pixel(0, 0).a, Time.get_ticks_msec() - _started])
	quit(0 if error == OK else 1)
