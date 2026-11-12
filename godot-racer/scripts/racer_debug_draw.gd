extends Node
## 只读开发叠层：不写入车辆、AI 或赛道状态；发行版不挂载。

var track: Node3D
var cars: Array
var shown := false
var _draw: Object

func setup(p_track: Node3D, p_cars: Array) -> void:
	track = p_track
	cars = p_cars

func _ready() -> void:
	if not Engine.has_singleton("DebugDraw3D"):
		push_warning("Debug Draw 3D 未加载，F3 可视化不可用")
		set_process(false)
		set_process_unhandled_input(false)
		return
	_draw = Engine.get_singleton("DebugDraw3D")
	print("[开发工具] F3：中心线/速度方向/接地轮；L2 F4：Phantom Camera 对照")

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("racer_debug_draw") and not event.is_echo():
		shown = not shown
		if not shown:
			_draw.clear_all()
		print("[Debug Draw 3D] ", "显示" if shown else "隐藏")
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if not shown or GameState.split_screen:
		return
	var _scope: RefCounted = _draw.new_scoped_config().set_thickness(0.06)
	for car: VehicleBody3D in cars:
		var origin := car.global_position + Vector3.UP * 0.6
		var color := Color.ORANGE if car == cars[0] else Color.GREEN
		_draw.draw_sphere(origin, 0.35, color)
		_draw.draw_arrow(origin, origin + car.linear_velocity * 0.5, color)
		var near: Dictionary = track.nearest_on_centerline(car.global_position, -1.0)
		var arc: float = near.arc
		var path := PackedVector3Array()
		for step in range(17):
			path.append(track.centerline_point(arc + step * 2.0) + Vector3.UP * 0.15)
		_draw.draw_line_path(path, Color.CYAN)
		_draw.draw_line(origin, Vector3(near.pos) + Vector3.UP * 0.15, Color.YELLOW)
		for child in car.get_children():
			if child is VehicleWheel3D and child.is_in_contact():
				_draw.draw_sphere(child.global_position, 0.12, Color.GREEN)
