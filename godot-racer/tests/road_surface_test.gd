extends SceneTree
## 五关道路主题、白色起点线以及雨夜独立时钟涟漪的真实渲染检查。
var output := ""
var single_level := -1
var passed := 0
var failed := 0
const THEMES := ["training","sunny","rain","sand","snow"]

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
		if arg.begins_with("--single-level="): single_level=int(arg.trim_prefix("--single-level="))
	call_deferred("run")

func check(ok: bool, description: String) -> void:
	if ok: passed+=1
	else: failed+=1
	print("ROAD_ASSERT %s %s" % ["PASS" if ok else "FAIL",description])

func picture(label: String) -> Image:
	await create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(output.path_join(label+".png"))
	return image

func run() -> void:
	var state := root.get_node("GameState")
	state.settings_path=output.path_join("settings.cfg")
	for level in range(5):
		if single_level>=0 and level!=single_level: continue
		state.chosen_level=level
		change_scene_to_file("res://scenes/main.tscn")
		var deadline := Time.get_ticks_msec()+50000
		while current_scene==null or state.phase_name()!="RACING":
			await process_frame
			if Time.get_ticks_msec()>deadline: break
		check(current_scene!=null and state.phase_name()=="RACING","L%d 实际装配发车" % (level+1))
		if current_scene==null or state.phase_name()!="RACING": quit(1);return
		var scene := current_scene
		var track: Node3D = scene.get_node("Track")
		for car in scene.find_children("*","VehicleBody3D",true,false):
			car.set_physics_process(false);car.freeze=true
		var road: MeshInstance3D = track.find_child("RoadMesh",true,false)
		var material := road.material_override as ShaderMaterial
		check(material!=null and str(material.get_meta("road_theme",""))==THEMES[level],
			"L%d 路面材质匹配关卡主题" % (level+1))
		var line: MeshInstance3D = track.find_child("StartLine",true,false)
		var line_material := line.material_override as StandardMaterial3D
		check(line_material!=null and line_material.shading_mode==BaseMaterial3D.SHADING_MODE_UNSHADED
			and minf(line_material.albedo_color.r,minf(line_material.albedo_color.g,line_material.albedo_color.b))>0.8,
			"L%d 起点线保持独立白色材质" % (level+1))
		var center: Vector3 = track.centerline_point(0.0)
		check(line.global_position.y>center.y+track.road_lift,"L%d 白线高于路面，未被新材质覆盖" % (level+1))
		await create_timer(2.0).timeout
		DisplayServer.window_set_size(Vector2i(1280,720))
		var start_image := await picture("L%d-road-start-720" % (level+1))
		var camera: Camera3D = scene.get_node("ChaseCamera")
		# 60%横向位置会被并排AI的前轮/车头挡住；90%仍在白线内，避开起跑车位。
		var line_point: Vector3 = line.global_position+line.global_basis.x.normalized()*track.road_half_width()*0.9
		var road_point: Vector3 = line_point+track.centerline_forward(0.0)*3.0-Vector3.UP*0.01
		var line_pixel := camera.unproject_position(line_point)
		var road_pixel := camera.unproject_position(road_point)
		var paint := start_image.get_pixel(clampi(roundi(line_pixel.x),0,1279),clampi(roundi(line_pixel.y),0,719))
		var surface := start_image.get_pixel(clampi(roundi(road_pixel.x),0,1279),clampi(roundi(road_pixel.y),0,719))
		var contrast := paint.get_luminance()-surface.get_luminance()
		print("ROAD_PAINT_SAMPLE L%d paint=%s road=%s colors=%s/%s" % [level+1,line_pixel,road_pixel,paint,surface])
		check(contrast>0.10,"L%d 实际白线比紧邻路面亮，亮度差%.3f" % [level+1,contrast])
		if level==2 and material!=null:
			var player: VehicleBody3D = scene.get_node("RaceCar")
			player.get_node("WeatherParticles").visible=false
			camera.set_process(false)
			material.set_shader_parameter("ripple_clock",0.2)
			var first := await picture("rain-ripple-clock-a")
			material.set_shader_parameter("ripple_clock",0.9)
			var second := await picture("rain-ripple-clock-b")
			var changed := 0
			for y in range(420,560):
				for x in range(830,1060):
					var a := first.get_pixel(x,y)
					var b := second.get_pixel(x,y)
					if Vector3(a.r-b.r,a.g-b.g,a.b-b.b).length()>1.0/255.0: changed+=1
			check(changed>20,"雨夜只切换涟漪时钟，路面局部产生实际变化：%d像素" % changed)
			material.set_shader_parameter("ripple_clock",-1.0)
		state.enter_menu();current_scene=null;scene.free();await process_frame
	var music := state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	preload("res://scripts/theme_sky.gd").clear_cached_textures()
	await process_frame
	await RenderingServer.frame_post_draw
	print("ROAD_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
