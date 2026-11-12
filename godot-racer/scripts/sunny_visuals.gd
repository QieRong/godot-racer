extends Node3D
## L2开阔竞速场：低矮维修区与白砂/青蓝赛事设施，仅生成合批视觉。
const Dressing := preload("res://scripts/scenery_dressing.gd")
const PADDOCK_TENTS := preload("res://assets/l2_sample/kenney/paddock-tents.glb")
const SERVICE_TRUCK := preload("res://assets/l2_sample/kenney/service-truck.glb")
const GANTRY_DETAIL := preload("res://assets/l2_sample/gantry_detail.glb")
const COLORS := [Color("b9b49b"), Color("214b57"), Color("cb713b"),
	Color("3d484b"), Color("23333d"), Color("d6cfb3")]
var _boxes: Array = [[], [], [], [], [], []]
var _footprints: Array[Vector4] = []

func build(track: Node3D, reserved: Array[Vector4] = []) -> Array[Vector4]:
	_footprints.assign(reserved)
	var start: float = track.start_finish_t * track.road_length()
	# 单侧赛事中心，另一侧留出草地和长直道视野，不复制L1的林地棚屋。
	for site in [[205.0, 1.0], [270.0, 1.0]]:
		var frame := _frame(track, start + float(site[0]), float(site[1]) * (track.rail_half_width() + 33.0))
		if not _site_clear(track, frame.origin, 28.0): continue
		_footprints.append(Vector4(frame.origin.x, frame.origin.y, frame.origin.z, 28.0))
		_pit_building(frame)
	var tower := _frame(track, start + 1.0, track.rail_half_width() + 25.0)
	if _site_clear(track, tower.origin, 8.0):
		_footprints.append(Vector4(tower.origin.x, tower.origin.y, tower.origin.z, 8.0))
		_box(tower, Vector3(0, 4.5, 0), Vector3(7, 9, 9), 0)
		_box(tower, Vector3(0, 8.0, 0), Vector3(8, 2.5, 10), 4)
		_box(tower, Vector3(0, 9.45, 0), Vector3(10, 0.4, 12), 1)
		_box(tower, Vector3(0, 6.6, 0), Vector3(8.2, 0.4, 10.2), 2)
	# 轻薄的白砂色横梁与青蓝信号板，区别于L1的深色训练营门架。
	var gate := _frame(track, start + 22.0, 0.0)
	var span: float = track.rail_half_width() + 4.0
	for side in [-1.0, 1.0]:
		var post := _frame(track, start + 22.0, side * span)
		_box(post, Vector3(0, 4.1, 0), Vector3(0.55, 8.2, 0.9), 0)
		_box(post, Vector3(0, 2.0, 0), Vector3(0.65, 1.3, 1.0), 2)
		_footprints.append(Vector4(post.origin.x, post.origin.y, post.origin.z, 1.5))
	_box(gate, Vector3(0, 8.2, 0), Vector3(span * 2.0 + 1.0, 0.45, 1.2), 5)
	_box(gate, Vector3(0, 7.35, 0), Vector3(15.0, 1.2, 0.4), 1)
	var label := Label3D.new()
	label.text = "SUNNY CIRCUIT"
	label.font_size = 80
	label.pixel_size = 0.012
	label.outline_size = 0
	label.modulate = Color("f3e9ca")
	label.transform = gate * Transform3D(Basis(Vector3.UP, PI), Vector3(0, 7.35, -0.25))
	add_child(label)
	var gantry_detail := GANTRY_DETAIL.instantiate() as Node3D
	gantry_detail.name = "GantryDetail"
	gantry_detail.transform = gate.scaled_local(Vector3(span * 2.0 / 26.4, 1.0, 1.0))
	add_child(gantry_detail)
	# 起跑区与首弯前各留一组赛事设施，其间保持长直道视野开阔。
	_place_paddock_prop(track, PADDOCK_TENTS, "GridTeamTents", start + 42.0, 18.0, 7.2, 1.0)
	_place_paddock_prop(track, SERVICE_TRUCK, "GridServiceTruck", start + 57.0, 14.0, 2.8, 1.65)
	_place_paddock_prop(track, PADDOCK_TENTS, "TurnOneMarshalTents", start + 288.0, 22.0, 7.2, 1.0)
	for i in range(COLORS.size()):
		if _boxes[i].is_empty(): continue
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.mesh = mesh
		multi.instance_count = _boxes[i].size()
		for j in range(_boxes[i].size()): multi.set_instance_transform(j, _boxes[i][j])
		var material := StandardMaterial3D.new()
		material.albedo_color = COLORS[i]
		material.roughness = 1.0
		material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		var batch := MultiMeshInstance3D.new()
		batch.name = "SunnyFacilities_%d" % i
		batch.multimesh = multi
		batch.material_override = material
		batch.visibility_range_end = 600.0
		add_child(batch)
	set_meta("facility_sites", _footprints.size())
	return _footprints

func _place_paddock_prop(track: Node3D, asset: PackedScene, node_name: String,
		arc: float, shoulder_offset: float, radius: float, scale_factor: float) -> void:
	var lateral: float = -track.rail_half_width() - shoulder_offset
	var frame := _frame(track, arc, lateral)
	if not _site_clear(track, frame.origin, radius): return
	var prop := asset.instantiate() as Node3D
	prop.name = node_name
	prop.transform = frame.scaled_local(Vector3.ONE * scale_factor)
	for mesh in prop.find_children("*", "MeshInstance3D", true, false):
		mesh.visibility_range_end = 240.0
	add_child(prop)
	_footprints.append(Vector4(frame.origin.x, frame.origin.y, frame.origin.z, radius))

func _pit_building(frame: Transform3D) -> void:
	_box(frame, Vector3(0, 0.08, 0), Vector3(23, 0.16, 48), 3)
	_box(frame, Vector3(4.5, 2.5, 0), Vector3(10, 5, 44), 0)
	_box(frame, Vector3(4.5, 5.2, 0), Vector3(12, 0.4, 46), 5)
	_box(frame, Vector3(-0.7, 4.6, 0), Vector3(0.25, 0.75, 44), 1)
	_box(frame, Vector3(-0.9, 5.1, 0), Vector3(0.3, 0.16, 46), 2)
	for i in range(6):
		var z := float(i) * 7.0 - 17.5
		_box(frame, Vector3(-0.56, 2.0, z), Vector3(0.12, 3.6, 5.6), 4)
		_box(frame, Vector3(-0.66, 3.85, z), Vector3(0.15, 0.25, 5.8), 5)
		_box(frame, Vector3(-7.0, 0.19, z), Vector3(7.0, 0.04, 0.12), 5)
		_box(frame, Vector3(-8.5, 0.19, z + 2.5), Vector3(0.15, 0.04, 4.0), 2)

func _frame(track: Node3D, arc: float, lateral: float) -> Transform3D:
	var forward: Vector3 = track.centerline_forward(arc)
	forward.y = 0.0
	forward = forward.normalized()
	return Transform3D(Basis(Vector3(forward.z, 0, -forward.x), Vector3.UP, forward),
		track.scenery_ground_point(arc, lateral))

func _site_clear(track: Node3D, point: Vector3, radius: float) -> bool:
	if Dressing.overlaps(point, radius, _footprints): return false
	var nearest: Dictionary = track.nearest_on_centerline(point, -1.0)
	return float(nearest.dist) > track.rail_half_width() + radius + 3.0 \
		and Dressing._ground_covers(track, point, radius)

func _box(frame: Transform3D, point: Vector3, size: Vector3, color: int) -> void:
	_boxes[color].append(frame * Transform3D(Basis.from_scale(size), point))
