extends Node3D
## 右上角实时小地图的数据源。
##
## 为什么不用"给小地图单独开一个 World3D"：
##   实测 Godot 4.4.1 里 SubViewport.own_world_3d 运行时拿到的 world_3d 是空的，
##   手动 `vp.world_3d = World3D.new()` 虽然能生效，但会让渲染器报
##   `Parameter "scenario" is null`，主视角直接花掉（天空变橙、车看不见、屏幕一大块黑）。
##   所以改用用户建议的方案：**共用主世界 + cull_mask 分层**。
##
## 分层方案：
##   - 小地图自己的东西（底板/路面环/起终点/检查点/车点）统统放到 MAP_LAYER（第 17 层）；
##   - 主世界里的草地地面也挪到 GROUND_LAYER（第 18 层），否则小地图里是一片草地、
##     路面和背景分不开（这是这次唯一需要动主场景的地方）；
##   - 小地图相机只渲染 GROUND_LAYER（不要）→ 实际只渲染 MAP_LAYER；
##     主相机把 MAP_LAYER 剔掉，所以主视角永远看不到小地图元素。
##
## 相机**固定**在赛道中心正上方、不跟随车（用户要求）：地图不动、只有车点在动。

## 小地图专用层（第 17 层，值 1<<16）
const MAP_LAYER := 1 << 16
## 主世界的草地地面层（第 18 层，值 1<<17），小地图不渲染它
const GROUND_LAYER := 1 << 17
## 路面环颜色
const ROAD_COLOR := Color(0.58, 0.61, 0.68)
## 底板颜色
const BOARD_COLOR := Color(0.10, 0.12, 0.15)
## 起终点白杠
const START_COLOR := Color(0.98, 0.99, 1.0)
## 检查点方块
const CHECKPOINT_COLOR := Color(0.25, 0.85, 0.95)
## 车点
const CAR_COLOR := Color(1.0, 0.35, 0.15)
## 路面环采样段数
const RING_SEGMENTS := 256
## 地图离地抬高，避免与底板 z-fighting
const MAP_LIFT := 1.0

var _car: Node3D = null
## 车点（HUD 每帧更新它的位置）
var car_marker: Node3D = null
var _track: Node3D = null


func _ready() -> void:
	_configure_cameras()
	_build_content()


## 地图内容必须在**赛道生成之后**才能搭（要读中心线）。
## 赛道是延迟构建的（见 track_generator 的顺序说明），所以这里 await。
func _build_content() -> void:
	await get_tree().process_frame
	_track = get_parent().get_node_or_null("Track") as Node3D
	_car = get_parent().get_node_or_null("RaceCar") as Node3D
	if _track != null and _track.has_method("await_world_ready"):
		await _track.call("await_world_ready")
	if _track == null or not _track.has_method("road_length"):
		push_warning("Minimap 找不到可用的赛道数据，小地图只显示底板")
		return
	if _track.call("road_length") == null or float(_track.call("road_length")) < 1.0:
		push_warning("Minimap 赛道数据还没就绪，跳过地图内容")
		return
	_build_board()
	_build_ring()
	_build_start_line()
	_build_checkpoints()
	if _car != null:
		_build_car_marker()
	print("[Minimap] 地图内容已生成（路面环 + 起终点 + 检查点 + 车点）")


## 相机分层：
##   小地图相机 → 只渲染地图层；
##   主相机 → 剔掉地图层（否则会在主视角里看到底板/车点）。
func _configure_cameras() -> void:
	var vp := get_node_or_null("SubViewport") as SubViewport
	if vp != null:
		var cam := vp.get_node_or_null("TopCam") as Camera3D
		if cam != null:
			# 只渲染地图层：主世界里的草地/护栏都不进小地图，
			# 地图由本脚本自己搭的深色底板 + 路面环组成。
			cam.cull_mask = MAP_LAYER
			cam.environment = _map_environment()
	var chase := get_parent().get_node_or_null("ChaseCamera") as Camera3D
	if chase != null:
		chase.cull_mask = chase.cull_mask & ~MAP_LAYER


## 小地图相机专用的环境（深色背景，不参与主视角）
func _map_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 1.0
	return env


## 底板：一块比赛道包络大一圈的深色方块
func _build_board() -> void:
	var extent := _track_extent() + 60.0
	var mesh := BoxMesh.new()
	mesh.size = Vector3(extent * 2.0, 1.0, extent * 2.0)
	var body := MeshInstance3D.new()
	body.name = "Board"
	body.mesh = mesh
	body.position = Vector3(0.0, -1.0, 0.0)
	body.layers = MAP_LAYER
	body.material_override = _flat(BOARD_COLOR)
	add_child(body)


## 路面环：沿中心线扫一圈条带（只有一个 mesh，开销可忽略）
func _build_ring() -> void:
	var total := float(_track.call("road_length"))
	var half := float(_track.call("road_half_width"))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts: Array[Vector3] = []
	for i in range(RING_SEGMENTS):
		pts.append(Vector3(_track.call("centerline_point", float(i) / float(RING_SEGMENTS) * total)))
	for i in range(RING_SEGMENTS):
		var p0 := pts[i]
		var p1 := pts[(i + 1) % RING_SEGMENTS]
		var fwd := (p1 - p0)
		fwd.y = 0.0
		if fwd.length() < 0.0001:
			continue
		fwd = fwd.normalized()
		var side := Vector3(fwd.z, 0.0, -fwd.x).normalized() * half
		# 顶点顺序保证法线朝上（相机在正上方）
		_add_tri(st, p0 + side, p1 + side, p0 - side)
		_add_tri(st, p0 + side, p1 - side, p1 + side)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "RoadRing"
	mi.mesh = st.commit()
	mi.position = Vector3(0.0, MAP_LIFT, 0.0)
	mi.layers = MAP_LAYER
	mi.material_override = _flat(ROAD_COLOR)
	add_child(mi)


## 起终点：横跨路面的一道白杠
func _build_start_line() -> void:
	var half := float(_track.call("road_half_width"))
	for node in get_tree().get_nodes_in_group("checkpoints"):
		var cp := node as Node3D
		if cp == null or not bool(cp.get("is_start_finish")):
			continue
		var p := Vector3(_track.call("centerline_point", 0.0))
		var fwd := Vector3(_track.call("centerline_forward", 0.0))
		var mesh := BoxMesh.new()
		mesh.size = Vector3(half * 2.0, 1.0, 8.0)
		var bar := MeshInstance3D.new()
		bar.name = "StartLine"
		bar.mesh = mesh
		bar.position = p + Vector3.UP * MAP_LIFT
		bar.rotation.y = atan2(fwd.x, fwd.z)
		bar.layers = MAP_LAYER
		bar.material_override = _flat(START_COLOR)
		add_child(bar)
		return


## 检查点：每处一个小方块（青色）
func _build_checkpoints() -> void:
	for node in get_tree().get_nodes_in_group("checkpoints"):
		var cp := node as Node3D
		if cp == null or bool(cp.get("is_start_finish")):
			continue
		var mesh := BoxMesh.new()
		mesh.size = Vector3(14.0, 1.0, 14.0)
		var dot := MeshInstance3D.new()
		dot.name = "Cp%d" % int(cp.get("order_index"))
		dot.mesh = mesh
		dot.position = Vector3(cp.global_position.x, MAP_LIFT, cp.global_position.z)
		dot.layers = MAP_LAYER
		dot.material_override = _flat(CHECKPOINT_COLOR)
		add_child(dot)


## 车点：一个显眼的橙红色圆盘，由 HUD 每帧挪到车的水平位置
func _build_car_marker() -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = 9.0
	mesh.bottom_radius = 9.0
	mesh.height = 2.0
	var mi := MeshInstance3D.new()
	mi.name = "CarMarker"
	mi.mesh = mesh
	mi.position = Vector3(_car.global_position.x, MAP_LIFT + 3.0, _car.global_position.z)
	mi.layers = MAP_LAYER
	mi.material_override = _flat(CAR_COLOR)
	add_child(mi)
	car_marker = mi


func _track_extent() -> float:
	var max_extent := 0.0
	var total := float(_track.call("road_length"))
	for i in range(72):
		var p := Vector3(_track.call("centerline_point", float(i) / 72.0 * total))
		max_extent = maxf(max_extent, maxf(absf(p.x), absf(p.z)))
	return max_extent


## 小地图统一用"无光照"材质：不参与光照计算，颜色稳定，也省一点渲染
func _flat(c: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = c
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_normal(Vector3.UP)
	st.add_vertex(a)
	st.set_normal(Vector3.UP)
	st.add_vertex(b)
	st.set_normal(Vector3.UP)
	st.add_vertex(c)
