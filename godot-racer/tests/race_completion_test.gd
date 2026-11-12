extends SceneTree
## 所有可写路径由独立证据目录提供；只在该目录启用完赛保存。
const Store := preload("res://scripts/race_completion.gd")
var ui: Script
var folder := ""
var ids := PackedStringArray(["level_1", "level_2", "level_3", "level_4", "level_5"])
var passed := 0
var failed := 0
var gs: Node

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): folder = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("COMPLETION_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func write(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.close()

func run() -> void:
	if folder.is_empty(): push_error("必须提供独立 --evidence-dir"); quit(2); return
	DirAccess.make_dir_recursive_absolute(folder)
	gs = root.get_node("GameState")
	ui = load("res://scripts/ui_theme.gd")
	check(not gs.record_results_enabled, "--script默认隔离自动化成绩")
	if "--scene-only" in OS.get_cmdline_user_args():
		gs.records.load_from(folder.path_join("scene-records.json"))
		await scene_check()
		print("COMPLETION_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
		await gs.quit_after_menu_audio()
		quit(0 if failed == 0 else 1)
		return
	var store := Store.new()
	var path := folder.path_join("completion.json")
	if "--verify-only" in OS.get_cmdline_user_args():
		check(store.load_from(ids, path) and store.completed_count() == 5, "新进程读取五关完成文件")
		check(gs.completion.completed_count() == 0, "测试未污染默认完成存档")
	else:
		check(not FileAccess.file_exists(path), "使用全新独立文件")
		check(store.load_from(ids, path) and store.completed_count() == 0, "没有新档时从零开始")
		gs.completion = store
		gs.records.load_from(folder.path_join("records.json"))
		gs.records.update_record("level_5", false, 60.123)
		var record_hash := FileAccess.get_sha256(gs.records.path)
		check(store.completed_count() == 0, "旧最佳纪录不推断完成")
		# 真实入口的状态门槛；以下快照夹具只写独立文件。
		gs.chosen_level = 4
		gs.begin_race()
		gs.save_level_completion()
		check(store.completed_count() == 0, "未完赛不能写完成")
		gs.finish_race(2, 30.0, 30.0, 2)
		gs.save_level_completion()
		check(store.completed_count() == 0, "自动化即使完赛也不写")
		gs.record_results_enabled = true
		gs.endless_mode = true
		gs.save_level_completion()
		check(store.completed_count() == 0, "无限模式不写普通完成")
		gs.endless_mode = false
		gs.finish_snapshot.target = 1
		gs.save_level_completion()
		check(store.completed_count() == 0, "非两圈目标不写")
		gs.finish_snapshot.target = 2
		gs.finish_snapshot.outcome = "lose"
		gs.save_level_completion()
		check(store.is_completed("level_5") and store.completed_count() == 1, "先完成L5且不要求击败AI")
		var saved_hash := FileAccess.get_sha256(path)
		gs.save_level_completion()
		check(FileAccess.get_sha256(path) == saved_hash and store.completed_count() == 1, "同快照重复保存幂等")
		gs.enter_menu()
		gs.begin_race()
		gs.finish_race(2, 31.0, 30.0, 2)
		gs.save_level_completion()
		check(not gs.finish_snapshot.completion_new and store.completed_count() == 1, "重玩不重复累加")
		gs.prepare_race()
		gs.enter_countdown()
		gs.enter_menu()
		check(store.completed_count() == 1 and gs.finish_snapshot.is_empty(), "准备/倒计时退出清本局快照且保留历史完成")
		for index in [2, 0, 3, 1]:
			gs.chosen_level = index
			gs.ai_enabled = index != 1
			gs.begin_race()
			gs.finish_race(2, 30.0, 29.0, 2)
			gs.save_level_completion()
		check(store.completed_count() == 5 and gs.finish_snapshot.completion_count == 5, "任意顺序完成五关，含关闭AI练习")
		check(FileAccess.file_exists(path + ".bak"), "替换前保留上一份完成备份")
		check(FileAccess.get_sha256(gs.records.path) == record_hash, "完成记录不改旧最佳纪录字节")
		await ui_check("complete")
		var bad := folder.path_join("corrupt.json")
		for content in ["{broken", '{"version":2,"completed":[]}', '{"version":1,"completed":["level_99"]}', '{"version":1,"completed":[true]}']:
			write(bad, content)
			check(not store.load_from(ids, bad) and not store.mark_completed("level_1") and FileAccess.get_file_as_string(bad) == content,
				"损坏/未知版本/无效关卡原文件保留且禁止覆盖")
		await ui_check("corrupt")
		store.load_from(ids, folder.path_join("missing-dir/progress.json"))
		gs.chosen_level = 0
		gs.begin_race()
		gs.finish_race(2, 30.0, 30.0, 2)
		gs.save_level_completion()
		check(not gs.finish_snapshot.completion_saved and store.completed_count() == 0 and not gs.finish_snapshot.completion_error.is_empty(),
			"写失败不增加完成数，快照明确未保存")
		await ui_check("failed")
		gs.record_results_enabled = false
		# 真正的物理穿线只验证信号接线；保持自动化隔离，不冒充自然完整两圈。
		if "--scene-check" in OS.get_cmdline_user_args(): await scene_check()
	print("COMPLETION_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	await gs.quit_after_menu_audio()
	quit(0 if failed == 0 else 1)

func label_fits(label: Label) -> bool:
	var font := label.get_theme_font("font")
	var size := label.get_theme_font_size("font_size")
	for line in label.text.split("\n"):
		if font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > label.size.x: return false
	return label.get_line_height() * label.get_line_count() <= label.size.y

func ui_check(state: String) -> void:
	gs.enter_menu()
	var menu: Control = load("res://scenes/menu.tscn").instantiate()
	root.add_child(menu)
	current_scene = menu
	menu._show_level_select()
	menu._on_level_focus(4)
	await create_timer(0.6, true).timeout
	check(menu._buttons.size() == 5 and menu.find_children("*", "ScrollContainer", true, false).is_empty(), state + "五关一屏无滚动")
	var cards_ok := true
	for index in range(5):
		menu._on_level_focus(index)
		cards_ok = cards_ok and not menu._buttons[index].disabled and not menu._start.disabled
		var label: Label = menu._buttons[index].find_child("CardCompletion", true, false)
		cards_ok = cards_ok and label_fits(label)
	check(cards_ok, state + "五关任意可选且完成标签无溢出")
	var summary: Label = menu.find_child("CompletionSummary", true, false)
	check(label_fits(summary), state + "完成数/读取错误文字无溢出")
	check(menu._record_label.global_position.x > menu._level_list.get_global_rect().end.x, "最佳纪录仍在右侧详情")
	var key := InputEventKey.new()
	key.pressed = true
	ui.update_navigation(key, root)
	check(not menu._buttons[0].get_theme_stylebox("focus") is StyleBoxEmpty, "键盘保留可见焦点")
	var mouse := InputEventMouseMotion.new()
	mouse.relative = Vector2(4, 0)
	ui.update_navigation(mouse, root)
	check(menu._buttons[0].get_theme_stylebox("focus") is StyleBoxEmpty, "鼠标不显示误导焦点框")
	var joy := InputEventJoypadButton.new()
	joy.pressed = true
	ui.update_navigation(joy, root)
	check(not menu._buttons[0].get_theme_stylebox("focus") is StyleBoxEmpty, "手柄保留可见焦点")
	await screenshot("select-" + state)
	root.remove_child(menu)
	menu.queue_free()
	# enter_menu清快照，结算UI取测试期保存的完成状态。
	var finish: CanvasLayer = load("res://scripts/finish_menu.gd").new()
	finish.result = {"laps":2, "target":2, "total":60.0, "last":30.0, "best":30.0, "field_size":1, "outcome":"practice",
		"completion_saved":state == "complete", "completion_new":true, "completion_count":5, "completion_total":5,
		"completion_error":gs.completion.last_error}
	root.add_child(finish)
	await create_timer(0.3, true).timeout
	var feedback: Label = finish.find_child("CompletionFeedback", true, false)
	check(label_fits(feedback), state + "结算反馈文字无溢出")
	check(feedback.text.contains("五关全部完成" if state == "complete" else "未保存"), state + "结算反馈明确")
	await screenshot("finish-" + state)
	root.remove_child(finish)
	finish.queue_free()
	await process_frame

func screenshot(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(folder.path_join(name + ".png"))

func scene_check() -> void:
	for with_ai in [true, false]:
		gs.record_results_enabled = not with_ai
		gs.completion.load_from(ids, folder.path_join("scene-%s.json" % str(with_ai)))
		gs.ai_enabled = with_ai
		gs.chosen_level = 1
		gs.race_variants_enabled = not ("--fixed-scene" in OS.get_cmdline_user_args())
		gs.apply_cli_args(PackedStringArray(["--race-seed=61102", "--race-combination=0"]))
		gs.photo_finish_enabled = false
		var main: Node3D = load("res://scenes/main.tscn").instantiate()
		root.add_child(main)
		current_scene = main
		for i in range(2500):
			await physics_frame
			if main._setup_done: break
		check(main._setup_done, "实际场景装配 AI=" + str(with_ai))
		if not main._setup_done: return
		check(main._ghost_trace.status != null and not main._ghost_trace.identity.is_empty(), "幽灵初始化完成 AI=" + str(with_ai))
		if "--fixed-scene" in OS.get_cmdline_user_args():
			check(main._obstacle_field == null, "真实无障碍配置不创建占位障碍节点")
		if gs.phase_name() == "INTRO": main.get_node("RaceIntro")._finish()
		main._on_race_go()
		if with_ai:
			main._on_ai_finished(2, main._opponents[0])
			check(gs.phase_name() == "RACING" and gs.finish_snapshot.is_empty(), "AI单独完赛不推进玩家完成")
		var car: VehicleBody3D = main.get_node("RaceCar")
		var road: Node3D = main.get_node("Track")
		var pose: Transform3D = road.surface_frame(road.road_length() - 24.0, 0.0)
		pose.basis = Basis.looking_at(road.centerline_forward(road.road_length() - 24.0), pose.basis.y)
		pose.origin += Vector3.UP * 0.05
		car.global_transform = pose
		car.linear_velocity = Vector3.ZERO
		car.angular_velocity = Vector3.ZERO
		car._safe_reset.queue_pose(pose)
		car.laps_done = 1
		car.start_line_crossed = true
		car._lap_armed = true
		car._prev_line_signed = -24.0
		car._lap_suppressed = false
		Input.action_press("accelerate")
		for i in range(1800):
			await physics_frame
			if gs.phase_name() == "FINISHED": break
		Input.action_release("accelerate")
		check(gs.phase_name() == "FINISHED" and car.laps_done == 2, "真实物理最后一圈穿线 AI=" + str(with_ai))
		if with_ai:
			check(not gs.finish_snapshot.has("completion_saved") and gs.completion.completed_count() == 0, "场景自动化不推进完成")
		else:
			check(gs.finish_snapshot.get("completion_saved", false) and gs.completion.completed_count() == 1,
				"AI关闭练习真实穿线后写独立测试档")
		root.remove_child(main)
		main.queue_free()
		gs.enter_menu()
		await process_frame
	gs.record_results_enabled = false
