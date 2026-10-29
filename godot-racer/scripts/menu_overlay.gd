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
var _music: Node
var _music_button: Button


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
	shade.color = Color(0, 0, 0, 0.8)
	shade.size = Ui.BASE_SIZE
	add_child(shade)
	var panel := Ui.panel(self, "OverlayPanel", Rect2(433, 120, 500, 465), _accent)
	var title := Ui.label(panel, "OverlayTitle", "比赛设置" if _kind == "settings" else "操作帮助", 32)
	Ui.place(title, Rect2(24, 24, 452, 48))
	var back := Ui.button(panel, "CloseOverlay", "返回首页", Rect2(24, 369, 452, 48), _accent)
	back.pressed.connect(func() -> void: closed.emit())
	var controls: Array[Control] = []
	if _kind == "settings":
		_ai = Ui.button(panel, "AiButton", "", Rect2(24, 104, 452, 48), _accent)
		_fps = Ui.button(panel, "FpsButton", "", Rect2(24, 180, 452, 48), _accent)
		_ai.pressed.connect(_toggle_ai)
		_fps.pressed.connect(_toggle_fps)
		if _music != null:
			_music_button = Ui.button(panel, "MusicButton", "", Rect2(24, 244, 452, 48), _accent)
			_music_button.pressed.connect(func(): _music.set_enabled(not _music.enabled))
			_music.enabled_changed.connect(_refresh_music)
			_refresh_music(_music.enabled)
		_refresh()
		var hint := Ui.label(panel, "SettingsHint", "设置沿用当前选择，返回后可直接开赛。", 15, Ui.MUTED)
		Ui.place(hint, Rect2(24, 308, 452, 48))
		controls.assign([_ai, _fps])
		if _music_button != null:
			controls.append(_music_button)
		controls.append(back)
	else:
		var help := Ui.label(panel, "HelpText", _help_text(), 18, Ui.MUTED)
		help.add_theme_constant_override("line_spacing", 12)
		Ui.place(help, Rect2(24, 94, 452, 256))
		controls.append(back)
	Ui.focus_ring(controls)
	controls[0].grab_focus()


## 操作说明从 InputMap 读取真实绑定，改键位后文本自动跟随，不会退化成假说明。
## ESC 不在 InputMap 内（由各页 _unhandled_input 直接处理），故该行保留字面量。
func _help_text() -> String:
	return "\n".join([
		"%s 油门 · %s 刹车/倒车" % [_binding("accelerate", "W"), _binding("brake_reverse", "S")],
		"%s / %s 转向 · %s 手刹" % [_binding("steer_left", "A"), _binding("steer_right", "D"),
			_binding("handbrake", "空格")],
		"%s 复位脱困 · %s 切换视角" % [_binding("reset", "R"), _binding("camera_view", "V")],
		"按住 %s 向后看 · %s 环视" % [_binding("camera_rear", "C"), _binding("camera_orbit", "鼠标右键")],
		"ESC 暂停 / 返回 / 退出确认",
		"进入赛道后倒计时 3 秒，出发时统一计时",
	])


## 取动作绑定的第一个按键名；取不到时 push_warning 并回退到当前真实键位。
func _binding(action: String, fallback: String) -> String:
	if not InputMap.has_action(action):
		push_warning("menu_overlay: 缺少输入动作 %s" % action)
		return fallback
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		push_warning("menu_overlay: 输入动作 %s 未绑定按键" % action)
		return fallback
	var ev := events[0]
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


func _refresh_music(value: bool) -> void:
	_music_button.text = "背景音乐：%s" % ("开启" if value else "关闭")
