extends StyleBox
## 脚本StyleBox绘制切角；保留UI辅助代码实际使用的颜色/边距接口。
@export var bg_color := Color.TRANSPARENT
@export var border_color := Color.WHITE
var border_width := 1.0
var expand_margin := 0.0
func set_border_width_all(width: float) -> void:
	border_width = width
func set_expand_margin_all(value: float) -> void:
	expand_margin = value
func _draw(item: RID, area: Rect2) -> void:
	area = area.grow(expand_margin)
	var a := area.position
	var b := area.end
	var cut := minf(12.0, minf(area.size.x, area.size.y) * 0.22)
	var points := PackedVector2Array([Vector2(a.x+cut,a.y), Vector2(b.x-cut,a.y),
		Vector2(b.x,a.y+cut), Vector2(b.x,b.y-cut), Vector2(b.x-cut,b.y),
		Vector2(a.x+cut,b.y), Vector2(a.x,b.y-cut), Vector2(a.x,a.y+cut)])
	RenderingServer.canvas_item_add_polygon(item, points, PackedColorArray([bg_color]))
	points.append(points[0])
	if border_width > 0.0:
		RenderingServer.canvas_item_add_polyline(item, points, PackedColorArray([border_color]), border_width, true)
