extends Control
## 主菜单：选关卡 + 调极速 + 进入游戏。
##
## 设计取舍：
##   - **UI 全部代码构建**，不用 .tscn 摆节点：手写 .tscn 的 UI 属性极易出语法错，
##     而且改布局要同时动场景和脚本。代码构建只有一个来源，也便于加关卡时自动增删按钮。
##   - 关卡列表**从 GameState 读 .tres**，菜单里没有任何写死的关卡信息 ——
##     以后加关卡只丢一个 .tres 进去，菜单自动多一个按钮。
##   - `--check=` / `--level=` 启动时**直接跳过菜单**进关卡：否则 run-check.ps1
##     那套验收会因为主场景变成菜单而全部失效（这是主场景改菜单后最容易漏的坑）。

const GAME_SCENE := "res://scenes/main.tscn"

var _level_list: VBoxContainer
var _speed_slider: HSlider
## AI 对手开关按钮 + 说明
var _ai_button: Button
var _ai_hint: Label
var _speed_value: Label
var _hint: Label
var _buttons: Array[Button] = []


func _ready() -> void:
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
	if not _buttons.is_empty():
		GameState.chosen_level = clampi(GameState.chosen_level, 0, _buttons.size() - 1)
		_buttons[GameState.chosen_level].grab_focus()
		_on_level_focus(GameState.chosen_level)
	if autostart >= 0:
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
	await get_tree().process_frame
	get_tree().quit()


## 停顿一下再模拟"点第 n 关"，用于验证菜单按钮真的能进关卡
func _autostart_after(n: int) -> void:
	await get_tree().create_timer(1.5).timeout
	print("[Menu] --autostart：模拟点击第 %d 关" % (n + 1))
	_on_level_pressed(clampi(n, 0, maxi(_buttons.size() - 1, 0)))


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 背景
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.07, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(panel)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 12)
	panel.add_child(rows)

	var title := Label.new()
	title.text = "Godot 赛车"
	title.add_theme_font_size_override("font_size", 40)
	rows.add_child(title)

	var sub := Label.new()
	sub.text = "选一个关卡，把极速调到你想玩的档位。W 油门 / S 刹车 / A D 转向 / 空格 手刹"
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	rows.add_child(sub)

	rows.add_child(HSeparator.new())

	_level_list = VBoxContainer.new()
	_level_list.add_theme_constant_override("separation", 8)
	rows.add_child(_level_list)

	rows.add_child(HSeparator.new())
	rows.add_child(_build_speed_row())
	rows.add_child(_build_ai_row())

	_hint = Label.new()
	_hint.text = "↑↓ 选择 · Enter 开始 · ESC 退出"
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", Color(0.7, 0.85, 0.95))
	rows.add_child(_hint)

	_build_level_buttons()


func _build_speed_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var label := Label.new()
	label.text = "极速"
	label.add_theme_font_size_override("font_size", 18)
	row.add_child(label)

	_speed_slider = HSlider.new()
	_speed_slider.min_value = GameState.MIN_SPEED
	_speed_slider.max_value = GameState.MAX_SPEED
	_speed_slider.step = 5.0
	_speed_slider.custom_minimum_size = Vector2(340, 28)
	_speed_slider.value = GameState.effective_speed()
	_speed_slider.value_changed.connect(_on_speed_changed)
	row.add_child(_speed_slider)

	_speed_value = Label.new()
	_speed_value.add_theme_font_size_override("font_size", 18)
	_speed_value.custom_minimum_size = Vector2(190, 0)
	row.add_child(_speed_value)
	_update_speed_label(_speed_slider.value)
	return row


## AI 对手开关。
## 为什么做成"开关"而不是让玩家填数量：关卡配置里的 ai_opponents 本身就是
## 难度设计的一部分（1→4 台随难度递进），玩家只需要决定"要不要陪跑"，
## 数量交给关卡，避免两个旋钮互相打架。
func _build_ai_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var label := Label.new()
	label.text = "AI 对手"
	label.add_theme_font_size_override("font_size", 18)
	row.add_child(label)

	_ai_button = Button.new()
	_ai_button.toggle_mode = true
	_ai_button.button_pressed = GameState.ai_enabled
	_ai_button.custom_minimum_size = Vector2(150, 34)
	_ai_button.toggled.connect(_on_ai_toggled)
	row.add_child(_ai_button)

	_ai_hint = Label.new()
	_ai_hint.add_theme_font_size_override("font_size", 15)
	_ai_hint.add_theme_color_override("font_color", Color(0.72, 0.86, 0.95))
	row.add_child(_ai_hint)
	_update_ai_labels()
	# 选关卡时刷新提示（每关对手数不同）
	for b in _level_list.get_children():
		if b is Button:
			b.focus_entered.connect(_on_level_focus_refresh_ai)
	return row


func _on_ai_toggled(on: bool) -> void:
	GameState.ai_enabled = on
	_update_ai_labels()
	print("[Menu] AI 对手已%s（各关卡对手数量作为上限，关掉则全部关卡都不生成）"
		% ("开启" if on else "关闭"))


func _on_level_focus_refresh_ai() -> void:
	_update_ai_labels()


func _update_ai_labels() -> void:
	if _ai_button != null:
		_ai_button.text = "开启" if GameState.ai_enabled else "关闭"
	if _ai_hint == null:
		return
	var n := GameState.level_ai_count()
	if not GameState.ai_enabled:
		# 明确告诉玩家"这关本来有几台、现在被你关了"，避免以为关卡没做对手
		_ai_hint.text = "已关闭（当前关卡本来有 %d 台）" % n if n > 0 else "已关闭"
	elif n == 0:
		_ai_hint.text = "本关本来就没有对手"
	else:
		_ai_hint.text = "本关 %d 台 · 小地图上是黄绿色圆环" % n


func _build_level_buttons() -> void:
	var n := GameState.level_count()
	if n == 0:
		var err := Label.new()
		err.text = "没有找到关卡配置（res://data/levels/*.tres）"
		err.add_theme_color_override("font_color", Color(1, 0.5, 0.4))
		_level_list.add_child(err)
		return
	for i in range(n):
		var cfg := GameState.get_level(i)
		if cfg == null:
			continue
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(620, 64)
		btn.text = "%d. %s　【%s】\n      %s" % [i + 1, cfg.display_name, cfg.difficulty, cfg.summary()]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 19)
		btn.focus_entered.connect(_on_level_focus.bind(i))
		btn.pressed.connect(_on_level_pressed.bind(i))
		_level_list.add_child(btn)
		_buttons.append(btn)


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.96)
	sb.border_color = Color(0.30, 0.34, 0.42)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 34
	sb.content_margin_right = 34
	sb.content_margin_top = 26
	sb.content_margin_bottom = 26
	return sb


func _on_speed_changed(v: float) -> void:
	GameState.max_speed_kmh = v
	GameState.speed_user_set = true
	_update_speed_label(v)


func _update_speed_label(v: float) -> void:
	_speed_value.text = "最高速度：%d km/h" % roundi(v)


func _on_level_focus(idx: int) -> void:
	GameState.chosen_level = idx
	var cfg := GameState.get_level(idx)
	if cfg == null:
		return
	_hint.text = "%s · %s · %s%s" % [
		cfg.weather_label(),
		"夜间" if cfg.is_night else "白天",
		cfg.blurb,
		"" if cfg.friction_multiplier >= 0.999 else "（抓地力 ×%.2f）" % cfg.friction_multiplier,
	]


func _on_level_pressed(idx: int) -> void:
	GameState.chosen_level = idx
	_enter_game()


func _enter_game() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()
