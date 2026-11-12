extends SceneTree
const AudioExit := preload("res://tests/audio_exit_probe.gd")
## 只读定位装配阶段：30秒原判据不变，不改装配、车辆、AI或倒计时时序。
var output := ""
var level := 2
var started := 0
var next_sample := 0
var rows: Array[Dictionary] = []
var hide_scenery := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
		if arg.begins_with("--level="): level = int(arg.trim_prefix("--level="))
		if arg == "--probe-hide-scenery": hide_scenery = true
	if hide_scenery:
		node_added.connect(func(node: Node):
			if node.name == "TrackScenery": node.visible = false)
	call_deferred("run")

func sample() -> void:
	var state := root.get_node("GameState")
	var scene := current_scene
	var track: Node = scene.get_node_or_null("Track") if scene != null else null
	var scenery: Node3D = scene.get_node_or_null("TrackScenery") if scene != null else null
	var row := {"wall_ms": Time.get_ticks_msec()-started,
		"physics_frames": Engine.get_physics_frames(), "process_frames": Engine.get_process_frames(),
		"phase": state.phase_name(), "paused": paused,
		"setup": scene.get("_setup_done") if scene != null else null,
		"world_ready": track.is_world_ready() if track != null else false,
		"ai_count": scene.get("_opponents").size() if scene != null else 0,
		"fps": Engine.get_frames_per_second(),
		"scenery_visible": scenery.visible if scenery != null else null,
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)}
	rows.append(row)
	print("LOADING_SAMPLE ", JSON.stringify(row))

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = level
	state.settings_path = output.path_join("settings.cfg")
	started = Time.get_ticks_msec()
	change_scene_to_file("res://scenes/main.tscn")
	while Time.get_ticks_msec()-started < 30000:
		await process_frame
		if Time.get_ticks_msec() >= next_sample:
			sample()
			next_sample = Time.get_ticks_msec()+2000
		if current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING": break
	sample()
	var ready: bool = current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING"
	FileAccess.open(output.path_join("loading.json"), FileAccess.WRITE).store_string(JSON.stringify(rows, "\t"))
	paused = false
	var music := state.find_child("MenuMusic", false, false)
	if music != null: await music.shutdown_and_wait()
	var active := current_scene
	var audio_ids := AudioExit.capture_tree(active)
	current_scene = null
	if active != null: active.free()
	var drained := await AudioExit.wait_all_released(self, audio_ids)
	print("LOADING_AUDIO_DRAINED=", drained)
	print("LOADING_PROBE_COMPLETE READY=", ready)
	quit(0 if ready and drained else 1)
