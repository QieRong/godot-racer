extends SceneTree
## 公共 drive_track → Input → 真实玩家转向，证明有障碍时二值输入的曲率误差。
const Pilot := preload("res://scripts/autopilot.gd")
const Field := preload("res://scripts/obstacle_field.gd")
const Diag := preload("res://scripts/l4_debug_diag.gd")

class CircleTrack extends Node3D:
	var radius := 142.0
	var level_config: Resource = null
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

class StraightTrack extends CircleTrack:
	func centerline_point(arc: float) -> Vector3:
		return Vector3(0.0, 0.0, -arc)
	func centerline_forward(_arc: float) -> Vector3:
		return Vector3.FORWARD

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
	field.set("track", track)
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
	var failures := 0 if ok else 1
	# 75m 的中心障碍在旧 45m 决策距离外，但在 30m/s × 3s 内。
	# 通过真实选道、目标点和输入输出断言提前避让，而非检查实现中的常量。
	var straight := StraightTrack.new()
	root.add_child(straight)
	field.set("track", straight)
	field.obstacles[0]["arc"] = 75.0
	car.set("_steer", 0.0)
	pilot.drive_track(straight, 45.0)
	car.call("_update_steering", 1.0)
	var avoids_early := absf(car.steering) > 0.001
	print("%s avoids obstacle 75m ahead at 30m/s: steering=%.5f" % ["PASS" if avoids_early else "FAIL", car.steering])
	if not avoids_early:
		failures += 1
	# 没有障碍时仍保留旧门限和满幅方向键（同一圆弧、同一车速）。
	field.obstacles.clear()
	car.set("_steer", 0.0)
	pilot.drive_track(track, 45.0)
	var empty_unchanged := is_equal_approx(Input.get_action_strength("steer_right"), 1.0)
	print("%s empty field retains original binary steering" % ["PASS" if empty_unchanged else "FAIL"])
	if not empty_unchanged:
		failures += 1
	pilot.setup(car, null, diag)
	pilot.drive_track(track, 45.0)
	var absent_unchanged := is_equal_approx(Input.get_action_strength("steer_right"), 1.0)
	print("%s absent field retains original binary steering" % ["PASS" if absent_unchanged else "FAIL"])
	if not absent_unchanged:
		failures += 1
	# 低速仍有 45m 选道距离；35m 处障碍应立即触发避让。
	pilot.setup(car, field, diag)
	field.obstacles.append({"arc": 35.0, "lateral": 0.0, "half_width": 0.95, "kind": "rock"})
	car.linear_velocity = Vector3(0.0, 0.0, -5.0)
	pilot.drive_track(straight, 45.0)
	var slow_avoids := absf(Input.get_axis("steer_right", "steer_left")) > 0.001
	print("%s low speed retains minimum decision distance" % ["PASS" if slow_avoids else "FAIL"])
	if not slow_avoids:
		failures += 1
	# 沿用真实侧倾保护：车身横倒时不得由连续输入重新抬高权限。
	car.rotation.z = PI * 0.5
	car.set("_steer", 0.0)
	pilot.drive_track(straight, 45.0)
	car.call("_update_steering", 1.0)
	var protected := is_zero_approx(car.steering)
	print("%s roll guard still suppresses steering" % ["PASS" if protected else "FAIL"])
	if not protected:
		failures += 1
	# 同一 R142m 圆弧上 216km/h 已超过 16m/s² 抓地模型允许速度。
	# 正常输入应收油并制动；不能靠直接改 linear_velocity 使读数变绿。
	car.rotation = Vector3.ZERO
	car.linear_velocity = Vector3(0.0, 0.0, -60.0)
	field.set("track", track)
	field.obstacles[0]["arc"] = 1000.0
	pilot.drive_track(track, 45.0)
	var brakes_for_curve := not Input.is_action_pressed("accelerate") and Input.is_action_pressed("handbrake")
	print("%s excessive curve speed releases throttle and brakes" % ["PASS" if brakes_for_curve else "FAIL"])
	if not brakes_for_curve:
		failures += 1
	for action in ["steer_left", "steer_right", "accelerate", "brake_reverse", "handbrake"]:
		Input.action_release(action)
	car.free()
	field.free()
	track.free()
	straight.free()
	print("AUTOPILOT_FAILURES=%d" % failures)
	quit(0 if failures == 0 else 1)
