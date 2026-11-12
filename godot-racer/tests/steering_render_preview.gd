extends "res://tests/reset_safety_test.gd"
## 实际Compatibility画面取证；模拟玩家输入，不代替真人操控体验。

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = level
	state.ai_enabled = false
	state.settings_path = output.path_join("settings.cfg")
	root.size = Vector2i(1280, 720)
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING": break
	check(current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING", "30秒内实际渲染装配发车，AI关闭")
	if failed > 0: quit(1); return
	car = current_scene.get_node("RaceCar")
	track = current_scene.get_node("Track")
	var results: Array[Dictionary] = []
	for fixture in [[40.0, "steer_left"], [120.0, "steer_right"]]:
		place(20.0)
		car.set("_steer", 0.0)
		car.steering = 0.0
		await frames(180)
		car.linear_velocity = track.centerline_forward(20.0) * fixture[0] / 3.6
		car.angular_velocity = Vector3.ZERO
		Input.action_press(fixture[1])
		await frames(48)
		var lean := rad_to_deg(acos(clampf(car.global_basis.y.dot(Vector3.UP), -1.0, 1.0)))
		check(lean < 45.0, "%.0fkm/h真实渲染转向不侧立，倾角%.2f°" % [fixture[0], lean])
		await process_frame
		await RenderingServer.frame_post_draw
		var label := "L%d-%dkmh-%s" % [level + 1, fixture[0], fixture[1]]
		var image := root.get_texture().get_image()
		check(image.save_png(output.path_join(label + ".png")) == OK, "实际画面保存 " + label)
		results.append({"fixture_kmh": fixture[0], "input_action": fixture[1],
			"actual_speed_kmh": car.linear_velocity.length() * 3.6, "lean_degrees": lean,
			"steer_radians": car.steering, "image": label + ".png"})
		Input.action_release(fixture[1])
	FileAccess.open(output.path_join("rendered-steering.json"), FileAccess.WRITE).store_string(JSON.stringify(results, "\t"))
	car = null
	track = null
	var active := current_scene
	var ids := AudioExit.capture_tree(active)
	current_scene = null
	active.free()
	check(await AudioExit.wait_all_released(self, ids), "渲染实例音频回收")
	print("STEERING_RENDER_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
