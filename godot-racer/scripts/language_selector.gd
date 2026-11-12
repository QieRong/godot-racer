extends HBoxContainer

signal language_changed(lang_code: String)

var languages = ["跟随系统", "简体中文", "繁体中文", "English", "Русский", "日本語", "한국어"]
const LANGUAGE_CODES := ["automatic", "zh_CN", "zh_TW", "en", "ru", "ja", "ko"]
var index := 0
var left_button: Button
var right_button: Button
var language_label: Label

func _ready() -> void:
	add_theme_constant_override("separation", 8)
	left_button = _arrow("LeftArrow", "<", -1)
	language_label = Label.new()
	language_label.name = "LanguageName"
	language_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	language_label.custom_minimum_size = Vector2(174, 42)
	language_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	language_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	language_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	language_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(language_label)
	right_button = _arrow("RightArrow", ">", 1)
	_update_label()

func _arrow(node_name: String, caption: String, step: int) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.flat = true
	button.custom_minimum_size = Vector2(44, 42)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(_cycle.bind(step))
	add_child(button)
	return button

func select_code(code: String) -> void:
	index = LANGUAGE_CODES.find(code)
	if index < 0: index = 0
	if is_instance_valid(language_label): _update_label()

func _cycle(step: int) -> void:
	index = posmod(index + step, languages.size())
	_update_label()
	language_changed.emit(LANGUAGE_CODES[index])

func _update_label() -> void:
	language_label.text = languages[index]
