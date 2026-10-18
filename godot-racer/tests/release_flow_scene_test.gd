extends SceneTree
## 真场景接线冒烟：完成信号只触发一次结算，ESC 从结算回菜单。

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
	var scene := load("res://scenes/main.tscn") as PackedScene
	if scene == null:
		_check(false, "main scene loads")
		_finish()
		return
	var game := scene.instantiate()
	root.add_child(game)
	current_scene = game
	var ready := false
	for _i in range(900):
		await process_frame
		if game.get("_setup_done"):
			ready = true
			break
	_check(ready, "race scene finishes setup")
	if not ready:
		_finish()
		return
	# Phase 01：互动路径装配完进 COUNTDOWN（树暂停、玩家输入锁），先验相位再触发
	# "出发！"（与游玩同一个入口 _on_race_go），然后才验结算链路
	_check(state.call("phase_name") == "COUNTDOWN" and paused,
		"after setup the race waits in countdown with tree paused")
	game.call("_on_race_go")
	_check(state.call("phase_name") == "RACING" and not paused, "GO starts the race")
	var car := game.get_node("RaceCar")
	car.set("lap_last", 42.5)
	car.set("lap_best", 40.0)
	car.set("laps_done", int(car.get("laps_target")))
	Input.action_press("accelerate")
	car.emit_signal("race_finished", int(car.get("laps_target")))
	_check(paused and state.call("phase_name") == "FINISHED", "real finish signal pauses the race")
	_check(not Input.is_action_pressed("accelerate"), "real finish releases throttle")
	var finish_count := 0
	for child in game.get_children():
		if child is CanvasLayer and child.get_script() == load("res://scripts/finish_menu.gd"):
			finish_count += 1
	_check(finish_count == 1, "one finish overlay")
	car.emit_signal("race_finished", int(car.get("laps_target")))
	var second_count := 0
	for child in game.get_children():
		if child is CanvasLayer and child.get_script() == load("res://scripts/finish_menu.gd"):
			second_count += 1
	_check(second_count == 1, "duplicate signal does not duplicate overlay")
	state.call("request_exit")
	_check(state.call("phase_name") == "EXIT_CONFIRM" and paused, "finish exit shows confirmation")
	state.call("cancel_exit")
	_check(state.call("phase_name") == "FINISHED" and paused, "cancel returns to frozen result")
	state.call("restart_race")
	var restarted := false
	for _i in range(900):
		await process_frame
		if current_scene != null and current_scene.name == "Main" and current_scene != game \
			and current_scene.get("_setup_done"):
			restarted = true
			break
	_check(restarted, "restart loads a fresh race scene")
	if not restarted:
		_finish()
		return
	var second_car := current_scene.get_node("RaceCar")
	# Phase 01：重开 = 完整新比赛 —— 新场景从 LOADING 重新走倒计时（R14/G9），
	# 成绩清零、快照清空都在 COUNTDOWN 相位上验
	_check(state.call("phase_name") == "COUNTDOWN" and paused and int(second_car.get("laps_done")) == 0 and
		state.get("finish_snapshot").is_empty(), "restart clears result and re-enters countdown")
	# 再触发一次"出发！"验第二轮完整链路（第二次走的是新实例的同一个入口）
	current_scene.call("_on_race_go")
	second_car.set("lap_last", 41.0)
	second_car.set("lap_best", 39.0)
	second_car.emit_signal("race_finished", int(second_car.get("laps_target")))
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)
	for _i in range(4):
		await process_frame
	_check(state.call("phase_name") == "MENU" and not paused, "ESC from finish returns to menu")
	_check(current_scene != null and current_scene.name == "Menu", "menu scene is active")
	_finish()


func _finish() -> void:
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	print("RELEASE_FLOW_SCENE_PASS" if failed == 0 else "RELEASE_FLOW_SCENE_FAIL")
	quit(0 if failed == 0 else 1)
