extends Node3D
## 主题美术沿最终中心线装配；只生成视觉实例，不另造道路或路中碰撞。
## GLB已由Blender检查米制尺寸。每类子网格合并成MultiMesh，限制draw call。
var asset_instances := 0

func build(track: Node3D, cfg: Resource) -> void:
	_tint_ground(track, cfg)
	var asset := "pine_tree"
	var spacing := 35.0
	var scale_factor := 1.8
	match cfg.weather_type:
		"snow": asset = "snow_pine_tree"
		"sand": asset = "sandstone_boulder"; scale_factor = 4.0
		"rain": asset = "street_lamp"; spacing = 48.0; scale_factor = 1.5
	if cfg.weather_type == "clear" and cfg.display_name != "新兵训练营": asset = "sun_palm"
	var placements: Array[Transform3D] = []
	var light_targets: Array[Vector3] = []
	var length: float = track.road_length()
	var count := mini(180, int(length / spacing))
	for i in range(count):
		var arc := float(i) * length / float(count)
		var f: Vector3 = track.centerline_forward(arc)
		# 路灯按固定横向距离成对布置；一侧靠近相邻路段时整对略过。
		var lamp_offset: float = track.road_half_width()+8.0
		if asset == "street_lamp":
			var pair_clear := true
			for sign_i in [-1.0,1.0]:
				var pole: Vector3 = track.scenery_ground_point(arc,lamp_offset*sign_i)
				var pole_near: Dictionary = track.nearest_on_centerline(pole,-1.0)
				if Vector3(pole_near.pos).distance_to(pole)<track.road_half_width()+5.5: pair_clear=false
			if not pair_clear: continue
		for sign_i in [-1.0, 1.0]:
			var off: float = track.road_half_width() + 8.0 + float(i % 4) * 3.0
			if asset == "street_lamp": off=lamp_offset
			var pos: Vector3 = track.scenery_ground_point(arc, off * sign_i)
			# 空间近邻再验，不能把A段的路边树放到相邻B段路中。
			var near: Dictionary = track.nearest_on_centerline(pos, -1.0)
			if Vector3(near.pos).distance_to(pos) < track.road_half_width() + 5.5: continue
			var basis := Basis(Vector3.UP, float(i) * 1.3).scaled(Vector3.ONE * scale_factor)
			if asset == "street_lamp":
				# 模型灯臂沿本地+X；道路两侧镜像朝内，不用负缩放翻转模型。
				basis = Basis(Vector3.UP,atan2(f.x,f.z)+(PI if sign_i>0.0 else 0.0)).scaled(Vector3.ONE*scale_factor)
				light_targets.append(track.centerline_point(arc)+Vector3.UP*track.road_lift)
			placements.append(Transform3D(basis, pos))
	_stamp(asset, placements)
	if asset == "street_lamp":
		var lighting := preload("res://scripts/street_lighting.gd").new()
		lighting.name = "StreetLighting"
		add_child(lighting)
		lighting.setup(placements,light_targets,track.get_parent().get_node_or_null("RaceCar"))
	asset_instances = placements.size()
	_build_markers(track)
	var delineators := preload("res://scripts/boundary_delineators.gd").new()
	delineators.name = "BoundaryDelineators"
	add_child(delineators)
	delineators.build(track)
	print("[主题] %s 实例%d MultiMesh子批次%d 无新增碰撞" % [asset, asset_instances, get_child_count()])

func _tint_ground(track: Node3D, cfg: Resource) -> void:
	var road := track.find_child("RoadMesh", true, false) as MeshInstance3D
	if road != null and road.material_override is StandardMaterial3D:
		road.material_override.albedo_color = Color(0.32,0.36,0.4)
		road.material_override.roughness = 0.72 if cfg.weather_type == "rain" else 0.95
	var ground := track.find_child("GroundMesh", true, false) as MeshInstance3D
	if ground == null: return
	var material := ground.material_override as StandardMaterial3D
	if material == null: return
	match cfg.weather_type:
		"snow": material.albedo_color = Color(0.8,0.86,0.92)
		"sand": material.albedo_color = Color(0.65,0.43,0.23)
		"rain": material.albedo_color = Color(0.25,0.32,0.3)
		_: material.albedo_color = Color(0.32,0.55,0.2) if cfg.display_name == "新兵训练营" else Color(0.48,0.55,0.25)
	var verges := track.find_child("ElevationVerges", false, false) as MeshInstance3D
	if verges != null and verges.material_override is StandardMaterial3D:
		verges.material_override.albedo_color = material.albedo_color

func _stamp(asset: String, placements: Array[Transform3D]) -> void:
	var packed: PackedScene = load("res://models/environment/%s.glb" % asset)
	if packed == null: return
	var model := packed.instantiate()
	var chunks: Dictionary = {}
	for placement in placements:
		var key := Vector2i(floori(placement.origin.x / 160.0), floori(placement.origin.z / 160.0))
		if not chunks.has(key): chunks[key] = []
		chunks[key].append(placement)
	for key in chunks:
		var center := Vector3(key.x * 160.0 + 80.0, 0.0, key.y * 160.0 + 80.0)
		var local_placements: Array[Transform3D] = []
		for placement in chunks[key]:
			local_placements.append(Transform3D(placement.basis, placement.origin - center))
		_collect_meshes(model, Transform3D.IDENTITY, local_placements, center)
	model.free()

func _collect_meshes(node: Node, parent_transform: Transform3D, placements: Array[Transform3D], center: Vector3) -> void:
	var local := parent_transform
	if node is Node3D: local = parent_transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.mesh = node.mesh
		batch.instance_count = placements.size()
		for i in range(placements.size()): batch.set_instance_transform(i, placements[i] * local)
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = batch
		instance.material_override = node.material_override
		instance.position = center
		instance.visibility_range_end = 350.0
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)
	for child in node.get_children(): _collect_meshes(child, local, placements, center)

func _build_markers(track: Node3D) -> void:
	# 红白路缘由最终中心线采样，合批且在护栏内；没有影响车辆的第二套碰撞。
	var batches: Array[MultiMesh] = []
	for color in [Color(0.82, 0.12, 0.10), Color(0.9, 0.91, 0.88)]:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.45, 0.06, 2.1)
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.9
		mesh.material = material
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.mesh = mesh
		batch.instance_count = 0
		batches.append(batch)
	var transforms: Array = [[], []]
	for i in range(int(track.road_length() / 2.0)):
		var p: Vector3 = track.centerline_point(i * 2.0)
		var f: Vector3 = track.centerline_forward(i * 2.0)
		var side := Vector3(f.z, 0.0, -f.x).normalized()
		for sign_i in [-1.0, 1.0]:
			transforms[i % 2].append(Transform3D(Basis(Vector3.UP, atan2(f.x, f.z)),
				p + side * sign_i * (track.road_half_width() - 0.3) + Vector3.UP * 0.045))
	for k in range(2):
		batches[k].instance_count = transforms[k].size()
		for i in range(transforms[k].size()): batches[k].set_instance_transform(i, transforms[k][i])
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = batches[k]
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)
