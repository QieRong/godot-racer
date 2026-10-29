extends RefCounted
## 隔离验证的街机抗侧倾辅助。只施加物理滚转力矩，不修改速度/姿态/质量/悬挂。
## 路面方向来自既有surface_frame；完全腾空或已经侧立时交还原恢复系统。
var roll_stiffness := 45.0
var roll_damping := 12.0
var max_torque_per_kg := 30.0
var frames_applied := 0

func compute_torque(pose: Basis, angular_velocity: Vector3, road_up: Vector3,
		body_mass: float, support_wheels: int, height_gap: float) -> Vector3:
	if support_wheels < 2 or absf(height_gap) > 0.9 or body_mass <= 0.0:
		return Vector3.ZERO
	var axis := pose.z.normalized()
	var up := pose.y.normalized()
	var target := road_up.slide(axis).normalized()
	if target.is_zero_approx() or up.dot(target) < 0.5:
		return Vector3.ZERO
	var error := atan2(up.cross(target).dot(axis), up.dot(target))
	var effort := error * roll_stiffness - angular_velocity.dot(axis) * roll_damping
	return axis * clampf(effort, -max_torque_per_kg, max_torque_per_kg) * body_mass

func tick(car: VehicleBody3D, track: Node3D) -> void:
	if not is_instance_valid(car) or not is_instance_valid(track): return
	var support := int(car.call("grounded_wheel_count"))
	if support < 2: return
	var near: Dictionary = car.call("_nearest_track_point")
	if near.is_empty(): return
	var surface: Transform3D = track.call("surface_frame", float(near.arc), 0.0)
	var torque := compute_torque(car.global_basis, car.angular_velocity, surface.basis.y,
		car.mass, support, car.global_position.y - Vector3(near.pos).y)
	if not torque.is_zero_approx():
		car.apply_torque(torque)
		frames_applied += 1
