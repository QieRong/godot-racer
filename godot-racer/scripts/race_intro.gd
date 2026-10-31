extends CanvasLayer
## 装配遮罩与受控赛道环绕；镜头只表现，不发车、不启动圈钟。
signal finished
const Ui := preload("res://scripts/ui_theme.gd")
const DURATION := 7.0
var elapsed := 0.0
var _active := false
var _done := false
var _track: Node3D
var _follow: Camera3D
var _camera: Camera3D
var _cover: ColorRect
var _title: Label
var _hint: Label
var _center := Vector3.ZERO
var _radius := 100.0
var _height := 100.0
var _saved_ranges: Array[Dictionary] = []
var _backdrop: MeshInstance3D

func _ready() -> void:
	name = "RaceIntro"
	layer = 89
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	Ui.install(root)
	_cover = ColorRect.new()
	_cover.color = Color("131f2b")
	_cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_cover)
	_title = Ui.label(root, "IntroTitle", "正在准备赛道…", 30)
	_title.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_title.offset_left = -300
	_title.offset_right = 300
	_title.offset_top = -110
	_title.offset_bottom = -62
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint = Ui.label(root, "IntroHint", "", 18)
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.offset_left = -300
	_hint.offset_right = 300
	_hint.offset_top = -62
	_hint.offset_bottom = -34
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for label in [_title, _hint]:
		label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.add_theme_constant_override("outline_size", 5)

func begin(track: Node3D, follow: Camera3D, scenery: Node3D) -> void:
	_track = track
	_follow = follow
	# 从真实路线计算中心，忽略大面积GroundMesh与未完成场地。
	var points: Array[Vector3] = []
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for i in range(96):
		var point: Vector3 = track.centerline_point(track.road_length() * float(i) / 96.0)
		points.append(point)
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	_center = (minimum + maximum) * 0.5
	var extent := 0.0
	for point in points: extent = maxf(extent, Vector2(point.x-_center.x, point.z-_center.z).length())
	# 围绕已布置的起点赛事区巡览，避免全图高度暴露大片未完成的路外空场。
	var profiles := [Vector2(110,85), Vector2(135,95), Vector2(85,75), Vector2(120,90), Vector2(105,85)]
	var profile: Vector2 = profiles[GameState.chosen_level]
	_center = track.centerline_point(track.start_finish_t * track.road_length() + 75.0)
	_radius = minf(profile.x, maxf(80.0, extent * 0.4))
	_height = profile.y
	_camera = Camera3D.new()
	_camera.name = "TrackOverviewCamera"
	_camera.fov = 64.0
	# 鸟瞰不需要近距离物体；增大近裁面避免高空深度精度导致路面破碎。
	_camera.near = 5.0
	_camera.far = 6000.0
	track.get_parent().add_child(_camera)
	_camera.make_current()
	_extend_ground(track)
	_show_scenery(scenery)
	_title.text = GameState.current_level().display_name
	_hint.text = "赛道巡览  ·  确认键跳过"
	_pose(0.0)
	_active = true
	# 第一帧呈现真实赛道后再撤下加载遮罩，避免白屏/旧出生点。
	await RenderingServer.frame_post_draw
	if is_instance_valid(_cover): _cover.visible = false

func _process(delta: float) -> void:
	if not _active or _done or GameState.phase_name() != "INTRO": return
	elapsed += delta
	_pose(clampf(elapsed / DURATION, 0.0, 1.0))
	if elapsed >= DURATION: _finish()

func _pose(progress: float) -> void:
	var angle := progress * TAU + 0.35
	_camera.global_position = _center + Vector3(cos(angle)*_radius, _height, sin(angle)*_radius)
	_camera.look_at(_center, Vector3.UP)

func _unhandled_input(event: InputEvent) -> void:
	if not _active or _done or GameState.phase_name() != "INTRO": return
	if event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		_finish()
	elif event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		GameState.request_exit()

func _finish() -> void:
	if _done: return
	_done = true
	_active = false
	_restore_ranges()
	if is_instance_valid(_backdrop): _backdrop.visible = false
	_camera.current = false
	# 明确回第三人称，倒计时必须看得到起点赛车；用户开赛后可照常V切换。
	_follow.set_view_mode(2)
	_follow.make_current()
	visible = false
	finished.emit()

func _extend_ground(track: Node3D) -> void:
	var ground := track.find_child("GroundMesh", true, false) as MeshInstance3D
	var source := ground.material_override as StandardMaterial3D
	var material := source.duplicate() as StandardMaterial3D
	var bounds := ground.mesh.get_aabb()
	var size := maxf(bounds.size.x, bounds.size.z) * 4.0
	material.uv1_scale *= size / maxf(bounds.size.x, 1.0)
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	_backdrop = MeshInstance3D.new()
	_backdrop.name = "OverviewGroundContinuation"
	_backdrop.mesh = plane
	_backdrop.material_override = material
	_backdrop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_backdrop.position = Vector3(ground.position.x, -1.0, ground.position.z)
	track.add_child(_backdrop)

func _show_scenery(node: Node) -> void:
	if node is GeometryInstance3D and node.visibility_range_end > 0.0:
		_saved_ranges.append({"node":node, "distance":node.visibility_range_end})
		node.visibility_range_end = maxf(node.visibility_range_end, _radius * 3.0)
	for child in node.get_children(): _show_scenery(child)

func _restore_ranges() -> void:
	for entry in _saved_ranges:
		if is_instance_valid(entry.node): entry.node.visibility_range_end = entry.distance
	_saved_ranges.clear()

func _exit_tree() -> void:
	_restore_ranges()
	if is_instance_valid(_camera): _camera.queue_free()
	if is_instance_valid(_backdrop): _backdrop.queue_free()
