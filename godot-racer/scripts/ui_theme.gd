extends RefCounted
## 三页共用设计令牌与纯展示辅助函数。配置由消费方传入，无流程状态。

const BASE_SIZE := Vector2(1366, 705)
const BACKGROUND := Color("0b1220")
const PANEL := Color("172235")
const TEXT := Color("f3f6fa")
const MUTED := Color("b8c2d1")
const BORDER := Color("3a4a63")
const WARNING := Color("f1c477")
const SKY := Color("7fb3e8")
const RED := Color("ff454d")
const RACE_SURFACE := Color(PANEL, 0.88)
const RACE_EDGE := Color("586e8b")
static var keyboard_navigation := false

static func focus_style(node: Control, style: StyleBox) -> void:
	node.set_meta("navigation_focus_style", style)
	node.add_theme_stylebox_override("focus", style if keyboard_navigation else StyleBoxEmpty.new())

static func update_navigation(event: InputEvent, root: Node) -> void:
	var show := keyboard_navigation
	if event is InputEventMouseButton or event is InputEventScreenTouch:
		show = false
	elif event is InputEventMouseMotion and event.relative.length() > 1.0:
		show = false
	elif event is InputEventKey and event.pressed:
		show = true
	elif event is InputEventJoypadButton and event.pressed:
		show = true
	elif event is InputEventJoypadMotion and absf(event.axis_value) > 0.5:
		show = true
	if show == keyboard_navigation: return
	keyboard_navigation = show
	for node in root.find_children("*", "Control", true, false):
		if node.has_meta("navigation_focus_style"):
			node.add_theme_stylebox_override("focus", node.get_meta("navigation_focus_style") if show else StyleBoxEmpty.new())


static func accent(cfg: Resource) -> Color:
	if cfg == null:
		return SKY
	match String(cfg.get("weather_type")):
		"rain":
			return Color("6e86c8") if bool(cfg.get("is_night")) else SKY
		"sand":
			return Color("e0b368")
		"snow":
			return Color("a8c4dc")
	return SKY


static var ui_font := SystemFont.new()


static func set_font_language(locale: String) -> void:
	var family := {
		"zh_CN": "Microsoft YaHei UI", "zh_TW": "Microsoft JhengHei UI",
		"ja": "Yu Gothic UI", "ko": "Malgun Gothic",
	}.get(locale, "Segoe UI") as String
	ui_font.font_names = PackedStringArray([family, "sans-serif"])


static func install(root: Control) -> void:
	var theme := Theme.new()
	theme.default_font = ui_font
	theme.default_font_size = 18
	root.theme = theme


static func place(node: Control, rect: Rect2) -> void:
	node.position = rect.position
	node.size = rect.size


static func stage(root: Control) -> Control:
	var content := Control.new()
	content.name = "Stage"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.size = BASE_SIZE
	root.add_child(content)
	root.resized.connect(fit_stage.bind(content, root))
	fit_stage(content, root)
	return content


static func fit_stage(content: Control, root: Control) -> void:
	var factor := minf(root.size.x / BASE_SIZE.x, root.size.y / BASE_SIZE.y)
	content.scale = Vector2.ONE * factor
	content.position = (root.size - BASE_SIZE * factor) * 0.5


static func box(color: Color, border := BORDER, width := 1, padding := 20) -> StyleBox:
	var style := preload("res://scripts/racing_style.gd").new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(width)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style

class Brand extends Control:
	var title: Label
	var subtitle: Label

	func _notification(what: int) -> void:
		if what == NOTIFICATION_TRANSLATION_CHANGED and title != null:
			refresh.call_deferred()

	func refresh() -> void:
		var primary := tr("棱角飞车")
		var bilingual := primary != "EDGE RACER"
		title.text = primary
		var title_height := size.y * 0.70 if bilingual else size.y
		var desired_size := roundi(title_height * 0.70)
		var font := title.get_theme_font("font")
		var text_width := font.get_string_size(primary, HORIZONTAL_ALIGNMENT_LEFT, -1, desired_size).x
		title.add_theme_font_size_override("font_size", floori(desired_size * minf(1.0, size.x / maxf(1.0, text_width))))
		title.size = Vector2(size.x, title_height)
		subtitle.visible = bilingual
		subtitle.position.y = title_height
		subtitle.size = Vector2(size.x, size.y - title_height if bilingual else 0.0)


static func brand(parent: Node, rect: Rect2) -> Control:
	var root := Brand.new()
	root.name = "RacerBrand"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(root, rect)
	parent.add_child(root)
	var bold := FontVariation.new()
	bold.base_font = ui_font
	bold.variation_embolden = 0.65
	root.title = label(root, "BrandTitle", "")
	root.title.add_theme_font_override("font", bold)
	root.subtitle = label(root, "BrandSubtitle", "EDGE RACER", roundi(rect.size.y * 0.21), RED)
	for line: Label in [root.title, root.subtitle]:
		line.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.clip_text = true
		line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	root.refresh()
	return root


static func panel(parent: Node, node_name: String, rect: Rect2, color := BORDER, fill := PANEL) -> Panel:
	var node := Panel.new()
	node.name = node_name
	node.add_theme_stylebox_override("panel", box(fill, color))
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place(node, rect)
	parent.add_child(node)
	return node


static func label(parent: Node, node_name: String, text: String, font_size := 18,
		color := TEXT) -> Label:
	var node := Label.new()
	node.name = node_name
	node.text = text
	node.add_theme_font_size_override("font_size", font_size)
	node.add_theme_color_override("font_color", color)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(node)
	return node


static func button(parent: Node, node_name: String, text: String, rect: Rect2,
		color: Color) -> Button:
	var node := Button.new()
	node.name = node_name
	node.text = text
	node.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	place(node, rect)
	style_button(node, color)
	parent.add_child(node)
	return node


static func style_button(node: Button, color: Color, selected := false) -> void:
	var pressed := Sfx.button_pressed.bind(node)
	if not node.pressed.is_connected(pressed):
		node.pressed.connect(pressed)
		node.mouse_entered.connect(Sfx.button_hovered)
		node.focus_entered.connect(Sfx.button_hovered)
	node.add_theme_font_size_override("font_size", 19)
	node.add_theme_color_override("font_color", TEXT)
	node.add_theme_color_override("font_hover_color", TEXT)
	node.add_theme_color_override("font_focus_color", TEXT)
	node.add_theme_color_override("font_pressed_color", TEXT)
	var fill := Color("63202b") if selected and color.is_equal_approx(RED) else PANEL
	node.add_theme_stylebox_override("normal", box(fill, color if selected else BORDER, 2 if selected else 1, 8))
	node.add_theme_stylebox_override("hover", box(PANEL.lightened(0.06), color, 2, 8))
	node.add_theme_stylebox_override("pressed", box(PANEL.lightened(0.12), color, 2, 8))
	focus_style(node, box(Color.TRANSPARENT, color, 3, 8))
	node.add_theme_stylebox_override("disabled", box(PANEL, BORDER, 1, 8))


## 卡片选择与键盘焦点独立；天气强调色仅用于赛事标题。
static func style_level_card(node: Button, selected := false) -> void:
	style_button(node, RED, selected)
	node.add_theme_stylebox_override("normal", box(Color("52202c") if selected else PANEL,
		RED if selected else BORDER, 2 if selected else 1, 8))
	var focus := box(Color.TRANSPARENT, TEXT, 1, 8)
	focus.set_expand_margin_all(-6)
	focus_style(node, focus)


static func style_speed_slider(node: HSlider) -> void:
	var track := box(Color("485363"), Color.TRANSPARENT, 0, 0)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	node.add_theme_stylebox_override("slider", track)
	var fill = track.duplicate()
	fill.bg_color = SKY
	node.add_theme_stylebox_override("grabber_area", fill)
	node.add_theme_stylebox_override("grabber_area_highlight", fill)
	for item in ["grabber", "grabber_highlight", "grabber_disabled"]:
		var image := Image.create(20, 20, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		for y in range(20):
			for x in range(20):
				if Vector2(x - 9.5, y - 9.5).length() <= 9.5:
					image.set_pixel(x, y, TEXT if item != "grabber_disabled" else MUTED)
		node.add_theme_icon_override(item, ImageTexture.create_from_image(image))


static func focus_ring(controls: Array[Control], horizontal := false) -> void:
	for i in range(controls.size()):
		var current := controls[i]
		var before := current.get_path_to(controls[posmod(i - 1, controls.size())])
		var after := current.get_path_to(controls[(i + 1) % controls.size()])
		current.focus_previous = before
		current.focus_next = after
		current.focus_neighbor_top = before
		current.focus_neighbor_bottom = after
		if horizontal:
			current.focus_neighbor_left = before
			current.focus_neighbor_right = after


static func suspend_focus(root: Control) -> Dictionary:
	var saved: Dictionary = {}
	for control in root.find_children("*", "Control", true, false):
		if control.focus_mode != Control.FOCUS_NONE:
			saved[control] = control.focus_mode
			control.focus_mode = Control.FOCUS_NONE
	return saved


static func restore_focus(saved: Dictionary) -> void:
	for control in saved:
		if is_instance_valid(control):
			control.focus_mode = saved[control]
