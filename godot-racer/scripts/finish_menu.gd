extends CanvasLayer
## 比赛结算：只展示main注入的GameState.finish_snapshot副本。
## 不读取车辆或墙钟，不重新计算名次/圈速；差距仅为用户批准的last-best。
## 全屏CanvasLayer保留冻结比赛与三个真实出口，不新增场景/流程状态。
## 老快照缺字段时按空态渲染；UI规格见plan/ui-spec-20261020.md。

const Ui := preload("res://scripts/ui_theme.gd")

var result: Dictionary = {}
var _root: Control
var _stage: Control
var _back: Button
var _retry: Button
var _quit: Button
var _last_focus: Control
var _was_exit := false
var _exit_focus: Dictionary = {}
var _accent := Ui.SKY


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not result.is_empty():
		Sfx.play_clip("失败" if result.get("outcome", "") == "lose" else "胜利", -18.0)
	layer = 20
	_root = Control.new()
	_root.name = "FinishRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	Ui.install(_root)
	var shade := ColorRect.new()
	shade.color = Ui.BACKGROUND
	shade.color.a = 0.96
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	_stage = Ui.stage(_root)
	_accent = Ui.accent(GameState.current_level())
	var accent := _accent
	Ui.panel(_stage, "ResultsPanel", Rect2(183, 64, 1000, 577), accent)
	var title := Ui.label(_stage, "ResultTitle", _title_text(), 40, accent)
	Ui.place(title, Rect2(211, 88, 944, 56))
	var rank := Ui.label(_stage, "ResultRank", _result_line_text(), 24)
	Ui.place(rank, Rect2(211, 150, 944, 38))
	var total := Ui.label(_stage, "TotalTime", "总时间  %s" % _fmt(float(result.get("total", 0.0))), 32)
	if result.get("new_record", false): total.text += "  · 新纪录"
	Ui.place(total, Rect2(211, 200, 944, 48))
	var target := int(result.get("target", 0))
	var progress := "完成 %d/%d 圈" % [int(result.get("laps", 0)), target] if target > 0 else "完成 %d 圈（目标未提供）" % int(result.get("laps", 0))
	var summary := Ui.label(_stage, "LapSummary", "%s · 末圈 %s · 最快圈 %s" % [progress,
		_fmt(float(result.get("last", 0.0))), _fmt(float(result.get("best", 0.0)))], 19, Ui.MUTED)
	Ui.place(summary, Rect2(211, 260, 944, 32))
	summary.visible = not result.is_empty() and result.has("laps")
	var difference := Ui.label(_stage, "LapDifference", _difference_text(), 18, accent)
	if not String(result.get("record_error", "")).is_empty():
		difference.text = "纪录未保存：%s" % result["record_error"]
	Ui.place(difference, Rect2(211, 300, 944, 28))
	difference.visible = not difference.text.is_empty()
	_build_entrant_table()
	_back = Ui.button(_stage, "BackButton", "返回主菜单（ESC）", Rect2(211, 553, 300, 48), accent)
	_retry = Ui.button(_stage, "RetryButton", "再玩一局", Rect2(533, 553, 300, 48), accent)
	_quit = Ui.button(_stage, "QuitButton", "退出游戏", Rect2(855, 553, 300, 48), accent)
	_back.pressed.connect(GameState.back_to_menu)
	_retry.pressed.connect(GameState.restart_race)
	_quit.pressed.connect(_request_exit)
	var buttons: Array[Control] = [_back, _retry, _quit]
	Ui.focus_ring(buttons, true)
	_back.grab_focus()
	_last_focus = _back
	_stage.modulate.a = 0
	# 仅淡入，不延迟按钮可用，不等待动画完成。
	create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS).tween_property(_stage, "modulate:a", 1.0, 0.22)


func _has_finished() -> bool:
	var target := int(result.get("target", 0))
	return target > 0 and int(result.get("laps", 0)) >= target


func _title_text() -> String:
	if result.is_empty():
		return "暂无结算数据"
	if not _has_finished():
		return "本局未完赛"
	if result.get("outcome", "") == "practice" or (result.has("field_size") and int(result["field_size"]) <= 1):
		return "练习完成"
	match String(result.get("outcome", "")):
		"win": return "你获得了冠军"
		"tie": return "并列夺冠"
	return "比赛完成"


func _result_line_text() -> String:
	if result.is_empty():
		return "本局成绩暂不可用"
	if not result.has("field_size") and result.get("outcome", "") != "practice":
		return "参赛信息暂不可用"
	var field_size := int(result.get("field_size", 0))
	var position := int(result.get("position", 0))
	if field_size <= 1 or result.get("outcome", "") == "practice":
		return "练习完成 · 本局无对手" if _has_finished() else "本局无对手 · 尚未完赛"
	if position <= 0 or position > field_size:
		return "名次数据暂不可用"
	return "最终名次   第 %d 名（共 %d 车）" % [position, field_size]


func _difference_text() -> String:
	var last := float(result.get("last", 0.0))
	var best := float(result.get("best", 0.0))
	if not is_finite(last) or not is_finite(best) or last <= 0 or best <= 0:
		return ""
	if last == best:
		return "末圈即本局最快圈"
	if last < best:
		return "圈速数据不一致"
	return "末圈比本局最快圈慢 %.3f 秒" % (last - best)


func _build_entrant_table() -> void:
	var entrants: Array = result.get("entrants", [])
	if int(result.get("field_size", 0)) <= 1 or result.get("outcome", "") == "practice":
		return
	if entrants.is_empty():
		var empty := Ui.label(_stage, "EntrantEmpty", "参赛车辆记录暂不可用", 18, Ui.MUTED)
		Ui.place(empty, Rect2(211, 342, 944, 40))
		return
	var scroll := ScrollContainer.new()
	scroll.name = "EntrantScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.focus_mode = Control.FOCUS_NONE
	Ui.place(scroll, Rect2(211, 342, 944, 180))
	_stage.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	scroll.add_child(rows)
	Ui.label(rows, "EntrantHeader", "参赛车辆 · 名次 / 车手 / 圈数 / 状态", 15, Ui.MUTED)
	# 保留快照顺序；rank是权威字段，不以行索引替代或另排一次名次。
	for i in range(entrants.size()):
		var entry: Dictionary = entrants[i]
		var rank := int(entry.get("rank", 0))
		var label := String(entry.get("label", ""))
		if label.is_empty():
			label = "未命名车手"
		var laps_text := str(int(entry["laps"])) if entry.has("laps") else "--"
		var status := "完赛" if bool(entry.get("finished", false)) else "未完赛"
		if not entry.has("finished"):
			status = "状态未提供"
		var text := "%s · %s · %s 圈 · %s" % [str(rank) if rank > 0 else "--", label, laps_text, status]
		var color := _accent if String(entry.get("id", "")) == "player" else Ui.TEXT
		var row := Ui.label(rows, "Entrant%d" % i, text, 19, color)
		row.custom_minimum_size.y = 32


func _process(_delta: float) -> void:
	if GameState.phase == GameState.Phase.EXIT_CONFIRM:
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


## ESC与“返回主菜单”走相同入口；退出框打开时不抢其ESC。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and GameState.phase_name() == "FINISHED":
		get_viewport().set_input_as_handled()
		GameState.back_to_menu()


## mm:ss.mmm，总时间 ≤ 0（没出发/异常）时给占位。与 hud.gd 的 _fmt 同口径 ——
## 两处各留一份纯格式化是有意的：跨文件耦合一个 6 行函数不划算，
## 口径的一致性由 tests/finish_results_test.gd 与 hud 断言双向钉住。
func _fmt(t: float) -> String:
	if not is_finite(t) or t <= 0.0:
		return "--:--.---"
	# ⚠ 必须先归一到毫秒再拆位：若秒、毫秒分别 int/round，秒的小数落在
	#   [0.9995, 1.0) 时会 round 出 1000 毫秒，%03d 于是打出四位小数
	#   （00:59.1000）。先 round(t*1000) 再整除，进位自然带到秒/分。
	var total_ms := int(round(t * 1000.0))
	var m := total_ms / 60000
	var s := (total_ms / 1000) % 60
	var ms := total_ms % 1000
	return "%02d:%02d.%03d" % [m, s, ms]
