extends CanvasLayer
## 全局退出确认：GameState 持有，跨菜单、暂停、结算共用。


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.72)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 14)
	panel.add_child(rows)
	var title := Label.new()
	title.text = "确定退出游戏？"
	title.add_theme_font_size_override("font_size", 28)
	rows.add_child(title)
	var cancel := Button.new()
	cancel.text = "取消，返回游戏"
	cancel.custom_minimum_size = Vector2(280, 44)
	cancel.pressed.connect(GameState.cancel_exit)
	rows.add_child(cancel)
	var confirm := Button.new()
	confirm.text = "确认退出"
	confirm.custom_minimum_size = Vector2(280, 44)
	confirm.pressed.connect(GameState.confirm_exit)
	rows.add_child(confirm)
	cancel.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		GameState.cancel_exit()
		get_viewport().set_input_as_handled()
