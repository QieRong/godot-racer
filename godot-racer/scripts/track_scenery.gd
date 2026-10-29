extends Node3D
## 主题美术沿最终中心线装配；只生成视觉实例，不另造道路或路中碰撞。
## GLB已由Blender检查米制尺寸。每类子网格合并成MultiMesh，限制draw call。
var asset_instances := 0
var _dressing_meshes: Dictionary = {}
var _store_focus: Node3D
var _store_batches: Array[Dictionary] = []
var _store_visibility_elapsed := 0.0
const SnowVisuals := preload("res://scripts/snow_visuals.gd")
const Dressing := preload("res://scripts/scenery_dressing.gd")

func build(track: Node3D, cfg: Resource) -> void:
	_store_focus=track.get_parent().get_node_or_null("RaceCar")
	_tint_ground(track, cfg)
	_configure_shadows(track, cfg)
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
	var footprints: Array[Vector4] = []
	var length: float = track.road_length()
	var count := mini(180, int(length / spacing))
	if cfg.weather_type=="sand": count=0 # 沙漠石头改为独立岩簇，取消旧双侧石列。
	var lamp_rng := RandomNumberGenerator.new()
	lamp_rng.seed=27483
	for i in range(count):
		var arc := float(i) * length / float(count)
		if asset=="street_lamp": arc=fposmod((float(i)+lamp_rng.randf_range(-0.25,0.25))*length/float(count),length)
		var f: Vector3 = track.centerline_forward(arc)
		# 路灯按固定横向距离成对布置；一侧靠近相邻路段时整对略过。
		var lamp_offset: float = track.road_half_width()+8.0
		if asset=="street_lamp": lamp_offset+=lamp_rng.randf_range(0.0,8.0)
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
	_stamp(asset,placements,null,350.0,Dressing.theme_key(cfg) if cfg.weather_type=="clear" else "")
	if asset == "street_lamp":
		var lighting := preload("res://scripts/street_lighting.gd").new()
		lighting.name = "StreetLighting"
		add_child(lighting)
		lighting.setup(placements,light_targets,track.get_parent().get_node_or_null("RaceCar"),
			track,track.get_parent().get_node_or_null("ChaseCamera"))
	asset_instances = placements.size()
	_build_markers(track)
	var delineators := preload("res://scripts/boundary_delineators.gd").new()
	delineators.name = "BoundaryDelineators"
	add_child(delineators)
	delineators.build(track)
	if cfg.weather_type == "snow":
		var banks := Node3D.new()
		banks.name = "SnowBanks"
		add_child(banks)
		var bank_placements := SnowVisuals.bank_placements(track)
		banks.set_meta("instance_count",bank_placements.size())
		_stamp("snow_pile_01",bank_placements,banks)
		for placement in bank_placements:
			footprints.append(Vector4(placement.origin.x,placement.origin.y,placement.origin.z,2.5))
		var forest := Node3D.new()
		forest.name = "SnowForest"
		add_child(forest)
		var forest_placements := SnowVisuals.forest_placements(track)
		forest.set_meta("instance_count",forest_placements.size())
		_stamp("snow_pine_01",forest_placements,forest)
		for placement in forest_placements:
			footprints.append(Vector4(placement.origin.x,placement.origin.y,placement.origin.z,4.0))
	var dressing := Node3D.new()
	dressing.name="SceneryDressing"
	dressing.set_meta("theme",Dressing.theme_key(cfg))
	add_child(dressing)
	for placement in placements:
		footprints.append(Vector4(placement.origin.x,placement.origin.y,placement.origin.z,4.0))
	for entry in Dressing.groups(track,cfg):
		var group := Node3D.new()
		group.name=entry.asset
		group.set_meta("tier",entry.tier)
		group.set_meta("asset",entry.asset)
		dressing.add_child(group)
		_stamp(entry.asset,entry.placements,group,entry.visibility,Dressing.theme_key(cfg))
		if entry.asset=="konbini_aoi_01":
			var shop_lighting := preload("res://scripts/konbini_lighting.gd").new()
			shop_lighting.name="KonbiniLighting"
			add_child(shop_lighting)
			shop_lighting.setup(entry.placements,track.get_parent().get_node_or_null("RaceCar"))
		asset_instances+=entry.placements.size()
		for placement in entry.placements:
			footprints.append(Vector4(placement.origin.x,placement.origin.y,placement.origin.z,
				float(entry.radius)*placement.basis.get_scale().x))
	var relief := preload("res://scripts/ground_relief.gd").new()
	relief.name="GroundRelief"
	add_child(relief)
	relief.build(track,cfg,footprints)
	_refresh_store_visibility()
	print("[主题] %s 实例%d MultiMesh子批次%d 无新增碰撞" % [asset, asset_instances, get_child_count()])

func _process(delta: float) -> void:
	_store_visibility_elapsed+=delta
	if _store_visibility_elapsed<0.2: return
	_store_visibility_elapsed=0.0
	_refresh_store_visibility()

func _refresh_store_visibility() -> void:
	if not is_instance_valid(_store_focus): return
	for entry in _store_batches:
		var visual: MultiMeshInstance3D = entry.visual
		var origins: Array = entry.origins
		var mask := 0
		for i in range(origins.size()):
			if visual.to_global(origins[i]).distance_squared_to(_store_focus.global_position)<450.0*450.0:
				mask|=1<<i
		if mask==int(entry.get("mask",-1)): continue
		entry.mask=mask
		var order: Array[int] = []
		for i in range(origins.size()):
			if mask&(1<<i): order.append(i)
		visual.multimesh.visible_instance_count=order.size()
		for i in range(origins.size()):
			if not mask&(1<<i): order.append(i)
		# 只重排可见前缀；全部原始变换仍在，进入距离后能完整恢复。
		for i in range(order.size()): visual.multimesh.set_instance_transform(i,entry.poses[order[i]])

func _tint_ground(track: Node3D, cfg: Resource) -> void:
	var road := track.find_child("RoadMesh", true, false) as MeshInstance3D
	if road != null and road.material_override is StandardMaterial3D:
		road.material_override.albedo_color = Color(0.32,0.36,0.4)
		road.material_override.roughness = 0.72 if cfg.weather_type == "rain" else 0.95
		if cfg.weather_type!="rain":
			road.material_override.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	var ground := track.find_child("GroundMesh", true, false) as MeshInstance3D
	if ground == null: return
	var material := ground.material_override as StandardMaterial3D
	if material == null: return
	match cfg.weather_type:
		"snow": SnowVisuals.tint_ground(material)
		"sand": material.albedo_color = Color(0.38,0.28,0.17)
		# 原铺装贴图本身很暗，不能再乘0.16，否则建筑周围成为近黑空场。
		"rain": material.albedo_color = Color(0.70,0.73,0.76)
		_: material.albedo_color = Color(0.13,0.21,0.10) if cfg.display_name == "新兵训练营" else Color(0.18,0.24,0.10)
	material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	material.metallic=0.0
	material.metallic_texture=null
	if cfg.weather_type=="rain":
		# 已有铺装接收店前局部暖光和镜面；方向补光镜面仍为0，不恢复第二太阳。
		material.specular_mode=BaseMaterial3D.SPECULAR_SCHLICK_GGX
		material.metallic_specular=0.35
		material.roughness=0.62
	var verges := track.find_child("ElevationVerges", false, false) as MeshInstance3D
	if verges != null and verges.material_override is StandardMaterial3D:
		verges.material_override.albedo_color = material.albedo_color
		verges.material_override.albedo_texture = material.albedo_texture
		verges.material_override.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
	preload("res://scripts/road_surface.gd").apply(track,cfg)


func _configure_shadows(track: Node3D, cfg: Resource) -> void:
	var sun := track.get_parent().get_node_or_null("Sun") as DirectionalLight3D
	var preview := track.get_node_or_null("Sun") as DirectionalLight3D
	if sun == null: return # Track独立预览仍使用自己的太阳。
	if preview != null:
		# 合并同方向预览光，保留原总照度与加权颜色，仅主太阳生成全场阴影。
		if cfg.weather_type != "rain":
			var energy := sun.light_energy + preview.light_energy
			if energy > 0.0:
				sun.light_color = (sun.light_color * sun.light_energy + preview.light_color * preview.light_energy) / energy
				sun.light_energy = energy
		preview.light_energy = 0.0
		preview.shadow_enabled = false
	sun.shadow_enabled = true
	# 雨夜在920MX冷缓存下四级级联拖慢首次装配；两级保留近景精度并减少绘制。
	# 保留150m覆盖、级联混合和冷色柔影，晴天/雪地沿用四级。
	sun.directional_shadow_mode = (DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		if cfg.weather_type == "rain" else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)
	sun.directional_shadow_max_distance = 150.0
	sun.directional_shadow_blend_splits = true
	# Compatibility支持的PCF柔化与透明度；环境冷色补光自然形成雨雪阴影底色。
	sun.shadow_opacity = 0.30 if cfg.weather_type == "rain" else (0.45 if cfg.weather_type == "snow" else 0.80)
	sun.shadow_blur = 2.0 if cfg.weather_type == "rain" else (1.6 if cfg.weather_type == "snow" else 1.0)

func _stamp(asset: String, placements: Array[Transform3D], destination: Node3D = null,
		visibility: float = 350.0, material_theme: String = "") -> void:
	var path := "res://models/environment/%s.glb" % asset
	if not ResourceLoader.exists(path): return
	var packed: PackedScene = load(path)
	if packed == null: return
	var model := packed.instantiate()
	var chunks: Dictionary = {}
	# 36件小设施合计3216三角面，逐160m分区反而放大为134批。
	# 小设施按源网格全关合批；便利店复用16批并另做实例距离筛选，保留全部九店数据。
	var small_street_prop := asset in ["bus_shelter_01","electrical_cabinet_01","vending_machine_blank_01","konbini_aoi_01"]
	for placement in placements:
		var key := Vector2i(floori(placement.origin.x / 160.0), floori(placement.origin.z / 160.0))
		if small_street_prop: key=Vector2i.ZERO
		if not chunks.has(key): chunks[key] = []
		chunks[key].append(placement)
	for key in chunks:
		var center := Vector3(key.x * 160.0 + 80.0, 0.0, key.y * 160.0 + 80.0)
		if small_street_prop: center=Vector3.ZERO
		var local_placements: Array[Transform3D] = []
		for placement in chunks[key]:
			local_placements.append(Transform3D(placement.basis, placement.origin - center))
		var tint_snow: bool = asset in ["snow_pine_tree","snow_pine_01","snow_pile_01"]
		_collect_meshes(model, Transform3D.IDENTITY, local_placements, center, tint_snow,destination,
			0.0 if small_street_prop else visibility,material_theme)
	model.free()

func _collect_meshes(node: Node, parent_transform: Transform3D, placements: Array[Transform3D],
		center: Vector3, snow_tree: bool = false, destination: Node3D = null,
		visibility: float = 350.0, material_theme: String = "") -> void:
	var local := parent_transform
	if node is Node3D: local = parent_transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.mesh = node.mesh
		var multi_surface_snow: bool = snow_tree and node.mesh.get_surface_count()>1
		if multi_surface_snow: batch.mesh = SnowVisuals.multi_surface_tree_mesh(node)
		if not material_theme.is_empty():
			var key := str(node.mesh.get_instance_id())+material_theme
			if not _dressing_meshes.has(key): _dressing_meshes[key]=Dressing.matte_mesh(node,material_theme)
			batch.mesh=_dressing_meshes[key]
		batch.instance_count = placements.size()
		for i in range(placements.size()): batch.set_instance_transform(i, placements[i] * local)
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = batch
		instance.material_override = SnowVisuals.tree_material(node) if snow_tree else node.material_override
		if multi_surface_snow: instance.material_override = null
		if not material_theme.is_empty(): instance.material_override=null
		instance.position = center
		instance.visibility_range_end = visibility
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if destination == null: add_child(instance)
		else: destination.add_child(instance)
		if destination!=null and destination.get_meta("asset","")=="konbini_aoi_01":
			var poses: Array[Transform3D] = []
			var origins: Array[Vector3] = []
			for i in range(placements.size()):
				poses.append(batch.get_instance_transform(i))
				origins.append(placements[i].origin)
			_store_batches.append({"visual":instance,"poses":poses,"origins":origins,"mask":-1})
	for child in node.get_children(): _collect_meshes(child, local, placements, center,
		snow_tree,destination,visibility,material_theme)

func _build_markers(track: Node3D) -> void:
	# 红白路缘由最终中心线采样，合批且在护栏内；没有影响车辆的第二套碰撞。
	var batches: Array[MultiMesh] = []
	for color in [Color(0.65,0.055,0.04), Color(0.65,0.66,0.64)]:
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.45, 0.06, 2.1)
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.9
		material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
		mesh.material = material
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.mesh = mesh
		batch.instance_count = 0
		batches.append(batch)
	var transforms: Array = [[], []]
	# 偶数段保证红白交替闭合；末段精确连接首点，不丢弃不足2m的尾段。
	var count := ceili(track.road_length()/2.0)
	if count%2!=0: count += 1
	for i in range(count):
		var arc_a: float = float(i)*track.road_length()/float(count)
		var arc_b: float = float(i+1)*track.road_length()/float(count)
		var p_a: Vector3 = track.centerline_point(arc_a)
		var p_b: Vector3 = track.centerline_point(arc_b)
		var f_a: Vector3 = track.centerline_forward(arc_a)
		var f_b: Vector3 = track.centerline_forward(arc_b)
		var side_a := Vector3(f_a.z,0.0,-f_a.x).normalized()
		var side_b := Vector3(f_b.z,0.0,-f_b.x).normalized()
		for sign_i in [-1.0, 1.0]:
			var a: Vector3 = p_a+side_a*sign_i*(track.road_half_width()-0.3)+Vector3.UP*0.045
			var b: Vector3 = p_b+side_b*sign_i*(track.road_half_width()-0.3)+Vector3.UP*0.045
			var direction := b-a
			var basis := Basis.looking_at(-direction.normalized(),Vector3.UP)
			basis.z *= direction.length()/2.1
			transforms[i%2].append(Transform3D(basis,(a+b)*0.5))
	for k in range(2):
		batches[k].instance_count = transforms[k].size()
		for i in range(transforms[k].size()): batches[k].set_instance_transform(i, transforms[k][i])
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = batches[k]
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		add_child(instance)
