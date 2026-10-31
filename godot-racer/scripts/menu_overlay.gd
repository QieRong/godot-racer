extends Control
## 首页设置/帮助。依赖与关闭回调经setup注入；不持有第二套比赛设置。

signal closed

const Ui := preload("res://scripts/ui_theme.gd")

## 键名到中文的显示别名；未列出的键直接用引擎名称（W/S/A/D/R/V/M 等）。
const KEY_ALIAS := {"Space": "空格", "Escape": "ESC", "Enter": "回车"}

var _state: Node
var _accent := Ui.SKY
var _kind := "settings"
var _ai: Button
var _fps: Button


func setup(state: Node, color: Color, kind: String, _music: Node = null) -> void:
	_state = state
	_accent = color
	_kind = kind


func _ready() -> void:
	name = "MenuOverlay"
	size = Ui.BASE_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.8)
	shade.size = Ui.BASE_SIZE
	add_child(shade)
	var panel := Ui.panel(self, "OverlayPanel", Rect2(433, 120, 500, 465), _accent)
	var title_text := "最佳纪录" if _kind == "records" else ("比赛设置" if _kind == "settings" else "操作帮助")
	var title := Ui.label(panel, "OverlayTitle", title_text, 32)
	Ui.place(title, Rect2(24, 24, 452, 48))
	var back := Ui.button(panel, "CloseOverlay", "返回首页", Rect2(24, 369, 452, 48), _accent)
	back.pressed.connect(func() -> void: closed.emit())
	var controls: Array[Control] = []
	if _kind == "settings":
		_ai = Ui.button(panel, "AiButton", "", Rect2(24, 104, 452, 48), _accent)
		_fps = Ui.button(panel, "FpsButton", "", Rect2(24, 180, 452, 48), _accent)
		_ai.pressed.connect(_toggle_ai)
		_fps.pressed.connect(_toggle_fps)
		_refresh()
		var hint := Ui.label(panel, "SettingsHint", "设置沿用当前选择，返回后可直接开赛。", 15, Ui.MUTED)
		Ui.place(hint, Rect2(24, 244, 452, 48))
		controls.assign([_ai, _fps])
		controls.append(back)
	elif _kind == "records":
		var note := Ui.label(panel, "RecordsNote", "本地个人纪录 · 同关不同组合/极速合并统计", 14, Ui.MUTED)
		Ui.place(note, Rect2(24, 78, 452, 30))
		if not _state.records.last_error.is_empty(): note.text = _state.records.last_error
		var scroll := ScrollContainer.new()
		scroll.name = "RecordsScroll"
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.follow_focus = true
		Ui.place(scroll, Rect2(24, 116, 452, 235))
		panel.add_child(scroll)
		var rows := VBoxContainer.new()
		rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rows.add_theme_constant_override("separation", 12)
		scroll.add_child(rows)
		for i in range(_state.level_count()):
			var cfg: Resource = _state.get_level(i)
			var id := cfg.resource_path.get_file().get_basename()
			var row := Label.new()
			row.name = "RecordLevel%d" % (i + 1)
			row.text = "%s\n普通两圈  %s\n无限单圈  %s" % [cfg.display_name,
				_state.RaceRecords.time_text(_state.records.best_time(id, false)),
				_state.RaceRecords.time_text(_state.records.best_time(id, true))]
			row.add_theme_font_size_override("font_size", 16)
			row.focus_mode = Control.FOCUS_ALL
			rows.add_child(row)
			controls.append(row)
		controls.append(back)
	else:
		var help := Ui.label(panel, "HelpText", _help_text(), 18, Ui.MUTED)
		help.add_theme_constant_override("line_spacing", 12)
		Ui.place(help, Rect2(24, 94, 452, 256))
		controls.append(back)
	Ui.focus_ring(controls)
	controls[0].grab_focus()


## 操作说明从 InputMap 读取真实绑定，改键位后文本自动跟随，不会退化成假说明。
func _help_text() -> String:
	return "\n".join([
		"%s 油门 · %s 刹车/倒车" % [_binding("accelerate", "W"), _binding("brake_reverse", "S")],
		"%s / %s 转向 · %s 手刹" % [_binding("steer_left", "A"), _binding("steer_right", "D"),
			_binding("handbrake", "空格")],
		"%s 复位脱困 · %s 切换视角" % [_binding("reset", "R"), _binding("camera_view", "V")],
		"按住 %s 向后看 · %s 环视" % [_binding("camera_rear", "C"), _binding("camera_orbit", "鼠标右键")],
		"%s 暂停 / 返回 / 退出确认" % _binding("ui_cancel", "ESC"),
		"进入赛道后倒计时 3 秒，出发时统一计时",
	])


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
	_ai.text = "AI 对手：%s" % ("开启" if bool(_state.get("ai_enabled")) else "关闭")
	_fps.text = "渲染帧率：%d FPS" % int(_state.get("render_fps"))
