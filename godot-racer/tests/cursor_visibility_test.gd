extends SceneTree
## 真实菜单→比赛/倒计时→暂停/退出确认→结算→菜单；不代表真人点击或驾驶验收。

var passed := 0
var failed := 0
var state: Node


func _initialize() -> void:
	print("CURSOR_VISIBILITY_UID=", ResourceUID.id_to_text(ResourceUID.create_id()))
	call_deferred("_run")


func _check(ok: bool, detail: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("CURSOR_VISIBILITY_ASSERT %s %s" % ["PASS" if ok else "FAIL", detail])


func _mode(expected: int, detail: String) -> void:
	# 等待生产节点的正常帧调度，不直接调用被测可见性实现。
	await process_frame
	await process_frame
	_check(Input.mouse_mode == expected, detail)


func _run() -> void:
	state = root.get_node("GameState")
	state.settings_path = "user://cursor-visibility-selftest.cfg"
	state.ai_enabled = false
	_check(change_scene_to_file("res://scenes/menu.tscn") == OK, "加载真实菜单")
	await _mode(Input.MOUSE_MODE_VISIBLE, "首页光标可见")
	var menu: Control = current_scene
	# 通过真实开始入口进入main，保留正常关卡装配与倒计时。
	menu.call("_enter_game")
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.scene_file_path == "res://scenes/main.tscn" \
				and current_scene.get("_setup_done"): break
	var scene := current_scene
	var ready: bool = scene != null and scene.scene_file_path == "res://scenes/main.tscn" and scene.get("_setup_done")
	_check(ready, "真实装配比赛场景")
	if not ready:
		await _done()
		return
	_check(state.call("phase_name") == "COUNTDOWN", "真实进入倒计时")
	_check(scene.get("_opponents").is_empty(), "本次未装配AI")
	await _mode(Input.MOUSE_MODE_HIDDEN, "倒计时隐藏光标")
	state.call("request_exit")
	await _mode(Input.MOUSE_MODE_VISIBLE, "倒计时退出确认恢复光标")
	state.call("cancel_exit")
	await _mode(Input.MOUSE_MODE_HIDDEN, "取消退出后继续倒计时并隐藏")
	deadline = Time.get_ticks_msec() + 7000
	while state.call("phase_name") != "RACING" and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(state.call("phase_name") == "RACING", "真实倒计时完成进入比赛")
	await _mode(Input.MOUSE_MODE_HIDDEN, "驾驶时隐藏光标且不捕获鼠标")
	var pause_menu: Node = scene.get_node("PauseMenu")
	for cycle in range(2):
		pause_menu.call("pause")
		_check(state.call("phase_name") == "PAUSED" and paused, "真实暂停%d" % cycle)
		await _mode(Input.MOUSE_MODE_VISIBLE, "暂停菜单恢复光标%d" % cycle)
		pause_menu.call("resume")
		await _mode(Input.MOUSE_MODE_HIDDEN, "继续比赛重新隐藏%d" % cycle)
	state.call("request_exit")
	await _mode(Input.MOUSE_MODE_VISIBLE, "比赛退出确认恢复光标")
	state.call("cancel_exit")
	await _mode(Input.MOUSE_MODE_HIDDEN, "取消退出继续比赛并隐藏")
	# 仅验证结算相位的光标；不把注入有效成绩当实际完赛。
	_check(state.call("finish_race", 2, 10.0, 10.0, 2), "生产结算接口接受测试成绩")
	await _mode(Input.MOUSE_MODE_VISIBLE, "结算恢复光标")
	state.call("back_to_menu")
	await _mode(Input.MOUSE_MODE_VISIBLE, "返回首页保留光标")
	_check(current_scene != null and current_scene.scene_file_path == "res://scenes/menu.tscn",
		"真实返回菜单场景")
	# 再次进入装配相位，验证菜单之后仍会重新隐藏。
	state.call("prepare_race")
	await _mode(Input.MOUSE_MODE_HIDDEN, "再次进入关卡装配时隐藏光标")
	state.call("enter_menu")
	await _mode(Input.MOUSE_MODE_VISIBLE, "回到菜单相位恢复光标")
	await _done()


func _done() -> void:
	state.call("enter_menu")
	var music := state.find_child("MenuMusic", false, false)
	if music != null:
		_check(await music.call("shutdown_and_wait"), "菜单音频退出前实际回收")
	if current_scene != null:
		var scene := current_scene
		current_scene = null
		scene.free()
	await process_frame
	await process_frame
	print("CURSOR_VISIBILITY_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
