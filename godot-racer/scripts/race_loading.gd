extends CanvasLayer
## 菜单与关卡装配共用的轻量过渡；只报告实际阶段，不伪造百分比。
const Ui := preload("res://scripts/ui_theme.gd")
var caption: Label
var stage_text := "正在读取赛道资源"
var _steps: Array[Panel] = []
class Circuit extends Control:
	var phase := 0.0
	var accent := Ui.SKY
	func _process(delta: float) -> void:
		phase = fposmod(phase + delta * 1.4, TAU)
		queue_redraw()
	func _draw() -> void:
		var center := size * 0.5
		var radius := Vector2(172, 64)
		var points := PackedVector2Array()
		for i in range(97):
			var angle := TAU * float(i) / 96.0
			points.append(center + Vector2(cos(angle), sin(angle)) * radius)
		draw_polyline(points, Color("1c2a38"), 26, true)
		draw_polyline(points, Color("354b60"), 2, true)
		for i in range(18):
			var angle := phase - float(i) * 0.045
			var point := center + Vector2(cos(angle), sin(angle)) * radius
			draw_circle(point, 3.0, Color(accent, (1.0 - float(i) / 18.0) * 0.65))
		var car := center + Vector2(cos(phase), sin(phase)) * radius
		var tangent := Vector2(-radius.x * sin(phase), radius.y * cos(phase)).angle()
		draw_set_transform(car, tangent)
		draw_style_box(Ui.box(accent, accent.lightened(0.3), 1, 0), Rect2(-12,-6,24,12))
		draw_rect(Rect2(-3,-4,7,8), Color("15202b"))
		for x in [-7.0, 6.0]:
			draw_rect(Rect2(x,-9,5,4), Color("080b10"))
			draw_rect(Rect2(x,5,5,4), Color("080b10"))
		draw_set_transform(Vector2.ZERO)

func _ready() -> void:
	name = "RaceLoading"
	layer = 180
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.name = "LoadingRoot"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	Ui.install(root)
	var background := ColorRect.new()
	background.color = Color("0b111a")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(background)
	var stage := Ui.stage(root)
	var cfg := GameState.current_level()
	var accent := Ui.accent(cfg)
	Ui.brand(stage, Rect2(42, 28, 330, 54))
	var eyebrow := Ui.label(stage, "LoadingEyebrow", "赛前准备", 16, Ui.MUTED)
	Ui.place(eyebrow, Rect2(930, 42, 394, 30))
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_rule(stage, Rect2(42, 100, 1282, 1), Ui.BORDER)
	var title := Ui.label(stage, "LoadingTitle", cfg.display_name if cfg != null else "准备比赛", 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(title, Rect2(42, 124, 1282, 54))
	var subtitle := Ui.label(stage, "LoadingSubtitle", "熟悉赛道，准备出发。", 17, Ui.MUTED)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(subtitle, Rect2(42, 181, 1282, 28))
	if cfg != null:
		subtitle.text = "%s  ·  %s" % [tr(cfg.difficulty), tr(cfg.weather_label())]
		_build_briefing(stage, cfg, accent)
	var circuit := Circuit.new()
	circuit.name = "LoadingCircuit"
	circuit.accent = accent
	Ui.place(circuit, Rect2(410, 242, 546, 220))
	circuit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stage.add_child(circuit)
	caption = Ui.label(stage, "LoadingStage", "", 22)
	Ui.place(caption, Rect2(396, 471, 574, 38))
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var hint := Ui.label(stage, "LoadingHint", "赛道巡览  →  倒计时  →  发车", 16, Ui.MUTED)
	Ui.place(hint, Rect2(396, 516, 574, 30))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	for i in range(3):
		var step := Ui.panel(stage, "LoadingStep%d" % i, Rect2(42 + i * 432, 598, 418, 46))
		_steps.append(step)
		var label := Ui.label(step, "Caption", "%02d   %s" % [i + 1, [tr("读取资源"), tr("生成赛道"), tr("布置环境")][i]], 17, Ui.TEXT)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Ui.place(label, Rect2(18, 8, 382, 30))
	set_stage(stage_text)

func _build_briefing(stage: Control, cfg: Resource, accent: Color) -> void:
	Ui.panel(stage, "TrackBriefing", Rect2(42, 230, 342, 326))
	var preview := TextureRect.new()
	preview.name = "TrackPreview"
	preview.texture = load("res://assets/ui/tracks/level_%d.png" % (GameState.chosen_level + 1))
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.place(preview, Rect2(54, 242, 318, 176))
	stage.add_child(preview)
	_rule(stage, Rect2(54, 418, 318, 3), accent)
	var condition := Ui.label(stage, "TrackCondition", tr("赛道印象  /  %s") % tr(cfg.weather_label()), 18, accent)
	Ui.place(condition, Rect2(62, 436, 302, 30))
	var blurb := Ui.label(stage, "TrackBlurb", cfg.blurb, 17, Ui.MUTED)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(blurb, Rect2(62, 477, 302, 66))
	# 自动换行的最小尺寸会延迟刷新；退栈后恢复栏宽，避免保留原单行宽度。
	blurb.set_deferred("size", Vector2(302, 66))
	Ui.panel(stage, "RaceBriefing", Rect2(982, 230, 342, 326))
	var heading := Ui.label(stage, "RaceBriefingTitle", "本局赛事", 20)
	Ui.place(heading, Rect2(1002, 246, 300, 34))
	var laps := "不限圈数" if GameState.endless_mode else tr("%d 圈") % GameState.effective_laps()
	var ai := GameState.effective_ai_count()
	var values := ["本地双人" if GameState.split_screen else ("无限畅玩" if GameState.endless_mode else "两圈竞速"), laps,
		"%d km/h" % roundi(GameState.effective_speed()), "另一位本地玩家" if GameState.split_screen else (tr("%d 名 AI") % ai if ai > 0 else "单人练习")]
	for i in range(4):
		var key := Ui.label(stage, "RaceFactKey%d" % i, ["模式", "圈数", "极速", "对手"][i], 15, Ui.MUTED)
		Ui.place(key, Rect2(1002, 294 + i * 34, 126, 30))
		var value := Ui.label(stage, "RaceFactValue%d" % i, values[i], 16)
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		Ui.place(value, Rect2(1132, 294 + i * 34, 172, 30))
	_rule(stage, Rect2(1002, 440, 302, 1), Ui.BORDER)
	var tip := "入弯前减速，出弯后再逐渐加速。"
	match String(cfg.weather_type):
		"snow": tip = "雪地抓地较低，提前收油，轻缓转向。"
		"rain": tip = "湿滑路面提前制动，避免弯中急打方向。"
		"sand": tip = "留意连续弯道与路障，先看准出弯方向。"
	var advice := Ui.label(stage, "DrivingTip", tr("驾驶建议\n%s") % tr(tip), 16, Ui.MUTED)
	advice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(advice, Rect2(1002, 448, 302, 102))
	advice.set_deferred("size", Vector2(302, 102))

func _rule(parent: Node, rect: Rect2, color: Color) -> void:
	var line := ColorRect.new()
	line.color = color
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.place(line, rect)
	parent.add_child(line)

func set_stage(text: String) -> void:
	stage_text = text
	if caption != null: caption.text = tr(text) + "…"
	var active := ["正在读取赛道资源", "正在生成道路与赛道", "正在布置场景与环境"].find(text)
	for i in range(_steps.size()):
		_steps[i].add_theme_stylebox_override("panel", Ui.box(Color("1c2935") if i == active else Color("101923"),
			Ui.RED if i == active else Ui.BORDER))
