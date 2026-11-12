extends Control
## 五关俯视图，路线和起终点使用正式赛道的数据。
const Ui := preload("res://scripts/ui_theme.gd")
const CARD_SIZE := Vector2(254, 132)
const OUTLINE := Color("111d2a")

const PALETTES := {
	"training": [Color("8fba78"), Color("18251c")],
	"sunny": [Color("f0f7ff"), Color("111d2a")],
	"rain": [Color("76c9df"), Color("101b2b")],
	"sand": [Color("dfbc87"), Color("2c2019")],
	"snow": [Color("c8e6f2"), Color("182935")]
}
var _route_color := Color.WHITE
var _panel_color := OUTLINE
var _track: Node3D
var _route := PackedVector2Array()
var _length_m := 0.0
var _player_arc := -1.0
var _car: Node3D
var _opponents: Array
var _map_center := Vector2.ZERO
var _map_scale := 1.0
var _start := Vector2.ZERO
var _start_forward := Vector2.RIGHT


func setup(track: Node3D, car: Node3D, opponents: Array) -> void:
	var key: String = preload("res://scripts/scenery_dressing.gd").theme_key(GameState.current_level())
	_route_color = PALETTES[key][0]
	_panel_color = PALETTES[key][1]
	_track = track
	_car = car
	_opponents = opponents
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2(1088, 130)
	size = CARD_SIZE
	var background := Polygon2D.new()
	background.polygon = PackedVector2Array([Vector2(12, 0), Vector2(CARD_SIZE.x, 0),
		Vector2(CARD_SIZE.x, CARD_SIZE.y - 12), Vector2(CARD_SIZE.x - 12, CARD_SIZE.y),
		Vector2(0, CARD_SIZE.y), Vector2(0, 12)])
	background.color = Color(_panel_color, 0.76)
	background.show_behind_parent = true
	add_child(background)
	var rim := Line2D.new()
	rim.points = background.polygon
	rim.closed = true
	rim.antialiased = true
	rim.width = 1.0
	rim.default_color = Color(Ui.BORDER, 0.65)
	background.add_child(rim)
	var accent := Line2D.new()
	accent.points = PackedVector2Array([Vector2(2, 10), Vector2(11, 1), Vector2(36, 1)])
	accent.width = 2.0
	accent.antialiased = true
	accent.default_color = _route_color
	background.add_child(accent)

	_length_m = track.road_length()
	var route := PackedVector2Array()
	for i in range(240):
		route.append(_flat(track.centerline_point(_length_m * float(i) / 240.0)))
	var bounds := Rect2(route[0], Vector2.ZERO)
	for point in route:
		bounds = bounds.expand(point)
	_map_center = bounds.get_center()
	_map_scale = minf(208.0 / maxf(bounds.size.x, 1.0), 94.0 / maxf(bounds.size.y, 1.0))
	for i in range(route.size()):
		route[i] = (route[i] - _map_center) * _map_scale + CARD_SIZE * 0.5
	_route = route
	for thickness in [7.0, 3.4]:
		var path := Line2D.new()
		path.points = route
		path.closed = true
		path.antialiased = true
		path.joint_mode = Line2D.LINE_JOINT_ROUND
		path.width = thickness
		path.default_color = OUTLINE if thickness > 4.0 else _route_color
		path.show_behind_parent = true
		add_child(path)
	_start = _project(track.start_line_center)
	_start_forward = _flat(track.start_line_forward).normalized()


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if _car == null:
		return
	draw_set_transform(_start, _start_forward.angle())
	draw_rect(Rect2(-4, -10, 8, 20), OUTLINE)
	for row in range(6):
		for column in range(2):
			draw_rect(Rect2(column * 3 - 3, row * 3 - 9, 3, 3),
				Color.WHITE if (row + column) % 2 == 0 else OUTLINE)
	draw_set_transform(Vector2.ZERO)

	var nearest: Dictionary = _track.nearest_on_centerline(_car.global_position, _player_arc)
	_player_arc = float(nearest["arc"])
	var player_pos := _route_point(_player_arc)
	for opponent in _opponents:
		if not is_instance_valid(opponent):
			continue
		var arc: float = opponent.progress() if opponent.has_method("progress") else float(_track.nearest_on_centerline(opponent.global_position, -1.0).arc)
		var point := _route_point(arc)
		# 标记共用赛道中心线，齐头时用外环保留 AI 的辨识度。
		if point.distance_to(player_pos) < 12.0:
			draw_arc(point, 7.0, 0.0, TAU, 24, OUTLINE, 3.0, true)
			draw_arc(point, 7.0, 0.0, TAU, 24, Ui.SKY, 1.6, true)
		else:
			draw_circle(point, 5.0, OUTLINE, true, -1.0, true)
			draw_circle(point, 3.9, Ui.SKY, true, -1.0, true)
	draw_set_transform(player_pos, _flat(-_car.global_basis.z).angle())
	var arrow := PackedVector2Array([Vector2(8, 0), Vector2(-5, 5), Vector2(-3, 0), Vector2(-5, -5)])
	draw_colored_polygon(arrow, Ui.RED)
	arrow.append(arrow[0])
	draw_polyline(arrow, Color.WHITE, 1.2, true)
	draw_set_transform(Vector2.ZERO)


func _route_point(arc: float) -> Vector2:
	# 按已绘制折线插值，弯道上也与白线精确重合。
	var index := fposmod(arc, _length_m) / _length_m * _route.size()
	var segment := floori(index) % _route.size()
	return _route[segment].lerp(_route[(segment + 1) % _route.size()], index - floorf(index))


func _project(pos: Vector3) -> Vector2:
	return (_flat(pos) - _map_center) * _map_scale + CARD_SIZE * 0.5


func _flat(pos: Vector3) -> Vector2:
	return Vector2(pos.x, pos.z)

