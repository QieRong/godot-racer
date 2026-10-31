extends SceneTree
## 注入真实 Joypad 事件检查动作映射；不代替外接手柄和手机体验验收。
const Overlay := preload("res://scripts/menu_overlay.gd")
const RacingLine := preload("res://scripts/racing_line.gd")
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("GAMEPAD_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func axis(which: JoyAxis, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = 0
	event.axis = which
	event.axis_value = value
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func button(which: JoyButton, down: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = 0
	event.button_index = which
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func run() -> void:
	axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	check(Input.get_action_strength("accelerate") > 0.99, "右扳机全油门")
	axis(JOY_AXIS_TRIGGER_RIGHT, 0.6)
	check(Input.get_action_strength("accelerate") > 0.1 and Input.get_action_strength("accelerate") < 0.9, "右扳机支持模拟量")
	axis(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	check(not Input.is_action_pressed("accelerate"), "松开右扳机清油门")
	axis(JOY_AXIS_TRIGGER_LEFT, 1.0)
	check(Input.get_axis("brake_reverse", "accelerate") < -0.99, "左扳机进入同一制动/倒车动作")
	axis(JOY_AXIS_TRIGGER_LEFT, 0.0)
	axis(JOY_AXIS_LEFT_X, -1.0)
	check(Input.get_axis("steer_right", "steer_left") > 0.99, "左摇杆左推沿用车辆正转向约定")
	axis(JOY_AXIS_LEFT_X, 1.0)
	check(Input.get_axis("steer_right", "steer_left") < -0.99, "左摇杆右推沿用车辆负转向约定")
	axis(JOY_AXIS_LEFT_X, 0.1)
	check(is_zero_approx(Input.get_axis("steer_right", "steer_left")), "摇杆死区过滤小幅漂移")
	axis(JOY_AXIS_LEFT_X, 0.0)
	for pair in [[JOY_BUTTON_X, "handbrake"], [JOY_BUTTON_Y, "camera_view"],
			[JOY_BUTTON_BACK, "reset"], [JOY_BUTTON_RIGHT_SHOULDER, "camera_rear"], [JOY_BUTTON_START, "ui_cancel"]]:
		button(pair[0], true)
		check(Input.is_action_pressed(pair[1]), "手柄按键接入 %s" % pair[1])
		button(pair[0], false)
		check(not Input.is_action_pressed(pair[1]), "手柄松键释放 %s" % pair[1])
	check(InputMap.action_get_events("accelerate").any(func(event): return event is InputEventKey), "保留键盘油门")
	var original := InputMap.action_get_events("accelerate")
	InputMap.action_erase_events("accelerate")
	var trigger := InputEventJoypadMotion.new()
	trigger.axis = JOY_AXIS_TRIGGER_RIGHT
	trigger.axis_value = 1.0
	InputMap.action_add_event("accelerate", trigger)
	var overlay := Overlay.new()
	check(String(overlay.call("_binding", "accelerate", "W")).contains("右扳机"), "只有手柄绑定时帮助不谎报W键")
	overlay.free()
	InputMap.action_erase_events("accelerate")
	for event in original: InputMap.action_add_event("accelerate", event)
	for path in ["res://scripts/vehicle.gd", "res://scripts/ai_opponent.gd"]:
		var car: VehicleBody3D = load(path).new()
		check(is_equal_approx(float(car.get("max_lateral_accel")), RacingLine.GRIP_BASE), "玩家/AI默认抓地力同源且数值不变：%s" % path)
		car.free()
	print("GAMEPAD_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
