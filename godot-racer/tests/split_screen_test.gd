extends SceneTree
## 定向双人场景验证；冲线使用事件夹具，不冒充两人自然完整两圈。
var passed := 0
var failed := 0
var state: Node
var evidence := ""

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	if value: passed += 1
	else: failed += 1
	print("SPLIT_%s %s" % ["PASS" if value else "FAIL", label])

func key(code: int, pressed: bool, location := KEY_LOCATION_UNSPECIFIED) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.location = location
	event.pressed = pressed
	Input.parse_input_event(event)

func wait_phase(expected: String, seconds := 35.0) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000)
	while state.phase_name() != expected and Time.get_ticks_msec() < end:
		await process_frame
	check(state.phase_name() == expected, "phase_" + expected)
	return state.phase_name() == expected

func canvas(size: Vector2i) -> void:
	root.content_scale_size = size
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	await process_frame
	await process_frame

func shot(name: String) -> void:
	if evidence.is_empty(): return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(evidence.path_join(name + ".png"))

func inside(node: Control, bounds: Rect2) -> bool:
	return bounds.encloses(node.get_global_rect())

func run() -> void:
	state = root.get_node("GameState")
	state.record_results_enabled = false
	state.race_variants_enabled = false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): evidence = arg.trim_prefix("--evidence-dir=")
	if OS.get_cmdline_user_args().has("--window-only"):
		check(state.window_size == Vector2i(1100, 620), "window_choice_restored_cross_process")
		check(DisplayServer.window_get_size() == Vector2i(1100, 620), "native_window_restored_size")
		check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED and root.get_visible_rect().size == Vector2(root.size), "render_tracks_native_window")
		print("WINDOW_RESULT passed=%d failed=%d" % [passed, failed])
		quit(0 if failed == 0 else 1)
		return
	if OS.get_cmdline_user_args().has("--weather-only"):
		await weather_run()
		return
	check(root.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED, "native_window_render_size")
	var display := load("res://scripts/display_settings.gd")
	var sizes := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(1024, 768)]
	for size in sizes:
		var initial: Vector2i = display.initial_window_size(size)
		check(initial.x <= size.x * 0.91 and initial.y <= size.y * 0.91 and absf(float(initial.x) / initial.y - 16.0 / 9.0) < 0.01, "auto_window_" + str(size))
	var kept: Rect2i = display.resolve_window_rect(Vector2i(1100, 620), Vector2i.ZERO, Vector2i(2560, 1400))
	check(kept.size == Vector2i(1100, 620), "preserve_saved_window")
	change_scene_to_file("res://scenes/menu.tscn")
	await process_frame
	await process_frame
	var menu := current_scene
	menu._home.start_requested.emit()
	check(menu._mode_page.visible and not menu._home.visible, "home_opens_mode_cards")
	check(menu._mode_page.find_child("ModeCard3", true, false).disabled, "lan_explicitly_unavailable")
	for size in sizes:
		await canvas(size)
		var bounds := Rect2(Vector2.ZERO, Vector2(size))
		check(inside(menu._mode_page.find_child("ModeCard3", true, false), bounds), "mode_layout_" + str(size))
		await shot("modes-%dx%d" % [size.x, size.y])
	menu._mode_page.find_child("ModeCard2", true, false).pressed.emit()
	check(state.split_screen and not state.endless_mode and state.effective_ai_count() == 0, "select_split_without_ai_or_endless")
	check(menu._start.text == "开始双人分屏", "split_start_label")
	menu._on_level_focus(1)
	await shot("level-select")
	menu._on_start_pressed()
	if not await wait_phase("INTRO", 70.0): quit(1); return
	var main := current_scene
	var split: Node = main._split_screen
	check(split != null and split.cars.size() == 2 and main._opponents.is_empty(), "two_humans_one_world_no_ai")
	check(main._ghost_trace == null and split._photo != null, "no_ghost_and_shared_photo_connected")
	check(split.cars[0].global_position.distance_to(split.cars[1].global_position) > 2.0, "separate_start_slots")
	main._race_intro._finish()
	await process_frame
	check(not is_instance_valid(split._guide) and state.phase_name() == "COUNTDOWN" and paused
		and split.cars[0].freeze and split.cars[1].freeze, "intro_flows_directly_to_countdown")
	if not await wait_phase("RACING", 12.0): quit(1); return
	check(split._display.find_child("SplitDivider", true, false) != null, "visible_center_divider")
	var first: VehicleBody3D = split.cars[0]
	var second: VehicleBody3D = split.cars[1]
	check(not first.start_locked and not second.start_locked and first._lap_start_ms == second._lap_start_ms, "same_go_and_lap_clock")
	for size in sizes:
		await canvas(size)
		var bounds_ok := true
		for i in range(2):
			var view: SubViewport = split.views[i]
			var data: Dictionary = split._readouts[i]
			var scale_factor: float = data.layer.transform.get_scale().x
			var local_bounds := Rect2(Vector2.ZERO, Vector2(view.size) / scale_factor)
			bounds_ok = bounds_ok and absf(float(view.size.x) - (size.x - 4) / 2.0) < 2.0
			for item in [data.panel, data.rank, data.speed, data.notice]: bounds_ok = bounds_ok and inside(item, local_bounds)
		check(bounds_ok, "half_view_hud_" + str(size))
		await create_timer(0.6).timeout
		await shot("split-%dx%d" % [size.x, size.y])
	# 在最窄测试画布验证独立提示、翻译与实际变换后的视口边界。
	var warning := TranslationServer.translate("逆向行驶 · 请调整方向")
	for driver in range(2):
		split.cars[driver].wrong_way = true
		split.cars[1 - driver].wrong_way = false
		split._process(0.0)
		var label: Label = split._readouts[driver].notice
		var other: Label = split._readouts[1 - driver].notice
		var view: SubViewport = split.views[driver]
		var drawn := label.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, label.size)
		check(label.text == warning and other.text.is_empty() and label.get_viewport() == view
			and Rect2(Vector2.ZERO, Vector2(view.size)).encloses(drawn), "wrong_way_isolated_p%d" % (driver + 1))
		split.cars[driver].wrong_way = false
	await canvas(Vector2i(1280, 720))
	key(KEY_W, true)
	await create_timer(0.8).timeout
	check(first.linear_velocity.length() > 1.0 and second.linear_velocity.length() < 0.2, "p1_throttle_does_not_drive_p2")
	key(KEY_W, false)
	key(KEY_UP, true)
	await create_timer(0.8).timeout
	check(second.linear_velocity.length() > 1.0 and not Input.is_action_pressed("p1_accelerate"), "p2_throttle_independent")
	key(KEY_A, true)
	key(KEY_RIGHT, true)
	await create_timer(0.1).timeout
	check(first.steering > 0.0 and second.steering < 0.0, "opposite_steering_simultaneously")
	key(KEY_A, false)
	key(KEY_RIGHT, false)
	key(KEY_CTRL, true, KEY_LOCATION_RIGHT)
	await create_timer(0.1).timeout
	check(Input.is_action_pressed("p2_handbrake") and not Input.is_action_pressed("p1_handbrake") and second._braking, "p2_right_control_handbrake")
	key(KEY_CTRL, false, KEY_LOCATION_RIGHT)
	var initial_mode: int = split.cameras[0]._mode
	key(KEY_ENTER, true)
	await process_frame
	await process_frame
	key(KEY_ENTER, false)
	check(split.cameras[1]._mode != initial_mode and split.cameras[0]._mode == initial_mode, "p2_view_key_isolated")
	key(KEY_SHIFT, true, KEY_LOCATION_RIGHT)
	await process_frame
	await process_frame
	check(split.cameras[1]._rear_active and not split.cameras[0]._rear_active, "p2_rear_view_isolated")
	key(KEY_SHIFT, false, KEY_LOCATION_RIGHT)
	key(KEY_UP, false)
	var resets := [0, 0]
	first.trajectory_discontinuity.connect(func(): resets[0] += 1)
	second.trajectory_discontinuity.connect(func(): resets[1] += 1)
	key(KEY_BACKSPACE, true)
	await process_frame
	key(KEY_BACKSPACE, false)
	check(resets == [0, 1], "p2_reset_isolated")
	key(KEY_R, true)
	await process_frame
	key(KEY_R, false)
	check(resets == [1, 1], "p1_reset_isolated")
	var pause_button: Button = split._display.find_child("SharedPause", true, false)
	var at := pause_button.get_global_rect().get_center()
	var click := InputEventMouseButton.new()
	click.position = at
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	root.push_input(click, true)
	await process_frame
	click = click.duplicate()
	click.pressed = false
	root.push_input(click, true)
	await process_frame
	check(state.phase_name() == "PAUSED", "click_shared_pause")
	if state.phase_name() != "PAUSED": main.get_node("PauseMenu").pause()
	var time_before: float = state.race_total_time()
	var poses := [first.global_transform, second.global_transform]
	await create_timer(0.2).timeout
	check(state.race_total_time() == time_before and first.global_transform == poses[0] and second.global_transform == poses[1], "pause_freezes_both_cars_and_clock")
	main.get_node("PauseMenu").find_child("SplitControls", true, false).pressed.emit()
	check(is_instance_valid(split._guide), "pause_can_reopen_controls")
	await shot("pause-controls")
	key(KEY_ESCAPE, true)
	await process_frame
	key(KEY_ESCAPE, false)
	check(not is_instance_valid(split._guide) and state.phase_name() == "PAUSED", "close_controls_stays_paused")
	main.get_node("PauseMenu").resume()
	check(not Input.is_action_pressed("p1_accelerate") and not Input.is_action_pressed("p2_accelerate"), "resume_clears_both_inputs")
	# P2先完赛，验证不会因P1作为旧主玩家而提前冻结/错误判胜。
	second.linear_velocity = -second.global_basis.z * 20.0
	finish_fixture(second)
	check(second.freeze and second.linear_velocity.is_zero_approx() and not first.freeze, "p2_stops_at_finish_immediately")
	await process_frame
	var rows: Array = main._race_position.standings()
	var winner_time: float = rows[0].total
	check(state.phase_name() == "RACING" and second.finish_input_locked and not first.finish_input_locked and rows[0].id == "p2", "p2_finishes_first_p1_keeps_racing")
	await create_timer(0.15).timeout
	check(split._readouts[1].total.text.contains(split._time(winner_time)) and state.race_total_time() > winner_time, "winner_time_fixed_other_clock_continues")
	finish_fixture(first)
	await process_frame
	await process_frame
	check(state.phase_name() == "FINISHED" and state.finish_snapshot.entrants[0].id == "p2", "both_finished_authoritative_order")
	var finish: Node = main.get_children().filter(func(n): return n.get_script() == load("res://scripts/finish_menu.gd"))[0]
	check(finish._title_text().contains("P2") and not state.finish_snapshot.has("new_record") and not state.finish_snapshot.has("completion_saved"), "winner_title_no_single_records")
	await shot("split-result-p2-wins")
	state.restart_race()
	if not await wait_phase("INTRO", 70.0): quit(1); return
	main = current_scene
	main._race_intro._finish()
	await process_frame
	check(state.phase_name() == "COUNTDOWN" and not is_instance_valid(main._split_screen._guide), "retry_fresh_cars_skip_guide")
	if not await wait_phase("RACING", 12.0): quit(1); return
	check(not main._split_screen.cars[0].finish_input_locked and not main._split_screen.cars[1].finish_input_locked, "retry_resets_both_finish_locks")
	state.back_to_menu()
	await process_frame
	await process_frame
	menu = current_scene
	menu._select_mode(0)
	check(not state.split_screen and not state.endless_mode and state.effective_ai_count() > 0, "back_to_single_restores_ai_preference")
	menu._on_level_focus(1)
	menu._on_start_pressed()
	if not await wait_phase("INTRO", 70.0): quit(1); return
	main = current_scene
	check(main._split_screen == null and main._car.input_prefix.is_empty() and main._ghost_trace != null and main._photo_finish != null, "single_player_path_preserved")
	main._race_intro._finish()
	if not await wait_phase("RACING", 12.0): quit(1); return
	key(KEY_W, true)
	await create_timer(0.5).timeout
	check(main._car.linear_velocity.length() > 0.5, "single_player_keyboard_still_drives")
	key(KEY_W, false)
	await create_timer(0.6).timeout
	for size in sizes:
		await canvas(size)
		var bounds := Rect2(Vector2.ZERO, Vector2(size))
		var fits := true
		for label in [main._hud._speed_label, main._hud._time_label, main._hud._lap_label, main._hud._total_label]:
			fits = fits and bounds.encloses(label.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, label.size))
		check(fits, "single_hud_layout_" + str(size))
		await shot("single-%dx%d" % [size.x, size.y])
	state.remember_window_size(Vector2i(1100, 620))
	print("SPLIT_RESULT passed=%d failed=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)

func finish_fixture(car: VehicleBody3D) -> void:
	car.laps_done = 1
	car.start_line_crossed = true
	car._lap_running = true
	car._reverse_line_crossings = 0
	car._safe_reset.consume_replayed_finish()
	car._on_lap_crossed()

func weather_run() -> void:
	state.split_screen = true
	state.chosen_level = 2
	change_scene_to_file("res://scenes/main.tscn")
	if not await wait_phase("INTRO", 70.0): quit(1); return
	var main := current_scene
	var split: Node = main._split_screen
	for i in range(2):
		var weather: Node = split.cars[i].get_node_or_null("WeatherParticles")
		check(weather != null and weather.layers == 1 << (18 + i), "weather_emitter_player_%d" % (i + 1))
		check(split.cameras[i].cull_mask & (1 << (18 + i)) != 0 and split.cameras[i].cull_mask & (1 << (19 - i)) == 0, "weather_camera_isolation_%d" % (i + 1))
	check(split.cars[0].max_speed_kmh == split.cars[1].max_speed_kmh and split.cars[0]._steering_grip == split.cars[1]._steering_grip, "same_weather_and_speed_rules")
	main._race_intro._finish()
	if not await wait_phase("RACING", 12.0): quit(1); return
	await create_timer(0.6).timeout
	await shot("split-rain")
	key(KEY_ESCAPE, true)
	await process_frame
	key(KEY_ESCAPE, false)
	check(state.phase_name() == "PAUSED", "escape_pauses_both")
	var modes := [split.cameras[0]._mode, split.cameras[1]._mode]
	key(KEY_ENTER, true)
	await process_frame
	await process_frame
	key(KEY_ENTER, false)
	await process_frame
	await process_frame
	check(state.phase_name() == "RACING", "enter_resumes_from_pause")
	check(split.cameras[0]._mode == modes[0] and split.cameras[1]._mode == modes[1], "menu_enter_does_not_change_p2_camera")
	if state.phase_name() == "PAUSED": main.get_node("PauseMenu").resume()
	await create_timer(3.1).timeout
	finish_fixture(split.cars[0])
	await create_timer(0.2).timeout
	finish_fixture(split.cars[1])
	await process_frame
	await process_frame
	check(split._photo.playing and not split._display.visible, "two_human_close_finish_shared_photo")
	await shot("split-photo")
	await create_timer(2.7).timeout
	check(not split._photo.playing and split._display.visible and split.cars[0].visible and split.cars[1].visible, "photo_restores_both_views_and_cars")
	check(state.phase_name() == "FINISHED" and state.finish_snapshot.split_screen, "photo_preserves_double_result")
	print("WEATHER_RESULT passed=%d failed=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
