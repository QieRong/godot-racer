extends SceneTree
## 观察真实 --check=lap 路径，跨起点后在旧卡点附近抓图；不写车辆状态或输入。
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
		if current_scene == null or not bool(current_scene.get("_setup_done")):
			continue
		var car := current_scene.get_node("RaceCar") as VehicleBody3D
		var track := current_scene.get_node("Track")
		var near: Dictionary = track.call("nearest_on_centerline", car.global_position, -1.0)
		var arc := float(near["arc"])
		var speed := car.linear_velocity.length() * 3.6
		if arc < 100.0 and speed > 5.0 and not crossed_start:
			crossed_start = true
			print("[VISUAL] player crossed_start arc=%.2f speed=%.2f" % [arc, speed])
		if not crossed_start or arc < 260.0:
			continue
		if arc > 280.0 or speed < 5.0:
			printerr("[VISUAL] missed moving player crossing window")
			quit(1)
			return
		await RenderingServer.frame_post_draw
		var result := root.get_texture().get_image().save_png(output)
		var nose := -car.global_transform.basis.z
		var heading := rad_to_deg(nose.angle_to(Vector3(near["forward"])))
		print("[VISUAL] player start_crossed=true arc=%.2f speed=%.2f dist=%.2f heading=%.2f grounded=%d pos=%s PNG=%s result=%d" % [
			arc, speed, float(near["dist"]), heading, int(car.call("grounded_wheel_count")),
			str(car.global_position), output, result])
		if result != OK:
			quit(1)
			return
		# --check=lap 的协程仍在 physics_frame 等待。成功抓图后由原检查跑完并退出，
		# 避免此处强退留下 GDScriptFunctionState（独立探针已复现该泄漏）。
		return
	printerr("[VISUAL] player crossing not captured")
	quit(1)
