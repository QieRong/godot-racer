extends RefCounted
## 本机、联机和 AI 共用的车轮执行层。调用方负责决定油门、制动和舵角。

static func throttle(prefix: String) -> float:
	return Input.get_axis(prefix + "brake_reverse", prefix + "accelerate")


static func steering_input(prefix: String) -> float:
	return Input.get_axis(prefix + "steer_right", prefix + "steer_left")


static func sample_input(prefix: String) -> Dictionary:
	return {"throttle":throttle(prefix), "steering":steering_input(prefix),
		"handbrake":Input.is_action_pressed(prefix + "handbrake"),
		"drift":Input.is_action_pressed(prefix + "drift")}


static func apply_drive(wheels: Array[VehicleWheel3D], driven: Array[VehicleWheel3D],
		intent: float, forward_power: float, reverse_power: float, brake: float) -> void:
	# 车体朝本地 -Z，负轮力驱动车辆前进。正负油门使用各自的功率上限。
	var force := -intent * (forward_power if intent >= 0.0 else reverse_power)
	for wheel in driven:
		wheel.engine_force = force
	for wheel in wheels:
		wheel.brake = brake


static func hold(wheels: Array[VehicleWheel3D], brake: float) -> void:
	apply_drive(wheels, wheels, 0.0, 0.0, 0.0, brake)


static func steer(car: VehicleBody3D, angle: float) -> void:
	car.steering = angle
