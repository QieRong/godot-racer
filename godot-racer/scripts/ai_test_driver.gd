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

## 保留一个 preload 引用：让 openrouter_client.gd 在**加载期**就被解析一遍，
## 写错语法时立刻炸出来，而不是等压测跑到一半才发现。
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
## 可选的 AI 用例来源（有网络时由本脚本自动向 OpenRouter 索取）
var ai_cases: Array = []
## 想向 AI 要几组用例。
## 定在 8 而不是 20/12：实测主模型输出越长越容易撞上超时（4096 token 输出 >45s），
## 8 组刚好在"覆盖足够边界"和"能在截止时间内返回"之间平衡；超时也有备用模型兜底。
var ai_case_count := 8

var _rng := RandomNumberGenerator.new()
var _openrouter: Node = null


func _ready() -> void:
	_rng.seed = seed_value
	# AI 通道：可用时用 AI 生成用例，不可用就静默降级到本地随机。
	# 这层**绝不会**阻塞或打断压测 —— 见 openrouter_client 的 _await_response。
	var ai_script: GDScript = OpenRouterClientScript
	_openrouter = ai_script.new()
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

	# AI 用例（可选）：拿到了就先瞬移跑一轮随机起点；
	# 拿不到（无 key / 429 / 401 / 超时）就走下面的本地随机 —— 不报错、不停机。
	if not ai_cases.is_empty():
		var r0 := await _run_ai_cases(ai_cases)
		report["ai_cases_used"] = int(r0.get("used", 0))
		report["ai_failures"] = int(r0.get("failed", 0))
	elif _openrouter != null and bool(_openrouter.get("available")):
		var hint := "椭圆赛道，含 S 弯关卡" if float(track.get("s_curve_amplitude")) > 0.1 else "椭圆赛道"
		print("[压测] 向 AI 索取 %d 组极端测试用例（模型 %s）…"
			% [ai_case_count, str(_openrouter.get("model"))])
		var cases: Array = await _openrouter.call("generate_test_cases", ai_case_count, hint)
		if not cases.is_empty():
			ai_cases = cases
			var r1 := await _run_ai_cases(cases)
			report["ai_cases_used"] = int(r1.get("used", 0))
			report["ai_failures"] = int(r1.get("failed", 0))
		else:
			report["ai_note"] = "AI 不可用，已降级为本地确定性用例（原因：%s）" % str(_openrouter.get("last_error"))
			printerr("[压测] %s" % report["ai_note"])
			report["degraded"] = true

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


## 随机瞬移到 AI 指定的极端位置，验证复位/兜底一定能把车弄回赛道。
## 返回 {"used": 实际执行数, "failed": 兜底失败数}。
func _run_ai_cases(cases: Array) -> Dictionary:
	var used := 0
	var failed := 0
	for c in cases:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var pos = c.get("pos", null)
		if typeof(pos) != TYPE_ARRAY or (pos as Array).size() < 3:
			continue
		var note := str(c.get("note", "?"))
		car.global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		car.linear_velocity = Vector3.ZERO
		await get_tree().physics_frame
		if car.has_method("reset_to_track"):
			car.call("reset_to_track")
		await get_tree().physics_frame
		var near: Dictionary = track.call("nearest_on_centerline", car.global_position, -1.0)
		var road_half := float(track.call("road_half_width"))
		var dist := float(near.get("dist", 999.0))
		used += 1
		if dist > road_half:
			failed += 1
			printerr("[压测] AI 用例兜底失败：%s → %s（偏离路面中心线 %.2fm > 半路宽 %.2fm）"
				% [note, car.global_position, dist, road_half])
		else:
			print("[压测] AI 用例通过：%s（复位后偏离中心线 %.2fm）" % [note, dist])
	return {"used": used, "failed": failed}


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
