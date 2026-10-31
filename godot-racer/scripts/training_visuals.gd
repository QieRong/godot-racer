extends Node3D
## L1山林训练场的纯视觉设施；共享几何与材质，不生成碰撞、不消费赛事随机数。
const COLORS := [Color("243947"), Color("d6d8ca"), Color("b52e35"),
	Color("616d69"), Color("344e35"), Color("567141"), Color("78904c")]
var _boxes: Array = [[], [], [], [], [], [], []]
var _footprints: Array[Vector4] = []
var _rng := RandomNumberGenerator.new()

func build(track: Node3D) -> Array[Vector4]:
	_rng.seed = 314159
	var start: float = track.start_finish_t * track.road_length()
	var gate := _frame(track, start + 26.0, 0.0)
	var span: float = track.rail_half_width() + 3.5
	for side in [-1.0, 1.0]:
		_box(gate, Vector3(side * span, 4.2, 0), Vector3(0.7, 8.4, 1.0), 0)
		_box(gate, Vector3(side * span, 0.3, 0), Vector3(1.7, 0.6, 2.0), 3)
		_reserve(gate * Vector3(side * span, 0, 0), 2.0)
	_box(gate, Vector3(0, 7.8, 0), Vector3(span * 2.0 + 0.7, 1.8, 0.65), 0)
	_box(gate, Vector3(0, 8.8, 0), Vector3(span * 2.0 + 0.7, 0.18, 0.8), 2)
	for side in [-1.0, 1.0]:
		for row in range(2):
			for col in range(4):
				var x: float = side * (span - 3.0) + (float(col) - 1.5) * 0.6
				_box(gate, Vector3(x, 7.35 + row * 0.6, -0.34), Vector3(0.6, 0.6, 0.04),
					1 if (row + col) % 2 == 0 else 0)
	_label(gate, Vector3(0, 7.85, -0.38), "GODOT CIRCUIT", 0.015)
	# 两侧错开，留出起跑和远处道路视线；每个设施都检查整圈道路净空。
	for data in [[72.0, 1.0, 0], [125.0, -1.0, 1], [225.0, 1.0, 1]]:
		var lateral: float = float(data[1]) * (track.rail_half_width() + 23.0)
		var frame := _frame(track, start + float(data[0]), lateral)
		if not _site_clear(track, frame.origin, 17.0): continue
		_reserve(frame.origin, 17.0)
		if int(data[2]) == 0: _paddock(frame)
		else: _grandstand(frame, float(data[1]))
	# 全圈分段设旗，避免复制起点设施或铺成连续围墙。
	for i in range(18):
		var arc: float = start + 48.0 + float(i) * track.road_length() / 18.0
		var side := 1.0 if i % 2 == 0 else -1.0
		var frame := _frame(track, arc, side * (track.rail_half_width() + 5.0))
		if not _site_clear(track, frame.origin, 1.5): continue
		_box(frame, Vector3(0, 3.8, 0), Vector3(0.12, 7.6, 0.12), 3)
		_box(frame, Vector3(side * 0.75, 5.65, 0), Vector3(1.4, 3.2, 0.06), 2)
		_box(frame, Vector3(side * 0.75, 4.65, -0.04), Vector3(1.4, 0.3, 0.04), 1)
		_reserve(frame.origin, 1.6)
	_build_forest(track)
	_build_mountains(track)
	for i in range(COLORS.size()):
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE
		_batch("Facilities_%d" % i, mesh, _boxes[i], COLORS[i], 520.0)
	set_meta("facility_sites", _footprints.size())
	return _footprints

func _paddock(frame: Transform3D) -> void:
	_box(frame, Vector3(0, 0.06, 0), Vector3(16, 0.12, 28), 3)
	# 维修棚：开敞立柱、红色檐口、深色顶棚，避免封闭立方盒。
	for x in [-6.0, 6.0]:
		for z in [-11.0, 0.0, 11.0]:
			_box(frame, Vector3(x, 2.4, z), Vector3(0.28, 4.8, 0.28), 0)
	_box(frame, Vector3(0, 4.9, 0), Vector3(14, 0.3, 26), 0)
	for x in [-7.0, 7.0]:
		_box(frame, Vector3(x, 4.65, 0), Vector3(0.18, 0.65, 26), 2)
	for z in [-9.0, 0.0, 9.0]:
		_box(frame, Vector3(0, 1.05, z), Vector3(6.0, 2.0, 0.65), 1)
		_box(frame, Vector3(0, 1.8, z - 0.36), Vector3(4.0, 0.4, 0.08), 2)
		for x in [-4.8, 4.8]:
			_box(frame, Vector3(x, 0.65, z), Vector3(0.8, 1.2, 1.5), 0)

func _grandstand(frame: Transform3D, side: float) -> void:
	for row in range(4):
		var x: float = side * (float(row) * 1.5 - 2.25)
		var height := 0.7 + float(row) * 0.65
		_box(frame, Vector3(x, height * 0.5, 0), Vector3(1.5, height, 26), 3)
		for seat in range(15):
			_box(frame, Vector3(x, height + 0.18, float(seat) * 1.6 - 11.2),
				Vector3(0.65, 0.28, 1.0), 2 if (seat / 3 + row) % 2 == 0 else 1)
	for z in [-13.0, 0.0, 13.0]:
		_box(frame, Vector3(side * 4.2, 3.3, z), Vector3(0.25, 6.6, 0.25), 0)
	_box(frame, Vector3(0, 6.7, 0), Vector3(11.0, 0.28, 29.0), 0)
	_box(frame, Vector3(-side * 5.4, 6.5, 0), Vector3(0.2, 0.65, 29.0), 2)

func _build_forest(track: Node3D) -> void:
	var trunks: Array[Transform3D] = []
	var crowns: Array = [[], [], []]
	for i in range(420):
		# 簇间留白，近处小树、后排高树，独立装饰种子不影响坡度/障碍组合。
		var cluster := i / 10
		var arc: float = float(cluster) * track.road_length() / 42.0 + _rng.randf_range(-32, 32)
		var lateral := _rng.randf_range(34, 125) * (1.0 if cluster % 2 == 0 else -1.0)
		var point: Vector3 = track.scenery_ground_point(arc, lateral)
		if not _site_clear(track, point, 4.0): continue
		var blocked := false
		for other in _footprints:
			if Vector2(point.x - other.x, point.z - other.z).length() < other.w + 4.0:
				blocked = true
				break
		if blocked: continue
		var height := _rng.randf_range(6.0, 13.0)
		var radius := height * _rng.randf_range(0.20, 0.28)
		trunks.append(Transform3D(Basis.from_scale(Vector3(0.4, height * 0.4, 0.4)),
			point + Vector3.UP * height * 0.2))
		for layer in range(3):
			var scale_y := height * (0.56 - float(layer) * 0.10)
			var width := radius * (1.0 - float(layer) * 0.23)
			var origin := point + Vector3.UP * (height * (0.35 + float(layer) * 0.23))
			crowns[i % 3].append(Transform3D(Basis.from_scale(Vector3(width, scale_y, width)), origin))
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.4
	trunk.bottom_radius = 0.5
	trunk.height = 1.0
	trunk.radial_segments = 6
	_batch("ForestTrunks", trunk, trunks, Color("635a43"), 650.0)
	var cone := _cone_mesh()
	for i in range(3): _batch("ForestCanopy_%d" % i, cone, crowns[i], COLORS[i + 4], 650.0)
	set_meta("forest_trees", trunks.size())

func _build_mountains(track: Node3D) -> void:
	var ground := track.find_child("GroundMesh", true, false) as MeshInstance3D
	var bounds := ground.mesh.get_aabb()
	var center := ground.to_global(bounds.get_center())
	var radius := maxf(bounds.size.x, bounds.size.z) * 0.55 + 130.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 连续山脊：山脚—山腰—山顶连成起伏轮廓，避免规则锥体围一圈。
	for layer in range(2):
		var ridge: Array[Vector3] = []
		var ring_radius := radius + float(layer) * 210.0
		for i in range(97):
			var angle := float(i % 96) * TAU / 96.0
			var height := 90.0 + float(layer) * 55.0 + sin(angle * 5.0 + layer) * 26.0 \
				+ sin(angle * 13.0) * 17.0 + sin(angle * 27.0) * 9.0
			# 三组山体与低谷交替，打断环形山墙；颜色继续使用同一灰绿色盘。
			height *= smoothstep(0.0, 0.65, maxf(0.0, sin(angle * 3.0 + 0.4)))
			var distance := ring_radius + sin(angle * 7.0) * 42.0
			ridge.append(center + Vector3(cos(angle) * distance, height, sin(angle) * distance))
		for i in range(96):
			var a := float(i) * TAU / 96.0
			var b := float(i + 1) * TAU / 96.0
			var base_a := center + Vector3(cos(a) * (ring_radius - 210.0), -4, sin(a) * (ring_radius - 210.0))
			var base_b := center + Vector3(cos(b) * (ring_radius - 210.0), -4, sin(b) * (ring_radius - 210.0))
			var waist_a := base_a.lerp(ridge[i], 0.48)
			var waist_b := base_b.lerp(ridge[i + 1], 0.48)
			waist_a.y += sin(a * 19.0) * 12.0
			waist_b.y += sin(b * 19.0) * 12.0
			var color := Color("52634f") if layer == 0 else Color("5a7068")
			st.set_color(color.lightened(float(i % 3) * 0.018))
			for vertex in [base_a, waist_a, waist_b, base_a, waist_b, base_b,
				waist_a, ridge[i], ridge[i + 1], waist_a, ridge[i + 1], waist_b]:
				st.add_vertex(vertex)
	st.generate_normals()
	var instance := MeshInstance3D.new()
	instance.name = "DistantMountainRidges"
	instance.mesh = st.commit()
	var material := _material(Color.WHITE)
	material.vertex_color_use_as_albedo = true
	# 远山使用烘入的分面明暗，避免高能量主光再次叠亮成白色。
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_is_srgb = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)

func _cone_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(7):
		var a := float(i) * TAU / 7.0
		var b := float(i + 1) * TAU / 7.0
		for vertex in [Vector3(cos(a), -0.5, sin(a)), Vector3(0, 0.5, 0),
			Vector3(cos(b), -0.5, sin(b))]:
			st.add_vertex(vertex)
	st.generate_normals()
	return st.commit()

func _frame(track: Node3D, arc: float, lateral: float) -> Transform3D:
	var forward: Vector3 = track.centerline_forward(arc)
	var side := Vector3(forward.z, 0, -forward.x)
	return Transform3D(Basis(side, Vector3.UP, forward), track.scenery_ground_point(arc, lateral))

func _site_clear(track: Node3D, point: Vector3, radius: float) -> bool:
	var nearest: Dictionary = track.nearest_on_centerline(point, -1.0)
	if float(nearest.dist) < track.rail_half_width() + radius + 3.0: return false
	var ground := track.find_child("GroundMesh", true, false) as MeshInstance3D
	var bounds := ground.mesh.get_aabb()
	var local := ground.to_local(point)
	return local.x - radius > bounds.position.x and local.x + radius < bounds.end.x \
		and local.z - radius > bounds.position.z and local.z + radius < bounds.end.z

func _reserve(point: Vector3, radius: float) -> void:
	_footprints.append(Vector4(point.x, point.y, point.z, radius))

func _box(frame: Transform3D, point: Vector3, size: Vector3, color: int) -> void:
	_boxes[color].append(frame * Transform3D(Basis.from_scale(size), point))

func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material

func _batch(title: String, mesh: Mesh, poses: Array, color: Color, distance: float) -> void:
	if poses.is_empty(): return
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = poses.size()
	for i in range(poses.size()): multi.set_instance_transform(i, poses[i])
	var instance := MultiMeshInstance3D.new()
	instance.name = title
	instance.multimesh = multi
	instance.material_override = _material(color)
	instance.visibility_range_end = distance
	add_child(instance)

func _label(frame: Transform3D, point: Vector3, title: String, pixel: float) -> void:
	var label := Label3D.new()
	label.text = title
	label.font_size = 80
	label.pixel_size = pixel
	label.modulate = Color("e7e8df")
	label.outline_size = 0
	label.transform = frame * Transform3D(Basis(Vector3.UP, PI), point)
	add_child(label)
