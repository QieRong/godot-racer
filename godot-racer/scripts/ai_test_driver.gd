extends Node
## 本地确定性"鲁莽玩家"压测器（**默认的测试主力，不依赖任何网络**）。
##
## 为什么本地确定性比"每帧调 AI 开车"更适合找 bug：
##   ① 可复现：固定种子 → 同样的输入序列 → 同样的失败点，改完能立刻回归；
##   ② 够快：不联网，一秒能跑几千帧，一次压测能覆盖几十种极端操作组合；
##   ③ AI 开车反而测不出东西：免费额度下延迟几秒，车早就撞墙了，
##      而且每次结果都不同，无法判断"这次修好了没有"。
##   AI 的用武之地是**生成用例参数**与**归因日志**（见 openrouter_client.gd）。
##
## 注入方式（在 main.gd 里按需创建）：
##   var driver := AiTestDriver.new()
##   driver.mode = AiTestDriver.Mode.RECKLESS
##   add_child(driver)
##   var report := await driver.stress_test(60.0)

const OpenRouterClientScript := preload("res://scripts/openrouter_client.gd")

enum Mode {
	RECKLESS,     ## 乱打方向 + 猛油猛刹（模拟鲁莽玩家）
	WALL_PUSH,    ## 专挑墙怼（贴墙/正对墙）
	RANDOM_START, ## 随机瞬移到极端位置看兜底是否生效
}

## 运行模式
var mode := Mode.RECKLESS
## 固定随机种子：保证失败可复现（这是这套测试的核心价值）
var seed_value := 20260919
## 单次操作的持续帧数范围（模拟人手按键时长不均）
var action_min_frames := 6
var action_max_frames := 90

## 由外部注入：要测的车与赛道
var car: VehicleBody3D = null
var track: Node3D = null
## 可选的 AI 用例来源（没网络时保持 null，自动走本地随机）
var ai_cases: Array = []

var _rng := RandomNumberGenerator.new()
var _openrouter: Node = null


func _ready() -> void:
	_rng.seed = seed_value
	# 预留的 AI 通道：可用时用 AI 生成用例，不可用就静默跳过
	_openrouter = OpenRouterClientScript.new()
	add_child(_openrouter)


## 压测：跑 duration_sec 秒，返回报告字典。
## 判定"卡住"的标准来自用户的原始报障：
##   车速长期接近 0 且位置几乎不动（说明被墙咬住/卡死，而不是在正常慢速过弯）。
func stress_test(duration_sec: float) -> Dictionary:
	var report := {
		"mode": mode,
		"frames": 0,
		"stuck_events": 0,
		"stuck_positions": [],
		"resets": 0,
		"max_deviation": 0.0,
		"ai_cases_used": 0,
		"ok": true,
	}
	if car == null or track == null:
		report["ok"] = false
		report["error"] = "没有注入 car/track"
		return report

	# AI 用例（可选）：拿到了就先瞬移跑一轮随机起点
	if not ai_cases.is_empty():
		report["ai_cases_used"] = await _run_ai_cases(ai_cases)
	elif _openrouter != null and bool(_openrouter.get("available")):
		var hint := "椭圆赛道，含 S 弯关卡" if float(track.get("s_curve_amplitude")) > 0.1 else "椭圆赛道"
		var cases: Array = await _openrouter.call("generate_test_cases", 20, hint)
		if not cases.is_empty():
			ai_cases = cases
			report["ai_cases_used"] = await _run_ai_cases(cases)

	var hz := float(Engine.physics_ticks_per_second)
	var total := int(hz * duration_sec)
	var last_pos: Vector3 = car.global_position
	var still_frames := 0
	for i in range(total):
		_drive_step()
		await get_tree().physics_frame
		report["frames"] = i + 1
		# 卡住判定：连续 3 秒速度 < 0.4 m/s 且位移 < 0.5m
		var moved := last_pos.distance_to(car.global_position)
		var slow := car.linear_velocity.length() < 0.4
		if slow and moved < 0.5 / hz * 3.0:
			still_frames += 1
		else:
			still_frames = 0
		last_pos = car.global_position
		if still_frames >= int(hz * 3.0):
			report["stuck_events"] += 1
			report["stuck_positions"].append(str(car.global_position))
			report["ok"] = false
			# 记录一次就复位继续跑，避免整段测试都卡在同一个点
			if car.has_method("reset_to_track"):
				car.call("reset_to_track")
			still_frames = 0
		var near: Dictionary = track.call("nearest_on_centerline", car.global_position, -1.0)
		report["max_deviation"] = maxf(report["max_deviation"], float(near.get("dist", 0.0)))
	return report


## 随机瞬移到极端位置，验证复位/兜底一定能把车弄回赛道
func _run_ai_cases(cases: Array) -> int:
	var used := 0
	for c in cases:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var pos = c.get("pos", null)
		if typeof(pos) != TYPE_ARRAY or (pos as Array).size() < 3:
			continue
		car.global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		car.linear_velocity = Vector3.ZERO
		await get_tree().physics_frame
		if car.has_method("reset_to_track"):
			car.call("reset_to_track")
		await get_tree().physics_frame
		var near: Dictionary = track.call("nearest_on_centerline", car.global_position, -1.0)
		var road_half := float(track.call("road_half_width"))
		if float(near.get("dist", 999.0)) > road_half:
			print("[压测] AI 用例未回到路面：%s → %s（偏离 %.2fm）"
				% [c.get("note", "?"), car.global_position, float(near.get("dist", 0.0))])
		used += 1
	return used


## 一拍操作：按模式随机决定油门/方向，模拟真实玩家的手抖
func _drive_step() -> void:
	match mode:
		Mode.WALL_PUSH:
			Input.action_press("accelerate")
			# 只朝一侧猛打方向，专门往墙上蹭
			Input.action_press("steer_right")
		_:
			# 每 N 帧换一次操作，N 随机（模拟时长不均的按键）
			if _rng.randi_range(0, action_max_frames) < action_min_frames:
				_release_all()
				if _rng.randf() < 0.75:
					Input.action_press("accelerate")
				elif _rng.randf() < 0.5:
					Input.action_press("brake_reverse")
				var r := _rng.randf()
				if r < 0.35:
					Input.action_press("steer_left")
				elif r < 0.7:
					Input.action_press("steer_right")
				if _rng.randf() < 0.08:
					Input.action_press("handbrake")


func _release_all() -> void:
	for a in ["accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake"]:
		Input.action_release(a)


func stop() -> void:
	_release_all()
