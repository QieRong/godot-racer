extends SceneTree
## REVIEW-R6: 独立复现草稿，不改变 Quick/全量项数或既有验收阈值。
## 故障目标：墙钟继续走时，暂停/退出确认/结算冻结后的成绩仍增长。
## 直接调用真实状态机与车辆计圈入口；不模拟驾驶、不写车辆速度。

const CAR_SCENE := "res://scenes/race_car.tscn"
const WAIT_SEC := 0.6
const EPS_SEC := 0.05

var passed := 0
var failed := 0
var _state: Node
var _car: VehicleBody3D
var _rank: CanvasLayer
var _ai: VehicleBody3D


func _initialize() -> void:
	create_timer(20.0, true).timeout.connect(_timeout)
	call_deferred("_run")


func _run() -> void:
	_state = root.get_node("GameState")
	_state.call("prepare_race")
	_car = load(CAR_SCENE).instantiate()
	_car.freeze = true
	_car.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(_car)
	_car.get_node("EngineSound").stop()
	_ai = VehicleBody3D.new()
	_ai.freeze = true
	root.add_child(_ai)
	_rank = load("res://scripts/race_position.gd").new()
	_rank.set("_player", _car)
	await _go_origin()
	await _pause_cycle(1)
	await _pause_cycle(2)
	await _exit_from_racing()
	await _exit_from_paused()
	await _finish_and_reset()
	_rank.free()
	_ai.free()
	_car.free()
	_state.call("enter_menu")
	print("RACE_CLOCK_REVIEW_SUMMARY pass=%d fail=%d" % [passed, failed])
	print("RACE_CLOCK_REVIEW_PASS" if failed == 0 else "RACE_CLOCK_REVIEW_FAIL")
	quit(0 if failed == 0 else 1)


func _go_origin() -> void:
	_check(_state.call("enter_countdown"), "进入真实 COUNTDOWN")
	await create_timer(WAIT_SEC, true).timeout
	_check(_total() == 0.0 and _lap() == 0.0, "倒计时不计入总时间和首圈")
	Input.action_press("accelerate")
	_check(_state.call("start_race"), "倒计时结束的 GO 入口进入 RACING")
	_car.call("begin_lap_timing", _state.get("race_start_ms"))
	_check(Input.is_action_pressed("accelerate"), "GO 不吞倒计时期间按住的油门")
	Input.action_release("accelerate")
	await create_timer(0.15, true).timeout
	_check(_total() >= 0.1 and _lap() >= 0.1, "车辆未移动、未压线，GO 后总时间和首圈已增长")
	_check(absf(_total() - _lap()) <= EPS_SEC, "总时间与首圈使用同一 GO 原点")
	_car.call("_on_lap_crossed")
	_check(int(_car.get("laps_done")) == 0, "首次压线只标记，不完圈、不重新起表")


func _pause_cycle(index: int) -> void:
	_check(_state.call("pause_race"), "第 %d 次暂停成功" % index)
	var total_before := _total()
	var lap_before := _lap()
	await create_timer(WAIT_SEC, true).timeout
	_delta("第 %d 次暂停总时间" % index, _total() - total_before)
	_delta("第 %d 次暂停本圈" % index, _lap() - lap_before)
	_check(not bool(_state.call("pause_race")), "重复暂停被拒绝")
	_check(_state.call("resume_race"), "第 %d 次恢复成功" % index)
	_delta("第 %d 次恢复瞬间总时间" % index, _total() - total_before)
	_delta("第 %d 次恢复瞬间本圈" % index, _lap() - lap_before)
	var resumed := _total()
	await create_timer(0.15, true).timeout
	_check(_total() - resumed >= 0.1, "第 %d 次恢复后时钟继续走" % index)


func _exit_from_racing() -> void:
	_state.call("request_exit")
	_check(_state.call("phase_name") == "EXIT_CONFIRM" and paused, "比赛中退出确认冻结场景")
	var before := _total()
	var lap_before := _lap()
	await create_timer(WAIT_SEC, true).timeout
	_delta("比赛中退出确认总时间", _total() - before)
	_delta("比赛中退出确认本圈", _lap() - lap_before)
	_state.call("cancel_exit")
	_check(_state.call("phase_name") == "RACING" and not paused, "取消退出恢复比赛")
	_delta("取消退出瞬间总时间", _total() - before)
	await process_frame


func _exit_from_paused() -> void:
	_state.call("pause_race")
	var before := _total()
	_state.call("request_exit")
	await create_timer(WAIT_SEC, true).timeout
	_state.call("cancel_exit")
	_check(_state.call("phase_name") == "PAUSED" and paused, "暂停中取消退出仍保持 PAUSED")
	_delta("暂停与退出嵌套后总时间", _total() - before)
	await create_timer(WAIT_SEC, true).timeout
	_state.call("resume_race")
	_delta("嵌套暂停恢复后总时间", _total() - before)


func _finish_and_reset() -> void:
	# 墙钟等待累计约 3 秒；活跃比赛仅约 0.45s（另有退出弹层初始化开销）。
	# 此绝对上界能抓到共同污染；total == sum(laps) 单独成立不能证明无暂停污染。
	_check(_total() < 1.0, "成绩绝对值不包含累计约 3 秒暂停等待（实际 %.3f）" % _total())
	_check(_rank.call("record_finish", _ai, 1), "真实 AI 完赛记录入口成功")
	var records: Dictionary = _rank.get("_finished")
	var ai_total := float(records[_ai.get_instance_id()]["total"])
	_check(ai_total < 1.0, "AI 完赛时间不含暂停（实际 %.3f）" % ai_total)
	_car.call("_on_lap_crossed")
	var last := float(_car.get("lap_last"))
	_check(last < 1.0, "落入圈速记录的时间不含暂停（实际 %.3f）" % last)
	_check(_state.call("finish_race", 1, last, last, 1), "真实结算入口成功")
	var snapshot: Dictionary = Dictionary(_state.get("finish_snapshot")).duplicate(true)
	_check(float(snapshot["total"]) < 1.0, "结算总时间不含暂停（实际 %.3f）" % float(snapshot["total"]))
	_check(absf(float(snapshot["total"]) - last) <= EPS_SEC, "总时间与完整圈速和一致（辅助守卫）")
	var finished_total := _total()
	var finished_lap := _lap()
	await create_timer(WAIT_SEC, true).timeout
	_delta("结算后公开总时间", _total() - finished_total)
	_delta("结算后本圈时钟", _lap() - finished_lap)
	_check(snapshot == _state.get("finish_snapshot"), "结算快照保持不变")
	_state.call("enter_menu")
	_check(_total() == 0.0, "返回首页后总时间清零")
	_state.call("prepare_race")
	_check(_total() == 0.0, "新比赛 LOADING 总时间清零")
	_state.call("enter_countdown")
	await create_timer(0.1, true).timeout
	_state.call("start_race")
	_check(_total() <= EPS_SEC, "新 GO 清掉上一局暂停量与冻结状态")


func _total() -> float:
	return float(_state.call("race_total_time"))


func _lap() -> float:
	return float(_car.call("current_lap_time"))


func _delta(label: String, actual: float) -> void:
	print("CLOCK_DELTA label=%s actual=%.3f max=%.3f" % [label, actual, EPS_SEC])
	_check(absf(actual) <= EPS_SEC, label + "应冻结")


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("PASS " + label)
	else:
		failed += 1
		print("FAIL " + label)


func _timeout() -> void:
	print("RACE_CLOCK_REVIEW_TIMEOUT")
	quit(2)
