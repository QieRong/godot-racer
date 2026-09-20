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
