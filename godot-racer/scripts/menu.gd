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
var _home: Control
var _back_home: Button
var _level_name: Label
var _blurb: Label
var _facts: Label
var _recommended: Label
var _marker: ColorRect
var _start: Button
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
	_music = GameState.find_child("MenuMusic", false, false)
	if _music == null:
		_music = MenuMusic.new()
		_music.setup(GameState)
		GameState.add_child(_music)
	_home = Homepage.new()
	_home.setup(GameState.level_count(), _music)
	_home.start_requested.connect(_show_level_select)
	_home.settings_requested.connect(func(trigger: Control): _open_overlay("settings", trigger))
	_home.help_requested.connect(func(trigger: Control): _open_overlay("help", trigger))
	_home.exit_requested.connect(_request_exit)
	add_child(_home)
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
	var title := Ui.label(_stage, "GameTitle", "选择赛道", 40)
	Ui.place(title, Rect2(48, 28, 900, 56))
	var sub := Ui.label(_stage, "MenuSubtitle", "单击查看赛事条件 · 双击确认进入赛道", 18, Ui.MUTED)
	Ui.place(sub, Rect2(48, 88, 1100, 28))
	_back_home = Ui.button(_stage, "BackHomeButton", "返回首页", Rect2(1170, 36, 148, 48), Ui.SKY)
	_back_home.pressed.connect(_show_home)
	var scroll := ScrollContainer.new()
	scroll.name = "LevelScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	Ui.place(scroll, Rect2(48, 140, 700, 458))
	_stage.add_child(scroll)
	_level_list = VBoxContainer.new()
	_level_list.add_theme_constant_override("separation", 12)
	_level_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_level_list)
	_build_level_buttons()
	var info := Ui.panel(_stage, "InfoPanel", Rect2(772, 140, 546, 220))
	_level_name = Ui.label(info, "LevelName", "未找到可用关卡", 24)
	Ui.place(_level_name, Rect2(20, 16, 300, 36))
	_ai_quick = Ui.button(info, "AiQuickButton", "", Rect2(348, 8, 178, 48), _accent)
	_ai_quick.toggle_mode = true
	_ai_quick.pressed.connect(_toggle_ai)
	_refresh_ai_button()
	_blurb = Ui.label(info, "LevelBlurb", "", 15, Ui.MUTED)
	Ui.place(_blurb, Rect2(20, 58, 506, 24))
	_facts = Ui.label(info, "LevelFacts", "请检查关卡资源后重新启动", 18)
	_facts.add_theme_constant_override("line_spacing", 8)
	Ui.place(_facts, Rect2(20, 88, 506, 116))
	_build_speed_panel()
	_start = Ui.button(_stage, "StartButton", "开始比赛", Rect2(48, 628, 230, 48), _accent)
	_settings = Ui.button(_stage, "SettingsButton", "设置", Rect2(294, 628, 170, 48), _accent)
	_help = Ui.button(_stage, "HelpButton", "操作帮助", Rect2(480, 628, 170, 48), _accent)
	_exit = Ui.button(_stage, "ExitButton", "退出游戏", Rect2(666, 628, 150, 48), _accent)
	_start.pressed.connect(_on_start_pressed)
	_settings.pressed.connect(_open_overlay.bind("settings", _settings))
	_help.pressed.connect(_open_overlay.bind("help", _help))
	_exit.pressed.connect(_request_exit)
	var keys := Ui.label(_stage, "KeyboardHint", "单击选关 · 双击/连按确认 · Tab 切换", 15, Ui.MUTED)
	Ui.place(keys, Rect2(884, 636, 434, 36))
	var controls: Array[Control] = []
	controls.assign(_buttons)
	controls.append_array([_ai_quick, _speed_slider, _start, _settings, _help, _exit, _back_home])
	Ui.focus_ring(controls)
	# Tab贯穿全页；上下键只在关卡卡片间循环。
	for i in range(_buttons.size()):
		_buttons[i].focus_neighbor_top = _buttons[i].get_path_to(_buttons[posmod(i - 1, _buttons.size())])
		_buttons[i].focus_neighbor_bottom = _buttons[i].get_path_to(_buttons[(i + 1) % _buttons.size()])
	_start.disabled = _buttons.is_empty()
	_speed_slider.editable = not _buttons.is_empty()
	if _buttons.is_empty():
		_settings.grab_focus()
	process_mode = Node.PROCESS_MODE_ALWAYS


func _build_level_buttons() -> void:
	for i in range(GameState.level_count()):
		var cfg := GameState.get_level(i)
		if cfg == null:
			continue
		var btn := Button.new()
		btn.name = "LevelCard%d" % i
		btn.custom_minimum_size = Vector2(680, 82)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		Ui.style_level_card(btn)
		_level_list.add_child(btn)
		# 动的只是内部视觉层：卡片本体始终可点击、可聚焦。
		var visual := Control.new()
		visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
		visual.size = Vector2(680, 82)
		btn.add_child(visual)
		var name_label := Ui.label(visual, "CardName", "%02d  %s  【%s】" % [i + 1, cfg.display_name, cfg.difficulty], 19)
		Ui.place(name_label, Rect2(20, 10, 640, 30))
		var laps := "%d 圈" % cfg.laps_to_finish if cfg.laps_to_finish > 0 else "不限圈数"
		var detail := Ui.label(visual, "CardDetail", "%s · %s · 推荐 %d km/h" % [cfg.weather_label(), laps, roundi(cfg.suggested_speed_kmh)], 15, Ui.MUTED)
		Ui.place(detail, Rect2(20, 44, 640, 24))
		var badge := Ui.label(visual, "SelectedBadge", "已选择", 14, Ui.SKY)
		Ui.place(badge, Rect2(582, 45, 86, 24))
		badge.hide()
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
	var panel := Ui.panel(_stage, "SpeedPanel", Rect2(772, 376, 546, 224))
	_speed_value = Ui.label(panel, "SpeedValue", "极速", 19)
	Ui.place(_speed_value, Rect2(20, 16, 506, 30))
	_speed_slider = HSlider.new()
	_speed_slider.name = "SpeedSlider"
	_speed_slider.min_value = GameState.MIN_SPEED
	_speed_slider.max_value = GameState.MAX_SPEED
	_speed_slider.step = 5.0
	Ui.style_speed_slider(_speed_slider)
	_speed_slider.set_value_no_signal(GameState.effective_speed())
	Ui.place(_speed_slider, Rect2(30, 62, 486, 28))
	_speed_slider.value_changed.connect(_on_speed_changed)
	panel.add_child(_speed_slider)
	var minimum := Ui.label(panel, "SpeedMinimum", "%d km/h" % GameState.MIN_SPEED, 14, Ui.MUTED)
	Ui.place(minimum, Rect2(20, 94, 120, 24))
	var maximum := Ui.label(panel, "SpeedMaximum", "%d km/h" % GameState.MAX_SPEED, 14, Ui.MUTED)
	Ui.place(maximum, Rect2(406, 94, 120, 24))
	maximum.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_marker = ColorRect.new()
	_marker.name = "RecommendedMarker"
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.size = Vector2(3, 12)
	panel.add_child(_marker)
	_recommended = Ui.label(panel, "RecommendedSpeed", "", 15, Ui.MUTED)
	Ui.place(_recommended, Rect2(20, 124, 506, 24))
	_hint = Ui.label(panel, "SpeedHint", "", 15)
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	Ui.place(_hint, Rect2(20, 156, 506, 54))


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
	_ai_quick.text = "AI 对手：%s" % ("开启" if GameState.ai_enabled else "关闭")
	_ai_quick.set_pressed_no_signal(GameState.ai_enabled)
	Ui.style_button(_ai_quick, Ui.SKY, GameState.ai_enabled)


func _update_speed_label(v: float) -> void:
	_speed_value.text = "极速  %d km/h" % roundi(v)
	var cfg := GameState.current_level()
	if cfg == null:
		_hint.text = "未找到可用关卡"
		return
	_recommended.text = "本关推荐 %d km/h · 拖动滑条自由调校" % roundi(cfg.suggested_speed_kmh)
	var ratio := (cfg.suggested_speed_kmh - GameState.MIN_SPEED) / (GameState.MAX_SPEED - GameState.MIN_SPEED)
	# 滑块半径10：有效行程排除两端半径，标记位于轨道下方不遮滑块。
	_marker.position = Vector2(40 + clampf(ratio, 0, 1) * 466 - 1.5, 88)
	_marker.color = _accent
	var difference := roundi(v - cfg.suggested_speed_kmh)
	if difference == 0:
		_hint.text = "当前为本关推荐极速"
		_hint.add_theme_color_override("font_color", _accent)
	else:
		_hint.text = "%s推荐 %d km/h（本关抓地力 ×%.2f%s）" % [
			"高于" if difference > 0 else "低于", absi(difference), cfg.friction_multiplier,
			"，注意打滑" if difference > 0 else ""]
		_hint.add_theme_color_override("font_color", Ui.WARNING if difference > 0 else Ui.MUTED)


func _on_level_focus(idx: int) -> void:
	if _locked:
		return
	_selected_idx = idx
	GameState.chosen_level = idx
	var cfg := GameState.get_level(idx)
	if cfg == null or _level_name == null:
		return
	_accent = Ui.accent(cfg)
	_refresh_ai_button()
	_level_name.text = cfg.display_name
	_level_name.add_theme_color_override("font_color", _accent)
	_blurb.text = cfg.blurb
	_blurb.visible = not cfg.blurb.is_empty()
	var ai_text := "AI %d 台" % GameState.effective_ai_count()
	if not GameState.ai_enabled:
		ai_text += "（已关闭；配置 %d 台）" % cfg.ai_opponents
	elif cfg.ai_opponents == 0:
		ai_text += "（本关无对手）"
	_facts.text = "%s · %s · 难度 %s\n圈数 %s · 推荐 %d km/h\n抓地力 ×%.2f · %s\n静态障碍 %d · 动态障碍 %d" % [
		cfg.weather_label(), "夜间" if cfg.is_night else "白天", cfg.difficulty,
		str(cfg.laps_to_finish) if cfg.laps_to_finish > 0 else "不限", roundi(cfg.suggested_speed_kmh),
		cfg.friction_multiplier, ai_text, cfg.obstacle_count, cfg.dynamic_obstacle_count]
	_speed_slider.set_value_no_signal(GameState.effective_speed())
	_speed_slider.visible = true
	_speed_slider.editable = true
	_recommended.visible = true
	_marker.visible = true
	_start.disabled = false
	_update_speed_label(_speed_slider.value)
	for i in range(_buttons.size()):
		Ui.style_level_card(_buttons[i], i == idx)
		_buttons[i].find_child("SelectedBadge", true, false).visible = i == idx
	for button in [_start, _settings, _help, _exit]:
		Ui.style_button(button, Ui.SKY, button == _start)


func _on_start_pressed() -> void:
	if _selected_idx >= 0 and not _locked:
		_confirm_enter(_selected_idx)


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
	var error := get_tree().change_scene_to_file(GAME_SCENE)
	if error != OK and _hint != null:
		_hint.text = "进入赛道失败（错误码 %d），请按 ESC 退出后重新启动" % error


func _show_empty_selection() -> void:
	_selected_idx = -1
	_pending_idx = -1
	_pending_ms = 0
	_level_name.text = "选择赛道" if not _buttons.is_empty() else "未找到可用关卡"
	_facts.text = "点击左侧赛道查看赛事条件" if not _buttons.is_empty() else "请检查关卡资源后重新启动"
	_blurb.visible = false
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
		card.find_child("SelectedBadge", true, false).hide()


func _show_home() -> void:
	if _locked or _overlay != null:
		return
	_show_empty_selection()
	_stage.hide()
	_home.show()
	var entries: Array[Control] = _home.controls()
	entries[0 if not (entries[0] as Button).disabled else 1].grab_focus()


func _show_level_select() -> void:
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
	if _home != null and _home.visible:
		return _home.controls()
	var controls: Array[Control] = []
	controls.assign(_buttons)
	controls.append_array([_ai_quick, _speed_slider, _start, _settings, _help, _exit, _back_home])
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


func _unhandled_input(event: InputEvent) -> void:
	if GameState.phase != GameState.Phase.MENU:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _overlay != null:
			_close_overlay()
		elif not _home.visible and not _locked:
			_show_home()
		else:
			_request_exit()
