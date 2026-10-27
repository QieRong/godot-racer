extends Node3D
## 低矮反光桩直接取原空气墙位置；只有视觉MultiMesh，没有新增碰撞。
func build(track: Node3D) -> void:
	var placements: Array[Transform3D] = []
	var count := ceili(track.road_length()/24.0)
	for i in range(count):
		var arc: float = float(i)*track.road_length()/float(count)
		var p: Vector3 = track.centerline_point(arc)+Vector3.UP*track.road_lift
		var f: Vector3 = track.centerline_forward(arc)
		var side := Vector3(f.z,0.0,-f.x).normalized()
		for sign_i in [-1.0,1.0]:
			placements.append(Transform3D(Basis(Vector3.UP,atan2(f.x,f.z)),
				p+side*sign_i*track.rail_half_width()))
	var body := StandardMaterial3D.new()
	body.albedo_color=Color(0.12,0.15,0.18)
	body.roughness=0.9
	var white := StandardMaterial3D.new()
	white.albedo_color=Color(0.92,0.94,0.90)
	white.emission_enabled=true
	white.emission=Color(0.45,0.47,0.42)
	white.roughness=0.35
	var red := StandardMaterial3D.new()
	red.albedo_color=Color(0.95,0.18,0.08)
	red.emission_enabled=true
	red.emission=Color(0.45,0.045,0.015)
	red.roughness=0.35
	_batch("Posts",Vector3(0.14,0.72,0.14),body,placements,[0.36])
	_batch("WhiteBands",Vector3(0.17,0.11,0.17),white,placements,[0.20,0.48])
	_batch("RedReflectors",Vector3(0.18,0.08,0.18),red,placements,[0.64])

func _batch(label: String, size: Vector3, material: Material,
		placements: Array[Transform3D], heights: Array) -> void:
	var mesh := BoxMesh.new()
	mesh.size=size
	mesh.material=material
	var batch := MultiMesh.new()
	batch.transform_format=MultiMesh.TRANSFORM_3D
	batch.mesh=mesh
	batch.instance_count=placements.size()*heights.size()
	var index:=0
	for placement in placements:
		for height in heights:
			var t:=placement
			t.origin.y+=float(height)
			batch.set_instance_transform(index,t)
			index+=1
	var visual:=MultiMeshInstance3D.new()
	visual.name=label
	visual.multimesh=batch
	visual.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(visual)
