extends SceneTree
## 阶段二真实赛场接线：AI 完赛不终止比赛，玩家完赛才结算胜负。

const MAIN_SCENE := "res://scenes/main.tscn"
var passed := 0
var failed := 0
var _done := false


func _initialize() -> void:
	create_timer(180.0, true).timeout.connect(_watchdog)
	call_deferred("_run")


func _watchdog() -> void:
	if not _done:
		_check(false, "场景测试 180 秒内结束")
		_finish()


func _run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = 3
	state.ai_enabled = true
	var game := (load(MAIN_SCENE) as PackedScene).instantiate()
	root.add_child(game)
	current_scene = game
	var ready := false
	for _i in range(1500):
		await process_frame
		if bool(game.get("_setup_done")):
			ready = true
			break
	_check(ready, "L4 场景完成装配")
	if not ready:
		_finish()
		return
	var ais: Array = game.get("_opponents")
	_check(ais.size() == 1, "L4 有一台 AI 对手")
	if ais.size() != 1:
		_finish()
		return
	var ai: VehicleBody3D = ais[0]
	var car: VehicleBody3D = game.get_node("RaceCar")
	game.call("_on_race_go")
	car.emit_signal("race_finished", 0)
	var early_rows: Array = game.get("_race_position").standings()
	var early_player_finished := false
	for row in early_rows:
		if row.get("id") == "player":
			early_player_finished = bool(row.get("finished"))
	_check(state.phase_name() == "RACING" and not early_player_finished,
		"圈数不足的伪完成信号不锁定玩家名次")
	ai.emit_signal("race_finished", int(ai.get("laps_target")))
	_check(state.phase_name() == "RACING" and not paused,
		"AI 先完赛后玩家仍能继续比赛")
	_check(ai.collision_layer == 0 and ai.collision_mask == 1 and not ai.freeze and bool(ai.get("armed")),
		"真实 AI 完赛后变为只与场地碰撞")
	var overlay: CanvasLayer = game.get("_race_position")
	await create_timer(0.35).timeout
	var rank_text: String = overlay.get_node("RankLabel").text
	var notice_text: String = overlay.get_node("AiFinishNotice").text
	_check(rank_text == "名次 2 / 2" and notice_text == "AI#1 已完赛",
		"HUD 实时显示落后名次与 AI 完赛提示（名次=%s，提示=%s，采样=%.3f，相位=%s，处理=%s/%s，模式=%d）"
		% [rank_text, notice_text, float(overlay.get("_sample_time")), state.phase_name(),
		str(overlay.is_processing()), str(overlay.can_process()), overlay.process_mode])
	_check(float(ai.call("speed_kmh")) >= 1.0,
		"AI 完赛后仍按原控制器继续行驶（%.1f km/h）" % float(ai.call("speed_kmh")))
	await physics_frame
	car.set("laps_done", int(car.get("laps_target")))
	car.set("lap_last", 42.0)
	car.set("lap_best", 40.0)
	car.emit_signal("race_finished", int(car.get("laps_target")))
	# 在物理帧发出时，main 等本帧全部 AI 回调结束后才写最终名次。
	await process_frame
	var result: Dictionary = state.finish_snapshot
	_check(state.phase_name() == "FINISHED" and paused and String(result.get("outcome", "")) == "lose",
		"玩家稍后完赛时判负并进入结算")
	var entries: Array = result.get("entrants", [])
	_check(entries.size() == 2 and entries[0].get("id") == "ai1"
		and int(entries[0].get("rank", 0)) == 1 and entries[1].get("id") == "player"
		and int(entries[1].get("rank", 0)) == 2,
		"最终名次表按同一排序口径包含 AI 和玩家")
	_check(entries.size() == 2 and is_equal_approx(float(result.get("total", -1.0)),
		float(entries[1].get("total", -2.0))), "总时间锁在玩家完成信号时刻")
	state.restart_race()
	var second: Node = null
	for _i in range(1500):
		await process_frame
		if current_scene != null and current_scene != game and bool(current_scene.get("_setup_done")):
			second = current_scene
			break
	_check(second != null, "重开后装配第二局")
	if second == null:
		_finish()
		return
	second.call("_on_race_go")
	var second_car: VehicleBody3D = second.get_node("RaceCar")
	var second_ai: VehicleBody3D = second.get("_opponents")[0]
	second_car.set("laps_done", int(second_car.get("laps_target")))
	await physics_frame
	second_car.emit_signal("race_finished", int(second_car.get("laps_target")))
	second_ai.emit_signal("race_finished", int(second_ai.get("laps_target")))
	await process_frame
	var tied: Dictionary = state.finish_snapshot
	var tied_rows: Array = tied.get("entrants", [])
	_check(String(tied.get("outcome", "")) == "tie" and int(tied.get("position", 0)) == 1
		and tied_rows.size() == 2 and int(tied_rows[0].get("rank", 0)) == 1
		and int(tied_rows[1].get("rank", 0)) == 1,
		"同物理帧双完赛在真实接线中并列第一")
	state.ai_enabled = false
	state.restart_race()
	var practice: Node = null
	for _i in range(1500):
		await process_frame
		if current_scene != null and current_scene != second and bool(current_scene.get("_setup_done")):
			practice = current_scene
			break
	_check(practice != null and practice.get("_opponents").is_empty(), "无 AI 模式仍完成装配")
	if practice != null:
		practice.call("_on_race_go")
		await process_frame
		var practice_ui: CanvasLayer = practice.get("_race_position")
		_check(practice_ui.get_node("RankLabel").text == "练习", "无 AI 模式 HUD 显示练习")
		var practice_car: VehicleBody3D = practice.get_node("RaceCar")
		practice_car.set("laps_done", int(practice_car.get("laps_target")))
		practice_car.emit_signal("race_finished", int(practice_car.get("laps_target")))
		var solo: Dictionary = state.finish_snapshot
		_check(String(solo.get("outcome", "")) == "practice" and int(solo.get("field_size", 0)) == 1,
			"无 AI 模式完赛后保留单人成绩")
	_finish()


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("  ✔ " + label)
	else:
		failed += 1
		printerr("  ✘ " + label)


func _finish() -> void:
	if _done:
		return
	_done = true
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	print("RACE_POSITION_SCENE_PASS" if failed == 0 else "RACE_POSITION_SCENE_FAIL")
	quit(0 if failed == 0 else 1)
