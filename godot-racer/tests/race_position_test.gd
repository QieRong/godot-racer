extends SceneTree
## 阶段二名次规则：先用同一公共排序入口固定已完赛优先。

const POSITION_SCRIPT := "res://scripts/race_position.gd"
var passed := 0
var failed := 0

class TrackStub extends Node3D:
	func road_length() -> float:
		return 1000.0

	func nearest_on_centerline(point: Vector3, _hint: float) -> Dictionary:
		return {"arc": point.x}


class PlayerStub extends VehicleBody3D:
	var laps_done := 0
	var lap_running := false

	func current_lap_time() -> float:
		return 1.0 if lap_running else 0.0


class AiStub extends VehicleBody3D:
	var meters := 0.0

	func progress() -> float:
		return meters


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var script := load(POSITION_SCRIPT)
	if script == null:
		_check(false, "名次模块可加载")
		_finish()
		return
	var position: Node = script.new()
	var rows: Array = position.call("rank_entries", [
		{"id": "player", "finished": false, "progress": 1200.0},
		{"id": "ai1", "finished": true, "finish_frame": 100, "progress": 200.0},
	])
	_check(rows.size() == 2 and rows[0].get("id") == "ai1" and int(rows[0].get("rank", 0)) == 1
		and rows[1].get("id") == "player" and int(rows[1].get("rank", 0)) == 2,
		"已完赛者排在高进度未完赛者之前")
	var player := VehicleBody3D.new()
	var ai := VehicleBody3D.new()
	ai.collision_layer = 2
	ai.collision_mask = 3
	if position.has_method("setup") and position.has_method("record_finish"):
		position.call("setup", player, null, [ai])
		position.call("record_finish", ai, 2)
	_check(ai.collision_layer == 0 and ai.collision_mask == 1 and not ai.freeze,
		"AI 完赛后仍可驾驶并与地面碰撞，但不再与玩家碰撞")
	var tie_rows: Array = position.call("rank_entries", [
		{"id": "player", "finished": true, "finish_frame": 120, "progress": 2000.0},
		{"id": "ai1", "finished": true, "finish_frame": 120, "progress": 2010.0},
	])
	var outcome := ""
	if position.has_method("player_outcome"):
		outcome = String(position.call("player_outcome", tie_rows))
	_check(tie_rows.size() == 2 and int(tie_rows[0].get("rank", 0)) == 1
		and int(tie_rows[1].get("rank", 0)) == 1 and outcome == "tie",
		"同帧完赛并列第 1，玩家不判负")
	var track := TrackStub.new()
	var p2 := PlayerStub.new()
	var a2 := AiStub.new()
	root.add_child(track)
	root.add_child(p2)
	root.add_child(a2)
	p2.position.x = 995.0
	a2.meters = 995.0
	var live: Node = script.new()
	live.call("setup", p2, track, [a2])
	var first: Array = live.call("standings") if live.has_method("standings") else []
	_check(first.size() == 2 and float(first[0].get("progress", -1.0)) == 995.0
		and int(first[0].get("rank", 0)) == 1 and int(first[1].get("rank", 0)) == 1,
		"首次压线前双方进度非负且并列")
	p2.lap_running = true
	p2.position.x = 700.0
	a2.meters = 1650.0
	var before_reset: Array = live.call("standings")
	p2.position.x = 500.0
	var after_reset: Array = live.call("standings")
	var after_reset_again: Array = live.call("standings")
	_check(int(before_reset[0].get("rank", 0)) == 1 and before_reset[0].get("id") == "player"
		and after_reset[0].get("id") == "ai1" and after_reset_again[0].get("id") == "ai1"
		and float(after_reset[1].get("progress", -1.0)) >= 995.0,
		"复位后进度可下降、名次下降且稳定，不低于出生进度")
	p2.position.x = 999.0
	var before_cross := float(live.call("player_progress"))
	var rank_before: Array = live.call("standings")
	p2.laps_done = 1
	p2.position.x = 1.0
	var after_cross := float(live.call("player_progress"))
	var rank_after: Array = live.call("standings")
	_check(after_cross >= before_cross
		and is_equal_approx((after_cross - 1.0) - (before_cross - 999.0), 1000.0)
		and rank_before[0].get("id") == "player" and rank_after[0].get("id") == "player",
		"跨圈弧长回绕时累计进度不下降，圈数项恰增加一个赛道长度")
	live.free()
	track.free()
	p2.free()
	a2.free()
	player.free()
	ai.free()
	position.free()
	_finish()


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("  ✔ " + label)
	else:
		failed += 1
		printerr("  ✘ " + label)


func _finish() -> void:
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	print("RACE_POSITION_PASS" if failed == 0 else "RACE_POSITION_FAIL")
	quit(0 if failed == 0 else 1)
