extends Node3D
## 路外视觉地形/地基过渡；避开整圈道路及所有模型足迹，不增加可驾驶坡道或碰撞。
const COLORS := {
	"training":Color(0.21,0.29,0.12),"sunny":Color(0.18,0.24,0.10),
	"rain":Color(0.13,0.17,0.15),"sand":Color(0.34,0.24,0.13),"snow":Color(0.32,0.34,0.37)
}

func build(track: Node3D, cfg: Resource, footprints: Array[Vector4]) -> void:
	var key: String = preload("res://scripts/scenery_dressing.gd").theme_key(cfg)
	var rng := RandomNumberGenerator.new()
	rng.seed=27583+key.hash()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 0
	var forms: Array[Vector4] = []
	var target := 28 if key=="rain" else 42
	for attempt in range(1800):
		if count>=target: break
		var arc: float = rng.randf()*track.road_length()
		var radius := rng.randf_range(18.0,55.0)
		var side := -1.0 if rng.randf()<0.5 else 1.0
		var point: Vector3 = track.scenery_ground_point(arc,rng.randf_range(45.0,250.0)*side)
		var near: Dictionary = track.nearest_on_centerline(point,-1.0)
		if float(near.dist)<track.rail_half_width()+radius+8.0: continue
		var ground := track.find_child("GroundMesh",true,false) as MeshInstance3D
		var half := ground.mesh.get_aabb().size.x*0.5
		if absf(point.x)+radius>half or absf(point.z)+radius>half: continue
		var blocked := false
		for other in footprints+forms:
			if Vector2(other.x-point.x,other.z-point.z).length()<other.w+radius+2.0:
				blocked=true;break
		if blocked: continue
		var height := rng.randf_range(3.0,16.0)
		if key=="rain": height=rng.randf_range(0.12,0.45)
		_mound(st,point,radius,height,COLORS[key],rng)
		forms.append(Vector4(point.x,point.y,point.z,radius))
		count+=1
	# 模型脚下加低对比的土/碎石/铺装过渡，避免建筑像直接贴在无边平面上。
	var patches := 0
	for footprint in footprints:
		if footprint.w>25.0: continue
		var center := Vector3(footprint.x,footprint.y,footprint.z)
		var near: Dictionary = track.nearest_on_centerline(center,-1.0)
		if float(near.dist)<track.rail_half_width()+footprint.w+4.0: continue
		var color: Color = COLORS[key].lerp(Color(0.25,0.22,0.16),0.25)
		if key=="rain": color=Color(0.58,0.63,0.68)
		if key=="snow": color=Color(0.28,0.31,0.35)
		_mound(st,center,footprint.w+2.0,0.035,color,rng)
		patches+=1
	st.generate_normals()
	var mesh := st.commit()
	var instance := MeshInstance3D.new()
	instance.name="TerrainAndGroundTransitions"
	instance.mesh=mesh
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo=true
	material.roughness=1.0
	material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	material.cull_mode=BaseMaterial3D.CULL_DISABLED
	var ground := track.find_child("GroundMesh",true,false) as MeshInstance3D
	material.albedo_texture=ground.material_override.albedo_texture
	instance.material_override=material
	instance.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	set_meta("landforms",count)
	set_meta("patches",patches)
	set_meta("forms",forms)
	set_meta("theme",key)

func _mound(st: SurfaceTool, center: Vector3, radius: float, height: float,
		color: Color, rng: RandomNumberGenerator) -> void:
	var rings: Array[PackedVector3Array] = []
	var phase := rng.randf()*TAU
	for ring in range(4):
		var points := PackedVector3Array()
		var fraction := float(ring)/3.0
		for i in range(17):
			var angle := float(i%16)*TAU/16.0
			var irregular := 0.9+sin(angle*3.0+phase)*0.10
			var point := center+Vector3(cos(angle),0,sin(angle))*radius*fraction*irregular
			point.y+=height*pow(1.0-fraction*fraction,2.0)-0.015
			points.append(point)
		rings.append(points)
	for ring in range(3):
		for i in range(16):
			var shade := 0.92+float(ring)*0.04
			for point in [rings[ring][i],rings[ring+1][i],rings[ring+1][i+1],
				rings[ring][i],rings[ring+1][i+1],rings[ring][i+1]]:
				st.set_color(color*Color(shade,shade,shade,1))
				st.set_uv(Vector2(point.x,point.z)/24.0)
				st.add_vertex(point)
