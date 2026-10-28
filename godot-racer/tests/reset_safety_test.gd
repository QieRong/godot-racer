extends SceneTree
## 回归用户侧立截图与方案A。只在夹具摆初始状态，操控走真实Input和车辆物理。
var output := ""
var level := 0
var passed := 0
var failed := 0
var car: VehicleBody3D
var track: Node3D

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): output = arg.trim_prefix("--evidence-dir=")
		if arg.begins_with("--level="): level = int(arg.trim_prefix("--level="))
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("RESET_SAFETY_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func frames(count: int) -> void:
	for i in range(count): await physics_frame

func place(arc: float, lateral := 0.0, roll := 0.0, speed := 0.0) -> void:
	var surface: Transform3D = track.surface_frame(arc, lateral)
	var forward: Vector3 = track.centerline_forward(arc)
	car.global_transform = Transform3D(Basis(forward, deg_to_rad(roll)) *
		Basis.looking_at(forward, surface.basis.y), surface.origin+Vector3.UP*0.55)
	car.linear_velocity = forward*speed
	car.angular_velocity = Vector3.ZERO
	car.set("_arc_hint", arc)
	car.set("_reset_cooldown", 0.0)
	car.set("_immunity", 0.0)

func press_r() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_R
	event.physical_keycode = KEY_R
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await frames(3)

func run() -> void:
	var state := root.get_node("GameState")
	state.chosen_level = level
	state.ai_enabled = false
	state.settings_path = output.path_join("settings.cfg")
	Engine.max_fps = 0
	change_scene_to_file("res://scenes/main.tscn")
	var deadline := Time.get_ticks_msec()+30000
	while Time.get_ticks_msec()<deadline:
		await process_frame
		if current_scene != null and current_scene.get("_setup_done") and state.phase_name()=="RACING": break
	check(current_scene != null and current_scene.get("_setup_done") and state.phase_name()=="RACING", "真实场景装配发车")
	if failed>0: quit(1); return
	car = current_scene.get_node("RaceCar")
	track = current_scene.get_node("Track")
	car.auto_recover = false
	car.auto_reset_out_of_bounds = false
	# 接地后留足安全样本；事故向前20m，复位位置还必须满足用户选定的30米硬上限。
	place(200.0)
	await frames(180)
	var safe_position := car.global_position
	check(car.grounded_wheel_count()==4, "安全位置由真实四轮接地建立")
	var laps_before: int = car.laps_done
	place(220.0, 0.0, 90.0)
	await press_r()
	check(car.global_position.distance_to(safe_position)<4.0, "R回最后安全处，不能回事故最近点")
	check(car.global_basis.y.dot(Vector3.UP)>0.98, "侧立后真实R输入扶正，up=%.4f" % car.global_basis.y.dot(Vector3.UP))
	check(car.linear_velocity.length()<1.0 and car.angular_velocity.length()<0.2, "复位清除运动与翻滚")
	check(car.laps_done==laps_before, "复位不增加已完成圈数")
	await frames(150)
	check(car.grounded_wheel_count()==4 and car.global_basis.y.dot(Vector3.UP)>0.95, "复位后实际落地稳定")
	car.auto_recover = true
	for attempt in range(3):
		await frames(72)
		await press_r()
	check(car.auto_recover, "连续手动R不会被误判为自动复位死循环并关闭脱困")
	car.auto_recover = false
	place(280.0,0.0,90.0)
	await press_r()
	# 按真实位置核对限定路段；全局粗反查的亚米误差不能经fposmod变成整圈。
	var bounded_distance := INF
	for arc in range(250,281):
		bounded_distance = minf(bounded_distance,car.global_position.distance_to(track.centerline_point(float(arc))))
	check(bounded_distance<0.5,"旧安全点太远时，只在事故同路段后方30米内复位")
	place(190.0, 0.0, 90.0)
	await press_r()
	var accident: Vector3 = track.centerline_point(190.0)
	var advance: float = (car.global_position-accident).dot(track.centerline_forward(190.0))
	check(advance<=0.5 and car.global_position.distance_to(accident)<30.5,
		"倒车后不能用R回到前方旧安全点刷进度，前进%.3fm" % advance)
	place(200.0)
	await frames(300)
	var blocker := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(3.0,2.0,6.0)
	collision.shape = box
	blocker.add_child(collision)
	current_scene.add_child(blocker)
	blocker.global_position = track.centerline_point(200.0)+Vector3.UP
	await frames(1)
	place(220.0,0.0,90.0)
	await press_r()
	check(car.global_position.distance_to(safe_position)>4.0, "历史点被实体占用后不把车辆传送进碰撞体")
	blocker.queue_free()
	await frames(1)
	# 高坡侧立：对应用户截图的路肩姿态，不能被世界坐标y>=3错误挡住。
	var peak_arc := 0.0
	var peak_height := -INF
	for arc in range(int(track.road_length())):
		var height: float = track.centerline_point(float(arc)).y
		if height>peak_height:
			peak_arc = float(arc)
			peak_height = height
	place(peak_arc)
	await frames(240)
	var safe_peak := car.global_position
	check(safe_peak.y>3.0 and car.grounded_wheel_count()>=3, "高坡上建立真实接地安全位置")
	place(peak_arc+20.0, 0.0, 90.0)
	await press_r()
	check(car.global_position.distance_to(safe_peak)<4.0 and car.global_basis.y.dot(Vector3.UP)>0.98,
		"坡顶侧立R回坡顶安全处，不落回零高度")
	await frames(260)
	place(peak_arc, 0.0, 90.0)
	car.auto_recover = true
	await frames(120)
	check(car.global_basis.y.dot(Vector3.UP)>0.95 and car.global_position.y>3.0,
		"高于3米路面的自动扶正仍生效")
	car.auto_recover = false
	# 真实A/D交替；初速只在夹具摆放时给一次，随后不写姿态或速度。
	var steering_results: Array[Dictionary] = []
	for fixture in [[80.0,24], [120.0,48], [150.0,72]]:
		place(20.0, 0.0, 0.0, fixture[0]/3.6)
		var max_lean := 0.0
		var two_wheel_frames := 0
		Input.action_press("accelerate")
		for i in range(480):
			var left := (i/int(fixture[1]) as int)%2==0
			Input.action_release("steer_right" if left else "steer_left")
			Input.action_press("steer_left" if left else "steer_right")
			await physics_frame
			max_lean = maxf(max_lean, rad_to_deg(acos(clampf(car.global_basis.y.dot(Vector3.UP),-1.0,1.0))))
			if car.grounded_wheel_count()<=2: two_wheel_frames+=1
		Input.action_release("accelerate")
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		check(max_lean<45.0, "%.0fkm/h初速A/D交替%d帧不侧立，最大倾角%.1f°" % [fixture[0],fixture[1],max_lean])
		steering_results.append({"speed_kmh":fixture[0],"switch_frames":fixture[1],
			"max_lean_degrees":max_lean,"at_most_two_wheel_frames":two_wheel_frames})
	FileAccess.open(output.path_join("steering.json"),FileAccess.WRITE).store_string(JSON.stringify(steering_results))
	# 新局真实过线→倒退到线前→R→等原6s隔离结束→真实油门再过线，不得多算一圈。
	var old_scene_id := current_scene.get_instance_id()
	car = null
	track = null
	state.restart_race()
	deadline = Time.get_ticks_msec()+30000
	while Time.get_ticks_msec()<deadline:
		await process_frame
		if current_scene != null and current_scene.get_instance_id()!=old_scene_id:
			if current_scene.get("_setup_done") and state.phase_name()=="RACING": break
	car = current_scene.get_node("RaceCar")
	track = current_scene.get_node("Track")
	place(8.0)
	await frames(240)
	var before_replay: int = car.laps_done
	place(track.road_length()-2.0,0.0,90.0)
	await press_r()
	var wall_deadline := Time.get_ticks_msec()+6100
	while Time.get_ticks_msec()<wall_deadline: await process_frame
	Input.action_press("accelerate")
	await frames(240)
	Input.action_release("accelerate")
	var passed_line: bool = (car.global_position-track.start_line_center).dot(track.start_line_forward)>1.0
	check(passed_line and car.laps_done==before_replay,
		"终点倒退后R，超过6秒再真实过线也不能多算圈")
	paused = false
	var active := current_scene
	current_scene = null
	car = null
	track = null
	active.free()
	await process_frame
	await process_frame
	print("RESET_SAFETY_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
