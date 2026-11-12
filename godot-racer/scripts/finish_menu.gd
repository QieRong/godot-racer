extends CanvasLayer
## 比赛结算：只展示main注入的GameState.finish_snapshot副本。
## 不读取车辆或墙钟，不重新计算名次/圈速；差距仅为用户批准的last-best。
## 全屏CanvasLayer保留冻结比赛与三个真实出口，不新增场景/流程状态。
## 老快照缺字段时按空态渲染；UI规格见plan/ui-spec-20261020.md。

const Ui := preload("res://scripts/ui_theme.gd")
const CarShowcase := preload("res://scripts/car_showcase.gd")

var result: Dictionary = {}
var return_to_online_room: Callable
var leave_online_room: Callable
var _root: Control
var _stage: Control
var _back: Button
var _retry: Button
var _quit: Button
var _last_focus: Control
var _was_exit := false
var _exit_focus: Dictionary = {}
var _accent := Ui.RED
var _showcase


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not result.is_empty() and not result.get("training", false):
		Sfx.play_clip("失败" if not result.get("split_screen", false) and result.get("outcome", "") == "lose" else "胜利", -18.0)
	layer = 20
	if result.get("split_screen", false) or result.get("online", false):
		_build_split_result()
		return
	_root = Control.new()
	_root.name = "FinishRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	Ui.install(_root)
	var shade := ColorRect.new()
	shade.color = Ui.BACKGROUND
	shade.color.a = 0.98
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	_stage = Ui.stage(_root)
	var accent := _accent
	Ui.brand(_stage, Rect2(42, 40, 480, 74))
	var stripes := Polygon2D.new()
	stripes.polygon = PackedVector2Array([Vector2(0, 596), Vector2(578, 434), Vector2(578, 450), Vector2(0, 612)])
	stripes.color = Color("732f40")
	_stage.add_child(stripes)
	_showcase = CarShowcase.new()
	_showcase.simplified_effects = true
	Ui.place(_showcase, Rect2(8, 202, 580, 378))
	_stage.add_child(_showcase)
	_showcase.set_angle(-0.28)
	_showcase.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_showcase.tooltip_text = ""
	_showcase.set_process_input(false)
	_showcase.set_physics_process(false)
	var left_title := Ui.label(_stage, "FinishCaption", "这一程，已留下成绩。", 27)
	left_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(left_title, Rect2(48, 148, 520, 44))
	var left_hint := Ui.label(_stage, "FinishHint", "重返赛道，挑战下一次突破", 18, Ui.MUTED)
	Ui.place(left_hint, Rect2(48, 658, 520, 32))
	var completion := Ui.label(_stage, "CompletionFeedback", _completion_text(), 20, Ui.SKY)
	completion.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(completion, Rect2(48, 594, 520, 56))
	completion.visible = not completion.text.is_empty()
	Ui.panel(_stage, "ResultsPanel", Rect2(590, 38, 738, 546), Ui.BORDER)
	var eyebrow := Ui.label(_stage, "ResultSection", "比赛结算", 17, accent)
	Ui.place(eyebrow, Rect2(618, 54, 686, 30))
	var title := Ui.label(_stage, "ResultTitle", _title_text(), 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(title, Rect2(618, 88, 686, 50))
	var rank_panel := Ui.panel(_stage, "RankPanel", Rect2(614, 154, 690, 100), accent)
	rank_panel.add_theme_stylebox_override("panel", Ui.box(Color("36202e"), accent, 1, 0))
	var position := int(result.get("position", 0))
	var field_size := int(result.get("field_size", 0))
	var rank_value := str(position) if field_size > 1 and position > 0 and position <= field_size else "—"
	var rank_number := Ui.label(_stage, "RankNumber", rank_value, 62, accent)
	rank_number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(rank_number, Rect2(638, 160, 114, 84))
	var rank := Ui.label(_stage, "ResultRank", _result_line_text(), 22)
	rank.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(rank, Rect2(766, 174, 516, 60))
	_build_record_cards()
	if result.get("new_record", false):
		var record := Ui.label(_stage, "NewRecord", "新纪录", 17, accent)
		record.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		Ui.place(record, Rect2(1148, 60, 156, 26))
	var error := String(result.get("record_error", ""))
	if not error.is_empty():
		var warning := Ui.label(_stage, "RecordError", tr("纪录未保存：%s") % tr(error), 16, Ui.WARNING)
		Ui.place(warning, Rect2(618, 540, 686, 32))
	_build_entrant_table()
	_back = Ui.button(_stage, "BackButton", "返回选关（Esc）", Rect2(590, 606, 238, 58), accent)
	_retry = Ui.button(_stage, "RetryButton", "再玩一局", Rect2(842, 606, 238, 58), accent)
	_quit = Ui.button(_stage, "QuitButton", "退出游戏", Rect2(1094, 606, 234, 58), accent)
	Ui.style_button(_retry, accent, true)
	_back.pressed.connect(GameState.back_to_menu.bind(true))
	_retry.pressed.connect(GameState.restart_race)
	_quit.pressed.connect(_request_exit)
	var buttons: Array[Control] = [_back, _retry, _quit]
	Ui.focus_ring(buttons, true)
	_back.grab_focus()
	_last_focus = _back
	_stage.modulate.a = 0
	# 仅淡入，不延迟按钮可用，不等待动画完成。
	create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS).tween_property(_stage, "modulate:a", 1.0, 0.22)


func _build_record_cards() -> void:
	if result.get("training", false):
		_stat_card("DurationCard", "本次训练时长", _fmt(float(result.get("total", 0.0))), Rect2(614, 270, 222, 82))
		_stat_card("BestLapCard", "本次最佳单圈", _fmt(float(result.get("best", 0.0))), Rect2(848, 270, 222, 82))
		_stat_card("LapCountCard", "完成圈数", str(result.get("laps", 0)), Rect2(1082, 270, 222, 82))
		_stat_card("EndlessRecord", "历史最佳单圈", _fmt(float(result.get("endless_best", 0.0))), Rect2(614, 362, 690, 76))
		return
	var laps: Array = result.get("lap_times", [])
	var bests: Array = result.get("lap_bests", [0.0, 0.0])
	for i in range(2):
		_stat_card("Lap%dCard" % (i + 1), "第一圈耗时" if i == 0 else "第二圈耗时",
			_fmt(float(laps[i])) if i < laps.size() else _fmt(0.0), Rect2(614 + i * 234, 262, 222, 82))
		_stat_card("Lap%dRecord" % (i + 1), "第一圈最佳纪录" if i == 0 else "第二圈最佳纪录",
			_fmt(float(bests[i])), Rect2(614 + i * 234, 354, 222, 78))
	_stat_card("TotalCard", "总耗时", _fmt(float(result.get("total", 0.0))), Rect2(1082, 262, 222, 82), "TotalTime")
	_stat_card("TotalRecord", "总最佳纪录", _fmt(float(result.get("total_best", 0.0))), Rect2(1082, 354, 222, 78))


func _stat_card(node_name: String, caption: String, value: String, rect: Rect2, value_name := "") -> void:
	Ui.panel(_stage, node_name, rect, Ui.BORDER)
	var heading := Ui.label(_stage, node_name + "Caption", caption, 16, Ui.MUTED)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(heading, Rect2(rect.position + Vector2(16, 8), Vector2(rect.size.x - 32, 24)))
	var display := Ui.label(_stage, value_name if not value_name.is_empty() else node_name + "Value", value, 25)
	display.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(display, Rect2(rect.position + Vector2(16, 32), Vector2(rect.size.x - 32, 42)))


func _has_finished() -> bool:
	var target := int(result.get("target", 0))
	return target > 0 and int(result.get("laps", 0)) >= target


func _completion_text() -> String:
	if not result.has("completion_saved"): return ""
	if not result["completion_saved"]:
		return tr("本次完成记录未保存\n%s") % tr(result.get("completion_error", "保存失败"))
	var count := int(result["completion_count"])
	var total := int(result["completion_total"])
	if count == total:
		return "五关全部完成！\n所有赛道仍可自由重玩"
	return tr("%s · 已完成 %d/%d\n随时自由选择赛道重玩") % [
		tr("本关首次完成，已保存") if result.get("completion_new", false) else tr("本关已完成"), count, total]


func _title_text() -> String:
	if result.get("training", false): return "训练记录"
	if result.get("split_screen", false):
		var rows: Array = result["entrants"]
		return "双人对赛 · 并列夺冠" if int(rows[1].rank) == 1 else tr("双人对赛 · %s 获胜") % rows[0].label
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
	if result.get("training", false): return "本次训练结束 · 确认记录后返回"
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
	return tr("最终名次   第 %d 名（共 %d 车）") % [position, field_size]


func _difference_text() -> String:
	var last := float(result.get("last", 0.0))
	var best := float(result.get("best", 0.0))
	if not is_finite(last) or not is_finite(best) or last <= 0 or best <= 0:
		return ""
	if last == best:
		return "末圈即本局最快圈"
	if last < best:
		return "圈速数据不一致"
	return tr("末圈比本局最快圈慢 %.3f 秒") % (last - best)


func _build_entrant_table() -> void:
	var entrants: Array = result.get("entrants", [])
	if int(result.get("field_size", 0)) <= 1 or result.get("outcome", "") == "practice":
		var practice := Ui.label(_stage, "PracticeSummary", "完成一圈后记录本次最佳单圈" if result.get("training", false) and int(result.get("laps", 0)) == 0 else "本局无对手 · 专注自己的节奏", 19, Ui.MUTED)
		Ui.place(practice, Rect2(638, 476, 642, 40))
		return
	if entrants.is_empty():
		var empty := Ui.label(_stage, "EntrantEmpty", "参赛车辆记录暂不可用", 18, Ui.MUTED)
		Ui.place(empty, Rect2(638, 476, 642, 40))
		return
	var heading := Ui.label(_stage, "EntrantHeader", "参赛车辆 · 名次 / 车手 / 圈数 / 状态", 15, Ui.MUTED)
	Ui.place(heading, Rect2(638, 438, 642, 26))
	# 保留快照顺序；rank是权威字段，不以行索引替代或另排一次名次。
	for i in range(mini(entrants.size(), 2)):
		var entry: Dictionary = entrants[i]
		var rank := int(entry.get("rank", 0))
		var label := String(entry.get("label", ""))
		if label.is_empty():
			label = "未命名车手"
		var laps_text := str(int(entry["laps"])) if entry.has("laps") else "--"
		var status := "完赛" if bool(entry.get("finished", false)) else "未完赛"
		if not entry.has("finished"):
			status = "状态未提供"
		var text := tr("%s · %s · %s 圈 · %s") % [str(rank) if rank > 0 else "--", tr(label), laps_text, tr(status)]
		var player := String(entry.get("id", "")) == "player"
		var color := _accent if player else Ui.TEXT
		var rect := Rect2(614, 468 + i * 42, 690, 38)
		var background := Ui.panel(_stage, "EntrantPanel%d" % i, rect, _accent if player else Ui.BORDER)
		if player:
			background.add_theme_stylebox_override("panel", Ui.box(Color("36202e"), _accent, 1, 0))
		var row := Ui.label(_stage, "Entrant%d" % i, text, 19, color)
		row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		Ui.place(row, Rect2(rect.position + Vector2(24, 0), Vector2(450, 38)))
		var time := Ui.label(_stage, "EntrantTime%d" % i,
			_fmt(float(entry.get("total", 0.0))) if bool(entry.get("finished", false)) else "--:--.---", 20, color)
		time.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		time.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		Ui.place(time, Rect2(rect.position + Vector2(482, 0), Vector2(186, 38)))


func _process(_delta: float) -> void:
	if GameState.phase == GameState.Phase.EXIT_CONFIRM:
		if _showcase != null: _showcase.set_suspended(true)
		_suspend_for_exit()
		return
	if _showcase != null: _showcase.set_suspended(false)
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
		if return_to_online_room.is_valid(): return_to_online_room.call()
		else: GameState.back_to_menu(true)


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


func _build_split_result() -> void:
	var online: bool = result.get("online", false)
	_root = Control.new()
	_root.name = "SplitFinishRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	Ui.install(_root)
	var shade := ColorRect.new()
	shade.color = Color(0.043, 0.071, 0.125, 0.96)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	_stage = Ui.stage(_root)
	Ui.brand(_stage, Rect2(48, 24, 456, 70))
	var mode := Ui.label(_stage, "ResultMode", tr("联机对战") if online else tr("本地双人 · 两圈对赛"), 20, Ui.MUTED)
	mode.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	Ui.place(mode, Rect2(780, 48, 538, 34))
	var heading := _title_text()
	if online:
		heading = tr("并列夺冠") if result.outcome == "tie" else (tr("你获得了冠军") if result.outcome == "win" else tr("对手获胜"))
	var title := Ui.label(_stage, "DuelTitle", heading, 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(title, Rect2(90, 116, 1186, 56))
	var entrants: Array = result["entrants"]
	for i in range(2):
		var entry: Dictionary
		if online:
			var local_slot: int = result.local_slot
			entry = entrants[local_slot if i == 0 else 1 - local_slot]
		else:
			for row in entrants:
				if row.id == ("player" if i == 0 else "p2"): entry = row
		var accent := Ui.RED if i == 0 else Ui.SKY
		var winner := int(entry.rank) == 1
		var card := Ui.panel(_stage, "Player%dResult" % (i + 1), Rect2(90 + i * 636, 190, 550, 370), accent if winner else Ui.BORDER)
		var name_text := tr("你") if i == 0 else tr("对手")
		if not online: name_text = tr("P%d · %s画面") % [i + 1, tr("左侧") if i == 0 else tr("右侧")]
		var name_label := Ui.label(card, "PlayerName", name_text, 24, accent)
		Ui.place(name_label, Rect2(24, 16, 290, 40))
		var place := Ui.label(card, "Rank", tr("第 %d 名") % int(entry.rank), 27, accent if winner else Ui.MUTED)
		place.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		Ui.place(place, Rect2(328, 18, 198, 38))
		var total_caption := Ui.label(card, "TotalCaption", tr("总用时"), 18, Ui.MUTED)
		total_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Ui.place(total_caption, Rect2(24, 82, 496, 28))
		var total := Ui.label(card, "TotalTime", _fmt(float(entry.total)), 42)
		total.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Ui.place(total, Rect2(24, 116, 496, 62))
		var lap_times: Array = entry.get("lap_times", [])
		var lap_bests: Array = entry.get("lap_bests", [0.0, 0.0])
		for lap_index in range(2):
			var x := 24 + lap_index * 252
			var caption := Ui.label(card, "Lap%dCaption" % (lap_index + 1), "第一圈耗时" if lap_index == 0 else "第二圈耗时", 17, Ui.MUTED)
			Ui.place(caption, Rect2(x, 182, 240, 26))
			var time := Ui.label(card, "Lap%dTime" % (lap_index + 1), _fmt(float(lap_times[lap_index])) if lap_index < lap_times.size() else _fmt(0.0), 24)
			Ui.place(time, Rect2(x, 208, 240, 34))
			if online: continue
			var best_caption := Ui.label(card, "Lap%dBestCaption" % (lap_index + 1), "第一圈最佳纪录" if lap_index == 0 else "第二圈最佳纪录", 16, Ui.MUTED)
			Ui.place(best_caption, Rect2(x, 252, 240, 26))
			var best := Ui.label(card, "Lap%dBest" % (lap_index + 1), _fmt(float(lap_bests[lap_index])), 23)
			Ui.place(best, Rect2(x, 278, 240, 34))
		var best_text := tr("本局最快圈") + "  " + _fmt(float(entry.get("best", 0.0))) if online else tr("总最佳纪录") + "  " + _fmt(float(entry.get("total_best", 0.0)))
		var record := Ui.label(card, "TotalBest", best_text, 20, Ui.SKY)
		Ui.place(record, Rect2(24, 324, 496, 32))
		var destination := card.position
		card.position.x += -28 if i == 0 else 28
		card.modulate.a = 0.0
		var tween := create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS).set_parallel(true)
		tween.tween_property(card, "position", destination, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(card, "modulate:a", 1.0, 0.3)
	if online:
		_back = Ui.button(_stage, "BackButton", tr("再比一场"), Rect2(284, 612, 370, 56), Ui.RED)
		_quit = Ui.button(_stage, "QuitButton", tr("离开房间"), Rect2(712, 612, 370, 56), Ui.SKY)
		_back.pressed.connect(return_to_online_room)
		_quit.pressed.connect(leave_online_room)
		var online_buttons: Array[Control] = [_back, _quit]
		Ui.focus_ring(online_buttons, true)
		_back.grab_focus()
		_last_focus = _back
		return
	var note := Ui.label(_stage, "DuelRecordNote", tr("双人纪录按 P1 / P2 分开保存 · 不计入单人纪录与关卡完成进度"), 18, Ui.MUTED)
	Ui.place(note, Rect2(90, 568, 1186, 30))
	_back = Ui.button(_stage, "BackButton", tr("返回选关（Esc）"), Rect2(90, 612, 370, 56), Ui.SKY)
	_retry = Ui.button(_stage, "RetryButton", tr("再比一场"), Rect2(498, 612, 370, 56), Ui.RED)
	_quit = Ui.button(_stage, "QuitButton", tr("退出游戏"), Rect2(906, 612, 370, 56), Ui.SKY)
	_back.pressed.connect(GameState.back_to_menu.bind(true))
	_retry.pressed.connect(GameState.restart_race)
	_quit.pressed.connect(_request_exit)
	var buttons: Array[Control] = [_back, _retry, _quit]
	Ui.focus_ring(buttons, true)
	_back.grab_focus()
	_last_focus = _back
