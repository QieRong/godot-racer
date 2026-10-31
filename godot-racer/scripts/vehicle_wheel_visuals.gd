extends RefCounted
## SPLIT-VEHICLE-001：从 vehicle.gd 原位迁出的纯视觉车轮绑定与动画。
## 调用相位、条目状态和自转公式保持不变；不写车体物理状态，无 await。

static func _find_wheel(car: VehicleBody3D, key: String) -> VehicleWheel3D:
	var want := key.replace("_", "")
	for child in car.get_children():
		if child is VehicleWheel3D:
			var n: String = child.name.to_lower().replace("wheel", "").replace("_", "")
			if n == want:
				return child
	return null


static func bind(car: VehicleBody3D, entries: Array, enabled: bool) -> void:
	if not enabled:
		return
	var model_node := car.get_node_or_null("CarModel")
	if not (model_node is Node3D):
		push_warning("没有 CarModel 节点，车轮动画跳过")
		return
	var model: Node3D = model_node

	var corners := {
		"front_left": ["Tire_Front_L", "Rim_Front_L", "Hub_Front_L"],
		"front_right": ["Tire_Front_R", "Rim_Front_R", "Hub_Front_R"],
		"rear_left": ["Tire_Rear_L", "Rim_Rear_L", "Hub_Rear_L"],
		"rear_right": ["Tire_Rear_R", "Rim_Rear_R", "Hub_Rear_R"],
	}
	for key in corners.keys():
		var wheel := _find_wheel(car, key)
		if wheel == null:
			continue
		var meshes: Array[Node3D] = []
		var rests: Array[Basis] = []
		var spins: Array[Vector3] = []
		var ups: Array[Vector3] = []
		for nm in corners[key]:
			var n := model.find_child(nm, true, false)
			if not (n is Node3D):
				continue
			var node: Node3D = n
			meshes.append(node)
			rests.append(node.basis)
			spins.append((node.global_transform.basis.inverse() * model.global_transform.basis.z).normalized())
			ups.append((node.global_transform.basis.inverse() * model.global_transform.basis.y).normalized())
		if meshes.is_empty():
			continue
		entries.append({
			"wheel": wheel,
			"meshes": meshes,
			"rests": rests,
			"spins": spins,
			"ups": ups,
			"angle": 0.0,
		})
	print("[车辆] 车轮视觉已绑定 %d 个角（自转轴 = 模型 Z 轴）" % entries.size())


static func update(car: VehicleBody3D, entries: Array, delta: float) -> void:
	if entries.is_empty():
		return
	var forward_speed := car.linear_velocity.dot(-car.global_transform.basis.z)
	for entry in entries:
		var wheel: VehicleWheel3D = entry["wheel"]
		if wheel == null or not is_instance_valid(wheel):
			continue
		var radius: float = maxf(wheel.wheel_radius, 0.05)
		var angle: float = float(entry["angle"]) + forward_speed / radius * delta
		entry["angle"] = angle
		var steer: float = car.steering if wheel.use_as_steering else 0.0
		var meshes: Array = entry["meshes"]
		var rests: Array = entry["rests"]
		var spins: Array = entry["spins"]
		var ups: Array = entry["ups"]
		for i in meshes.size():
			var node: Node3D = meshes[i]
			var rest: Basis = rests[i]
			var up: Vector3 = ups[i]
			var spin_axis: Vector3 = spins[i]
			node.basis = rest * Basis(up, steer) * Basis(spin_axis, angle)


static func start_burnout(entries: Array, delta: float) -> void:
	# 沿用绑定好的轮网格/自转轴，只转后轮视觉，不改VehicleWheel的物理状态。
	for entry in entries:
		if not entry.wheel.use_as_traction: continue
		entry.angle = fposmod(float(entry.angle)+delta*35.0,TAU)
		for i in range(entry.meshes.size()):
			entry.meshes[i].basis = entry.rests[i] * Basis(entry.spins[i],entry.angle)


