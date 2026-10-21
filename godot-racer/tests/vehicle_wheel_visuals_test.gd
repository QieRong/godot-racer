extends SceneTree
## SPLIT-VEHICLE-001：车轮动画迁移前后使用同一确定性采样，不是驾驶/物理验收。
## 冻结真实车辆，仅为动画输入设置速度/转角；验证其不写车体物理状态。

var passed := 0
var failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var car: VehicleBody3D = load("res://scenes/race_car.tscn").instantiate()
	car.freeze = true
	car.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(car)
	car.get_node("EngineSound").stop()
	var entries: Array = car.get("_wheel_visuals")
	_check(entries.size() == 4, "真实模型绑定四个车轮")
	car.linear_velocity = Vector3(0.0, 0.0, -12.0)
	car.steering = 0.2
	var pose := car.global_transform
	for tick in range(10):
		car.call("_update_wheel_visuals", 1.0 / 120.0)
	var sample: Array = []
	for entry in entries:
		var wheel: VehicleWheel3D = entry["wheel"]
		var meshes: Array = entry["meshes"]
		_check(meshes.size() == 3, "%s 轮胎/轮圈/轮毂均绑定" % wheel.name)
		var want := 2.9411764706 if wheel.use_as_steering else 2.0
		_check(absf(float(entry["angle"]) - want) < 0.00001, "%s 视觉前进一米" % wheel.name)
		for mesh in meshes:
			var node: Node3D = mesh
			var b := node.basis
			sample.append({"wheel": str(wheel.name), "mesh": str(node.name),
				"basis": [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z]})
	_check(car.global_transform == pose, "动画不改变车体变换")
	_check(car.linear_velocity == Vector3(0.0, 0.0, -12.0), "动画不改变车体速度")
	print("WHEEL_VISUAL_SAMPLE|" + JSON.stringify(sample))
	car.linear_velocity = Vector3(0.0, 0.0, 12.0)
	for tick in range(10):
		car.call("_update_wheel_visuals", 1.0 / 120.0)
	for entry in entries:
		_check(absf(float(entry["angle"])) < 0.00001, "倒车一米抵消车轮自转")
	car.free()
	print("WHEEL_VISUAL_SUMMARY pass=%d fail=%d" % [passed, failed])
	print("WHEEL_VISUAL_PASS" if failed == 0 else "WHEEL_VISUAL_FAIL")
	quit(0 if failed == 0 else 1)


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("PASS " + label)
	else:
		failed += 1
		print("FAIL " + label)
