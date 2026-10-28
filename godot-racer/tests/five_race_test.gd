extends SceneTree
const Observer := preload("res://tests/fixed_actor_observer.gd")
const Driver := preload("res://tests/fixed_player_driver.gd")
var output := ""
var level := 0
var passed := 0
var failed := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
		if arg.begins_with("--level="): level = int(arg.trim_prefix("--level="))
	call_deferred("run")

func check(ok: bool, text: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("FIVE_RACE_ASSERT %s %s" % ["PASS" if ok else "FAIL", text])

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = level
	state.ai_enabled = true
	state.settings_path = output.path_join("settings.cfg")
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec() + 50000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and state.phase_name() == "RACING": break
	check(current_scene != null and state.phase_name() == "RACING", "实际装配倒计时进入RACING")
	if failed > 0: quit(1); return
	var scene := current_scene
	var track: Node3D = scene.get_node("Track")
	var player: VehicleBody3D = scene.get_node("RaceCar")
	var opponents: Array = scene.get("_opponents")
	check(opponents.size() == 1, "一台真实AI对手")
	if failed > 0: quit(1); return
	var driver := Driver.new()
	driver.pilot = scene.get("_autopilot"); driver.car = player
	driver.track = track; driver.state = state; driver.last_pos = player.global_position
	driver.process_priority = -100
	scene.add_child(driver)
	var observers: Array = []
	for actor in [player, opponents[0]]:
		var path := output.path_join("player" if actor == player else "ai")
		DirAccess.make_dir_recursive_absolute(path)
		var geometry: Array = []
		for i in range(int(track.road_length()) + 1):
			var p: Vector3 = track.centerline_point(float(i)); geometry.append([p.x,p.y,p.z])
		var gates: Array = []
		for gate in track.get_children():
			if gate is Area3D:
				var p: Vector3 = gate.global_position
				var f: Vector3 = gate.global_basis.z
				gates.append({"order": gate.order_index,"pos":[p.x,p.y,p.z],"forward":[f.x,f.y,f.z]})
		var shape: BoxShape3D = actor.get_node("BodyCollision").shape
		FileAccess.open(path.path_join("actual-road.json"),FileAccess.WRITE).store_string(JSON.stringify({
			"centerline":geometry,"gates":gates,"length":track.road_length(),"layout":track.layout,
			"half_width":track.road_half_width(),"body_half_width":shape.size.x/2.0,
			"body_half_length":shape.size.z/2.0,"physics_hz":Engine.physics_ticks_per_second,
			"target_laps":state.current_level().laps_to_finish,"level":level+1,"actor":"player" if actor==player else "ai"}))
		var observer := Observer.new()
		observer.setup(actor,track,state,path,actor==player); scene.add_child(observer); observers.append(observer)
	deadline = Time.get_ticks_msec() + 650000
	if OS.get_cmdline_user_args().has("--accelerated"): Engine.max_fps = 0
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if observers[0].done or observers[1].stop_reason == "rescue": break
	check(observers[0].done and observers[0].stop_reason == "complete", "玩家通过正式输入完成目标圈数")
	# 玩家先完赛会按正式规则冻结全场；AI完整两圈由单独只读测试验证。
	check(opponents[0].rescue_count() == 0 and opponents[0].laps_done() >= 1, "对手无自救且至少完成一圈；完整AI轨迹另验")
	check(driver.recovery_frames == 0, "玩家全程零恢复接管")
	check(state.phase_name() == "FINISHED", "实际进入结算相位")
	FileAccess.open(output.path_join("race-summary.json"),FileAccess.WRITE).store_string(JSON.stringify({
		"player_reason":observers[0].stop_reason,"ai_reason":observers[1].stop_reason,
		"recovery_frames":driver.recovery_frames,"phase":state.phase_name(),
		"player_laps":player.laps_done,"ai_laps":opponents[0].laps_done(),"finish_snapshot":state.finish_snapshot},"  "))
	if DisplayServer.get_name() != "headless":
		await create_timer(0.8, true).timeout
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("finish.png"))
	state.release_drive_input()
	paused = false
	var music := state.find_child("MenuMusic", false, false)
	if music != null: await music.shutdown_and_wait()
	current_scene = null
	scene.free()
	await process_frame
	await process_frame
	print("FIVE_RACE_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed == 0 else 1)
