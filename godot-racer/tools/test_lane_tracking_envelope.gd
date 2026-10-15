extends SceneTree
## L4/L5：真实选道入口同时验证目标车道和实测跟踪偏差对应的车身路径。
const Field := preload("res://scripts/obstacle_field.gd")

class StraightTrack extends Node3D:
	func nearest_on_centerline(pos: Vector3, _hint: float) -> Dictionary:
		return {"arc": -pos.z, "pos": Vector3(0.0, 0.0, pos.z), "forward": Vector3.FORWARD}
	func road_half_width() -> float:
		return 4.0

class PlanningCar extends "res://scripts/ai_opponent.gd":
	func _ready() -> void:
		set_physics_process(false)

var failures := 0
var executed := 0

func expect(ok: bool, label: String) -> void:
	executed += 1
	print("%s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var track := StraightTrack.new()
	root.add_child(track)
	var field := Field.new()
	root.add_child(field)
	field.set("_total_len", 2000.0)
	field.obstacles.append({"arc": 30.0, "lateral": 0.01, "half_width": 0.95, "kind": "rock"})
	var ai := PlanningCar.new()
	root.add_child(ai)
	ai.track = track
	ai.obstacle_field = field
	ai.set("_arc", 0.0)
	ai.set("_lane_now", 2.4)
	ai.global_position = Vector3(-1.9, 0.0, 0.0)
	var lane: float = ai.call("_effective_lane")
	var offset := -0.5
	var ok := not field.lane_blocked(lane + offset, 0.0, 45.0, 0.875)
	expect(ok, "selected lane %.3f remains clear with measured -0.5m offset" % lane)
	expect(absf(lane) <= 2.925 and absf(lane + offset) <= 2.925, "entire tracking band remains within road bounds")
	var unchanged: Dictionary = field.pick_clear_lane(2.4, 0.0, 45.0, 0.875, 2.925)
	expect(bool(unchanged["found"]) and is_equal_approx(float(unchanged["lane"]), 2.4),
		"default zero-offset API preserves existing callers")
	var crossing: Dictionary = field.pick_clear_lane(2.4, 0.0, 45.0, 0.875, 2.925, -4.8)
	expect(not bool(crossing["found"]), "clear endpoints cannot hide a blocked tracking band")
	ai.global_position = Vector3(2.4, 0.0, 0.0)
	ai.call("_effective_lane")
	expect(float(ai.get("_queue_until_arc")) >= 0.0, "unreachable tracking band enters slowdown queue")
	ai.free()
	field.free()
	track.free()
	print("ENVELOPE_EXECUTED=%d ENVELOPE_FAILURES=%d" % [executed, failures])
	quit(1 if failures > 0 else 0)
