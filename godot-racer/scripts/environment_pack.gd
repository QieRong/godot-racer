extends RefCounted
## 用户环境包：按实际米制尺寸布置路外地标，足迹交给原布景系统统一避让。
const Dressing := preload("res://scripts/scenery_dressing.gd")
const LEVELS := {"training":"L1", "sunny":"L2", "rain":"L3", "sand":"L4", "snow":"L5"}
## 依目录顺序给出[弧长m(0~1为圈长比例),路侧,坡脚外退距m]。
## L1单侧维修/教学对侧；L2起跑维修区、赛道中段观赛区和回程休息区。
const SITES := {
	"L1": [[30,1,15],[76,1,20],[0.28,-1,15],[0.56,1,20],[30,-1,15],
		[0.70,1,28],[0.42,-1,18],[0.84,1,18],[-18,-1,15],[112,1,32],[0.16,-1,10]],
	"L2": [[24,1,14],[85,-1,14],[-28,1,14],[88,1,14],[0.24,-1,14],
		[130,1,14],[0.48,1,24],[0.78,-1,14],[-15,-1,14],[0.84,-1,14],[-5,1,7]],
	# 雨夜街角商业/车间后院；遗迹驿站/发掘营；雪地救援/维修/补给点。
	"L3": [[35,1,16],[0.22,1,23],[12,-1,14],[0.41,-1,14],[0.68,1,16],
		[0.32,-1,16],[0.73,1,19],[0,1,0],[0.52,-1,75],[0.87,-1,16],[55,1,10]],
	"L4": [[35,1,18],[0.18,1,18],[0.12,1,22],[0.34,-1,18],[0.47,-1,22],
		[0.53,-1,18],[0.66,1,18],[0.38,-1,22],[0.83,1,18],[0.76,-1,28],[0.09,-1,12]],
	"L5": [[25,1,18],[66,1,18],[0.17,-1,18],[0.29,1,22],[0.68,1,18],
		[0.48,-1,28],[0.60,1,18],[0.78,-1,22],[0.88,1,18],[0.91,-1,18],[0.11,-1,12]],
}
const GROUND_COLORS := {"L1":Color("555646"), "L2":Color("787e78"),
	"L3":Color("373f4a"), "L4":Color(0.38,0.28,0.17), "L5":Color("7d8b91")}

static func groups(track: Node3D, cfg: Resource, reserved: Array[Vector4]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var catalog: Array = JSON.parse_string(FileAccess.get_file_as_string("res://models/environment/environment_pack.json"))
	var level: String = LEVELS[Dressing.theme_key(cfg)]
	var start: float = track.start_finish_t * track.road_length()
	var roof_frame := Transform3D.IDENTITY
	var has_roof := false
	var slot := 0
	for entry in catalog:
		if entry.level != level: continue
		# 原始模型在统一库；游戏同名副本按材质合并，保持几何、尺度和朝向。
		if not ResourceLoader.exists("res://models/environment/" + entry.file): continue
		var poses: Array[Transform3D] = []
		var dimensions: Array = entry.dimensions
		var natural: bool = "rock_cluster" in entry.id or "skyline" in entry.id or "rooftop" in entry.id
		var pad_size := Vector3(float(dimensions[0]) + 3.0, 0.12, float(dimensions[2]) + 5.0)
		if entry.id == "L3_08_rooftop_equipment_cluster":
			# 商业楼的平屋顶上表面为9.90m；设备不能落在地面或住宅内院上。
			if has_roof:
				poses.append(roof_frame * Transform3D(Basis.IDENTITY, Vector3(0,9.90,0)))
		else:
			var radius := Vector2(pad_size.x, pad_size.z).length() * 0.5 + 1.0
			var distance := _distance(slot, track.road_length())
			var sign_i := 1.0 if slot % 2 == 0 else -1.0
			var setback := 32.0
			if SITES.has(level):
				var site: Array = SITES[level][slot]
				distance = float(site[0]) * track.road_length() if float(site[0]) > 0.0 and float(site[0]) < 1.0 else float(site[0])
				sign_i = float(site[1])
				setback = float(site[2])
			var skyline: bool = entry.id == "L3_09_city_skyline_cluster"
			for attempt in range(48):
				var arc := start + distance
				if attempt < 24:
					arc += float((attempt + 1) / 2) * 19.0 * (1.0 if attempt % 2 == 0 else -1.0)
				else:
					arc += float(attempt - 23) * track.road_length() / 24.0
				var lateral: float = sign_i * (track.rail_half_width() + radius + setback
					+ float(attempt % 3) * 8.0 + (55.0 if skyline else 0.0))
				var point: Vector3 = track.scenery_ground_point(arc, lateral)
				var near: Dictionary = track.nearest_on_centerline(point, -1.0)
				# 建筑整块基底放在路肩坡脚以外的平地；同时避开相邻的另一段赛道。
				var toe: float = track.rail_half_width() + maxf(12.0, Vector3(near.pos).y * 2.0 + 5.0)
				if float(near.dist) < toe + radius + 4.0: continue
				if not Dressing._ground_covers(track, point, radius): continue
				if Dressing.overlaps(point, radius, reserved): continue
				var toward: Vector3 = Vector3(near.pos) - point
				var frame := Transform3D(Basis(Vector3.UP, atan2(-toward.x, -toward.z)), point)
				poses.append(frame)
				reserved.append(Vector4(point.x, point.y, point.z, radius))
				if entry.id == "L3_01_corner_commercial_block":
					roof_frame = frame
					has_roof = true
				break
		if poses.is_empty():
			push_warning("[环境包] 未找到安全摆放位置: " + str(entry.id))
		result.append({"asset":str(entry.id), "placements":poses, "tier":"far" if slot == 8 else "middle",
			"visibility":750.0 if slot == 8 else 500.0, "pad_size":Vector3.ZERO if natural else pad_size,
			"pad_color":GROUND_COLORS[level]})
		slot += 1
	return result

static func add_apron(parent: Node3D, entry: Dictionary) -> void:
	if entry.pad_size == Vector3.ZERO or entry.placements.is_empty(): return
	var mesh := BoxMesh.new()
	mesh.size = entry.pad_size
	var material := StandardMaterial3D.new()
	material.albedo_color = entry.pad_color
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mesh.material = entry.get("ground_material", material)
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = mesh
	multi.instance_count = entry.placements.size()
	for i in range(entry.placements.size()):
		# 地坪顶面略埋入地面，前方留出3m门前场坪；不改地形或道路碰撞。
		multi.set_instance_transform(i, entry.placements[i] * Transform3D(Basis.IDENTITY, Vector3(0,-0.04,-1.0)))
	var apron := MultiMeshInstance3D.new()
	apron.name = "FacilityApron"
	apron.multimesh = multi
	apron.visibility_range_end = entry.visibility
	parent.add_child(apron)

static func _distance(slot: int, length: float) -> float:
	# 起点赛事区集中展示前五件，其余沿圈设置独立节点，保持主题间的留白。
	var near_slots := [20.0, 80.0, -45.0, 155.0, 225.0]
	if slot < near_slots.size(): return near_slots[slot]
	if slot == 10: return -85.0
	return length * (0.30 + float(slot - 5) * 0.13)
