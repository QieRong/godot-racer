extends RefCounted
## 只替换障碍外观；外包尺寸、摆放和碰撞仍由障碍场负责。
static var _meshes: Dictionary = {}
static var _materials: Dictionary = {}

static func mesh_for(kind: String, size: Vector3) -> ArrayMesh:
	var key := kind + str(size)
	if _meshes.has(key): return _meshes[key]
	var source := BoxMesh.new()
	source.size = size
	source.subdivide_width = 1
	source.subdivide_height = 3 if kind == "barrier" else 1
	source.subdivide_depth = 1
	var arrays := source.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var half := size * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	for index in indices:
		var point := vertices[index]
		var normalized := point / half
		if kind == "rock":
			# 保留六个方向的最大尺寸，收拢棱角，形成不规则分面石块。
			var rounded := normalized.lerp(normalized.normalized(), 0.55)
			var skew := 0.10 * (1.0 - absf(rounded.x)) * rounded.y
			rounded.x += skew
			point = rounded * half
			var shade := 0.85 + 0.15 * (normalized.y + 1.0) * 0.5
			st.set_color(Color(0.39,0.37,0.33) * Color(shade,shade,shade,1.0))
		else:
			# 宽底座与收窄上缘，代替直上直下的橙色方块。
			var shoulder := clampf((normalized.y + 0.35) / 1.35, 0.0, 1.0)
			point.x *= lerpf(1.0, 0.90, shoulder)
			point.z *= lerpf(1.0, 0.70, shoulder)
			st.set_color(Color.WHITE)
		st.set_uv(uvs[index])
		st.add_vertex(point)
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, material_for(kind))
	_meshes[key] = mesh
	return mesh

static func material_for(kind: String) -> StandardMaterial3D:
	if _materials.has(kind): return _materials[kind]
	var material := StandardMaterial3D.new()
	material.roughness = 0.95
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	if kind == "barrier":
		var image := Image.create(64,64,false,Image.FORMAT_RGB8)
		for y in range(64):
			for x in range(64):
				image.set_pixel(x,y,Color("e85635") if (x+y)%32<16 else Color("e8e4d7"))
		image.generate_mipmaps()
		material.albedo_texture = ImageTexture.create_from_image(image)
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_materials[kind] = material
	return material
