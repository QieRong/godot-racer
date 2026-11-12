extends SceneTree
## 同场景旧/新/旧/新灯池耗时对照；原weather/30秒门不在这里改判据。
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var output := ""
var legacy_script := ""

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output=arg.trim_prefix("--evidence-dir=")
		if arg.begins_with("--legacy-light-script="): legacy_script=arg.trim_prefix("--legacy-light-script=")
	call_deferred("run")

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
	if current_scene==null or state.phase_name()!="RACING" or legacy_script.is_empty(): quit(1);return
	var scene := current_scene
	var car: VehicleBody3D=scene.get_node("RaceCar")
	car.freeze=true
	car.set_physics_process(false)
	var current: Node3D=scene.get_node("TrackScenery/StreetLighting")
	var legacy: Node3D=load(legacy_script).new()
	current.get_parent().add_child(legacy)
	legacy.setup(current.get("_mounts"),current.get("_targets"),car)
	var rows: Array[Dictionary]=[]
	for mode in ["old","new","old","new"]:
		legacy.visible=mode=="old"
		legacy.set_process(mode=="old")
		current.visible=mode=="new"
		current.set_process(mode=="new")
		for i in range(120): await physics_frame
		var started := Time.get_ticks_usec()
		var physics := 0.0
		var process := 0.0
		for i in range(600):
			await physics_frame
			physics+=Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
			process+=Performance.get_monitor(Performance.TIME_PROCESS)
		var seconds := float(Time.get_ticks_usec()-started)/1000000.0
		var row := {"mode":mode,"ticks":600,"wall_seconds":seconds,"achieved_hz":600.0/seconds,
			"mean_physics_ms":physics/0.6,"mean_process_ms":process/0.6}
		rows.append(row)
		print("RAIN_TIMING_SAMPLE ",JSON.stringify(row))
	FileAccess.open(output.path_join("timing.json"),FileAccess.WRITE).store_string(JSON.stringify(rows,"\t"))
	var ids := AudioExit.capture_tree(scene)
	current_scene=null
	scene.free()
	var drained := await AudioExit.wait_all_released(self,ids)
	print("RAIN_TIMING_PROBE_COMPLETE drained=",drained)
	quit(0 if drained else 1)
