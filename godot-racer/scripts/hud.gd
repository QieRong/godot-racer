extends CanvasLayer
## HUD：显示车速 + 圈速计时 + 右上角实时小地图
##
## 用法：
##   1. 场景根下新建 CanvasLayer，挂本脚本
##   2. 车子的 vehicle.gd 所在节点赋给 car
##   3. 场景里所有 Checkpoint（Area3D）的 car_passed 信号连到本脚本的 _on_car_passed
##   4. 把 Minimap（Node3D 容器：SubViewport + 正交俯视相机 + 车点）赋给 minimap
##
## 小地图的实现取舍（为什么用 SubViewport 而不是自绘 2D 图）：
##   - 直接复用现有 3D 场景，路面形状**永远**和真实赛道一致，改赛道不用同步改 2D 图；
##   - 相机用 `cull_mask` 只留"世界 + 小地图标记"两层，装饰物（树、帐篷）不进渲染；
##   - 相机**固定**包住整条赛道、不跟随车（用户要求）：地图不动、只有车点在动，
##     这样读图时"赛道轮廓"是稳定的参照系，不会晕。
##   代价是每帧多渲一遍场景，所以留了开关（M 键 / --minimap=off），关掉即零开销。

@export var car: VehicleBody3D
## 需要依序通过的检查点数量（不含起终点）。设成 0 表示只要求压线即可计圈。
@export var required_checkpoints := 0
## 最短有效圈时（秒），防止刚起步反复压线刷圈
@export var min_lap_time := 10.0

@onready var _speed_label: Label = $SpeedLabel
@onready var _time_label: Label = $TimeLabel
@onready var _last_label: Label = $LastLabel
@onready var _best_label: Label = $BestLabel
@onready var _minimap_panel: Control = get_node_or_null("MinimapPanel")
@onready var _minimap_rect: TextureRect = get_node_or_null("MinimapPanel/MinimapRect")
@onready var _minimap_title: Label = get_node_or_null("MinimapPanel/MinimapTitle")

## 小地图源节点（Node3D：子节点有 SubViewport 和车点）
@export var minimap: Node3D

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
#   好处是**不碰 main.tscn 的节点顺序**（那份顺序有讲究：Minimap 必须排在 HUD 前），
#   少一处会因为拖拽/重排而悄悄坏掉的地方。
# 字体必须显式指定系统字体：Godot 默认主题字体不含中文字形，直接用会全是方框。
var _wrong_way_label: Label = null
## 提示条外框（负责显隐；Label 只装文字）
var _wrong_way_panel: PanelContainer = null
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
var _last_lap := 0.0
var _best_lap := 0.0
## 已通过顺序登记的检查点（防抄近道用；计圈本身不依赖它）
var _passed := {}
## 小地图是否开启（M 键切换）
var _minimap_on := true
## AI 对手的父节点（惰性查找，生成时机晚于 HUD）
var _opponents_root: Node3D = null
## 障碍物场的父节点（可为空：没有障碍的关卡）
var _obstacles_root: Node3D = null
## 图例要同时反映对手数和障碍数，所以各自记一份最近的值
var _last_opponent_count := 0
var _last_obstacle_count := 0
var _marker: Node3D = null
var _subviewport: SubViewport = null


func _ready() -> void:
	_refresh_labels()
	_setup_minimap()
	_build_wrong_way_label()
	# 圈速由车辆按"几何压线"判定后发信号，HUD 只负责显示
	if car != null and car.has_signal("lap_completed"):
		car.lap_completed.connect(_on_lap_completed)
	if car != null:
		_last_lap = float(car.get("lap_last"))
		_best_lap = float(car.get("lap_best"))
		_refresh_labels()


## 取小地图里的车点与 SubViewport，并按命令行参数决定是否一开始就开着。
func _setup_minimap() -> void:
	if minimap == null:
		push_warning("HUD 没有指定 minimap 节点，小地图不启用")
		return
	_marker = minimap.get_node_or_null("CarMarker") as Node3D
	_subviewport = minimap.get_node_or_null("SubViewport") as SubViewport
	# SubViewport 的纹理在 .tscn 里用 ViewportTexture 引用会绕，这里直接代码接上
	if _subviewport != null and _minimap_rect != null:
		_minimap_rect.texture = _subviewport.get_texture()
	# 命令行：--minimap=off 关掉（省一遍场景渲染）
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--minimap="):
			_minimap_on = a.split("=", true, 1)[1] != "off"
	_apply_minimap_visibility()
	# 先按"没有对手"写图例；等 Opponents 节点出现后 _update_opponent_dots 会修正
	_update_minimap_legend(0)
	# 车点是 minimap.gd 异步搭出来的，这里找不到很正常（它会在 _process 里惰性补上），
	# 所以不要在这里喊 warning 刷日志。
	if _marker == null:
		print("[HUD] 小地图车点稍后就绪（等 minimap 搭完地图内容）")


## 建「开反了」提示条（运行时建，不碰 main.tscn）。
##
## 位置：屏幕上方 1/4 处、水平居中 —— 玩家在追尾视角下视线正好落在这一带，
## 不用低头也能看见；也不会挡住下方的小地图与圈速。
## 样式刻意做得"刺眼"（红底白字 + 黑描边 + 大字号）：这是一条**纠错**提示，
## 出现时玩家正在做错事，必须一眼看见，不能像普通信息那样低调。
func _build_wrong_way_label() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "sans-serif"])

	var panel := PanelContainer.new()
	panel.name = "WrongWayPanel"	# 红底：用 StyleBoxFlat 现做一个，避免依赖主题里有没有合适的样式
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.78, 0.10, 0.08, 0.88)
	sb.border_color = Color(1.0, 0.85, 0.2, 0.95)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 22.0
	sb.content_margin_right = 22.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", sb)
	# 锚到"上方靠中"：0.5 横向居中、0.22 纵向（约屏幕上方 1/4 处）
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.22
	panel.anchor_bottom = 0.22
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
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
	_wrong_way_label.text = "⚠ 方向反了，请调头"
	_wrong_way_label.add_theme_font_override("font", font)
	# 字号 40：车速数字是 46（main.tscn 的 SpeedLabel），规格要求"不小于它的 80%"
	# ——40/46 = 87%，留了余量（车速数字将来调大也不至于立刻违反）。
	_wrong_way_label.add_theme_font_size_override("font_size", 40)
	_wrong_way_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_wrong_way_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_wrong_way_label.add_theme_constant_override("outline_size", 6)
	_wrong_way_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wrong_way_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_wrong_way_label)

	panel.visible = false
	print("[HUD] 「方向反了」提示条已就绪（判定来自 track_layout.wrong_way_state，本处只显示）")


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
	if get_tree().paused:
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


func _apply_minimap_visibility() -> void:
	if _minimap_panel != null:
		_minimap_panel.visible = _minimap_on
	if _subviewport != null:
		# 关掉时停更：不再重复渲染整条赛道
		_subviewport.render_target_update_mode = \
			SubViewport.UPDATE_ALWAYS if _minimap_on else SubViewport.UPDATE_DISABLED
	if _marker != null:
		_marker.visible = _minimap_on


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_minimap"):
		_minimap_on = not _minimap_on
		_apply_minimap_visibility()
		print("[HUD] 小地图 %s" % ("开启" if _minimap_on else "关闭"))


func _process(_delta: float) -> void:
	# 车速：把 m/s 换成 km/h
	if car:
		var kmh := car.linear_velocity.length() * 3.6
		_speed_label.text = "%d km/h" % roundi(kmh)
		# 本圈计时实时走动。原来只在压线时才刷新一次，所以"本圈"永远停在 --:--.---
		_time_label.text = "本圈   %s" % _fmt(float(car.call("current_lap_time")))
		# 「开反了」：只读判定结果，不在这里重算（阈值在 track_layout.wrong_way_state）。
		# `car` 是 VehicleBody3D 类型，`wrong_way` 是脚本变量 —— 用 get() 取，
		# 避免"变量在但类型推断不出"的解析告警（本项目踩过三次）。
		_pass_wrong_way_to_view()
	# 小地图：相机固定不动，只把车点挪到车的水平位置。
	# 车点是 Minimap 在它自己的 _ready 里现搭的，可能比 HUD 晚一帧出现，
	# 所以这里惰性补一次查找，而不是只在 _ready 里找一次。
	if _minimap_on and _marker == null:
		_resolve_marker()
	if _minimap_on and _marker != null and car != null:
		_marker.global_position = Vector3(car.global_position.x, 4.0, car.global_position.z)
	# AI 对手点：同样每帧挪位置（相机是固定的，所以只有点动）
	if _minimap_on:
		_update_opponent_dots()
		_update_obstacle_dots()


## 把障碍物画到小地图上。动态路障每帧都在滑动，所以必须逐帧刷新位置。
## 数据来自 obstacle_field.gd 的 marker_positions()（它知道哪些障碍在动）。
func _update_obstacle_dots() -> void:
	if minimap == null or car == null:
		return
	if _obstacles_root == null:
		_obstacles_root = car.get_parent().get_node_or_null("Obstacles") as Node3D
		if _obstacles_root == null:
			return
	var positions: Array = _obstacles_root.call("marker_positions")
	var markers: Array = minimap.get("obstacle_markers")
	if markers == null:
		return
	if markers.size() != positions.size():
		minimap.call("build_obstacle_markers", positions.size())
		markers = minimap.get("obstacle_markers")
		_update_minimap_legend(_last_opponent_count, positions.size())
	for i in range(mini(positions.size(), markers.size())):
		var m = markers[i]
		if m == null or not is_instance_valid(m):
			continue
		var p: Vector3 = (positions[i] as Dictionary)["pos"]
		m.global_position = Vector3(p.x, 4.5, p.z)


## 把 AI 对手画到小地图上。
## 对手由 main.gd 生成在 "Opponents" 节点下，数量来自关卡配置的 ai_opponents，
## 所以点的数量不能写死 —— 这里按实际子节点数惰性补齐/重建。
func _update_opponent_dots() -> void:
	if minimap == null or car == null:
		return
	if _opponents_root == null:
		_opponents_root = car.get_parent().get_node_or_null("Opponents") as Node3D
	var live: Array = []
	if _opponents_root != null:
		for c in _opponents_root.get_children():
			if c is Node3D and is_instance_valid(c):
				live.append(c)
	var markers: Array = minimap.get("opponent_markers")
	if markers == null:
		return
	if markers.size() != live.size():
		minimap.call("build_opponent_markers", live.size())
		markers = minimap.get("opponent_markers")
		_last_opponent_count = live.size()
		_update_minimap_legend(_last_opponent_count, _last_obstacle_count)
	for i in range(mini(live.size(), markers.size())):
		var m = markers[i]
		if m == null or not is_instance_valid(m):
			continue
		var o := live[i] as Node3D
		m.global_position = Vector3(o.global_position.x, 4.0, o.global_position.z)


## 小地图图例：把"什么形状是什么"直接写在标题下面。
## 加图例是因为光靠颜色区分不够稳 —— 小地图很小，玩家一眼扫过去分不清
## 青色方块（检查点）和黄绿圆环（对手）到底哪个是哪个。
func _update_minimap_legend(opponent_count: int, obstacle_count := 0) -> void:
	_last_opponent_count = opponent_count
	_last_obstacle_count = obstacle_count
	if _minimap_title == null:
		return
	# 图例文字必须够短：面板宽度有限，写全"■检查点 ●你 ◎对手×1 □障碍×8 · M 隐藏"
	# 会直接溢出面板被裁掉（实测"M 隐藏"被切了一半）。所以只留形状+名称，
	# 不带数量 —— 数量在小地图上一眼就能数出来，不值得为它牺牲可读性。
	var parts := PackedStringArray(["■检查点", "●你"])
	if opponent_count > 0:
		parts.append("◎对手")
	if obstacle_count > 0:
		parts.append("□障碍")
	parts.append("M隐藏")
	_minimap_title.text = " ".join(parts)


## 取小地图里的车点。小地图内容是**异步**生成的（它要等赛道就绪），
## 所以不能在 _ready 里只找一次 —— 那样会一直 warning"找不到 CarMarker"、
## 车点永远不动。这里在 _process 里惰性重试，直到找到为止。
func _resolve_marker() -> void:
	if minimap == null:
		return
	_marker = minimap.get_node_or_null("CarMarker") as Node3D
	if _marker != null:
		print("[HUD] 已接上小地图车点")


## 车辆按几何压线判定完一圈后发的信号（圈速的唯一权威来源）
func _on_lap_completed(last_lap: float, best_lap: float) -> void:
	_last_lap = last_lap
	_best_lap = best_lap
	_passed.clear()
	_refresh_labels()


## 普通检查点信号：只用来登记"这一圈经过哪些点"（防止抄近道）。
## **计圈不再依赖它** —— 实测 Area3D 信号会漏检/误触发，导致"上圈和最快圈
## 显示同一个时间、本圈压根不计时"。计圈改由车辆按起终点平面穿越判定。
func _on_car_passed(order_index: int, is_start_finish: bool) -> void:
	if is_start_finish:
		return
	_passed[order_index] = true


func _refresh_labels() -> void:
	_last_label.text = "上圈   %s" % _fmt(_last_lap)
	_best_label.text = "最快   %s" % _fmt(_best_lap)


func _fmt(t: float) -> String:
	if t <= 0.0:
		return "--:--.---"
	var m := int(t) / 60
	var s := int(t) % 60
	var ms := int(round((t - floor(t)) * 1000.0))
	return "%02d:%02d.%03d" % [m, s, ms]
