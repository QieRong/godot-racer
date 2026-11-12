extends CanvasLayer
## HUD：显示车速 + 圈速计时 + 总时间（R15）
##
## 用法：
##   1. 场景根下新建 CanvasLayer，挂本脚本
##   2. 车子的 vehicle.gd 所在节点赋给 car
@export var car: VehicleBody3D
## 需要依序通过的检查点数量（不含起终点）。设成 0 表示只要求压线即可计圈。
@export var required_checkpoints := 0
## 最短有效圈时（秒），防止刚起步反复压线刷圈
@export var min_lap_time := 10.0

@onready var _speed_label: Label = $SpeedLabel
@onready var _time_label: Label = $TimeLabel
@onready var _last_label: Label = $LastLabel
@onready var _best_label: Label = $BestLabel
# ==================== 「开反了」提示 ====================
#
# 玩家需求（2026-09 试玩反馈）：「方向如果是相反的话，就要提示用户开反了。
# **我们只能顺时针的开**」。
#
# 分工：**判定在别处，这里只负责显示**。
#   判定是 `track_layout.wrong_way_state()` 的纯状态机（阈值 + 迟滞，
#   由 `--check=layout` 第⑤组穷举断言），车辆每帧把结果写进 `car.wrong_way`。
#   HUD 只读那个 bool —— 所以"提示什么时候该亮"不在这里，改阈值不用碰本文件。
#
# 为什么在代码里建这个提示条，而不是往 main.tscn 里加节点：
#   与 ChaseCamera 的视角提示同一个做法（那边也是运行时建）。
#   好处是**不碰 main.tscn 的节点顺序**，
#   少一处会因为拖拽/重排而悄悄坏掉的地方。
# 字体必须显式指定系统字体：Godot 默认主题字体不含中文字形，直接用会全是方框。
var _wrong_way_label: Label = null
## 提示条外框（负责显隐；Label 只装文字）
var _wrong_way_panel: PanelContainer = null
## 圈数显示（"当前第几圈 / 共几圈"）。和「开反了」提示条同一个做法：**运行时建**。
## 为什么不往 main.tscn 里加节点：实测编辑器保存 .tscn 时会把手写注释整段吃掉
## （main.tscn 里那些注释记着出生点踩坑之类的结论，丢不起），uid 也会被重新生成。
var _lap_label: Label = null
## 总时间标签（R15：从「出发！」race_start_ms 起算到完赛的整场用时）。和圈数
## 标签同一个做法：**运行时建**，不碰 main.tscn。位置见 _build_total_label()。
var _total_label: Label = null
## 提示条的脉冲周期（秒）。规格：透明度 0.7~1.0 循环，周期 0.8 秒。
const WRONG_WAY_PULSE_PERIOD := 0.8

## 承载提示条的 CanvasLayer。
##
## 规格要求：`CanvasLayer` + `process_mode = ALWAYS`，保证**暂停时也能被正确隐藏**。
## 为什么必须这样：`process_mode = ALWAYS` 让它在 `get_tree().paused` 时照样收到
## `_physics_process`，所以我们才能在那里面读到"已暂停"并把提示条藏起来。
## 若用默认的 INHERIT/PAUSABLE，暂停后回调直接不再触发，提示会**僵在屏幕上**
## —— 玩家一按 ESC 就看见一条红色警告挂在那里，像是游戏卡死了。
var _wrong_way_layer: CanvasLayer = null
## 脉冲动画计时（秒）。规格：透明度 0.7~1.0 循环，周期 0.8 秒。
var _wrong_way_pulse := 0.0
var _speed_units: Label
var _last_lap := 0.0
var _best_lap := 0.0
## 已通过顺序登记的检查点（防抄近道用；计圈本身不依赖它）
const Ui := preload("res://scripts/ui_theme.gd")


func _ready() -> void:
	_refresh_labels()
	_build_wrong_way_label()
	_build_lap_label()
	_build_total_label()
	_style_timing_readout()
	get_viewport().size_changed.connect(_fit_hud)
	_fit_hud()
	# 圈速由车辆按"几何压线"判定后发信号，HUD 只负责显示
	if car != null and car.has_signal("lap_completed"):
		car.lap_completed.connect(_on_lap_completed)
	if car != null:
		_last_lap = float(car.get("lap_last"))
		_best_lap = float(car.get("lap_best"))
		_refresh_labels()


## 1366×705 参考布局；只更换呈现，所有计时仍读取原来的权威数据。
func _style_timing_readout() -> void:
	for label in [_speed_label, _time_label, _last_label, _best_label, _lap_label, _total_label]:
		label.add_theme_font_override("font", Ui.ui_font)
		label.add_theme_color_override("font_color", Ui.TEXT)
		label.add_theme_constant_override("outline_size", 0)
		label.add_theme_constant_override("shadow_offset_x", 0)
		label.add_theme_constant_override("shadow_offset_y", 0)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 原场景的公开标签仍是 HUD 的直接子节点，供原有查询和回归使用。
	move_child(Ui.panel(self, "TimingPanel", Rect2(24, 24, 260, 140), Ui.RACE_EDGE, Ui.RACE_SURFACE), 0)
	Ui.place(_lap_label, Rect2(40, 29, 228, 48))
	_lap_label.add_theme_font_size_override("font_size", 26)
	Ui.place(_total_label, Rect2(40, 82, 228, 30))
	_total_label.add_theme_font_size_override("font_size", 18)
	_total_label.add_theme_color_override("font_color", Ui.MUTED)
	Ui.place(_time_label, Rect2(40, 121, 228, 30))
	_time_label.add_theme_font_size_override("font_size", 18)
	_hud_line(Vector2(39, 78), Vector2(269, 78))
	_hud_line(Vector2(39, 117), Vector2(269, 117))
	# 次要圈速仍更新，但驾驶中只展示参考图的三行核心信息。
	_last_label.hide()
	_best_label.hide()
	move_child(Ui.panel(self, "SpeedPanel", Rect2(551, 603, 264, 74), Ui.RACE_EDGE, Ui.RACE_SURFACE), 0)
	var slash := Polygon2D.new()
	slash.name = "SpeedAccent"
	slash.polygon = PackedVector2Array([Vector2(570, 662), Vector2(576, 662), Vector2(593, 617), Vector2(587, 617)])
	slash.color = Ui.RED
	add_child(slash)
	_speed_label.add_theme_font_size_override("font_size", 57)
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_speed_units = Ui.label(self, "SpeedUnits", "km/h", 18, Ui.MUTED)
	_speed_units.add_theme_font_override("font", Ui.ui_font)
	_speed_units.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_set_speed_text("0")
	_hud_line(Vector2(592, 669), Vector2(797, 669))


func _set_speed_text(value: String) -> void:
	_speed_label.text = value
	var digits := _speed_label.get_minimum_size().x
	var units := _speed_units.get_minimum_size().x
	const GAP := 12.0
	var left := 683.0 - (digits + GAP + units) * 0.5
	Ui.place(_speed_label, Rect2(left, 599, digits, 69))
	Ui.place(_speed_units, Rect2(left + digits + GAP, 637, units, 28))


func _hud_line(start: Vector2, end: Vector2) -> void:
	var line := Line2D.new()
	line.points = PackedVector2Array([start, end])
	line.default_color = Ui.RACE_EDGE
	line.width = 1.0
	add_child(line)


func _fit_hud() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var factor := minf(viewport_size.x / Ui.BASE_SIZE.x, viewport_size.y / Ui.BASE_SIZE.y)
	transform = Transform2D(0.0, Vector2.ONE * factor, 0.0, (viewport_size - Ui.BASE_SIZE * factor) * 0.5)
	_wrong_way_layer.transform = transform


## 建「开反了」提示条（运行时建，不碰 main.tscn）。
##
## 位置：屏幕上方 1/4 处、水平居中 —— 玩家在追尾视角下视线正好落在这一带，
## 不用低头也能看见；也不会挡住下方的圈速。
## 暖色描边和文字区分普通读数，深色底板保证亮背景下可读。
func _build_wrong_way_label() -> void:
	var panel := PanelContainer.new()
	panel.name = "WrongWayPanel"
	var sb := Ui.box(Ui.RACE_SURFACE, Ui.WARNING, 2, 22)
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", sb)
	# 采用和计时、名次面板相同的参考画布，给长译文留出换行宽度。
	Ui.place(panel, Rect2(353, 128, 660, 0))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ⚠ 挂在**独立** CanvasLayer 上（而不是 HUD 自己那层），因为这一层要
	#   `process_mode = ALWAYS`：暂停时仍要收到回调才能把提示藏起来。
	#   CanvasLayer 的 layer 取 128（与 ChaseCamera 的视角提示同档）——
	#   确保它盖在 HUD 普通元素之上。
	_wrong_way_layer = CanvasLayer.new()
	_wrong_way_layer.name = "WrongWayLayer"
	_wrong_way_layer.layer = 128
	_wrong_way_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_wrong_way_layer)
	_wrong_way_layer.add_child(panel)
	_wrong_way_panel = panel

	_wrong_way_label = Label.new()
	_wrong_way_label.name = "WrongWayLabel"
	_wrong_way_label.text = "逆向行驶 · 请调整方向"
	_wrong_way_label.add_theme_font_override("font", Ui.ui_font)
	_wrong_way_label.add_theme_font_size_override("font_size", 30)
	_wrong_way_label.add_theme_color_override("font_color", Ui.WARNING)
	_wrong_way_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wrong_way_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_wrong_way_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_wrong_way_label)

	panel.visible = false
	print("[HUD] 「方向反了」提示条已就绪（判定来自 track_layout.wrong_way_state，本处只显示）")


## 运行时创建，保留节点契约，不改动主场景。
func _build_lap_label() -> void:
	_lap_label = Label.new()
	_lap_label.name = "LapLabel"
	_lap_label.text = tr("圈数   %d / %d") % [1, 1]
	add_child(_lap_label)


func _build_total_label() -> void:
	_total_label = Label.new()
	_total_label.name = "TotalTimeLabel"
	_total_label.text = tr("总时间   %s") % _fmt(0.0)
	add_child(_total_label)


## 把「开反了」判定同步到提示条。
##
## ⚠ 为什么要在 **_physics_process** 里同步，而不是只在 `_process`：
##   判定（`car.wrong_way`）是车辆在**物理帧**更新的，而 `_process` 跑在**渲染帧**。
##   两者不同步时，在阈值附近会出现"车上的判定已经是 true、屏幕上的提示还是 false"
##   一帧错位 —— 实测就是这么暴露的：验收里读到 `car.wrong_way=true 但 panel.visible=false`。
##   Godot 保证同一物理帧内的 `_physics_process` 之间状态一致，所以在这里同步最稳。
##   渲染帧那次调用留着无妨（幂等，且渲染帧可能比物理帧多）。
func _pass_wrong_way_to_view() -> void:
	if _wrong_way_panel == null or car == null:
		return
	# 暂停时**必须**不显示（规格明确要求）。
	# 这一条能生效，靠的是本节点 process_mode = ALWAYS（见 _wrong_way_layer 的说明）：
	# 默认模式下暂停后回调不再触发，提示会僵在屏幕上。
	if GameState.split_screen or get_tree().paused:
		_wrong_way_panel.visible = false
		return
	var ww = car.get("wrong_way")
	_wrong_way_panel.visible = ww != null and bool(ww)


## 提示条的脉冲动画：透明度 0.7~1.0 循环，周期 0.8 秒（规格要求"轻微脉冲"）。
##
## 为什么做脉冲而不是常亮：这是一条**纠错**提示，常亮久了会被眼睛过滤掉；
## 轻微呼吸能让余光一直注意到它，又不至于晃得没法看路。
## 用 `modulate.a` 而不是改主题色：只影响整体透明度，不动文字与底色。
func _pulse_wrong_way(delta: float) -> void:
	if _wrong_way_panel == null or not _wrong_way_panel.visible:
		# 不显示时把相位归零：下次亮起总是从"不透明"开始，
		# 否则可能正好从 0.7 的暗相位亮起，第一眼显得"没亮"。
		_wrong_way_pulse = 0.0
		return
	_wrong_way_pulse = fmod(_wrong_way_pulse + delta, WRONG_WAY_PULSE_PERIOD)
	# 余弦波映射到 [0.7, 1.0]：中点 0.85、幅度 0.15
	var phase := _wrong_way_pulse / WRONG_WAY_PULSE_PERIOD * TAU
	_wrong_way_panel.modulate.a = 0.85 + 0.15 * cos(phase)


func _physics_process(delta: float) -> void:
	_pass_wrong_way_to_view()
	_pulse_wrong_way(delta)


func _process(_delta: float) -> void:
	# 车速：把 m/s 换成 km/h
	if car:
		var kmh := car.linear_velocity.length() * 3.6
		var value := str(roundi(kmh))
		if value != _speed_label.text:
			_set_speed_text(value)
		# 本圈计时实时走动。原来只在压线时才刷新一次，所以"本圈"永远停在 --:--.---
		var network_finish: float = car.network_finish_time
		_time_label.text = tr("末圈   %s") % _fmt(car.lap_last) if network_finish > 0.0 else tr("本圈   %s") % _fmt(float(car.call("current_lap_time")))
		# 圈数：laps_done 是**已完成**的圈数，显示给玩家要 +1（正在跑的这一圈）；
		# laps_target = 0 表示不限圈数，以 ∞ 标明这一显示模式。
		if _lap_label != null:
			var _done := int(car.get("laps_done"))
			var _target := int(car.get("laps_target"))
			if network_finish > 0.0:
				_lap_label.text = tr("已完赛")
			elif _target > 0:
				_lap_label.text = tr("圈数   %d / %d") % [mini(_done + 1, _target), _target]
			else:
				_lap_label.text = tr("圈数   %d  /  ∞") % (_done + 1)
		# 总时间（R15）：GameState.race_total_time() 从 GO 瞬间的 race_start_ms
		# 起算。GO 前 race_start_ms = 0 → 返回 0 → 显示 --:--.---；倒计时期间
		# 树是暂停的、本 _process 不跑，标签就停在占位上；FINISHED 后树同样
		# 暂停，总时间定格在完赛一刻（计时停住，策划案 AC-07）。
		if _total_label != null:
			_total_label.text = tr("总时间   %s") % _fmt(network_finish if network_finish > 0.0 else GameState.race_total_time())
		# 「开反了」：只读判定结果，不在这里重算（阈值在 track_layout.wrong_way_state）。
		# `car` 是 VehicleBody3D 类型，`wrong_way` 是脚本变量 —— 用 get() 取，
		# 避免"变量在但类型推断不出"的解析告警（本项目踩过三次）。
		_pass_wrong_way_to_view()
## 车辆按几何压线判定完一圈后发的信号（圈速的唯一权威来源）
func _on_lap_completed(last_lap: float, best_lap: float) -> void:
	_last_lap = last_lap
	_best_lap = best_lap
	_refresh_labels()


func _refresh_labels() -> void:
	_last_label.text = tr("上圈   %s") % _fmt(_last_lap)
	_best_label.text = tr("最快   %s") % _fmt(_best_lap)


func _fmt(t: float) -> String:
	if t <= 0.0:
		return "--:--.---"
	# ⚠ 必须先归一到毫秒再拆位：若秒、毫秒分别 int/round，秒的小数落在
	#   [0.9995, 1.0) 时会 round 出 1000 毫秒，%03d 于是打出四位小数
	#   （00:41.1000）。先 round(t*1000) 再整除，进位自然带到秒/分。
	#   与 scripts/finish_menu.gd 的 _fmt 同口径（两处各留一份是刻意的，
	#   一致性由 tests/finish_results_test.gd 双向钉住）。
	var total_ms := int(round(t * 1000.0))
	var m := total_ms / 60000
	var s := (total_ms / 1000) % 60
	var ms := total_ms % 1000
	return "%02d:%02d.%03d" % [m, s, ms]
