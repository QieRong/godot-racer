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

## 小地图源节点（Node3D：子节点有 SubViewport 和车点）
@export var minimap: Node3D

var _lap_start := 0.0
var _running := false
var _last_lap := 0.0
var _best_lap := 0.0
## 已按顺序通过的检查点集合，集齐才认为这一圈有效
var _passed := {}
## 小地图是否开启（M 键切换）
var _minimap_on := true
var _marker: Node3D = null
var _subviewport: SubViewport = null


func _ready() -> void:
	_lap_start = Time.get_ticks_msec() / 1000.0
	_running = true
	_refresh_labels()
	_setup_minimap()


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
	if _marker == null:
		push_warning("小地图里找不到 CarMarker，车点不会移动")


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
	# 小地图：相机固定不动，只把车点挪到车的水平位置。
	# 车点是 Minimap 在它自己的 _ready 里现搭的，可能比 HUD 晚一帧出现，
	# 所以这里惰性补一次查找，而不是只在 _ready 里找一次。
	if _minimap_on and _marker == null:
		_resolve_marker()
	if _minimap_on and _marker != null and car != null:
		_marker.global_position = Vector3(car.global_position.x, 4.0, car.global_position.z)


func _resolve_marker() -> void:
	if minimap == null:
		return
	_marker = minimap.get_node_or_null("CarMarker") as Node3D


## 连到每个 Checkpoint 的 car_passed 信号
func _on_car_passed(order_index: int, is_start_finish: bool) -> void:
	if not is_start_finish:
		# 普通检查点：登记一下
		_passed[order_index] = true
		if required_checkpoints > 0 and _passed.size() >= required_checkpoints:
			# 集齐了，等压线计圈
			pass
		return

	# 压到起终点线
	var now := Time.get_ticks_msec() / 1000.0
	var lap := now - _lap_start
	var enough_cp := _passed.size() >= required_checkpoints
	if lap >= min_lap_time and enough_cp:
		_last_lap = lap
		if _best_lap <= 0.0 or lap < _best_lap:
			_best_lap = lap
		_lap_start = now
		_passed.clear()
		_refresh_labels()
	elif lap < min_lap_time and _passed.is_empty():
		# 起步后第一次压线：把它当成计时起点，不计圈
		_lap_start = now


func _refresh_labels() -> void:
	_time_label.text = "本圈   --:--.---"
	_last_label.text = "上圈   %s" % _fmt(_last_lap)
	_best_label.text = "最快   %s" % _fmt(_best_lap)


func _fmt(t: float) -> String:
	if t <= 0.0:
		return "--:--.---"
	var m := int(t) / 60
	var s := int(t) % 60
	var ms := int(round((t - floor(t)) * 1000.0))
	return "%02d:%02d.%03d" % [m, s, ms]


## 想实时显示本圈用时就把 TimeLabel 的文本在 _process 里更新（可选）
func _update_current_lap_text() -> void:
	if _running:
		var now := Time.get_ticks_msec() / 1000.0
		_time_label.text = "本圈   %s" % _fmt(now - _lap_start)
