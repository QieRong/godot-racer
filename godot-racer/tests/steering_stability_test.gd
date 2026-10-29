extends SceneTree
## 物理力矩契约：只影响车身滚转，不直接改姿态/速度；空中及已侧立不抢R的职责。
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("STEERING_STABILITY_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	var path := "res://scripts/vehicle_steering_stability.gd"
	check(ResourceLoader.exists(path), "隔离物理抗侧倾模块存在")
	if failed > 0:
		print("STEERING_STABILITY_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
		quit(1)
		return
	var assist: RefCounted = load(path).new()
	var identity := Basis.IDENTITY
	var zero: Vector3 = assist.compute_torque(identity, Vector3.ZERO, Vector3.UP, 1200.0, 4, 0.0)
	check(zero.is_zero_approx(), "平路平稳时不凭空施加转向/翻滚力矩")
	for contacts in [0, 1]:
		var torque: Vector3 = assist.compute_torque(Basis(Vector3.BACK, 0.2), Vector3.ZERO,
			Vector3.UP, 1200.0, contacts, 0.0)
		check(torque.is_zero_approx(), "%d轮接地时不在空中强行扶正" % contacts)
	for angle in [-0.3, 0.3]:
		var torque: Vector3 = assist.compute_torque(Basis(Vector3.BACK, angle), Vector3.ZERO,
			Vector3.UP, 1200.0, 4, 0.0)
		check(torque.z * angle < 0.0, "左右侧倾的力矩均指向路面法线")
		check(absf(torque.x) < 0.001 and absf(torque.y) < 0.001, "只作用于滚转轴")
	var damping: Vector3 = assist.compute_torque(identity, Vector3(0, 0, 2.0), Vector3.UP, 1200.0, 4, 0.0)
	check(damping.z < 0.0, "滚转角速度有阻尼")
	var yaw: Vector3 = assist.compute_torque(identity, Vector3(0, 2.0, 0), Vector3.UP, 1200.0, 4, 0.0)
	check(yaw.is_zero_approx(), "不抹掉驾驶转弯的偏航角速度")
	var slope := Basis(Vector3.RIGHT, 0.25) * Basis(Vector3.BACK, 0.15)
	var aligned: Vector3 = assist.compute_torque(slope, Vector3.ZERO, slope.y, 1200.0, 4, 0.0)
	check(aligned.is_zero_approx(), "贴合真实坡面时不强行对齐世界竖直")
	var high: Vector3 = assist.compute_torque(Basis(Vector3.BACK, 0.2), Vector3.ZERO,
		Vector3.UP, 1200.0, 4, 1.5)
	check(high.is_zero_approx(), "离路较高时不施力")
	var flipped: Vector3 = assist.compute_torque(Basis(Vector3.BACK, PI / 2.0), Vector3.ZERO,
		Vector3.UP, 1200.0, 2, 0.0)
	check(flipped.is_zero_approx(), "已侧立时由原扶正/R系统处理")
	var cap: Vector3 = assist.compute_torque(Basis(Vector3.BACK, 0.8), Vector3(0, 0, -50),
		Vector3.UP, 1200.0, 4, 0.0)
	check(cap.length() <= 1200.0 * float(assist.max_torque_per_kg) + 0.001, "最大力矩有硬上限")
	print("STEERING_STABILITY_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
