extends RefCounted
## 只给已有平面中心线添加高度；不复制平面DSL或车辆物理。
const Layout := preload("res://scripts/track_layout.gd")

static func apply(planar: Curve3D, profile: String, grade_limit: float) -> Dictionary:
	var total := planar.get_baked_length()
	var parsed := Layout.parse_elevation(profile, grade_limit, total)
	if not parsed.ok: return {"ok": false, "error": parsed.error}
	var points := PackedVector3Array()
	var distances := PackedFloat64Array([0.0])
	var walked := 0.0
	for i in range(planar.point_count):
		points.append(planar.get_point_position(i))
		if i > 0:
			walked += points[i].distance_to(points[i-1])
			distances.append(walked)
	if walked <= 0.0: return {"ok": false, "error": "水平中心线长度为零"}
	var curve := planar.duplicate() as Curve3D
	for i in range(points.size()):
		var t := distances[i] / walked
		var sample := _height(parsed.items, t, total)
		var p := points[i]
		p.y = sample.x
		var handle_in := planar.get_point_in(i)
		var handle_out := planar.get_point_out(i)
		handle_in.y = -sample.y * Vector2(handle_in.x, handle_in.z).length()
		handle_out.y = sample.y * Vector2(handle_out.x, handle_out.z).length()
		curve.set_point_position(i, p)
		curve.set_point_in(i, handle_in)
		curve.set_point_out(i, handle_out)
	curve.bake_interval = 0.5
	var report := measure(curve)
	if report.min_height < -0.001 or report.max_height > 16.001:
		return {"ok": false, "error": "本版高度范围必须在0—16m内，实际%.3f—%.3fm" % [report.min_height, report.max_height]}
	if report.max_grade > grade_limit + 0.00001:
		return {"ok": false, "error": "最终曲线实际坡度 %.3f%% 超过硬上限 %.3f%%" % [report.max_grade*100.0, grade_limit*100.0]}
	report["ok"] = true
	report["error"] = ""
	report["horizontal_length"] = total
	report["curve"] = curve
	return report

static func _height(items: Array, t: float, total: float) -> Vector2:
	for i in range(1, items.size()):
		if t > float(items[i].t) and i < items.size()-1: continue
		var a: Dictionary = items[i-1]
		var b: Dictionary = items[i]
		var span := float(b.t) - float(a.t)
		var u := clampf((t-float(a.t))/span, 0.0, 1.0)
		# 五次平滑步进：段端一、二阶导数均为零，坡顶与起终点不留硬折。
		var smooth := u*u*u*(u*(u*6.0-15.0)+10.0)
		var derivative := 30.0*u*u*(u-1.0)*(u-1.0)
		var rise := float(b.h)-float(a.h)
		return Vector2(float(a.h)+rise*smooth, rise*derivative/(span*total))
	return Vector2.ZERO

static func measure(curve: Curve3D) -> Dictionary:
	var highest := -INF
	var lowest := INF
	var grade := 0.0
	var samples := curve.get_baked_points()
	for i in range(samples.size()):
		highest = maxf(highest, samples[i].y)
		lowest = minf(lowest, samples[i].y)
		if i == 0: continue
		var d := samples[i]-samples[i-1]
		var horizontal := Vector2(d.x, d.z).length()
		if horizontal > 0.00001: grade = maxf(grade, absf(d.y)/horizontal)
	return {"min_height": lowest, "max_height": highest, "max_grade": grade}

static func surface_frame(track: Node3D, arc: float, lateral: float) -> Transform3D:
	var p: Vector3 = track.centerline_point(arc)
	var tangent: Vector3 = (track.centerline_point(arc+0.5)-track.centerline_point(arc-0.5)).normalized()
	var flat: Vector3 = track.centerline_forward(arc)
	var side := Vector3(flat.z, 0.0, -flat.x).normalized()
	var normal := tangent.cross(side).normalized()
	return Transform3D(Basis(side, normal, tangent).orthonormalized(),
		p + side*lateral + Vector3.UP*track.road_lift)

static func build_verges(track: Node3D, material: Material) -> void:
	# 护栏外路肩与边坡落到已有地面，视觉/碰撞使用同一个mesh。
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := ceili(track.road_length()/4.0)
	var faces := PackedVector3Array()
	for i in range(steps):
		var a: float = float(i)*track.road_length()/steps
		var b: float = float(i+1)*track.road_length()/steps
		for sign_i in [-1.0, 1.0]:
			var ra := _verge_ring(track, a, sign_i)
			var rb := _verge_ring(track, b, sign_i)
			for j in range(2):
				for p in [ra[j], rb[j], rb[j+1], ra[j], rb[j+1], ra[j+1]]:
					faces.append(p)
					st.set_uv(Vector2(p.x, p.z)/24.0)
					st.add_vertex(p)
	st.generate_normals()
	var mesh := st.commit()
	var visual := MeshInstance3D.new()
	visual.name = "ElevationVerges"
	visual.mesh = mesh
	var mat := material.duplicate() as BaseMaterial3D
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.uv1_scale = Vector3.ONE
	visual.material_override = mat
	track.add_child(visual)
	var body := StaticBody3D.new()
	body.name = "ElevationVergeBody"
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	collision.shape = shape
	body.add_child(collision)
	track.add_child(body)

static func _verge_ring(track: Node3D, arc: float, sign_i: float) -> Array[Vector3]:
	var p: Vector3 = track.centerline_point(arc)
	var f: Vector3 = track.centerline_forward(arc)
	var side := Vector3(f.z, 0.0, -f.x).normalized()*sign_i
	var inner: Vector3 = p+side*(track.road_half_width()+0.05)
	var shoulder: Vector3 = p+side*(track.rail_half_width()+1.5)
	var toe: Vector3 = p+side*(track.rail_half_width()+maxf(12.0, p.y*2.0+5.0))
	toe.y = -0.01
	return [inner, shoulder, toe]

static func scenery_ground_point(track: Node3D, arc: float, lateral: float) -> Vector3:
	var p: Vector3 = track.centerline_point(arc)
	var f: Vector3 = track.centerline_forward(arc)
	var side := Vector3(f.z, 0.0, -f.x).normalized()
	var result: Vector3 = p+side*lateral
	if track.elevation_profile.is_empty(): return result
	var ring := _verge_ring(track, arc, -1.0 if lateral < 0.0 else 1.0)
	var shoulder: float = track.rail_half_width()+1.5
	var toe: float = track.rail_half_width()+maxf(12.0, p.y*2.0+5.0)
	var fraction := clampf((absf(lateral)-shoulder)/(toe-shoulder), 0.0, 1.0)
	result.y = lerpf(ring[1].y, ring[2].y, fraction)
	return result
