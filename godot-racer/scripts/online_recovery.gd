extends RefCounted
## 房间会话的有限重连状态；恢复运输后还须应用房主快照，才允许继续本局。
enum Phase { IDLE, ROOM, RACING, RECONNECTING, RESYNCING }
const MAX_ATTEMPTS := 3
const ATTEMPT_TIMEOUT_MS := 3000
const RETRY_DELAY_MS := 500

var phase: Phase = Phase.IDLE
var room_id := ""
var local_slot := -1
var race_id := ""
var room_connected := false
var epoch := 0
var attempts_started := 0
var _in_flight := false
var _deadline_ms := 0
var _next_attempt_ms := 0
var _return_pending := false

func join_room(id: String, slot: int) -> bool:
	if id.is_empty() or slot < 0 or slot > 1: return false
	leave_room()
	room_id = id
	local_slot = slot
	room_connected = true
	phase = Phase.ROOM
	return true

func begin_race(id: String) -> bool:
	if phase != Phase.ROOM or not room_connected or id.is_empty(): return false
	race_id = id
	phase = Phase.RACING
	return true

func connection_lost(now_ms: int) -> bool:
	if not room_connected or (phase != Phase.ROOM and phase != Phase.RACING): return false
	room_connected = false
	phase = Phase.RECONNECTING
	epoch += 1
	attempts_started = 0
	_in_flight = false
	_return_pending = false
	_next_attempt_ms = now_ms
	return true

## 调用者按 action 启动一次真正的新连接；不要把一次 poll 计作一次重连。
func poll(now_ms: int, attempt_timeout_ms := ATTEMPT_TIMEOUT_MS) -> Dictionary:
	if _in_flight and now_ms >= _deadline_ms:
		fail_attempt(epoch, now_ms)
	if _return_pending:
		_return_pending = false
		return {"action": "room", "room_id": room_id, "reason": "重连三次失败，请在原房间重新准备"}
	if phase != Phase.RECONNECTING or _in_flight or now_ms < _next_attempt_ms: return {}
	attempts_started += 1
	epoch += 1
	_in_flight = true
	_deadline_ms = now_ms + attempt_timeout_ms
	return {"action": "retry", "attempt": attempts_started, "epoch": epoch}

func fail_attempt(attempt_epoch: int, now_ms: int) -> void:
	if not _in_flight or attempt_epoch != epoch: return
	_in_flight = false
	epoch += 1
	if attempts_started >= MAX_ATTEMPTS:
		phase = Phase.ROOM
		race_id = ""
		_return_pending = true
	else:
		phase = Phase.RECONNECTING
		_next_attempt_ms = now_ms + RETRY_DELAY_MS

func transport_ready(attempt_epoch: int, now_ms: int) -> bool:
	if phase != Phase.RECONNECTING or not _valid_attempt(attempt_epoch, now_ms): return false
	phase = Phase.RESYNCING
	return true

## 只能在调用者完成房主快照校验/应用后确认；同一房间、身份与本局均不可变。
func confirm_resume(attempt_epoch: int, id: String, slot: int, resumed_race: String, now_ms: int) -> bool:
	if phase != Phase.RESYNCING or not _valid_attempt(attempt_epoch, now_ms): return false
	if id != room_id or slot != local_slot or resumed_race != race_id: return false
	_in_flight = false
	room_connected = true
	phase = Phase.ROOM if race_id.is_empty() else Phase.RACING
	return true

func accepts_race_packet(packet_epoch: int, packet_race: String) -> bool:
	return phase == Phase.RACING and room_connected and packet_epoch == epoch and packet_race == race_id

func has_active_attempt() -> bool:
	return _in_flight

func leave_room() -> void:
	epoch += 1
	phase = Phase.IDLE
	room_id = ""
	local_slot = -1
	race_id = ""
	room_connected = false
	attempts_started = 0
	_in_flight = false
	_return_pending = false

func _valid_attempt(attempt_epoch: int, now_ms: int) -> bool:
	return _in_flight and attempt_epoch == epoch and now_ms < _deadline_ms
