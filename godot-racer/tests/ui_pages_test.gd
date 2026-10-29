extends SceneTree
## 秒级页面实例自测：不装配赛道，不改验收阈值，不代表正式T/U。
## --headless --path godot-racer --script res://tests/ui_pages_test.gd

var _gs: Node
var _menu: Control
var _cd: CanvasLayer
var _finish: CanvasLayer
var _hud: CanvasLayer
var _step := 0
var _frames := 0
var _pass := 0
var _fail := 0
var _go_count := 0
var _snapshot: Dictionary = {}
var _finishing := false

## 帮助页键名判据的独立取值：从 InputMap 反查，不复用被测实现的函数，
## 避免出现"实现自己生成文本、自己比对文本"的自证循环。
const KEY_ALIAS := {"Space": "空格", "Escape": "ESC", "Enter": "回车"}


func _initialize() -> void:
	call_deferred("_boot")


func _boot() -> void:
	_gs = root.get_node("GameState")
	_gs.set("settings_path", "user://ui-pages-selftest.cfg")
	root.size = Vector2i(1366, 705)
	_menu = load("res://scripts/menu.gd").new()
	root.add_child(_menu)


func _process(_delta: float) -> bool:
	if _finishing:
		return false
	_frames += 1
	if _frames > 180:
		_check("UI-01", false, "watchdog 180 frames")
		_done()
	if _gs == null:
		return false
	match _step:
		0:
			_test_menu()
			_step = 1
			root.size = Vector2i(1920, 1080)
		1:
			_check_layout(_menu, "MENU-09")
			_menu.queue_free()
			_step = 2
		2:
			_test_countdown()
			_build_finish()
			_step = 3
		3:
			_test_finish()
			_check_layout(_finish, "FIN-06")
			root.size = Vector2i(1366, 705)
			_step = 4
		4:
			_check_layout(_finish, "FIN-06")
			_test_hud()
			_step = 5
		5:
			_test_hud_values()
			_done()
	return false


func _check(id: String, ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("%s %s %s" % [id, "PASS" if ok else "FAIL", detail])


func _find(node: Node, node_name: String) -> Node:
	return node.find_child(node_name, true, false)


func _binding_name(action: String) -> String:
	if not InputMap.has_action(action):
		return ""
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return ""
	var ev := events[0]
	if ev is InputEventKey:
		var key := OS.get_keycode_string(ev.physical_keycode)
		if key.is_empty():
			key = ev.as_text().get_slice("+", 0)
		return KEY_ALIAS.get(key, key)
	if ev is InputEventMouseButton:
		match ev.button_index:
			MOUSE_BUTTON_RIGHT: return "鼠标右键"
			MOUSE_BUTTON_LEFT: return "鼠标左键"
			MOUSE_BUTTON_MIDDLE: return "鼠标中键"
	return ""


func _test_menu() -> void:
	var home_tests: RefCounted = load("res://tests/ui_home_assertions.gd").new()
	home_tests.setup(root, _gs, _check)
	home_tests.run()
	if _menu.has_method("_show_level_select"):
		_menu.call("_show_level_select")
	var ui_b: RefCounted = load("res://tests/ui_b_assertions.gd").new()
	ui_b.setup(root, _gs, _check)
	ui_b.run()
	_menu.get("_buttons")[0].grab_focus()
	# 既有赛事数据断言需要先明确选关；不依赖新版取消的自动选中。
	_menu.call("_on_level_focus", 0)
	var buttons: Array = _menu.get("_buttons")
	_check("MENU-01", buttons.size() == int(_gs.call("level_count")), "关卡卡片数量")
	for n in ["StartButton", "SettingsButton", "HelpButton", "ExitButton"]:
		var b := _find(_menu, n) as Button
		_check("MENU-01", b != null and b.pressed.get_connections().size() > 0, n)
	if _find(_menu, "StartButton") == null:
		return
	_check("MENU-05", buttons[0].has_focus(), "初始选关焦点")
	var slider := _find(_menu, "SpeedSlider") as HSlider
	var ai_quick := _find(_menu, "AiQuickButton") as Button
	_check("MENU-10", ai_quick != null and ai_quick.visible and ai_quick.text == "AI 对手：开启", "首页直接显示AI开关")
	if ai_quick != null:
		ai_quick.pressed.emit()
		_check("MENU-10", not bool(_gs.get("ai_enabled")) and ai_quick.text == "AI 对手：关闭"
			and "AI 0 台（已关闭；配置 1 台）" in String(_find(_menu, "LevelFacts").text), "首页关闭AI立即同步台数")
		ai_quick.pressed.emit()
		_check("MENU-10", bool(_gs.get("ai_enabled")) and ai_quick.button_pressed
			and ai_quick.text == "AI 对手：开启", "首页重新开启AI")
	var colors := ["7fb3e8", "7fb3e8", "6e86c8", "e0b368", "a8c4dc"]
	_gs.set("speed_user_set", false)
	for i in range(int(_gs.call("level_count"))):
		_menu.call("_on_level_focus", i)
		var cfg: Resource = _gs.call("current_level")
		_check("MENU-02", String(_find(_menu, "LevelName").text) == cfg.get("display_name"), "关卡名%d" % i)
		_check("MENU-03", slider.value == float(cfg.get("suggested_speed_kmh")), "默认极速%d" % i)
		_check("MENU-02", _find(_menu, "LevelName").get_theme_color("font_color").is_equal_approx(Color(colors[i])), "主题色%d" % i)
		# INT-01：新轨道有效行程为466，推荐线中心与滑块中心对齐。
		var expected_x := 40 + (float(cfg.get("suggested_speed_kmh")) - 80) / 160 * 466 - 1.5
		_check("MENU-03", is_equal_approx(_find(_menu, "RecommendedMarker").position.x, expected_x), "推荐标记%d" % i)
		var facts: String = _find(_menu, "LevelFacts").text
		_check("MENU-02", "抓地力 ×%.2f" % float(cfg.get("friction_multiplier")) in facts
			and "静态障碍 %d" % int(cfg.get("obstacle_count")) in facts
			and "动态障碍 %d" % int(cfg.get("dynamic_obstacle_count")) in facts, "真实关卡字段%d" % i)
	_menu.call("_on_level_focus", 0)
	_check("MENU-04", _find(_menu, "SpeedHint").text == "当前为本关推荐极速", "推荐相等")
	slider.value = 180
	_check("MENU-04", _find(_menu, "SpeedHint").text == "高于推荐 20 km/h（本关抓地力 ×1.00，注意打滑）", "高于推荐")
	slider.value = 140
	_check("MENU-04", _find(_menu, "SpeedHint").text == "低于推荐 20 km/h（本关抓地力 ×1.00）", "低于推荐")
	_menu.call("_on_level_focus", 4)
	_check("MENU-03", slider.value == 140 and bool(_gs.get("speed_user_set")), "自由极速跨关保留")
	for i in range(buttons.size()):
		var b: Button = buttons[i]
		_check("MENU-05", b.get_node(b.focus_neighbor_bottom) == buttons[(i + 1) % buttons.size()]
			and b.get_node(b.focus_neighbor_top) == buttons[(i - 1 + buttons.size()) % buttons.size()], "上下焦点%d" % i)
	var settings := _find(_menu, "SettingsButton") as Button
	var chain: Array[Control] = []
	chain.assign(buttons)
	chain.append_array([ai_quick, slider, _find(_menu, "StartButton"), settings,
		_find(_menu, "HelpButton"), _find(_menu, "ExitButton")])
	if _find(_menu, "BackHomeButton") != null:
		chain.append(_find(_menu, "BackHomeButton"))
	for i in range(chain.size()):
		_check("MENU-05", chain[i].get_node(chain[i].focus_next) == chain[(i + 1) % chain.size()]
			and chain[i].get_node(chain[i].focus_previous) == chain[posmod(i - 1, chain.size())], "Tab链%d" % i)
	settings.pressed.emit()
	var overlay := _find(_menu, "MenuOverlay")
	_check("MENU-06", overlay != null, "设置入口")
	if overlay != null:
		var ai := _find(overlay, "AiButton") as Button
		_check("MENU-06", ai.has_focus() and settings.focus_mode == Control.FOCUS_NONE, "弹层焦点隔离")
		var before: bool = _gs.get("ai_enabled")
		ai.pressed.emit()
		_check("MENU-06", bool(_gs.get("ai_enabled")) != before, "AI真实切换")
		var fps := _find(overlay, "FpsButton") as Button
		var old_fps: int = _gs.get("render_fps")
		fps.pressed.emit()
		_check("MENU-06", int(_gs.get("render_fps")) != old_fps, "FPS真实切换")
		_check("MENU-06", ai.get_node(ai.focus_next) == fps
			and fps.get_node(fps.focus_next) == _find(overlay, "CloseOverlay")
			and _find(overlay, "MusicButton") == null,
			"设置焦点顺序无重复BGM入口")
		var esc := InputEventAction.new()
		esc.action = "ui_cancel"
		esc.pressed = true
		_menu.call("_unhandled_input", esc)
		_check("MENU-06", settings.has_focus(), "ESC恢复设置焦点")
		_check("MENU-10", ai_quick.text == "AI 对手：关闭" and not ai_quick.button_pressed, "设置与首页开关共享状态")
	_find(_menu, "HelpButton").pressed.emit()
	overlay = _menu.get("_overlay")
	_check("MENU-06", overlay != null and "V 切换视角" in String(_find(overlay, "HelpText").text), "真实操作帮助")
	var help_text := String(_find(overlay, "HelpText").text)
	for act in ["accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake",
			"reset", "camera_view", "camera_orbit"]:
		var bound := _binding_name(act)
		_check("MENU-11", bound != "" and help_text.contains(bound),
			"帮助页键位取自InputMap: %s=%s" % [act, bound])
	_check("MENU-11", help_text.contains("复位"), "帮助页含复位脱困键")
	_check("MENU-11", help_text.contains("ESC"), "帮助页含ESC说明")
	_menu.call("_close_overlay")
	var quit_button := _find(_menu, "ExitButton") as Button
	quit_button.grab_focus()
	quit_button.pressed.emit()
	_check("MENU-06", _gs.call("phase_name") == "EXIT_CONFIRM" and quit_button.focus_mode == Control.FOCUS_NONE, "退出真实弹框并隔离焦点")
	_gs.call("cancel_exit")
	_menu.call("_process", 0.0)
	_check("MENU-06", quit_button.has_focus(), "退出取消恢复退出按钮")
	_check_layout(_menu, "MENU-09")
	# 空态使用同一真实关卡缓存，测试后原样恢复，不写磁盘资源。
	var levels: Array = _gs.get("_levels")
	var saved: Array = levels.duplicate()
	levels.clear()
	var empty: Control = load("res://scripts/menu.gd").new()
	root.add_child(empty)
	_check("MENU-07", bool(_find(empty, "StartButton").disabled)
		and not bool(_find(empty, "SpeedSlider").editable), "无关卡禁用开赛与调速")
	empty.free()
	levels.assign(saved)


func _test_countdown() -> void:
	_gs.set("chosen_level", 4)
	_cd = load("res://scripts/start_countdown.gd").new()
	root.add_child(_cd)
	_cd.set_process(false)
	_gs.call("prepare_race")
	_gs.call("enter_countdown")
	_cd.finished.connect(_on_go)
	_cd.call("_process", 0.0)
	_check("CD-02", _cd.get("_label").text == "3", "0秒数字3")
	_cd.call("_process", 1.0)
	_check("CD-02", _cd.get("_label").text == "2", "1秒数字2")
	_gs.call("request_exit")
	var elapsed: float = _cd.get("_elapsed")
	_cd.call("_process", 1.0)
	_check("CD-03", float(_cd.get("_elapsed")) == elapsed, "退出确认冻结累计")
	_gs.call("cancel_exit")
	_cd.call("_process", 1.0)
	_check("CD-02", _cd.get("_label").text == "1", "2秒数字1")
	_cd.call("_process", 1.0)
	_check("CD-04", _go_count == 1 and _gs.call("phase_name") == "RACING"
		and _cd.get("_label").text == "出发！", "3秒立即发车，独立于收旗")
	_cd.call("_process", 0.49)
	_check("CD-04", bool(_cd.get("_label").visible), "GO后0.49秒可见")
	_cd.call("_process", 0.01)
	_check("CD-04", not bool(_cd.get("_label").visible) and _go_count == 1, "0.5秒收旗且只发一次")
	_check("CD-05", _find(_cd, "SignalLights") != null and _find(_cd, "CountdownStage") != null, "数字面板与信号灯")
	_check("CD-05", _find(_cd, "CountdownTitle").get_theme_color("font_color").is_equal_approx(Color("f3f6fa"))
		and _find(_cd, "CountdownTitle").get_theme_constant("outline_size") >= 4,
		"五关统一亮字黑描边；主题色保留信号灯")
	_check_ignore(_cd)
	_cd.queue_free()
	_gs.set("ai_enabled", false)
	var practice: CanvasLayer = load("res://scripts/start_countdown.gd").new()
	root.add_child(practice)
	practice.set_process(false)
	_gs.call("prepare_race")
	_gs.call("enter_countdown")
	practice.call("_process", 0.0)
	practice.call("_process", 3.0)
	_check("CD-05", _find(practice, "CountdownHint").text == "计时已开始，开始你的练习", "无AI不显示假对手")
	practice.free()


func _on_go() -> void:
	_go_count += 1
	_gs.call("start_race")


func _check_ignore(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			_check("CD-04", child.mouse_filter == Control.MOUSE_FILTER_IGNORE
				and child.focus_mode == Control.FOCUS_NONE, String(child.name))
		_check_ignore(child)


func _build_finish() -> void:
	_snapshot = {"laps": 2, "target": 2, "total": 82.5, "last": 42.0, "best": 40.0,
		"position": 1, "field_size": 2, "outcome": "win", "entrants": [
			{"rank": 1, "label": "玩家", "laps": 2, "finished": true, "id": "player"},
			{"rank": 2, "label": "AI#1", "laps": 1, "finished": false, "id": "ai1"}]}
	_finish = load("res://scripts/finish_menu.gd").new()
	_gs.set("finish_snapshot", _snapshot.duplicate(true))
	_gs.set("phase", 5)
	_finish.set("result", _gs.get("finish_snapshot").duplicate(true))
	root.add_child(_finish)


func _test_finish() -> void:
	if _find(_finish, "TotalTime") == null:
		_check("FIN-01", false, "成绩控件不存在")
		return
	_check("FIN-01", _find(_finish, "TotalTime").text == "总时间  01:22.500", "总时间来自快照")
	_check("FIN-01", _find(_finish, "LapSummary").text == "完成 2/2 圈 · 末圈 00:42.000 · 最快圈 00:40.000", "圈数与圈速")
	_check("FIN-03", _find(_finish, "LapDifference").text == "末圈比本局最快圈慢 2.000 秒", "末圈差距")
	_check("FIN-04", _find(_finish, "Entrant1").text == "2 · AI#1 · 1 圈 · 未完赛", "参赛表保持字段")
	_check("FIN-04", _find(_finish, "Entrant0").get_theme_color("font_color").is_equal_approx(Color("a8c4dc"))
		and not _find(_finish, "Entrant1").get_theme_color("font_color").is_equal_approx(Color("a8c4dc")), "玩家行随L5主题高亮")
	_check("FIN-05", _find(_finish, "BackButton").has_focus(), "默认返回焦点")
	var exits: Array[Control] = []
	for n in ["BackButton", "RetryButton", "QuitButton"]:
		var b := _find(_finish, n) as Button
		exits.append(b)
		_check("FIN-05", b.pressed.get_connections().size() == 1, "真实出口 " + n)
	for i in range(exits.size()):
		_check("FIN-05", exits[i].get_node(exits[i].focus_next) == exits[(i + 1) % 3], "出口焦点循环%d" % i)
	_check("FIN-01", _gs.get("finish_snapshot") == _snapshot, "未改写快照")
	for i in range(2):
		var handler: Callable = exits[i].pressed.get_connections()[0]["callable"]
		_check("FIN-05", handler.get_object() == _gs
			and handler.get_method() == ["back_to_menu", "restart_race"][i], "出口真实回调%d" % i)
	exits[2].grab_focus()
	exits[2].pressed.emit()
	_check("FIN-05", _gs.call("phase_name") == "EXIT_CONFIRM" and exits[0].focus_mode == Control.FOCUS_NONE, "退出弹框隔离下层焦点")
	_gs.call("cancel_exit")
	_finish.call("_process", 0.0)
	_check("FIN-05", exits[2].has_focus() and _gs.call("phase_name") == "FINISHED", "取消回结算且恢复退出焦点")
	var variants := [
		["win", "你获得了冠军"], ["lose", "比赛完成"],
		["tie", "并列夺冠"], ["practice", "练习完成"]]
	for variant in variants:
		var data := _snapshot.duplicate(true)
		data["outcome"] = variant[0]
		var page := _variant(data)
		_check("FIN-02", _find(page, "ResultTitle").text == variant[1], String(variant[0]))
		page.free()
	for value in [40.0, 0.0, -1.0, INF, NAN]:
		var data := _snapshot.duplicate(true)
		data["last"] = value
		var page := _variant(data)
		var diff := _find(page, "LapDifference") as Label
		_check("FIN-03", diff.text == "末圈即本局最快圈" if value == 40.0 else not diff.visible,
			"差距边界 %s" % str(value))
		page.free()
	for value in [0.0, -1.0, INF, NAN]:
		var data := _snapshot.duplicate(true)
		data["best"] = value
		var page := _variant(data)
		_check("FIN-03", not _find(page, "LapDifference").visible, "最快圈无效 %s" % str(value))
		page.free()
	_check("FIN-01", _finish.call("_fmt", 59.9996) == "01:00.000"
		and _finish.call("_fmt", INF) == "--:--.---", "毫秒进位与非法时间空态")
	var empty := _variant({})
	_check("FIN-02", _find(empty, "ResultTitle").text == "暂无结算数据", "空快照")
	_check("FIN-01", not _find(empty, "LapSummary").visible
		and _find(empty, "TotalTime").text == "总时间  --:--.---", "空快照不伪造零圈与计时")
	empty.free()
	var unknown := _snapshot.duplicate(true)
	unknown.erase("field_size")
	unknown["outcome"] = ""
	var unknown_page := _variant(unknown)
	_check("FIN-02", _find(unknown_page, "ResultRank").text == "参赛信息暂不可用", "缺字段不称无对手")
	unknown_page.free()
	var inconsistent := _snapshot.duplicate(true)
	inconsistent["last"] = 39.0
	var invalid_page := _variant(inconsistent)
	_check("FIN-03", _find(invalid_page, "LapDifference").text == "圈速数据不一致", "不修饰不一致快照")
	invalid_page.free()
	var practice_data := _snapshot.duplicate(true)
	practice_data["outcome"] = "practice"
	practice_data["field_size"] = 1
	var practice_page := _variant(practice_data)
	_check("FIN-03", _find(practice_page, "LapDifference").text == "末圈比本局最快圈慢 2.000 秒"
		and _find(practice_page, "EntrantScroll") == null, "练习显示差距、不显示对手表")
	practice_page.free()
	var unfinished := _snapshot.duplicate(true)
	unfinished["laps"] = 1
	var partial := _variant(unfinished)
	_check("FIN-02", _find(partial, "ResultTitle").text == "本局未完赛", "未完赛")
	partial.free()
	# 长表与缺标签使用同一构建路径；按钮不进入滚动容器。
	var long_data := _snapshot.duplicate(true)
	for i in range(20):
		long_data["entrants"].append({"rank": i + 3, "laps": 0, "finished": false})
	var long_page := _variant(long_data)
	_check("FIN-06", _find(long_page, "EntrantScroll") is ScrollContainer
		and not _find(long_page, "EntrantScroll").is_ancestor_of(_find(long_page, "BackButton")), "长表滚动与按钮隔离")
	long_page.free()


func _variant(data: Dictionary) -> CanvasLayer:
	var page: CanvasLayer = load("res://scripts/finish_menu.gd").new()
	page.set("result", data)
	root.add_child(page)
	return page


func _check_layout(page: Node, id: String) -> void:
	var stage := _find(page, "Stage") as Control
	if stage == null:
		_check(id, false, "Stage不存在")
		return
	var rect := stage.get_global_rect()
	var factor := minf(float(root.size.x) / 1366.0, float(root.size.y) / 705.0)
	_check(id, rect.position.x >= -0.1 and rect.position.y >= -0.1
		and rect.end.x <= root.size.x + 0.1 and rect.end.y <= root.size.y + 0.1,
		"%s stage=%s" % [str(root.size), str(rect)])
	_check(id, rect.size.is_equal_approx(Vector2(1366, 705) * factor), "设计画布必须铺到预期尺寸")
	for child in stage.get_children():
		if child is Control and not child.is_queued_for_deletion() and child.visible:
			var bounds: Rect2 = child.get_global_rect()
			_check(id, bounds.position.x >= -0.1 and bounds.position.y >= -0.1
				and bounds.end.x <= root.size.x + 0.1 and bounds.end.y <= root.size.y + 0.1,
				"控件边界 " + String(child.name))
	for name in ["AiQuickButton", "StartButton", "SettingsButton", "BackButton", "RetryButton", "QuitButton"]:
		var button := _find(page, name) as Button
		if button != null:
			_check(id, button.size.y == 48, "按钮高48 " + name)


func _test_hud() -> void:
	_hud = load("res://scripts/hud.gd").new()
	for n in ["SpeedLabel", "TimeLabel", "LastLabel", "BestLabel"]:
		var label := Label.new()
		label.name = n
		_hud.add_child(label)
	root.add_child(_hud)
	_hud.set_process(false)
	_hud.set_physics_process(false)


func _test_hud_values() -> void:
	for n in ["SpeedLabel", "TimeLabel", "LastLabel", "BestLabel", "LapLabel", "TotalTimeLabel"]:
		var label := _find(_hud, n) as Label
		_check("HUD-01", label != null and label.get_theme_constant("outline_size") == 6
			and label.get_theme_color("font_color").is_equal_approx(Color("f3f6fa"))
			and label.get_theme_color("font_outline_color").is_equal_approx(Color.BLACK), n)
	# 2026-10-20 用户实机反馈：410x346 的半透明黑底盖住赛道左侧，太挡视野，要求去掉。
	# 判据随之**反向收紧**（不是放宽）：底衬必须不存在；对比度改由描边(6) + 投影保证。
	# 加这条是为了防回归 —— 以后谁再把底衬加回来，这里会红。
	_check("HUD-01", _find(_hud, "TimingBackdrop") == null, "无遮挡底衬")
	for n in ["SpeedLabel", "TimeLabel", "LastLabel", "BestLabel", "LapLabel", "TotalTimeLabel"]:
		var label := _find(_hud, n) as Label
		_check("HUD-01", label != null and label.get_theme_constant("shadow_offset_x") == 2
			and label.get_theme_color("font_shadow_color").a > 0.4, "投影 " + n)


func _done() -> void:
	if _finishing:
		return
	_finishing = true
	var music := _gs.find_child("MenuMusic", false, false)
	if music != null:
		_check("UI-01", await music.call("shutdown_and_wait"), "页面测试退出前菜单音频实际回收")
	print("UI_RUNTIME_DONE PASS=%d FAIL=%d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
