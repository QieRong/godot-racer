extends Node
## 房间控制HTTP客户端。尚未注册autoload/接菜单或车辆；默认不连接服务。
## 调用者await操作结果，并在房间阶段定期poll_room；离开前await leave_room。
signal room_changed(snapshot: Dictionary)
signal room_events(events: Array, needs_resync: bool)

var local_slot := -1
var _base_url := ""
var _room: Dictionary = {}
var _member_token := ""
var _admission_key := ""
var _cursor := 0
var _generation := 0
var _busy := false
var _leaving := false
var _cleanup_busy := false
var _http: HTTPRequest
var _cleanup_http: HTTPRequest

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_http = _make_http()
	_cleanup_http = _make_http()

func _make_http() -> HTTPRequest:
	var request := HTTPRequest.new()
	request.timeout = 5.0
	request.max_redirects = 0 # 不把成员凭据转发给重定向目标。
	request.body_size_limit = 256 * 1024
	add_child(request)
	return request

func configure(base_url: String, allow_local_http: bool = false) -> Error:
	if _busy or _cleanup_busy or not _member_token.is_empty() or not _admission_key.is_empty(): return ERR_BUSY
	var url := base_url.trim_suffix("/")
	var pattern := RegEx.new()
	pattern.compile("^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$")
	var local := RegEx.new()
	local.compile("^http://127\\.0\\.0\\.1:[0-9]{1,5}$")
	if pattern.search(url) == null and not (allow_local_http and local.search(url) != null): return ERR_INVALID_PARAMETER
	_base_url = url
	return OK

func get_room_snapshot() -> Dictionary:
	return _room.duplicate(true)

func has_pending_cleanup() -> bool:
	return _leaving or (not _admission_key.is_empty() and not _busy)

func query_room(code: String) -> Dictionary:
	var normalized := _normalize_code(code)
	if normalized.is_empty(): return _failure("INVALID_CODE")
	if not _can_request(): return _failure("BUSY_OR_NOT_CONFIGURED")
	_busy = true
	var generation := _generation
	var result := await _request(_http, "/rooms/" + normalized, HTTPClient.METHOD_GET)
	_busy = false
	if generation != _generation: return _failure("CANCELLED")
	if result.get("ok", false) and not _valid_room(result.get("room")): return _failure("INVALID_RESPONSE")
	return result # 预览不取得身份、不覆盖当前共同房间。

func create_room(player_name: String, config: Dictionary, platform: String = OS.get_name()) -> Dictionary:
	return await _admit("/rooms", {"name": player_name, "platform": platform, "config": config})

func join_room(code: String, player_name: String, platform: String = OS.get_name()) -> Dictionary:
	var normalized := _normalize_code(code)
	if normalized.is_empty(): return _failure("INVALID_CODE")
	return await _admit("/rooms/" + normalized + "/join", {"name": player_name, "platform": platform})

func _admit(path: String, body: Dictionary) -> Dictionary:
	if not _can_request() or not _room.is_empty() or not _admission_key.is_empty(): return _failure("BUSY_OR_NOT_CONFIGURED")
	_admission_key = Crypto.new().generate_random_bytes(32).hex_encode()
	var key := _admission_key
	var generation := _generation
	_busy = true
	var result := await _request(_http, path, HTTPClient.METHOD_POST, body, key)
	_busy = false
	if generation != _generation: return _failure("CANCELLED")
	if not result.get("ok", false):
		# 明确拒绝没有占席；超时/坏响应则保留操作键，必须取消确认后才能再入房。
		if result.get("error") in ["INVALID_CONFIG", "INVALID_NAME", "INVALID_PLATFORM", "ROOM_FULL", "ROOM_LIMIT", "ROOM_NOT_FOUND", "ALREADY_STARTED", "UNAUTHORIZED", "ADMISSION_CANCELLED", "ADMISSION_LIMIT"]:
			_admission_key = ""
		return result
	var slot: Variant = result.get("slot") # JSON数字被Godot解析为float，Array.has则严格区分int。
	if result.get("token") != key or not (slot is int or slot is float) or (slot != 0 and slot != 1) or not _valid_room(result.get("room")):
		return _failure("INVALID_RESPONSE")
	_member_token = key
	_admission_key = ""
	local_slot = int(result.slot)
	_cursor = 0
	_apply_room(result.room)
	if generation != _generation: return _failure("CANCELLED")
	return {"ok": true, "room": get_room_snapshot(), "slot": local_slot} # 不把token交给UI/日志。

func update_room_config(config: Dictionary) -> Dictionary:
	return await request_command("config", {"config": config})

func set_ready(ready: bool, revision: int) -> Dictionary:
	return await request_command("ready", {"revision": revision, "ready": ready})

func request_start(revision: int) -> Dictionary:
	return await request_command("start", {"revision": revision})

func poll_room() -> Dictionary:
	return await request_command("poll", {"after": _cursor})

## 恢复/信令命令只转发，尚未驱动OnlineSession或确认实车恢复。
func request_command(op: String, args: Dictionary = {}) -> Dictionary:
	if op not in ["config", "ready", "start", "poll", "disconnect", "retry", "signal", "resync", "resume", "failed"]: return _failure("INVALID_COMMAND")
	if not _can_request() or _member_token.is_empty(): return _failure("BUSY_OR_NOT_JOINED")
	var body := args.duplicate(true)
	body.op = op
	var generation := _generation
	_busy = true
	var result := await _request(_http, "/rooms/" + str(_room.code) + "/command", HTTPClient.METHOD_POST, body, _member_token)
	_busy = false
	if generation != _generation: return _failure("CANCELLED")
	if result.get("ok", false):
		if not _valid_room(result.get("room")) or result.room.id != _room.id: return _failure("INVALID_RESPONSE")
		_apply_room(result.room)
		if generation != _generation: return _failure("CANCELLED")
		if op == "poll":
			if not result.get("events") is Array or not result.get("cursor") is float and not result.get("cursor") is int: return _failure("INVALID_RESPONSE")
			_cursor = int(result.cursor)
			room_events.emit(result.events.duplicate(true), result.get("needs_resync", false))
	return result

func leave_room() -> Dictionary:
	if _cleanup_busy: return _failure("BUSY")
	if _admission_key.is_empty() and _member_token.is_empty(): return {"ok": true}
	_generation += 1 # 使原建房/轮询的迟到结果失效，不等HTTP返回再取消。
	_leaving = true
	_cleanup_busy = true
	var result: Dictionary
	if not _admission_key.is_empty():
		result = await _request(_cleanup_http, "/admissions/cancel", HTTPClient.METHOD_POST, {}, _admission_key)
	else:
		result = await _request(_cleanup_http, "/rooms/" + str(_room.code) + "/command", HTTPClient.METHOD_POST, {"op": "leave"}, _member_token)
	_cleanup_busy = false
	if not result.get("ok", false) and result.get("error") not in ["ROOM_NOT_FOUND", "UNAUTHORIZED"]:
		return _failure("CLEANUP_PENDING") # 保留操作键/成员凭据，允许明确重试清理，不假报成功。
	_member_token = ""
	_admission_key = ""
	_room.clear()
	local_slot = -1
	_cursor = 0
	_leaving = false
	room_changed.emit({})
	return {"ok": true}

func _can_request() -> bool:
	return is_inside_tree() and not _base_url.is_empty() and not _busy and not _leaving

func _request(request: HTTPRequest, path: String, method: HTTPClient.Method, body: Dictionary = {}, token: String = "") -> Dictionary:
	var headers := PackedStringArray(["Accept: application/json"])
	if method == HTTPClient.METHOD_POST: headers.append("Content-Type: application/json")
	if not token.is_empty(): headers.append("Authorization: Bearer " + token)
	var error := request.request(_base_url + path, headers, method, JSON.stringify(body) if method == HTTPClient.METHOD_POST else "")
	if error != OK: return _failure("REQUEST_FAILED")
	var completed: Array = await request.request_completed
	if int(completed[0]) != HTTPRequest.RESULT_SUCCESS: return _failure("NETWORK_OR_TLS_ERROR")
	var status := int(completed[1])
	var bytes: PackedByteArray = completed[3]
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not parsed is Dictionary: return _failure("INVALID_RESPONSE")
	if status < 200 or status >= 300: return {"ok": false, "status": status, "error": str(parsed.get("error", "HTTP_ERROR"))}
	parsed.ok = true
	return parsed

func _apply_room(snapshot: Dictionary) -> void:
	if not _room.is_empty() and snapshot.id == _room.id and int(snapshot.revision) < int(_room.revision): return
	_room = snapshot.duplicate(true)
	room_changed.emit(get_room_snapshot())

func _valid_room(value: Variant) -> bool:
	return value is Dictionary and value.get("id") is String and value.get("code") is String \
		and _normalize_code(value.code) == value.code and value.get("config") is Dictionary \
		and value.get("members") is Array and value.get("phase") in ["ROOM", "RACING", "RECOVERING"] \
		and (value.get("revision") is float or value.get("revision") is int)

func _normalize_code(code: String) -> String:
	var normalized := code.strip_edges().replace("-", "").replace(" ", "").to_upper()
	if normalized.length() != 8: return ""
	for character in normalized:
		if not character in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789": return ""
	return normalized

func _failure(code: String) -> Dictionary:
	return {"ok": false, "error": code}
