extends RefCounted
## UI-B独立断言组件；root/state/report由原页面测试注入。无协程。

var _root: Window
var _state: Node
var _report: Callable


func setup(root: Window, state: Node, report: Callable) -> void:
	_root = root
	_state = state
	_report = report


func run() -> void:
	var ai_enabled: bool = _state.get("ai_enabled")
	_test_menu()
	_test_countdown()
	_state.call("enter_menu")
	_state.set("ai_enabled", ai_enabled)


func _check(id: String, ok: bool, detail: String) -> void:
	_report.call(id, ok, detail)


func _new_menu() -> Control:
	_state.set("chosen_level", 3)
	var menu: Control = load("res://scripts/menu.gd").new()
	if menu.get("suppress_scene_change") != null:
		menu.set("suppress_scene_change", true)
	_root.add_child(menu)
	if menu.has_method("_show_level_select"):
		menu.call("_show_level_select")
	return menu


func _plain_cards(menu: Control) -> bool:
	for card in menu.get("_buttons"):
		var style: StyleBoxFlat = card.get_theme_stylebox("normal")
		if style.border_width_left != 1 or not style.border_color.is_equal_approx(Color("364152")):
			return false
	return true


func _test_menu() -> void:
	var menu := _new_menu()
	_check("MENU-12", menu.get("_selected_idx") == -1 and _plain_cards(menu), "无视历史关卡，默认无选中样式")
	_check("MENU-12", menu.get("_buttons")[0].has_focus(), "初始键盘焦点仍在第一卡片")
	_check("MENU-12", menu.find_child("StartButton", true, false).disabled
		and menu.find_child("LevelName", true, false).text == "选择赛道"
		and menu.find_child("LevelFacts", true, false).text == "点击左侧赛道查看赛事条件", "默认信息板为空态且开始禁用")
	_check("MENU-12", not menu.find_child("RecommendedMarker", true, false).visible
		and menu.find_child("SpeedHint", true, false).text == "选择赛道后显示本关推荐极速", "极速空态不显示历史推荐")
	menu.call("_on_card_hover", 2)
	_check("MENU-18", menu.get("_selected_idx") == -1 and _plain_cards(menu), "悬停不选中")
	menu.find_child("AiQuickButton", true, false).pressed.emit()
	_check("MENU-19", menu.get("_selected_idx") == -1 and _plain_cards(menu), "AI开关不制造选中")
	menu.get("_buttons")[1].grab_focus()
	_check("MENU-12", menu.get("_selected_idx") == -1 and _plain_cards(menu), "移动键盘焦点不等于选择赛道")
	if menu.get("_selected_idx") == null:
		for id in ["MENU-13", "MENU-14", "MENU-15", "MENU-16", "MENU-17"]:
			_check(id, false, "双击状态接口尚未实现，避免旧单击入口切换场景")
		menu.free()
		return
	menu.call("_on_level_pressed", 0)
	_check("MENU-13", menu.get("_selected_idx") == 0 and menu.get("_pending_idx") == 0
		and menu.get("enter_requests") == 0 and not menu.get("_locked")
		and not menu.find_child("StartButton", true, false).disabled
		and not _plain_cards(menu), "第一次确认只选择，不进入")
	menu.call("_on_level_pressed", 0)
	var disabled := true
	for card in menu.get("_buttons"):
		disabled = disabled and card.disabled
	_check("MENU-14", menu.get("enter_requests") == 1 and menu.get("_locked") and disabled,
		"窗口内第二次确认先锁并禁用卡片，只请求一次进入")
	for i in range(5):
		menu.call("_on_level_pressed", 0)
		menu.call("_on_start_pressed")
	_check("MENU-16", menu.get("enter_requests") == 1 and menu.get("_locked"), "确认后连点/连按不重复进入")
	menu.free()
	menu = _new_menu()
	menu.call("_on_level_pressed", 0)
	var old_ms := Time.get_ticks_msec() - 301
	menu.set("_pending_ms", old_ms)
	menu.call("_on_level_pressed", 0)
	_check("MENU-15", menu.get("enter_requests") == 0 and menu.get("_pending_idx") == 0
		and int(menu.get("_pending_ms")) > old_ms, "超过300ms刷新首次点击时间戳，不清空选择")
	menu.call("_on_level_pressed", 1)
	_check("MENU-17", menu.get("enter_requests") == 0 and menu.get("_selected_idx") == 1
		and menu.get("_pending_idx") == 1, "换关不误触发确认")
	menu.find_child("StartButton", true, false).pressed.emit()
	_check("MENU-14", menu.get("enter_requests") == 1 and menu.get("_locked"), "明确开始按钮确认已选关卡")
	menu.free()


func _test_countdown() -> void:
	_state.call("prepare_race")
	_state.call("enter_countdown")
	var page: CanvasLayer = load("res://scripts/start_countdown.gd").new()
	_root.add_child(page)
	page.set_process(false)
	page.call("_process", 0.0)
	_check_controls(page)
	var panel := page.find_child("CountdownPanel", true, false) as Panel
	var clear := panel == null
	if panel != null:
		var box := panel.get_theme_stylebox("panel") as StyleBoxFlat
		clear = box != null and box.bg_color.a == 0 and box.border_width_left == 0
		clear = clear and box.border_width_right == 0 and box.border_width_top == 0 and box.border_width_bottom == 0
	_check("CD-07", clear, "中央面板不存在或底色/四边均完全透明")
	_check("CD-08", page.find_children("*", "ColorRect", true, false).is_empty(), "倒计时无全屏shade或其他ColorRect底衬")
	var label: Label = page.get("_label")
	_check("CD-09", label.get_theme_font_size("font_size") == 96
		and label.get_theme_constant("outline_size") >= 6
		and label.get_theme_color("font_outline_color").is_equal_approx(Color.BLACK), "96px数字与至少6px黑描边保留")
	var calls: Array[int] = [0]
	page.finished.connect(_on_go.bind(calls))
	page.call("_process", 2.999)
	_check("CD-10", calls[0] == 0 and _state.call("phase_name") == "COUNTDOWN", "2.999秒尚未发车")
	page.call("_process", 0.001)
	_check("CD-10", calls[0] == 1 and _state.call("phase_name") == "RACING", "3.000秒立即发车，未等待动画")
	page.call("_process", 0.49)
	_check("CD-10", label.visible and calls[0] == 1, "0.49秒视觉收旗等待不重复发车")
	page.call("_process", 0.01)
	_check("CD-10", not label.visible and calls[0] == 1, "0.5秒隐藏，发车次数不变")
	page.free()


func _on_go(calls: Array[int]) -> void:
	calls[0] += 1
	_state.call("start_race")


func _check_controls(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			_check("CD-06", child.mouse_filter == Control.MOUSE_FILTER_IGNORE
				and child.focus_mode == Control.FOCUS_NONE, String(child.get_path()))
			for property in child.get_property_list():
				if String(property.name).begins_with("theme_override_styles/"):
					var style = child.get(property.name)
					if style is StyleBoxFlat:
						_check("CD-06", style.bg_color.a == 0, "无底色StyleBox " + String(child.get_path()))
		_check_controls(child)
