extends SceneTree
## 真实首页帮助入口，两分辨率渲染与实际绑定说明；不装配赛道。
var output := ""
var passed := 0
var failed := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.get_slice("=", 1)
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("REAR_UI_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	root.get_node("GameState").settings_path = output.path_join("settings.cfg")
	change_scene_to_file("res://scenes/menu.tscn")
	for i in range(5): await process_frame
	var menu := current_scene
	var button := menu.find_child("HomeHelpButton", true, false) as Button
	check(button != null, "真实首页帮助按钮")
	if button == null: quit(1); return
	button.pressed.emit()
	var help := menu.find_child("HelpText", true, false) as Label
	check(help != null and "按住 C 向后看" in help.text, "实际帮助显示C后视")
	for size in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
		root.size = size
		for i in range(5): await process_frame
		var back := menu.find_child("CloseOverlay", true, false) as Button
		check(Rect2(Vector2.ZERO, Vector2(size)).encloses(help.get_global_rect())
			and not help.get_global_rect().intersects(back.get_global_rect()), "%s帮助文字可见且不遮按钮" % size)
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			check(root.get_texture().get_image().save_png(output.path_join("help-%dx%d.png" % [size.x, size.y])) == OK,
				"真实菜单帮助截图")
	menu.find_child("CloseOverlay", true, false).pressed.emit()
	await process_frame
	check(menu.get("_overlay") == null, "关闭帮助返回首页")
	var music := root.get_node("GameState").find_child("MenuMusic", false, false)
	if music != null: await music.call("shutdown_and_wait")
	current_scene = null
	menu.free()
	await process_frame
	print("REAR_UI_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
