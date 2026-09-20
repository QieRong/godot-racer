extends CanvasLayer
## 暂停菜单：ESC 呼出，继续 / 重新开始 / 选关 / 退出。
##
## 三个关键点（Godot 里最容易做错的地方）：
##   1. 暂停用 `get_tree().paused = true`，**不要**动 `Engine.time_scale`
##      （改 time_scale 会让所有 delta 变形，物理与计时的行为都会漂）。
##   2. 本节点必须 `process_mode = PROCESS_MODE_WHEN_PAUSED`，否则暂停后它自己也停了，
##      就再也按不动"继续"。
##   3. 暂停/恢复时清掉按住的输入，否则恢复瞬间车辆会带着暂停前的油门冲出去。

const MENU_SCENE := "res://scenes/menu.tscn"

var _panel: PanelContainer
var _title: Label
var _info: Label
var _buttons: Array[Button] = []


func _ready() -> void:
	visible = false
	# ⚠⚠ 必须是 ALWAYS，**不能**用 PROCESS_MODE_WHEN_PAUSED。
	#
	# 这里原来写的是 WHEN_PAUSED，注释理由是"否则暂停后它自己也停了、按不动继续"。
	# 那个担心是对的，但选错了模式：在 Godot 4 里 `process_mode` **同时决定
	# 输入是否投递**（_input / _unhandled_input 都受它管），而 WHEN_PAUSED 的含义是
	# "**只在暂停时**处理"。于是没暂停的时候这个节点收不到任何输入 ——
	# ESC 永远触发不了 pause()，玩家按 ESC 完全没反应（暂停菜单形同虚设）。
	#
	# 这个 bug 靠读代码没看出来（代码看起来"很合理"），是
	# `--check=pause` 喂真实按键事件之后才暴露的。
	# ALWAYS 同样满足"暂停时还能按继续"这个原始需求，且两种状态都收输入。
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 10
	_build_ui()


func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(_panel)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 10)
	_panel.add_child(rows)

	_title = Label.new()
	_title.text = "已暂停"
	_title.add_theme_font_size_override("font_size", 30)
	rows.add_child(_title)

	_info = Label.new()
	_info.add_theme_font_size_override("font_size", 15)
	_info.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	rows.add_child(_info)

	rows.add_child(HSeparator.new())

	_add_button(rows, "继续游戏", resume)
	_add_button(rows, "重新开始", _restart_level)
	_add_button(rows, "返回选关", _back_to_menu)
	_add_button(rows, "退出游戏", func(): get_tree().quit())
	_buttons[0].grab_focus()


func _add_button(parent: Node, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320, 46)
	b.add_theme_font_size_override("font_size", 19)
	b.pressed.connect(cb)
	parent.add_child(b)
	_buttons.append(b)


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.98)
	sb.border_color = Color(0.30, 0.34, 0.42)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	return sb


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if get_tree().paused:
			resume()
		else:
			pause()
		get_viewport().set_input_as_handled()


func pause() -> void:
	visible = true
	get_tree().paused = true
	_release_input()
	var cfg := GameState.current_level()
	if cfg != null:
		_title.text = "已暂停　·　%s" % cfg.display_name
		_info.text = "%s · %s · 圈数 %d/%d" % [
			cfg.difficulty, cfg.weather_label(),
			_current_lap(), cfg.laps_to_finish,
		]
	if not _buttons.is_empty():
		_buttons[0].grab_focus()


func resume() -> void:
	visible = false
	get_tree().paused = false
	_release_input()


func _current_lap() -> int:
	var car := get_parent().get_node_or_null("RaceCar")
	if car == null:
		return 1
	return clampi(int(car.get("laps_done")) + 1, 1, 99)


func _restart_level() -> void:
	get_tree().paused = false
	_release_input()
	get_tree().reload_current_scene()


func _back_to_menu() -> void:
	get_tree().paused = false
	_release_input()
	get_tree().change_scene_to_file(MENU_SCENE)


func _release_input() -> void:
	for act in ["accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake"]:
		Input.action_release(act)
