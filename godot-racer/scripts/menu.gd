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
