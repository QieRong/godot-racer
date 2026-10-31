extends RefCounted
## 五关独立美术清单。固定本地种子仅控制装饰，不消费比赛随机数，不生成碰撞。
## 规格：模型、簇数、横向距离范围、缩放范围、原始XZ包围半径、每簇成员、层次。
const THEMES := {
	"training": [
		["barracks_hut_01",16,25.0,100.0,1.2,1.7,5.0,1,"middle"],
		["training_storage_shed_01",12,30.0,120.0,1.2,1.8,2.9,1,"middle"],
		["training_watchtower_01",12,110.0,250.0,1.7,2.5,2.5,1,"far"]],
	"sunny": [
		["country_house_01",16,27.0,110.0,1.2,1.7,5.4,1,"middle"],
		["small_barn_01",12,35.0,130.0,1.2,1.8,4.7,1,"middle"],
		["farm_windmill_01",12,110.0,260.0,1.8,2.8,2.5,1,"far"]],
	"rain": [
		["city_building_low_01",20,27.0,110.0,1.0,1.8,5.6,1,"middle"],
		["city_building_mid_01",16,110.0,250.0,1.8,3.0,6.7,1,"far"],
		["bus_shelter_01",12,18.0,65.0,1.0,1.25,2.2,1,"middle"],
		["electrical_cabinet_01",12,18.0,65.0,1.0,1.25,0.6,1,"middle"],
		["vending_machine_blank_01",12,18.0,65.0,1.0,1.25,0.8,1,"middle"],
		["konbini_aoi_01",9,24.0,27.0,1.0,1.0,9.3,1,"middle"]],
	"sand": [
		["sandstone_boulder",24,22.0,95.0,1.0,3.0,2.0,3,"near"],
		["desert_cactus_01",12,30.0,110.0,0.8,1.5,0.9,2,"near"],
		["ruin_wall_01",7,45.0,130.0,1.2,2.5,2.7,2,"middle"],
		["desert_rock_arch_01",7,70.0,160.0,1.5,2.8,6.0,1,"middle"],
		["desert_mesa_01",10,180.0,290.0,2.5,4.0,16.2,1,"far"],
		["desert_cliff_module_01",10,160.0,290.0,3.0,5.0,8.3,1,"far"]],
	"snow": [
		["ice_boulder_01",10,30.0,100.0,1.0,2.0,1.6,2,"near"],
		["snow_cabin_01",8,55.0,160.0,1.0,1.4,4.5,1,"middle"],
		["snow_mountain_ridge_01",12,180.0,300.0,2.4,3.6,30.0,1,"far"]]
}

static func theme_key(cfg: Resource) -> String:
	if cfg.weather_type!="clear": return cfg.weather_type
	return "training" if cfg.display_name=="新兵训练营" else "sunny"

static func groups(track: Node3D, cfg: Resource, reserved: Array[Vector4] = []) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var occupied: Array[Vector4] = []
	var key := theme_key(cfg)
	if key == "training": occupied.assign(reserved)
	var specs: Array = THEMES.get(key,[])
	for index in range(specs.size()):
		var spec: Array = specs[index]
		# GLB按用户要求仅本地保留；公开代码缺私有模型时继续使用已有基础布景。
		if not ResourceLoader.exists("res://models/environment/%s.glb" % spec[0]): continue
		var rng := RandomNumberGenerator.new()
		rng.seed=27641+key.hash()+index*7937
		var placements: Array[Transform3D] = []
		var target: int = int(spec[1])*int(spec[7])
		for attempt in range(target*30):
			if placements.size()>=target: break
			# 每簇重新选择二维中心；簇内偏移，绝不复制为另一侧的镜像排。
			var arc: float = rng.randf()*track.road_length()
			var lateral: float = rng.randf_range(spec[2],spec[3])*(-1.0 if rng.randf()<0.5 else 1.0)
			if key in ["training","sunny","rain"] and spec[8]=="middle" and attempt<6:
				var fractions := [0.018,0.25,0.60,0.10,0.42,0.82]
				arc=fposmod(float(fractions[attempt])*track.road_length()+float(index)*22.0,track.road_length())
				lateral=(track.rail_half_width()+20.0+float(index)*9.0+rng.randf_range(0,6)) \
					*(-1.0 if (attempt+index)%2==0 else 1.0)
			if key=="rain" and index>=2 and attempt<8:
				# 设施围绕八个独立街角组团，不沿整圈等距铺成两排。
				var stops := [0.015,0.095,0.23,0.39,0.52,0.68,0.82,0.94]
				arc=float(stops[attempt])*track.road_length()+float(index-2)*3.5
				lateral=(track.rail_half_width()+8.0+float(index-2)*2.0+rng.randf_range(0,2)) \
					*(-1.0 if attempt%2==0 else 1.0)
			if key=="rain" and index==0 and attempt<8:
				# 左侧42/122/173m形成连续纵深；右侧74m错位，后四栋仍分布在全圈。
				var blocks := [42.0,74.0,122.0,173.0,0.23*track.road_length(),
					0.41*track.road_length(),0.64*track.road_length(),0.83*track.road_length()]
				arc=float(blocks[attempt])
				var left := attempt in [0,2,3,4,6]
				lateral=(track.rail_half_width()+16.0+rng.randf_range(0,5))*(1.0 if left else -1.0)
			if key=="rain" and spec[0]=="konbini_aoi_01":
				# 九个沿圈街角，左五右四；每个位置小范围寻空，不做对门或镜像排布。
				var slot := placements.size()
				var offsets := [0.0,4.0,-4.0,8.0,-8.0,12.0,-12.0,16.0,-16.0]
				arc=fposmod(74.0+float(slot)*track.road_length()/9.0 \
					+float(offsets[attempt%offsets.size()]),track.road_length())
				lateral=(track.rail_half_width()+16.0+rng.randf_range(0,2.0)) \
					*(1.0 if slot%2==0 else -1.0)
			var center: Vector3 = track.scenery_ground_point(arc,lateral)
			var members := rng.randi_range(1,int(spec[7]))
			for member in range(members):
				if placements.size()>=target: break
				var position := center
				if member>0: position+=Vector3(rng.randf_range(-12,12),0,rng.randf_range(-12,12))
				var factor: float = rng.randf_range(spec[4],spec[5])
				if key=="rain" and index==0 and attempt<2: factor=1.65
				var radius: float = float(spec[6])*factor
				var near: Dictionary = track.nearest_on_centerline(position,-1.0)
				var required: float = track.rail_half_width()+radius+5.0
				if spec[8]=="far": required+=45.0
				if float(near.dist)<required: continue
				if not _ground_covers(track,position,radius): continue
				var overlaps := false
				for other in occupied:
					if Vector2(other.x-position.x,other.z-position.z).length()<other.w+radius+1.0:
						overlaps=true;break
				if overlaps: continue
				occupied.append(Vector4(position.x,position.y,position.z,radius))
				var yaw := rng.randf_range(-PI,PI)
				if key=="rain" and (index<2 or spec[0]=="konbini_aoi_01"):
					# 源GLB入口与窗户在-Z面，面向最近赛道并保留小角度错落。
					var toward: Vector3 = near.pos-position
					yaw=atan2(-toward.x,-toward.z)+yaw*(0.025 if spec[0]=="konbini_aoi_01" else 0.06)
				var basis := Basis(Vector3.UP,yaw).scaled(Vector3.ONE*factor)
				placements.append(Transform3D(basis,position))
		result.append({"asset":spec[0],"tier":spec[8],"placements":placements,"radius":spec[6],
			"visibility":950.0 if spec[8]=="far" else 450.0})
	return result

static func _ground_covers(track: Node3D, point: Vector3, radius: float) -> bool:
	var ground := track.find_child("GroundMesh",true,false) as MeshInstance3D
	if ground==null: return false
	var local: Vector3 = ground.to_local(point)
	var bounds := ground.mesh.get_aabb()
	return local.x-radius>bounds.position.x and local.x+radius<bounds.end.x \
		and local.z-radius>bounds.position.z and local.z+radius<bounds.end.z

static func matte_mesh(node: MeshInstance3D, theme: String) -> Mesh:
	# 只复制装饰网格/材质；当前光照下的白色镜面亮斑会吞掉岩石与雪帽层次。
	var mesh := node.mesh.duplicate() as ArrayMesh
	for surface in range(mesh.get_surface_count()):
		var source := node.get_active_material(surface) as StandardMaterial3D
		if source==null: continue
		var material := source.duplicate() as StandardMaterial3D
		material.metallic=0.0
		material.metallic_texture=null
		material.roughness=1.0
		material.specular_mode=BaseMaterial3D.SPECULAR_DISABLED
		var factor := 0.33 if theme in ["training","sunny"] else 0.40
		if theme=="rain": factor=0.55
		material.albedo_color=source.albedo_color*Color(factor,factor,factor,1.0)
		if theme=="training":
			match source.resource_name:
				"cream": material.albedo_color=Color(0.38,0.35,0.27)
				"olive": material.albedo_color=Color(0.20,0.25,0.23)
				"concrete": material.albedo_color=Color(0.31,0.33,0.30)
				"glass": material.albedo_color=Color(0.12,0.18,0.19)
		if theme=="rain" and source.resource_name=="glass":
			material.albedo_color=Color(0.13,0.18,0.23)
		mesh.surface_set_material(surface,material)
	return mesh
