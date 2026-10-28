extends "res://tests/rain_normal_preview.gd"
## 正常雨夜入口、九间路边错位店铺与真实照地对照；不改变正式灯光设置。
var shops: Array[Transform3D] = []

func inspect_groups(dressing: Node3D, track: Node3D, level: int) -> void:
	super.inspect_groups(dressing,track,level)
	var group := dressing.get_node_or_null("konbini_aoi_01")
	check(group!=null,"正常雨夜便利店已装配")
	if group==null: return
	var first: Mesh
	var arcs: Array[float] = []
	var left := 0
	var aligned := true
	for batch in group.get_children():
		if first==null: first=batch.multimesh.mesh
		if batch.multimesh.mesh!=first: continue
		for i in range(batch.multimesh.instance_count):
			var xf: Transform3D = batch.global_transform*batch.multimesh.get_instance_transform(i)
			shops.append(xf)
			var near: Dictionary = track.nearest_on_centerline(xf.origin,-1.0)
			arcs.append(near.arc)
			var toward: Vector3 = near.pos-xf.origin
			toward.y=0
			aligned=aligned and (-xf.basis.z).normalized().dot(toward.normalized())>=cos(deg_to_rad(8.0))
			var forward: Vector3 = near.forward
			if (xf.origin-Vector3(near.pos)).dot(Vector3(forward.z,0,-forward.x))>0: left+=1
	arcs.sort()
	var gap := INF
	for i in range(arcs.size()):
		gap=minf(gap,fposmod(arcs[(i+1)%arcs.size()]-arcs[i],track.road_length()))
	check(shops.size()==9 and left==5,"全圈恰好九间，左五右四错位，没有成对镜像")
	check(aligned,"九间店门面均朝向最近赛道内侧，偏角<=8度")
	var roadside := true
	for shop in shops:
		var nearest: Dictionary = track.nearest_on_centerline(shop.origin,-1.0)
		roadside=roadside and float(nearest.dist)>=track.rail_half_width()+9.3+5.0 \
			and float(nearest.dist)<=track.rail_half_width()+18.1
	check(roadside,"九间店均靠近路边，保留模型半径和5m道路/护栏净空")
	check(gap>=250.0,"便利店沿圈最小间隔>=250m：%.1f" % gap)
	var pool := track.get_parent().get_node("TrackScenery/KonbiniLighting")
	check(pool.get_child_count()==2 and pool.get_child(0) is SpotLight3D
		and pool.get_child(1) is OmniLight3D,"九间店共用两盏近车灯：檐灯与室内暖灯")
	var rain: GPUParticles3D = track.get_parent().get_node("RaceCar/WeatherParticles")
	check(rain.draw_pass_1.material.shading_mode==BaseMaterial3D.SHADING_MODE_PER_VERTEX,
		"正常700粒雨丝接收真实局部灯光")
	FileAccess.open(output.path_join("konbini-scene.json"),FileAccess.WRITE).store_string(
		JSON.stringify({"count":shops.size(),"left":left,"arcs":arcs,"minimum_gap":gap,"aligned":aligned},"  "))

func capture(label: String) -> void:
	await super.capture(label)
	if label!="L3-start-720" or shops.is_empty(): return
	var scene := current_scene
	var camera := Camera3D.new()
	scene.add_child(camera)
	var store := shops[0]
	camera.global_position=store*Vector3(17,8,-21)
	camera.look_at(store*Vector3(0,1.8,-0.5),Vector3.UP)
	camera.fov=48
	camera.make_current()
	var player: Node3D = scene.get_node("RaceCar")
	var old_position := player.global_position
	player.global_position=store*Vector3(0,0.6,-8)
	await create_timer(0.6).timeout
	DisplayServer.window_set_size(Vector2i(1280,720))
	await super.capture("konbini-close-720")
	DisplayServer.window_set_size(Vector2i(1920,1080))
	await super.capture("konbini-close-1080")
	# 同机位稳定雨粒子/涟漪时间，比较真实檐灯开关；不把关灯图当正式入口。
	var lamp: SpotLight3D = scene.get_node("TrackScenery/KonbiniLighting/WarmCanopyPool")
	var owner := lamp.get_parent()
	owner.set_process(false)
	var was_visible := lamp.visible
	check(was_visible,"近店玩家使真实暖灯池激活")
	var direction := -lamp.global_basis.z
	var hit: Vector3 = lamp.global_position+direction*(-lamp.global_position.y/direction.y)
	var local_hit: Vector3 = store.affine_inverse()*hit
	check(direction.y<0 and local_hit.z < -4.0 and absf(local_hit.x)<6.0
		and lamp.global_position.distance_to(hit)<lamp.spot_range,
		"真实檐灯光轴落在店前已有地面且位于射程内")
	check(lamp.light_color.r>lamp.light_color.b and lamp.light_specular<=0.1 and not lamp.shadow_enabled,
		"檐灯暖色、局部柔和反光且不增加实时阴影")
	lamp.visible=false
	await super.capture("konbini-light-off-diagnostic-1080")
	lamp.visible=was_visible
	var interior: OmniLight3D = owner.get_node("WarmInteriorPool")
	check(interior.visible and interior.omni_range<=8.0 and not interior.shadow_enabled,
		"近店真实室内灯有界、激活且无实时阴影")
	var rain: GPUParticles3D = player.get_node("WeatherParticles")
	var old_speed := rain.speed_scale
	rain.speed_scale=0.0
	await create_timer(0.2).timeout
	await RenderingServer.frame_post_draw
	var interior_on := root.get_texture().get_image()
	interior_on.save_png(output.path_join("konbini-interior-on-1080.png"))
	interior.visible=false
	await create_timer(0.2).timeout
	await RenderingServer.frame_post_draw
	var interior_off := root.get_texture().get_image()
	interior_off.save_png(output.path_join("konbini-interior-off-diagnostic-1080.png"))
	# 固定玻璃橱窗投影区；冻结雨粒子，像素变化来自室内灯开关，排除招牌自发光。
	var lower := Vector2(INF,INF)
	var upper := -lower
	for x in [-5.3,5.3]:
		for y in [0.65,2.65]:
			var point: Vector2 = camera.unproject_position(store*Vector3(x,y,-3.6))
			lower=lower.min(point);upper=upper.max(point)
	var region := Rect2i(Vector2i(lower),Vector2i(upper-lower)).intersection(Rect2i(0,0,1920,1080))
	var changed := 0
	var response := 0.0
	for y in range(region.position.y,region.end.y):
		for x in range(region.position.x,region.end.x):
			var delta := interior_on.get_pixel(x,y).get_luminance()-interior_off.get_pixel(x,y).get_luminance()
			if delta>1.0/255.0: changed+=1
			response+=delta
	check(changed>100 and response>0.0,"室内灯实际照亮玻璃后的货架/商品/收银区域：%d像素" % changed)
	FileAccess.open(output.path_join("konbini-interior-light.json"),FileAccess.WRITE).store_string(
		JSON.stringify({"changed_pixels":changed,"luminance_sum_delta":response,"region":str(region)},"  "))
	interior.visible=true
	rain.speed_scale=old_speed
	owner.set_process(true)
	player.global_position=old_position
	camera.queue_free()
	scene.get_node("ChaseCamera").make_current()
	DisplayServer.window_set_size(Vector2i(1280,720))
