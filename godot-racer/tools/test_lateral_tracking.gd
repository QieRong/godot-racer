extends SceneTree
## L4：在真 AI 控制入口验证圆弧追线曲率，不另写一份控制器。

class CircleTrack extends Node3D:
	var radius := 142.0
	func centerline_point(arc: float) -> Vector3:
		var angle := arc / radius
		return Vector3(radius * (1.0 - cos(angle)), 0.0, -radius * sin(angle))
	func centerline_forward(arc: float) -> Vector3:
		var angle := arc / radius
		return Vector3(sin(angle), 0.0, -cos(angle))

class TrackingCar extends "res://scripts/ai_opponent.gd":
	func _ready() -> void:
		set_physics_process(false)

var failures := 0
var executed := 0

func expect(ok: bool, label: String) -> void:
	executed += 1
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var track := CircleTrack.new()
	root.add_child(track)
	var ai := TrackingCar.new()
	root.add_child(ai)
	ai.track = track
	ai.set("_lane_now", 0.0)
	ai.set("_arc", 0.0)
	ai.set("_wheel_base", 2.6)
	ai.max_lateral_accel = 16.0
	ai.linear_velocity = Vector3(0.0, 0.0, -30.0)
	ai.call("_update_steering", 1.0)
	var expected := -atan(2.6 / track.radius)
	var actual := ai.steering
	var ok := absf(actual - expected) < 0.001
	expect(ok, "circular path uses wheelbase curvature, expected %.5f got %.5f" % [expected, actual])
	# 另一方向与不同速度仍应跟同一条圆弧，不因瞄准距离变化改变稳态半径。
	for radius in [-142.0, 142.0]:
		track.radius = radius
		for speed in [10.0, 20.0, 30.0]:
			ai.linear_velocity = Vector3(0.0, 0.0, -speed)
			ai.set("_steer", 0.0)
			ai.call("_update_steering", 1.0)
			expect(absf(ai.steering + atan(2.6 / radius)) < 0.001,
				"circle radius %.0fm tracked at %.0fm/s" % [radius, speed])
	track.radius = 142.0
	ai.linear_velocity = Vector3(0.0, 0.0, -60.0)
	ai.max_lateral_accel = 8.0
	ai.set("_steer", 0.0)
	ai.call("_update_steering", 1.0)
	expect(absf(ai.steering) <= atan(2.6 * 8.0 / 3600.0) + 0.00001,
		"low grip caps requested lateral acceleration")
	ai.linear_velocity = Vector3(0.0, 0.0, -10.0)
	ai.max_lateral_accel = 16.0
	ai.set("_steer", 0.0)
	ai.call("_update_steering", 0.001)
	expect(absf(ai.steering) <= ai.steer_speed * 0.001 + 0.00001,
		"existing wheel response rate remains authoritative")
	ai.free()
	track.free()
	print("LATERAL_EXECUTED=%d LATERAL_FAILURES=%d" % [executed, failures])
	quit(1 if failures > 0 else 0)
