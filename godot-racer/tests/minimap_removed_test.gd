extends SceneTree
## 真实菜单帮助→无AI游玩；验证M和旧CLI均不能恢复已取消的小地图。

var _pass := 0
var _fail := 0
var _tag := "probe"
const AudioExit := preload("res://tests/audio_exit_probe.gd")


func _initialize() -> void:
	print("MINIMAP_REMOVED_UID=", ResourceUID.id_to_text(ResourceUID.create_id()))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tag="): _tag = arg.get_slice("=", 1)
	call_deferred("_run")


func _check(ok: bool, detail: String) -> void:
	if ok: _pass += 1
	else: _fail += 1
	print("MINIMAP_REMOVED_ASSERT %s %s" % ["PASS" if ok else "FAIL", detail])


func _run() -> void:
	var state := root.get_node("GameState")
	state.settings_path = ProjectSettings.globalize_path("res://../godot-logs/minimap-remove-20261025/%s-settings.cfg" % _tag)
	_check(not InputMap.has_action("toggle_minimap"), "不再注册小地图输入动作")
	_check(not ResourceLoader.exists("res://scripts/minimap.gd"), "小地图实现资源已删除")
	change_scene_to_file("res://scenes/menu.tscn")
	await process_frame
	await process_frame
	var menu: Control = current_scene
	var home: Control = menu.get("_home")
	menu.call("_open_overlay", "help", home.controls()[2])
	await process_frame
	var help_text: String = menu.get("_overlay").find_child("HelpText", true, false).text
	_check(not help_text.contains("小地图") and not help_text.contains("M 显示"), "实际帮助页没有小地图或M键提示")
	menu.call("_close_overlay")
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.scene_file_path == "res://scenes/main.tscn" \
				and current_scene.get("_setup_done") and state.call("phase_name") == "RACING": break
	var scene := current_scene
	_check(scene != null and scene.get("_setup_done") and state.call("phase_name") == "RACING", "真实装配和倒计时完成后进入游玩")
	var hud: CanvasLayer = scene.get_node("HUD")
	_check(scene.get_node_or_null("Minimap") == null, "游玩场景不装配小地图世界或相机")
	_check(hud.get_node_or_null("MinimapPanel") == null, "HUD没有小地图面板")
	_check(not hud.has_method("_setup_minimap") and not hud.has_method("_update_minimap_legend"),
		"HUD不再持有地图绑定或图例实现")
	_check(not scene.get("_checks_basic").has_method("run_minimap")
		and not scene.get("_checks_basic").has_method("run_minimap_disabled"), "基础检查不再持有旧地图入口")
	_check(scene.get("_opponents").is_empty(), "本次验证没有装配AI")
	for name in ["SpeedLabel", "TimeLabel", "LastLabel", "BestLabel"]:
		_check(hud.get_node_or_null(name) != null, "保留HUD读数 " + name)
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = KEY_M
		event.keycode = KEY_M
		event.pressed = pressed
		root.push_input(event)
		await process_frame
	_check(hud.get_node_or_null("MinimapPanel") == null, "旧CLI参数及真实M按下/松开后仍无小地图")
	_check(hud.call("_fmt", 59.9996) == "01:00.000", "HUD毫秒进位保持")
	scene.get_node("RaceCar").emit_signal("lap_completed", 61.234, 60.123)
	_check(hud.get_node("LastLabel").text == "上圈   01:01.234"
		and hud.get_node("BestLabel").text == "最快   01:00.123", "圈速信号仍驱动HUD显示")
	if DisplayServer.get_name() != "headless":
		var settled := false
		deadline = Time.get_ticks_msec() + 6000
		while not settled and Time.get_ticks_msec() < deadline:
			var countdown: Variant = scene.get("_countdown")
			settled = not is_instance_valid(countdown) or (countdown.get("_state") == "done"
				and not countdown.get("_root").visible)
			await RenderingServer.frame_post_draw
		_check(settled, "GO提示退出后再采集稳定游玩画面")
		await RenderingServer.frame_post_draw
		var path := ProjectSettings.globalize_path("res://../godot-logs/minimap-remove-20261025/%s-gameplay.png" % _tag)
		_check(root.get_texture().get_image().save_png(path) == OK, "真实游玩截图保存成功")
	var music := state.find_child("MenuMusic", false, false)
	if music != null: _check(await music.call("shutdown_and_wait"), "菜单音频实际回收")
	var audio_ids := AudioExit.capture_tree(scene)
	paused = false
	current_scene = null
	scene.free()
	await process_frame
	_check(await AudioExit.wait_all_released(self, audio_ids), "场景音频回执实际回收")
	print("MINIMAP_REMOVED_COMPLETE PASS=%d FAIL=%d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
