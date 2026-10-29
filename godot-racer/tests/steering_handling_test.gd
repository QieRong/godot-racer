extends "res://tests/reset_safety_test.gd"
## 真实玩家车短段转向，不用自动驾驶，不在行驶中改速度/姿态，不代替真人手感。

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = level
	state.ai_enabled = false
	state.settings_path = output.path_join("settings.cfg")
	Engine.max_fps = 0
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING": break
	check(current_scene != null and current_scene.get("_setup_done") and state.phase_name() == "RACING", "真实场景装配发车")
	if failed > 0: quit(1); return
	car = current_scene.get_node("RaceCar")
	track = current_scene.get_node("Track")
	car.auto_recover = false
	car.auto_reset_out_of_bounds = false
	if OS.get_cmdline_user_args().has("--probe-legacy-rates"):
		car.steer_speed = 4.0
		car.steer_return_speed = 4.0
		car.steering_stability_enabled = false
	var results: Array[Dictionary] = []
	for speed in [20.0, 40.0, 80.0, 120.0, 150.0]:
		for left in [true, false]:
			Input.action_release("steer_left")
			Input.action_release("steer_right")
			place(20.0)
			car.set("_steer", 0.0)
			car.steering = 0.0
			await frames(120)
			check(car.grounded_wheel_count() == 4, "%.0fkm/h 起测时四轮真实接地" % speed)
			# 只给一次初速，保留实际悬挂落地高度；不能再抬回出生高度制造腾空延迟。
			car.linear_velocity = track.centerline_forward(20.0) * speed / 3.6
			car.angular_velocity = Vector3.ZERO
			var start := car.global_position
			var forward := -car.global_basis.z.normalized()
			var side := forward.cross(Vector3.UP).normalized()
			var peak_roll := 0.0
			var early_yaw := 0.0
			var early_steer := 0.0
			Input.action_press("steer_left" if left else "steer_right")
			for i in range(48):
				await physics_frame
				peak_roll = maxf(peak_roll, rad_to_deg(acos(clampf(car.global_basis.y.dot(Vector3.UP), -1.0, 1.0))))
				if i == 7:
					early_yaw = rad_to_deg(forward.signed_angle_to(-car.global_basis.z, Vector3.UP))
					early_steer = car.steering
			Input.action_release("steer_left")
			Input.action_release("steer_right")
			var yaw := rad_to_deg(forward.signed_angle_to(-car.global_basis.z, Vector3.UP))
			var lateral := (car.global_position - start).dot(side)
			check(peak_roll < 45.0, "%.0fkm/h %s短段不侧立，最大倾角%.2f°" % [speed, "A" if left else "D", peak_roll])
			check(absf(yaw) > 0.15 and (yaw > 0.0) == left,
				"%.0fkm/h %s真实转弯方向正确，偏航%.2f°" % [speed, "A" if left else "D", yaw])
			results.append({"speed_kmh": speed, "left": left, "early_yaw_degrees": early_yaw,
				"early_steer_radians": early_steer, "yaw_degrees": yaw, "lateral_m": lateral,
				"max_roll_degrees": peak_roll, "final_speed_kmh": car.linear_velocity.length() * 3.6})
	FileAccess.open(output.path_join("handling.json"), FileAccess.WRITE).store_string(JSON.stringify(results, "\t"))
	car = null
	track = null
	var active := current_scene
	var ids := AudioExit.capture_tree(active)
	current_scene = null
	active.free()
	check(await AudioExit.wait_all_released(self, ids), "音频回执回收")
	print("STEERING_HANDLING_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
