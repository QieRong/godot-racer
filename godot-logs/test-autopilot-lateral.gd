extends SceneTree
## 公共 drive_track → Input → 真实玩家转向，证明有障碍时二值输入的曲率误差。
const Pilot := preload("res://scripts/autopilot.gd")
const Field := preload("res://scripts/obstacle_field.gd")
const Diag := preload("res://scripts/l4_debug_diag.gd")

class CircleTrack extends Node3D:
	var radius := 142.0
	func centerline_point(arc: float) -> Vector3:
		var angle := arc / radius
		return Vector3(radius * (1.0 - cos(angle)), 0.0, -radius * sin(angle))
	func centerline_forward(arc: float) -> Vector3:
		return Vector3(sin(arc / radius), 0.0, -cos(arc / radius))
	func nearest_on_centerline(_pos: Vector3, _hint: float) -> Dictionary:
		return {"arc": 0.0, "pos": Vector3.ZERO, "forward": Vector3.FORWARD}
	func road_half_width() -> float:
		return 5.0
	func road_length() -> float:
		return TAU * radius

class PlayerCar extends "res://scripts/vehicle.gd":
	func _ready() -> void:
		set_physics_process(false)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var track := CircleTrack.new()
	root.add_child(track)
	var car := PlayerCar.new()
	# @onready 仍会在重写 _ready 的夹具中执行，补齐真实脚本所需节点。
	var sound := AudioStreamPlayer3D.new()
	sound.name = "EngineSound"
	car.add_child(sound)
	root.add_child(car)
	car.set("_wheel_base", 2.6)
	car.linear_velocity = Vector3(0.0, 0.0, -30.0)
	var field := Field.new()
	root.add_child(field)
	field.set("_total_len", 2000.0)
	field.obstacles.append({"arc": 1000.0, "lateral": 0.0, "half_width": 0.95, "kind": "rock"})
	var diag := Diag.new()
	diag.setup(car, field, 0.875, 45.0)
	var pilot := Pilot.new()
	pilot.setup(car, field, diag)
	pilot.drive_track(track, 45.0)
	car.call("_update_steering", 1.0)
	var expected := -atan(2.6 / track.radius)
	var actual := car.steering
	var ok := absf(actual - expected) < 0.001
	print("%s player obstacle path follows circle curvature: expected %.5f got %.5f" % ["PASS" if ok else "FAIL", expected, actual])
	for action in ["steer_left", "steer_right", "accelerate", "brake_reverse", "handbrake"]:
		Input.action_release(action)
	car.free()
	field.free()
	track.free()
	print("AUTOPILOT_FAILURES=%d" % (0 if ok else 1))
	quit(0 if ok else 1)
