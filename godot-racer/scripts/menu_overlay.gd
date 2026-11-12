extends Control
## 首页设置/帮助。依赖与关闭回调经setup注入；不持有第二套比赛设置。

signal closed

const Ui := preload("res://scripts/ui_theme.gd")
const ControlCards := preload("res://scripts/split_control_cards.gd")
static var _help_resolver: RefCounted

## 键名到中文的显示别名；未列出的键直接用引擎名称（W/S/A/D/R/V/M 等）。
const KEY_ALIAS := {"Space": "空格", "Escape": "ESC", "Enter": "回车"}
const CONTROL_LABELS := {
	"accelerate": "油门", "brake_reverse": "刹车 / 倒车", "steer_left": "左转", "steer_right": "右转",
	"handbrake": "手刹", "drift": "漂移（按住）", "reset": "复位脱困", "camera_view": "切换视角",
	"camera_rear": "按住后视", "camera_orbit": "环视", "ui_cancel": "暂停 / 返回 / 退出确认",
	"ui_accept": "菜单确认",
}

var _state: Node
var _accent := Ui.SKY
var _kind := "settings"
var _ai: Button
var _fps: Button
var _racing_buttons: Dictionary = {}
var _music: Node
var _music_button: Button
var _language: HBoxContainer
var _language_status: Label
var _steering_slider: HSlider
var _steering_value: Label
var _help_panel: Panel
var _help_content: Control
var _help_tabs: Array[Button] = []
var _help_back: Button
var _drift_status: Label
var _drift_buttons: Array[Button] = []
var _rebind_player := -1


func setup(state: Node, color: Color, kind: String, music: Node = null) -> void:
	_state = state
	_accent = color
	_kind = kind
	_music = music


func _ready() -> void:
	name = "MenuOverlay"
	size = Ui.BASE_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.01, 0.02, 0.04, 0.64)
	shade.size = Ui.BASE_SIZE
	add_child(shade)
	var settings_page := _kind == "settings"
	var panel := Ui.panel(self, "OverlayPanel", Rect2(674, 12, 644, 681) if settings_page
		else Rect2(233, 60, 900, 585), Ui.BORDER)
	var width := panel.size.x
	var title_text := "最佳纪录" if _kind == "records" else ("设置" if settings_page else "操作帮助")
	var title := Ui.label(panel, "OverlayTitle", title_text, 38)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(title, Rect2(36, 25, width - 72, 60))
	var subtitle := "自定义你的游戏体验" if settings_page else (
		"本地个人最佳 · 五条赛道" if _kind == "records" else "熟悉操作，专注下一条赛道")
	var note := Ui.label(panel, "OverlaySubtitle", subtitle, 17, Ui.MUTED)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(note, Rect2(36, 87, width - 72, 30))
	var divider := ColorRect.new()
	divider.color = Ui.RED
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.place(divider, Rect2(36, 123, width - 72, 2))
	panel.add_child(divider)
	var back := Ui.button(panel, "CloseOverlay", "完成并返回  ›" if settings_page else "返回  ›",
		Rect2(36, panel.size.y - 82, width - 72, 52), Ui.RED)
	Ui.style_button(back, Ui.RED, true)
	back.pressed.connect(func() -> void: closed.emit())
	var controls: Array[Control] = []
	if settings_page:
		_music_button = _setting_row(panel, "MusicButton", "背景音乐", 136)
		_music_button.disabled = _music == null
		if _music != null:
			_music_button.pressed.connect(func(): _music.set_enabled(not _music.enabled))
			_music.enabled_changed.connect(_refresh_music)
		_refresh_music(_music.enabled if _music != null else false)
		_fps = _setting_row(panel, "FpsButton", "画面帧率上限", 182)
		_ai = _setting_row(panel, "AiButton", "AI 对手", 228)
		_ai.pressed.connect(_toggle_ai)
		_fps.pressed.connect(_toggle_fps)
		controls.assign([_music_button, _fps, _ai])
		if _music == null: controls.erase(_music_button)
		var index := 0
		var labels := {"dynamic_chase_enabled": "轻度动态追赶", "ghost_enabled": "组合最佳幽灵", "photo_finish_enabled": "终点摄影", "camera_shake_enabled": "轻微碰撞震动"}
		for key in ["dynamic_chase_enabled", "ghost_enabled", "photo_finish_enabled", "camera_shake_enabled"]:
			var button := _setting_row(panel, key, labels[key], 274 + index * 46)
			button.pressed.connect(func(): _state.toggle_racing_option(key); _refresh())
			_racing_buttons[key] = button
			controls.append(button)
			index += 1
		var steering_title := Ui.label(panel, "SteeringTitle", "转向灵敏度 · 默认 1.0×", 18)
		steering_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Ui.place(steering_title, Rect2(36, 458, 390, 28))
		_steering_value = Ui.label(panel, "SteeringValue", "", 18, Ui.SKY)
		_steering_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		Ui.place(_steering_value, Rect2(440, 458, 168, 28))
		_steering_slider = HSlider.new()
		_steering_slider.name = "SteeringSlider"
		_steering_slider.min_value = 0.6
		_steering_slider.max_value = 1.5
		_steering_slider.step = 0.05
		_steering_slider.value = _state.steering_sensitivity
		_steering_slider.tooltip_text = "调节转向与回中的响应速度；保留高速抓地与舵角限制。"
		Ui.place(_steering_slider, Rect2(36, 488, 572, 28))
		Ui.style_speed_slider(_steering_slider)
		panel.add_child(_steering_slider)
		_steering_value.text = "%.2f×" % _state.steering_sensitivity
		_steering_slider.value_changed.connect(_change_steering)
		controls.append(_steering_slider)
		var language_title := Ui.label(panel, "LanguageTitle", "语言", 19)
		language_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		language_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		Ui.place(language_title, Rect2(36, 526, 286, 42))
		_language = preload("res://scripts/language_selector.gd").new()
		_language.name = "LanguageSelector"
		Ui.place(_language, Rect2(330, 526, 278, 42))
		panel.add_child(_language)
		_language.select_code(_state.language_choice)
		_language.language_changed.connect(_select_language)
		_language_status = Ui.label(panel, "LanguageStatus", "", 16, Ui.WARNING)
		_language_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Ui.place(_language_status, Rect2(36, 569, 572, 24))
		controls.append_array([_language.left_button, _language.right_button])
		_refresh()
		controls.append(back)
	elif _kind == "records":
		if not _state.records.last_error.is_empty(): note.text = tr(_state.records.last_error)
		var headers := Ui.label(panel, "RecordsHeaders", "赛道", 15, Ui.MUTED)
		Ui.place(headers, Rect2(52, 139, 330, 30))
		for column in range(2):
			var header := Ui.label(panel, "RecordHeader%d" % column,
				"普通两圈" if column == 0 else "无限单圈", 15, Ui.MUTED)
			header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			Ui.place(header, Rect2(418 + column * 218, 139, 200, 30))
		for i in range(_state.level_count()):
			var cfg: Resource = _state.get_level(i)
			var id := cfg.resource_path.get_file().get_basename()
			var row := Ui.panel(panel, "RecordLevel%d" % (i + 1), Rect2(36, 178 + i * 58, 828, 50), Ui.BORDER)
			var track := Ui.label(row, "TrackName", "%02d   %s" % [i + 1, tr(cfg.display_name)], 19)
			track.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			Ui.place(track, Rect2(16, 0, 350, 50))
			for column in range(2):
				var time_label := Ui.label(row, "BestTime%d" % column,
					_state.RaceRecords.time_text(_state.records.best_time(id, column == 1)), 21, Ui.TEXT)
				time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				Ui.place(time_label, Rect2(382 + column * 218, 0, 200, 50))
		var record_note := Ui.label(panel, "RecordsNote", "同关不同组合 / 极速合并统计；完成比赛后自动更新纪录", 14, Ui.MUTED)
		record_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		Ui.place(record_note, Rect2(42, 464, 810, 40))
		controls.append(back)
	else:
		_build_help(panel, back)
		return
	Ui.focus_ring(controls)
	controls[0].grab_focus()


func _build_help(panel: Panel, back: Button) -> void:
	_help_panel = panel
	_help_back = back
	for i in range(2):
		var tab := Ui.button(panel, "SoloHelpTab" if i == 0 else "SplitHelpTab",
			"单人操作" if i == 0 else "本地双人", Rect2(36 + i * 420, 134, 408, 40), Ui.SKY)
		_help_tabs.append(tab)
		tab.pressed.connect(_show_help_mode.bind(i))
	_help_tabs[0].focus_neighbor_right = _help_tabs[0].get_path_to(_help_tabs[1])
	_help_tabs[1].focus_neighbor_left = _help_tabs[1].get_path_to(_help_tabs[0])
	_show_help_mode(1 if _state.split_screen else 0)


func _show_help_mode(mode: int) -> void:
	_rebind_player = -1
	if _help_content != null:
		_help_panel.remove_child(_help_content)
		_help_content.queue_free()
	_drift_buttons.clear()
	_help_content = Control.new()
	_help_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help_panel.add_child(_help_content)
	if mode == 0:
		for i in range(6):
			var row := Ui.panel(_help_content, "HelpRow%d" % i, Rect2(36, 184 + i * 44, 828, 40), Ui.BORDER)
			_help_icons(row, i)
	else:
		for player in range(2):
			_add_drift_binding(ControlCards.build(_help_content, player, Rect2(36 + player * 420, 184, 408, 260), true))
	var rules := "进入赛道后倒计时 3 秒，出发时统一计时" if mode == 0 else "Esc 暂停双方 · 两圈对赛 · 完赛即停车"
	var hint := Ui.label(_help_content, "HelpRaceHint", rules, 16, Ui.MUTED)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(hint, Rect2(42, 449, 816, 23))
	_drift_status = Ui.label(_help_content, "DriftBindingStatus", "", 16, Ui.MUTED)
	_drift_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(_drift_status, Rect2(42, 474, 816, 24))
	_show_drift_status("")
	_refresh_drift_bindings()
	var controls: Array[Control] = []
	controls.assign(_help_tabs)
	controls.append_array(_drift_buttons)
	controls.append(_help_back)
	Ui.focus_ring(controls)
	for i in range(_help_tabs.size()):
		Ui.style_button(_help_tabs[i], Ui.SKY, i == mode)
	_help_tabs[mode].grab_focus()


func _add_drift_binding(button: Button) -> void:
	var player := _drift_buttons.size()
	button.tooltip_text = "点击后按下新键，Esc 取消"
	button.pressed.connect(_begin_drift_rebind.bind(player))
	button.focus_exited.connect(_leave_drift_binding.bind(player))
	_drift_buttons.append(button)


func _help_icons(row: Control, index: int) -> void:
	var groups := [["accelerate", "brake_reverse"], ["steer_left", "steer_right"], ["handbrake", "drift"],
		["reset", "camera_view"], ["camera_rear", "camera_orbit"], ["ui_cancel"]]
	var device := 0
	var pads := Input.get_connected_joypads()
	if not pads.is_empty():
		var pad_name := Input.get_joy_name(pads[0]).to_lower()
		device = 3 if "playstation" in pad_name or "dual" in pad_name else (2 if "switch" in pad_name else 1)
		if _help_resolver == null:
			_help_resolver = load("res://addons/godot_input_icons/input_icon_resolver.gd").new()
	var content := HBoxContainer.new()
	content.name = "Binding"
	content.add_theme_constant_override("separation", 12)
	Ui.place(content, Rect2(22, 2, 784, 36))
	row.add_child(content)
	for action: String in groups[index]:
		if action == "drift":
			var binding := Ui.button(content, "DriftBinding1", "", Rect2(), Ui.SKY)
			binding.add_theme_font_size_override("font_size", 16)
			binding.custom_minimum_size = Vector2(164, 36)
			_add_drift_binding(binding)
		elif device == 0 or action == "camera_orbit":
			var key := Ui.label(content, action + "Key", _binding(action, ""), 17, Ui.BACKGROUND)
			key.custom_minimum_size = Vector2(104 if action == "camera_orbit" else 62, 36)
			key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			key.add_theme_stylebox_override("normal", Ui.box(Ui.TEXT, Ui.SKY, 2, 8))
		else:
			var icon := TextureRect.new()
			icon.name = action + "Icon"
			icon.custom_minimum_size = Vector2(52, 36)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.texture = _help_resolver.get_icon(device, action)
			content.add_child(icon)
		var text := Ui.label(content, action + "Label", CONTROL_LABELS[action], 19)
		text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _begin_drift_rebind(player: int) -> void:
	_drift_buttons[player].grab_focus()
	_rebind_player = player
	_refresh_drift_bindings()
	_show_drift_status("按 Esc 取消")


func _leave_drift_binding(player: int) -> void:
	if _rebind_player == player:
		_finish_drift_rebind("")


func _finish_drift_rebind(message: String, warning := false) -> void:
	_rebind_player = -1
	_refresh_drift_bindings()
	_show_drift_status(message, warning)


func _show_drift_status(message: String, warning := false) -> void:
	_drift_status.text = "选择漂移键可修改。入弯时按住，松开收漂。" if message.is_empty() else message
	_drift_status.add_theme_color_override("font_color", Ui.WARNING if warning else Ui.MUTED)


func _refresh_drift_bindings() -> void:
	for player in range(_drift_buttons.size()):
		var key_name := tr(GameState.drift_key_name(GameState.drift_keys[player]))
		if _rebind_player == player:
			key_name = tr("按下新键…")
		_drift_buttons[player].text = key_name


func _input(event: InputEvent) -> void:
	if _rebind_player < 0 or not event is InputEventKey:
		return
	get_viewport().set_input_as_handled()
	var key := event as InputEventKey
	if not key.pressed or key.is_echo():
		return
	if key.physical_keycode == KEY_ESCAPE or key.keycode == KEY_ESCAPE:
		_finish_drift_rebind("已取消，保留原按键")
		return
	var result: String = _state.save_drift_key(_rebind_player, Vector2i(key.physical_keycode, key.location))
	match result:
		"": _finish_drift_rebind("已保存漂移键")
		"save_failed":
			_finish_drift_rebind("无法保存漂移键设置", true)
			Sfx.play_clip("界面错误", -19.0)
		_:
			_show_drift_status(_drift_conflict_text(result), true)
			Sfx.play_clip("界面错误", -19.0)


func _drift_conflict_text(action: String) -> String:
	var action_name := action.trim_prefix("p1_").trim_prefix("p2_")
	if not CONTROL_LABELS.has(action_name):
		return "按键已占用或为系统保留，请换一个"
	var label: String = tr("后视") if action_name == "camera_rear" else tr(CONTROL_LABELS[action_name])
	if action.begins_with("p1_") or action.begins_with("p2_"):
		label = "%s · %s" % [action.left(2).to_upper(), label]
	return tr("该键已用于 %s，请换一个") % label


func _select_language(lang_code: String) -> void:
	if _state.set_language(lang_code):
		_language_status.text = ""
		_refresh_music(_music.enabled if _music != null else false)
		_refresh()
	else:
		_language.select_code(_state.language_choice)
		_language_status.text = "无法保存语言设置"


func _setting_row(parent: Control, node_name: String, text: String, y: float) -> Button:
	var button := Ui.button(parent, node_name, "", Rect2(36, y, 572, 42), Ui.RED)
	var caption := Ui.label(button, "SettingCaption", text, 19)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Ui.place(caption, Rect2(10, 0, 350, 42))
	var value := Ui.label(button, "SettingValue", "", 19, Ui.TEXT)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Ui.place(value, Rect2(368, 0, 194, 42))
	return button


func _setting_value(button: Button, text: String, enabled := false) -> void:
	var value := button.get_node("SettingValue") as Label
	value.text = text
	value.add_theme_color_override("font_color", Ui.RED if enabled else Ui.MUTED)


func _change_steering(value: float) -> void:
	if _state.set_steering_sensitivity(value):
		_steering_value.text = "%.2f×" % _state.steering_sensitivity
	else:
		_steering_slider.set_value_no_signal(_state.steering_sensitivity)
		_steering_value.text = "保存失败"


func _refresh_music(enabled: bool) -> void:
	_setting_value(_music_button, "不可用" if _music == null else ("●  开启" if enabled else "○  关闭"), enabled)


## 有已连接手柄时优先显示手柄绑定，其余场合保留键鼠提示。
func _binding(action: String, fallback: String) -> String:
	if not InputMap.has_action(action):
		push_warning("menu_overlay: 缺少输入动作 %s" % action)
		return fallback
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		push_warning("menu_overlay: 输入动作 %s 未绑定按键" % action)
		return fallback
	var ev: InputEvent = events[0]
	if not Input.get_connected_joypads().is_empty():
		for candidate in events:
			if candidate is InputEventJoypadButton or candidate is InputEventJoypadMotion:
				ev = candidate
				break
	if ev is InputEventKey:
		var key := OS.get_keycode_string(ev.physical_keycode)
		if key.is_empty():
			key = ev.as_text().get_slice("+", 0)
		return fallback if key.is_empty() else String(KEY_ALIAS.get(key, key))
	if ev is InputEventMouseButton:
		match ev.button_index:
			MOUSE_BUTTON_LEFT: return "鼠标左键"
			MOUSE_BUTTON_RIGHT: return "鼠标右键"
			MOUSE_BUTTON_MIDDLE: return "鼠标中键"
	if ev is InputEventJoypadMotion:
		match ev.axis:
			JOY_AXIS_TRIGGER_RIGHT: return "右扳机"
			JOY_AXIS_TRIGGER_LEFT: return "左扳机"
			JOY_AXIS_LEFT_X: return "左摇杆←" if ev.axis_value < 0.0 else "左摇杆→"
	if ev is InputEventJoypadButton:
		match ev.button_index:
			JOY_BUTTON_X: return "X/□"
			JOY_BUTTON_Y: return "Y/△"
			JOY_BUTTON_BACK: return "选择键"
			JOY_BUTTON_RIGHT_SHOULDER: return "右肩键"
			JOY_BUTTON_START: return "菜单键"
			JOY_BUTTON_B: return "B/○"
		return ev.as_text()
	return fallback


func _toggle_ai() -> void:
	_state.set("ai_enabled", not bool(_state.get("ai_enabled")))
	_refresh()


func _toggle_fps() -> void:
	_state.call("set_render_fps", 60 if int(_state.get("render_fps")) >= 120 else 120)
	_refresh()


func _refresh() -> void:
	var ai_enabled := bool(_state.get("ai_enabled"))
	_setting_value(_ai, "●  开启" if ai_enabled else "○  关闭", ai_enabled)
	_setting_value(_fps, "‹   %d FPS   ›" % int(_state.get("render_fps")))
	for key in _racing_buttons:
		var enabled := bool(_state.get(key))
		_setting_value(_racing_buttons[key], "●  开启" if enabled else "○  关闭", enabled)
