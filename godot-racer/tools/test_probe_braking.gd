extends SceneTree
## BUG-L5-001：真实 AI 限速入口的近障碍地板，不替换限速实现。
const Racing := preload("res://scripts/racing_line.gd")

class StraightTrack extends Node3D:
	func centerline_point(arc: float) -> Vector3:
		return Vector3(0.0, 0.0, -arc)
	func centerline_forward(_arc: float) -> Vector3:
		return Vector3.FORWARD
	func nearest_on_centerline(pos: Vector3, _hint: float) -> Dictionary:
		return {"arc": -pos.z, "pos": Vector3(0.0, 0.0, pos.z), "forward": Vector3.FORWARD}
	func road_half_width() -> float:
		return 4.0

class ProbeCar extends "res://scripts/ai_opponent.gd":
	var obstacle_distance := INF
	func _ready() -> void:
		set_physics_process(false)
	func probe_ahead_m() -> float:
		return obstacle_distance

var failures := 0

func expect(ok: bool, label: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var track := StraightTrack.new()
	root.add_child(track)
	var ai := ProbeCar.new()
	root.add_child(ai)
	ai.track = track
	ai.speed_cap_kmh = 120.0
	ai.obstacle_distance = 0.8
	var target: float = ai.call("_target_speed")
	expect(is_equal_approx(target, 6.0), "near obstacle retains 6 km/h crawl instead of zero-speed fixed point (got %.3f)" % target)
	ai.obstacle_distance = 10.0
	target = ai.call("_target_speed")
	expect(target < 60.0 and target > 6.0, "10m obstacle slows before the old quadratic curve (got %.3f)" % target)
	var wheel := VehicleWheel3D.new()
	ai.add_child(wheel)
	ai.get("_all_wheels").append(wheel)
	ai.get("_drive_wheels").append(wheel)
	ai.linear_velocity = Vector3(0.0, 0.0, -50.0 / 3.6)
	ai.call("_update_drive")
	expect(wheel.brake >= 30.0 and is_zero_approx(wheel.engine_force), "braking-distance boundary bypasses 3m/s cruise deadzone (brake %.2f)" % wheel.brake)
	ai.obstacle_distance = 0.8
	ai.linear_velocity = Vector3(0.0, 0.0, -100.0 / 3.6)
	ai.call("_update_drive")
	expect(is_equal_approx(wheel.brake, 30.0), "probe uses exactly the calibrated force instead of extrapolating to 55 (brake %.2f)" % wheel.brake)
	expect(is_equal_approx(Racing.probe_speed_limit_kmh(0.2, 4.0, 11.3), 4.0), "probe floor cannot raise a lower physical cap")
	expect(is_equal_approx(Racing.probe_speed_limit_kmh(INF, 120.0, 11.3), 120.0), "no obstacle leaves cruise cap unchanged")
	var previous := 0.0
	for distance in [0.0, 1.0, 2.0, 4.0, 10.0, 18.0]:
		var value := Racing.probe_speed_limit_kmh(distance, 120.0, 11.3)
		expect(value >= previous and value >= 6.0 and value <= 120.0, "probe envelope monotone and bounded at %.1fm" % distance)
		expect(Racing.brake_distance(value, 6.0, 11.3) <= maxf(0.0, distance - 2.0) + 0.001, "envelope obeys shared braking distance at %.1fm" % distance)
		previous = value
	expect(Racing.probe_speed_limit_kmh(10.0, 120.0, 3.0) < Racing.probe_speed_limit_kmh(10.0, 120.0, 11.3), "lower available deceleration lowers admissible speed")
	ai.free()
	track.free()
	print("PROBE_FAILURES=%d" % failures)
	quit(1 if failures > 0 else 0)
