extends RefCounted
## 雪天专用视觉材质；保留原贴图和模型，不修改共享资源或物理。

static func tint_ground(material: StandardMaterial3D) -> void:
	# 旧基色在当前日光下溢成纯白；压低输入，让原积雪贴图重新可读。
	material.albedo_color = Color(0.32,0.34,0.37)
	material.metallic = 0.0
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

static func tree_material(node: MeshInstance3D) -> Material:
	var source := node.get_active_material(0) as StandardMaterial3D
	if source == null: return node.material_override
	return tinted_material(source,str(node.name))

static func tinted_material(source: StandardMaterial3D, role: String) -> StandardMaterial3D:
	var material := source.duplicate() as StandardMaterial3D
	material.metallic = 0.0
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if role.contains("foliage") or role.contains("needles"):
		material.albedo_color = Color(0.08,0.16,0.12)
	elif role.begins_with("snow_") or role.ends_with("_snow"):
		material.albedo_color = Color(0.38,0.40,0.42)
	else:
		material.albedo_color = Color(0.50,0.47,0.44)
	return material

static func bank_placements(track: Node3D) -> Array[Transform3D]:
	var placements: Array[Transform3D] = []
	var count := mini(20,ceili(track.road_length()/240.0))
	var rng := RandomNumberGenerator.new()
	rng.seed=27519
	for i in range(count):
		var center_arc: float = rng.randf()*track.road_length()
		var side := -1.0 if rng.randf()<0.5 else 1.0
		for member in range(2):
			var arc: float = fposmod(center_arc+float(member)*rng.randf_range(6.0,15.0),track.road_length())
			var lateral: float = (track.rail_half_width()+rng.randf_range(7.0,25.0))*side
			var position: Vector3 = track.scenery_ground_point(arc,lateral)
			var near: Dictionary = track.nearest_on_centerline(position,-1.0)
			# 原雪堆4.2x2.6m，2.5m包围半径；避开相邻赛道路段及原空气墙。
			if float(near.dist)<track.rail_half_width()+4.5: continue
			var basis := Basis(Vector3.UP,rng.randf_range(-PI,PI))
			placements.append(Transform3D(basis,position))
	return placements

static func forest_placements(track: Node3D) -> Array[Transform3D]:
	var placements: Array[Transform3D] = []
	var count := mini(12,ceili(track.road_length()/400.0))
	for i in range(count):
		for sign_i in [-1.0,1.0]:
			for member in range(3):
				var arc: float = fposmod(float(i)*track.road_length()/float(count)
					+float(member)*9.0,track.road_length())
				var distance := 60.0+float((i+member)%4)*10.0
				var position: Vector3 = track.scenery_ground_point(arc,distance*sign_i)
				var near: Dictionary = track.nearest_on_centerline(position,-1.0)
				if float(near.dist)<track.rail_half_width()+6.0: continue
				var scale_factor := 1.05+float(member)*0.20
				var basis := Basis(Vector3.UP,float(i+member)*1.3).scaled(Vector3.ONE*scale_factor)
				placements.append(Transform3D(basis,position))
	return placements

static func multi_surface_tree_mesh(node: MeshInstance3D) -> Mesh:
	var mesh := node.mesh.duplicate() as ArrayMesh
	for surface in range(mesh.get_surface_count()):
		var source := node.get_active_material(surface) as StandardMaterial3D
		if source!=null:
			mesh.surface_set_material(surface,tinted_material(source,source.resource_name))
	return mesh

static func flake_texture() -> GradientTexture2D:
	# 内建径向渐变：让雪花中心可见、边缘透明，避免贴脸的硬边白方块。
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0,0.25,1.0])
	gradient.colors = PackedColorArray([Color.WHITE,Color(1,1,1,0.8),Color(1,1,1,0)])
	var texture := GradientTexture2D.new()
	texture.width = 32
	texture.height = 32
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5,0.5)
	texture.fill_to = Vector2(1.0,0.5)
	return texture
