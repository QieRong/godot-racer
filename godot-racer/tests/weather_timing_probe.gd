extends SceneTree
## 只读计时诊断：同一雨夜场景灯光开/关/开，保留全部样本，不替代原天气判据。
var output := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level=2
	state.settings_path=output.path_join("settings.cfg")
	change_scene_to_file("res://scenes/main.tscn")
	var deadline:=Time.get_ticks_msec()+40000
	while Time.get_ticks_msec()<deadline:
		await process_frame
		if current_scene!=null and state.phase_name()=="RACING": break
	if current_scene==null or state.phase_name()!="RACING": quit(1);return
	var scene:=current_scene
	# 静止观察必须同时关闭控制器；仅freeze会诱发AI卡住自救，污染灯光计时。
	for node in scene.find_children("*","VehicleBody3D",true,false):
		node.set_physics_process(false)
		node.freeze=true
	var pool: Node=scene.get_node("TrackScenery/StreetLighting")
	var samples: Array=[]
	for enabled in [true,false,true]:
		pool.set_process(false)
		for light in pool.get_children(): light.visible=enabled
		for i in range(120): await physics_frame
		var start:=Time.get_ticks_usec()
		var physics_sum:=0.0
		var process_sum:=0.0
		var fps_sum:=0.0
		for i in range(1200):
			await physics_frame
			physics_sum+=Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
			process_sum+=Performance.get_monitor(Performance.TIME_PROCESS)
			fps_sum+=Performance.get_monitor(Performance.TIME_FPS)
		var seconds:=float(Time.get_ticks_usec()-start)/1000000.0
		var row: Dictionary={"lights_enabled":enabled,"ticks":1200,"wall_s":seconds,
			"achieved_hz":1200.0/seconds,"mean_physics_ms":physics_sum/1.2,
			"mean_process_ms":process_sum/1.2,"mean_fps_monitor":fps_sum/1200.0}
		samples.append(row)
		print("WEATHER_TIMING_SAMPLE ",JSON.stringify(row))
	FileAccess.open(output.path_join("weather-timing.json"),FileAccess.WRITE).store_string(JSON.stringify(samples,"  "))
	var music:=state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	current_scene=null
	scene.free()
	await process_frame
	print("WEATHER_TIMING_COMPLETE")
	quit(0)
