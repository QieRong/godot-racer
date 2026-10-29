extends "res://tests/reset_safety_test.gd"
## 从当局真实赛道选最紧弯，复用RacingLine估计入弯速度；只测试玩家真实A/D短段。
const RacingLine := preload("res://scripts/racing_line.gd")

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
	var tight_radius := INF
	var tight_arc := -1.0
	for arc in range(0, int(track.road_length()), 4):
		var radius := RacingLine.corner_radius_at(track, float(arc))
		if radius > 1.0 and radius < tight_radius:
			tight_radius = radius
			tight_arc = float(arc)
	check(tight_arc >= 0.0 and is_finite(tight_radius), "由实际最终中心线找到有效最紧弯")
	if failed > 0: quit(1); return
	var cfg: Resource = state.current_level()
	var turn_speed := minf(car.max_speed_kmh, RacingLine.speed_limit_kmh(
		tight_radius, car.max_lateral_accel * float(cfg.friction_multiplier), 0.80))
	var forward: Vector3 = track.centerline_forward(tight_arc)
	var next_forward: Vector3 = track.centerline_forward(tight_arc + 12.0)
	forward.y = 0.0
	next_forward.y = 0.0
	var left: bool = forward.signed_angle_to(next_forward, Vector3.UP) > 0.0
	var samples: Array[Dictionary] = []
	for speed in [20.0, turn_speed]:
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		place(tight_arc)
		car.set("_steer", 0.0)
		car.steering = 0.0
		await frames(180)
		check(car.grounded_wheel_count() == 4, "最紧弯起测四轮接地")
		car.linear_velocity = track.centerline_forward(tight_arc) * speed / 3.6
		car.angular_velocity = Vector3.ZERO
		var start_forward := -car.global_basis.z
		var max_roll := 0.0
		var max_lateral := 0.0
		var max_height_gap := 0.0
		Input.action_press("steer_left" if left else "steer_right")
		for i in range(48):
			await physics_frame
			max_roll = maxf(max_roll, rad_to_deg(acos(clampf(car.global_basis.y.dot(Vector3.UP), -1.0, 1.0))))
			var near: Dictionary = track.nearest_on_centerline(car.global_position, tight_arc)
			var offset: Vector3 = car.global_position - Vector3(near.pos)
			max_height_gap = maxf(max_height_gap, absf(offset.y))
			offset.y = 0.0
			max_lateral = maxf(max_lateral, offset.length())
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		var yaw := rad_to_deg(start_forward.signed_angle_to(-car.global_basis.z, Vector3.UP))
		check(absf(yaw) > 0.15 and (yaw > 0.0) == left, "%.1fkm/h按实际弯向转弯，偏航%.2f°" % [speed, yaw])
		check(max_roll < 45.0 and max_height_gap < 1.0,
			"%.1fkm/h最紧弯不侧立/离路，倾角%.2f°高度差%.3fm" % [speed, max_roll, max_height_gap])
		check(max_lateral + car.body_half_width < track.road_half_width(),
			"%.1fkm/h短段仍在本关实际路宽内，中心偏差%.3fm" % [speed, max_lateral])
		samples.append({"speed_kmh": speed, "yaw_degrees": yaw, "max_roll_degrees": max_roll,
			"max_lateral_m": max_lateral, "max_height_gap_m": max_height_gap})
	FileAccess.open(output.path_join("corners.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"level": level + 1, "weather": cfg.weather_type, "grip": cfg.friction_multiplier,
		"width_m": track.road_half_width() * 2.0, "arc_m": tight_arc,
		"radius_m": tight_radius, "slope": RacingLine.slope_at(track, tight_arc),
		"curve_speed_kmh": turn_speed, "samples": samples}, "\t"))
	car = null
	track = null
	var active := current_scene
	var ids := AudioExit.capture_tree(active)
	current_scene = null
	active.free()
	check(await AudioExit.wait_all_released(self, ids), "音频回执回收")
	print("STEERING_CORNER_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
