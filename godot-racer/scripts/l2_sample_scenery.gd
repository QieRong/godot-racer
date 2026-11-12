extends Node3D
## L2单关美化样板。插件在独立工程制作/烘焙，游戏仅加载静态视觉资源。
const HILL := preload("res://assets/l2_sample/terrain_hill.res")
const FACILITY := preload("res://assets/l2_sample/pit_grandstand_refined.glb")
const SKY_TEXTURE := preload("res://assets/l2_sample/sky3d_day.exr")
const Dressing := preload("res://scripts/scenery_dressing.gd")
const HILL_SCALES := [
	Vector3(1.0, 0.82, 0.86), Vector3(0.82, 1.24, 1.0), Vector3(0.94, 1.03, 0.85),
]
var hills := 0
var facilities := 0

func build(track: Node3D) -> void:
	name = "L2ScenerySample"
	var environment_node := get_parent().get_node("WorldEnvironment") as WorldEnvironment
	var env := environment_node.environment
	var previous_sky := env.sky
	if previous_sky != null:
		RenderingServer.frame_post_draw.connect(preload("res://scripts/theme_sky.gd")._release_sky_after_draw.bind(previous_sky), CONNECT_ONE_SHOT)
	var panorama := PanoramaSkyMaterial.new()
	panorama.panorama = SKY_TEXTURE
	var sky := Sky.new()
	sky.sky_material = panorama
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.set_meta("source", "Sky3D 2.1.0 / 14:00 daytime bake")
	env.sky = sky
	var sun := get_parent().get_node("Sun") as DirectionalLight3D
	# 与Sky3D烘焙时的方向灯一致，避免天空太阳与地面影子相互矛盾。
	sun.rotation = Vector3(-0.6979806, -0.69211274, 0)
	sun.light_color = Color.WHITE
	sun.light_energy = 1.0
	var hill_material := StandardMaterial3D.new()
	var ground := track.find_child("GroundMesh", true, false) as MeshInstance3D
	var ground_material := ground.material_override as StandardMaterial3D
	hill_material.albedo_color = ground_material.albedo_color
	hill_material.albedo_texture = ground_material.albedo_texture
	# 地面颜色还会乘草地贴图；山体复用同一贴图和世界尺度，避免纯色山仍显浅。
	hill_material.uv1_triplanar = true
	hill_material.uv1_world_triplanar = true
	hill_material.uv1_scale = Vector3.ONE * ground_material.uv1_scale.x / ground.mesh.get_aabb().size.x
	hill_material.texture_filter = ground_material.texture_filter
	hill_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	hill_material.roughness = 1.0
	var length_m: float = track.road_length()
	var start: float = track.start_finish_t * length_m
	# 不接管道路地形；整块丘陵须在道路缓冲区以外，没有碰撞或植被。
	for i in range(8):
		var arc := start + length_m * (float(i) + 0.5) / 8.0
		var sign_f := -1.0 if i % 2 == 0 else 1.0
		var center: Vector3 = track.scenery_ground_point(arc, sign_f * (track.rail_half_width() + 175.0))
		var nearest: Dictionary = track.nearest_on_centerline(center, -1.0)
		if float(nearest.dist) <= track.rail_half_width() + 135.0: continue
		var hill := MeshInstance3D.new()
		hill.name = "Terrain3DHill%d" % i
		hill.mesh = HILL
		hill.material_override = hill_material
		hill.scale = HILL_SCALES[i % HILL_SCALES.size()]
		hill.position = center - Vector3(128 * hill.scale.x, 0.5, 128 * hill.scale.z)
		hill.visibility_range_end = 800.0
		hill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(hill)
		hills += 1
	var reserved: Array[Vector4] = []
	for group in get_parent().get_node("TrackScenery/EnvironmentAssetPack").get_children():
		var apron := group.get_node_or_null("FacilityApron") as MultiMeshInstance3D
		if apron == null: continue
		var size := apron.multimesh.mesh.get_aabb().size
		var radius := Vector2(size.x, size.z).length() * 0.5 + 1.0
		for pose: Transform3D in group.get_meta("placements"):
			reserved.append(Vector4(pose.origin.x, pose.origin.y, pose.origin.z, radius))
	# 入口朝向赛道，整块看台同时避开既有建筑和相邻路段。
	for site in [[85.0, 40.0], [125.0, 65.0], [165.0, 65.0], [125.0, 95.0]]:
		var arc: float = start + float(site[0])
		var point: Vector3 = track.scenery_ground_point(arc, -(track.rail_half_width() + float(site[1])))
		var nearest: Dictionary = track.nearest_on_centerline(point, -1.0)
		if float(nearest.dist) <= track.rail_half_width() + 32.0: continue
		if Dressing.overlaps(point, 29.0, reserved) or not Dressing._ground_covers(track, point, 29.0): continue
		var forward: Vector3 = track.centerline_forward(arc)
		forward.y = 0.0
		forward = forward.normalized()
		var side := Vector3(forward.z, 0, -forward.x)
		var facility: Node3D = FACILITY.instantiate()
		facility.transform = Transform3D(Basis(-side, Vector3.UP, -forward), point)
		add_child(facility)
		facilities += 1
		break
	print("[L2样板] Sky3D日景已加载；Terrain3D外围丘陵=%d；Cyclops维修区/看台=%d（纯视觉、无新增植被）" % [hills, facilities])


func build_grid_marks(track: Node3D, cars: Array) -> void:
	const HALF_WIDTH := 1.4
	const PAINT_WIDTH := 0.12
	const REAR := -2.3
	const SIDE_LENGTH := 3.7
	var paint := SurfaceTool.new()
	paint.begin(Mesh.PRIMITIVE_TRIANGLES)
	var start: float = track.start_finish_t * track.road_length()
	for car: Node3D in cars:
		var nearest: Dictionary = track.nearest_on_centerline(car.global_position, start)
		var arc: float = nearest.arc
		var frame: Transform3D = track.surface_frame(arc)
		var lateral := (car.global_position - frame.origin).dot(frame.basis.x)
		# 开口朝起跑线，三条线围住实际车位。
		var rear := arc + REAR
		_add_paint_strip(paint, track, Rect2(lateral - HALF_WIDTH, rear, HALF_WIDTH * 2.0, PAINT_WIDTH))
		_add_paint_strip(paint, track, Rect2(lateral - HALF_WIDTH, rear + PAINT_WIDTH, PAINT_WIDTH, SIDE_LENGTH))
		_add_paint_strip(paint, track, Rect2(lateral + HALF_WIDTH - PAINT_WIDTH, rear + PAINT_WIDTH, PAINT_WIDTH, SIDE_LENGTH))
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("e8e7df")
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	var grid := MeshInstance3D.new()
	grid.name = "StartingGridPaint"
	grid.mesh = paint.commit()
	grid.material_override = material
	grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(grid)


func _add_paint_strip(paint: SurfaceTool, track: Node3D, strip: Rect2) -> void:
	var corners := [
		strip.position, Vector2(strip.end.x, strip.position.y),
		strip.end, Vector2(strip.position.x, strip.end.y),
	]
	for i in [0, 1, 2, 0, 2, 3]:
		var corner: Vector2 = corners[i]
		var frame: Transform3D = track.surface_frame(corner.y, corner.x)
		paint.set_normal(frame.basis.y)
		paint.add_vertex(frame.origin + frame.basis.y * 0.012)
