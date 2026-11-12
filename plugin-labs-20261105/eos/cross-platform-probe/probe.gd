extends Node
## 隔离SDK检查：不打印凭据/玩家ID，可选临时大厅，不打开登录网页/Overlay。
const ROOM_CODE_ATTRIBUTE := "RACER_ROOM_CODE"
const JOIN_CODE_ATTRIBUTE := "RACER_JOIN_CODE"
const DIAGNOSTIC_WORDS := ["connection", "connect", "connecting", "connected", "disconnect", "disconnected", "close", "closed", "remote", "local", "peer", "request", "response", "received", "receive", "send", "sent", "packet", "packets", "relay", "relayed", "turn", "stun", "ice", "candidate", "candidates", "allocation", "allocate", "allocated", "permission", "channel", "auth", "authentication", "authenticated", "unauthorized", "credential", "credentials", "expired", "timeout", "timed", "out", "fail", "failed", "failure", "error", "warning", "success", "successful", "retry", "retrying", "socket", "sockets", "udp", "tcp", "dns", "resolve", "resolved", "resolving", "network", "unreachable", "unavailable", "invalid", "valid", "denied", "refused", "dropped", "completed", "complete", "pending", "start", "started", "starting", "finish", "finished", "session", "signaling", "signal", "negotiation", "negotiate", "negotiating", "route", "transport", "host", "client", "server", "established", "keepalive", "heartbeat", "no", "not", "cannot", "unable", "too", "many", "new", "old", "initial", "cached", "cache", "refresh", "refreshing", "resolution", "initialize", "initialized", "cancelled", "canceled", "wait", "waiting", "attempt", "attempting", "reconnect", "reconnecting", "http", "https", "tls", "ssl", "certificate", "verified", "verify", "handshake", "data", "buffer", "queue", "full", "limit", "port", "address", "ipv", "mapped", "binding", "bind", "interface", "create", "created", "creating", "destroy", "destroyed", "suspended", "resume", "resumed", "endpoint", "endpoints", "capacity", "quota", "reservation", "eos", "encryption", "encrypt", "decrypt", "known", "unknown", "for", "from", "with", "without", "after", "before", "during", "ready"]
var checks := 0
var failures := 0
var initialized := false
var platform_created := false
var finished := false
var watchdog: Timer
var lab_lobby_id := ""
var test_peer: MultiplayerPeer
var test_root := "user://"
var is_host := false
var status_label: Label
var setup_required := false
var failed_checks: Array[String] = []
var dual_test_started := false
var dual_transfer_passed := false
var room_flow_requested := false
var room_flow_passed := false
var invite_only := false
var invite_only_passed := false
var room_module_hash := ""
var room_flow_proof: Dictionary = {}
var peer_socket_sha256 := ""
var relay_policy := ""
var local_flow_child := false
var local_flow_done := false
var room_ui_passed := false
var local_ui_only := false
var room_ui_hashes: Dictionary = {}
var transport_diagnostics: Dictionary = {"events":[], "sdk_counts":{}, "sdk_templates":{}, "accepted_requests":0, "denied_requests":0}
var connection_started_ms := 0

func _ready() -> void:
	if local_flow_child: return
	if _load_usb_probe(): return
	watchdog = Timer.new()
	watchdog.one_shot = true
	watchdog.wait_time = 180.0
	add_child(watchdog)
	watchdog.timeout.connect(func() -> void:
		check(false, "bounded_sdk_callback_timeout")
		finish())
	watchdog.start()
	if OS.get_name() != "Android": test_root = OS.get_environment("RACER_TEST_ROOT") + "/"
	status_label = Label.new()
	status_label.text = "EOS phone + PC isolation test"
	status_label.position = Vector2(35,80)
	status_label.add_theme_font_size_override("font_size",28)
	add_child(status_label)
	_run.call_deferred()

func _load_usb_probe() -> bool:
	var root := get_tree().root
	var path := "user://network_probe.gd"
	if OS.get_name() != "Android" or not OS.has_feature("debug") or root.has_meta("usb_probe_loaded") or not FileAccess.file_exists(path):
		return false
	root.set_meta("usb_probe_loaded", true)
	root.set_meta("usb_probe_hash", FileAccess.get_file_as_string(path).sha256_text())
	var script := load(path) as GDScript
	if script == null or not script.can_instantiate():
		push_error("USB probe script failed to load")
		var error_label := Label.new()
		error_label.text = "USB probe script failed to load. Check the PC log."
		error_label.position = Vector2(48,80)
		add_child(error_label)
		FileAccess.open("user://result.json", FileAccess.WRITE).store_string(JSON.stringify({"finished":true,"failures":1,"failed_checks":["usb_probe_load_failed"],"dual_transfer_passed":false}))
		return true
	root.call_deferred("add_child", script.new())
	queue_free()
	return true


func check(value: bool, label: String) -> bool:
	checks += 1
	if not value:
		failures += 1
		failed_checks.append(label)
	print(("PASS " if value else "FAIL ") + label)
	if status_label != null: status_label.text = ("PASS " if value else "FAIL ") + label
	FileAccess.open(test_root + "result.json", FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures,"last":label,"finished":false}))
	return value

func _run() -> void:
	local_ui_only = "--local-room-ui" in OS.get_cmdline_user_args()
	if OS.get_name() == "Android" and FileAccess.file_exists("user://session.json"):
		var local_options: Variant = JSON.parse_string(FileAccess.get_file_as_string("user://session.json"))
		if local_options is Dictionary: local_ui_only = local_options.get("local_ui", false) == true
	if "--local-room-flow" in OS.get_cmdline_user_args() or local_ui_only:
		room_flow_requested = true
		room_flow_passed = await test_local_room_flow(local_ui_only)
		room_ui_passed = room_flow_passed if local_ui_only else false
		print("LOCAL_ROOM_FLOW passed=",room_flow_passed," eos_transport=false")
		finish()
		return
	if not check(is_instance_valid(EOS.get_instance()), "native_extension_loaded"):
		finish()
		return
	var sdk_version: String = EOS.Version.VersionInterface.get_version()
	check(not sdk_version.is_empty(), "sdk_version_available")
	print("SDK_VERSION " + sdk_version)
	if "--native-only" in OS.get_cmdline_user_args():
		if "--diagnostic-self-test" in OS.get_cmdline_user_args():
			_record_transport_event({"local_user_id":"fixture_local", "remote_user_id":"fixture_remote", "reason":3, "access_token":"fixture_secret", "address":"fixture_address"}, "peer_connection_closed", "fixture_local", "fixture_remote")
			_record_transport_log({"level":300, "message":"relay timed out fixture_secret fixture_address"})
			var encoded := JSON.stringify(transport_diagnostics)
			check(not "fixture_" in encoded, "transport_diagnostics_exclude_raw_identity_token_and_address")
			check(transport_diagnostics.events[0].reason == 3 and transport_diagnostics.events[0].expected_remote, "transport_diagnostics_keep_reason_and_member_match")
			check(transport_diagnostics.sdk_counts.get("300:relay") == 1 and transport_diagnostics.sdk_counts.get("300:timed out") == 1, "transport_diagnostics_keep_timeout_category")
		if "--peer-api" in OS.get_cmdline_user_args():
			for method in ClassDB.class_get_method_list("EOSGMultiplayerPeer",true):
				print("PEER_METHOD ",JSON.stringify(method))
		if "--p2p-api" in OS.get_cmdline_user_args():
			for entry in ClassDB.class_get_signal_list("EOSGMultiplayerPeer", true): print("PEER_SIGNAL ", JSON.stringify(entry))
			for entry in IEOS.get_signal_list():
				if "p2p" in entry.name or "logging" in entry.name: print("EOS_SIGNAL ", JSON.stringify(entry))
			for entry in IEOS.get_method_list():
				if "p2p" in entry.name or "logging" in entry.name: print("EOS_METHOD ", JSON.stringify(entry))
		finish()
		return
	var config := read_config()
	if config.is_empty():
		finish()
		return
	var init_options := EOS.Platform.InitializeOptions.new()
	init_options.product_name = config.PRODUCT_NAME
	init_options.product_version = config.PRODUCT_VERSION
	var result: EOS.Result = EOS.Platform.PlatformInterface.initialize(init_options)
	if not check(EOS.is_success(result), "sdk_initialize_" + EOS.result_str(result)):
		finish()
		return
	initialized = true
	EOS.Logging.set_log_level(EOS.Logging.LogCategory.AllCategories, EOS.Logging.LogLevel.Off)
	IEOS.logging_interface_callback.connect(_record_transport_log)
	EOS.Logging.set_log_level(EOS.Logging.LogCategory.P2P, EOS.Logging.LogLevel.Verbose)
	EOS.Logging.set_log_level(EOS.Logging.LogCategory.Messaging, EOS.Logging.LogLevel.Warning)
	if "--connect-diagnostics" in OS.get_cmdline_user_args():
		EOS.Logging.set_log_level(EOS.Logging.LogCategory.Connect, EOS.Logging.LogLevel.Verbose)
		EOS.Logging.set_log_level(EOS.Logging.LogCategory.Http, EOS.Logging.LogLevel.Warning)
	var options := EOS.Platform.CreateOptions.new()
	options.product_id = config.PRODUCT_ID
	options.sandbox_id = config.SANDBOX_ID
	options.deployment_id = config.DEPLOYMENT_ID
	options.client_id = config.CLIENT_ID
	options.client_secret = config.CLIENT_SECRET
	options.encryption_key = "" # 不使用文件存储。
	options.flags = EOS.Platform.PlatformFlags.DisableOverlay | EOS.Platform.PlatformFlags.DisableSocialOverlay
	options.cache_directory = ProjectSettings.globalize_path("user://eos-cache")
	DirAccess.make_dir_recursive_absolute(options.cache_directory)
	var session: Variant = JSON.parse_string(FileAccess.get_file_as_string(test_root + "session.json"))
	var native_tick: bool = session is Dictionary and session.get("native_tick", false)
	options.tick_budget_in_milliseconds = 0 if native_tick else 2
	transport_diagnostics.tick_budget_ms = options.tick_budget_in_milliseconds
	options.task_network_timeout_seconds = 8.0
	platform_created = EOS.Platform.PlatformInterface.create(options)
	config.clear()
	if not check(platform_created, "platform_create"):
		finish()
		return
	var device_options := EOS.Connect.CreateDeviceIdOptions.new()
	device_options.device_model = "RacerWindowsIsolationLab"
	# 与上游2.3.1演示不同：不删除既有Device ID，允许复用同一实验身份。
	EOS.Connect.ConnectInterface.create_device_id(device_options)
	var device: Dictionary = await IEOS.connect_interface_create_device_id_callback
	result = device.result_code
	if not check(result == EOS.Result.Success or result == EOS.Result.DuplicateNotAllowed, "device_identity_" + EOS.result_str(result)):
		finish()
		return
	var login_options := EOS.Connect.LoginOptions.new()
	login_options.credentials = EOS.Connect.Credentials.new()
	login_options.credentials.type = EOS.ExternalCredentialType.DeviceidAccessToken
	login_options.user_login_info = EOS.Connect.UserLoginInfo.new()
	login_options.user_login_info.display_name = "RacerLabPC"
	EOS.Connect.ConnectInterface.login(login_options)
	var login: Dictionary = await IEOS.connect_interface_login_callback
	var player_id: String = login.get("local_user_id", "")
	result = login.result_code
	if result == EOS.Result.InvalidUser:
		var create_options := EOS.Connect.CreateUserOptions.new()
		create_options.continuance_token = login.continuance_token
		EOS.Connect.ConnectInterface.create_user(create_options)
		var created: Dictionary = await IEOS.connect_interface_create_user_callback
		result = created.result_code
		player_id = created.get("local_user_id", "")
	if not check(EOS.is_success(result) and not player_id.is_empty(), "anonymous_login_" + EOS.result_str(result)):
		finish()
		return
	if "--cleanup-lobby" in OS.get_cmdline_user_args():
		await cleanup_pending(player_id)
	elif "--member-handle-probe" in OS.get_cmdline_user_args():
		await test_lobby(player_id)
	else:
		dual_test_started = true
		await test_dual(player_id)
		if OS.get_name() == "Android" and is_host and not lab_lobby_id.is_empty():
			await close_dual_lobby(player_id, lab_lobby_id)
	if "--identity-probe" in OS.get_cmdline_user_args():
		# 仅在D盘隔离profile写身份摘要，供本机比较；不打印玩家ID或摘要。
		var proof := FileAccess.open("user://identity-proof.txt", FileAccess.WRITE)
		if check(proof != null, "private_identity_proof_writable"):
			proof.store_string(player_id.sha256_text())
			proof.close()
		for type_name in ClassDB.get_class_list():
			if "EOS" in type_name and ("Peer" in type_name or "Socket" in type_name):
				print("PEER_API_CLASS ", type_name)
				for method in ClassDB.class_get_method_list(type_name, true):
					print("PEER_API_METHOD ", JSON.stringify(method))
	if "--lobby-probe" in OS.get_cmdline_user_args():
		await test_lobby(player_id)
	var logout_options := EOS.Connect.LogoutOptions.new()
	logout_options.local_user_id = player_id
	EOS.Connect.ConnectInterface.logout(logout_options)
	var logout: Dictionary = await IEOS.connect_interface_logout_callback
	check(EOS.is_success(logout), "logout_" + EOS.result_str(logout))
	finish()

func test_lobby(player_id: String) -> void:
	var options := EOS.Lobby.CreateLobbyOptions.new()
	options.local_user_id = player_id
	options.bucket_id = "RacerIsolationProbe-" + Crypto.new().generate_random_bytes(8).hex_encode()
	options.max_lobby_members = 2
	options.presence_enabled = false
	options.enable_rtc_room = false
	options.disable_host_migration = true
	options.allow_invites = false
	options.enable_join_by_id = false
	EOS.Lobby.LobbyInterface.create_lobby(options)
	var created: Dictionary = await IEOS.lobby_interface_create_lobby_callback
	if not check(EOS.is_success(created), "lobby_create_" + EOS.result_str(created)): return
	lab_lobby_id = created.lobby_id
	# 若进程意外退出，保留清理定位信息在D盘私有profile，不打印ID。
	var pending := FileAccess.open("user://pending-lobby.txt", FileAccess.WRITE)
	pending.store_string(lab_lobby_id)
	pending.close()
	await check_lobby_data(player_id)
	var destroy_options := EOS.Lobby.DestroyLobbyOptions.new()
	destroy_options.local_user_id = player_id
	destroy_options.lobby_id = lab_lobby_id
	EOS.Lobby.LobbyInterface.destroy_lobby(destroy_options)
	var destroyed: Dictionary = await IEOS.lobby_interface_destroy_lobby_callback
	if check(EOS.is_success(destroyed), "lobby_destroy_" + EOS.result_str(destroyed)):
		lab_lobby_id = ""
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://pending-lobby.txt"))

func check_lobby_data(player_id: String) -> void:
	var modification_options := EOS.Lobby.UpdateLobbyModificationOptions.new()
	modification_options.local_user_id = player_id
	modification_options.lobby_id = lab_lobby_id
	var modified: Dictionary = EOS.Lobby.LobbyInterface.update_lobby_modification(modification_options)
	if not check(EOS.is_success(modified), "lobby_modification_" + EOS.result_str(modified)): return
	var modification: EOSGLobbyModification = modified.lobby_modification
	var result: EOS.Result = modification.add_attribute("RACER_LAB_LEVEL", "L2", EOS.Lobby.LobbyAttributeVisibility.Public)
	check(EOS.is_success(result), "lobby_level_attribute")
	result = modification.add_attribute("RACER_LAB_LAPS", 2, EOS.Lobby.LobbyAttributeVisibility.Public)
	check(EOS.is_success(result), "lobby_laps_attribute")
	if "--member-handle-probe" in OS.get_cmdline_user_args():
		var added: EOS.Result = modification.add_member_attribute("RACER_READY", true, EOS.Lobby.LobbyAttributeVisibility.Public)
		check(EOS.is_success(added), "member_ready_attribute_added")
	var update_options := EOS.Lobby.UpdateLobbyOptions.new()
	update_options.lobby_modification = modification
	EOS.Lobby.LobbyInterface.update_lobby(update_options)
	var updated: Dictionary = await IEOS.lobby_interface_update_lobby_callback
	if not check(EOS.is_success(updated), "lobby_update_" + EOS.result_str(updated)): return
	var search_options := EOS.Lobby.CreateLobbySearchOptions.new()
	search_options.max_results = 1
	var search_created: Dictionary = EOS.Lobby.LobbyInterface.create_lobby_search(search_options)
	if not check(EOS.is_success(search_created), "lobby_search_handle"): return
	var search: EOSGLobbySearch = search_created.lobby_search
	result = search.set_lobby_id(lab_lobby_id)
	if not check(EOS.is_success(result), "lobby_search_filter"): return
	var count := 0
	for attempt in range(3):
		search.find(player_id)
		var found: Dictionary = await IEOS.lobby_search_find_callback
		if not check(EOS.is_success(found), "lobby_search_" + EOS.result_str(found)): return
		count = search.get_search_result_count()
		if count > 0: break
		if attempt < 2: await get_tree().create_timer(0.5).timeout
	if not check(count == 1, "lobby_found_by_exact_id"): return
	var copied: Dictionary = search.copy_search_result_by_index(0)
	if not check(EOS.is_success(copied), "lobby_copy_details"): return
	var details: EOSGLobbyDetails = copied.lobby_details
	var info: Dictionary = details.copy_info()
	if not check(EOS.is_success(info), "lobby_read_info"): return
	check(int(info.lobby_details.max_members) == 2, "lobby_two_player_capacity")
	if "--member-handle-probe" in OS.get_cmdline_user_args():
		check(details.get_member_by_index(0).is_empty(), "search_handle_cannot_enumerate_members")
		var joined := joined_details(player_id, lab_lobby_id)
		if not check(joined != null, "joined_handle_available"): return
		check(joined.get_member_count() == 1 and joined.get_member_by_index(0) == player_id, "joined_handle_enumerates_local_member")
		var ready: Dictionary = joined.copy_member_attribute_by_key(player_id, "RACER_READY")
		check(member_is_ready(ready), "joined_handle_reads_ready_value")
		for value in [true, 1]:
			check(member_is_ready({"result_code":EOS.Result.Success,"attribute":{"data":{"value":value}}}), "ready_true_value_" + type_string(typeof(value)))
		for value in [false, 0, 2, "true"]:
			check(not member_is_ready({"result_code":EOS.Result.Success,"attribute":{"data":{"value":value}}}), "ready_rejects_" + type_string(typeof(value)))
	var attributes: Dictionary = {}
	for index in range(details.get_attribute_count()):
		var attribute: Dictionary = details.copy_attribute_by_index(index)
		if EOS.is_success(attribute): attributes[attribute.attribute.data.key] = attribute.attribute.data.value
	check(attributes.get("RACER_LAB_LEVEL") == "L2" and attributes.get("RACER_LAB_LAPS") == 2, "lobby_shared_test_rules_readback")

func read_config() -> Dictionary:
	var path := "user://config.env" if OS.get_name() == "Android" else OS.get_environment("RACER_EOS_CONFIG")
	if not check(FileAccess.file_exists(path), "private_config_available"):
		setup_required = true
		return {}
	var config: Dictionary = {}
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var text := line.strip_edges()
		if text.is_empty() or text.begins_with("#"): continue
		var pair := text.split("=", true, 1)
		if pair.size() == 2: config[pair[0]] = pair[1].trim_prefix('"').trim_suffix('"')
	for key in ["PRODUCT_NAME", "PRODUCT_VERSION", "PRODUCT_ID", "SANDBOX_ID", "DEPLOYMENT_ID", "CLIENT_ID", "CLIENT_SECRET"]:
		if not check(not str(config.get(key, "")).is_empty(), "config_present_" + key):
			setup_required = true
			return {}
	return config

func finish() -> void:
	if finished: return
	finished = true
	watchdog.stop()
	if test_peer != null:
		test_peer.close()
		test_peer = null
	get_node("/root/EOSGRuntime").set_process(false)
	# SDK回调从tick内部发出，等当前tick退栈后再释放句柄。
	_shutdown.call_deferred()

func _shutdown() -> void:
	if dual_test_started and not invite_only and not dual_transfer_passed and failures == 0:
		check(false, "dual_transport_incomplete")
	if room_flow_requested and not invite_only and not room_flow_passed and failures == 0:
		check(false, "room_flow_incomplete")
	if invite_only and not invite_only_passed and failures == 0:
		check(false, "invite_only_incomplete")
	if not lab_lobby_id.is_empty():
		check(false, "lobby_cleanup_pending_in_private_profile")
	if platform_created:
		EOS.Platform.PlatformInterface.release()
		platform_created = false
	if initialized:
		var result: EOS.Result = EOS.Platform.PlatformInterface.shutdown()
		check(EOS.is_success(result), "sdk_shutdown_" + EOS.result_str(result))
		initialized = false
	print("EOS_PROBE checks=%d failures=%d" % [checks, failures])
	var report := {"checks":checks,"failures":failures,"finished":true,"host":is_host,
		"setup_required":setup_required,"failed_checks":failed_checks,"dual_transfer_passed":dual_transfer_passed,
		"room_flow_requested":room_flow_requested,"room_flow_passed":room_flow_passed,
		"invite_only":invite_only,"invite_only_passed":invite_only_passed,
		"room_module_sha256":room_module_hash,"room_flow_proof":room_flow_proof,
		"room_ui_passed":room_ui_passed,"room_ui_hashes":room_ui_hashes,"local_ui_only":local_ui_only,
		"peer_socket_sha256":peer_socket_sha256,"relay_policy":relay_policy,"transport_diagnostics":transport_diagnostics,
		"usb_script_sha256":get_tree().root.get_meta("usb_probe_hash", "")}
	FileAccess.open(test_root + "result.json",FileAccess.WRITE).store_string(JSON.stringify(report))
	if OS.get_name() == "Android":
		status_label.position = Vector2(48, 80)
		status_label.size = Vector2(get_viewport().get_visible_rect().size.x - 96, 440)
		status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		status_label.text = "USB test setup required.\nThis app needs temporary configuration from the PC test runner.\nKeep USB connected, then start the PC + phone test.\nNo login credentials are stored in this APK." if setup_required else "Test finished: %d checks, %d failures.\n%s" % [checks, failures, "All checks passed." if failed_checks.is_empty() else "Failed: " + ", ".join(failed_checks)]
		var close := Button.new()
		close.text = "Close test app"
		close.position = Vector2(48, 540)
		close.size = Vector2(320, 80)
		close.pressed.connect(func(): get_tree().quit(0 if failures == 0 else 1))
		add_child(close)
		return
	get_tree().quit(0 if failures == 0 else 1)

func search_details(player_id: String, key: String, by_invite: bool) -> EOSGLobbyDetails:
	var options := EOS.Lobby.CreateLobbySearchOptions.new()
	options.max_results = 2 if by_invite else 1
	var created: Dictionary = EOS.Lobby.LobbyInterface.create_lobby_search(options)
	if not check(EOS.is_success(created), "search_handle"): return null
	var search: EOSGLobbySearch = created.lobby_search
	if by_invite:
		if not check(EOS.is_success(search.set_parameter(ROOM_CODE_ATTRIBUTE, key, EOS.ComparisonOp.Equal)), "invite_search_parameter"): return null
	else:
		search.set_lobby_id(key)
	# 新公开属性可能尚未进入EOS的搜索索引。
	var attempts := 5 if by_invite else 1
	for attempt in range(attempts):
		search.find(player_id)
		var found: Dictionary = await IEOS.lobby_search_find_callback
		if not check(EOS.is_success(found) or (by_invite and found.result_code == EOS.Result.NotFound), "exact_lobby_search"): return null
		var count := search.get_search_result_count() if EOS.is_success(found) else 0
		if not check(count <= 1, "invite_search_is_unambiguous"): return null
		if count == 1:
			var copy: Dictionary = search.copy_search_result_by_index(0)
			return copy.lobby_details if EOS.is_success(copy) else null
		if attempt + 1 < attempts: await get_tree().create_timer(1.0).timeout
	return null


func publish_next_invite(player_id: String, lobby_id: String, invite: RefCounted,
		room_module: GDScript, clock_offset_ms: int) -> bool:
	var next_code: String = room_module.make_code()
	while next_code == invite.code:
		next_code = room_module.make_code()
	var options := EOS.Lobby.UpdateLobbyModificationOptions.new()
	options.lobby_id = lobby_id
	options.local_user_id = player_id
	var handle: Dictionary = EOS.Lobby.LobbyInterface.update_lobby_modification(options)
	if not check(EOS.is_success(handle), "rotate_invite_handle"): return false
	var modification: EOSGLobbyModification = handle.lobby_modification
	if not check(EOS.is_success(modification.add_attribute(ROOM_CODE_ATTRIBUTE, next_code,
			EOS.Lobby.LobbyAttributeVisibility.Public)), "rotate_invite_attribute"): return false
	var update := EOS.Lobby.UpdateLobbyOptions.new()
	update.lobby_modification = modification
	EOS.Lobby.LobbyInterface.update_lobby(update)
	var updated: Dictionary = await IEOS.lobby_interface_update_lobby_callback
	return check(EOS.is_success(updated) and invite.publish(next_code, Time.get_ticks_msec() + clock_offset_ms),
		"rotated_invite_published_to_same_lobby")


func export_invite(session: Dictionary, lobby_id: String, nonce: String) -> void:
	var exported := {"host":false,"lobby_id":lobby_id,"nonce":nonce,"relay":session.relay}
	if room_flow_requested:
		exported = {"host":false,"code":session.code,"relay":session.relay,"room_flow":true}
	if session.get("room_ui", false): exported.room_ui = true
	if session.get("mesh_probe", false): exported.mesh_probe = true
	if session.get("mesh_listener_first", false): exported.mesh_listener_first = true
	if session.get("mesh_pc_initiates", false): exported.mesh_pc_initiates = true
	if session.get("native_tick", false): exported.native_tick = true
	if invite_only:
		exported.invite_only = true
		exported.expired_code = session.expired_code
	FileAccess.open(test_root+"export-session.json",FileAccess.WRITE).store_string(JSON.stringify(exported))

func _capture_nat_diagnostics() -> void:
	var callback := func(result: Dictionary):
		transport_diagnostics.nat = {"result":EOS.result_str(result.result_code), "type":int(result.nat_type)}
	IEOS.p2p_interface_query_nat_type_callback.connect(callback, CONNECT_ONE_SHOT)
	IEOS.p2p_interface_query_nat_type()
	var deadline := Time.get_ticks_msec() + 8000
	while not transport_diagnostics.has("nat") and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if IEOS.p2p_interface_query_nat_type_callback.is_connected(callback):
		IEOS.p2p_interface_query_nat_type_callback.disconnect(callback)
		transport_diagnostics.nat = {"result":"callback_timeout"}


static func member_is_ready(attribute: Dictionary) -> bool:
	if not EOS.is_success(attribute): return false
	var value: Variant = attribute.attribute.data.value
	# EOSG的EOS_Bool可能以整数返回；仅接受bool true或整数1。
	return (value is bool and value) or (value is int and value == 1)


func joined_details(player_id: String, lobby_id: String) -> EOSGLobbyDetails:
	var options := EOS.Lobby.CopyLobbyDetailsOptions.new()
	options.local_user_id = player_id
	options.lobby_id = lobby_id
	var copied: Dictionary = EOS.Lobby.LobbyInterface.copy_lobby_details(options)
	return copied.lobby_details if EOS.is_success(copied) else null



func _record_transport_event(data: Dictionary, event: String, local_user: String, remote_user: String) -> void:
	# 只记录枚举、匹配结果和时间；不输出原始回调、用户ID或地址。
	if transport_diagnostics.events.size() >= 32: return
	var entry := {"event":event, "elapsed_ms":Time.get_ticks_msec() - connection_started_ms,
		"expected_local":str(data.get("local_user_id", "")) == local_user,
		"expected_remote":str(data.get("remote_user_id", "")) == remote_user}
	for key in ["reason", "connection_closed_reason", "network_type", "connection_type"]:
		var value: Variant = data.get(key)
		if value is int: entry[key] = value
	transport_diagnostics.events.append(entry)
	print("TRANSPORT_EVENT ", JSON.stringify(entry))

func _record_transport_log(data: Dictionary) -> void:
	# SDK消息可能含身份/地址/令牌；仅累积固定关键词，不保存或打印消息原文。
	var message := str(data.get("message", "")).to_lower()
	var level := int(data.get("level", 0))
	var tokens := PackedStringArray()
	var pattern := RegEx.new()
	pattern.compile("[A-Za-z]+")
	for matched in pattern.search_all(message):
		var word: String = matched.get_string()
		if word in DIAGNOSTIC_WORDS: tokens.append(word)
	var template := str(level) + ":" + " ".join(tokens).left(240)
	var templates: Dictionary = transport_diagnostics.sdk_templates
	if templates.has(template) or templates.size() < 80:
		templates[template] = int(templates.get(template, 0)) + 1

	var counts: Dictionary = transport_diagnostics.sdk_counts
	var level_key := "level_" + str(level)
	counts[level_key] = int(counts.get(level_key, 0)) + 1
	for word in ["relay", "turn", "stun", "ice", "timeout", "timed out", "fail", "error", "auth", "denied", "allocat", "negotiat", "connect", "socket", "send", "receiv", "disconnect", "proxy", "curl", "resolve", "certificate", "ssl", "tls"]:
		if word in message:
			var key: String = str(level) + ":" + str(word)
			counts[key] = int(counts.get(key, 0)) + 1

func test_pc_menu_admission(player_id: String, code: String) -> void:
	var details := await search_details(player_id, code, true)
	if not check(details != null, "production_pc_lobby_found_by_invite"): return
	var info := details.copy_info()
	if not check(EOS.is_success(info) and info.lobby_details.bucket_id == "GodotRacerPC-v1",
			"production_pc_lobby_matches_version"): return
	var lobby_id: String = info.lobby_details.lobby_id
	var host: String = info.lobby_details.lobby_owner_user_id
	if not check(not host.is_empty() and host != player_id, "phone_and_pc_have_distinct_eos_identities"): return
	var join := EOS.Lobby.JoinLobbyOptions.new()
	join.local_user_id = player_id
	join.lobby_details = details
	EOS.Lobby.LobbyInterface.join_lobby(join)
	var joined: Dictionary = await IEOS.lobby_interface_join_lobby_callback
	if not check(EOS.is_success(joined), "phone_joined_production_pc_lobby"): return
	var admitted := false
	if await publish_member_ready(player_id, lobby_id, code):
		var deadline := Time.get_ticks_msec() + 15000
		while Time.get_ticks_msec() < deadline:
			var current := joined_details(player_id, lobby_id)
			if current == null: break
			var value := current.copy_member_attribute_by_key(host, "RACER_ADMITTED_USER")
			if EOS.is_success(value) and value.attribute.data.value == player_id:
				admitted = true
				break
			await get_tree().create_timer(0.25).timeout
	check(admitted, "formal_pc_host_confirmed_phone_admission")
	var left := await close_dual_lobby(player_id, lobby_id)
	invite_only_passed = admitted and left


func test_dual(player_id: String) -> void:
	var session: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(test_root + "session.json"))
	if OS.get_name() == "Android" and session.get("cleanup_lobby", false):
		dual_test_started = false
		await cleanup_pending(player_id)
		return
	is_host = bool(session.get("host",false))
	if session.get("pc_menu_admission", false):
		invite_only = true
		await test_pc_menu_admission(player_id, str(session.get("code", "")))
		return
	room_flow_requested = bool(session.get("room_flow",false))
	invite_only = bool(session.get("invite_only", false))
	var nonce: String = session.get("nonce", "")
	var room_code: String = session.get("code", "")
	var room_module: GDScript
	var invite: RefCounted
	var invite_clock_offset := 0
	if room_flow_requested:
		var module_path := "user://online_room_state.gd" if OS.get_name() == "Android" else OS.get_environment("RACER_ROOM_MODULE")
		room_module = load(module_path)
		if not check(room_module != null and room_module.can_instantiate(), "invite_rules_loaded"): return
		if invite_only: room_module_hash = FileAccess.get_sha256(module_path)
		room_code = room_module.normalize_code(room_code)
		if not check(not room_code.is_empty(), "invite_code_valid"): return
		session.code = room_code
		if is_host: invite = room_module.HostInvite.new()
	var socket_id := ""
	var lobby_id := ""
	var remote_user := ""
	if is_host:
		var options := EOS.Lobby.CreateLobbyOptions.new()
		options.local_user_id = player_id
		options.bucket_id = "RacerDual-" + nonce
		options.max_lobby_members = 2
		options.presence_enabled = false
		options.enable_rtc_room = false
		options.disable_host_migration = true
		options.allow_invites = false
		EOS.Lobby.LobbyInterface.create_lobby(options)
		var created: Dictionary = await IEOS.lobby_interface_create_lobby_callback
		if not check(EOS.is_success(created), "dual_lobby_create"): return
		lobby_id = created.lobby_id
		lab_lobby_id = lobby_id
		FileAccess.open(test_root+"pending-lobby.txt",FileAccess.WRITE).store_string(lobby_id)
		var modification_options := EOS.Lobby.UpdateLobbyModificationOptions.new()
		modification_options.lobby_id=lobby_id
		modification_options.local_user_id=player_id
		var handle: Dictionary = EOS.Lobby.LobbyInterface.update_lobby_modification(modification_options)
		if not check(EOS.is_success(handle), "dual_rules_handle"): return
		var modification: EOSGLobbyModification = handle.lobby_modification
		modification.add_attribute("RACER_LAB_LEVEL","L2",EOS.Lobby.LobbyAttributeVisibility.Public)
		modification.add_attribute("RACER_LAB_LAPS",2,EOS.Lobby.LobbyAttributeVisibility.Public)
		if room_flow_requested:
			if not check(EOS.is_success(modification.add_attribute(ROOM_CODE_ATTRIBUTE, room_code,
					EOS.Lobby.LobbyAttributeVisibility.Public)), "invite_attribute_added"): return
			modification.add_attribute("RACER_ROOM_CONFIG",JSON.stringify(session.config),EOS.Lobby.LobbyAttributeVisibility.Public)
			modification.add_attribute("RACER_LINK_NONCE",nonce,EOS.Lobby.LobbyAttributeVisibility.Public)
		var update := EOS.Lobby.UpdateLobbyOptions.new()
		update.lobby_modification = modification
		EOS.Lobby.LobbyInterface.update_lobby(update)
		var updated: Dictionary = await IEOS.lobby_interface_update_lobby_callback
		if not check(EOS.is_success(updated), "dual_rules_published"): return
		if invite != null:
			if not check(invite.publish(room_code, Time.get_ticks_msec()), "invite_lifetime_starts_after_publication"): return
			if invite_only:
				var original := await search_details(player_id, room_code, true)
				if not check(original != null, "original_code_indexed_before_rotation"): return
				var original_info: Dictionary = original.copy_info()
				if not check(EOS.is_success(original_info) and original_info.lobby_details.lobby_id == lobby_id,
						"original_code_resolves_to_created_lobby"): return
				session.expired_code = room_code
			if session.get("rotate_invite_before_join", false):
				# 只在隔离验收中推进房主时钟，复用真实的同房换码请求。
				invite_clock_offset = room_module.HostInvite.VALID_MS
				if not await publish_next_invite(player_id, lobby_id, invite, room_module, invite_clock_offset): return
				session.code = invite.code
		export_invite(session, lobby_id, nonce)
	else:
		lobby_id = str(session.get("lobby_id", ""))
		var details: EOSGLobbyDetails = await search_details(player_id,
			room_code if room_flow_requested else lobby_id, room_flow_requested)
		if not check(details != null,"phone_found_pc_lobby"): return
		if room_flow_requested:
			var info: Dictionary = details.copy_info()
			if not check(EOS.is_success(info) and not str(info.lobby_details.lobby_id).is_empty(), "matched_lobby_id_resolved"): return
			lobby_id = info.lobby_details.lobby_id
		var attrs: Dictionary = {}
		for index in range(details.get_attribute_count()):
			var value: Dictionary = details.copy_attribute_by_index(index)
			if EOS.is_success(value): attrs[value.attribute.data.key] = value.attribute.data.value
		if not check(attrs.get("RACER_LAB_LEVEL")=="L2" and attrs.get("RACER_LAB_LAPS")==2,"phone_sees_effective_rules"): return
		if room_flow_requested:
			if not check(attrs.get(ROOM_CODE_ATTRIBUTE)==room_code,"room_found_by_public_invite_attribute"): return
			session.config = JSON.parse_string(str(attrs.get("RACER_ROOM_CONFIG", "")))
			nonce = str(attrs.get("RACER_LINK_NONCE", ""))
			if not check(session.config is Dictionary and not nonce.is_empty(),"room_config_and_connection_read_from_eos"): return
		if invite_only:
			var expired_code: String = room_module.normalize_code(str(session.get("expired_code", "")))
			if not check(not expired_code.is_empty() and expired_code != room_code, "rotation_provides_distinct_codes"): return
			var expired := await search_details(player_id, expired_code, true)
			if not check(expired == null, "expired_code_no_longer_searchable"): return
		var join := EOS.Lobby.JoinLobbyOptions.new()
		join.local_user_id = player_id
		join.lobby_details = details
		join.presence_enabled = false
		EOS.Lobby.LobbyInterface.join_lobby(join)
		var joined: Dictionary = await IEOS.lobby_interface_join_lobby_callback
		if not check(EOS.is_success(joined),"phone_joined_pc_lobby"): return
	if not invite_only or not is_host:
		if not await publish_member_ready(player_id, lobby_id, room_code if not is_host and room_flow_requested else ""): return
	var deadline := Time.get_ticks_msec()+90000
	var last_member_count := -1
	var self_ready := false
	while Time.get_ticks_msec()<deadline and (remote_user.is_empty() or not self_ready):
		if invite != null and invite.needs_code(Time.get_ticks_msec() + invite_clock_offset):
			if not await publish_next_invite(player_id, lobby_id, invite, room_module, invite_clock_offset): return
			session.code = invite.code
			export_invite(session, lobby_id, nonce)
		# 搜索结果没有成员属性；加入后从本地订阅缓存复制活动大厅句柄。
		var details: EOSGLobbyDetails = joined_details(player_id,lobby_id)
		if details == null:
			check(false, "joined_lobby_handle_available")
			return
		if details.get_member_count() != last_member_count:
			last_member_count = details.get_member_count()
			print("LOBBY_MEMBER_COUNT ", last_member_count)
		var own_ready: Dictionary = details.copy_member_attribute_by_key(player_id, "RACER_READY")
		self_ready = (invite_only and is_host) or member_is_ready(own_ready)
		if remote_user.is_empty() and details.get_member_count()==2:
			for i in range(2):
				var user: String = details.get_member_by_index(i)
				if user == player_id: continue
				var ready: Dictionary = details.copy_member_attribute_by_key(user,"RACER_READY")
				if not member_is_ready(ready): continue
				if invite != null:
					var submitted: Dictionary = details.copy_member_attribute_by_key(user, JOIN_CODE_ATTRIBUTE)
					var submitted_code := str(submitted.attribute.data.value) if EOS.is_success(submitted) else ""
					if not invite.claim(submitted_code, Time.get_ticks_msec() + invite_clock_offset):
						var kick := EOS.Lobby.KickMemberOptions.new()
						kick.local_user_id = player_id
						kick.lobby_id = lobby_id
						kick.target_user_id = user
						EOS.Lobby.LobbyInterface.kick_member(kick)
						var kicked: Dictionary = await IEOS.lobby_interface_kick_member_callback
						if not check(EOS.is_success(kicked), "invalid_invite_member_removed"): return
						break
				remote_user = user
		if remote_user.is_empty() or not self_ready: await get_tree().create_timer(1.0).timeout
	if not check(self_ready and not remote_user.is_empty() and remote_user != player_id,"two_distinct_identities_both_ready"): return
	if invite_only:
		if is_host:
			if not check(invite.claimed and session.code != session.expired_code, "host_admitted_new_code_in_original_lobby"): return
			# 此模式的房主准备标志只在验码后发布，作为手机离房前的回执。
			if not await publish_member_ready(player_id, lobby_id): return
			var leave_deadline := Time.get_ticks_msec() + 10000
			var guest_left := false
			while Time.get_ticks_msec() < leave_deadline:
				var current := joined_details(player_id, lobby_id)
				if current != null and current.get_member_count() == 1:
					guest_left = true
					break
				await get_tree().create_timer(0.5).timeout
			if not check(guest_left, "host_observed_guest_leave"): return
		invite_only_passed = await close_dual_lobby(player_id, lobby_id)
		return
	socket_id = "Racer" + nonce.substr(0,12)
	peer_socket_sha256 = socket_id.sha256_text()
	relay_policy = "ForceRelays" if bool(session.relay) else "AllowRelays"
	var control := EOS.P2P.RelayControl.ForceRelays if bool(session.relay) else EOS.P2P.RelayControl.AllowRelays
	if not check(EOS.is_success(EOS.P2P.P2PInterface.set_relay_control(control)),"relay_policy_set"): return
	var native_peer := EOSGMultiplayerPeer.new()
	test_peer = native_peer
	native_peer.set_auto_accept_connection_requests(not room_flow_requested)
	connection_started_ms = Time.get_ticks_msec()
	for event in ["incoming_connection_request", "peer_connection_established", "peer_connection_interrupted", "peer_connection_closed"]:
		native_peer.connect(event, _record_transport_event.bind(event, player_id, remote_user))
	var remote_peer := [0]
	test_peer.peer_connected.connect(func(id: int): remote_peer[0]=id)
	var mesh := bool(session.get("mesh_probe", false))
	var listener_first := bool(session.get("mesh_listener_first", false))
	transport_diagnostics.peer_mode = "mesh" if mesh else "server_client"
	var result: int
	if mesh:
		result = native_peer.create_mesh(socket_id)
		if result == OK and not listener_first:
			result = native_peer.add_mesh_peer(remote_user)
	else:
		result = native_peer.create_server(socket_id) if is_host else native_peer.create_client(socket_id,remote_user)
	if not check(result == OK,"peer_created"): return
	if not check(native_peer.get_local_user_id()==player_id and native_peer.get_socket()==socket_id,"peer_bound_to_login_and_socket"): return
	if listener_first:
		var pc_initiates := bool(session.get("mesh_pc_initiates", false))
		transport_diagnostics.peer_mode = "mesh_pc_initiates" if pc_initiates else "mesh_listener_first"
		var listening := "RACER_P2P_LISTENING"
		if not await publish_member_ready(player_id, lobby_id, "", listening): return
		deadline = Time.get_ticks_msec() + 12000
		var remote_listening := false
		while not remote_listening and Time.get_ticks_msec() < deadline:
			var details := joined_details(player_id, lobby_id)
			remote_listening = details != null and member_is_ready(details.copy_member_attribute_by_key(remote_user, listening))
			if not remote_listening: await get_tree().create_timer(0.2).timeout
		if not check(remote_listening, "both_p2p_listeners_registered"): return
		if is_host == pc_initiates and not check(native_peer.add_mesh_peer(remote_user) == OK, "peer_initiates_after_both_listen"): return
	deadline = Time.get_ticks_msec()+35000
	while remote_peer[0]==0 and Time.get_ticks_msec()<deadline:
		test_peer.poll()
		if room_flow_requested:
			for user in native_peer.get_all_connection_requests():
				if user == remote_user:
					native_peer.accept_connection_request(user)
					transport_diagnostics.accepted_requests += 1
				else:
					native_peer.deny_connection_request(user)
					transport_diagnostics.denied_requests += 1
		await get_tree().process_frame
	transport_diagnostics.connection_wait_ms = Time.get_ticks_msec() - connection_started_ms
	transport_diagnostics.peer_status = test_peer.get_connection_status()
	transport_diagnostics.pending_requests = native_peer.get_all_connection_requests().size()
	if mesh and remote_peer[0] == 0: await _capture_nat_diagnostics()
	print("TRANSPORT_DIAGNOSTICS ", JSON.stringify(transport_diagnostics))
	if not check(remote_peer[0]!=0,"phone_pc_peer_connected"): return
	if not check(native_peer.get_peer_user_id(remote_peer[0])==remote_user,"peer_is_expected_lobby_member"): return
	test_peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	test_peer.set_target_peer(remote_peer[0])
	var received: Dictionary = {}
	var acknowledgements: Dictionary = {}
	var local_transfer_done := false
	var remote_transfer_done := false
	var last_sent := 0
	deadline = Time.get_ticks_msec()+15000
	while Time.get_ticks_msec()<deadline:
		test_peer.poll()
		if not local_transfer_done and Time.get_ticks_msec()-last_sent>=200:
			last_sent = Time.get_ticks_msec()
			for i in range(10):
				var message := {"nonce":nonce,"host":is_host,"level":"L2","laps":2,"ready":true,"index":i,"ack":false}
				if not check(test_peer.put_packet(JSON.stringify(message).to_utf8_buffer())==OK,"packet_submitted"): return
		while test_peer.get_available_packet_count()>0:
			var source := test_peer.get_packet_peer()
			var bytes := test_peer.get_packet()
			if bytes.size()>1024: check(false,"bounded_packet");return
			var message: Variant = JSON.parse_string(bytes.get_string_from_utf8())
			if room_flow_requested and message is Dictionary and message.get("kind")=="transport_done":
				if source!=remote_peer[0] or message.get("nonce")!=nonce: return
				remote_transfer_done = true
				if local_transfer_done: break
				continue
			if not message is Dictionary or source!=remote_peer[0] or message.get("nonce")!=nonce or message.get("host")==is_host or message.get("level")!="L2" or message.get("laps")!=2 or message.get("ready")!=true:
				check(false,"packet_identity_rules_validation");return
			var index := int(message.index)
			if bool(message.ack): acknowledgements[index]=true
			else:
				received[index]=true
				message.host=is_host
				message.ack=true
				test_peer.put_packet(JSON.stringify(message).to_utf8_buffer())
			if room_flow_requested and received.size()==10 and acknowledgements.size()==10 and not local_transfer_done:
				if not room_packet("transport_done",nonce): return
				local_transfer_done = true
			if local_transfer_done and remote_transfer_done: break
		if received.size()==10 and acknowledgements.size()==10 and (not room_flow_requested or remote_transfer_done): break
		await get_tree().process_frame
	dual_transfer_passed = check(received.size()==10 and acknowledgements.size()==10,"bidirectional_ten_packets_acknowledged")
	if dual_transfer_passed and room_flow_requested:
		if session.get("room_ui", false):
			room_ui_passed = await test_shared_room_ui(session, nonce, remote_peer[0])
			room_flow_passed = room_ui_passed
		else:
			room_flow_passed = await test_room_flow(session, nonce, remote_peer[0])
	await get_tree().create_timer(1.0).timeout
	test_peer.close()
	test_peer = null
	await close_dual_lobby(player_id, lobby_id)


func publish_member_ready(player_id: String, lobby_id: String, code := "", attribute := "RACER_READY") -> bool:
	var ready_options := EOS.Lobby.UpdateLobbyModificationOptions.new()
	ready_options.lobby_id = lobby_id
	ready_options.local_user_id = player_id
	var ready_handle: Dictionary = EOS.Lobby.LobbyInterface.update_lobby_modification(ready_options)
	if not check(EOS.is_success(ready_handle), "ready_handle"): return false
	var modification: EOSGLobbyModification = ready_handle.lobby_modification
	if not code.is_empty():
		if not check(EOS.is_success(modification.add_member_attribute(JOIN_CODE_ATTRIBUTE, code,
				EOS.Lobby.LobbyAttributeVisibility.Public)), "guest_submitted_invite"): return false
	var ready_added: EOS.Result = modification.add_member_attribute(attribute, true, EOS.Lobby.LobbyAttributeVisibility.Public)
	if not check(EOS.is_success(ready_added), "ready_attribute_added_" + EOS.result_str(ready_added)): return false
	var ready_update := EOS.Lobby.UpdateLobbyOptions.new()
	ready_update.lobby_modification = modification
	EOS.Lobby.LobbyInterface.update_lobby(ready_update)
	var ready_result: Dictionary = await IEOS.lobby_interface_update_lobby_callback
	return check(EOS.is_success(ready_result), "local_ready_published")


func close_dual_lobby(player_id: String, lobby_id: String) -> bool:
	if not is_host:
		var leave := EOS.Lobby.LeaveLobbyOptions.new()
		leave.local_user_id=player_id
		leave.lobby_id=lobby_id
		EOS.Lobby.LobbyInterface.leave_lobby(leave)
		var left: Dictionary = await IEOS.lobby_interface_leave_lobby_callback
		return check(EOS.is_success(left),"phone_left_lobby")
	else:
		await get_tree().create_timer(2.0).timeout
		var destroy := EOS.Lobby.DestroyLobbyOptions.new()
		destroy.local_user_id=player_id
		destroy.lobby_id=lobby_id
		EOS.Lobby.LobbyInterface.destroy_lobby(destroy)
		var destroyed: Dictionary = await IEOS.lobby_interface_destroy_lobby_callback
		if check(EOS.is_success(destroyed),"dual_lobby_destroyed"):
			lab_lobby_id=""
			DirAccess.remove_absolute(test_root+"pending-lobby.txt")
			return true
	return false

## 只绑定127.0.0.1的双端协议回归；不能把这里的结果当作EOS/手机通过。
func test_local_room_flow(use_ui := false) -> bool:
	var server := ENetMultiplayerPeer.new()
	server.set_bind_ip("127.0.0.1")
	if not check(server.create_server(0,1)==OK,"local_protocol_server"): return false
	var client := ENetMultiplayerPeer.new()
	if not check(client.create_client("127.0.0.1",server.get_host().get_local_port())==OK,"local_protocol_client"): return false
	test_peer = server
	var guest: Node = get_script().new()
	guest.local_flow_child = true
	guest.test_root = test_root
	guest.test_peer = client
	add_child(guest)
	var ids := [0,0]
	server.peer_connected.connect(func(id: int): ids[0]=id)
	client.peer_connected.connect(func(id: int): ids[1]=id)
	var deadline := Time.get_ticks_msec()+3000
	while (ids[0]==0 or ids[1]==0) and Time.get_ticks_msec()<deadline:
		server.poll()
		client.poll()
		await get_tree().process_frame
	if not check(ids[0]!=0 and ids[1]!=0,"local_protocol_connected"):
		client.close()
		guest.queue_free()
		return false
	server.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	client.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	server.set_target_peer(ids[0])
	client.set_target_peer(ids[1])
	var rules_path := "user://room-rules.json" if OS.get_name() == "Android" else OS.get_environment("RACER_ROOM_RULES")
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(rules_path))
	var session := {"code":"ABCD2345","config":config,"room_ui":use_ui}
	is_host = true
	guest.run_local_guest.call_deferred(session,ids[1])
	var passed: bool = await test_shared_room_ui(session,"local-protocol",ids[0]) if use_ui else await test_room_flow(session,"local-protocol",ids[0])
	deadline = Time.get_ticks_msec()+2000
	while not guest.local_flow_done and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	passed = check(passed and guest.local_flow_done and guest.room_flow_passed and guest.failures==0,"both_local_room_flows_complete")
	if use_ui: room_flow_proof.local_guest = guest.room_flow_proof
	print("LOCAL_ROOM_GUEST checks=",guest.checks," failures=",guest.failures)
	client.close()
	guest.queue_free()
	return passed

func run_local_guest(session: Dictionary, remote_peer: int) -> void:
	room_flow_passed = await test_shared_room_ui(session,"local-protocol",remote_peer) if session.get("room_ui", false) else await test_room_flow(session,"local-protocol",remote_peer)
	local_flow_done = true

func room_packet(kind: String, nonce: String, payload: Dictionary = {}) -> bool:
	var message := payload.duplicate(true)
	message.kind = kind
	message.nonce = nonce
	return test_peer.put_packet(JSON.stringify(message).to_utf8_buffer()) == OK

## 同一正式房间状态脚本在PC与固定Android宿主运行；这里只模拟加载完成，不加载赛车。
func test_room_flow(session: Dictionary, nonce: String, remote_peer: int) -> bool:
	var module_path := "user://online_room_state.gd" if OS.get_name() == "Android" else OS.get_environment("RACER_ROOM_MODULE")
	room_module_hash = FileAccess.get_file_as_string(module_path).sha256_text()
	var module: GDScript = load(module_path)
	if not check(module != null and module.can_instantiate(),"shared_production_room_module_loaded"): return false
	var state: RefCounted = module.new()
	if not check(module.valid_config(session.config),"effective_room_rules_valid"): return false
	if is_host:
		if not check(state.create_room(session.code,session.config) and state.set_guest_present(true),"room_two_members_bound"): return false
		for slot in [0,1]: state.set_ready(slot,true,1,state.config_digest())
		var changed: Dictionary = session.config.duplicate(true)
		changed.speed_kmh = 160.0
		if not check(state.update_config(0,changed) and state.snapshot().ready == [false,false],"rules_change_clears_both_ready"): return false
		state.set_ready(0,true,2,state.config_digest())
	var clock_samples := 0
	var clock_offset := 0.0 # 房主时钟 - 本机时钟，取最小RTT样本。
	var best_rtt := INF
	var ping_pending := false
	var pending_ping_ms := -1
	var ready_sent := false
	var stale_ready_rejected := false
	var loaded_sent := false
	var load_due := -1
	var countdown_seen := false
	var go_sent := false
	var remote_go := false
	var complete_sent := false
	var returned_sent := false
	var last_snapshot := -1000
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		test_peer.poll()
		var now := Time.get_ticks_msec()
		if is_host and now-last_snapshot >= 250:
			last_snapshot = now
			if not room_packet("room_snapshot",nonce,{"snapshot":state.snapshot()}): return false
		while test_peer.get_available_packet_count() > 0:
			var source := test_peer.get_packet_peer()
			var bytes := test_peer.get_packet()
			if not check(bytes.size() <= 8192 and source == remote_peer,"room_packet_bound_to_peer"): return false
			var message: Variant = JSON.parse_string(bytes.get_string_from_utf8())
			if not message is Dictionary or message.get("nonce") != nonce: return false
			var kind: String = str(message.get("kind",""))
			# 旧10包通信的迟到重发仍可到达；它们不参与房间控制状态。
			if kind.is_empty(): continue
			if is_host:
				if kind == "clock_ping":
					if not room_packet("clock_pong",nonce,{"client_ms":message.client_ms,"host_ms":Time.get_ticks_msec()}): return false
				elif kind == "stale_ready":
					stale_ready_rejected = not state.set_ready(1,true,int(message.revision),str(message.digest))
					if not check(stale_ready_rejected,"remote_old_ready_rejected"): return false
				elif kind == "ready":
					if not check(state.set_ready(1,true,int(message.revision),str(message.digest)),"remote_ready_matches_current_rules"): return false
					if not check(stale_ready_rejected and state.request_start(0,2,state.config_digest(),nonce),"host_only_start_after_current_ready"): return false
					state.mark_loaded(0,2,state.config_digest(),nonce)
					if not check(not state.schedule_start(0,Time.get_ticks_msec()+3500,Time.get_ticks_msec()),"slow_remote_loader_blocks_start"): return false
				elif kind == "loaded":
					if not check(state.mark_loaded(1,int(message.revision),str(message.digest),str(message.race_id)),"remote_loaded_same_race_and_rules"): return false
					var host_now := Time.get_ticks_msec()
					if not check(state.schedule_start(0,host_now+3500,host_now),"both_loaded_shared_countdown_scheduled"): return false
				elif kind == "go":
					remote_go = message.get("race_id") == nonce and message.get("digest") == state.config_digest()
					room_flow_proof.remote_go_late_ms = message.get("late_ms")
					if not check(remote_go,"remote_go_same_race_and_rules"): return false
				elif kind == "complete_ack" and complete_sent and not returned_sent:
					if not check(state.return_to_room(0),"host_returns_to_same_room"): return false
					if not room_packet("returned",nonce,{"snapshot":state.snapshot()}): return false
					room_flow_proof.room_code_only_discovery = true
					room_flow_proof.rules_revision = 2
					returned_sent = true
				elif kind == "returned_ack" and returned_sent:
					return true
			else:
				if kind in ["room_snapshot","returned"]:
					var incoming: Variant = message.get("snapshot")
					if not state.snapshot().is_empty() and incoming is Dictionary and incoming.get("version",0) < state.snapshot().version: continue
					# 房主先到GO的快照不能替代本机按共同时间触发GO。
					if incoming is Dictionary and incoming.get("phase")=="RACING" and not go_sent: continue
					if not state.apply_snapshot(incoming): return false
					var view: Dictionary = state.snapshot()
					if not check(view.code == session.code and view.config.speed_kmh == 160.0,"guest_sees_effective_revised_rules"): return false
					if kind == "returned":
						room_flow_proof.clock_rtt_ms = best_rtt
						if not room_packet("returned_ack",nonce): return false
						return check(view.phase=="ROOM" and view.race_id.is_empty() and view.ready==[false,false],"guest_returns_same_room_unready")
					if view.phase == "LOADING" and load_due < 0: load_due = now+700
					if view.phase == "COUNTDOWN" and not countdown_seen:
						countdown_seen = check(clock_samples==3 and float(view.host_go_ms)-clock_offset-now > 0,"guest_arms_future_go_after_clock_sync")
						room_flow_proof.shared_go_ms = view.host_go_ms
				elif kind == "clock_pong" and ping_pending:
					if int(message.client_ms) != pending_ping_ms: return false
					var received_ms := Time.get_ticks_msec()
					var rtt := received_ms-int(message.client_ms)
					if rtt < best_rtt:
						best_rtt = rtt
						clock_offset = float(message.host_ms) - (float(message.client_ms)+received_ms)*0.5
					clock_samples += 1
					ping_pending = false
				elif kind == "complete" and go_sent:
					if not room_packet("complete_ack",nonce): return false
		var view: Dictionary = state.snapshot()
		if not is_host and not view.is_empty():
			if clock_samples < 3 and not ping_pending:
				pending_ping_ms = Time.get_ticks_msec()
				if not room_packet("clock_ping",nonce,{"client_ms":pending_ping_ms}): return false
				ping_pending = true
			if clock_samples == 3 and view.phase == "ROOM" and not ready_sent:
				if not room_packet("stale_ready",nonce,{"revision":1,"digest":view.digest}): return false
				if not room_packet("ready",nonce,{"revision":view.revision,"digest":view.digest}): return false
				ready_sent = true
			if load_due >= 0 and now >= load_due and not loaded_sent:
				if not room_packet("loaded",nonce,{"revision":view.revision,"digest":view.digest,"race_id":view.race_id}): return false
				loaded_sent = true
		var host_now := int(Time.get_ticks_msec() + (0.0 if is_host else clock_offset))
		if not view.is_empty() and view.phase == "COUNTDOWN" and host_now >= int(view.host_go_ms) and not go_sent:
			if not check(state.begin_race(host_now),"local_go_after_shared_deadline"): return false
			go_sent = true
			room_flow_proof.local_go_late_ms = host_now-int(view.host_go_ms)
			if is_host:
				room_flow_proof.shared_go_ms = view.host_go_ms
			else:
				if not room_packet("go",nonce,{"race_id":view.race_id,"digest":view.digest,"late_ms":host_now-int(view.host_go_ms)}): return false
		if is_host and go_sent and remote_go and not complete_sent:
			if not room_packet("complete",nonce): return false
			complete_sent = true
		await get_tree().process_frame
	check(false,"bounded_room_flow_completed")
	return false

## 使用正式房间控件/控制器做跨设备验收；加载回调仍是明确的模拟。
func test_shared_room_ui(session: Dictionary, nonce: String, remote_peer: int) -> bool:
	var android := OS.get_name() == "Android"
	var base := OS.get_environment("RACER_ROOM_UI_ROOT")
	var paths := {
		"online_room_session.gd":"user://online_room_session.gd" if android else base + "/scripts/online_room_session.gd",
		"online_room_view.gd":"user://online_room_view.gd" if android else base + "/scripts/online_room_view.gd",
		"racing_style.gd":"user://racing_style.gd" if android else base + "/scripts/racing_style.gd",
		"room_preview.png":"user://room_preview.png" if android else base + "/assets/ui/tracks/level_2.png",
		"room-ui-info.json":"user://room-ui-info.json" if android else OS.get_environment("RACER_ROOM_UI_INFO")}
	for name in paths: room_ui_hashes[name] = FileAccess.get_sha256(paths[name])
	var module_path := "user://online_room_state.gd" if android else OS.get_environment("RACER_ROOM_MODULE")
	room_module_hash = FileAccess.get_file_as_string(module_path).sha256_text()
	var state_script: GDScript = load(module_path)
	var controller_script: GDScript = load(paths["online_room_session.gd"])
	var view_script: GDScript = load(paths["online_room_view.gd"])
	if not check(state_script != null and controller_script != null and view_script != null \
		and state_script.can_instantiate() and controller_script.can_instantiate() and view_script.can_instantiate(), "shared_room_ui_modules_load"): return false
	var state: RefCounted = state_script.new()
	if is_host and not state.create_room(session.code, session.config): return false
	var controller: Node = controller_script.new()
	add_child(controller)
	var expected: Dictionary = session.config.duplicate(true)
	var rules_check := func(value: Dictionary) -> bool:
		return state_script.valid_config(value) and value.rules_hash == expected.rules_hash \
			and value.level_id == expected.level_id and value.combination == expected.combination and value.race_seed == expected.race_seed
	if not check(controller.attach(test_peer, remote_peer, 0 if is_host else 1, state, nonce, rules_check) == OK, "room_ui_bound_to_authenticated_peer"): return false
	var info: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(paths["room-ui-info.json"]))
	var preview_image := Image.load_from_file(paths["room_preview.png"])
	if not check(not preview_image.is_empty(), "room_ui_preview_loaded"):
		controller.detach()
		controller.queue_free()
		return false
	info.preview = ImageTexture.create_from_image(preview_image)
	var view: Control = view_script.new()
	view.configure(controller, load(paths["racing_style.gd"]), info)
	add_child(view)
	if local_ui_only and is_host: view.hide()
	var errors: Array[String] = []
	controller.action_failed.connect(func(reason: String): errors.append(reason))
	var invalidated := [false]
	controller.room_changed.connect(func(snapshot: Dictionary):
		if snapshot.get("revision") == 2 and snapshot.get("ready") == [false,false]: invalidated[0] = true)
	var initial_ready := false
	var revised_ready := false
	var changed := false
	var start_sent := false
	var loaded := false
	var load_due := -1
	var started := false
	var returned := false
	var passed := false
	var deadline := Time.get_ticks_msec() + 30000
	while controller.connected and errors.is_empty() and Time.get_ticks_msec() < deadline:
		var snapshot: Dictionary = controller.snapshot()
		if snapshot.is_empty():
			await get_tree().process_frame
			continue
		if is_host:
			if not changed:
				if not initial_ready and controller.can_ready():
					view._ready_button.pressed.emit()
					initial_ready = true
				if controller.can_start():
					view._speed_slider.value = 160
					view._apply_button.pressed.emit()
					changed = check(controller.snapshot().ready == [false,false], "room_ui_rule_change_clears_ready")
			elif not revised_ready and controller.can_ready():
				view._ready_button.pressed.emit()
				revised_ready = true
			if changed and revised_ready and not start_sent and controller.can_start():
				view._start_button.pressed.emit()
				start_sent = true
			if snapshot.phase == "LOADING" and not loaded:
				loaded = controller.mark_loaded(snapshot.race_id)
				if not check(loaded and controller.snapshot().phase == "LOADING", "room_ui_slow_guest_blocks_countdown"): break
			if snapshot.phase == "RACING" and controller.remote_started and not returned:
				started = true
				returned = controller.return_to_room()
			if returned and controller.remote_revision == 3:
				passed = check(controller.snapshot().ready == [false,false], "room_ui_return_acknowledged")
				break
		else:
			if not initial_ready and controller.can_ready() and int(snapshot.revision) == 1:
				if not check(not view._start_button.visible and not view._speed.editable and view._apply_button.disabled, "room_ui_guest_permissions"): break
				await capture_room_ui("room-ui-ready.png")
				view._ready_button.pressed.emit()
				initial_ready = true
			if not revised_ready and controller.can_ready() and int(snapshot.revision) == 2:
				if not check(invalidated[0] and snapshot.config.speed_kmh == 160 and view._rules.text.contains("160"), "room_ui_guest_sees_revised_rules_and_unready"): break
				await capture_room_ui("room-ui-revised.png")
				view._ready_button.pressed.emit()
				revised_ready = true
			if snapshot.phase == "LOADING":
				if load_due < 0: load_due = Time.get_ticks_msec() + 700
				if not loaded and Time.get_ticks_msec() >= load_due: loaded = controller.mark_loaded(snapshot.race_id)
			if snapshot.phase == "RACING": started = true
			if snapshot.phase == "ROOM" and int(snapshot.revision) == 3:
				passed = check(started and snapshot.ready == [false,false] and snapshot.race_id.is_empty(), "room_ui_guest_returns_same_room")
				break
		await get_tree().process_frame
	room_flow_proof = {"shared_room_ui":true,"simulated_loading":true,"started":started,
		"rules_invalidated_ready":invalidated[0],"local_slot":controller.local_slot,"clock_rtt_ms":controller.best_rtt_ms}
	check(passed and errors.is_empty(), "bounded_shared_room_ui_complete")
	controller.detach()
	controller.queue_free()
	view.queue_free()
	return passed and errors.is_empty()

func capture_room_ui(filename: String) -> void:
	if OS.get_name() != "Android": return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	check(get_viewport().get_texture().get_image().save_png("user://" + filename) == OK, "room_ui_screenshot_saved")

func cleanup_pending(player_id: String) -> void:
	var pending_path := test_root+"pending-lobby.txt"
	if not FileAccess.file_exists(pending_path): return
	var options := EOS.Lobby.DestroyLobbyOptions.new()
	options.local_user_id=player_id
	options.lobby_id=FileAccess.get_file_as_string(pending_path)
	EOS.Lobby.LobbyInterface.destroy_lobby(options)
	var destroyed: Dictionary = await IEOS.lobby_interface_destroy_lobby_callback
	if check(EOS.is_success(destroyed) or destroyed.result_code==EOS.Result.NotFound,"pending_lobby_cleanup"):
		DirAccess.remove_absolute(pending_path)
