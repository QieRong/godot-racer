extends SceneTree
## 控制圈线事件验证模式接线和真实落盘；不冒充真人或AI实际跑完三圈。
const AudioExit := preload("res://tests/audio_exit_probe.gd")
const Overlay := preload("res://scripts/menu_overlay.gd")
var passed := 0
var failed := 0
var folder := ""
var state: Node

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): folder = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("ENDLESS_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func ready_race() -> bool:
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING": return true
	return false

func run() -> void:
	state = root.get_node("GameState")
	check(not state.record_results_enabled, "脚本验收默认不写玩家纪录")
	check(not folder.is_empty(), "明确指定独立测试存档目录")
	if failed > 0: quit(1); return
	DirAccess.make_dir_recursive_absolute(folder)
	var path := folder.path_join("mode-records.json")
	check(not FileAccess.file_exists(path), "不覆盖历史测试或玩家纪录")
	state.records.load_from(path)
	state.record_results_enabled = true
	state.race_variants_enabled = false
	for i in range(state.level_count()):
		state.chosen_level = i
		state.endless_mode = true
		check(state.effective_laps() == 0 and state.get_level(i).laps_to_finish == 2, "五关无限目标不改写原资源：L%d" % (i + 1))
		state.endless_mode = false
		check(state.effective_laps() == 2, "五关普通模式仍两圈：L%d" % (i + 1))
	state.endless_mode = true
	state.ai_enabled = true
	state.chosen_level = 0
	Engine.max_fps = 0
	change_scene_to_file("res://scenes/main.tscn")
	check(await ready_race(), "无限模式真实装配和倒计时")
	if failed > 0: quit(1); return
	var car: VehicleBody3D = current_scene.get_node("RaceCar")
	var opponents: Array = current_scene.get("_opponents")
	check(car.get("laps_target") == 0 and state.effective_laps() == 0, "玩家不限圈，不修改关卡资源")
	check(opponents.size() == 1 and opponents[0].get("laps_target") == 0, "沿用AI开关且AI不限圈")
	car.set_physics_process(false)
	var player_finishes := [0]
	car.race_finished.connect(func(_laps): player_finishes[0] += 1)
	car.call("_on_lap_crossed")
	for i in range(3):
		car.set("_lap_start_ms", state.race_clock_ms() / 1000.0 - (60.0 + i))
		car.call("_on_lap_crossed")
	check(car.get("laps_done") == 3 and player_finishes[0] == 0 and state.phase_name() == "RACING", "控制完成三圈后继续驾驶，无结算")
	check(state.records.best_time("level_1", true) > 0.0 and is_zero_approx(state.records.best_time("level_1", false)), "单圈信号实际保存无限纪录，不污染普通纪录")
	var single: float = state.records.best_time("level_1", true)
	check(not current_scene.get_node("HUD/TotalTimeLabel").visible, "无限模式隐藏整场总时间")
	check(String(current_scene.get_node("HUD/LastLabel").text).contains("01:"), "无限模式仍显示刚完成单圈用时")
	var ai: VehicleBody3D = opponents[0]
	ai.set_physics_process(false)
	var ai_finishes := [0]
	ai.race_finished.connect(func(_laps): ai_finishes[0] += 1)
	var track := current_scene.get_node("Track")
	ai.set("_crossed_start", true)
	for i in range(3):
		ai.set("_arc", track.road_length() - 2.0)
		ai.global_position = track.centerline_point(1.0) + Vector3.UP * 0.5
		ai.call("_update_progress")
	check(ai.call("laps_done") >= 3 and ai_finishes[0] == 0, "AI控制跨线三圈后不发完赛信号")
	var pause_menu := current_scene.get_node("PauseMenu")
	pause_menu.call("pause")
	var before: float = car.call("current_lap_time")
	await create_timer(0.12, true).timeout
	check(absf(float(car.call("current_lap_time")) - before) < 0.002, "暂停不增加单圈用时")
	pause_menu.call("resume")
	var previous := current_scene
	var previous_audio := AudioExit.capture_tree(previous)
	state.endless_mode = false
	state.restart_race()
	await process_frame
	check(await ready_race(), "重开后普通模式装配发车")
	check(await AudioExit.wait_all_released(self, previous_audio), "重开回收前场景音频")
	car = current_scene.get_node("RaceCar")
	check(car.get("laps_target") == 2 and current_scene.get_node("HUD/TotalTimeLabel").visible, "普通模式恢复两圈与总时间显示")
	car.set("laps_done", 2)
	car.set("lap_last", 60.0)
	car.set("lap_best", 59.0)
	await create_timer(0.12).timeout
	current_scene.call("_on_race_finished", 2)
	await process_frame
	check(state.phase_name() == "FINISHED" and state.records.best_time("level_1", false) > 0.0, "普通两圈结算保存总成绩")
	check(is_equal_approx(state.records.best_time("level_1", true), single), "普通结算不覆盖无限单圈")
	var overlay := Overlay.new()
	overlay.setup(state, Color.WHITE, "records")
	root.add_child(overlay)
	check(overlay.find_child("RecordLevel5", true, false) != null, "纪录弹层可查看全部五关")
	check(String(overlay.find_child("RecordLevel1", true, false).text).contains("普通两圈"), "弹层明确两类纪录")
	overlay.free()
	paused = false
	var active := current_scene
	var audio := AudioExit.capture_tree(active)
	current_scene = null
	active.free()
	check(await AudioExit.wait_all_released(self, audio), "测试结束回收音频")
	print("ENDLESS_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
