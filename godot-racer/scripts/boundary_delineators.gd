extends Node3D
## 低矮反光桩直接取原空气墙位置；只有视觉MultiMesh，没有新增碰撞。
func build(track: Node3D) -> void:
	var placements: Array[Transform3D] = []
	var base_arcs: Array[float] = [0.0]
	var previous := _at_arc(track,0.0)
	placements.append_array(previous)
	var distances := Vector2.ZERO
	# 以两侧边界实际路程布桩，外弯不因中心线24m变成近30m；闭环尾段也计入。
	for i in range(1,ceili(track.road_length()/0.5)+1):
		var pair := _at_arc(track,minf(float(i)*0.5,track.road_length()))
		var step := Vector2(previous[0].origin.distance_to(pair[0].origin),
			previous[1].origin.distance_to(pair[1].origin))
		if maxf(distances.x+step.x,distances.y+step.y)>23.5:
			placements.append_array(previous)
			base_arcs.append(float(i-1)*0.5)
			distances = step
		else:
			distances += step
		previous = pair
	# 保留每根原桩，各侧按实际边界路径路程取中点；外弯与内弯独立，含闭环尾段。
	var dense: Array[Transform3D] = []
	for i in range(base_arcs.size()):
		dense.append(placements[i*2])
		dense.append(placements[i*2+1])
		var end_arc: float = base_arcs[i+1] if i+1<base_arcs.size() else track.road_length()
		for side in range(2): dense.append(_boundary_midpoint(track,base_arcs[i],end_arc,side))
	placements=dense
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

func _boundary_midpoint(track: Node3D, start: float, end: float, side: int) -> Transform3D:
	var steps := ceili((end-start)/0.25)
	var distances: Array[float] = [0.0]
	var previous: Vector3 = _at_arc(track,start)[side].origin
	for i in range(1,steps+1):
		var point: Vector3 = _at_arc(track,lerpf(start,end,float(i)/steps))[side].origin
		distances.append(distances[-1]+previous.distance_to(point))
		previous=point
	var half := distances[-1]*0.5
	for i in range(1,distances.size()):
		if distances[i]<half: continue
		var fraction := (half-distances[i-1])/maxf(distances[i]-distances[i-1],0.00001)
		return _at_arc(track,lerpf(start,end,(float(i-1)+fraction)/steps))[side]
	return _at_arc(track,(start+end)*0.5)[side]

func _at_arc(track: Node3D, arc: float) -> Array[Transform3D]:
	var p: Vector3 = track.centerline_point(arc)+Vector3.UP*track.road_lift
	var f: Vector3 = track.centerline_forward(arc)
	var side := Vector3(f.z,0.0,-f.x).normalized()
	var pair: Array[Transform3D] = []
	for sign_i in [-1.0,1.0]:
		pair.append(Transform3D(Basis(Vector3.UP,atan2(f.x,f.z)),p+side*sign_i*track.rail_half_width()))
	return pair

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
	visual.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(visual)
