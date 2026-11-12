extends SceneTree
# 几何事件夹具；不冒充自然完整路线。真实往返复现另存samples.jsonl。
var car: VehicleBody3D
var passed := 0
var failed := 0
class Road extends Node3D:
	var start_line_center := Vector3.ZERO
	var start_line_forward := Vector3.RIGHT
	func rail_half_width() -> float: return 8.4
	func nearest_on_centerline(position: Vector3, _hint: float) -> Dictionary:
		return {"arc":fposmod(position.x, 1000.0),"forward":Vector3.RIGHT}
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("LAP_BOUNDARY %s %s" % ["PASS" if ok else "FAIL",label])
func point(x: float, z := 0.0) -> void:
	car.global_position = Vector3(x,0,z)
	car._check_start_line_crossing()
func fresh() -> void:
	car.laps_done = 0
	car.lap_last = 0.0
	car.lap_best = 0.0
	car.start_line_crossed = false
	car._lap_running = true
	car._lap_start_ms = root.get_node("GameState").race_clock_ms()/1000.0
	car._lap_suppressed = false
	car._lap_armed = true
	car._prev_line_signed = -2.0
	car._safe_reset._replayed_finishes = 0
	car._reverse_line_crossings = 0
	point(-2.0)
	point(2.0)
func forward_lap() -> void:
	# 环绕路线的几何事件：在远离终点门处回到负侧，再正向压线。
	point(20.0,100.0)
	point(-20.0,100.0)
	point(-2.0)
	point(2.0)
func run() -> void:
	var gs := root.get_node("GameState")
	gs.record_results_enabled = false
	gs.phase = gs.Phase.RACING
	gs.race_start_ms = Time.get_ticks_msec()
	var road := Road.new()
	root.add_child(road)
	car = VehicleBody3D.new()
	root.add_child(car)
	car.set_script(load("res://scripts/vehicle.gd"))
	car.freeze = true
	car.set_physics_process(false)
	car._track = road
	car.laps_target = 0
	fresh()
	check(car.start_line_crossed and car.laps_done == 0,"首发只标记，GO圈钟不重置")
	var origin: float = car._lap_start_ms
	point(-2.0)
	point(2.0)
	check(car.laps_done == 0 and car.lap_last == 0.0 and car._lap_start_ms == origin,"反向越线后正向返回不计圈、不重置圈钟")
	point(-2.0)
	point(2.0)
	check(car.laps_done == 0,"重复往返不能累加圈数")
	fresh()
	forward_lap()
	check(car.laps_done == 1,"完整环绕的正向终点事件仍计圈")
	point(-2.0)
	point(2.0)
	check(car.laps_done == 1,"已完成后倒退再压线不多计")
	fresh()
	point(-2.0)
	car._safe_reset._replayed_finishes = 1
	point(2.0)
	check(car.laps_done == 0,"倒退与安全回退同时存在不计圈")
	forward_lap()
	check(car.laps_done == 1,"同一次回放只抵消一次，下一正常圈不漏计")
	fresh()
	car._safe_reset._replayed_finishes = 1
	forward_lap()
	check(car.laps_done == 0,"只由R回退的终点回放仍不计圈")
	forward_lap()
	check(car.laps_done == 1,"R回放后正常下一圈仍计圈")
	check_ai_laps(road, gs.race_start_ms)
	var driver = load("res://scripts/autopilot.gd").new()
	driver.setup(car,null,null)
	var line = load("res://scripts/racing_line.gd")
	for speed: float in [10.0,37.0]:
		for grip: float in [1.0,0.5]:
			for side: float in [-1.0,1.0]:
				gs.release_drive_input()
				car.basis = Basis.IDENTITY
				car.linear_velocity = Vector3(0,0,-speed)
				car._steering_grip = grip
				car._steer = 0.0
				var aim := Vector3(side*9.0,0,-44.0)
				var nose := Vector3.FORWARD
				var angle := atan2(nose.cross(aim.normalized()).y,nose.dot(aim.normalized()))
				var wanted: float = line.pursuit_steering(angle,aim.length(),car._wheel_base,speed,16.0*grip)
				driver._drive_obstacle_steering(aim,16.0*grip)
				car._update_steering(1.0)
				check(absf(car.steering-wanted)<0.0001,"autopilot真实Input传递所需舵角 speed=%.1f grip=%.1f side=%.0f wanted=%.5f actual=%.5f" % [speed,grip,side,wanted,car.steering])
	gs.release_drive_input()
	print("LAP_BOUNDARY_RESULT passed=%d failed=%d" % [passed,failed])
	car.free()
	road.free()
	quit(1 if failed else 0)


func check_ai_laps(road: Node3D, go_ms: int) -> void:
	var ai := VehicleBody3D.new()
	root.add_child(ai)
	ai.set_script(load("res://scripts/ai_opponent.gd"))
	ai.set_physics_process(false)
	ai.track = road
	ai.laps_target = 1
	ai._race_laps.configure(road, road.rail_half_width() * 2.0)
	ai.begin_lap_timing(go_ms)
	var finishes := [0]
	ai.race_finished.connect(func(_laps: int): finishes[0] += 1)
	for point_on_track: Vector3 in [Vector3(-2,0,0), Vector3(2,0,0), Vector3(-2,0,0), Vector3(2,0,0)]:
		ai.global_position = point_on_track
		ai._update_progress()
	check(ai.laps_done() == 0 and finishes[0] == 0, "AI 首发和反向返回遵循相同压线规则")
	for lap in range(2):
		for point_on_track: Vector3 in [Vector3(20,0,100), Vector3(-20,0,100), Vector3(-2,0,0), Vector3(2,0,0)]:
			ai.global_position = point_on_track
			ai._update_progress()
	check(ai.laps_done() == 1 and ai.lap_times.size() == 1 and finishes[0] == 1,
		"AI 达到目标后只记录一次完赛")
	ai.free()
