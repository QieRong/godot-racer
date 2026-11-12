extends Control
## 玩法入口只负责选择。
signal selected(mode: int)
signal back_requested
const Ui := preload("res://scripts/ui_theme.gd")
var _buttons: Array[Control] = []

class ModeArt extends Control:
	var mode := 0
	var accent := Ui.RED
	func _draw() -> void:
		var line := Color(accent, 0.65)
		match mode:
			0:
				draw_line(Vector2(20, 64), Vector2(220, 64), line, 3)
				_car(Vector2(88, 52), accent)
				for x in range(5):
					for y in range(2):
						if (x + y) % 2 == 0: draw_rect(Rect2(180 + x * 8, 24 + y * 8, 8, 8), Ui.TEXT)
			1:
				var points := PackedVector2Array()
				for i in range(81):
					var t := TAU * i / 80.0
					points.append(Vector2(120 + 85 * cos(t), 45 + 27 * sin(2 * t)))
				draw_polyline(points, line, 4, true)
				_car(Vector2(120, 45), accent)
			2, 3:
				for x in [20, 140]:
					draw_style_box(Ui.box(Color("101923"), line, 2, 0), Rect2(x, 12, 95, 66))
					_car(Vector2(x + 48, 54), accent if x == 20 else Ui.SKY)
				if mode == 2: draw_line(Vector2(128, 12), Vector2(128, 78), Ui.TEXT, 2)
				else: draw_line(Vector2(70, 90), Vector2(190, 90), line, 3)
	func _car(at: Vector2, color: Color) -> void:
		draw_rect(Rect2(at - Vector2(17, 6), Vector2(34, 12)), color)
		draw_rect(Rect2(at - Vector2(9, 10), Vector2(18, 20)), color)
		for side in [-1, 1]: draw_line(at + Vector2(-23, side * 8), at + Vector2(23, side * 8), Ui.TEXT, 3)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Ui.install(self)
	var background := ColorRect.new()
	background.color = Ui.BACKGROUND
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var stage := Ui.stage(self)
	Ui.brand(stage, Rect2(48, 24, 456, 70))
	var title := Ui.label(stage, "ModeTitle", "选择玩法", 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(title, Rect2(48, 118, 1270, 52))
	var hint := Ui.label(stage, "ModeHint", "独自挑战，或和朋友一起冲线", 18, Ui.MUTED)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(hint, Rect2(48, 178, 1270, 34))
	var titles := ["单人竞速", "无限畅玩", "本地双人", "联机对战"]
	var details := ["挑战 AI · 两圈决胜", "不限圈数 · 练车与挑战圈速", "一台电脑 · 共用键盘 · 左右分屏", "Windows · 房间码邀请"]
	var modes := [0, 1, 2, 3] if GameState.supports_local_split_screen() else [0, 1, 3]
	for column in range(modes.size()):
		var i: int = modes[column]
		var accent := Ui.SKY if i == 1 or i == 3 else Ui.RED
		var card := Ui.button(stage, "ModeCard%d" % i, "", Rect2(48 + (4 - modes.size()) * 163 + column * 326, 252, 310, 320), accent)
		var available := i != 3 or OS.get_name() == "Windows"
		card.disabled = not available
		card.pressed.connect(func(): selected.emit(i))
		_buttons.append(card)
		var art := ModeArt.new()
		art.mode = i
		art.accent = accent if available else Ui.MUTED
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		Ui.place(art, Rect2(30, 30, 250, 100))
		card.add_child(art)
		var caption := Ui.label(card, "Caption", titles[i], 28, Ui.TEXT if available else Ui.MUTED)
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Ui.place(caption, Rect2(12, 156, 286, 42))
		var detail := Ui.label(card, "Detail", details[i], 17, Ui.MUTED)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		detail.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		Ui.place(detail, Rect2(20, 204, 270, 66))
		var status := Ui.label(card, "Status", "选择  →" if available else "后续开放", 18, accent if i < 3 else Ui.MUTED)
		status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Ui.place(status, Rect2(24, 276, 262, 30))
	var back := Ui.button(stage, "ModeBack", "返回（Esc）", Rect2(48, 624, 230, 48), Ui.SKY)
	back.pressed.connect(func(): back_requested.emit())
	_buttons.append(back)
	Ui.focus_ring(_buttons)

func focus_current() -> void:
	_buttons[2 if GameState.split_screen else (1 if GameState.endless_mode else 0)].grab_focus()

func controls() -> Array[Control]:
	return _buttons

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		back_requested.emit()
