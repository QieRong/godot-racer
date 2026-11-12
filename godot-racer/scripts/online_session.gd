extends Node
## WebRTC 双人会话底座。房间/信令服务完成身份校验后再调用此节点；尚未接菜单。
signal signaling_message(message: Dictionary)
signal transport_connected
signal reconnect_attempt(attempt: int, epoch: int)
signal resume_required(epoch: int)
signal authoritative_resume_received(epoch: int, snapshot: Dictionary)
signal resumed
signal return_to_room(reason: String)
signal race_suspended
signal drive_input_cleared
signal race_packet_received(kind: String, payload: Dictionary)

const Recovery := preload("res://scripts/online_recovery.gd")
const HEARTBEAT_MS := 500
const CONNECTION_TIMEOUT_MS := 3000
const INPUT_TIMEOUT_MS := 250
const MAX_PACKET_BYTES := 1000
const MAX_RESUME_BYTES := 8192
var recovery := Recovery.new()
var _peer: WebRTCPeerConnection
var _events: WebRTCDataChannel
var _state_channel: WebRTCDataChannel
var _link_id := ""
var _last_link_id := ""
var _serial := 0
var _pending_candidates: Array[Dictionary] = []
var _remote_description_set := false
var _connected_announced := false
var _opened_ms := 0
var _last_seen_ms := 0
var _last_input_ms := 0
var _heartbeat_ms := 0
var _input_cleared := true
var _send_seq: Dictionary = {}
var _receive_seq: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

func join_room(room: String, slot: int) -> bool:
	leave_room()
	return recovery.join_room(room, slot)

## id 必须由双方可信信令共同确定，每次重连使用全新的连接代号。
func start_link(id: String, offerer: bool, ice_servers: Array = [], attempt_epoch: int = -1) -> Error:
	if recovery.room_id.is_empty() or id.is_empty() or id == _last_link_id: return ERR_INVALID_PARAMETER
	if recovery.phase == Recovery.Phase.RECONNECTING:
		if attempt_epoch != recovery.epoch: return ERR_INVALID_PARAMETER
	elif recovery.phase != Recovery.Phase.ROOM or attempt_epoch != -1:
		return ERR_BUSY
	_drop_peer()
	_link_id = id
	_last_link_id = id
	_peer = WebRTCPeerConnection.new()
	var error := _peer.initialize({"iceServers": ice_servers})
	if error != OK:
		_drop_peer()
		return error
	_peer.session_description_created.connect(_description.bind(_serial))
	_peer.ice_candidate_created.connect(_candidate.bind(_serial))
	_events = _peer.create_data_channel("events", {"negotiated": true, "id": 0})
	_state_channel = _peer.create_data_channel("state", {"negotiated": true, "id": 1, "ordered": false, "maxRetransmits": 0})
	if _events == null or _state_channel == null:
		_drop_peer()
		return ERR_CANT_CREATE
	_opened_ms = Time.get_ticks_msec()
	if offerer:
		error = _peer.create_offer()
		if error != OK: _drop_peer()
	return error

func apply_signaling(message: Dictionary) -> Error:
	if _peer == null or message.get("link") != _link_id: return ERR_INVALID_DATA
	if message.get("kind") == "description":
		var type: Variant = message.get("type")
		var sdp: Variant = message.get("sdp")
		if type not in ["offer", "answer"] or not sdp is String or sdp.length() > 32768: return ERR_INVALID_DATA
		var error := _peer.set_remote_description(type, sdp)
		if error != OK: return error
		_remote_description_set = true
		for candidate in _pending_candidates:
			error = _peer.add_ice_candidate(candidate.media, candidate.index, candidate.candidate)
			if error != OK: return error
		_pending_candidates.clear()
		return OK
	if message.get("kind") == "candidate":
		if not message.get("media") is String or not message.get("candidate") is String: return ERR_INVALID_DATA
		if not _whole_number(message.get("index")) or message.candidate.length() > 2048: return ERR_INVALID_DATA
		if not _remote_description_set:
			if _pending_candidates.size() >= 64: return ERR_OUT_OF_MEMORY
			_pending_candidates.append(message.duplicate(true))
			return OK
		return _peer.add_ice_candidate(message.media, int(message.index), message.candidate)
	return ERR_INVALID_DATA

func is_connected_to_peer() -> bool:
	return _peer != null and _events != null and _state_channel != null \
		and _events.get_ready_state() == WebRTCDataChannel.STATE_OPEN \
		and _state_channel.get_ready_state() == WebRTCDataChannel.STATE_OPEN

func send_race_packet(kind: String, payload: Dictionary, reliable: bool = false) -> Error:
	if not recovery.accepts_race_packet(recovery.epoch, recovery.race_id): return ERR_UNAVAILABLE
	if kind not in ["input", "event", "snapshot"]: return ERR_INVALID_PARAMETER
	if kind == "input" and not _valid_input(payload): return ERR_INVALID_DATA
	return _send_packet(kind, payload, reliable)

func send_resume_snapshot(snapshot: Dictionary) -> Error:
	if recovery.local_slot != 0 or recovery.race_id.is_empty(): return ERR_UNAUTHORIZED
	if recovery.phase not in [Recovery.Phase.RESYNCING, Recovery.Phase.RACING]: return ERR_UNAVAILABLE
	return _send_packet("resume", snapshot, true)

## 在权威车辆/计圈/时钟快照已经应用、双方恢复屏障完成后，由比赛协调节点调用。
func confirm_resume(epoch: int, room: String, slot: int, race: String) -> bool:
	if not is_connected_to_peer() or not recovery.confirm_resume(epoch, room, slot, race, Time.get_ticks_msec()): return false
	resumed.emit()
	return true

func report_connection_lost(_reason: String) -> void:
	if _peer == null: return
	var now := Time.get_ticks_msec()
	if recovery.phase == Recovery.Phase.RECONNECTING or recovery.phase == Recovery.Phase.RESYNCING:
		recovery.fail_attempt(recovery.epoch, now)
	elif recovery.connection_lost(now):
		race_suspended.emit()
	drive_input_cleared.emit()
	_drop_peer()

func leave_room() -> void:
	_drop_peer()
	recovery.leave_room()
	_last_link_id = ""
	drive_input_cleared.emit()

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	var action := recovery.poll(now)
	if not action.is_empty():
		_drop_peer()
		if action.action == "retry": reconnect_attempt.emit(action.attempt, action.epoch)
		else: return_to_room.emit(action.reason)
	if _peer == null: return
	var frame_serial := _serial
	var error := _peer.poll()
	if frame_serial != _serial or _peer == null: return
	var state := _peer.get_connection_state()
	if error != OK or state in [WebRTCPeerConnection.STATE_FAILED, WebRTCPeerConnection.STATE_DISCONNECTED, WebRTCPeerConnection.STATE_CLOSED]:
		report_connection_lost("连接中断")
		return
	if not is_connected_to_peer():
		if now - _opened_ms >= CONNECTION_TIMEOUT_MS: report_connection_lost("连接超时")
		return
	if not _connected_announced:
		_connected_announced = true
		_last_seen_ms = now
		if recovery.phase == Recovery.Phase.RECONNECTING:
			if not recovery.transport_ready(recovery.epoch, now): return
			resume_required.emit(recovery.epoch)
			if frame_serial != _serial: return
		transport_connected.emit()
		if frame_serial != _serial: return
	for channel in [_events, _state_channel]:
		var count := mini(channel.get_available_packet_count(), 64)
		for _index in range(count):
			_receive_packet(channel.get_packet())
			if frame_serial != _serial: return
	if now - _heartbeat_ms >= HEARTBEAT_MS:
		_send_packet("heartbeat", {}, true)
		_heartbeat_ms = now
	if now - _last_seen_ms >= CONNECTION_TIMEOUT_MS:
		report_connection_lost("对端响应超时")
	elif recovery.phase == Recovery.Phase.RACING and not _input_cleared and now - _last_input_ms >= INPUT_TIMEOUT_MS:
		_input_cleared = true
		drive_input_cleared.emit()

func _send_packet(kind: String, payload: Dictionary, reliable: bool) -> Error:
	if not is_connected_to_peer(): return ERR_UNAVAILABLE
	var seq := int(_send_seq.get(kind, 0)) + 1
	var packet := {"room": recovery.room_id, "link": _link_id, "race": recovery.race_id, "kind": kind, "seq": seq, "payload": payload}
	var bytes := JSON.stringify(packet).to_utf8_buffer()
	if bytes.size() > (MAX_RESUME_BYTES if kind == "resume" else MAX_PACKET_BYTES): return ERR_INVALID_DATA
	var error: Error = (_events if reliable else _state_channel).put_packet(bytes)
	if error == OK: _send_seq[kind] = seq
	return error

func _receive_packet(bytes: PackedByteArray) -> void:
	if bytes.size() > MAX_RESUME_BYTES: return
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not parsed is Dictionary: return
	var packet: Dictionary = parsed
	if packet.get("room") != recovery.room_id or packet.get("link") != _link_id: return
	if packet.get("kind") not in ["heartbeat", "input", "event", "snapshot", "resume"]: return
	if not _whole_number(packet.get("seq")) or not packet.get("payload") is Dictionary: return
	var kind: String = packet.kind
	if kind != "resume" and bytes.size() > MAX_PACKET_BYTES: return
	var seq := int(packet.seq)
	if seq <= int(_receive_seq.get(kind, -1)): return
	if kind == "resume":
		if recovery.local_slot != 1 or recovery.phase != Recovery.Phase.RESYNCING or packet.get("race") != recovery.race_id: return
	elif kind != "heartbeat":
		if not recovery.accepts_race_packet(recovery.epoch, str(packet.get("race", ""))): return
		if kind == "input" and not _valid_input(packet.payload): return
	_receive_seq[kind] = seq
	_last_seen_ms = Time.get_ticks_msec()
	if kind == "heartbeat": return
	if kind == "resume":
		authoritative_resume_received.emit(recovery.epoch, packet.payload)
		return
	if kind == "input":
		_last_input_ms = _last_seen_ms
		_input_cleared = false
	race_packet_received.emit(kind, packet.payload)

func _description(type: String, sdp: String, serial: int) -> void:
	if serial != _serial or _peer == null: return
	if _peer.set_local_description(type, sdp) != OK:
		report_connection_lost("会话协商失败")
		return
	signaling_message.emit({"link": _link_id, "kind": "description", "type": type, "sdp": sdp})

func _candidate(media: String, index: int, candidate: String, serial: int) -> void:
	if serial == _serial and _peer != null:
		signaling_message.emit({"link": _link_id, "kind": "candidate", "media": media, "index": index, "candidate": candidate})

func _drop_peer() -> void:
	_serial += 1
	if _events != null: _events.close()
	if _state_channel != null: _state_channel.close()
	if _peer != null: _peer.close()
	_events = null
	_state_channel = null
	_peer = null
	_link_id = ""
	_pending_candidates.clear()
	_remote_description_set = false
	_connected_announced = false
	_input_cleared = true
	_send_seq.clear()
	_receive_seq.clear()

static func _whole_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value >= 0 and value <= 2147483647 and floor(float(value)) == float(value)

static func _valid_input(payload: Dictionary) -> bool:
	for key in payload:
		if key in ["handbrake", "drift"]:
			if not payload[key] is bool: return false
		elif key in ["throttle", "steering", "brake"]:
			var value: Variant = payload[key]
			if not (value is int or value is float) or not is_finite(float(value)): return false
			if value < (0.0 if key == "brake" else -1.0) or value > 1.0: return false
		else: return false
	return true

func _exit_tree() -> void:
	leave_room()
