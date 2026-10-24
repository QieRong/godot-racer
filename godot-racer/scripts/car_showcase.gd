extends Control
## 首页独立展示世界：只复制GLB视觉节点，不实例化比赛车辆或脚本。

const MODEL := preload("res://models/race_car.glb")
const Podium := preload("res://scripts/showcase_podium.gd")
const Intro := preload("res://scripts/showcase_intro.gd")
const AUTO_RADIANS := PI / 18.0
const DRAG_RADIANS := PI / 600.0
const PICK_LAYER := 1 << 19
enum State { INTRO, AUTO, HOVER, DRAG, BLOCKED }
static var _has_entered := false
## 本地简化模式；不新增玩家设置，不改全局渲染器。
@export var simplified_effects := false

var angle := 0.0
var dragging := false
var hovered := false
var suspended := false
var viewport: SubViewport
var _pivot: Node3D
var _camera: Camera3D
var _bounds := AABB()
var _focused := true
var _covered := false
var state := State.AUTO
var _pointer := Vector2(-1, -1)
var _pending_press := false
var _resume_delay := 0.0
var _auto_speed := 0.0
var _lift: Node3D
var _podium: Node3D
var _intro: Node
var _lights: Array[DirectionalLight3D] = []
var _environment: Environment
var _was_hidden := false


func _ready() -> void:
	name = "HomeCarShowcase"
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	tooltip_text = "悬停暂停 · 左右拖动查看"
	viewport = SubViewport.new()
	viewport.name = "CarViewport"
	# 独立展车视口降低约23%的像素成本；保留2x MSAA和相同机位/外层布局。
	viewport.size = Vector2i(768, 448)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.audio_listener_enable_3d = false
	viewport.audio_listener_enable_2d = false
	viewport.msaa_3d = Viewport.MSAA_2X
	add_child(viewport)
	var surface := TextureRect.new()
	surface.texture = viewport.get_texture()
	surface.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	surface.stretch_mode = TextureRect.STRETCH_SCALE
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(surface)
	_build_world()
	_intro = Intro.new()
	_intro.name = "ShowcaseIntro"
	add_child(_intro)
	_intro.configure(_lift, _podium, _pivot, _environment, _lights, _has_entered or simplified_effects)
	_has_entered = true
	visibility_changed.connect(_sync_activity)
	_sync_activity()


func _build_world() -> void:
	var world := Node3D.new()
	viewport.add_child(world)
	_lift = Node3D.new()
	_lift.name = "LiftRoot3D"
	world.add_child(_lift)
	_pivot = Node3D.new()
	_pivot.name = "CarTurntablePivot"
	_lift.add_child(_pivot)
	var source := MODEL.instantiate()
	_copy_visual(source, _pivot)
	source.free()
	var first := true
	for mesh in _pivot.find_children("*", "MeshInstance3D", true, false):
		var relative: Transform3D = _pivot.global_transform.affine_inverse() * mesh.global_transform
		var box: AABB = relative * mesh.get_aabb()
		_bounds = box if first else _bounds.merge(box)
		first = false
	var center := _bounds.get_center()
	for child in _pivot.get_children():
		child.position -= Vector3(center.x, _bounds.position.y, center.z)
	_bounds.position -= Vector3(center.x, _bounds.position.y, center.z)
	# 独立展示世界的专用拾取层；碰撞三角形来自可见网格，保留轮间/尾翼空隙。
	# 所有网格共享一个物理体，旋转时只更新一次物理体变换。
	var body := StaticBody3D.new()
	body.name = "CarPickable"
	body.collision_layer = PICK_LAYER
	body.collision_mask = 0
	_pivot.add_child(body)
	for mesh in _pivot.find_children("*", "MeshInstance3D", true, false):
		if mesh.mesh == null or not mesh.is_visible_in_tree():
			continue
		var shape := CollisionShape3D.new()
		shape.shape = mesh.mesh.create_trimesh_shape()
		body.add_child(shape)
		shape.transform = _pivot.global_transform.affine_inverse() * mesh.global_transform
		shape.set_meta("visual_mesh", mesh)
	_add_contact_shadows()
	var radius := 0.0
	for i in range(8):
		var corner := _bounds.get_endpoint(i)
		radius = maxf(radius, Vector2(corner.x, corner.z).length())
	_podium = Podium.new()
	_podium.radius = radius
	_lift.add_child(_podium)
	var environment := Environment.new()
	_environment = environment
	environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.78, 0.84, 0.95)
	environment.ambient_light_energy = 0.75
	var env := WorldEnvironment.new()
	env.environment = environment
	world.add_child(env)
	for light_angles in [Vector3(-50, -35, 0), Vector3(-25, 130, 0)]:
		var light := DirectionalLight3D.new()
		light.rotation_degrees = light_angles
		light.light_energy = 1.1
		# 四轮已有软接触阴影；避免额外为126个车模网格绘制实时阴影。
		light.shadow_enabled = false
		world.add_child(light)
		_lights.append(light)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# 全旋转包络而非单一角度：水平含圆台，垂直含车型高度与俯角投影。
	_camera.size = maxf(radius * 2.5 / (874.0 / 510.0), radius * 0.95 + _bounds.size.y + 0.45)
	_camera.position = Vector3(-4.8, 3.0, 6.5)
	world.add_child(_camera)
	_camera.look_at(Vector3(0, _bounds.size.y * 0.42 - 0.12, 0))
	_camera.current = true
	_fit_rotation_envelope(radius * 1.16)


func _fit_rotation_envelope(platform_radius: float) -> void:
	var inverse := _camera.global_transform.affine_inverse()
	var extent := Vector2.ZERO
	for degrees in range(0, 360, 5):
		var rotation_basis := Basis(Vector3.UP, deg_to_rad(degrees))
		for i in range(8):
			var projected: Vector3 = inverse * (rotation_basis * _bounds.get_endpoint(i))
			extent.x = maxf(extent.x, absf(projected.x))
			extent.y = maxf(extent.y, absf(projected.y))
		var rim: Vector3 = inverse * (rotation_basis * Vector3(platform_radius, -0.54, 0))
		extent.x = maxf(extent.x, absf(rim.x))
		extent.y = maxf(extent.y, absf(rim.y))
	_camera.size = 2.0 * maxf(extent.y, extent.x / (874.0 / 510.0)) / 0.94


func _copy_visual(source: Node, parent: Node3D) -> void:
	var copy: Node3D
	if source is MeshInstance3D:
		var mesh := MeshInstance3D.new()
		mesh.mesh = source.mesh
		for i in range(source.mesh.get_surface_count()):
			var material := source.get_active_material(i) as StandardMaterial3D
			if material != null:
				var own := material.duplicate() as StandardMaterial3D
				if material.resource_name == "mat_body_red":
					own.clearcoat_enabled = true
					own.clearcoat = 0.65
				mesh.set_surface_override_material(i, own)
		copy = mesh
	else:
		copy = Node3D.new()
	copy.name = source.name
	if source is Node3D:
		copy.transform = source.transform
	parent.add_child(copy)
	for child in source.get_children():
		_copy_visual(child, copy)


func set_angle(value: float) -> void:
	angle = value
	if _pivot != null:
		_pivot.rotation.y = angle


func _add_contact_shadows() -> void:
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
void fragment() {
 vec2 q = (UV - vec2(0.5)) * 2.0;
 ALBEDO = vec3(0.008, 0.012, 0.018);
 ALPHA = 0.45 * (1.0 - smoothstep(0.1, 1.0, dot(q, q)));
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	for wheel_name in ["Tire_Front_L", "Tire_Front_R", "Tire_Rear_L", "Tire_Rear_R"]:
		var wheel := _pivot.find_child(wheel_name, true, false) as MeshInstance3D
		if wheel == null: continue
		var box: AABB = _pivot.global_transform.affine_inverse() * wheel.global_transform * wheel.get_aabb()
		var shadow := MeshInstance3D.new()
		shadow.name = "ContactShadow"
		var plane := PlaneMesh.new()
		plane.size = Vector2(box.size.x * 1.05, box.size.z * 0.8)
		shadow.mesh = plane
		shadow.position = Vector3(box.get_center().x, 0.004, box.get_center().z)
		shadow.material_override = material
		shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_pivot.add_child(shadow)


## 只在物理帧调用；TextureRect 为 STRETCH_SCALE，按实际控件尺寸映射。
func pick_car(local_position: Vector2) -> Dictionary:
	if not _pivot.visible or (_intro != null and _intro.running and not _intro.can_skip):
		return {}
	if suspended or not is_visible_in_tree() or not Rect2(Vector2.ZERO, size).has_point(local_position):
		return {}
	var point := local_position * Vector2(viewport.size) / size
	var origin := _camera.project_ray_origin(point)
	var direction := _camera.project_ray_normal(point)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 100.0, PICK_LAYER)
	var hit := viewport.find_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and _pivot.is_ancestor_of(hit.collider):
		# shape索引保留原网格归属；合并物理体不合并或近似三角形。
		var body := hit.collider as StaticBody3D
		var shape: CollisionShape3D = body.shape_owner_get_owner(body.shape_find_owner(hit.shape))
		hit["visual_mesh"] = shape.get_meta("visual_mesh")
		return hit
	return {}


func set_suspended(value: bool) -> void:
	_covered = value
	_sync_activity()


func _sync_activity() -> void:
	suspended = _covered or not _focused
	if viewport == null:
		return
	var active := is_visible_in_tree() and not suspended and _focused
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	if not active:
		dragging = false
		hovered = false
		_pending_press = false
		_auto_speed = 0.0
		state = State.BLOCKED
	if not is_visible_in_tree():
		_was_hidden = true
		if _intro != null and _intro.running: _intro.settle()
	elif _was_hidden:
		_was_hidden = false
		if _intro != null: _intro.play(true)


func _gui_input(event: InputEvent) -> void:
	if suspended or not _focused:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_pointer = event.position
		if event.pressed:
			_pending_press = true


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		_pointer = get_global_transform_with_canvas().affine_inverse() * event.position
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		dragging = false
		_pending_press = false
		_resume_delay = 0.35
	if dragging and event is InputEventMouseMotion and not suspended and _focused:
		# _input相对位移是窗口像素，换成画布像素后，两分辨率的手感一致。
		set_angle(angle + event.relative.x / maxf(get_global_transform().get_scale().x, 0.01) * DRAG_RADIANS)
		accept_event()


func _physics_process(_delta: float) -> void:
	_sync_activity()
	if state == State.BLOCKED and (suspended or not is_visible_in_tree()):
		return
	var hit := not pick_car(_pointer).is_empty()
	if hovered and not hit:
		_resume_delay = 0.35
	hovered = hit
	if _pending_press:
		_pending_press = false
		dragging = hit and (_intro == null or not _intro.running or _intro.can_skip)
		if dragging and _intro != null and _intro.running: _intro.skip_to_drag()
	state = State.DRAG if dragging else (State.INTRO if _intro != null and _intro.running else
		(State.HOVER if hit else State.AUTO))
	mouse_default_cursor_shape = Control.CURSOR_DRAG if hit or dragging else Control.CURSOR_ARROW
	if hit or dragging:
		_auto_speed = 0.0


func _notification(what: int) -> void:
	if what in [MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
		_focused = false
		_sync_activity()
	elif what in [MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN]:
		_focused = true
		_pointer = get_local_mouse_position()
		_sync_activity()
	elif what == NOTIFICATION_WM_MOUSE_EXIT:
		_pointer = Vector2(-1, -1)
		dragging = false
		_pending_press = false
		hovered = false
		_resume_delay = 0.35


func _process(delta: float) -> void:
	_sync_activity()
	var entering: bool = _intro != null and _intro.running
	if entering and not _intro.can_rotate: return
	if not entering and viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		_podium.animate_idle(delta, simplified_effects)
	if viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED and not hovered and not dragging:
		if _resume_delay > 0.0:
			_resume_delay = maxf(0.0, _resume_delay - delta)
			return
		_auto_speed = move_toward(_auto_speed, AUTO_RADIANS, AUTO_RADIANS * delta / 0.2)
		set_angle(angle + _auto_speed * delta)


## 独立几何边界检测；测试遍历各角度，投影真实网格包围盒的八个角。
func model_fits_view() -> bool:
	var safe := Rect2(Vector2(12, 12), Vector2(viewport.size) - Vector2(24, 24))
	for i in range(8):
		var world_point := _pivot.global_transform * _bounds.get_endpoint(i)
		if _camera.is_position_behind(world_point) or not safe.has_point(_camera.unproject_position(world_point)):
			return false
	return true
