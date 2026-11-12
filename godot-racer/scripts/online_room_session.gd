extends Node
## 已认证的双端连接上的房间控制。借用peer，不拥有登录、大厅或车辆恢复。
signal room_changed(snapshot: Dictionary)
signal load_requested(config: Dictionary, race_id: String)
signal race_started(snapshot: Dictionary)
signal race_packet_received(kind: String, payload: Dictionary)
signal action_failed(reason: String)
signal left_room
signal recovery_status(message: String)

const Recovery := preload("res://scripts/online_recovery.gd")
const RoomState := preload("res://scripts/online_room_state.gd")
const RACE_PACKETS := ["drive_input", "vehicle_state", "reset_request", "car_finished", "race_result", "result_return"]
const RESUME_PACKETS := ["resume_request", "resume_state", "resume_ack", "resume_commit"]
const HEARTBEAT_MS := 500
const LINK_TIMEOUT_MS := 3000

var local_slot := -1
var connected := false
var waiting_for_guest := false
var clock_ready := false
var best_rtt_ms := -1
var remote_started := false
var remote_revision := 0
var _peer: MultiplayerPeer
var _remote_id := 0
var _state: RefCounted
var _nonce := ""
var _rules_check: Callable
var _clock_samples := 0
var _clock_offset := 0.0
var _ping_ms := -1
var _pending_ready := false
var _last_load_id := ""
var reconnect_available := false
var reconnect_timeout_ms := 40000 # 与 EOS 首次中继建连使用相同预算。
var capture_resume: Callable
var apply_resume: Callable
var _backend: Node
var _recovery := Recovery.new()
var _opening_peer := false
var _link_key := ""
var _resume_key := ""
var _resume_room: Dictionary = {}
var _last_rx_ms := 0
var _next_heartbeat_ms := 0
var _leave_pending := false
var _leave_ack := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

func stage_host(state: RefCounted) -> void:
	_state = state
	local_slot = 0
	waiting_for_guest = true


func waiting_host_state() -> RefCounted:
	return _state


func update_waiting_code(code: String) -> void:
	if waiting_for_guest and _state.rotate_invite(code): room_changed.emit(snapshot())


func setup_recovery(backend: Node) -> void:
	_backend = backend


func attach(peer: MultiplayerPeer, remote_id: int, slot: int, state: RefCounted,
		nonce: String, rules_check: Callable) -> Error:
	if connected or slot not in [0, 1] or remote_id <= 0 or nonce.is_empty() or not rules_check.is_valid(): return ERR_INVALID_PARAMETER
	_peer = peer
	_remote_id = remote_id
	local_slot = slot
	_state = state
	_nonce = nonce
	_clock_samples = 0
	_clock_offset = 0.0
	_ping_ms = -1
	best_rtt_ms = -1
	remote_started = false
	remote_revision = 0
	_last_load_id = ""
	_rules_check = rules_check
	_watch_peer()
	connected = true
	waiting_for_guest = false
	clock_ready = slot == 0
	if slot == 0:
		_state.set_guest_present(true)
	_publish()
	set_process(true)
	if slot == 1: _send("hello")
	return OK

func snapshot() -> Dictionary:
	return _state.snapshot() if _state != null else {}

func local_go_deadline_ms() -> int:
	var view := snapshot()
	return int(float(view.get("host_go_ms", 0)) - _clock_offset)

func can_ready() -> bool:
	var view := snapshot()
	return connected and clock_ready and not _pending_ready and not view.is_empty() \
		and view.phase == "ROOM" and view.present[local_slot] and _rules_check.call(view.config)

func can_start() -> bool:
	var view := snapshot()
	return connected and local_slot == 0 and not view.is_empty() and view.phase == "ROOM" \
		and view.present == [true,true] and view.ready == [true,true]

func can_edit() -> bool:
	var view := snapshot()
	return connected and local_slot == 0 and not view.is_empty() and view.phase == "ROOM"

func set_ready(ready: bool) -> bool:
	if not can_ready(): return false
	var view := snapshot()
	if local_slot == 0:
		if not _state.set_ready(0, ready, view.revision, view.digest): return false
		_publish()
		return true
	_pending_ready = true
	var sent := _send("ready", {"ready":ready,"revision":view.revision,"digest":view.digest})
	room_changed.emit(snapshot())
	return sent

func update_config(config: Dictionary) -> bool:
	if not can_edit() or not _rules_check.call(config) or not _state.update_config(0, config): return false
	_publish()
	return true

func request_start() -> bool:
	if not can_start(): return false
	var view := snapshot()
	var race_id := Crypto.new().generate_random_bytes(16).hex_encode()
	if not _state.request_start(0, view.revision, view.digest, race_id): return false
	remote_started = false
	_publish()
	_notify_load()
	return true

## 加载者必须传回当时的局号，不能拿新快照确认旧加载任务。
func mark_loaded(race_id: String) -> bool:
	var view := snapshot()
	if not connected or view.is_empty() or view.phase != "LOADING" or view.race_id != race_id: return false
	if local_slot == 0:
		if not _state.mark_loaded(0, view.revision, view.digest, race_id): return false
		_schedule_if_loaded()
		_publish()
		return true
	return _send("loaded", {"race_id":race_id,"revision":view.revision,"digest":view.digest})

func return_to_room() -> bool:
	if not connected or local_slot != 0 or not _state.return_to_room(0): return false
	_last_load_id = ""
	remote_started = false
	_publish()
	return true

## 比赛高频数据仍由本节点唯一发送/接收；车辆协调器不再轮询peer。
func send_race_packet(kind: String, fields: Dictionary, reliable := false) -> bool:
	if kind not in RACE_PACKETS: return false
	return _send(kind, fields, reliable, 1000)

func leave_room() -> void:
	if _leave_pending: return
	_leave_pending = true
	_leave_ack = false
	if connected and _send("leave"):
		var deadline := Time.get_ticks_msec() + 1000
		while connected and not _leave_ack and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
	detach()
	_leave_pending = false
	left_room.emit()

func detach() -> void:
	set_process(false)
	connected = false
	waiting_for_guest = false
	_drop_peer()
	_recovery.leave_room()
	reconnect_available = false
	_pending_ready = false
	room_changed.emit(snapshot())

func _exit_tree() -> void:
	_drop_peer()

func _watch_peer() -> void:
	_peer.peer_disconnected.connect(_on_peer_left)
	_last_rx_ms = Time.get_ticks_msec()
	_next_heartbeat_ms = _last_rx_ms

func _drop_peer() -> void:
	if _peer != null and _peer.peer_disconnected.is_connected(_on_peer_left):
		_peer.peer_disconnected.disconnect(_on_peer_left)
	_peer = null

func _on_peer_left(id: int) -> void:
	if id == _remote_id: _link_lost("CONNECTION_LOST")

func _link_lost(reason: String) -> void:
	if _leave_pending:
		connected = false
		_drop_peer()
		return
	if _recovering():
		_recovery.fail_attempt(_recovery.epoch, Time.get_ticks_msec())
		_drop_peer()
		return
	var view := snapshot()
	if not connected or _backend == null or view.get("phase") != "RACING":
		_fail(reason)
		return
	connected = false
	_drop_peer()
	_recovery.join_room(_nonce, local_slot)
	_recovery.begin_race(view.race_id)
	_recovery.connection_lost(Time.get_ticks_msec())
	recovery_status.emit("比赛连接中断，正在重连…")

func _recovering() -> bool:
	return _recovery.phase in [Recovery.Phase.RECONNECTING, Recovery.Phase.RESYNCING]

func reconnect_room() -> void:
	if not reconnect_available: return
	reconnect_available = false
	_recovery.join_room(_nonce, local_slot)
	_recovery.connection_lost(Time.get_ticks_msec())
	room_changed.emit(snapshot())

func _step_recovery(now: int) -> void:
	var action := _recovery.poll(now, reconnect_timeout_ms)
	if _recovering() and not _recovery.has_active_attempt() and _backend.peer != null:
		_drop_peer()
		_backend.cancel_reconnect()
		_opening_peer = false
	match action.get("action"):
		"retry":
			_drop_peer()
			_resume_key = ""
			_resume_room.clear()
			recovery_status.emit(tr("正在重连（%d / %d）") % [action.attempt, Recovery.MAX_ATTEMPTS])
			_opening_peer = _backend.start_reconnect() == OK
			if not _opening_peer: _recovery.fail_attempt(action.epoch, now)
		"room":
			_drop_peer()
			_backend.cancel_reconnect()
			_opening_peer = false
			reconnect_available = true
			_last_load_id = ""
			remote_started = false
			_state.reset_disconnected_race(local_slot)
			room_changed.emit(snapshot())
			recovery_status.emit("重连三次失败，已返回原房间。")
	if not _opening_peer or not _recovering() or _peer != null: return
	if _backend.poll_reconnect() != OK: return
	_opening_peer = false
	if not _recovery.transport_ready(_recovery.epoch, now): return
	_peer = _backend.peer
	_remote_id = _backend.remote_peer_id
	_watch_peer()
	if local_slot == 1:
		_resume_key = Crypto.new().generate_random_bytes(16).hex_encode()
		_send("resume_request", {"resume":_resume_key, "race_id":_recovery.race_id})

func _receive_resume(kind: String, message: Dictionary) -> void:
	if _recovery.phase != Recovery.Phase.RESYNCING: return
	var key: Variant = message.get("resume")
	if not key is String or key.length() != 32 or not key.is_valid_hex_number(false): return
	var view := snapshot()
	if local_slot == 0 and kind == "resume_request":
		var race: Variant = message.get("race_id")
		if not race is String or (not race.is_empty() and view.phase == "RACING" and race != view.race_id): return
		if race.is_empty() and view.phase == "RACING":
			_state.return_to_room(0)
			view = snapshot()
			room_changed.emit(view)
		_resume_key = key
		var fields := {"resume":key, "room":view}
		if view.phase == "RACING":
			if not capture_resume.is_valid(): return
			fields.race = capture_resume.call()
		_send("resume_state", fields)
	elif key == _resume_key and local_slot == 1 and kind == "resume_state":
		var incoming: Variant = message.get("room")
		var candidate := RoomState.new()
		candidate.apply_snapshot(view)
		if not candidate.apply_snapshot(incoming): return
		if incoming.phase == "RACING":
			if incoming.race_id != _recovery.race_id or incoming.digest != view.digest \
					or not apply_resume.is_valid() or not apply_resume.call(message.get("race")): return
		elif incoming.phase != "ROOM":
			return
		_resume_room = incoming
		_send("resume_ack", {"resume":key})
	elif key == _resume_key and local_slot == 0 and kind == "resume_ack":
		if _send("resume_commit", {"resume":key}): _finish_recovery(view)
	elif key == _resume_key and local_slot == 1 and kind == "resume_commit" and not _resume_room.is_empty():
		_finish_recovery(_resume_room)

func _finish_recovery(view: Dictionary) -> void:
	if not _recovery.confirm_resume(_recovery.epoch, _nonce, local_slot, _recovery.race_id, Time.get_ticks_msec()): return
	if local_slot == 1: _state.apply_snapshot(view)
	_link_key = _resume_key
	connected = true
	reconnect_available = false
	_last_rx_ms = Time.get_ticks_msec()
	if view.phase == "ROOM":
		_last_load_id = ""
		remote_started = false
		_pending_ready = false
	room_changed.emit(snapshot())
	recovery_status.emit("")

func _fail(reason: String) -> void:
	detach()
	action_failed.emit(reason)

func _send(kind: String, fields: Dictionary = {}, reliable := true, max_bytes := 8192) -> bool:
	if not connected and (kind not in RESUME_PACKETS or _peer == null): return false
	var packet := fields.duplicate(true)
	packet.kind = kind
	packet.nonce = _nonce
	if kind not in RESUME_PACKETS and not _link_key.is_empty(): packet.link = _link_key
	var bytes := JSON.stringify(packet).to_utf8_buffer()
	if bytes.size() > max_bytes: return false
	_peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	_peer.set_target_peer(_remote_id)
	if _peer.put_packet(bytes) != OK:
		_link_lost("SEND_FAILED")
		return false
	return true

func _publish() -> void:
	room_changed.emit(snapshot())
	if local_slot == 0 and connected: _send("snapshot", {"snapshot":snapshot()})

func _notify_load() -> void:
	var view := snapshot()
	if view.phase == "LOADING" and view.race_id != _last_load_id:
		_last_load_id = view.race_id
		load_requested.emit(view.config.duplicate(true), view.race_id)

func _schedule_if_loaded() -> void:
	if snapshot().loaded == [true,true]:
		var now := Time.get_ticks_msec()
		_state.schedule_start(0, now + 3500, now)

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if not connected and _backend != null: _step_recovery(now)
	if _peer == null: return
	_peer.poll()
	if _peer != null and _peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		_link_lost("CONNECTION_LOST")
	while _peer != null and _peer.get_available_packet_count() > 0:
		var source := _peer.get_packet_peer()
		var bytes := _peer.get_packet()
		if source != _remote_id or bytes.size() > 8192:
			_fail("INVALID_PACKET")
			return
		var message: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if not message is Dictionary:
			_fail("INVALID_PACKET")
			return
		if message.get("nonce") != _nonce: continue
		var kind: String = str(message.get("kind", ""))
		if not connected:
			_receive_resume(kind, message)
			continue
		if message.get("link", "") != _link_key: continue
		_last_rx_ms = now
		if message.get("kind") in RACE_PACKETS and bytes.size() > 1000: continue
		_receive(message)
	if not connected: return
	if _backend != null and snapshot().get("phase") == "RACING":
		if now - _last_rx_ms >= LINK_TIMEOUT_MS:
			_link_lost("CONNECTION_LOST")
			return
		if now >= _next_heartbeat_ms:
			_next_heartbeat_ms = now + HEARTBEAT_MS
			if not _send("heartbeat", {}, false): return
	if local_slot == 1 and not clock_ready and _ping_ms < 0:
		_ping_ms = Time.get_ticks_msec()
		_send("clock_ping", {"client_ms":_ping_ms})
	var view := snapshot()
	if not view.is_empty() and view.phase == "COUNTDOWN" and clock_ready:
		var host_now := int(Time.get_ticks_msec() + _clock_offset)
		if host_now >= int(view.host_go_ms) and _state.begin_race(host_now):
			_last_rx_ms = now
			# 两端各自按共同期限GO；房主的先到快照不能替代加入端的时钟判断。
			room_changed.emit(snapshot())
			if local_slot == 1: _send("started", {"race_id":view.race_id})
			race_started.emit(snapshot())

static func _time_value(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and value >= 0 and value <= 9007199254740991 and value == floor(float(value))

func _receive(message: Dictionary) -> void:
	var kind: String = str(message.get("kind", ""))
	if kind == "leave":
		_send("leave_ack")
		_fail("PEER_LEFT")
		return
	if kind == "leave_ack":
		_leave_ack = true
		return
	if kind in RACE_PACKETS:
		var payload: Dictionary = message.duplicate(true)
		payload.erase("kind")
		payload.erase("nonce")
		payload.erase("link")
		race_packet_received.emit(kind, payload)
		return
	if local_slot == 0:
		match kind:
			"hello": _publish()
			"clock_ping":
				if _time_value(message.get("client_ms")):
					_send("clock_pong", {"client_ms":message.client_ms,"host_ms":Time.get_ticks_msec()})
			"ready", "loaded":
				var valid: bool = _time_value(message.get("revision")) and message.get("digest") is String
				var accepted := false
				if valid and kind == "ready" and message.get("ready") is bool:
					accepted = _state.set_ready(1, message.ready, int(message.revision), message.digest)
				elif valid and kind == "loaded" and message.get("race_id") is String:
					accepted = _state.mark_loaded(1, int(message.revision), message.digest, message.race_id)
					if accepted: _schedule_if_loaded()
				if not accepted: _send("rejected")
				_publish()
			"snapshot_ack":
				var view := snapshot()
				if message.get("revision") == view.revision and message.get("digest") == view.digest: remote_revision = view.revision
			"started":
				var view := snapshot()
				if view.phase in ["COUNTDOWN", "RACING"] and message.get("race_id") == view.race_id: remote_started = true
		return
	match kind:
		"snapshot":
			var incoming: Variant = message.get("snapshot")
			if incoming is Dictionary and incoming.get("phase") == "RACING" and snapshot().get("phase") != "RACING": return
			if not _state.apply_snapshot(incoming): return
			_pending_ready = false
			_publish()
			_send("snapshot_ack", {"revision":incoming.revision,"digest":incoming.digest})
			_notify_load()
		"rejected":
			_pending_ready = false
			action_failed.emit("STALE_RULES")
		"clock_pong":
			if _ping_ms < 0 or message.get("client_ms") != _ping_ms or not _time_value(message.get("host_ms")): return
			var now := Time.get_ticks_msec()
			var rtt := now - _ping_ms
			if best_rtt_ms < 0 or rtt < best_rtt_ms:
				best_rtt_ms = rtt
				_clock_offset = float(message.host_ms) - (float(_ping_ms) + now) * 0.5
			_clock_samples += 1
			_ping_ms = -1
			clock_ready = _clock_samples >= 3
			room_changed.emit(snapshot())
