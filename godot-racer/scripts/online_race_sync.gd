extends Node
## 房主权威双车输入与状态快照。RoomSession仍是唯一peer轮询/分发者。
## 加入端使用原车辆物理预测，按ack历史校正；远端车延迟插值。
signal result_received(rows: Array)
const CarScene := preload("res://scenes/race_car.tscn")
const VehicleDrive := preload("res://scripts/vehicle_drive.gd")
const INPUT_TIMEOUT_MS := 250
const INPUT_DIVIDER := 2 # 120Hz物理 / 60Hz输入
const SNAPSHOT_DIVIDER := 6 # 120Hz物理 / 20Hz状态
const INTERPOLATION_TICKS := 12.0 # 100ms缓冲，不无限外推丢失状态。
const MAX_PREDICTIONS := 120 # 最多2秒输入历史，超出后以权威状态重新对齐。

var cars: Array[VehicleBody3D] = []
var opponents: Array[VehicleBody3D] = []
var remote_car: VehicleBody3D = null
var last_snapshot_bytes := 0
var _room: Node = null
var _race_id := ""
var _started := false
var _slot_cars: Dictionary = {}
var _input_seq := 0
var _reset_seq := 0
var _last_input_seq := 0
var _last_reset_seq := 0
var _last_input_ms := 0
var _input_expired := true
var _snapshot_seq := 0
var _last_snapshot_seq := 0
var _last_snapshot: Dictionary = {}
var _snapshot_warned := false
var _predictions: Dictionary = {}
var _remote_states: Array[Dictionary] = []
var _render_tick := 0.0
var _last_host_tick := -1
var _last_ack := 0
var _applied_input_seq := 0
var _ranking: Node
var _finished: Dictionary = {}
var _result: Array = []
var _held_guest := false
var _held_layer := false
var _held_mask := false
var _resume_finishes: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -10 # 本帧驾驶意图先于车辆读取。
	set_physics_process(false)


func setup(room: Node, scene_parent: Node, local_car: VehicleBody3D, obstacles: Node3D) -> void:
	local_car.network_slot = room.local_slot
	var second := CarScene.instantiate() as VehicleBody3D
	second.name = "RaceCarRemote"
	second.network_slot = 1 - room.local_slot
	second.start_locked = true
	second.position = local_car.position
	scene_parent.add_child(second)
	second.apply_level_setup(GameState.effective_speed(), GameState.effective_laps(), GameState.current_level().friction_multiplier)
	second.obstacle_field = obstacles
	_bind(room, local_car, second)


## 定向测试可绑定已有复制车；正式场景只使用setup()。
func setup_existing(room: Node, local_car: VehicleBody3D, other_car: VehicleBody3D) -> void:
	_bind(room, local_car, other_car)


func _bind(room: Node, local_car: VehicleBody3D, other_car: VehicleBody3D) -> void:
	_room = room
	remote_car = other_car
	cars.assign([local_car, other_car])
	opponents.assign([other_car])
	_slot_cars[local_car.network_slot] = local_car
	_slot_cars[other_car.network_slot] = other_car
	if not _room.race_packet_received.is_connected(_on_race_packet):
		_room.race_packet_received.connect(_on_race_packet)
	if _room.has_signal("recovery_status"):
		_room.recovery_status.connect(_on_recovery_status)
		_room.capture_resume = _capture_resume
		_room.apply_resume = _apply_resume
	if _room.local_slot == 0:
		remote_car.clear_external_drive_input()
		remote_car.evidence_input_read.connect(_on_host_input_read)
	else:
		for car in cars: car.set_network_replicated(true)
		remote_car.collision_layer = 0
		remote_car.set_collision_mask_value(2, false)
		local_car.prediction_corrected.connect(_rebase_predictions)


func setup_ranking(ranking: Node) -> void:
	_ranking = ranking
	if _room.local_slot == 0:
		for car in cars: car.race_finished.connect(_on_host_finish.bind(car))


func begin() -> void:
	_race_id = str(_room.snapshot().get("race_id", ""))
	_started = not _race_id.is_empty()
	_input_seq = 0
	_reset_seq = 0
	_last_input_seq = 0
	_last_reset_seq = 0
	_snapshot_seq = 0
	_last_snapshot_seq = 0
	_input_expired = true
	_last_input_ms = Time.get_ticks_msec()
	_predictions.clear()
	_remote_states.clear()
	_last_host_tick = -1
	_last_ack = 0
	_applied_input_seq = 0
	_last_snapshot.clear()
	_finished.clear()
	_result.clear()
	for car in cars:
		car.start_locked = false
		car.freeze = _room.local_slot == 1
		car.begin_lap_timing(GameState.race_start_ms)
	if _room.local_slot == 1: _slot_cars[1].set_network_predicted()
	set_physics_process(_started)


func latest_snapshot() -> Dictionary:
	return _last_snapshot.duplicate(true)


func last_input_sequence() -> int:
	return _last_input_seq


func _physics_process(delta: float) -> void:
	if not _started or _room == null or not _room.connected: return
	var view: Dictionary = _room.snapshot()
	if view.get("phase") != "RACING" or view.get("race_id") != _race_id: return
	var frame := Engine.get_physics_frames()
	if _room.local_slot == 0:
		if not _input_expired and Time.get_ticks_msec() - _last_input_ms >= INPUT_TIMEOUT_MS:
			_slot_cars[1].clear_external_drive_input()
			_input_expired = true
		if frame % SNAPSHOT_DIVIDER == 0: _send_snapshot()
	else:
		if _predictions.has(_input_seq): _predictions[_input_seq] = _slot_cars[1].capture_network_state()
		if not _finished.has(1) and frame % INPUT_DIVIDER == 0: _send_input()
		_render_remote(delta)
		if not _finished.has(1) and Input.is_action_just_pressed("reset"):
			_reset_seq += 1
			_room.send_race_packet("reset_request", {"race_id":_race_id,"seq":_reset_seq,"tick":frame}, true)


func _send_input() -> void:
	_input_seq += 1
	var intent := VehicleDrive.sample_input(_slot_cars[1].input_prefix)
	intent.throttle = snappedf(intent.throttle, 0.0001)
	intent.steering = snappedf(intent.steering, 0.0001)
	intent.merge({"race_id":_race_id,"seq":_input_seq,"tick":Engine.get_physics_frames()})
	_slot_cars[1].set_external_drive_input(intent)
	_predictions[_input_seq] = _slot_cars[1].capture_network_state()
	while _predictions.size() > MAX_PREDICTIONS: _predictions.erase(_predictions.keys()[0])
	_room.send_race_packet("drive_input", intent)


func _make_snapshot() -> Dictionary:
	_snapshot_seq += 1
	return {
		"race_id":_race_id,"seq":_snapshot_seq,"tick":Engine.get_physics_frames(),
		"ack":_applied_input_seq,
		"cars":[_slot_cars[0].capture_network_state(),_slot_cars[1].capture_network_state()]
	}


func _send_snapshot() -> void:
	var packet := _make_snapshot()
	if _ranking != null and _snapshot_seq % 5 == 1: packet.ranks = _ranks()
	last_snapshot_bytes = JSON.stringify(packet).to_utf8_buffer().size()
	if not _room.send_race_packet("vehicle_state", packet) and not _snapshot_warned:
		_snapshot_warned = true
		push_warning("[联机车辆] 状态快照发送失败或超过1000字节")


func _on_recovery_status(message: String) -> void:
	if not _started: return
	if _ranking != null: _ranking.show_online_recovery(message, _room.local_slot)
	if _room.local_slot == 0:
		if not message.is_empty() and not _held_guest and not _finished.has(1):
			_held_guest = true
			_held_layer = remote_car.get_collision_layer_value(2)
			_held_mask = remote_car.get_collision_mask_value(2)
			remote_car.set_collision_layer_value(2, false)
			remote_car.set_collision_mask_value(2, false)
			remote_car.set_network_replicated(true)
			remote_car.linear_velocity = Vector3.ZERO
			remote_car.angular_velocity = Vector3.ZERO
			remote_car.freeze = true
			_input_expired = true
		elif message.is_empty() and _held_guest:
			_held_guest = false
			remote_car.set_collision_layer_value(2, _held_layer)
			remote_car.set_collision_mask_value(2, _held_mask)
			remote_car.set_network_replicated(false)
			remote_car.freeze = false
	elif not message.is_empty():
		_predictions.clear()
		_remote_states.clear()
		_slot_cars[1].clear_network_correction()
	elif not _resume_finishes.is_empty():
		for slot in [0, 1]:
			if not _resume_finishes[slot].is_empty(): _record_finish(slot, _resume_finishes[slot])
		if _finished.size() == 2:
			_accept_result({"race_id":_race_id, "ranks":_ranking.online_ranks, "laps_ms":_resume_finishes})
		_resume_finishes = []


func _capture_resume() -> Dictionary:
	return {"vehicles":_make_snapshot(), "elapsed":maxi(0, GameState.race_clock_ms() - GameState.race_start_ms),
		"lap_clocks":[_slot_cars[0].capture_lap_clock(), _slot_cars[1].capture_lap_clock()],
		"finished":[_finished.get(0, []), _finished.get(1, [])], "ranks":_ranks()}


func _apply_resume(data: Variant) -> bool:
	if not data is Dictionary or not data.get("vehicles") is Dictionary: return false
	var packet: Dictionary = data.vehicles
	if not valid_snapshot(packet) or packet.race_id != _race_id or int(packet.seq) <= _last_snapshot_seq \
			or int(packet.tick) < _last_host_tick or int(packet.ack) < _last_ack or int(packet.ack) > _input_seq: return false
	var elapsed: Variant = data.get("elapsed")
	var clocks: Variant = data.get("lap_clocks")
	var finished: Variant = data.get("finished")
	if not _whole(elapsed, 0) or not _valid_ranks(data.get("ranks")) \
			or not clocks is Array or clocks.size() != 2 or not finished is Array or finished.size() != 2: return false
	for slot in [0, 1]:
		var clock: Variant = clocks[slot]
		var laps: int = int(packet.cars[slot].l)
		if not clock is Array or clock.size() != 2 or not _whole(clock[0], 0) or clock[0] > elapsed \
				or not clock[1] is Array or clock[1].size() != laps \
				or not finished[slot] is Array or (laps == 2 and not _valid_laps(finished[slot])) \
				or (laps < 2 and not finished[slot].is_empty()): return false
		for lap in clock[1]:
			if not _whole(lap, 1) or lap > elapsed: return false
	if GameState.phase == GameState.Phase.RACING:
		GameState.race_start_ms = GameState.race_clock_ms() - int(elapsed)
	for slot in [0, 1]:
		_slot_cars[slot].clear_network_correction()
		_slot_cars[slot].apply_network_state(packet.cars[slot])
		_slot_cars[slot].apply_lap_clock(clocks[slot])
	_last_snapshot_seq = int(packet.seq)
	_last_host_tick = int(packet.tick)
	_last_ack = int(packet.ack)
	_last_snapshot = packet.duplicate(true)
	_ranking.online_ranks = data.ranks
	_resume_finishes = finished
	return true


func _on_host_input_read(kind: String, _frame: int, _values: Dictionary) -> void:
	if kind == "drive": _applied_input_seq = _last_input_seq


func _on_race_packet(kind: String, payload: Dictionary) -> void:
	if not _started or payload.get("race_id") != _race_id: return
	if _room.local_slot == 0:
		match kind:
			"result_return":
				if payload.size() == 1: return_after_result()
			"drive_input":
				if _finished.has(1) or not valid_input(payload): return
				var seq := int(payload.seq)
				if seq <= _last_input_seq: return
				_last_input_seq = seq
				_last_input_ms = Time.get_ticks_msec()
				_input_expired = false
				_slot_cars[1].set_external_drive_input(payload)
			"reset_request":
				if _finished.has(1) or not valid_reset(payload): return
				var seq := int(payload.seq)
				if seq <= _last_reset_seq: return
				_last_reset_seq = seq
				_slot_cars[1].request_reset()
	else:
		if kind == "car_finished":
			var slot: Variant = payload.get("slot")
			if _ranking != null and payload.size() == 3 and _whole(slot, 0) and slot <= 1 and _valid_laps(payload.get("laps_ms")):
				_record_finish(int(slot), payload.laps_ms)
			return
		if kind == "race_result":
			if _ranking != null: _accept_result(payload)
			return
		if kind != "vehicle_state" or not valid_snapshot(payload): return
		var seq := int(payload.seq)
		if seq <= _last_snapshot_seq or int(payload.tick) <= _last_host_tick \
				or int(payload.ack) > _input_seq or int(payload.ack) < _last_ack: return
		_last_snapshot_seq = seq
		_last_host_tick = int(payload.tick)
		_last_snapshot = payload.duplicate(true)
		if _ranking != null and payload.has("ranks"):
			_ranking.online_ranks = payload.ranks
		var ack := int(payload.ack)
		_last_ack = ack
		if _finished.has(1):
			if int(payload.cars[1].l) == 2: _slot_cars[1].apply_network_state(payload.cars[1])
		elif _predictions.has(ack):
			_slot_cars[1].reconcile_network_state(payload.cars[1], _predictions[ack])
		elif ack > 0 and (_predictions.is_empty() or ack < int(_predictions.keys()[0])):
			_slot_cars[1].reconcile_network_state(payload.cars[1], _slot_cars[1].capture_network_state())
		else:
			_slot_cars[1].apply_network_progress(payload.cars[1])
		for key in _predictions.keys():
			if key < ack: _predictions.erase(key)
		_buffer_remote(payload)


func _on_host_finish(laps: int, car: VehicleBody3D) -> void:
	if not _started or laps != 2 or not _ranking.record_finish(car, laps): return
	var slot: int = car.network_slot
	var times: Array = car.lap_times.map(func(time: float): return roundi(time * 1000.0))
	_record_finish(slot, times)
	_room.send_race_packet("car_finished", {"race_id":_race_id,"slot":slot,"laps_ms":times}, true)
	if _finished.size() == 2: _publish_result()


func _record_finish(slot: int, times: Array) -> void:
	if _finished.has(slot): return
	_finished[slot] = times.duplicate()
	var car: VehicleBody3D = _slot_cars[slot]
	car.network_finish_time = (float(times[0]) + float(times[1])) / 1000.0
	if _room.local_slot == 1:
		car.apply_network_progress({"l":2, "c":true, "ll":float(times[1]) / 1000.0,
			"lb":minf(times[0], times[1]) / 1000.0})
	car.finish_input_locked = true
	car.set_collision_layer_value(2, false)
	car.set_collision_mask_value(2, false)
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.freeze = true
	if slot == _room.local_slot: _ranking.show_online_finish_waiting()


func _ranks() -> Array:
	var ranks := [0, 0]
	for row: Dictionary in _ranking.standings():
		ranks[0 if row.id == "player" else 1] = int(row.rank)
	return ranks


func _publish_result() -> void:
	var packet := {"race_id":_race_id,"ranks":_ranks(),"laps_ms":[_finished[0],_finished[1]]}
	# 先把同一份房主结果排入可靠通道，再显示本机结算。
	_room.send_race_packet("race_result", packet, true)
	_accept_result(packet)


func _accept_result(payload: Dictionary) -> void:
	if not _result.is_empty() or payload.size() != 3 or not _valid_ranks(payload.get("ranks")): return
	var lap_times: Variant = payload.get("laps_ms")
	if not lap_times is Array or lap_times.size() != 2: return
	for slot in [0, 1]:
		if not _valid_laps(lap_times[slot]): return
		if _finished.has(slot) and _finished[slot] != lap_times[slot]: return
	for slot in [0, 1]:
		_record_finish(slot, lap_times[slot])
		var times: Array = lap_times[slot]
		_result.append({"slot":slot, "rank":int(payload.ranks[slot]), "laps":2,
			"lap_times":[float(times[0]) / 1000.0,float(times[1]) / 1000.0],
			"total":(float(times[0]) + float(times[1])) / 1000.0,
			"last":float(times[1]) / 1000.0, "best":minf(times[0], times[1]) / 1000.0})
	result_received.emit(_result.duplicate(true))


func return_after_result() -> void:
	if _result.is_empty() or _room.snapshot().get("race_id") != _race_id: return
	if _room.local_slot == 0:
		_room.return_to_room()
	else:
		_room.send_race_packet("result_return", {"race_id":_race_id}, true)


static func _valid_laps(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _whole(value[0], 1) and _whole(value[1], 1) \
		and value[0] + value[1] <= 86400000


static func _valid_ranks(value: Variant) -> bool:
	if not value is Array or value.size() != 2 or not _whole(value[0], 1) or not _whole(value[1], 1): return false
	var first := int(value[0])
	var second := int(value[1])
	return first <= 2 and second <= 2 and (first == 1 or second == 1)


func _rebase_predictions(offset: Vector3, rotation: Quaternion, velocity: Vector3, angular: Vector3) -> void:
	# 已施加的校正同步移入历史，避免同一误差被后续ack重复施加。
	for state: Dictionary in _predictions.values():
		for field in ["p", "v", "w"]:
			var correction: Vector3 = offset if field == "p" else (velocity if field == "v" else angular)
			for axis in range(3): state[field][axis] += correction[axis]
		var q: Array = state.q
		var adjusted := (rotation * Quaternion(q[0], q[1], q[2], q[3])).normalized()
		state.q = [adjusted.x, adjusted.y, adjusted.z, adjusted.w]


func _buffer_remote(packet: Dictionary) -> void:
	var state: Dictionary = packet.cars[0]
	if not _remote_states.is_empty():
		var previous: Dictionary = _remote_states.back()
		var elapsed := (float(packet.tick) - float(previous.tick)) / 120.0
		var expected: Vector3 = _vec(previous.state.p) + _vec(previous.state.v) * elapsed
		if expected.distance_to(_vec(state.p)) > 6.0:
			_remote_states.clear() # 复位/大幅权威位移不能插值穿过赛道。
	if _remote_states.is_empty():
		_render_tick = float(packet.tick) - INTERPOLATION_TICKS
		remote_car.apply_network_state(state)
	_remote_states.append({"tick":int(packet.tick), "state":state.duplicate(true)})
	while _remote_states.size() > 32: _remote_states.pop_front()


func _render_remote(delta: float) -> void:
	if _remote_states.is_empty(): return
	_render_tick = minf(_render_tick + delta * 120.0, float(_remote_states.back().tick))
	# 新快照堆积时只追到缓冲边界，避免永久落后。
	_render_tick = maxf(_render_tick, float(_remote_states.back().tick) - INTERPOLATION_TICKS * 2.0)
	while _remote_states.size() > 2 and float(_remote_states[1].tick) <= _render_tick:
		_remote_states.pop_front()
	if _remote_states.size() == 1: return
	var a: Dictionary = _remote_states[0]
	var b: Dictionary = _remote_states[1]
	var weight := clampf((_render_tick - float(a.tick)) / float(b.tick - a.tick), 0.0, 1.0)
	var state: Dictionary = a.state.duplicate(true)
	for field in ["p", "v", "w"]:
		for axis in range(3): state[field][axis] = lerpf(float(a.state[field][axis]), float(b.state[field][axis]), weight)
	var qa: Array = a.state.q
	var qb: Array = b.state.q
	var q := Quaternion(qa[0],qa[1],qa[2],qa[3]).slerp(Quaternion(qb[0],qb[1],qb[2],qb[3]), weight).normalized()
	state.q = [q.x,q.y,q.z,q.w]
	state.s = lerpf(float(a.state.s), float(b.state.s), weight)
	remote_car.apply_network_state(state)
	# 显示进度使用最新权威值，不能被较早的插值帧倒写。
	remote_car.apply_network_progress(_remote_states.back().state)


static func _vec(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])


static func valid_input(packet: Dictionary) -> bool:
	if packet.size() != 7: return false
	for key in ["race_id","seq","tick","throttle","steering","handbrake","drift"]:
		if not packet.has(key): return false
	return packet.race_id is String and not packet.race_id.is_empty() and packet.race_id.length() <= 64 \
		and _whole(packet.seq, 1) and _whole(packet.tick, 0) \
		and _axis(packet.throttle) and _axis(packet.steering) \
		and packet.handbrake is bool and packet.drift is bool


static func valid_reset(packet: Dictionary) -> bool:
	if packet.size() != 3: return false
	return packet.get("race_id") is String and not packet.race_id.is_empty() and packet.race_id.length() <= 64 \
		and _whole(packet.get("seq"), 1) and _whole(packet.get("tick"), 0)


static func valid_snapshot(packet: Dictionary) -> bool:
	if packet.size() != 5 and (packet.size() != 6 or not _valid_ranks(packet.get("ranks"))): return false
	for key in ["race_id","seq","tick","ack","cars"]:
		if not packet.has(key): return false
	if not packet.race_id is String or packet.race_id.is_empty() or packet.race_id.length() > 64: return false
	if not _whole(packet.seq, 1) or not _whole(packet.tick, 0) or not _whole(packet.ack, 0): return false
	if not packet.cars is Array or packet.cars.size() != 2: return false
	return _valid_car_state(packet.cars[0]) and _valid_car_state(packet.cars[1])


static func _valid_car_state(state: Variant) -> bool:
	if not state is Dictionary or state.size() != 10: return false
	for key in ["p","q","v","w","s","d","l","c","ll","lb"]:
		if not state.has(key): return false
	for key in ["p","q","v","w"]:
		if not state[key] is Array or state[key].size() != (4 if key == "q" else 3): return false
		for value in state[key]:
			if not _finite(value, 1.1 if key == "q" else (1000000.0 if key == "p" else 1000.0)): return false
	var q: Array = state.q
	var length_squared := float(q[0])*float(q[0]) + float(q[1])*float(q[1]) + float(q[2])*float(q[2]) + float(q[3])*float(q[3])
	if absf(length_squared - 1.0) > 0.01: return false
	if not _finite(state.s, 1.5) or not state.d is bool or not state.c is bool: return false
	if not _whole(state.l, 0) or int(state.l) > 2: return false
	return _finite(state.ll, 86400.0) and state.ll >= 0.0 and _finite(state.lb, 86400.0) and state.lb >= 0.0


static func _whole(value: Variant, minimum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and value >= minimum and value <= 9007199254740991 and floor(float(value)) == float(value)


static func _axis(value: Variant) -> bool:
	return _finite(value, 1.0)


static func _finite(value: Variant, limit: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and absf(float(value)) <= limit


func _exit_tree() -> void:
	_started = false
	set_physics_process(false)
	if _room != null and _room.race_packet_received.is_connected(_on_race_packet):
		_room.race_packet_received.disconnect(_on_race_packet)
	if _room != null and _room.local_slot == 0 and is_instance_valid(remote_car):
		remote_car.clear_external_drive_input()
