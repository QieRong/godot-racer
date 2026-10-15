extends SceneTree
## 跟随原 opponents 发车时序，在越过旧卡点后抓图；不改车辆输入/姿态。
var output := ""
var crossed_start := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-out="):
			output = arg.trim_prefix("--capture-out=")
	call_deferred("_run")

func _run() -> void:
	if output.is_empty():
		quit(2)
		return
	root.get_node("GameState").set("chosen_level", 3)
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	for _frame in range(24000):
		await physics_frame
		if current_scene == null:
			continue
		var ai := current_scene.get_node_or_null("Opponents/AiCar0") as VehicleBody3D
		if ai == null or not bool(ai.get("armed")):
			continue
		current_scene.get_node("ChaseCamera").set("target", ai)
		var arc := float(ai.get("_arc"))
		if arc < 100.0 and not crossed_start:
			crossed_start = true
			print("[VISUAL] crossed_start arc=%.2f" % arc)
		# 出生 arc 接近整圈长度，必须先真实跨过起点，再到旧卡点之后。
		if not crossed_start or arc < 260.0:
			continue
		if arc > 280.0 or int(ai.get("_rescue_count")) > 0:
			printerr("[VISUAL] missed clean crossing window")
			quit(1)
			return
		if ai.linear_velocity.length() * 3.6 < 5.0:
			continue
		await RenderingServer.frame_post_draw
		var result := root.get_texture().get_image().save_png(output)
		print("[VISUAL] start_crossed=true arc=%.2f speed=%.2f rescues=%d still=%d lane=%.2f lat=%.2f pos=%s PNG=%s result=%d" % [
			float(ai.get("_arc")), ai.linear_velocity.length() * 3.6, int(ai.get("_rescue_count")),
			int(ai.get("_still_frames")), float(ai.get("_lane_now")), float(ai.call("_cur_lateral")),
			str(ai.global_position), output, result])
		quit(0 if result == OK else 1)
		return
	printerr("[VISUAL] clean crossing not captured")
	quit(1)
