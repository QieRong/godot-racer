extends "res://tests/scenery_dressing_test.gd"
## 完整雨夜入口截图：不隐藏雨粒子，不切换光照，不冻结光池刷新。
func _initialize() -> void:
	single_level=2
	super._initialize()

func inspect_groups(dressing: Node3D, track: Node3D, level: int) -> void:
	super.inspect_groups(dressing,track,level)
	var counts: Dictionary = {}
	var directions: Dictionary = {}
	var frontage: Array = []
	var aligned := true
	for group in dressing.get_children():
		var first: Mesh
		var count := 0
		for batch in group.get_children():
			if first==null: first=batch.multimesh.mesh
			if batch.multimesh.mesh==first:
				count+=batch.multimesh.instance_count
				if str(group.name).begins_with("city_building"):
					for i in range(batch.multimesh.instance_count):
						var xf: Transform3D = batch.global_transform*batch.multimesh.get_instance_transform(i)
						var yaw := atan2(xf.basis.z.x,xf.basis.z.z)
						directions[floori(fposmod(yaw,TAU)/(PI*0.5))]=true
						# 两种源GLB的门窗均在-Z面，检查真实装配后的正面而非仅检查yaw分散。
						var nearest: Dictionary = track.nearest_on_centerline(xf.origin,-1.0)
						var toward: Vector3 = nearest.pos-xf.origin
						toward.y=0.0
						var dot := (-xf.basis.z).normalized().dot(toward.normalized())
						aligned=aligned and dot>=cos(deg_to_rad(18.0))
						frontage.append({"asset":str(group.name),"position":str(xf.origin),"facing_dot":dot})
		counts[str(group.name)]=count
	for asset in ["bus_shelter_01","electrical_cabinet_01","vending_machine_blank_01"]:
		check(int(counts.get(asset,0))==12,"正常雨夜实际装配12件 "+asset)
	check(directions.size()==4,"楼体实际朝向覆盖四象限，正面/侧面/转角错落")
	check(aligned and frontage.size()==36,"36栋楼的门窗正面朝向最近赛道，偏角不超过18度")
	check(int(counts.get("city_building_low_01",0))==20 and int(counts.get("city_building_mid_01",0))==16,
		"保留20栋低楼和16栋中楼，不靠增加模型总量填空")
	var scene := track.get_parent()
	var particles: GPUParticles3D = scene.get_node("RaceCar/WeatherParticles")
	check(particles.visible and particles.emitting and particles.amount==700,"正常入口保留700粒可见发射雨丝")
	var center: Vector3 = track.centerline_point(0.0)
	var forward: Vector3 = track.centerline_forward(0.0)
	var side := Vector3(forward.z,0,-forward.x).normalized()
	var near_sides := Vector2i.ZERO
	var left_depths: Array[float] = []
	var group: Node = dressing.get_node("city_building_low_01")
	var first: Mesh
	for batch in group.get_children():
		if first==null: first=batch.multimesh.mesh
		if batch.multimesh.mesh!=first: continue
		for i in range(batch.multimesh.instance_count):
			var point: Vector3 = (batch.global_transform*batch.multimesh.get_instance_transform(i)).origin
			var delta := point-center
			var depth := delta.dot(forward)
			# side为驾驶方向左侧；限定道路旁，排除远处或回程赛段的楼体充数。
			if depth>=20.0 and depth<=180.0 and delta.dot(side)>0 and delta.dot(side)<70.0:
				left_depths.append(depth)
			if delta.dot(forward)>20 and delta.dot(forward)<110:
				if delta.dot(side)>0: near_sides.x+=1
				else: near_sides.y+=1
	check(near_sides.x>0 and near_sides.y>0,"起点左右均有20-110m纵深的近景楼体")
	left_depths.sort()
	var layered := left_depths.size()>=3
	if layered:
		layered=left_depths[-1]-left_depths[0]>=100.0
		for i in range(1,left_depths.size()): layered=layered and left_depths[i]-left_depths[i-1]<=85.0
	check(layered,"左侧20-180m至少三栋错落楼体，纵深跨度至少100m且空档不超过85m")
	FileAccess.open(output.path_join("rain-normal.json"),FileAccess.WRITE).store_string(
		JSON.stringify({"counts":counts,"near_sides":str(near_sides),"rain_visible":particles.visible,
			"frontage":frontage,"left_depths":left_depths},"  "))

func capture(label: String) -> void:
	await super.capture(label)
	if label=="L3-start-720":
		DisplayServer.window_set_size(Vector2i(1920,1080))
		await super.capture("L3-start-1080")
		DisplayServer.window_set_size(Vector2i(1280,720))
