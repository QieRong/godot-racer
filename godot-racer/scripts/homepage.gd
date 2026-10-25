extends Control
## 独立2D首页＋隔离的实时3D展车，关卡数量由装配方注入。

signal start_requested
signal settings_requested(trigger: Control)
signal help_requested(trigger: Control)
signal exit_requested

const Ui := preload("res://scripts/ui_theme.gd")
const CarShowcase := preload("res://scripts/car_showcase.gd")

var _level_count := 0
var _stage: Control
var _controls: Array[Control] = []
var _music: Node
var _music_button: Button


func setup(level_count: int, music: Node = null) -> void:
	_level_count = level_count
	_music = music


func _ready() -> void:
	name = "Homepage"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage = Ui.stage(self)
	var category := Ui.label(_stage, "HomeCategory", "单人竞速", 18, Ui.SKY)
	Ui.place(category, Rect2(80, 78, 480, 30))
	var title := Ui.label(_stage, "HomeTitle", "Godot 赛车", 40)
	Ui.place(title, Rect2(80, 120, 480, 64))
	var intro := Ui.label(_stage, "HomeIntro", "选一条赛道，从起跑线开始。", 18, Ui.MUTED)
	Ui.place(intro, Rect2(80, 208, 480, 32))
	var start := Ui.button(_stage, "HomeStartButton", "开始游戏", Rect2(80, 316, 330, 64), Ui.SKY)
	Ui.style_button(start, Ui.SKY, true)
	start.add_theme_font_size_override("font_size", 24)
	start.disabled = _level_count == 0
	start.pressed.connect(func(): start_requested.emit())
	var settings := Ui.button(_stage, "HomeSettingsButton", "设置", Rect2(80, 400, 330, 48), Ui.SKY)
	settings.pressed.connect(func(): settings_requested.emit(settings))
	var help := Ui.button(_stage, "HomeHelpButton", "操作帮助", Rect2(80, 464, 330, 48), Ui.SKY)
	help.pressed.connect(func(): help_requested.emit(help))
	var quit_button := Ui.button(_stage, "HomeQuitButton", "退出游戏", Rect2(80, 528, 330, 48), Ui.SKY)
	quit_button.pressed.connect(func(): exit_requested.emit())
	_controls.assign([start, settings, help, quit_button])
	Ui.focus_ring(_controls)
	_music_button = Ui.button(_stage, "HomeMusicButton", "背景音乐：不可用", Rect2(80, 586, 330, 36), Ui.SKY)
	_music_button.add_theme_font_size_override("font_size", 16)
	_music_button.disabled = _music == null
	if _music != null:
		_music_button.pressed.connect(func(): _music.set_enabled(not _music.enabled))
		_music.enabled_changed.connect(_refresh_music)
		_refresh_music(_music.enabled)
	_controls.append(_music_button)
	Ui.focus_ring(_controls)
	var count_text := "%d 条赛道 · 从选关开始" % _level_count if _level_count > 0 else "暂无可用赛道"
	var count_label := Ui.label(_stage, "HomeLevelCount", count_text, 18, Ui.MUTED)
	Ui.place(count_label, Rect2(80, 654, 480, 32))
	var showcase := CarShowcase.new()
	showcase.name = "HomeCarShowcase"
	Ui.place(showcase, Rect2(460, 82, 874, 510))
	_stage.add_child(showcase)
	var interaction_hint := Ui.label(_stage, "CarInteractionHint", "悬停暂停 · 左右拖动查看", 15, Ui.MUTED)
	Ui.place(interaction_hint, Rect2(790, 592, 496, 28))
	var hint := Ui.label(_stage, "HomeKeyboardHint", "↑↓ 选择 · Enter 确认 · ESC 退出", 15, Ui.MUTED)
	Ui.place(hint, Rect2(790, 632, 496, 32))
	# 左侧菜单首帧可见；暗场与升降只由右侧独立展示世界负责。
	_stage.modulate.a = 1.0


func controls() -> Array[Control]:
	return _controls


func overlay_host() -> Control:
	return _stage


func set_presentation_suspended(value: bool) -> void:
	var showcase := find_child("HomeCarShowcase", true, false)
	if showcase != null:
		showcase.set_suspended(value)


func _refresh_music(value: bool) -> void:
	_music_button.text = "背景音乐：%s" % ("开启" if value else "关闭")
