extends SceneTree
## R6 场景补验：自然倒计时、真实 ESC 事件、菜单按钮、实际 AI 记录入口。
## 完赛用信号注入定位成绩链路，不声称车辆真实跑完一圈或真人体验通过。

const WAIT_SEC := 0.65
const EPS_SEC := 0.06
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var passed := 0
var failed := 0
var _state: Node
var _game: Node
var _car: VehicleBody3D
var _ai: VehicleBody3D
var _menu: CanvasLayer
var _done := false
var _audio_ids: Array[int] = []
var _audio_capture_ok := true


func _initialize() -> void:
	create_timer(120.0, true).timeout.connect(_timeout)
	call_deferred("_run")


func _run() -> void:
	_state = root.get_node("GameState")
	_state.set("chosen_level", 3)
	_game = load("res://scenes/main.tscn").instantiate()
	root.add_child(_game)
	current_scene = _game
	if not await _wait_setup():
		_check(false, "真实场景装配完成")
		_finish()
		return
	_car = _game.get_node("RaceCar")
	_menu = _game.get_node("PauseMenu")
	var opponents: Array = _game.get("_opponents")
	_check(opponents.size() > 0, "存在真实 AI 对手")
	if opponents.is_empty():
		_finish()
		return
	_ai = opponents[0]
	_check(_phase() == "COUNTDOWN" and paused, "真实场景进入倒计时")
	_check(_total() == 0.0 and _lap() == 0.0, "GO 前不计时")
	_check(await _wait_phase("RACING"), "倒计时自然结束进入 RACING")
	_check(not paused and not bool(_car.get("start_locked")), "GO 解冻场景并解锁玩家")
	_check(bool(_ai.get("armed")), "GO 同时放行 AI")
	await create_timer(0.25, true).timeout
	_check(_total() >= 0.2 and _lap() >= 0.2, "玩家不踩油门，GO 后两钟已增长")
	_check(absf(_total() - _lap()) < EPS_SEC, "总时间与首圈同原点")
	await _pause_cycle(false)
	await _pause_cycle(true)
	await _finish_records()
	_finish()


func _pause_cycle(use_button: bool) -> void:
	_escape()
	_check(await _wait_phase("PAUSED"), "ESC 事件触发 PAUSED")
	_check(paused and _menu.visible, "暂停树且显示真实暂停菜单")
	var before := _total()
	var lap_before := _lap()
	var player_pos := _car.global_position
	var ai_pos := _ai.global_position
	await create_timer(WAIT_SEC, true).timeout
	_check(absf(_total() - before) < EPS_SEC, "ESC 暂停期间共用总时钟冻结")
	_check(absf(_lap() - lap_before) < EPS_SEC, "ESC 暂停期间玩家圈钟冻结")
	_check(_car.global_position.distance_to(player_pos) < 0.001, "暂停期间玩家位置冻结")
	_check(_ai.global_position.distance_to(ai_pos) < 0.001, "暂停期间 AI 位置冻结")
	print("CLOCK_SCENE_PAUSE fps=%d button=%s total_delta=%.3f lap_delta=%.3f" % [
		Engine.max_fps, str(use_button), _total() - before, _lap() - lap_before])
	if use_button:
		_check(_press_button(_menu, "继续游戏"), "点击真实继续按钮")
	else:
		_escape()
	_check(await _wait_phase("RACING"), "恢复 RACING")
	_check(not paused and not _menu.visible, "恢复场景并隐藏菜单")
	_check(_total() - before < EPS_SEC, "恢复瞬间不补计暂停等待")
	await create_timer(0.2, true).timeout
	_check(_total() - before >= 0.15, "恢复后时钟继续增长")


func _finish_records() -> void:
	var total_before := _total()
	# 信号注入：经 main._on_ai_finished -> 实际 race_position 记录。
	_ai.emit_signal("race_finished", int(_ai.get("laps_target")))
	var rank: Node = _game.get("_race_position")
	var records: Dictionary = rank.get("_finished")
	_check(records.has(_ai.get_instance_id()), "真实 AI 完赛信号写入记录")
	if records.has(_ai.get_instance_id()):
		var ai_total := float(records[_ai.get_instance_id()]["total"])
		_check(absf(ai_total - total_before) < EPS_SEC, "AI 完赛记录采用扣除暂停后的共用时钟")
		var wall := (Time.get_ticks_msec() - int(_state.get("race_start_ms"))) / 1000.0
		print("CLOCK_SCENE_RECORD wall=%.3f ai=%.3f excluded=%.3f" % [wall, ai_total, wall - ai_total])
		_check(wall - ai_total >= WAIT_SEC * 2.0 - EPS_SEC, "AI 记录剔除两次暂停至少 1.24 秒")
	_car.set("laps_done", int(_car.get("laps_target")))
	_car.emit_signal("race_finished", int(_car.get("laps_target")))
	_check(await _wait_phase("FINISHED"), "真实玩家完赛信号进入结算")
	var snapshot: Dictionary = Dictionary(_state.get("finish_snapshot")).duplicate(true)
	var finish_total := _total()
	await create_timer(WAIT_SEC, true).timeout
	_check(absf(_total() - finish_total) < EPS_SEC, "结算后共用时钟冻结")
	_check(snapshot == _state.get("finish_snapshot"), "结算快照冻结")
	var finish_ui: Node = null
	for child in _game.get_children():
		if child.get_script() == load("res://scripts/finish_menu.gd"):
			finish_ui = child
	_check(finish_ui != null, "真实结算菜单挂载")
	if finish_ui == null:
		return
	_capture_audio(_game)
	_check(_press_button(finish_ui, "再玩一局"), "点击真实再玩一局按钮")
	var old := _game
	for _i in range(1800):
		await process_frame
		if current_scene != null and current_scene != old and bool(current_scene.get("_setup_done")):
			_game = current_scene
			break
	_check(_game != old and _phase() == "COUNTDOWN", "重开装配新场景并完整倒计时")
	_check(_total() == 0.0 and Dictionary(_state.get("finish_snapshot")).is_empty(), "重开清零旧时间与成绩")
	_check(await _wait_phase("RACING"), "新一局倒计时自然发车")
	_check(_total() < 0.2, "新 GO 清除旧暂停量和冻结值")


func _press_button(node: Node, label: String) -> bool:
	if node is Button and node.text == label:
		node.emit_signal("pressed")
		return true
	for child in node.get_children():
		if _press_button(child, label):
			return true
	return false


func _escape() -> void:
	for pressed_now in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
		event.physical_keycode = KEY_ESCAPE
		event.pressed = pressed_now
		Input.parse_input_event(event)


func _wait_setup() -> bool:
	for _i in range(1800):
		await process_frame
		if bool(_game.get("_setup_done")):
			return true
	return false


func _wait_phase(want: String) -> bool:
	for _i in range(1200):
		await process_frame
		if _phase() == want:
			return true
	return false


func _phase() -> String:
	return String(_state.call("phase_name"))


func _total() -> float:
	return float(_state.call("race_total_time"))


func _lap() -> float:
	return float(_car.call("current_lap_time"))


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
	print("%s %s" % ["PASS" if ok else "FAIL", label])


func _timeout() -> void:
	_check(false, "120 秒看门狗超时")
	_finish()


func _capture_audio(scene: Node) -> void:
	var ids := AudioExit.capture_tree(scene)
	_audio_capture_ok = _audio_capture_ok and not ids.is_empty()
	_audio_ids.append_array(ids)
	print("SCENE_AUDIO_CAPTURE scene=%d ids=%s" % [scene.get_instance_id(), str(ids)])


func _finish() -> void:
	if _done:
		return
	_done = true
	if is_instance_valid(_game):
		_capture_audio(_game)
		_game.queue_free()
	else:
		_audio_capture_ok = false
	current_scene = null
	paused = false
	if is_instance_valid(_state):
		_state.call("enter_menu")
	await process_frame
	await AudioExit.wait_all_released(self, _audio_ids)
	_check(_audio_capture_ok and not _audio_ids.is_empty() and _audio_ids.all(AudioExit.released),
		"all scene audio playbacks reclaimed before process quit")
	print("RACE_CLOCK_SCENE_SUMMARY pass=%d fail=%d fps=%d" % [passed, failed, Engine.max_fps])
	print("RACE_CLOCK_SCENE_PASS" if failed == 0 else "RACE_CLOCK_SCENE_FAIL")
	quit(0 if failed == 0 else 1)
