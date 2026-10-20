extends RefCounted
## 三页共用设计令牌与纯展示辅助函数。配置由消费方传入，无流程状态。

const BASE_SIZE := Vector2(1366, 705)
const BACKGROUND := Color("0b0d11")
const PANEL := Color("14171c")
const TEXT := Color("f3f6fa")
const MUTED := Color("b8c2d1")
const BORDER := Color("364152")
const WARNING := Color("f1c477")
const SKY := Color("7fb3e8")


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


static func install(root: Control) -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "sans-serif"])
	var theme := Theme.new()
	theme.default_font = font
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


static func box(color: Color, border := BORDER, width := 1, padding := 20) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(14)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style


static func panel(parent: Node, node_name: String, rect: Rect2, color := BORDER) -> Panel:
	var node := Panel.new()
	node.name = node_name
	node.add_theme_stylebox_override("panel", box(PANEL, color))
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
	node.add_theme_font_size_override("font_size", 19)
	node.add_theme_color_override("font_color", TEXT)
	node.add_theme_color_override("font_hover_color", TEXT)
	node.add_theme_color_override("font_focus_color", TEXT)
	node.add_theme_color_override("font_pressed_color", TEXT)
	node.add_theme_stylebox_override("normal", box(PANEL, color if selected else BORDER, 2 if selected else 1, 8))
	node.add_theme_stylebox_override("hover", box(PANEL.lightened(0.06), color, 2, 8))
	node.add_theme_stylebox_override("pressed", box(PANEL.lightened(0.12), color, 2, 8))
	node.add_theme_stylebox_override("focus", box(Color.TRANSPARENT, color, 3, 8))
	node.add_theme_stylebox_override("disabled", box(PANEL, BORDER, 1, 8))


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
