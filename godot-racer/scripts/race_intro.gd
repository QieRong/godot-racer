extends CanvasLayer
## 装配遮罩与两段受控航拍；镜头只表现，不发车、不启动圈钟。
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
var _landmark := Transform3D.IDENTITY
var _landmark_arc := 0.0
var _tour_arc := 0.0
var _landmark_side := 1.0
var _grid_car: Node3D
var _weather: GPUParticles3D
var _weather_home := Vector3.ZERO
var _weather_home_bounds := AABB()
const LANDMARKS := ["L1_01_training_briefing_center", "L2_02_sunshade_grandstand",
	"L3_01_corner_commercial_block", "L4_01_ruined_caravanserai", "L5_01_snow_rescue_station"]
var _saved_ranges: Array[Dictionary] = []
var _backdrop: MeshInstance3D
var _lighting: Array[Node] = []

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
	_grid_car = follow.target
	_weather = _grid_car.get_node_or_null("WeatherParticles") as GPUParticles3D
	if _weather != null:
		_weather_home = _weather.position
		_weather_home_bounds = _weather.visibility_aabb
		# 原8m裁剪盒小于天气发射体积，镜头上方的发射器会被剔除。
		_weather.visibility_aabb = AABB(Vector3(-80,-100,-80), Vector3(160,140,160))
	# 只取实际已摆出的近起点地标；不依据整张地图包围盒生成自由巡航。
	var site := scenery.get_node_or_null("EnvironmentAssetPack/" + LANDMARKS[GameState.chosen_level])
	_landmark = track.surface_frame(track.start_finish_t * track.road_length() + 30.0, 0.0)
	if site != null:
		var placements: Array = site.get_meta("placements", [])
		if not placements.is_empty(): _landmark = placements[0]
	var nearest: Dictionary = track.nearest_on_centerline(_landmark.origin, -1.0)
	_landmark_arc = float(nearest.arc)
	_tour_arc = _find_slope_arc()
	var road_frame: Transform3D = track.surface_frame(_landmark_arc, 0.0)
	_landmark_side = signf((_landmark.origin - road_frame.origin).dot(road_frame.basis.x))
	_center = _landmark.origin
	_camera = Camera3D.new()
	_camera.name = "TrackOverviewCamera"
	_camera.fov = 48.0
	_camera.near = 0.3
	_camera.far = 6000.0
	track.get_parent().add_child(_camera)
	_camera.make_current()
	_extend_ground(track)
	_show_scenery(scenery)
	for path in ["StreetLighting", "KonbiniLighting"]:
		var lighting := scenery.get_node_or_null(path)
		if lighting != null: _lighting.append(lighting)
	_set_overview_lighting(true)
	_title.text = GameState.current_level().display_name
	_hint.text = "赛道航拍 · 确认键跳过"
	_pose(0.0)
	if _weather != null: _weather.restart()
	_active = true
	# 第一帧呈现真实赛道后再撤下加载遮罩，避免白屏/旧出生点。
	await RenderingServer.frame_post_draw
	if is_instance_valid(_cover): _cover.color.a = 0.0
	GameState.hide_loading()

func _process(delta: float) -> void:
	if not _active or _done or GameState.phase_name() != "INTRO": return
	elapsed += delta
	_pose(clampf(elapsed / DURATION, 0.0, 1.0))
	if elapsed >= DURATION: _finish()

func _find_slope_arc() -> float:
	# 本局有坡道时优先展示真实爬坡；固定平路仍保留原地标机位。
	var arc := _landmark_arc
	var steepest := 0.0
	if _track.elevation_profile.is_empty(): return arc
	for sample in range(100, int(_track.road_length()) - 100, 4):
		var a: Vector3 = _track.centerline_point(float(sample))
		var b: Vector3 = _track.centerline_point(float(sample) + 4.0)
		var grade := (b.y - a.y) / Vector2(b.x-a.x, b.z-a.z).length()
		if grade > steepest:
			steepest = grade
			arc = float(sample)
	return arc

func _pose(progress: float) -> void:
	var time := progress * DURATION
	var target: Vector3
	if time < 4.0:
		var t := smoothstep(0.0, 1.0, time / 4.0)
		# 沿本局最终坡面推进，并向前取景，让爬坡与坡顶进入画面。
		var sloped: bool = not _track.elevation_profile.is_empty()
		var arc := _tour_arc + (lerpf(-45.0, 35.0, t) if sloped else lerpf(-28.0, 28.0, t))
		var profile: Vector2 = [Vector2(20, 14), Vector2(23, 16), Vector2(22, 12), Vector2(19, 15), Vector2(20, 13)][GameState.chosen_level]
		var camera_frame: Transform3D = _track.surface_frame(arc, -_landmark_side * profile.y)
		_camera.global_position = camera_frame.origin + Vector3.UP * lerpf(profile.x, profile.x - 3.0, t)
		var target_frame: Transform3D = _track.surface_frame(arc + (65.0 if sloped else 19.0), _landmark_side * 12.0)
		target = target_frame.origin + Vector3.UP * 1.0
		_camera.fov = 48.0
	else:
		var t := smoothstep(0.0, 1.0, (time - 4.0) / 3.0)
		# 第二镜沿已完成起跑区下降推进，末帧与真实第三人称机位完全对齐。
		var offset := Vector3(11, 12, 23).lerp(_follow.offset_third, t)
		_camera.global_position = _grid_car.global_transform * offset
		target = _grid_car.global_transform * Vector3(0, lerpf(1.5, 0.8, t), 0)
		_camera.fov = lerpf(48.0, _follow.fov, t)
	_camera.look_at(target, Vector3.UP)
	# 航拍离开起跑格时，天气发射区跟随当前镜头，保留原粒子参数。
	if _weather != null: _weather.global_position = _camera.global_position + Vector3.UP * 8.0
	_center = target
	_set_overview_lighting(true)
	# 仅在换镜时短淡出，避免跨越未审核区域；跳过和计时不依赖淡入淡出。
	_cover.color.a = 1.0 - smoothstep(0.0, 0.15, absf(time - 4.0))

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
	if _weather != null:
		_weather.position = _weather_home
		_weather.visibility_aabb = _weather_home_bounds
		_weather.restart()
	_restore_ranges()
	_set_overview_lighting(false)
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
		node.visibility_range_end = maxf(node.visibility_range_end, 250.0)
	for child in node.get_children(): _show_scenery(child)

func _restore_ranges() -> void:
	for entry in _saved_ranges:
		if is_instance_valid(entry.node): entry.node.visibility_range_end = entry.distance
	_saved_ranges.clear()

func _set_overview_lighting(enabled: bool) -> void:
	for lighting in _lighting:
		if is_instance_valid(lighting) and lighting.is_inside_tree():
			lighting.set_overview_focus(enabled, _center)

func _exit_tree() -> void:
	_restore_ranges()
	_set_overview_lighting(false)
	if is_instance_valid(_camera): _camera.queue_free()
	if is_instance_valid(_backdrop): _backdrop.queue_free()
