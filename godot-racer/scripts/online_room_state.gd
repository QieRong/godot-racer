extends RefCounted
## 双人房间与开赛屏障。传输层必须把已认证连接绑定到席位，不能信任包内自报slot。
## 不负责掉线期间车辆/时钟策略；尚未注册autoload或连接正式赛车场景。
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CONFIG_KEYS := ["level_id", "combination", "race_seed", "speed_kmh", "laps", "collision", "rules_hash"]
var _room: Dictionary = {}

## 房主在 Lobby 发布成功后开始计时；已入房成员的恢复走独立通路。
class HostInvite:
	const VALID_MS := 5 * 60_000
	var code := ""
	var expires_ms := 0
	var claimed := false

	func needs_code(now_ms: int) -> bool:
		return not claimed and (code.is_empty() or now_ms >= expires_ms)

	func publish(published_code: String, now_ms: int) -> bool:
		if not needs_code(now_ms) or published_code.is_empty() or published_code == code:
			return false
		code = published_code
		expires_ms = now_ms + VALID_MS
		return true

	func claim(submitted_code: String, now_ms: int) -> bool:
		if claimed or code.is_empty() or now_ms >= expires_ms or submitted_code != code:
			return false
		claimed = true
		return true

static func normalize_code(code: String) -> String:
	var normalized := code.strip_edges().replace("-", "").replace(" ", "").to_upper()
	if normalized.length() != 8: return ""
	for character in normalized:
		if not character in CODE_CHARS: return ""
	return normalized

static func make_code() -> String:
	var result := ""
	for byte in Crypto.new().generate_random_bytes(8): result += CODE_CHARS[byte % CODE_CHARS.length()]
	return result

static func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and value == floor(float(value)) and value >= minimum and value <= maximum

static func _hash(value: Variant) -> bool:
	if not value is String or value.length() != 64: return false
	for character in value:
		if not character in "0123456789abcdef": return false
	return true

static func valid_config(config: Variant) -> bool:
	if not config is Dictionary or config.size() != CONFIG_KEYS.size(): return false
	for key in CONFIG_KEYS:
		if not config.has(key): return false
	return _integer(config.level_id, 0, 4) and _integer(config.combination, 0, 8) \
		and _integer(config.race_seed, 0, 2147483647) and _integer(config.laps, 2, 2) \
		and (config.speed_kmh is int or config.speed_kmh is float) and is_finite(float(config.speed_kmh)) \
		and config.speed_kmh >= 80 and config.speed_kmh <= 240 \
		and config.collision is bool and config.collision and _hash(config.rules_hash)

static func digest_config(config: Dictionary) -> String:
	return JSON.stringify([int(config.level_id), int(config.combination), int(config.race_seed),
		float(config.speed_kmh), int(config.laps), bool(config.collision), str(config.rules_hash)]).sha256_text()

func create_room(code: String, config: Dictionary) -> bool:
	if not _room.is_empty() or code.is_empty() or normalize_code(code) != code or not valid_config(config): return false
	_room = {"code":code,"config":config.duplicate(true),"revision":1,"version":1,
		"digest":digest_config(config),"present":[true,false],"ready":[false,false],
		"loaded":[false,false],"phase":"ROOM","race_id":"","host_go_ms":0}
	return true

func snapshot() -> Dictionary:
	return _room.duplicate(true)

func config_digest() -> String:
	return str(_room.get("digest", ""))

func rotate_invite(code: String) -> bool:
	if _room.is_empty() or _room.phase != "ROOM" or _room.present[1] or normalize_code(code) != code or code.is_empty():
		return false
	_room.code = code
	_room.version += 1
	return true


func set_guest_present(present: bool) -> bool:
	if _room.is_empty() or _room.phase != "ROOM": return false
	if _room.present[1] == present: return true
	_room.present[1] = present
	_room.ready = [false, false]
	_room.version += 1
	return true

func update_config(caller_slot: int, config: Dictionary) -> bool:
	if caller_slot != 0 or _room.is_empty() or _room.phase != "ROOM" or not valid_config(config): return false
	_room.config = config.duplicate(true)
	_room.digest = digest_config(config)
	_room.revision += 1
	_room.version += 1
	_room.ready = [false, false]
	return true

func _matches(revision: int, digest: String) -> bool:
	return not _room.is_empty() and revision == int(_room.revision) and digest == _room.digest

func set_ready(slot: int, ready: bool, revision: int, digest: String) -> bool:
	if not _matches(revision, digest) or slot not in [0,1] or _room.phase != "ROOM" or not _room.present[slot]: return false
	_room.ready[slot] = ready
	_room.version += 1
	return true

func request_start(caller_slot: int, revision: int, digest: String, race_id: String) -> bool:
	if caller_slot != 0 or not _matches(revision, digest) or _room.phase != "ROOM" \
		or _room.ready != [true,true] or _room.present != [true,true] or race_id.is_empty() or race_id.length() > 64: return false
	_room.phase = "LOADING"
	_room.race_id = race_id
	_room.loaded = [false,false]
	_room.version += 1
	return true

func mark_loaded(slot: int, revision: int, digest: String, race_id: String) -> bool:
	if not _matches(revision, digest) or slot not in [0,1] or _room.phase != "LOADING" or race_id != _room.race_id: return false
	_room.loaded[slot] = true
	_room.version += 1
	return true

## host_go_ms是房主单调时钟。加入者必须先完成时钟偏差测量，再转换成本机时钟。
func schedule_start(caller_slot: int, host_go_ms: int, host_now_ms: int) -> bool:
	if caller_slot != 0 or _room.is_empty() or _room.phase != "LOADING" \
		or _room.loaded != [true,true] or host_now_ms < 0 or host_go_ms - host_now_ms < 3000: return false
	_room.phase = "COUNTDOWN"
	_room.host_go_ms = host_go_ms
	_room.version += 1
	return true

func begin_race(host_now_ms: int) -> bool:
	if _room.is_empty() or _room.phase != "COUNTDOWN" or host_now_ms < int(_room.host_go_ms): return false
	_room.phase = "RACING"
	_room.version += 1
	return true

func return_to_room(caller_slot: int) -> bool:
	if caller_slot != 0 or _room.is_empty(): return false
	_reset_race()
	_room.revision += 1
	_room.version += 1
	return true

func reset_disconnected_race(local_slot: int) -> void:
	if _room.is_empty() or _room.phase == "ROOM": return
	if local_slot == 0: return_to_room(0)
	else: _reset_race() # 加入端保留版本号，重连房间后接收房主版本。

func _reset_race() -> void:
	_room.phase = "ROOM"
	_room.race_id = ""
	_room.host_go_ms = 0
	_room.ready = [false,false]
	_room.loaded = [false,false]

## 只接收已绑定房主连接的快照，不把房间码当成管理凭据。
func apply_snapshot(value: Variant) -> bool:
	if not value is Dictionary or value.size() != 11: return false
	for key in ["code","config","revision","version","digest","present","ready","loaded","phase","race_id","host_go_ms"]:
		if not value.has(key): return false
	if not value.code is String or value.code.is_empty() or normalize_code(value.code) != value.code or not valid_config(value.config): return false
	if not _integer(value.revision,1,2147483647) or not _integer(value.version,1,2147483647) \
		or value.digest != digest_config(value.config) or value.phase not in ["ROOM","LOADING","COUNTDOWN","RACING"] \
		or not value.race_id is String or value.race_id.length() > 64 or not _integer(value.host_go_ms,0,9007199254740991): return false
	for key in ["present","ready","loaded"]:
		if not value[key] is Array or value[key].size() != 2: return false
		for flag in value[key]:
			if not flag is bool: return false
	if not value.present[0]: return false
	for slot in [0,1]:
		if (value.ready[slot] or value.loaded[slot]) and not value.present[slot]: return false
	if value.phase == "ROOM":
		if not value.race_id.is_empty() or value.host_go_ms != 0 or value.loaded != [false,false]: return false
	elif value.race_id.is_empty() or value.ready != [true,true] or value.present != [true,true]: return false
	if value.phase in ["COUNTDOWN","RACING"] and (value.loaded != [true,true] or value.host_go_ms <= 0): return false
	if not _room.is_empty() and (value.code != _room.code or value.version < _room.version or value.revision < _room.revision): return false
	_room = value.duplicate(true)
	return true
