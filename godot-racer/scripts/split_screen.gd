extends Node
## 同机双人装配。共享世界与比赛时钟，复用车辆、相机和名次算法。
const Ui := preload("res://scripts/ui_theme.gd")
const ControlCards := preload("res://scripts/split_control_cards.gd")
const ChaseCamera := preload("res://scripts/chase_camera.gd")
const EngineAudio := preload("res://scripts/engine_audio.gd")
const CarScene := preload("res://scenes/race_car.tscn")
const ACTIONS := ["accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake", "reset", "camera_view", "camera_rear", "drift"]
var cars: Array[VehicleBody3D] = []
var cameras: Array[Camera3D] = []
var views: Array[SubViewport] = []
var _ranking: CanvasLayer
var _audio := EngineAudio.new()
var _display: CanvasLayer
var _panes: Array[Control] = []
var _readouts: Array[Dictionary] = []
var _guide: CanvasLayer
var _guide_previous_focus: Control
var _track: Node3D
var _follow: Camera3D
var _finish_queued := false
var _photo: Node

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

static func configure_keyboard() -> void:
	for name in ACTIONS:
		for prefix in ["p1_", "p2_"]:
			var action: String = prefix + name
			if InputMap.has_action(action): InputMap.erase_action(action)
			InputMap.add_action(action)
			if prefix == "p1_":
				for event in InputMap.action_get_events(name):
					if event is InputEventKey: InputMap.action_add_event(action, event.duplicate())
			else:
				var key: Vector2i = GameState.drift_keys[1] if name == "drift" else GameState.P2_KEYBOARD[name]
				InputMap.action_add_event(action, GameState.keyboard_event(key))

func setup(first: VehicleBody3D, track: Node3D, obstacles: Node3D, follow: Camera3D) -> void:
	_track = track
	_follow = follow
	var second: VehicleBody3D = CarScene.instantiate()
	second.name = "RaceCarP2"
	second.input_prefix = "p2_"
	second.start_locked = true
	second.position = first.position
	get_parent().add_child(second)
	second.apply_level_setup(GameState.effective_speed(), 2, GameState.current_level().friction_multiplier)
	second.obstacle_field = obstacles
	preload("res://scripts/environment.gd").build_weather_particles(GameState.current_level(), second)
	# 每个视角只显示自身的近身天气，避免同处起点时雨雪叠加。
	for i in range(2):
		var weather: Node = [first, second][i].get_node_or_null("WeatherParticles")
		if weather != null: weather.layers = 1 << (18 + i)
	cars.assign([first, second])
	_audio.setup(second)
	_ranking = get_parent().get("_race_position")
	_ranking.human_opponents = true
	_ranking.setup(first, track, [second])
	for car in cars: car.race_finished.connect(_on_finished.bind(car))
	_photo = preload("res://scripts/photo_finish.gd").new()
	add_child(_photo)
	_photo.setup(first, [second], track)
	_photo.completed.connect(_finish_replay)
	_build_views()

func _build_views() -> void:
	_display = CanvasLayer.new()
	_display.name = "SplitDisplay"
	_display.layer = 2
	_display.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(_display)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_display.add_child(root)
	var row := HBoxContainer.new()
	row.name = "PlayerViews"
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 0)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(row)
	for i in range(2):
		if i == 1:
			var divider := ColorRect.new()
			divider.name = "SplitDivider"
			divider.color = Color("94a3b8")
			divider.custom_minimum_size.x = 4
			divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(divider)
		var pane := SubViewportContainer.new()
		pane.name = "P%d" % (i + 1)
		pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pane.stretch = true
		pane.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(pane)
		_panes.append(pane)
		var view := SubViewport.new()
		view.name = "View"
		view.size = Vector2i(640, 720)
		view.world_3d = get_viewport().world_3d
		view.gui_disable_input = true
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		pane.add_child(view)
		views.append(view)
		var camera := Camera3D.new()
		camera.name = "ChaseCamera"
		camera.set_script(ChaseCamera)
		camera.target = cars[i]
		camera.input_prefix = "p%d_" % (i + 1)
		camera.orbit_enabled = false
		camera.toast_enabled = false
		camera.cull_mask = (camera.cull_mask & ~((1 << 18) | (1 << 19))) | (1 << (18 + i))
		camera.fov = _follow.fov
		camera.far = _follow.far
		view.add_child(camera)
		var weather := cars[i].get_node_or_null("WeatherParticles") as GPUParticles3D
		if weather != null:
			weather.follow_camera = camera
			var far := weather.get_node_or_null("FarRain") as GPUParticles3D
			if far != null: far.layers = weather.layers
		camera.set_process_unhandled_input(false)
		camera.make_current()
		cameras.append(camera)
		_build_hud(i, view)
	_display.hide()
	var pause := Ui.button(root, "SharedPause", "暂停 / Esc", Rect2(), Ui.SKY)
	pause.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	pause.offset_left = -140
	pause.offset_right = -16
	pause.offset_top = 12
	pause.offset_bottom = 46
	pause.focus_mode = Control.FOCUS_NONE
	pause.pressed.connect(func(): get_parent().get_node("PauseMenu").pause())

func _build_hud(index: int, view: SubViewport) -> void:
	var layer := CanvasLayer.new()
	layer.name = "PlayerHUD"
	view.add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	Ui.install(root)
	var accent := Ui.RED if index == 0 else Ui.SKY
	var panel := Ui.panel(root, "TimingPanel", Rect2(16, 16, 238, 132), accent, Ui.RACE_SURFACE)
	var identity := Ui.label(panel, "Identity", "P%d" % (index + 1), 23, accent)
	Ui.place(identity, Rect2(12, 4, 54, 32))
	var laps := Ui.label(panel, "Laps", tr("圈数 %d / 2") % 1, 19)
	Ui.place(laps, Rect2(66, 8, 156, 28))
	var total := Ui.label(panel, "Total", tr("总用时  %s") % "--:--.---", 18, Ui.MUTED)
	Ui.place(total, Rect2(12, 48, 216, 30))
	var lap := Ui.label(panel, "Lap", tr("本圈    %s") % "--:--.---", 18)
	Ui.place(lap, Rect2(12, 86, 216, 30))
	var rank_panel := Ui.panel(root, "RankPanel", Rect2(), Ui.RACE_EDGE, Ui.RACE_SURFACE)
	var rank := Ui.label(rank_panel, "Rank", tr("准备"), 22)
	Ui.place(rank, Rect2(0, 0, 148, 44))
	var speed_panel := Ui.panel(root, "SpeedPanel", Rect2(), accent, Ui.RACE_SURFACE)
	var speed := Ui.label(speed_panel, "Speed", "0 km/h", 34)
	Ui.place(speed, Rect2(0, 0, 204, 58))
	var notice_panel := Ui.panel(root, "NoticePanel", Rect2(), Ui.WARNING, Ui.RACE_SURFACE)
	notice_panel.hide()
	var notice := Ui.label(notice_panel, "Notice", "", 21, Ui.WARNING)
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for label in [identity, laps, total, lap, rank, speed, notice]:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var minimap := preload("res://scripts/race_minimap.gd").new()
	minimap.name = "RaceMinimap"
	minimap.setup(_track, cars[index], [cars[1 - index]])
	root.add_child(minimap)
	_readouts.append({
		"minimap": minimap, "layer": layer, "panel": panel, "laps": laps, "total": total, "lap": lap,
		"rank_panel": rank_panel, "rank": rank, "speed_panel": speed_panel, "speed": speed,
		"notice_panel": notice_panel, "notice": notice,
	})
	view.size_changed.connect(_fit_hud.bind(index))
	_fit_hud(index)

func _fit_hud(index: int) -> void:
	var readout: Dictionary = _readouts[index]
	var size := Vector2(views[index].size)
	# 按半屏布局，以640宽为基准；大窗口保留可读字号，窄窗口等比缩放。
	var scale_factor := minf(1.25, minf(size.x / 640.0, size.y / 720.0))
	readout.layer.transform = Transform2D(0.0, Vector2.ONE * scale_factor, 0.0, Vector2.ZERO)
	var canvas := size / scale_factor
	# 共享暂停按钮使用原生像素，缩小半屏时仍要留出它的高度。
	var rank_y := maxf(60.0, 58.0 / scale_factor)
	readout.minimap.position = Vector2(canvas.x - 270, rank_y + 54)
	Ui.place(readout.rank_panel, Rect2(canvas.x - 164, rank_y, 148, 44))
	Ui.place(readout.speed_panel, Rect2(canvas.x * 0.5 - 102, canvas.y - 83, 204, 58))
	const NOTICE_WIDTH := 440.0
	Ui.place(readout.notice_panel, Rect2((canvas.x - NOTICE_WIDTH) * 0.5, maxf(166.0, rank_y + 50.0), NOTICE_WIDTH, 64))
	Ui.place(readout.notice, Rect2(16, 0, NOTICE_WIDTH - 32, 64))

func activate() -> void:
	_follow.clear_current(false)
	_follow.set_process(false)
	_follow.set_process_unhandled_input(false)
	_follow.get_node("ViewToastLayer").hide()
	# 两辆车处于同一 World3D，共享一个监听器，避免双份混音。
	views[0].audio_listener_enable_3d = true
	_display.show()
	get_parent().get_node("HUD").hide()

func show_controls() -> void:
	_guide_previous_focus = get_viewport().gui_get_focus_owner()
	_guide = CanvasLayer.new()
	_guide.name = "SplitGuide"
	_guide.layer = 92
	add_child(_guide)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_guide.add_child(root)
	Ui.install(root)
	var shade := ColorRect.new()
	shade.color = Color("0b1220")
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(shade)
	var stage := Ui.stage(root)
	var title := Ui.label(stage, "GuideTitle", tr("双人操作说明"), 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(title, Rect2(70, 42, 1226, 60))
	for i in range(2):
		ControlCards.build(stage, i, Rect2(70 + i * 636, 126, 590, 386))
	var hint := Ui.label(stage, "SharedRules", tr("Esc 暂停双方 · 两圈对赛 · 完赛即停车"), 20)
	Ui.place(hint, Rect2(70, 534, 1226, 36))
	var mechanisms := Ui.label(stage, "Mechanisms", tr("近距冲线摄影：%s · 双人对赛不显示或录制幽灵") % (tr("开启") if GameState.photo_finish_enabled else tr("关闭")), 17, Ui.SKY)
	Ui.place(mechanisms, Rect2(70, 574, 1226, 28))
	var rollover := Ui.label(stage, "KeyboardNote", tr("部分键盘同时多键可能漏键；比赛中可在暂停菜单重看操作。"), 16, Ui.MUTED)
	rollover.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(rollover, Rect2(70, 606, 650, 54))
	var button := Ui.button(stage, "GuideContinue", tr("返回暂停菜单（Esc）"), Rect2(730, 624, 566, 50), Ui.RED)
	button.pressed.connect(_close_guide)
	button.grab_focus()

func _close_guide() -> void:
	remove_child(_guide)
	_guide.queue_free()
	_guide = null
	if is_instance_valid(_guide_previous_focus):
		_guide_previous_focus.grab_focus()

func _input(event: InputEvent) -> void:
	if not is_instance_valid(_guide) or GameState.phase_name() == "EXIT_CONFIRM": return
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close_guide()

func begin() -> void:
	_photo.begin()
	for car in cars:
		car.start_locked = false
		car.begin_lap_timing(GameState.race_start_ms)

func _process(_delta: float) -> void:
	_audio.tick()
	if _ranking == null: return
	var rows: Array = _ranking.standings()
	for i in range(cars.size()):
		var car: VehicleBody3D = cars[i]
		var ui: Dictionary = _readouts[i]
		var id := "player" if i == 0 else "p2"
		var entry: Dictionary = {}
		for row in rows:
			if row.id == id: entry = row
		var done: bool = entry.get("finished", false)
		ui.laps.text = tr("已完赛") if done else tr("圈数 %d / 2") % mini(car.laps_done + 1, 2)
		ui.total.text = tr("总用时  %s") % _time(float(entry.total) if done else GameState.race_total_time())
		ui.lap.text = tr("末圈    %s") % _time(car.lap_last) if done else tr("本圈    %s") % _time(car.current_lap_time())
		ui.rank.text = tr("第 %d / 2 名") % int(entry.get("rank", 1))
		ui.speed.text = "%d km/h" % roundi(car.linear_velocity.length() * 3.6)
		ui.notice.text = tr("已完赛，等待另一位车手") if done else (tr("逆向行驶 · 请调整方向") if car.wrong_way else "")
		ui.notice_panel.visible = not ui.notice.text.is_empty()

func _on_finished(laps: int, car: VehicleBody3D) -> void:
	if not _ranking.record_finish(car, laps): return
	_photo.sample(true)
	car.finish_input_locked = true
	car.set_collision_layer_value(2, false)
	car.set_collision_mask_value(2, false)
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.freeze = true
	if _ranking.is_finished(cars[0]) and _ranking.is_finished(cars[1]) and not _finish_queued:
		_finish_queued = true
		call_deferred("_show_result")

func _show_result() -> void:
	var rows: Array = _ranking.standings()
	if not GameState.finish_classified_race(rows, cars[0].laps_target): return
	GameState.finish_snapshot["split_screen"] = true
	GameState.save_race_record()
	if _photo.start(rows):
		views[0].audio_listener_enable_3d = false
		_display.hide()
		return
	get_parent()._show_finish_menu()

func _finish_replay() -> void:
	views[0].audio_listener_enable_3d = true
	_display.show()
	get_parent()._show_finish_menu()

static func _time(value: float) -> String:
	return "%02d:%06.3f" % [int(value / 60.0), fmod(value, 60.0)]
