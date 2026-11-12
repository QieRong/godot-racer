extends SceneTree
var failed := 0
class Road extends Node3D:
	func nearest_on_centerline(p: Vector3, _hint: float) -> Dictionary:
		return {"arc": fposmod(p.z, 1000.0), "pos": Vector3(0, 0, p.z), "forward": Vector3.BACK}
	func road_half_width() -> float: return 8.0
	func centerline_point(d: float) -> Vector3: return Vector3(0, 0, d)
	func centerline_forward(_d: float) -> Vector3: return Vector3.BACK
	func road_length() -> float: return 1000.0
class Ranking extends Node:
	var distance := 300.0
	func player_progress() -> float: return distance
	func is_finished(_car: Node) -> bool: return false
func check(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok: failed += 1
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var gs := root.get_node("GameState")
	gs.record_results_enabled = false
	var road := Road.new()
	root.add_child(road)
	var player := VehicleBody3D.new()
	root.add_child(player)
	var script: Script = load("res://scripts/ai_opponent.gd")
	var ai: VehicleBody3D = load("res://scenes/race_car.tscn").instantiate()
	check(ai.get_node("CarModel").transform.is_equal_approx(load("res://data/car_appearance.tres").vehicle_transform), "默认模型配置保留原场景朝向")
	ai.set_script(script)
	root.add_child(ai)
	ai.freeze = true
	ai.track = road
	ai.player = player
	ai._total_len = 1000.0
	ai._arc = 100.0
	ai.global_position = Vector3(0, 1, 100)
	ai._face_along(Vector3.BACK)
	ai._lane_now = 0.0
	player.freeze = true
	player.global_position = Vector3(0, 1, 125)
	player.linear_velocity = Vector3(0, 0, 15)
	var chosen: float = ai._avoid_player_lane(0.0)
	check(ai.passing_state == ai.Passing.OVERTAKING and absf(chosen) >= 2.1, "主动选定超车侧")
	player.global_position.z = 101.0
	check(is_equal_approx(ai._avoid_player_lane(0.0), chosen), "并排保持承诺路线")
	player.global_position.z = 85.0
	ai._avoid_player_lane(0.0)
	check(ai.passing_state == ai.Passing.COOLDOWN, "超过安全净距后回线冷却")
	ai.passing_state = ai.Passing.CRUISE
	check(is_zero_approx(ai._avoid_player_lane(0.0)), "玩家在后方不主动变道")
	player.global_position.z = 104.0
	player.linear_velocity = Vector3.ZERO
	ai._avoid_player_lane(0.0)
	check(is_zero_approx(ai._follow_speed_kmh), "前方停车允许目标速度为零")
	ai._still_frames = 359
	ai._update_stuck_rescue()
	check(ai._still_frames == 0 and ai.rescue_count() == 0, "合理跟车等待不触发自救")
	var obstacles: Node3D = load("res://scripts/obstacle_field.gd").new()
	root.add_child(obstacles)
	obstacles.track = road
	obstacles._total_len = 1000.0
	obstacles.obstacles = [{"arc": 125.0, "lateral": 0.0, "half_width": 20.0, "dynamic_index": -1}]
	ai.obstacle_field = obstacles
	player.global_position.z = 125.0
	ai.passing_state = ai.Passing.CRUISE
	ai._avoid_player_lane(0.0)
	check(ai.passing_state != ai.Passing.OVERTAKING, "没有安全通道继续跟车")
	# 回线途中的旧超车车道被障碍封住时，不能否决已找到的安全车道而原地撞停。
	obstacles.obstacles[0].half_width = 0.95
	ai._lane_now = 0.5
	ai._pass_lane = 0.5
	ai.passing_state = ai.Passing.RETURN
	player.global_position = Vector3(-3, 1, 125)
	var escape_lane: float = ai._effective_lane()
	check(escape_lane > 2.0 and ai.passing_state == ai.Passing.COOLDOWN, "障碍冲突时结束旧超车路线并采用安全车道")
	ai.passing_state = ai.Passing.RETURN
	player.global_position = Vector3(1.5, 1, 105)
	check(is_equal_approx(ai._effective_lane(), ai._lane_now) and ai._queue_until_arc > ai._arc, "玩家在换道扫掠带内仍保持等待")
	ai.obstacle_field = null
	obstacles.free()
	var ranking := Ranking.new()
	ai.race_position = ranking
	gs.phase = gs.Phase.RACING
	ai._progress = 0.0
	for i in range(600): ai._update_chase(1.0 / 60.0)
	check(is_equal_approx(ai.chase_multiplier, 1.05), "追赶上限5%")
	ai.speed_cap_kmh = 180.0
	ai._follow_speed_kmh = -1.0
	ai._queue_until_arc = -1.0
	ai.linear_velocity = Vector3.ZERO
	ai._update_drive()
	check(is_equal_approx(ai._drive_wheels[0].engine_force, -ai.max_engine_force * 1.05), "追赶加成作用于低于弯速上限的加速过程")
	ranking.distance = -300.0
	for i in range(900): ai._update_chase(1.0 / 60.0)
	check(is_equal_approx(ai.chase_multiplier, 0.97), "领先最多降3%")
	gs.phase = gs.Phase.PAUSED
	var saved: float = ai.chase_multiplier
	ranking.distance = 300.0
	ai._update_chase(20.0)
	check(is_equal_approx(saved, ai.chase_multiplier), "暂停不更新追赶")
	gs.phase = gs.Phase.RACING
	gs.dynamic_chase_enabled = false
	ai._update_chase(0.1)
	check(is_equal_approx(ai.chase_multiplier, 1.0), "关闭恢复原基础速度")
	ai.race_position = null
	ranking.free()
	ai._follow_speed_kmh = -1.0
	ai.rotation.y = PI * 0.5
	ai.linear_velocity = Vector3(1.5, 0, 0)
	ai._still_frames = 0
	var hz := Engine.physics_ticks_per_second
	for i in range(int(hz * 1.5)):
		ai.position.x += 1.5 / float(hz)
		ai._update_stuck_rescue()
	check(ai.rescue_count() == 1 and ai._nose_horizontal().dot(Vector3.BACK) > 0.99, "被撞偏航并以5.4km/h横滑时1.5秒扶正回线")
	# 原比例油门在长直道提前收油，与阻力平衡后长期达不到目标；滑条各档都应保留加速能力。
	ai._follow_speed_kmh = -1.0
	ai._queue_until_arc = -1.0
	ai._steer = 0.0
	for player_cap in [80.0, 180.0, 240.0]:
		ai.speed_cap_kmh = player_cap * 0.9
		ai.linear_velocity = Vector3(0, 0, ai.speed_cap_kmh * 0.75 / 3.6)
		ai._update_drive()
		check(is_equal_approx(ai._drive_wheels[0].engine_force, -ai.max_engine_force), "滑条%.0f对应AI低于目标时不提前收油" % player_cap)
	ai.linear_velocity = Vector3(0, 0, (ai.speed_cap_kmh + 3.0) / 3.6)
	ai._update_drive()
	check(is_zero_approx(ai._drive_wheels[0].engine_force) and is_equal_approx(ai._all_wheels[0].brake, ai.engine_brake * 0.2), "达到目标后保留原松油与轻制动")
	ai.linear_velocity = Vector3(0, 0, (ai.speed_cap_kmh + 20.0) / 3.6)
	ai._update_drive()
	check(is_zero_approx(ai._drive_wheels[0].engine_force) and ai._all_wheels[0].brake > ai.engine_brake * 0.2, "超速保留原主动制动")
	ai._follow_speed_kmh = 30.0
	ai.linear_velocity = Vector3(0, 0, 50.0 / 3.6)
	ai._update_drive()
	check(is_zero_approx(ai._drive_wheels[0].engine_force) and is_equal_approx(ai._all_wheels[0].brake, ai.PROBE_BRAKE_FORCE), "跟车限速仍优先于驱动力")
	var trace: Node = load("res://scripts/ghost_trace.gd").new()
	trace.directory = "user://mechanisms-test-ghosts"
	trace.identity = "fixture"
	var visual_script: Script = load("res://scripts/ghost_car.gd")
	trace.data = visual_script.append_sample(PackedFloat32Array(), 0.0, Transform3D.IDENTITY, 0.0)
	trace.data = visual_script.append_sample(trace.data, 1.0, Transform3D(Basis.IDENTITY, Vector3(4, 0, 0)), 4.0)
	# 同一隔离目录可跨进程再次执行，读取上次生成的文件。
	if FileAccess.file_exists(trace.file_path()):
		check(not trace.read_trace(trace.file_path()).is_empty(), "跨进程读取有效轨迹")
	else:
		check(trace.save_trace(1.0), "独立二进制幽灵存档")
	check(not trace.save_trace(2.0), "较慢轨迹保留旧记录")
	trace.identity = "other"
	check(trace.read_trace(trace.directory.path_join("fixture.ghost")).is_empty(), "不同组合禁止播放")
	var ghost: Node3D = visual_script.new()
	root.add_child(ghost)
	ghost.samples = trace.data
	ghost.play_at(0.5)
	check(ghost.global_position.is_equal_approx(Vector3(2,0,0)), "轨迹位置插值")
	trace.active = true
	trace.invalidate()
	check(not trace.valid, "复位使当前轨迹无效")
	trace.car = player
	var ghost_ranking := Ranking.new()
	trace.ranking = ghost_ranking
	trace.begin()
	check(trace.valid and trace.active and trace.data.size() == 9, "新圈恢复录制资格并重置时间原点")
	trace._sample(601.0)
	check(not trace.valid, "超出十分钟预算不保存轨迹")
	ghost_ranking.free()
	ghost.free()
	trace.free()
	road.free()
	ai.free()
	player.free()
	print("NEW_MECHANISMS failures=%d" % failed)
	quit(1 if failed else 0)
