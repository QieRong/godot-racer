extends Node
## Windows EOSG 2.3.1。Lobby 准入成功后才把 P2P 连接交给 RoomSession。

signal invite_changed(code: String)
signal connection_status(message: String)

const RoomState := preload("res://scripts/online_room_state.gd")
const CODE := "RACER_ROOM_CODE"
const LINK := "RACER_LINK_NONCE"
const SUBMITTED := "RACER_JOIN_CODE"
const ADMITTED := "RACER_ADMITTED_USER"
const CONNECT_MS := 40000
const CONFIG_KEYS := ["PRODUCT_NAME", "PRODUCT_VERSION", "PRODUCT_ID", "SANDBOX_ID",
	"DEPLOYMENT_ID", "CLIENT_ID", "CLIENT_SECRET"]

var peer: MultiplayerPeer
var remote_peer_id := 0
var nonce := ""
var _user := ""
var _lobby := ""
var _remote_user := ""
var _host := false
var _initialized := false
var _platform := false
var _opening := false
var _closing := false
var _cancelled := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	EOSGRuntime.process_mode = Node.PROCESS_MODE_ALWAYS


func open_room(host: bool, code: String) -> String:
	if _opening or _closing or not _lobby.is_empty():
		return "上一间 EOS 房间尚未关闭。"
	_opening = true
	_cancelled = false
	_host = host
	var reason := await _open(code)
	if _cancelled or not reason.is_empty():
		if not await _clear_room():
			reason = "EOS 房间关闭失败，请稍后重试。"
	_opening = false
	return reason


func _open(code: String) -> String:
	connection_status.emit("正在登录 EOS…")
	var reason := await _login()
	if _cancelled or not reason.is_empty(): return reason
	if _host:
		return await _create()
	return await _join(code)


func _login() -> String:
	if not _user.is_empty(): return ""
	if not _platform:
		var path := OS.get_environment("RACER_EOS_CONFIG")
		if path.is_empty() or not FileAccess.file_exists(path):
			return "请通过本机 EOS 启动器启动联机。"
		var config := {}
		for line in FileAccess.get_file_as_string(path).split("\n"):
			var entry := line.strip_edges()
			if entry.begins_with("#"): continue
			var pair := entry.split("=", true, 1)
			if pair.size() == 2: config[pair[0]] = pair[1].trim_prefix('"').trim_suffix('"')
		for key in CONFIG_KEYS:
			if str(config.get(key, "")).is_empty(): return "本机 EOS 配置不完整。"
		if not _initialized:
			var init := EOS.Platform.InitializeOptions.new()
			init.product_name = config.PRODUCT_NAME
			init.product_version = config.PRODUCT_VERSION
			var result := EOS.Platform.PlatformInterface.initialize(init)
			if not EOS.is_success(result): return _error("EOS 初始化失败", result)
			_initialized = true
			EOS.Logging.set_log_level(EOS.Logging.LogCategory.AllCategories, EOS.Logging.LogLevel.Off)
		var options := EOS.Platform.CreateOptions.new()
		options.product_id = config.PRODUCT_ID
		options.sandbox_id = config.SANDBOX_ID
		options.deployment_id = config.DEPLOYMENT_ID
		options.client_id = config.CLIENT_ID
		options.client_secret = config.CLIENT_SECRET
		options.flags = EOS.Platform.PlatformFlags.DisableOverlay | EOS.Platform.PlatformFlags.DisableSocialOverlay
		options.tick_budget_in_milliseconds = 2
		options.task_network_timeout_seconds = 8.0
		DirAccess.make_dir_recursive_absolute(options.cache_directory)
		_platform = EOS.Platform.PlatformInterface.create(options)
		config.clear()
		if not _platform: return "EOS 平台启动失败。"
		EOSGRuntime.set_process(true)
	var device := EOS.Connect.CreateDeviceIdOptions.new()
	device.device_model = "RacerWindows"
	EOS.Connect.ConnectInterface.create_device_id(device)
	var response: Dictionary = await IEOS.connect_interface_create_device_id_callback
	if response.result_code not in [EOS.Result.Success, EOS.Result.DuplicateNotAllowed]:
		return _error("EOS 设备登录失败", response.result_code)
	if _cancelled: return ""
	var login := EOS.Connect.LoginOptions.new()
	login.credentials = EOS.Connect.Credentials.new()
	login.credentials.type = EOS.ExternalCredentialType.DeviceidAccessToken
	login.user_login_info = EOS.Connect.UserLoginInfo.new()
	login.user_login_info.display_name = "Racer"
	EOS.Connect.ConnectInterface.login(login)
	response = await IEOS.connect_interface_login_callback
	if response.result_code == EOS.Result.InvalidUser and not _cancelled:
		var create := EOS.Connect.CreateUserOptions.new()
		create.continuance_token = response.continuance_token
		EOS.Connect.ConnectInterface.create_user(create)
		response = await IEOS.connect_interface_create_user_callback
	if _cancelled and not EOS.is_success(response): return ""
	if not EOS.is_success(response): return _error("EOS 登录失败", response.result_code)
	_user = response.get("local_user_id", "")
	EOSGRuntime.local_product_user_id = _user
	return "EOS 登录未返回玩家身份。" if _user.is_empty() else ""


func _create() -> String:
	connection_status.emit("正在创建 EOS 房间…")
	var options := EOS.Lobby.CreateLobbyOptions.new()
	options.local_user_id = _user
	options.bucket_id = "GodotRacerPC-v1"
	options.max_lobby_members = 2
	options.presence_enabled = false
	options.allow_invites = false
	options.disable_host_migration = true
	EOS.Lobby.LobbyInterface.create_lobby(options)
	var created: Dictionary = await IEOS.lobby_interface_create_lobby_callback
	if not EOS.is_success(created): return _error("建房失败", created.result_code)
	_lobby = created.lobby_id
	if _cancelled: return ""
	nonce = Crypto.new().generate_random_bytes(16).hex_encode()
	var invite := RoomState.HostInvite.new()
	var reason := await _publish_invite(invite)
	if not reason.is_empty(): return reason
	var pending_guest := ""
	var pending_since := 0
	while not _cancelled:
		if invite.needs_code(Time.get_ticks_msec()):
			reason = await _publish_invite(invite)
			if not reason.is_empty() or _cancelled: return reason
		var details := _joined_details()
		if details == null: return "EOS 房间已关闭。"
		if details.get_member_count() == 2:
			var member := details.get_member_by_index(0)
			if member == _user: member = details.get_member_by_index(1)
			if pending_guest != member:
				pending_guest = member
				pending_since = Time.get_ticks_msec()
			var submitted := _member_attribute(details, member, SUBMITTED)
			if invite.claim(submitted, Time.get_ticks_msec()):
				if not await _publish_member(ADMITTED, member):
					return "发送 EOS 准入确认失败。"
				return await _connect_peer(member)
			if not submitted.is_empty() or Time.get_ticks_msec() - pending_since >= 10000:
				var kick := EOS.Lobby.KickMemberOptions.new()
				kick.local_user_id = _user
				kick.lobby_id = _lobby
				kick.target_user_id = member
				EOS.Lobby.LobbyInterface.kick_member(kick)
				var kicked: Dictionary = await IEOS.lobby_interface_kick_member_callback
				var current := _joined_details()
				if not EOS.is_success(kicked) and current != null and current.get_member_count() == 2:
					return _error("移除过期邀请码成员失败", kicked.result_code)
		else:
			pending_guest = ""
		await get_tree().create_timer(0.25).timeout
	return ""


func _publish_invite(invite: RoomState.HostInvite) -> String:
	var code := RoomState.make_code()
	while code == invite.code: code = RoomState.make_code()
	var modification := _modify_lobby()
	if modification == null: return "获取 EOS 房间更新失败。"
	var visibility := EOS.Lobby.LobbyAttributeVisibility.Public
	if not EOS.is_success(modification.add_attribute(CODE, code, visibility)):
		return "写入 EOS 房间码失败。"
	if invite.code.is_empty() and not EOS.is_success(modification.add_attribute(LINK, nonce, visibility)):
		return "写入 EOS 房间连接信息失败。"
	if not await _commit(modification): return "发布 EOS 房间码失败。"
	invite.publish(code, Time.get_ticks_msec())
	if not _cancelled: invite_changed.emit(code)
	return ""


func _join(code: String) -> String:
	connection_status.emit("正在按房间码搜索 EOS…")
	var search_options := EOS.Lobby.CreateLobbySearchOptions.new()
	search_options.max_results = 2
	var created := EOS.Lobby.LobbyInterface.create_lobby_search(search_options)
	if not EOS.is_success(created): return _error("搜索房间失败", created.result_code)
	var search: EOSGLobbySearch = created.lobby_search
	if not EOS.is_success(search.set_parameter(CODE, code, EOS.ComparisonOp.Equal)):
		return "设置房间码搜索失败。"
	var details: EOSGLobbyDetails
	# 刚发布或轮换的公开属性需要时间进入搜索索引。
	for attempt in range(5):
		if _cancelled: return ""
		search.find(_user)
		var found: Dictionary = await IEOS.lobby_search_find_callback
		if not EOS.is_success(found) and found.result_code != EOS.Result.NotFound:
			return _error("搜索房间失败", found.result_code)
		var count := search.get_search_result_count() if EOS.is_success(found) else 0
		if count > 1: return "房间码匹配到多个房间，请向房主索取新码。"
		if count == 1:
			var copied := search.copy_search_result_by_index(0)
			if not EOS.is_success(copied): return _error("读取房间失败", copied.result_code)
			details = copied.lobby_details
			break
		if attempt < 4: await get_tree().create_timer(1.0).timeout
	if _cancelled: return ""
	if details == null: return "房间码无效或已过期。"
	var info := details.copy_info()
	var code_attr := details.copy_attribute_by_key(CODE)
	var link_attr := details.copy_attribute_by_key(LINK)
	if not EOS.is_success(info) or not EOS.is_success(code_attr) or not EOS.is_success(link_attr):
		return "EOS 房间信息不完整。"
	var lobby_info: Dictionary = info.lobby_details
	var host_user: String = lobby_info.lobby_owner_user_id
	if host_user == _user: return "两个进程使用了同一 EOS 玩家身份，不能加入自己的房间。"
	nonce = str(link_attr.attribute.data.value)
	if lobby_info.bucket_id != "GodotRacerPC-v1" or code_attr.attribute.data.value != code \
			or nonce.length() != 32 or not nonce.is_valid_hex_number(false):
		return "EOS 房间信息与当前版本不匹配。"
	connection_status.emit("正在等待房主验码…")
	var join := EOS.Lobby.JoinLobbyOptions.new()
	join.local_user_id = _user
	join.lobby_details = details
	EOS.Lobby.LobbyInterface.join_lobby(join)
	var joined: Dictionary = await IEOS.lobby_interface_join_lobby_callback
	if not EOS.is_success(joined): return _error("加入房间失败", joined.result_code)
	_lobby = lobby_info.lobby_id
	if _cancelled: return ""
	if not await _publish_member(SUBMITTED, code): return "提交 EOS 房间码失败。"
	var deadline := Time.get_ticks_msec() + 12000
	while not _cancelled and Time.get_ticks_msec() < deadline:
		var current := _joined_details()
		if current == null: break
		if _member_attribute(current, host_user, ADMITTED) == _user:
			return await _connect_peer(host_user)
		await get_tree().create_timer(0.25).timeout
	return "" if _cancelled else "房主未确认准入，请核对最新房间码。"


func _connect_peer(remote_user: String) -> String:
	if _cancelled: return ""
	connection_status.emit("已通过 EOS 准入，正在建立比赛连接…")
	var relay := EOS.P2P.P2PInterface.set_relay_control(EOS.P2P.RelayControl.AllowRelays)
	if not EOS.is_success(relay): return _error("设置 EOS 中继失败", relay)
	_remote_user = remote_user
	var result := start_reconnect()
	if result != OK: return "启动 EOS 比赛连接失败（%d）。" % result
	var deadline := Time.get_ticks_msec() + CONNECT_MS
	while not _cancelled and Time.get_ticks_msec() < deadline:
		if poll_reconnect() == OK: return ""
		var details := _joined_details()
		if details == null or details.get_member_count() != 2: return "另一位玩家已离开房间。"
		await get_tree().process_frame
	return "" if _cancelled else "EOS 比赛连接超时，请重新建房。"


# 在原大厅、原 PUID 和原 socket 上重开 P2P，沿用首次准入的身份绑定。
func start_reconnect() -> int:
	cancel_reconnect()
	if _cancelled or _remote_user.is_empty() or _lobby.is_empty(): return ERR_UNCONFIGURED
	var native := EOSGMultiplayerPeer.new()
	peer = native
	native.set_auto_accept_connection_requests(false)
	native.peer_connected.connect(_on_peer_connected)
	var socket := "Racer" + nonce.substr(0, 12)
	return native.create_server(socket) if _host else native.create_client(socket, _remote_user)


func poll_reconnect() -> Error:
	var native := peer as EOSGMultiplayerPeer
	native.poll()
	for user in native.get_all_connection_requests():
		if user == _remote_user: native.accept_connection_request(user)
		else: native.deny_connection_request(user)
	return OK if remote_peer_id > 0 else ERR_BUSY


func cancel_reconnect() -> void:
	if peer != null:
		peer.close()
		peer = null
	remote_peer_id = 0


func _on_peer_connected(id: int) -> void:
	if peer.get_peer_user_id(id) == _remote_user:
		remote_peer_id = id
	else:
		peer.disconnect_peer.call_deferred(id)


func _modify_lobby() -> EOSGLobbyModification:
	var options := EOS.Lobby.UpdateLobbyModificationOptions.new()
	options.local_user_id = _user
	options.lobby_id = _lobby
	var handle := EOS.Lobby.LobbyInterface.update_lobby_modification(options)
	return handle.lobby_modification if EOS.is_success(handle) else null


func _commit(modification: EOSGLobbyModification) -> bool:
	var update := EOS.Lobby.UpdateLobbyOptions.new()
	update.lobby_modification = modification
	EOS.Lobby.LobbyInterface.update_lobby(update)
	var result: Dictionary = await IEOS.lobby_interface_update_lobby_callback
	return EOS.is_success(result)


func _publish_member(key: String, value: String) -> bool:
	var modification := _modify_lobby()
	if modification == null: return false
	if not EOS.is_success(modification.add_member_attribute(key, value, EOS.Lobby.LobbyAttributeVisibility.Public)):
		return false
	return await _commit(modification)


func _joined_details() -> EOSGLobbyDetails:
	var options := EOS.Lobby.CopyLobbyDetailsOptions.new()
	options.local_user_id = _user
	options.lobby_id = _lobby
	var copied := EOS.Lobby.LobbyInterface.copy_lobby_details(options)
	return copied.lobby_details if EOS.is_success(copied) else null


func _member_attribute(details: EOSGLobbyDetails, user: String, key: String) -> String:
	var value := details.copy_member_attribute_by_key(user, key)
	return str(value.attribute.data.value) if EOS.is_success(value) else ""


func close_room() -> bool:
	_cancelled = true
	while _opening or _closing: await get_tree().process_frame
	_closing = true
	var closed := await _clear_room()
	_closing = false
	return closed


func _clear_room() -> bool:
	cancel_reconnect()
	_remote_user = ""
	nonce = ""
	if _lobby.is_empty(): return true
	var result: Dictionary
	if _host:
		var destroy := EOS.Lobby.DestroyLobbyOptions.new()
		destroy.local_user_id = _user
		destroy.lobby_id = _lobby
		EOS.Lobby.LobbyInterface.destroy_lobby(destroy)
		result = await IEOS.lobby_interface_destroy_lobby_callback
	else:
		var leave := EOS.Lobby.LeaveLobbyOptions.new()
		leave.local_user_id = _user
		leave.lobby_id = _lobby
		EOS.Lobby.LobbyInterface.leave_lobby(leave)
		result = await IEOS.lobby_interface_leave_lobby_callback
	if not EOS.is_success(result) and result.result_code != EOS.Result.NotFound:
		if _host or _joined_details() != null: return false
	_lobby = ""
	return true


func _exit_tree() -> void:
	if peer != null:
		peer.close()
		peer = null
	if is_instance_valid(EOSGRuntime): EOSGRuntime.set_process(false)
	if _platform: EOS.Platform.PlatformInterface.release()
	if _initialized: EOS.Platform.PlatformInterface.shutdown()


func _error(message: String, result: int) -> String:
	return "%s（%s）。" % [message, EOS.result_str(result)]
