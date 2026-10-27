extends "res://tests/track_drive_test.gd"
## 只增加障碍接触的只读观察；驾驶、计圈和逐帧判据复用原专项。
var obstacle_contacts := 0
var watched := false

func _process(_delta: float) -> bool:
	if watched or current_scene == null: return false
	var cars: Variant = current_scene.get("_opponents")
	if not cars is Array or cars.is_empty(): return false
	var ai: RigidBody3D = cars[0]
	ai.contact_monitor = true
	ai.max_contacts_reported = 16
	ai.body_entered.connect(func(body: Node):
		if body.name == "ObstacleBody": obstacle_contacts += 1)
	watched = true
	return false

func run() -> void:
	await super.run()
	# super调用quit只安排退出，当前协程仍可追加检查并纠正退出码。
	check(watched and obstacle_contacts == 0, "全程实际物理接触监视：零静态障碍接触")
	FileAccess.open(output.path_join("obstacle-contacts.json"), FileAccess.WRITE).store_string(
		JSON.stringify({"watched": watched, "obstacle_contacts": obstacle_contacts}))
	print("VARIANT_DRIVE_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
