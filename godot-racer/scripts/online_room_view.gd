extends Control
## 红蓝白横屏共同房间页；按密度、安全区和可用宽度布局，不接管赛车手机版移植。
const BG := Color("0b1220")
const PANEL := Color("172235")
const TEXT := Color("f3f6fa")
const MUTED := Color("b8c2d1")
const SKY := Color("7fb3e8")
const RED := Color("ff454d")
var _session: Node
var _style: GDScript
var _info: Dictionary
var _canvas: Control
var _adjust: HBoxContainer
var _speed_actions: HBoxContainer
var _speed_heading: Label
var _speed_unit: Label
var _tight_height := false
var _wide: HBoxContainer
var _left: PanelContainer
var _right: VBoxContainer
var _footer_wide: HBoxContainer
var _actions: HBoxContainer
var _leave: Button
var _code: Label
var _rules: Label
var _network: Label
var _notice: Label
var _players: Array[Label] = []
var _player_roles: Array[Label] = []
var _player_panels: Array[PanelContainer] = []
var _speed_value: Label
var _speed_pending: Label
var _speed_slider: HSlider
var _speed_minus: Button
var _speed_plus: Button
var _ready_button: Button
var _start_button: Button
var _apply_button: Button
var _speed: SpinBox
var _last_revision := 0

func configure(session: Node, style: GDScript, track_info: Dictionary) -> void:
	_session = session
	_style = style
	_info = track_info.duplicate()

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Noto Sans CJK SC", "sans-serif"])
	theme = Theme.new()
	theme.default_font = font
	theme.default_font_size = 18
	var background := ColorRect.new()
	background.color = BG
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	_canvas = Control.new()
	add_child(_canvas)
	var margins := MarginContainer.new()
	margins.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]: margins.add_theme_constant_override("margin_" + side, 16)
	margins.add_theme_constant_override("margin_top", 8)
	margins.add_theme_constant_override("margin_bottom", 16)
	_canvas.add_child(margins)
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	margins.add_child(page)
	var header := HFlowContainer.new()
	header.add_theme_constant_override("h_separation", 20)
	header.add_theme_constant_override("v_separation", 8)
	page.add_child(header)
	var heading := VBoxContainer.new()
	heading.custom_minimum_size.x = 280
	heading.add_theme_constant_override("separation", 0)
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(heading)
	_label(heading, "联机对战", 24)
	_notice = _label(heading, "", 14, SKY)
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var room_code := HBoxContainer.new()
	room_code.add_theme_constant_override("separation", 12)
	header.add_child(room_code)
	var connection := VBoxContainer.new()
	connection.custom_minimum_size.x = 190
	room_code.add_child(connection)
	_code = _label(connection, "", 19)
	_network = _label(connection, "", 14, SKY)
	_button(room_code, "复制", SKY, 70).pressed.connect(_copy_code)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(body)
	_wide = HBoxContainer.new()
	_wide.add_theme_constant_override("separation", 16)
	_wide.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_wide)
	_left = _panel(_wide, Color("142136"), SKY, 8)
	_left.size_flags_stretch_ratio = 1.4
	_left.custom_minimum_size.x = 240
	var track := VBoxContainer.new()
	track.add_theme_constant_override("separation", 6)
	_left.add_child(track)
	var preview := TextureRect.new()
	preview.texture = _info.get("preview")
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	preview.custom_minimum_size.y = 72
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	track.add_child(preview)
	_label(track, str(_info.get("title", "")), 20)
	_rules = _label(track, "", 14)
	_rules.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_right = VBoxContainer.new()
	_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right.add_theme_constant_override("separation", 8)
	_right.custom_minimum_size.x = 300
	_wide.add_child(_right)
	var seats := HBoxContainer.new()
	seats.add_theme_constant_override("separation", 10)
	_right.add_child(seats)
	for slot in [0, 1]:
		var panel := _panel(seats, PANEL, SKY, 4)
		panel.custom_minimum_size.y = 52
		_player_panels.append(panel)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		panel.add_child(row)
		_label(row, "%02d" % (slot + 1), 26, RED if slot == 0 else SKY)
		var captions := VBoxContainer.new()
		captions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		captions.add_theme_constant_override("separation", 0)
		row.add_child(captions)
		var role := _label(captions, "", 14, MUTED)
		role.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_player_roles.append(role)
		_players.append(_label(captions, "", 18))
	var speed_panel := _panel(_right, Color("19283d"), SKY, 8)
	speed_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var speed_content := VBoxContainer.new()
	speed_content.alignment = BoxContainer.ALIGNMENT_CENTER
	speed_content.add_theme_constant_override("separation", 4)
	speed_panel.add_child(speed_content)
	var speed_heading := HBoxContainer.new()
	speed_content.add_child(speed_heading)
	_speed_heading = _label(speed_heading, "共同极速", 17)
	_speed_pending = _label(speed_heading, "", 15, SKY)
	_speed_pending.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_speed_pending.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_speed = SpinBox.new()
	_speed.min_value = 80
	_speed.max_value = 240
	_speed.step = 10
	_speed.hide()
	_canvas.add_child(_speed)
	_adjust = HBoxContainer.new()
	_adjust.add_theme_constant_override("separation", 12)
	speed_content.add_child(_adjust)
	_speed_minus = _button(_adjust, "−", SKY, 54)
	_speed_minus.pressed.connect(func(): _speed.value -= 10)
	_speed_value = _label(_adjust, "180", 42, RED)
	_speed_value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_speed_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speed_unit = _label(_adjust, "km/h", 16)
	_speed_unit.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_speed_plus = _button(_adjust, "+", SKY, 54)
	_speed_plus.pressed.connect(func(): _speed.value += 10)
	_speed_actions = HBoxContainer.new()
	_speed_actions.add_theme_constant_override("separation", 12)
	speed_content.add_child(_speed_actions)
	_speed_slider = HSlider.new()
	_speed_slider.min_value = 80
	_speed_slider.max_value = 240
	_speed_slider.step = 10
	_speed_slider.custom_minimum_size = Vector2(80, 52)
	_speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var rail := StyleBoxFlat.new()
	rail.bg_color = Color("59667f")
	rail.content_margin_top = 3
	rail.content_margin_bottom = 3
	_speed_slider.add_theme_stylebox_override("slider", rail)
	var active := rail.duplicate() as StyleBoxFlat
	active.bg_color = RED
	_speed_slider.add_theme_stylebox_override("grabber_area", active)
	_speed_slider.add_theme_stylebox_override("grabber_area_highlight", active)
	_speed_actions.add_child(_speed_slider)
	_speed_slider.value_changed.connect(func(value: float): _speed.value = value)
	_speed.value_changed.connect(func(_value: float): _sync_speed_controls())
	_apply_button = _button(_speed_actions, "应用设置", RED, 112)
	_apply_button.pressed.connect(_apply_speed)
	_footer_wide = HBoxContainer.new()
	_footer_wide.add_theme_constant_override("separation", 12)
	page.add_child(_footer_wide)
	_leave = _button(_footer_wide, "离开房间", SKY, 120)
	_leave.pressed.connect(_session.leave_room)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_footer_wide.add_child(spacer)
	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override("separation", 12)
	_footer_wide.add_child(_actions)
	_ready_button = _button(_actions, "准备", RED, 144)
	_ready_button.pressed.connect(_toggle_ready)
	_start_button = _button(_actions, "开始比赛", RED, 160)
	_start_button.pressed.connect(_session.request_start)
	_session.room_changed.connect(_refresh)
	_session.action_failed.connect(_show_error)
	_session.left_room.connect(func(): _notice.text = tr("已离开房间"))
	resized.connect(_layout)
	_layout()
	_refresh(_session.snapshot())

func _layout() -> void:
	if _canvas == null: return
	var safe := Rect2(Vector2.ZERO, size)
	var mobile: bool = OS.get_name() == "Android"
	var factor: float = maxf(1.0, float(DisplayServer.screen_get_dpi()) / 160.0) if mobile else 1.0
	if mobile:
		var display_safe := Rect2(DisplayServer.get_display_safe_area())
		var window_size := Vector2(DisplayServer.window_get_size())
		if display_safe.has_area() and window_size.x > 0 and window_size.y > 0:
			var ratio := size / window_size
			safe = safe.intersection(Rect2(display_safe.position * ratio, display_safe.size * ratio))
	_canvas.position = safe.position
	_canvas.scale = Vector2.ONE * factor
	_canvas.size = safe.size / factor
	var tight: bool = _canvas.size.y < 430
	if tight != _tight_height:
		_tight_height = tight
		_apply_button.reparent(_adjust if tight else _speed_actions, false)
		_apply_button.custom_minimum_size.x = 96 if tight else 112
		_adjust.add_theme_constant_override("separation", 6 if tight else 12)
		_speed_value.add_theme_font_size_override("font_size", 30 if tight else 42)
		_speed_heading.text = tr("共同极速 (km/h)") if tight else tr("共同极速")
		_speed_unit.visible = not tight
		_speed_actions.visible = not tight


func _box(fill: Color, edge: Color, padding := 12) -> StyleBox:
	var box: StyleBox = _style.new()
	box.set("bg_color", fill)
	box.set("border_color", edge)
	box.call("set_border_width_all", 2)
	for side in ["left", "top", "right", "bottom"]: box.set("content_margin_" + side, padding)
	return box

func _panel(parent: Node, fill: Color, edge: Color, padding := 12) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _box(fill, edge, padding))
	parent.add_child(panel)
	return panel

func _label(parent: Node, text: String, font_size: int, color := TEXT) -> Label:
	var label := Label.new()
	label.text = tr(text)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _button(parent: Node, text: String, color: Color, width: float) -> Button:
	var button := Button.new()
	button.text = tr(text)
	button.custom_minimum_size = Vector2(width, 52)
	button.add_theme_font_size_override("font_size", 19)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_disabled_color", MUTED)
	var fill := Color("a42639") if color == RED else PANEL
	button.add_theme_stylebox_override("normal", _box(fill, color, 8))
	button.add_theme_stylebox_override("hover", _box(fill.lightened(0.12), color, 8))
	button.add_theme_stylebox_override("pressed", _box(fill.darkened(0.15), color, 8))
	button.add_theme_stylebox_override("focus", _box(Color.TRANSPARENT, TEXT, 8))
	button.add_theme_stylebox_override("disabled", _box(PANEL.darkened(0.3), Color("415570"), 8))
	parent.add_child(button)
	return button

func _refresh(view: Dictionary) -> void:
	_ready_button.disabled = not _session.can_ready() and not _session.reconnect_available
	_start_button.disabled = not _session.can_start()
	_start_button.visible = _session.local_slot == 0
	_apply_button.disabled = not _session.can_edit()
	_speed.editable = _session.can_edit()
	if view.is_empty():
		_notice.text = tr("正在同步房间信息…")
		return
	_code.text = tr("房间码 %s %s") % [view.code.substr(0, 4), view.code.substr(4)]
	_rules.text = tr("%d 圈 · 共同极速 %d km/h · 车际碰撞开启") % [int(view.config.laps), roundi(view.config.speed_kmh)]
	_rules.text += "\n" + tr("赛道组合 %02d") % (int(view.config.combination) + 1) + " · " + tr(str(_info.get("conditions", "")))
	if _last_revision != int(view.revision):
		_speed.value = view.config.speed_kmh
		_notice.text = tr("比赛设置已更新，请重新准备") if _last_revision > 0 else tr("请核对规则并准备")
		_last_revision = int(view.revision)
	for slot in [0, 1]:
		var role := tr("房主") if slot == 0 else tr("玩家 2")
		if slot == _session.local_slot: role += tr("（你）")
		var status := tr("已准备") if view.ready[slot] else tr("未准备")
		if not view.present[slot]: status = tr("等待加入")
		elif view.phase == "LOADING": status = tr("已加载") if view.loaded[slot] else tr("正在加载…")
		elif view.phase == "COUNTDOWN": status = tr("等待共同发车")
		elif view.phase == "RACING": status = "GO"
		_player_roles[slot].text = role
		_players[slot].text = status
		var active: bool = view.present[slot] and (view.ready[slot] or view.phase != "ROOM")
		_player_panels[slot].add_theme_stylebox_override("panel", _box(Color("183c5a") if active else PANEL, SKY if active else Color("415570"), 4))
		_players[slot].add_theme_color_override("font_color", TEXT if active else MUTED)
	_ready_button.text = tr("取消准备") if view.ready[_session.local_slot] else tr("准备")
	if _session.reconnect_available: _ready_button.text = tr("重新连接房间")
	if _session.waiting_for_guest:
		_network.text = tr("等待玩家加入")
		_notice.text = tr("请将房间码发给另一位玩家")
		_sync_speed_controls()
		return
	_network.text = tr("连接已中断") if not _session.connected else (tr("RTT %d ms") % _session.best_rtt_ms if _session.best_rtt_ms >= 0 else tr("连接已建立") if _session.clock_ready else tr("测量时钟中…"))
	if not _session.connected:
		_notice.text = tr("连接已中断")
	elif view.phase == "LOADING": _notice.text = tr("等待双方加载完成")
	elif view.phase == "COUNTDOWN": _notice.text = tr("双方加载完成，等待共同发车")
	elif view.phase == "RACING": _notice.text = "GO"
	_sync_speed_controls()

func show_connection_status(message: String) -> void:
	_notice.text = message


func focus_actions() -> void:
	_leave.grab_focus()


func _sync_speed_controls() -> void:
	if _apply_button == null: return
	var view: Dictionary = _session.snapshot()
	var editable: bool = _session.can_edit()
	_speed_value.text = str(roundi(_speed.value))
	_speed_slider.set_value_no_signal(_speed.value)
	_speed_slider.editable = editable
	_speed_minus.disabled = not editable or _speed.value <= _speed.min_value
	_speed_plus.disabled = not editable or _speed.value >= _speed.max_value
	var changed: bool = not view.is_empty() and _speed.value != float(view.config.speed_kmh)
	_apply_button.disabled = not editable or not changed
	_speed_pending.text = tr("待应用") if editable and changed else (tr("本局生效") if editable else tr("房主设定"))
	_speed_pending.add_theme_color_override("font_color", RED if editable and changed else SKY)

func _copy_code() -> void:
	var view: Dictionary = _session.snapshot()
	if not view.is_empty(): DisplayServer.clipboard_set(view.code)

func _toggle_ready() -> void:
	if _session.reconnect_available:
		_session.reconnect_room()
		return
	var view: Dictionary = _session.snapshot()
	if not view.is_empty(): _session.set_ready(not view.ready[_session.local_slot])

func _apply_speed() -> void:
	var view: Dictionary = _session.snapshot()
	if view.is_empty(): return
	var config: Dictionary = view.config.duplicate(true)
	config.speed_kmh = _speed.value
	_session.update_config(config)

func _show_error(reason: String) -> void:
	_notice.text = tr("比赛设置已更新，请重新准备") if reason == "STALE_RULES" else tr("连接已中断，请离开房间后重新加入")

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_session.leave_room()
