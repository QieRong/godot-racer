extends CanvasLayer
## HUD：显示车速 + 圈速计时
##
## 用法：
##   1. 场景根下新建 CanvasLayer，挂本脚本
##   2. 车子的 vehicle.gd 所在节点赋给 car
##   3. 场景里所有 Checkpoint（Area3D）的 car_passed 信号连到本脚本的 _on_car_passed
##
## 场景树建议：
##   HUD (CanvasLayer + 本脚本)
##   ├── SpeedLabel   (Label)
##   ├── TimeLabel    (Label)
##   ├── LastLabel    (Label)
##   └── BestLabel    (Label)

@export var car: VehicleBody3D
## 需要依序通过的检查点数量（不含起终点）。设成 0 表示只要求压线即可计圈。
@export var required_checkpoints := 0
## 最短有效圈时（秒），防止刚起步反复压线刷圈
@export var min_lap_time := 10.0

@onready var _speed_label: Label = $SpeedLabel
@onready var _time_label: Label = $TimeLabel
@onready var _last_label: Label = $LastLabel
@onready var _best_label: Label = $BestLabel

var _lap_start := 0.0
var _running := false
var _last_lap := 0.0
var _best_lap := 0.0
## 已按顺序通过的检查点集合，集齐才认为这一圈有效
var _passed := {}


func _ready() -> void:
	_lap_start = Time.get_ticks_msec() / 1000.0
	_running = true
	_refresh_labels()


func _process(_delta: float) -> void:
	# 车速：把 m/s 换成 km/h
	if car:
		var kmh := car.linear_velocity.length() * 3.6
		_speed_label.text = "%d km/h" % roundi(kmh)


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
