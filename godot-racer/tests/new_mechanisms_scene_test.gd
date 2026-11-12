extends SceneTree
## 初始夹具摆位后真实物理驾驶冲线；不手工发完赛信号，不在驾驶中写速度/姿态。
var failed := 0
var gs: Node
var main: Node3D
var car: VehicleBody3D
var ai: VehicleBody3D
var road: Node3D
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok: failed += 1
func frames(count: int) -> void:
	for i in range(count): await physics_frame
func place(body: VehicleBody3D, arc: float, lane: float) -> void:
	var pose: Transform3D = road.surface_frame(arc, lane)
	pose.basis = Basis.looking_at(road.centerline_forward(arc), pose.basis.y)
	pose.origin += Vector3.UP * 0.05
	body.global_transform = pose
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	if body == car: car._safe_reset.queue_pose(pose)
	else:
		ai._arc = fposmod(arc, road.road_length())
		ai._prev_arc = ai._arc
		ai._last_pos = pose.origin
		ai._lane_now = lane
func run() -> void:
	gs = root.get_node("GameState")
	gs.record_results_enabled = false
	gs.chosen_level = 1
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	current_scene = main
	for i in range(2500):
		await physics_frame
		if main._setup_done: break
	check(main._setup_done, "真实关卡装配")
	if not main._setup_done: quit(1); return
	if gs.phase_name() == "INTRO": main.get_node("RaceIntro")._finish()
	main._on_race_go()
	car = main.get_node("RaceCar")
	ai = main._opponents[0]
	road = main.get_node("Track")
	if DisplayServer.get_name() != "headless":
		await create_timer(0.5).timeout
		var ghost: Node3D = load("res://scripts/ghost_car.gd").new()
		main.add_child(ghost)
		ghost.build(car)
		ghost.add_ghost_label(84.35)
		var pose := car.global_transform
		pose.origin += -car.global_basis.z * 12.0
		ghost.global_transform = pose
		await frames(3)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://godot-logs/ghost-label-preview.png")
		check(ghost.find_children("*", "CollisionObject3D", true, false).is_empty(), "幽灵只有视觉节点")
		ghost.queue_free()
		main.get_node("PauseMenu").pause()
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://godot-logs/ui-pause-preview.png")
		main.get_node("PauseMenu").resume()
	# 第一段：停止玩家前方有足够空间，观察AI实际驶过和回线。
	car.freeze = true
	place(car, 140.0, 0.0)
	place(ai, 95.0, 0.0)
	var committed := false
	var passed := false
	var returned := false
	for i in range(1800):
		await physics_frame
		if ai.passing_state == ai.Passing.OVERTAKING: committed = true
		if ai._arc > 152.0 and ai._arc < 200.0: passed = true
		if passed and absf(ai._cur_lateral() - ai.lane_offset) < 0.5:
			returned = true
			break
	check(committed and passed and returned, "真实物理超车并回归巡航线")
	check(ai.rescue_count() == 0, "超车过程没有自救传送")
	print("PASSING state=%d arc=%.2f lateral=%.2f" % [ai.passing_state, ai._arc, ai._cur_lateral()])
	# 第二段：新起点夹具，双方最后一圈从终点前自然加速，仍由原计圈/排名判定。
	paused = true
	gs.phase = gs.Phase.COUNTDOWN
	car.freeze = false
	ai.freeze = false
	var length: float = road.road_length()
	place(car, length - 24.0, -3.0)
	place(ai, length - 27.0, 3.0)
	car.laps_done = 1
	car.start_line_crossed = true
	car._lap_running = true
	car._lap_armed = true
	car._prev_line_signed = -24.0
	car._lap_suppressed = false
	ai._laps = 1
	ai._crossings = 2
	ai._crossed_start = true
	ai.passing_state = ai.Passing.CRUISE
	main._photo_finish.invalidate()
	main._photo_finish.invalid_until = 0.0
	main._on_race_go()
	Input.action_press("accelerate")
	var photo_seen := false
	var pause_checked := false
	for i in range(1800):
		await process_frame
		if main._player_finish_pending and gs.phase_name() == "RACING" and not pause_checked:
			pause_checked = true
			gs.pause_race()
			var clock: float = gs.race_total_time()
			await create_timer(0.2, true).timeout
			check(is_equal_approx(clock, gs.race_total_time()), "冲线等待期暂停不消耗比赛时间")
			gs.resume_race()
		if main._photo_finish.playing:
			photo_seen = true
			if DisplayServer.get_name() != "headless":
				await create_timer(1.9).timeout
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png("res://godot-logs/photo-finish-live.png")
			break
		if gs.phase_name() == "FINISHED": break
	check(gs.phase_name() == "FINISHED", "真实物理冲线正常结算")
	var entries: Array = gs.finish_snapshot.get("entrants", [])
	print("ENTRANTS ", JSON.stringify(entries))
	check(photo_seen, "真实两车接近冲线触发摄影")
	var snapshot: Dictionary = gs.finish_snapshot.duplicate(true)
	for i in range(500):
		await process_frame
		if not main._photo_finish.playing: break
	check(gs.finish_snapshot == snapshot, "摄影不改变真实成绩")
	check(not main._photo_finish.playing, "摄影结束释放临时资源")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://godot-logs/ui-finish-preview.png")
	check(car.finish_input_locked and not car.get_collision_layer_value(2), "玩家锁输入及移除车际碰撞")
	Input.action_release("accelerate")
	gs.back_to_menu()
	for i in range(300):
		await process_frame
		if current_scene != null and current_scene.has_method("_show_level_select"): break
	check(gs.phase_name() == "MENU", "返回首页无状态残留")
	var menu := current_scene
	menu._show_level_select()
	await frames(2)
	check(menu._selected_idx == -1, "进入选关无默认选中")
	check(menu.find_children("*", "ScrollContainer", true, false).is_empty(), "五关选关不用滚动条")
	var list: Control = menu._level_list
	var inside := true
	for button in menu._buttons:
		inside = inside and Rect2(Vector2.ZERO, list.size).encloses(button.get_rect())
	check(inside and menu._buttons.size() == 5, "五张卡片全部在列表边界内")
	menu._on_level_focus(4)
	check(menu.find_child("SelectedRecord", true, false).text.contains("最佳纪录"), "最佳纪录显示在右侧详情")
	var key := InputEventKey.new()
	key.keycode = KEY_TAB
	key.pressed = true
	gs._input(key)
	check(not menu._buttons[0].get_theme_stylebox("focus") is StyleBoxEmpty, "键盘模式保留可见焦点")
	var mouse := InputEventMouseMotion.new()
	mouse.relative = Vector2(4,0)
	gs._input(mouse)
	check(menu._buttons[0].get_theme_stylebox("focus") is StyleBoxEmpty, "鼠标模式不显示误导焦点框")
	menu._open_overlay("settings", null)
	await frames(2)
	var panel: Control = menu._overlay.get_node("OverlayPanel")
	var settings_inside := true
	for button in panel.find_children("*", "Button", true, false):
		settings_inside = settings_inside and Rect2(Vector2.ZERO, panel.size).encloses(button.get_rect())
	check(settings_inside, "设置项和返回按钮都在面板内")
	menu._close_overlay()
	print("SCENE_MECHANISMS failures=%d" % failed)
	quit(1 if failed else 0)
