extends Control
## 菜单路由：独立首页→选关卡片＋真实赛事信息板；共用设置与帮助。
## 仅改展示与菜单交互，不复制关卡数据，不触碰发车/物理。
## UI全部脚本构建，不修改tscn，避免编辑器重排UID和丢失场景注释。
## 关卡从GameState加载；CLI直连保留，自动开始直接进入、不要求双击。

const GAME_SCENE := "res://scenes/main.tscn"
const Ui := preload("res://scripts/ui_theme.gd")
const MenuOverlay := preload("res://scripts/menu_overlay.gd")
const Homepage := preload("res://scripts/homepage.gd")
const MenuMusic := preload("res://scripts/menu_music.gd")
const DOUBLE_CLICK_MS := 300

var _selected_idx := -1
var _pending_idx := -1
var _pending_ms := 0
var _locked := false
var enter_requests := 0
## 仅测试置true；生产默认仍执行真实场景切换。
var suppress_scene_change := false

var _level_list: VBoxContainer
var _speed_slider: HSlider
var _speed_value: Label
var _hint: Label
var _buttons: Array[Button] = []
var _stage: Control
var _mode_button: Button
var _records_button: Button
var _home: Control
var _back_home: Button
var _level_name: Label
var _blurb: Label
var _facts: VBoxContainer
var _record_label: Label
var _preview: TextureRect
var _recommended: Label
var _marker: ColorRect
var _start: Button
var _mode_page: Control
var _online_page: Control
var _mode_return_to_select := false
var _ai_quick: Button
var _settings: Button
var _help: Button
var _exit: Button
var _accent := Ui.SKY
var _overlay: Control
var _return_focus: Control
var _last_focus: Control
var _was_exit := false
var _exit_focus: Dictionary = {}
var _music: Node


func _ready() -> void:
	GameState.enter_menu()
	# 验收/直连模式：
	#   --check=xxx    跑自检（必须跳过菜单，否则 run-check.ps1 全废）
	#   --level=N      直接进第 N 关
	#   --autostart=N  先显示菜单，短暂停顿后自动点第 N 关 —— 用来端到端验证"菜单→关卡"这条链路
	var args := OS.get_cmdline_user_args()
	var want_check := false
	var forced_level := -1
	var autostart := -1
	for a in args:
		if a.begins_with("--check="):
			want_check = true
		elif a.begins_with("--level="):
			forced_level = int(a.split("=", true, 1)[1])
		elif a.begins_with("--autostart="):
			autostart = int(a.split("=", true, 1)[1])
	if want_check or forced_level >= 0:
		if forced_level >= 0:
			GameState.chosen_level = forced_level
		print("[Menu] 检测到启动参数，跳过菜单直接进关卡（level=%d）" % GameState.chosen_level)
		# 必须 call_deferred：在 _ready 里直接 change_scene_to_file 时，
		# 场景树正在"添加子节点"，Godot 会报
		# "Parent node is busy adding/removing children, remove_child() can't be called"
		_enter_game.call_deferred()
		return
	_build_ui()
	GameState.language_changed.connect(_refresh_language)
	_music = GameState.find_child("MenuMusic", false, false)
	if _music == null:
		_music = MenuMusic.new()
		_music.setup(GameState)
		GameState.add_child(_music)
	_home = Homepage.new()
	_home.setup(GameState.level_count())
	_home.start_requested.connect(_show_mode_select)
	_home.settings_requested.connect(func(trigger: Control): _open_overlay("settings", trigger))
	_home.help_requested.connect(func(trigger: Control): _open_overlay("help", trigger))
	_home.exit_requested.connect(_request_exit)
	add_child(_home)
	_mode_page = preload("res://scripts/game_mode_menu.gd").new()
	_mode_page.selected.connect(_select_mode)
	_mode_page.back_requested.connect(_back_from_modes)
	add_child(_mode_page)
	_mode_page.hide()
	if GameState.menu_show_level_select:
		GameState.menu_show_level_select = false
		_show_level_select()
		_on_level_focus(GameState.chosen_level)
		if not _buttons.is_empty():
			_buttons[GameState.chosen_level].grab_focus()
	else:
		_show_home()
	if autostart >= 0:
		_show_level_select()
		_autostart_after(autostart)
	# --shot-menu[=N]：第 N 帧把菜单截下来再退出。
	# 为什么需要它：菜单是独立场景，main.gd 的 --shot 只管关卡场景，
	# 没有这个就没法**看到**菜单改动（AI 开关这种纯 UI 改动不截图等于没验证）。
	for a in args:
		if a == "--shot-menu" or a.begins_with("--shot-menu="):
			var frames := 30
			if a.contains("="):
				frames = int(a.split("=", true, 1)[1])
			_shot_menu_after(frames)


func _shot_menu_after(frames: int) -> void:
	for i in range(maxi(1, frames)):
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	var out := ProjectSettings.globalize_path("res://").path_join("..") \
		.simplify_path().path_join("godot-logs").path_join("menu.png")
	var err := img.save_png(out)
	print("[菜单截图] save_png -> %d  路径=%s" % [err, out])
	# BGM安全收尾只作用于CLI截图，不改变截图帧号或比赛时序。
	await GameState.quit_after_menu_audio()


## 停顿一下再模拟"点第 n 关"，用于验证菜单按钮真的能进关卡
func _autostart_after(n: int) -> void:
	await get_tree().create_timer(1.5).timeout
	print("[Menu] --autostart：模拟点击第 %d 关" % (n + 1))
	if _locked:
		return
	GameState.chosen_level = clampi(n, 0, maxi(GameState.level_count() - 1, 0))
	_locked = true
	enter_requests += 1
	_enter_game()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Ui.install(self)
	var bg := ColorRect.new()
	bg.color = Ui.BACKGROUND
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_stage = Ui.stage(self)
	Ui.brand(_stage, Rect2(48, 24, 456, 70))
	var title := Ui.label(_stage, "GameTitle", "选择赛道", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(title, Rect2(48, 100, 456, 52))
	var sub := Ui.label(_stage, "MenuSubtitle", "五关自由选择 · 普通两圈完赛即记完成", 18, Ui.MUTED)
	Ui.place(sub, Rect2(48, 152, 456, 28))
	var progress := Ui.label(_stage, "CompletionSummary", _completion_text(), 16, Ui.SKY)
	progress.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	progress.add_theme_constant_override("line_spacing", 1)
	Ui.place(progress, Rect2(48, 181, 456, 24))
	_back_home = Ui.button(_stage, "BackHomeButton", "返回首页", Rect2(48, 638, 188, 44), Ui.SKY)
	_back_home.pressed.connect(_show_home)
	_records_button = Ui.button(_stage, "RecordsButton", "最佳纪录", Rect2(950, 38, 170, 42), Ui.SKY)
	_records_button.pressed.connect(_open_overlay.bind("records", _records_button))
	_mode_button = Ui.button(_stage, "ModeButton", "", Rect2(1136, 38, 182, 42), Ui.SKY)
	_mode_button.pressed.connect(_show_mode_select)
	_level_list = VBoxContainer.new()
	_level_list.name = "LevelList"
	Ui.place(_level_list, Rect2(48, 214, 456, 414))
	_stage.add_child(_level_list)
	_level_list.add_theme_constant_override("separation", 6)
	_level_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_level_buttons()
	var info := Ui.panel(_stage, "InfoPanel", Rect2(536, 122, 782, 482))
	_level_name = Ui.label(info, "LevelName", "未找到可用关卡", 32)
	_level_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_level_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	Ui.place(_level_name, Rect2(24, 220, 516, 48))
	_preview = TextureRect.new()
	_preview.name = "TrackPreview"
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_preview.clip_contents = true
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.place(_preview, Rect2(20, 18, 742, 190))
	info.add_child(_preview)
	_ai_quick = Ui.button(info, "AiQuickButton", "", Rect2(560, 222, 202, 44), _accent)
	_ai_quick.add_theme_font_size_override("font_size", 17)
	_ai_quick.toggle_mode = true
	_ai_quick.pressed.connect(_toggle_ai)
	_refresh_ai_button()
	_blurb = Ui.label(info, "LevelBlurb", "", 15, Ui.MUTED)
	_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(_blurb, Rect2(24, 274, 734, 36))
	var fact_margin := MarginContainer.new()
	fact_margin.name = "FactsMargin"
	Ui.place(fact_margin, Rect2(24, 316, 734, 76))
	fact_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(fact_margin)
	_facts = VBoxContainer.new()
	_facts.name = "LevelFacts"
	_facts.add_theme_constant_override("separation", 6)
	_facts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fact_margin.add_child(_facts)
	for i in range(3):
		var row := HBoxContainer.new()
		row.name = "FactRow%d" % i
		row.add_theme_constant_override("separation", 16)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_facts.add_child(row)
		var caption := Ui.label(row, "Caption", ["赛道环境", "比赛规则", "驾驶条件"][i], 14, Ui.MUTED)
		caption.custom_minimum_size.x = 100
		caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var value := Ui.label(row, "Value", "", 15, Ui.SKY if i == 0 else Ui.TEXT)
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_record_label = Ui.label(info, "SelectedRecord", "", 16, Ui.SKY)
	Ui.place(_record_label, Rect2(24, 398, 734, 24))
	_build_speed_panel()
	_start = Ui.button(_stage, "StartButton", "开始比赛", Rect2(982, 628, 336, 60), Ui.RED)
	_settings = Ui.button(_stage, "SettingsButton", "设置", Rect2(254, 638, 200, 44), _accent)
	_help = Ui.button(_stage, "HelpButton", "操作帮助", Rect2(472, 638, 220, 44), _accent)
	_exit = Ui.button(_stage, "ExitButton", "退出游戏", Rect2(710, 638, 248, 44), _accent)
	_start.pressed.connect(_on_start_pressed)
	_settings.pressed.connect(_open_overlay.bind("settings", _settings))
	_help.pressed.connect(_open_overlay.bind("help", _help))
	_exit.pressed.connect(_request_exit)
	var keys := Ui.label(_stage, "KeyboardHint", "单击选关 · 双击/连按确认 · Tab 切换", 15, Ui.MUTED)
	Ui.place(keys, Rect2(536, 88, 782, 24))
	var controls: Array[Control] = []
	controls.assign(_buttons)
	controls.append_array([_mode_button, _records_button, _ai_quick, _speed_slider, _start, _settings, _help, _exit, _back_home])
	Ui.focus_ring(controls)
	# Tab贯穿全页；上下键只在关卡卡片间循环。
	for i in range(_buttons.size()):
		_buttons[i].focus_neighbor_top = _buttons[i].get_path_to(_buttons[posmod(i - 1, _buttons.size())])
		_buttons[i].focus_neighbor_bottom = _buttons[i].get_path_to(_buttons[(i + 1) % _buttons.size()])
	_refresh_mode_button()
	_start.disabled = _buttons.is_empty()
	_speed_slider.editable = not _buttons.is_empty()
	if _buttons.is_empty():
		_settings.grab_focus()
	process_mode = Node.PROCESS_MODE_ALWAYS


func _completion_text() -> String:
	if not GameState.completion.load_error.is_empty():
		return tr(GameState.completion.load_error)
	var completed := GameState.completion.completed_count()
	var total := GameState.level_count()
	var format := tr("已完成 %d/%d · 五关全部完成！可自由重玩") if completed == total and total > 0 else tr("已完成 %d/%d")
	return format % [completed, total]


func _refresh_language() -> void:
	_stage.get_node("CompletionSummary").text = _completion_text()
	_refresh_mode_button()
	_refresh_ai_button()
	for i in range(_buttons.size()):
		_buttons[i].tooltip_text = _track_tooltip(GameState.get_level(i))
	if _selected_idx >= 0:
		_on_level_focus(_selected_idx)


func _track_tooltip(cfg: LevelConfig) -> String:
	return tr("布局参考：%s（游戏化改编）") % cfg.get_meta("layout_reference", "")


func _build_level_buttons() -> void:
	for i in range(GameState.level_count()):
		var cfg := GameState.get_level(i)
		if cfg == null:
			continue
		var btn := Button.new()
		btn.name = "LevelCard%d" % i
		btn.tooltip_text = _track_tooltip(cfg)
		btn.custom_minimum_size = Vector2(456, 78)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		Ui.style_level_card(btn)
		_level_list.add_child(btn)
		# 动的只是内部视觉层：卡片本体始终可点击、可聚焦。
		var visual := Control.new()
		visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
		visual.size = Vector2(456, 78)
		btn.add_child(visual)
		var margin := MarginContainer.new()
		margin.name = "CardMargin"
		margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		margin.add_theme_constant_override("margin_left", 12)
		margin.add_theme_constant_override("margin_right", 12)
		margin.add_theme_constant_override("margin_top", 10)
		margin.add_theme_constant_override("margin_bottom", 10)
		margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		visual.add_child(margin)
		var row := HBoxContainer.new()
		row.name = "CardRow"
		row.add_theme_constant_override("separation", 14)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		margin.add_child(row)
		var picture := TextureRect.new()
		picture.name = "CardPreview"
		picture.texture = _track_texture(i)
		picture.custom_minimum_size = Vector2(104, 54)
		picture.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		picture.clip_contents = true
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(picture)
		var text_block := VBoxContainer.new()
		text_block.name = "CardText"
		text_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_block.alignment = BoxContainer.ALIGNMENT_CENTER
		text_block.add_theme_constant_override("separation", 6)
		text_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(text_block)
		var title_row := HBoxContainer.new()
		title_row.name = "CardTitleRow"
		title_row.add_theme_constant_override("separation", 8)
		title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_block.add_child(title_row)
		var name_label := Ui.label(title_row, "CardName", cfg.display_name, 18)
		name_label.custom_minimum_size.y = 26
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var id := cfg.resource_path.get_file().get_basename()
		var status := "已完成" if GameState.completion.is_completed(id) else "未完成"
		if not GameState.completion.load_error.is_empty(): status = "未读取"
		var completion_label := Ui.label(title_row, "CardCompletion", status, 13,
			Ui.SKY if GameState.completion.is_completed(id) else Ui.MUTED)
		completion_label.custom_minimum_size.x = 76
		completion_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		completion_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var detail := Ui.label(text_block, "CardDetail", _card_detail(cfg), 14, Ui.MUTED)
		detail.custom_minimum_size.y = 22
		detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		detail.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		# 原生focus样式仅表示键盘落点，不将focus_entered当作选中。
		btn.mouse_entered.connect(_on_card_hover.bind(i))
		btn.pressed.connect(_on_level_pressed.bind(i))
		_buttons.append(btn)
		visual.position.x = -24
		visual.modulate.a = 0
		var tween := create_tween().set_parallel(true)
		tween.tween_property(visual, "position:x", 0.0, 0.24).set_delay(i * 0.07)
		tween.tween_property(visual, "modulate:a", 1.0, 0.24).set_delay(i * 0.07)


func _build_speed_panel() -> void:
	var panel := Ui.panel(_stage, "SpeedPanel", Rect2(556, 548, 742, 48))
	_speed_value = Ui.label(panel, "SpeedValue", "极速调校", 16)
	Ui.place(_speed_value, Rect2(14, 10, 190, 28))
	_speed_slider = HSlider.new()
	_speed_slider.name = "SpeedSlider"
	_speed_slider.min_value = GameState.MIN_SPEED
	_speed_slider.max_value = GameState.MAX_SPEED
	_speed_slider.step = 5.0
	Ui.style_speed_slider(_speed_slider)
	_speed_slider.set_value_no_signal(GameState.effective_speed())
	Ui.place(_speed_slider, Rect2(210, 10, 350, 28))
	_speed_slider.value_changed.connect(_on_speed_changed)
	panel.add_child(_speed_slider)
	_marker = ColorRect.new()
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.size = Vector2(3, 8)
	panel.add_child(_marker)
	_recommended = Ui.label(panel, "RecommendedSpeed", "", 13, Ui.MUTED)
	Ui.place(_recommended, Rect2(586, 12, 142, 24))
	_hint = Ui.label(_stage, "SpeedHint", "选择赛道后显示赛事条件", 14, Ui.MUTED)
	Ui.place(_hint, Rect2(556, 606, 742, 20))

func _track_texture(index: int) -> Texture2D:
	return load("res://assets/ui/tracks/level_%d.png" % (index + 1)) as Texture2D


func _on_card_hover(_idx: int) -> void:
	# 悬停仅保留Button原生hover反馈，不写选中态或预览另一关。
	pass


func _on_speed_changed(v: float) -> void:
	GameState.max_speed_kmh = v
	GameState.speed_user_set = true
	_update_speed_label(v)


func _toggle_ai() -> void:
	GameState.ai_enabled = not GameState.ai_enabled
	_refresh_ai_button()
	if _selected_idx >= 0:
		_on_level_focus(_selected_idx)


func _refresh_ai_button() -> void:
	_ai_quick.disabled = GameState.split_screen
	if GameState.split_screen:
		_ai_quick.text = "双人对赛 · 无 AI"
		return
	_ai_quick.text = tr("AI 对手：%s") % (tr("开启") if GameState.ai_enabled else tr("关闭"))
	_ai_quick.set_pressed_no_signal(GameState.ai_enabled)
	Ui.style_button(_ai_quick, Ui.SKY, GameState.ai_enabled)


func _update_speed_label(v: float) -> void:
	_speed_value.text = tr("极速  %d km/h") % roundi(v)
	var cfg := GameState.current_level()
	if cfg == null:
		_hint.text = "未找到可用关卡"
		return
	_recommended.text = tr("推荐 %d km/h") % roundi(cfg.suggested_speed_kmh)
	var ratio := (cfg.suggested_speed_kmh - GameState.MIN_SPEED) / (GameState.MAX_SPEED - GameState.MIN_SPEED)
	# 滑块半径10：有效行程排除两端半径，标记位于轨道下方不遮滑块。
	_marker.position = Vector2(220 + clampf(ratio, 0, 1) * 330 - 1.5, 39)
	_marker.color = _accent
	var difference := roundi(v - cfg.suggested_speed_kmh)
	if difference == 0:
		_hint.text = "当前为本关推荐极速"
		_hint.add_theme_color_override("font_color", _accent)
	else:
		var format := tr("高于推荐 %d km/h（本关抓地力 ×%.2f，注意打滑）") if difference > 0 else tr("低于推荐 %d km/h（本关抓地力 ×%.2f）")
		_hint.text = format % [absi(difference), cfg.friction_multiplier]
		_hint.add_theme_color_override("font_color", Ui.WARNING if difference > 0 else Ui.MUTED)


func _on_level_focus(idx: int) -> void:
	if _locked:
		return
	_selected_idx = idx
	GameState.chosen_level = idx
	_refresh_mode_button()
	var cfg := GameState.get_level(idx)
	if cfg == null or _level_name == null:
		return
	_accent = Ui.RED
	_preview.texture = _track_texture(idx)
	_refresh_ai_button()
	_level_name.text = cfg.display_name
	_level_name.add_theme_color_override("font_color", _accent)
	_blurb.text = cfg.blurb
	_blurb.visible = not cfg.blurb.is_empty()
	var ai_text := tr("AI %d 台") % GameState.effective_ai_count()
	if GameState.split_screen: ai_text = tr("本地双人对赛（无 AI）")
	if not GameState.split_screen and not GameState.ai_enabled:
		ai_text = tr("AI 已关闭（配置 %d 台）") % cfg.ai_opponents
	elif not GameState.split_screen and cfg.ai_opponents == 0:
		ai_text = tr("本关无对手")
	var obstacle_count := cfg.obstacle_count
	if GameState.race_variants_enabled:
		# 只读预览数量，不持有本局组合；正式开赛才抽签。
		var preview := GameState.RaceVariants.make(cfg, 0, 0)
		if preview.get("ok", false): obstacle_count = preview.config.obstacle_count
	_facts.get_node("FactRow0/Value").text = "%s · %s · %s %s" % [tr(cfg.weather_label()), tr("夜间") if cfg.is_night else tr("白天"), tr("难度"), tr(cfg.difficulty)]
	_facts.get_node("FactRow1/Value").text = "%s %s · %s · %s %d km/h" % [tr("圈数"), str(GameState.effective_laps()) if GameState.effective_laps() > 0 else tr("不限"), ai_text, tr("推荐"), roundi(cfg.suggested_speed_kmh)]
	_facts.get_node("FactRow2/Value").text = "%s ×%.2f · %s %d · %s %d" % [tr("抓地力"), cfg.friction_multiplier, tr("静态障碍"), obstacle_count, tr("动态障碍"), cfg.dynamic_obstacle_count]
	_record_label.text = _card_record(cfg)
	_speed_slider.set_value_no_signal(GameState.effective_speed())
	_speed_slider.visible = true
	_speed_slider.editable = true
	_recommended.visible = true
	_marker.visible = true
	_start.disabled = false
	_update_speed_label(_speed_slider.value)
	for i in range(_buttons.size()):
		Ui.style_level_card(_buttons[i], i == idx)
	for button in [_start, _settings, _help, _exit]:
		Ui.style_button(button, Ui.RED if button == _start else Ui.SKY, button == _start)


func _on_start_pressed() -> void:
	if _selected_idx >= 0 and not _locked:
		_confirm_enter(_selected_idx)


func _refresh_mode_button() -> void:
	_mode_button.text = "更换玩法"
	var mode := "本地双人 · 左右分屏 · 两圈对赛" if GameState.split_screen else ("无限畅玩 · 不限圈数" if GameState.endless_mode else "单人竞速 · 两圈比赛")
	_stage.get_node("MenuSubtitle").text = mode
	_start.text = "开始双人分屏" if GameState.split_screen else "开始比赛"
	for i in range(_buttons.size()):
		_buttons[i].find_child("CardDetail", true, false).text = _card_detail(GameState.get_level(i))

func _card_record(cfg: LevelConfig) -> String:
	var id := cfg.resource_path.get_file().get_basename()
	if GameState.split_screen:
		return tr("单人两圈最佳纪录（分屏不计入）：%s") % tr(GameState.RaceRecords.time_text(GameState.records.best_time(id, false)))
	return tr("最佳纪录（%s）：%s") % [tr("无限单圈") if GameState.endless_mode else tr("普通两圈"), tr(GameState.RaceRecords.time_text(GameState.records.best_time(id, GameState.endless_mode)))]


func _card_detail(cfg: LevelConfig) -> String:
	var laps := tr("不限圈数") if GameState.endless_mode or cfg.laps_to_finish <= 0 else tr("%d 圈") % cfg.laps_to_finish
	return "%s · %s / %s" % [tr(cfg.weather_label()), tr(cfg.difficulty), laps]


func _show_mode_select() -> void:
	if _locked or _overlay != null: return
	_mode_return_to_select = _stage.visible
	_stage.hide()
	_home.hide()
	_mode_page.show()
	_mode_page.focus_current()


func _select_mode(mode: int) -> void:
	if mode == 3:
		if OS.get_name() != "Windows": return
		_mode_page.hide()
		if _online_page == null:
			_online_page = preload("res://scripts/online_pc_menu.gd").new()
			_online_page.name = "OnlinePcMenu"
			_online_page.back_requested.connect(func():
				_mode_page.show()
				_mode_page.focus_current())
			add_child(_online_page)
		_online_page.open()
		return
	GameState.split_screen = mode == 2
	GameState.endless_mode = mode == 1
	_mode_page.hide()
	_refresh_mode_button()
	_refresh_ai_button()
	_show_level_select()


func _back_from_modes() -> void:
	_mode_page.hide()
	if _mode_return_to_select: _show_level_select()
	else: _show_home()


func _on_level_pressed(idx: int) -> void:
	if _locked or GameState.phase != GameState.Phase.MENU or GameState.get_level(idx) == null:
		return
	var now := Time.get_ticks_msec()
	if idx == _pending_idx and now - _pending_ms <= DOUBLE_CLICK_MS:
		_confirm_enter(idx)
		return
	_pending_idx = idx
	_pending_ms = now
	_on_level_focus(idx)


func _confirm_enter(idx: int) -> void:
	if _locked:
		return
	_locked = true
	_pending_idx = -1
	_selected_idx = idx
	GameState.chosen_level = idx
	enter_requests += 1
	for card in _buttons:
		card.disabled = true
	_start.disabled = true
	_enter_game()


func _enter_game() -> void:
	if suppress_scene_change:
		return
	GameState.show_loading("正在读取赛道资源")
	await RenderingServer.frame_post_draw
	var error := ResourceLoader.load_threaded_request(GAME_SCENE, "PackedScene")
	if error == OK:
		while ResourceLoader.load_threaded_get_status(GAME_SCENE) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
		if ResourceLoader.load_threaded_get_status(GAME_SCENE) == ResourceLoader.THREAD_LOAD_LOADED:
			var packed: PackedScene = ResourceLoader.load_threaded_get(GAME_SCENE)
			error = get_tree().change_scene_to_packed(packed)
		else:
			error = ERR_CANT_OPEN
	if error != OK and _hint != null:
		GameState.hide_loading()
		_locked = false
		for card in _buttons:
			card.disabled = false
		_start.disabled = false
		Sfx.play_clip("界面错误", -19.0)
		_hint.text = tr("进入赛道失败（错误码 %d），可以重新选择赛道或重试") % error


func _show_empty_selection() -> void:
	_selected_idx = -1
	_pending_idx = -1
	_pending_ms = 0
	_level_name.text = "选择赛道" if not _buttons.is_empty() else "未找到可用关卡"
	_facts.get_node("FactRow0/Value").text = tr("点击左侧赛道查看赛事条件") if not _buttons.is_empty() else tr("请检查关卡资源后重新启动")
	for i in [1, 2]: _facts.get_node("FactRow%d/Value" % i).text = ""
	_blurb.visible = false
	_record_label.text = ""
	_preview.texture = null
	_start.disabled = true
	_speed_slider.visible = false
	_speed_slider.editable = false
	_speed_value.text = "极速调校"
	_recommended.visible = false
	_marker.visible = false
	_hint.text = "选择赛道后显示本关推荐极速"
	_hint.add_theme_color_override("font_color", Ui.MUTED)
	for card in _buttons:
		Ui.style_level_card(card)


func _show_home() -> void:
	if _mode_page != null: _mode_page.hide()
	if _locked or _overlay != null:
		return
	_show_empty_selection()
	_stage.hide()
	_home.show()
	var entries: Array[Control] = _home.controls()
	entries[0 if not (entries[0] as Button).disabled else 1].grab_focus()


func _show_level_select() -> void:
	if _mode_page != null: _mode_page.hide()
	if _locked or _overlay != null:
		return
	_home.hide()
	_stage.show()
	_show_empty_selection()
	if not _buttons.is_empty():
		_buttons[0].grab_focus()
	else:
		_settings.grab_focus()


func _open_overlay(kind: String, trigger: Control) -> void:
	if _overlay != null or GameState.phase != GameState.Phase.MENU:
		return
	_return_focus = trigger
	_home.set_presentation_suspended(true)
	for control in _page_controls():
		control.focus_mode = Control.FOCUS_NONE
	_overlay = MenuOverlay.new()
	_overlay.setup(GameState, Ui.SKY if _home.visible else _accent, kind, _music)
	_overlay.closed.connect(_close_overlay)
	var host: Control = _home.overlay_host() if _home.visible else _stage
	host.add_child(_overlay)


func _close_overlay() -> void:
	if _overlay == null:
		return
	_overlay.queue_free()
	_overlay = null
	_home.set_presentation_suspended(false)
	for control in _page_controls():
		control.focus_mode = Control.FOCUS_ALL
	_refresh_ai_button()
	if _selected_idx >= 0:
		_on_level_focus(_selected_idx)
	else:
		_show_empty_selection()
	if is_instance_valid(_return_focus):
		_return_focus.grab_focus()


func _page_controls() -> Array[Control]:
	if _mode_page != null and _mode_page.visible: return _mode_page.controls()
	if _home != null and _home.visible:
		return _home.controls()
	var controls: Array[Control] = []
	controls.assign(_buttons)
	controls.append_array([_mode_button, _records_button, _ai_quick, _speed_slider, _start, _settings, _help, _exit, _back_home])
	return controls


func _process(_delta: float) -> void:
	if GameState.phase == GameState.Phase.EXIT_CONFIRM:
		_suspend_for_exit()
		return
	if _was_exit:
		_was_exit = false
		_home.set_presentation_suspended(_overlay != null)
		Ui.restore_focus(_exit_focus)
		_exit_focus.clear()
		if is_instance_valid(_last_focus):
			_last_focus.grab_focus()
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		_last_focus = focused


func _suspend_for_exit() -> void:
	if _was_exit:
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		_last_focus = focused
	_exit_focus = Ui.suspend_focus(self)
	_home.set_presentation_suspended(true)
	_was_exit = true


func _request_exit() -> void:
	_suspend_for_exit()
	GameState.request_exit()


func close_online_room() -> void:
	if _online_page != null: await _online_page.close_for_quit()


func request_online_race_exit(quit_game := true) -> bool:
	if _online_page == null or not _online_page.race_active(): return false
	_online_page.request_race_exit(quit_game)
	return true


func _unhandled_input(event: InputEvent) -> void:
	if _online_page != null and _online_page.visible: return
	if GameState.phase != GameState.Phase.MENU:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _overlay != null:
			_close_overlay()
		elif _mode_page.visible:
			_back_from_modes()
		elif not _home.visible and not _locked:
			_show_home()
		else:
			_request_exit()
