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
const Ui := preload("res://scripts/ui_theme.gd")

var _panel: Panel
var _root: Control
var _stage: Control
var _title: Label
var _info: Label
var _buttons: Array[Button] = []
var _last_focus: Control
var _exit_focus: Dictionary = {}
var _was_exit := false


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
	_root = Control.new()
	_root.name = "PauseRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	Ui.install(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.025, 0.045, 0.08, 0.86)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	_stage = Ui.stage(_root)
	Ui.brand(_stage, Rect2(42, 34, 390, 62))
	_panel = Ui.panel(_stage, "PausePanel", Rect2(402, 104, 562, 516), Ui.BORDER)
	var marker := Ui.label(_stage, "PauseMarker", "Ⅱ", 40, Ui.RED)
	Ui.place(marker, Rect2(430, 126, 46, 58))
	_title = Ui.label(_stage, "PauseTitle", "已暂停", 29)
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(_title, Rect2(488, 116, 442, 74))
	_info = Ui.label(_stage, "PauseInfo", "", 17, Ui.MUTED)
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(_info, Rect2(434, 194, 498, 60))
	var divider := ColorRect.new()
	divider.color = Ui.RED
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.place(divider, Rect2(434, 266, 498, 2))
	_stage.add_child(divider)
	_add_button(_stage, "继续游戏", resume)
	_add_button(_stage, "重新开始", _restart_level)
	_add_button(_stage, "返回选关", _back_to_menu)
	_add_button(_stage, "退出游戏", _request_exit)
	Ui.style_button(_buttons[0], Ui.RED, true)
	var controls: Array[Control] = []
	controls.assign(_buttons)
	Ui.focus_ring(controls)
	var hint := Ui.label(_stage, "PauseHint", "ESC 继续游戏 · 方向键选择 · 回车确认", 15, Ui.MUTED)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(hint, Rect2(434, 576, 498, 50))
	if GameState.split_screen:
		var help := Ui.button(_stage, "SplitControls", "查看双人操作", Rect2(1010, 194, 250, 52), Ui.SKY)
		help.pressed.connect(func(): get_parent().get_node("SplitScreen").show_controls())
		controls.append(help)
		Ui.focus_ring(controls)
	_buttons[0].grab_focus()


func _add_button(parent: Node, text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.name = ["ResumeButton", "RestartButton", "LevelSelectButton", "QuitButton"][_buttons.size()]
	Ui.place(b, Rect2(434, 286 + _buttons.size() * 68, 498, 54))
	Ui.style_button(b, Ui.RED)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(cb)
	parent.add_child(b)
	_buttons.append(b)


func _process(_delta: float) -> void:
	if not visible:
		return
	if GameState.phase_name() == "EXIT_CONFIRM":
		_suspend_for_exit()
		return
	if _was_exit:
		_was_exit = false
		Ui.restore_focus(_exit_focus)
		_exit_focus.clear()
		if is_instance_valid(_last_focus):
			_last_focus.grab_focus()
	var focused := _root.get_viewport().gui_get_focus_owner()
	if focused != null and _root.is_ancestor_of(focused):
		_last_focus = focused


func _suspend_for_exit() -> void:
	if _was_exit:
		return
	var focused := _root.get_viewport().gui_get_focus_owner()
	if focused != null and _root.is_ancestor_of(focused):
		_last_focus = focused
	_exit_focus = Ui.suspend_focus(_stage)
	_was_exit = true


func _request_exit() -> void:
	_suspend_for_exit()
	GameState.request_exit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if GameState.phase_name() == "PAUSED":
			resume()
		elif GameState.phase_name() == "RACING":
			pause()
		elif GameState.phase_name() == "COUNTDOWN":
			# Phase 01：倒计时中 ESC 不进暂停菜单（比赛还没开始，没有"继续"可点），
			# 直接走退出确认（策划案 §5.1 状态机 COUNTDOWN → EXIT_CONFIRM）。
			# 倒计时本身靠相位门闩冻结：EXIT_CONFIRM 期间 start_countdown 不累计，
			# cancel_exit() 回 COUNTDOWN 且保持树暂停（R3/E7）。
			GameState.request_exit()
		else:
			return
		get_viewport().set_input_as_handled()


func pause() -> void:
	if not GameState.pause_race():
		return
	visible = true
	var cfg := GameState.current_level()
	if cfg != null:
		_title.text = tr("已暂停　·　%s") % tr(cfg.display_name)
		_info.text = tr("%s · %s · 圈数 %d/%d") % [
			tr(cfg.difficulty), tr(cfg.weather_label()),
			_current_lap(), cfg.laps_to_finish,
		]
		if GameState.split_screen:
			_info.text = "本地双人 · 左右分屏 · 双方比赛已暂停"
		elif GameState.endless_mode:
			_info.text = tr("%s · %s · 无限畅玩 · 当前第%d圈") % [tr(cfg.difficulty), tr(cfg.weather_label()), _current_lap()]
	if not _buttons.is_empty():
		_buttons[0].grab_focus()


func resume() -> void:
	if not GameState.resume_race():
		return
	visible = false


func _current_lap() -> int:
	var car := get_parent().get_node_or_null("RaceCar")
	if car == null:
		return 1
	return clampi(int(car.get("laps_done")) + 1, 1, 99)


func _restart_level() -> void:
	GameState.restart_race()


func _back_to_menu() -> void:
	GameState.back_to_menu(true)


func _release_input() -> void:
	GameState.release_drive_input()
