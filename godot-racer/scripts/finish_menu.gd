extends CanvasLayer
## 比赛结算界面；数据由 GameState 的首次完成快照提供。

var result: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 20
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.72)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 12)
	panel.add_child(rows)
	var title := Label.new()
	title.text = "比赛完成"
	title.add_theme_font_size_override("font_size", 32)
	rows.add_child(title)
	var summary := Label.new()
	summary.text = "完成 %d/%d 圈\n末圈 %.2f 秒\n最快圈 %.2f 秒" % [
		int(result.get("laps", 0)), int(result.get("target", 0)),
		float(result.get("last", 0.0)), float(result.get("best", 0.0))]
	summary.add_theme_font_size_override("font_size", 20)
	rows.add_child(summary)
	_add_button(rows, "重新开始", GameState.restart_race)
	var back := _add_button(rows, "返回选关（ESC）", GameState.back_to_menu)
	_add_button(rows, "退出游戏", GameState.request_exit)
	back.grab_focus()


func _add_button(parent: VBoxContainer, label: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(320, 46)
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and GameState.phase_name() == "FINISHED":
		get_viewport().set_input_as_handled()
		GameState.back_to_menu()
