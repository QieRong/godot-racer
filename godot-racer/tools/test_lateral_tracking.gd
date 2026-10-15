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
	print("%s circular path uses wheelbase curvature, expected %.5f got %.5f" % ["PASS" if ok else "FAIL", expected, actual])
	if not ok:
		failures += 1
	ai.free()
	track.free()
	print("LATERAL_FAILURES=%d" % failures)
	quit(1 if failures > 0 else 0)
