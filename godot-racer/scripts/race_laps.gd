extends RefCounted
## 每辆参赛车在权威一端使用同一套起终点、逆向、圈钟和目标圈数规则。

enum Crossing { NONE, START, LAP, FINISH }

var laps := 0
var started := false
var running := false
var lap_start_ms := 0
var last := 0.0
var best := 0.0
var times: Array[float] = []
var track: Node3D
var _center := Vector3.ZERO
var _forward := Vector3.ZERO
var _half_width := 0.0
var _previous_side := -1.0
var _armed := true
var _reverse_crossings := 0


func configure(road: Node3D, half_width: float) -> void:
	track = road
	_forward = Vector3.ZERO
	var center: Variant = road.get("start_line_center")
	var forward: Variant = road.get("start_line_forward")
	if center is Vector3 and forward is Vector3:
		_center = center
		var horizontal := Vector3(forward.x, 0.0, forward.z)
		if horizontal.length() >= 0.01: _forward = horizontal.normalized()
	_half_width = half_width


func begin(clock_ms: int) -> void:
	if running: return
	running = true
	lap_start_ms = clock_ms


func observe(position: Vector3) -> bool:
	if _forward == Vector3.ZERO: return false
	var offset := position - _center
	var side := offset.dot(_forward)
	var previous := _previous_side
	_previous_side = side
	if (offset - _forward * side).length() > _half_width: return false
	if started and previous >= 0.0 and side < 0.0:
		_reverse_crossings += 1
	var forward_crossing := _armed and previous < 0.0 and side >= 0.0
	_armed = side < 0.0
	return forward_crossing


func cross(clock_ms: int, target: int, replayed := false) -> Crossing:
	if _reverse_crossings > 0:
		_reverse_crossings -= 1
		return Crossing.NONE
	if replayed: return Crossing.NONE
	if not started or not running:
		started = true
		begin(clock_ms)
		return Crossing.START
	if target > 0 and laps >= target: return Crossing.NONE
	last = float(clock_ms - lap_start_ms) / 1000.0
	best = last if best <= 0.0 else minf(best, last)
	times.append(last)
	laps += 1
	lap_start_ms = clock_ms
	return Crossing.FINISH if target > 0 and laps == target else Crossing.LAP


func rebase(position: Vector3) -> void:
	_previous_side = (position - _center).dot(_forward)
	_armed = _previous_side < 0.0


func mark_behind() -> void:
	_previous_side = -1.0


static func progress(lap_count: int, crossed_start: bool, arc: float, length: float) -> float:
	return float(lap_count + int(crossed_start)) * length + clampf(arc, 0.0, length)
