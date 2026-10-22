extends SceneTree
## 针对真实测试判据的反例：时钟重置/跳变应失败，慢帧只应触发耗时门。

var subject: GDScript = load("res://tests/countdown_scene_test.gd")
var passed := 0
var failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _fixture(step_us: int = 10000) -> Array[Dictionary]:
	var samples: Array[Dictionary] = [_sample(1000000, "go", 0, 0)]
	for i in range(31):
		samples.append(_sample(1100000 + i * step_us, "window", i, 10 + i))
	return samples


func _sample(wall_us: int, stage: String, index: int, frame: int) -> Dictionary:
	return {
		"stage": stage, "index": index, "wall_before_us": wall_us,
		"wall_us": wall_us + 50, "race_clock_ms": wall_us / 1000,
		"lap_s": (wall_us / 1000 - 1000) / 1000.0, "lap_origin_s": 1.0,
		"go_ms": 1000, "paused_ms": 0, "pause_started_ms": -1,
		"paused": false, "phase": "RACING", "laps_done": 0,
		"crossed": stage != "go", "process_frame": frame,
	}


func _continuous(samples: Array[Dictionary]) -> bool:
	return bool(subject.call("clock_continuity", samples))


func _budget(t1: float, t2: float, wall_s: float) -> bool:
	return bool(subject.call("clock_window_within_budget", t1, t2, wall_s))


func _run() -> void:
	if not subject.has_method("clock_continuity") or not subject.has_method("clock_window_within_budget"):
		_check(false, "缺少分离的圈钟连续性/窗口耗时判据")
		_finish()
		return
	_check(not _continuous([]), "空采样不能通过连续性检查")
	_check(_continuous(_fixture()), "正常30帧：原点与圈钟保持连续")
	_check(_budget(0.1, 0.4, 0.3), "正常0.3秒窗口通过耗时门")
	_check(_continuous(_fixture(60000)), "慢帧1.8秒仍可保持圈钟连续")
	_check(not _budget(0.1, 1.9, 1.8), "慢帧1.8秒必须触发耗时红门")
	_check(not _budget(0.1, 1.1, 1.0), "恰好1秒仍失败，保持严格小于")
	_check(not _budget(0.0, 1.0, 0.9), "保留原圈钟增量小于1秒限制")
	_check(not _budget(0.2, 0.2, 0.2), "圈钟停住不能通过原递增限制")
	_check(not _budget(0.1, 0.4, 1.1), "墙钟超1秒不能被偏慢圈钟掩盖")
	var samples := _fixture()
	samples[10]["lap_origin_s"] = 1.2
	_check(not _continuous(samples), "压线后原点重置必须失败")
	samples = _fixture()
	samples[10]["go_ms"] = 1100
	_check(not _continuous(samples), "比赛GO原点变化必须失败")
	samples = _fixture()
	samples[10]["lap_s"] = 0.0
	_check(not _continuous(samples), "圈钟回零必须失败")
	samples = _fixture()
	samples[10]["lap_s"] += 0.05
	_check(not _continuous(samples), "圈钟向前跳变必须失败")
	samples = _fixture()
	samples.remove_at(10)
	_check(not _continuous(samples), "漏采样不能通过30帧检查")
	samples = _fixture()
	samples[10]["paused"] = true
	_check(not _continuous(samples), "窗口中出现暂停必须独立报错")
	samples = _fixture()
	var before_cross := _sample(1050000, "cross_poll", 0, 5)
	before_cross["lap_origin_s"] = 1.05
	samples.insert(1, before_cross)
	_check(not _continuous(samples), "压线前原点被改、窗口前恢复也必须失败")
	samples = _fixture()
	samples[10]["wall_before_us"] += 999
	samples[10]["wall_us"] += 960
	samples[10]["race_clock_ms"] += 1
	_check(_continuous(samples), "跨毫秒采样按实测读数区间检查，不误报")
	samples = _fixture()
	samples.remove_at(0)
	_check(not _continuous(samples), "缺GO采样不能通过原点检查")
	samples = _fixture()
	samples[10]["process_frame"] += 1
	_check(not _continuous(samples), "帧编号不连续不能冒充30帧")
	samples = _fixture()
	samples[10]["phase"] = "EXIT_CONFIRM"
	_check(not _continuous(samples), "窗口相位改变必须失败")
	samples = _fixture()
	samples[10]["race_clock_ms"] += 2
	_check(not _continuous(samples), "比赛时钟与墙钟区间不符必须失败")
	_finish()


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
	print("%s %s" % ["PASS" if ok else "FAIL", label])


func _finish() -> void:
	print("CLOCK_CONTRACT_SUMMARY pass=%d fail=%d" % [passed, failed])
	print("CLOCK_CONTRACT_PASS" if failed == 0 else "CLOCK_CONTRACT_FAIL")
	quit(0 if failed == 0 else 1)
