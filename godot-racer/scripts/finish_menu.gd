extends CanvasLayer
## 比赛结算界面；数据由 GameState 的首次完成快照提供（finish_snapshot）。
##
## 策划案 §7.3（plan/racing-system-design-20261018.md「结算页改版」）展示要求：
##   · 结果行：最终名次 第 X 名（共 N 车）；第 1 名时附加「你获得了冠军」；
##     无对手（field_size ≤ 1）显示练习文案、不排名次
##   · 成绩区：完成 X/Y 圈 · 总时间 mm:ss.mmm · 末圈 · 最快圈
##   · 对手成绩表：每行 名次 · 车手 · 圈数 · 状态（完赛/未完赛）；玩家行高亮
##   · 按钮：返回主菜单（ESC）/ 再玩一局 / 退出游戏（退出走既有确认框）
##
## 向后兼容：快照全部用 `result.get()` 读 —— 没有 position / field_size /
## entrants 这些新键的旧快照按默认值渲染（练习文案、无成绩表），不报错。
##
## 复用取舍（策划案 D6 / ALT-003）：沿用这个全屏 CanvasLayer，不建独立 .tscn 场景 ——
## 底层比赛画面被冻结（get_tree().paused），结算页"盖"在它上面；成绩真值的
## 唯一来源仍是 GameState.finish_snapshot，本文件只负责展示。

var result: Dictionary = {}

## 玩家行高亮色（成绩表第一用途是"找到我"，其次才是对比对手）。
## 金色与"冠军"语义同源，又和默认白字的对手行拉开差距。
const PLAYER_ROW_COLOR := Color(1.0, 0.85, 0.25, 1.0)


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
	# ---- 结果行（名次 / 冠军）----
	var result_line := Label.new()
	result_line.text = _result_line_text()
	result_line.add_theme_font_size_override("font_size", 24)
	rows.add_child(result_line)
	# ---- 成绩区（圈数 / 总时间 / 末圈 / 最快圈）----
	var summary := Label.new()
	summary.text = "完成 %d/%d 圈 · 总时间 %s\n末圈 %.2f 秒 · 最快圈 %.2f 秒" % [
		int(result.get("laps", 0)), int(result.get("target", 0)),
		_fmt(float(result.get("total", 0.0))),
		float(result.get("last", 0.0)), float(result.get("best", 0.0))]
	summary.add_theme_font_size_override("font_size", 20)
	rows.add_child(summary)
	# ---- 对手成绩表（有对手才渲染；练习模式没有"对手"可比）----
	_build_entrant_table(rows)
	# ---- 三个出口 ----
	var back := _add_button(rows, "返回主菜单（ESC）", GameState.back_to_menu)
	_add_button(rows, "再玩一局", GameState.restart_race)
	_add_button(rows, "退出游戏", GameState.request_exit)
	back.grab_focus()


## 结果行文案。field_size ≤ 1 = 本局没有对手（AI 关闭 / 练习），
## 报「第 1 名（共 1 车）」是句废话 —— 玩家自己完赛即完赛，直接说练习。
func _result_line_text() -> String:
	var field_size := int(result.get("field_size", 0))
	var position := int(result.get("position", 0))
	if field_size <= 1:
		return "练习完成 · 本局无对手"
	var text := "最终名次   第 %d 名（共 %d 车）" % [position, field_size]
	if position == 1:
		text += "\n你获得了冠军"
	return text


## 对手成绩表。entrants 来自 race_position.standings()（实时名次与最终成绩
## 同一把尺），行内字段见 race_position.gd 的 _entry()：rank / label / laps /
## finished。玩家行高亮。注意 AI 行允许「未完赛」—— AI 卡死不终止玩家比赛
## （策划案 E4），成绩表如实反映它的实际圈数。
func _build_entrant_table(rows: VBoxContainer) -> void:
	var entrants: Array = result.get("entrants", [])
	if entrants.size() <= 1:
		return
	var head := Label.new()
	head.text = "对手成绩"
	head.add_theme_font_size_override("font_size", 18)
	rows.add_child(head)
	for entry in entrants:
		var row := Label.new()
		row.text = "%d · %s · %d 圈 · %s" % [
			int(entry.get("rank", 0)), String(entry.get("label", "?")),
			int(entry.get("laps", 0)),
			"完赛" if bool(entry.get("finished", false)) else "未完赛"]
		row.add_theme_font_size_override("font_size", 19)
		if String(entry.get("id", "")) == "player":
			row.add_theme_color_override("font_color", PLAYER_ROW_COLOR)
		rows.add_child(row)


func _add_button(parent: VBoxContainer, label: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(320, 46)
	button.pressed.connect(handler)
	parent.add_child(button)
	return button


## ESC 与「返回主菜单」等价（都是 back_to_menu，不会把比赛恢复成 RACING）。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and GameState.phase_name() == "FINISHED":
		get_viewport().set_input_as_handled()
		GameState.back_to_menu()


## mm:ss.mmm，总时间 ≤ 0（没出发/异常）时给占位。与 hud.gd 的 _fmt 同口径 ——
## 两处各留一份纯格式化是有意的：跨文件耦合一个 6 行函数不划算，
## 口径的一致性由 tests/finish_results_test.gd 与 hud 断言双向钉住。
func _fmt(t: float) -> String:
	if t <= 0.0:
		return "--:--.---"
	# ⚠ 必须先归一到毫秒再拆位：若秒、毫秒分别 int/round，秒的小数落在
	#   [0.9995, 1.0) 时会 round 出 1000 毫秒，%03d 于是打出四位小数
	#   （00:59.1000）。先 round(t*1000) 再整除，进位自然带到秒/分。
	var total_ms := int(round(t * 1000.0))
	var m := total_ms / 60000
	var s := (total_ms / 1000) % 60
	var ms := total_ms % 1000
	return "%02d:%02d.%03d" % [m, s, ms]
