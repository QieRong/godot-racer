extends SceneTree
## L3真实场景音频交互/生命周期；不代替听音与原30秒冷启动门。
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var output := ""
var passed := 0
var failed := 0
var car: VehicleBody3D
var camera: Camera3D
var player: AudioStreamPlayer3D
var rain: AudioStreamPlayer
var samples: Array[Dictionary] = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("PLAYER_ENGINE_RUNTIME_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func frames(count: int) -> void:
	for i in range(count): await process_frame

func key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func wait_racing(old_id := 0) -> bool:
	var deadline := Time.get_ticks_msec()+30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.get_instance_id() != old_id:
			if current_scene.get("_setup_done") and root.get_node("GameState").phase_name() == "RACING": return true
	return false

func mount_players() -> void:
	car = current_scene.get_node("RaceCar")
	camera = current_scene.get_node("ChaseCamera")
	player = car.get_node("EngineSound")
	rain = car.get_node("RainAmbient")

func capture_state(label: String) -> void:
	samples.append({"label": label, "mode": camera.get("_mode"), "rear": camera.get("_rear_active"),
		"engine_receipt": AudioExit.capture(player), "rain_receipt": AudioExit.capture(rain),
		"engine_db": player.volume_db, "pitch": player.pitch_scale, "rain_position": rain.get_playback_position(),
		"speed_kmh": car.linear_velocity.length()*3.6, "synth_frames": current_scene.get("_engine_audio").frames_pushed})

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = 2
	state.ai_enabled = false
	state.settings_path = output.path_join("settings.cfg")
	change_scene_to_file("res://scenes/main.tscn")
	check(await wait_racing(), "L3真实装配与GO（本专项暖缓存，不充当冷启动复核）")
	if failed > 0: quit(1); return
	mount_players()
	await create_timer(2.0).timeout
	var engine_id := AudioExit.capture(player)
	var rain_id := AudioExit.capture(rain)
	var rain_pos := rain.get_playback_position()
	var synth_before: int = current_scene.get("_engine_audio").frames_pushed
	for mode in range(3):
		camera.call("set_view_mode", mode)
		await frames(3)
		key(KEY_C, true)
		await frames(3)
		check(camera.get("_rear_active"), "视角%d真实C进入后视" % mode)
		key(KEY_C, false)
		key(KEY_V, true)
		key(KEY_V, false)
		await frames(3)
		check(not camera.get("_rear_active") and int(camera.get("_mode")) == (mode+1)%3, "V切镜且C释放恢复")
		check(AudioExit.capture(player) == engine_id and AudioExit.capture(rain) == rain_id,
			"V/C复用引擎与单一雨声Playback")
		capture_state("view%d" % mode)
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output.path_join("view%d.png" % mode))
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_RIGHT
	mouse.pressed = true
	Input.parse_input_event(mouse)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(100, 40)
	Input.parse_input_event(motion)
	await frames(3)
	check(absf(float(camera.get("_yaw"))) > 0.1 and AudioExit.capture(player) == engine_id,
		"真实鼠标环视不重播本车引擎")
	mouse.pressed = false
	Input.parse_input_event(mouse)
	check(rain.get_playback_position() > rain_pos, "连续切镜雨声位置前进而非回零")
	check(int(current_scene.get("_engine_audio").frames_pushed) > synth_before, "切镜期间生成器持续续填")
	check(state.pause_race(), "真实暂停入口")
	await frames(4)
	check(rain.stream_paused and player.stream_paused, "暂停引擎与雨声")
	check(state.resume_race(), "真实恢复入口")
	await frames(4)
	check(not rain.stream_paused and player.playing and rain.playing
		and AudioExit.capture(player) == engine_id and AudioExit.capture(rain) == rain_id,
		"恢复复用原引擎/雨声回执")
	key(KEY_W, true)
	await create_timer(1.0).timeout
	key(KEY_W, false)
	capture_state("drive_then_release")
	key(KEY_R, true)
	await frames(1)
	key(KEY_R, false)
	await frames(6)
	check(AudioExit.capture(player) == engine_id and AudioExit.capture(rain) == rain_id,
		"真实R安全回退不重播音源")
	check(car.find_children("RainAmbient", "AudioStreamPlayer", false, false).size() == 1,
		"R与切镜不叠加雨声节点")
	var old_scene_id := current_scene.get_instance_id()
	var old_audio_ids := AudioExit.capture_tree(current_scene)
	car = null
	camera = null
	player = null
	rain = null
	state.restart_race()
	check(await wait_racing(old_scene_id), "真实重试成功")
	check(await AudioExit.wait_all_released(self, old_audio_ids), "重试释放旧局全部音频回执")
	if failed > 0: quit(1); return
	mount_players()
	check(player.attenuation_model == AudioStreamPlayer3D.ATTENUATION_DISABLED
		and is_equal_approx(player.panning_strength, 0.15), "新局保持玩家混音配置")
	check(car.find_children("RainAmbient", "AudioStreamPlayer", false, false).size() == 1, "重试只有一条雨声")
	var ids := AudioExit.capture_tree(current_scene)
	car = null
	camera = null
	player = null
	rain = null
	state.back_to_menu()
	await frames(6)
	check(state.phase_name() == "MENU", "真实返回首页")
	check(await AudioExit.wait_all_released(self, ids), "返回首页实际回收比赛全部回执")
	FileAccess.open(output.path_join("audio-runtime.json"), FileAccess.WRITE).store_string(JSON.stringify(samples, "\t"))
	var music := state.find_child("MenuMusic", false, false)
	if music != null: check(await music.shutdown_and_wait(), "首页BGM实际回收后退出")
	var menu := current_scene
	current_scene = null
	if menu != null: menu.free()
	print("PLAYER_ENGINE_RUNTIME_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
