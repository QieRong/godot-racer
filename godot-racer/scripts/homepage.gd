extends Control
## 独立2D首页＋隔离的实时3D展车，关卡数量由装配方注入。

signal start_requested
signal settings_requested(trigger: Control)
signal help_requested(trigger: Control)
signal exit_requested

const Ui := preload("res://scripts/ui_theme.gd")
const CarShowcase := preload("res://scripts/car_showcase.gd")
@export var showcase_rect := Rect2(454, 48, 864, 504)

var _level_count := 0
var _stage: Control
var _controls: Array[Control] = []


func setup(level_count: int) -> void:
	_level_count = level_count


func _ready() -> void:
	name = "Homepage"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage = Ui.stage(self)
	var backdrop := Control.new()
	backdrop.name = "ShowroomBackdrop"
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.size = Ui.BASE_SIZE
	_stage.add_child(backdrop)
	backdrop.draw.connect(_draw_backdrop.bind(backdrop))
	var showcase := CarShowcase.new()
	showcase.name = "HomeCarShowcase"
	Ui.place(showcase, showcase_rect)
	_stage.add_child(showcase)
	Ui.brand(_stage, Rect2(64, 48, 374, 94))
	var tagline := Ui.label(_stage, "HomeIntro", "每一道棱角，都是超车的角度。", 18, Ui.MUTED)
	tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tagline.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	tagline.max_lines_visible = 2
	tagline.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tagline.clip_text = true
	Ui.place(tagline, Rect2(68, 144, 370, 50))
	var start := _menu_button("HomeStartButton", "开始游戏", "01", 228, 72, true)
	start.disabled = _level_count == 0
	start.pressed.connect(func(): start_requested.emit())
	var settings := _menu_button("HomeSettingsButton", "设置", "02", 314, 58)
	settings.pressed.connect(func(): settings_requested.emit(settings))
	var help := _menu_button("HomeHelpButton", "操作帮助", "03", 386, 58)
	help.pressed.connect(func(): help_requested.emit(help))
	var quit_button := _menu_button("HomeQuitButton", "退出游戏", "04", 458, 58)
	quit_button.pressed.connect(func(): exit_requested.emit())
	_controls.assign([start, settings, help, quit_button])
	var category := Ui.label(_stage, "HomeCategory", "单人竞速 · 本地双人", 15, Ui.MUTED)
	Ui.place(category, Rect2(68, 540, 450, 30))
	Ui.focus_ring(_controls)
	var footer := Ui.panel(_stage, "HomeBottomBar", Rect2(28, 628, 1310, 60), Ui.BORDER)
	var divider := ColorRect.new()
	divider.color = Ui.BORDER
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.place(divider, Rect2(654, 12, 2, 36))
	footer.add_child(divider)
	var count_label := Ui.label(footer, "HomeLevelCount", "", 18, Ui.MUTED)
	var refresh_count := func():
		count_label.text = tr("可选赛道：%d") % _level_count if _level_count > 0 else "暂无可用赛道"
	refresh_count.call()
	GameState.language_changed.connect(refresh_count)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Ui.place(count_label, Rect2(16, 10, 622, 40))
	var hint := Ui.label(footer, "HomeKeyboardHint", "↑↓ 选择   Enter 确认   ESC 退出", 16, Ui.MUTED)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Ui.place(hint, Rect2(672, 10, 622, 40))
	# 左侧菜单首帧可见；暗场与升降只由右侧独立展示世界负责。
	_stage.modulate.a = 1.0


func _menu_button(node_name: String, text: String, number: String, y: float,
		height: float, primary := false) -> Button:
	var button := Ui.button(_stage, node_name, text, Rect2(64, y, 346, height), Ui.RED)
	Ui.style_button(button, Ui.RED, primary)
	button.add_theme_font_size_override("font_size", 25 if primary else 23)
	var index := Ui.label(button, "MenuIndex", number, 16, Ui.TEXT if primary else Ui.MUTED)
	index.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Ui.place(index, Rect2(20, 0, 40, height))
	var arrow := Ui.label(button, "MenuArrow", "›", 32, Ui.TEXT if primary else Ui.MUTED)
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Ui.place(arrow, Rect2(302, 0, 30, height))
	return button


func _draw_backdrop(canvas: Control) -> void:
	canvas.draw_colored_polygon(PackedVector2Array([Vector2(410, 208), Vector2(1366, 78),
		Vector2(1366, 630), Vector2(536, 630)]), Color("101c2d"))
	canvas.draw_colored_polygon(PackedVector2Array([Vector2(480, 585), Vector2(1366, 458),
		Vector2(1366, 630), Vector2(410, 630)]), Color("172234"))
	canvas.draw_line(Vector2(438, 612), Vector2(1366, 480), Color("963c48"), 3.0)
	canvas.draw_line(Vector2(66, 198), Vector2(405, 198), Ui.RED, 3.0)
	for i in range(5):
		var x := 1070.0 + i * 56.0
		canvas.draw_line(Vector2(x, 92), Vector2(x - 70, 182), Color("24334a"), 18.0)


func controls() -> Array[Control]:
	return _controls


func overlay_host() -> Control:
	return _stage


func set_presentation_suspended(value: bool) -> void:
	var showcase := find_child("HomeCarShowcase", true, false)
	if showcase != null:
		showcase.set_suspended(value)

