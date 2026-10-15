extends SceneTree
## 只读截图夹具：用真实关卡/真实 AI，通过 arm 开关起步，相机跟随 AI。
## 不改车辆位置、速度、转向或恢复状态；不参与验收通过判定。
var output := ""
var capture_arc := 805.0
var started_lap := false
var level_index := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-out="):
			output = arg.trim_prefix("--capture-out=")
		elif arg.begins_with("--capture-arc="):
			capture_arc = float(arg.trim_prefix("--capture-arc="))
		elif arg.begins_with("--level="):
			level_index = int(arg.trim_prefix("--level="))
	call_deferred("_run")

func _run() -> void:
	if output.is_empty():
		quit(2)
		return
	# 此夹具直接加载 main，需代替菜单传递关卡选择，不能只把 --level 留给菜单。
	root.get_node("GameState").set("chosen_level", level_index)
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	for _frame in range(24000):
		await physics_frame
		if current_scene == null:
			continue
		var ai := current_scene.get_node_or_null("Opponents/AiCar0") as VehicleBody3D
		if ai == null or ai.get("track") == null:
			continue
		ai.set("armed", true)
		var camera := current_scene.get_node_or_null("ChaseCamera")
		if camera != null:
			camera.set("target", ai)
		var arc := float(ai.get("_arc"))
		if arc < 100.0:
			started_lap = true
		if not started_lap or arc < capture_arc:
			continue
		await RenderingServer.frame_post_draw
		var result := root.get_texture().get_image().save_png(output)
		print("[VISUAL] arc=%.2f speed=%.2f rescues=%d pos=%s PNG=%s result=%d" % [
			float(ai.get("_arc")), ai.linear_velocity.length() * 3.6,
			int(ai.get("_rescue_count")), str(ai.global_position), output, result])
		quit(0 if result == OK else 1)
		return
	printerr("[VISUAL] did not reach capture arc")
	quit(1)
