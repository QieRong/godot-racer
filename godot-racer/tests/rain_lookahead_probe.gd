extends SceneTree
## 诊断夹具：同一固定相机/路面，选灯中心原位与赛道前40m对照；不改生产规则。
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var output := ""
var metrics: Array[Dictionary] = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func capture(label: String) -> Image:
	for i in range(4): await process_frame
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	picture.save_png(output.path_join(label+".png"))
	return picture

func difference(a: Image,b: Image) -> Dictionary:
	var count := 0
	var total := 0.0
	var peak := 0.0
	# 排除左侧HUD、天空与近车；观察前方路面。
	var region := Rect2i(400,330,700,230)
	for y in range(region.position.y,region.end.y):
		for x in range(region.position.x,region.end.x):
			var d := absf(a.get_pixel(x,y).get_luminance()-b.get_pixel(x,y).get_luminance())
			if d>1.0/255.0: count+=1
			total+=d
			peak=maxf(peak,d)
	return {"region":str(region),"changed":count,"mean":total/region.get_area(),"peak":peak}

func positions(pool: Node) -> Array[Vector3]:
	var result: Array[Vector3]=[]
	for light in pool.get_children():
		if light is SpotLight3D and light.visible: result.append(light.global_position)
	return result

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
	if current_scene==null or state.phase_name()!="RACING": quit(1);return
	var scene := current_scene
	# GO文案会随时间淡出；隐藏全部测试外UI，避免把叠层动画误认为路面差异。
	for layer in scene.find_children("*","CanvasLayer",true,false): layer.visible=false
	var car: VehicleBody3D=scene.get_node("RaceCar")
	car.freeze=true
	car.set_physics_process(false)
	car.get_node("WeatherParticles").visible=false
	var camera: Camera3D=scene.get_node("ChaseCamera")
	camera.toast_enabled=false
	var toast: CanvasLayer=camera.get_node_or_null("ViewToastLayer")
	if toast!=null: toast.visible=false
	var track: Node3D=scene.get_node("Track")
	var pool: Node=scene.get_node("TrackScenery/StreetLighting")
	pool.set_process(false)
	var focus := Node3D.new()
	scene.add_child(focus)
	var material: ShaderMaterial=track.find_child("RoadMesh",true,false).material_override
	material.set_shader_parameter("ripple_clock",0.2)
	for arc in [16.0,40.0,72.0,104.0]:
		car.global_position=track.centerline_point(arc)+Vector3.UP*0.55
		car.global_basis=Basis.looking_at(track.centerline_forward(arc),Vector3.UP)
		camera.call("set_view_mode",1)
		for i in range(10): await process_frame
		camera.set_process(false)
		pool.set("_focus",car)
		pool.call("_refresh")
		var before_positions := positions(pool)
		var before := await capture("arc%d-original" % int(arc))
		focus.global_position=track.centerline_point(arc+40.0)
		pool.set("_focus",focus)
		pool.call("_refresh")
		var after_positions := positions(pool)
		var after := await capture("arc%d-forward40" % int(arc))
		material.set_shader_parameter("ripple_clock",0.9)
		var ripples := await capture("arc%d-forward40-ripple-b" % int(arc))
		material.set_shader_parameter("ripple_clock",0.2)
		var row := {"arc":arc,"original_lamps":before_positions,"preview_lamps":after_positions,
			"preview_delta":difference(before,after),"preview_ripple_delta":difference(after,ripples)}
		metrics.append(row)
		print("RAIN_LOOKAHEAD_SAMPLE ",JSON.stringify(row))
		camera.set_process(true)
	FileAccess.open(output.path_join("lookahead.json"),FileAccess.WRITE).store_string(JSON.stringify(metrics,"\t"))
	var ids := AudioExit.capture_tree(scene)
	current_scene=null
	scene.free()
	var drained := await AudioExit.wait_all_released(self,ids)
	print("RAIN_LOOKAHEAD_PROBE_COMPLETE drained=",drained)
	quit(0 if drained else 1)
