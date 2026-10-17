extends SceneTree
## 发布状态回归：只检验比赛状态、暂停、结算、退出取消的契约。

var passed := 0
var failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("  ✔ " + label)
	else:
		failed += 1
		printerr("  ✘ " + label)


func _run() -> void:
	var state := root.get_node_or_null("GameState")
	if state == null:
		_check(false, "GameState autoload exists")
		_finish()
		return
	for method in ["begin_race", "pause_race", "resume_race", "finish_race",
		"request_exit", "cancel_exit", "enter_menu", "release_drive_input"]:
		_check(state.has_method(method), "GameState." + method)
	if failed > 0:
		_finish()
		return
	state.call("begin_race")
	_check(state.call("phase_name") == "RACING" and not paused, "begin race is active")
	Input.action_press("accelerate")
	Input.action_press("handbrake")
	state.call("pause_race")
	_check(state.call("phase_name") == "PAUSED" and paused, "pause stops the tree")
	_check(not Input.is_action_pressed("accelerate") and not Input.is_action_pressed("handbrake"),
		"pause releases held controls")
	state.call("resume_race")
	_check(state.call("phase_name") == "RACING" and not paused, "resume restores racing")
	Input.action_press("brake_reverse")
	var accepted: bool = state.call("finish_race", 3, 42.5, 40.0, 3)
	_check(accepted and state.call("phase_name") == "FINISHED" and paused, "finish accepted once and freezes race")
	_check(not Input.is_action_pressed("brake_reverse"), "finish releases held controls")
	var result: Dictionary = state.get("finish_snapshot")
	_check(result.get("laps") == 3 and result.get("last") == 42.5 and result.get("best") == 40.0,
		"result is a snapshot")
	_check(not bool(state.call("finish_race", 3, 1.0, 1.0, 3)), "duplicate finish rejected")
	state.call("resume_race")
	_check(state.call("phase_name") == "FINISHED" and paused, "finished race cannot resume")
	state.call("request_exit")
	_check(state.call("phase_name") == "EXIT_CONFIRM" and paused, "exit confirmation holds finish")
	state.call("cancel_exit")
	_check(state.call("phase_name") == "FINISHED" and paused, "cancel restores exact finished state")
	state.call("enter_menu")
	_check(state.call("phase_name") == "MENU" and not paused and state.get("finish_snapshot").is_empty(),
		"menu clears race result and unpauses")
	state.call("request_exit")
	state.call("cancel_exit")
	_check(state.call("phase_name") == "MENU" and not paused, "cancel restores menu state")
	_finish()


func _finish() -> void:
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	print("RELEASE_FLOW_PASS" if failed == 0 else "RELEASE_FLOW_FAIL")
	quit(0 if failed == 0 else 1)
