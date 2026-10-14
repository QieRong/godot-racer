extends Node
## 本地确定性"鲁莽玩家"压测器（**测试主力，不依赖任何网络**）。
##
## 为什么本地确定性比"每帧调 AI 开车"更适合找 bug：
##   ① 可复现：固定种子 → 同样的输入序列 → 同样的失败点，改完能立刻回归；
##   ② 够快：不联网，一秒能跑几千帧，一次压测能覆盖几十种极端操作组合；
##   ③ AI 开车反而测不出东西：免费额度下延迟几秒，车早就撞墙了，
##      而且每次结果都不同，无法判断"这次修好了没有"。
##
## 备注：曾有一套"联网问 LLM 现生成用例 / 现问归因"的旁路，与游玩无关、
## 且每次结果不可复现，已于 2026-10-14 整体移除（见 push-log 与 HANDOVER）。
## 现在极端用例只来自**落盘的确定性用例文件**（离线算得），读不到就走本地随机。
##
## 注入方式（在 main.gd 里按需创建）：
##   var driver := AiTestDriver.new()
##   driver.mode = AiTestDriver.Mode.RECKLESS
##   add_child(driver)
##   var report := await driver.stress_test(60.0)

## 落盘的确定性极端用例：不联网、可复现、能进版本库。
const LOCAL_CASES_PATH := "res://data/ai_test_cases.json"

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
## 极端位置用例（默认从 LOCAL_CASES_PATH 读；也可由外部直接注入覆盖）
var cases: Array = []

var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = seed_value


## 读取落盘的确定性极端用例。
## 返回 {"ok": bool, "cases": Array, "meta": Dictionary, "error": String}
func _load_local_cases() -> Dictionary:
	if not FileAccess.file_exists(LOCAL_CASES_PATH):
		return {"ok": false, "cases": [], "meta": {}, "error": "没有 %s" % LOCAL_CASES_PATH}
	var f := FileAccess.open(LOCAL_CASES_PATH, FileAccess.READ)
	if f == null:
		return {"ok": false, "cases": [], "meta": {}, "error": "打不开用例文件"}
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "cases": [], "meta": {}, "error": "用例文件不是 JSON 对象"}
	var d: Dictionary = parsed
	if not d.has("cases") or typeof(d["cases"]) != TYPE_ARRAY:
		return {"ok": false, "cases": [], "meta": {}, "error": "用例文件里没有 cases 数组"}
	var arr: Array = d["cases"]
	var meta := {
		"model": str(d.get("model", "?")),
		"generated_at": str(d.get("generated_at", "?")),
		"level_name": str(d.get("level_name", "?")),
		"requested": int(d.get("requested", 0)),
		"accepted": int(d.get("accepted", arr.size())),
	}
	return {"ok": true, "cases": arr, "meta": meta, "error": ""}


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
		"cases_used": 0,
		"ok": true,
	}
	if car == null or track == null:
		report["ok"] = false
		report["error"] = "没有注入 car/track"
		return report

	# 极端用例（可选）：优先读开发期落盘的文件 —— 不联网、可复现、能进版本库。
	# 拿不到就走本地随机，不报错、不停机。
	if cases.is_empty():
		var local: Dictionary = _load_local_cases()
		if bool(local.get("ok", false)):
			cases = local.get("cases", [])
			var meta: Dictionary = local.get("meta", {})
			print("[压测] 已从 %s 读取 %d 组用例（生成于 %s）"
				% [LOCAL_CASES_PATH, cases.size(), meta.get("generated_at", "?")])
			report["cases_source"] = "file"
	if not cases.is_empty():
		var r0 := await _run_cases(cases)
		report["cases_used"] = int(r0.get("used", 0))
		report["case_failures"] = int(r0.get("failed", 0))

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


## 随机瞬移到用例指定的极端位置，验证复位/兜底一定能把车弄回赛道。
## 返回 {"used": 实际执行数, "failed": 兜底失败数}。
func _run_cases(cases_in: Array) -> Dictionary:
	var used := 0
	var failed := 0
	for c in cases_in:
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
			printerr("[压测] 用例兜底失败：%s → %s（偏离路面中心线 %.2fm > 半路宽 %.2fm）"
				% [note, car.global_position, dist, road_half])
		else:
			print("[压测] 用例通过：%s（复位后偏离中心线 %.2fm）" % [note, dist])
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
