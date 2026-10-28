extends "res://tests/track_drive_test.gd"
## 复用既有逐物理帧只读记录器；只改变输入关卡资源，不改车辆或判据。
func run() -> void:
	var state := root.get_node("GameState")
	var cfg: Resource = state.get_level(selected_level)
	cfg.elevation_profile = "0:0, 0.08:0, 0.30:16, 0.56:0, 0.78:8, 0.92:0, 1:0"
	cfg.max_grade = 0.08
	await super.run()
