extends "res://tests/rain_reflection_test.gd"
## 正式场景：前方未驶近的灯已真实参与路面/涟漪，四灯预算及后视保留。
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var far_road_polygon := PackedVector2Array()

func difference(a: Image,b: Image) -> Dictionary:
	var changed := 0
	var total := 0.0
	var region := Rect2i(400,330,700,230)
	for y in range(region.position.y,region.end.y):
		for x in range(region.position.x,region.end.x):
			var d := absf(a.get_pixel(x,y).get_luminance()-b.get_pixel(x,y).get_luminance())
			if d>1.0/255.0: changed+=1
			total+=d
	return {"changed":changed,"mean":total/region.get_area()}

func far_difference(a: Image,b: Image,c: Image=null,d: Image=null) -> Dictionary:
	var changed := 0
	var luminance_changed := 0
	var pixels := 0
	var total := 0.0
	var bounds := Rect2(far_road_polygon[0],Vector2.ZERO)
	for point in far_road_polygon: bounds=bounds.expand(point)
	for y in range(maxi(0,int(bounds.position.y)),mini(a.get_height(),ceili(bounds.end.y))):
		for x in range(maxi(0,int(bounds.position.x)),mini(a.get_width(),ceili(bounds.end.x))):
			if not Geometry2D.is_point_in_polygon(Vector2(x+0.5,y+0.5),far_road_polygon): continue
			var delta := a.get_pixel(x,y).get_luminance()-b.get_pixel(x,y).get_luminance()
			if c!=null: delta-=c.get_pixel(x,y).get_luminance()-d.get_pixel(x,y).get_luminance()
			if absf(delta)>1.0/255.0: luminance_changed+=1
			# 与原rain_reflection_test一致：RGB向量差>1/255；同时保留亮度差诊断。
			var rgb := Vector3(a.get_pixel(x,y).r-b.get_pixel(x,y).r,
				a.get_pixel(x,y).g-b.get_pixel(x,y).g,a.get_pixel(x,y).b-b.get_pixel(x,y).b)
			if c!=null:
				rgb-=Vector3(c.get_pixel(x,y).r-d.get_pixel(x,y).r,
					c.get_pixel(x,y).g-d.get_pixel(x,y).g,c.get_pixel(x,y).b-d.get_pixel(x,y).b)
			if rgb.length()>1.0/255.0: changed+=1
			total+=absf(delta)
			pixels+=1
	return {"changed":changed,"luminance_changed":luminance_changed,"pixels":pixels,
		"mean_luminance_delta":total/maxi(1,pixels),"bounds":str(bounds)}

func active(pool: Node) -> Array[SpotLight3D]:
	var result: Array[SpotLight3D]=[]
	for child in pool.get_children():
		if child is SpotLight3D and child.visible: result.append(child)
	return result

func key(code: Key,down: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode=code
	event.keycode=code
	event.pressed=down
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level=2
	state.ai_enabled=false
	state.settings_path=output.path_join("settings.cfg")
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec()+30000
	while Time.get_ticks_msec()<deadline:
		await process_frame
		if current_scene!=null and current_scene.get("_setup_done") and state.phase_name()=="RACING": break
	check(current_scene!=null and state.phase_name()=="RACING","真实L3装配与GO")
	if failed>0: quit(1);return
	var scene := current_scene
	for layer in scene.find_children("*","CanvasLayer",true,false): layer.visible=false
	var car: VehicleBody3D=scene.get_node("RaceCar")
	car.freeze=true
	car.set_physics_process(false)
	car.get_node("WeatherParticles").visible=false
	var camera: Camera3D=scene.get_node("ChaseCamera")
	var track: Node3D=scene.get_node("Track")
	var pool: Node=scene.get_node("TrackScenery/StreetLighting")
	var material: ShaderMaterial=track.find_child("RoadMesh",true,false).material_override
	car.global_position=track.centerline_point(16.0)+Vector3.UP*0.55
	car.global_basis=Basis.looking_at(track.centerline_forward(16.0),Vector3.UP)
	camera.call("set_view_mode",1)
	for i in range(12): await process_frame
	pool.call("_refresh")
	pool.set_process(false)
	camera.set_process(false)
	check(active(pool).size()==4 and pool.get_child_count()==4,"仍只使用四盏真实道路灯")
	var ahead: Array[SpotLight3D]=[]
	for light in active(pool):
		var direction: Vector3=track.centerline_forward(16.0)
		if (light.global_position-car.global_position).dot(direction)>60.0: ahead.append(light)
	check(ahead.size()==2,"距离车前方60m以上的一对灯提前启用")
	if not ahead.is_empty():
		var near: Dictionary=track.nearest_on_centerline(ahead[0].global_position)
		# 由实际远灯落点附近的道路投影确定ROI，只量路面，排除楼体和天空。
		for corner in [Vector2(-12,-0.75),Vector2(-12,0.75),Vector2(12,0.75),Vector2(12,-0.75)]:
			var surface: Transform3D=track.surface_frame(float(near.arc)+corner.x,track.road_half_width()*corner.y)
			far_road_polygon.append(camera.unproject_position(surface.origin+Vector3.UP*0.03))
	material.set_shader_parameter("ripple_clock",0.2)
	var lit_a := await capture("preview-lamps-on-ripple-a")
	material.set_shader_parameter("ripple_clock",0.9)
	var lit_b := await capture("preview-lamps-on-ripple-b")
	material.set_shader_parameter("ripple_clock",0.2)
	for light in ahead: light.visible=false
	var unlit_a := await capture("far-lamps-off-ripple-a")
	material.set_shader_parameter("ripple_clock",0.9)
	var unlit_b := await capture("far-lamps-off-ripple-b")
	metrics["far_lamps"]=far_difference(lit_a,unlit_a)
	metrics["all_ripples"]=difference(lit_a,lit_b)
	check(int(metrics.far_lamps.changed)>100,"远灯提前对真实路面产生可测光照贡献")
	check(int(metrics.all_ripples.changed)>20,"提前受光时原法线涟漪有真实像素变化")
	metrics["far_lamp_ripples"]=far_difference(lit_a,lit_b,unlit_a,unlit_b)
	check(int(metrics.far_lamp_ripples.changed)>20,"远处路面涟漪变化确实由提前启用的远灯产生")
	metrics["without_far_ripples"]=difference(unlit_a,unlit_b)
	for light in ahead: light.visible=true
	material.set_shader_parameter("ripple_clock",-1.0)
	pool.set_process(true)
	camera.set_process(true)
	key(KEY_C,true)
	# 只观察下一次process；不能用等待0.2s掩盖后视延迟。
	await process_frame
	await RenderingServer.frame_post_draw
	check(float(pool.get("_view_sign"))<0.0,"C后视下一帧立即反向预备")
	key(KEY_C,false)
	for i in range(3): await process_frame
	check(float(pool.get("_view_sign"))>0.0,"C松开恢复前方预备")
	car.freeze=false
	car.set_physics_process(true)
	for i in range(120): await physics_frame
	var start_position := car.global_position
	key(KEY_W,true)
	var drive_deadline := Time.get_ticks_msec()+5000
	var max_active := 0
	while Time.get_ticks_msec()<drive_deadline:
		await physics_frame
		max_active=maxi(max_active,active(pool).size())
	key(KEY_W,false)
	for i in range(3): await physics_frame
	check(car.global_position.distance_to(start_position)>25.0 and car.linear_velocity.length()>5.0,
		"真实W输入行驶穿过选灯更新范围")
	check(max_active==4 and pool.get_child_count()==4,"真实行驶过程不扩张四灯预算")
	metrics["drive_meters"]=car.global_position.distance_to(start_position)
	car.freeze=true
	car.set_physics_process(false)
	for arc in [300.0,700.0,1500.0,track.road_length()-10.0]:
		car.global_position=track.centerline_point(arc)+Vector3.UP*0.55
		car.global_basis=Basis.looking_at(track.centerline_forward(arc),Vector3.UP)
		camera.call("set_view_mode",2)
		for i in range(4): await process_frame
		pool.call("_refresh")
		var preview: Vector3=pool.call("_preview_position")
		check(preview.distance_to(track.centerline_point(arc+40.0))<0.4,
			"弯道/坡面/闭环%.0fm沿最终中心线提前40m" % arc)
	FileAccess.open(output.path_join("preview.json"),FileAccess.WRITE).store_string(JSON.stringify({
		"passed":passed,"failed":failed,"metrics":metrics},"\t"))
	var ids := AudioExit.capture_tree(scene)
	current_scene=null
	scene.free()
	check(await AudioExit.wait_all_released(self,ids),"音频回执真实回收")
	print("RAIN_PREVIEW_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
