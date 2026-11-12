extends SceneTree
## 联机生命周期定向回归：不加载赛道，不访问公共服务，不读写玩家存档。
var failures := 0
var checks := 0
var recovery_script: GDScript

func _initialize() -> void:
	call_deferred("_run")

func expect(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL " + label)

func _run() -> void:
	if not FileAccess.file_exists("res://scripts/online_recovery.gd"):
		expect(false, "online recovery module exists")
		_done()
		return
	recovery_script = load("res://scripts/online_recovery.gd")
	for successful_attempt in [1, 2, 3]:
		var r: RefCounted = recovery_script.new()
		expect(r.join_room("TESTROOM", 1), "join room")
		expect(r.begin_race("race-a"), "begin race")
		expect(r.connection_lost(100), "detect connection loss")
		var now := 100
		for attempt in range(1, successful_attempt + 1):
			var action: Dictionary = r.poll(now)
			expect(action.get("action") == "retry" and action.get("attempt") == attempt, "attempt number %d" % attempt)
			var epoch: int = action.get("epoch", -1)
			if attempt == successful_attempt:
				expect(r.transport_ready(epoch, now + 10), "transport connected")
				expect(not r.accepts_race_packet(epoch, "race-a"), "no drive before authoritative resync")
				expect(not r.confirm_resume(epoch, "OTHER", 1, "race-a", now + 20), "wrong room cannot resume")
				expect(not r.confirm_resume(epoch, "TESTROOM", 0, "race-a", now + 20), "wrong slot cannot resume")
				expect(not r.confirm_resume(epoch, "TESTROOM", 1, "old-race", now + 20), "wrong race cannot resume")
				expect(r.confirm_resume(epoch, "TESTROOM", 1, "race-a", now + 20), "resume SAME race after attempt %d" % attempt)
				expect(r.accepts_race_packet(epoch, "race-a"), "drive restored after authoritative resync")
				expect(not r.accepts_race_packet(epoch - 1, "race-a"), "old connection packet rejected")
				expect(not r.accepts_race_packet(epoch, "old-race"), "old race packet rejected")
			else:
				r.fail_attempt(epoch, now + 3000)
				expect(not r.transport_ready(epoch, now + 3100), "late completion cannot revive failed attempt")
				now += 3500
	var failed: RefCounted = recovery_script.new()
	failed.join_room("TESTROOM", 0)
	failed.begin_race("race-b")
	failed.connection_lost(0)
	var previous_epoch := -1
	for attempt in range(3):
		var action: Dictionary = failed.poll(attempt * 3500)
		expect(action.get("attempt") == attempt + 1, "timeout retry %d" % (attempt + 1))
		previous_epoch = action.get("epoch", -1)
		failed.poll(attempt * 3500 + 3000)
	expect(failed.room_id == "TESTROOM" and failed.local_slot == 0, "three failures retain original room identity")
	expect(failed.race_id.is_empty() and not failed.room_connected, "three failures end race and mark room offline")
	expect(not failed.begin_race("fake-race"), "offline room cannot start a race")
	expect(failed.poll(100000).is_empty(), "no fourth attempt or repeated room return")
	expect(not failed.transport_ready(previous_epoch, 100001), "late third completion cannot resume abandoned race")
	var cancelled: RefCounted = recovery_script.new()
	cancelled.join_room("TESTROOM", 1)
	cancelled.begin_race("race-c")
	cancelled.connection_lost(0)
	var pending: Dictionary = cancelled.poll(0)
	cancelled.leave_room()
	expect(cancelled.room_id.is_empty() and cancelled.poll(10000).is_empty(), "manual leave cancels all retries")
	expect(not cancelled.transport_ready(pending.epoch, 1), "leave invalidates in-flight callbacks")
	var expired: RefCounted = recovery_script.new()
	expired.join_room("TESTROOM", 1)
	expired.begin_race("race-d")
	expired.connection_lost(0)
	var expired_attempt: Dictionary = expired.poll(0)
	expect(not expired.transport_ready(expired_attempt.epoch, 3000), "completion at deadline is expired even before next poll")
	var state := root.get_node_or_null("GameState")
	if state != null:
		if state.has_method("supports_local_split_screen"):
			expect(not state.supports_local_split_screen("Android"), "Android phones and tablets reject local split screen")
			expect(state.supports_local_split_screen("Windows"), "Windows retains local split screen")
		else:
			expect(false, "platform mode boundary exists")
	if "--native-probe" in OS.get_cmdline_user_args(): await _native_probe()
	_done()

func _native_probe() -> void:
	if not FileAccess.file_exists("res://scripts/online_session.gd"):
		expect(false, "native session driver exists")
		return
	var status := GDExtensionManager.load_extension("res://addons/webrtc_native/webrtc_native.gdextension")
	expect(status == GDExtensionManager.LOAD_STATUS_OK or status == GDExtensionManager.LOAD_STATUS_ALREADY_LOADED, "load native transport in isolated lab")
	var session: GDScript = load("res://scripts/online_session.gd")
	var host: Node = session.new()
	var client: Node = session.new()
	root.add_child(host)
	root.add_child(client)
	host.signaling_message.connect(client.apply_signaling)
	client.signaling_message.connect(host.apply_signaling)
	host.join_room("TESTROOM", 0)
	client.join_room("TESTROOM", 1)
	expect(client.start_link("link-one", false) == OK and host.start_link("link-one", true) == OK, "start two real WebRTC peers")
	await _wait_transport(host, client, false)
	expect(host.is_connected_to_peer() and client.is_connected_to_peer(), "initial data channels open")
	host.recovery.begin_race("race-live")
	client.recovery.begin_race("race-live")
	var received: Array = []
	client.race_packet_received.connect(func(kind, payload): received.append([kind, payload]))
	expect(host.send_race_packet("input", {"throttle": 1.0}) == OK, "send real input packet")
	var deadline := Time.get_ticks_msec() + 1000
	while received.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	expect(received.size() == 1, "receive real input packet")
	var stale := {"room": "TESTROOM", "link": "link-one", "race": "race-live", "kind": "input", "seq": 999, "payload": {"throttle": 1.0}}
	host.report_connection_lost("probe")
	client.report_connection_lost("probe")
	expect(host.send_race_packet("input", {"throttle": 1.0}) != OK, "cannot drive while reconnecting")
	var attempts: Array = []
	host.reconnect_attempt.connect(func(attempt, _epoch): attempts.append(attempt))
	for expected_attempt in [1, 2, 3]:
		deadline = Time.get_ticks_msec() + 2000
		while (host.recovery.attempts_started < expected_attempt or client.recovery.attempts_started < expected_attempt) and Time.get_ticks_msec() < deadline: await process_frame
		expect(host.recovery.attempts_started == expected_attempt and client.recovery.attempts_started == expected_attempt, "real driver attempts %d" % expected_attempt)
		if expected_attempt < 3:
			host.recovery.fail_attempt(host.recovery.epoch, Time.get_ticks_msec())
			client.recovery.fail_attempt(client.recovery.epoch, Time.get_ticks_msec())
	expect(client.start_link("link-three", false, [], client.recovery.epoch) == OK and host.start_link("link-three", true, [], host.recovery.epoch) == OK, "third retry starts fresh native connections")
	await _wait_transport(host, client, true)
	expect(not host.recovery.room_connected and not client.recovery.room_connected, "connected transport still waits for authoritative resync")
	var authority_snapshots: Array = []
	if not host.has_method("send_resume_snapshot"):
		expect(false, "authoritative resync has a reliable transport path")
		host.free()
		client.free()
		return
	client.authoritative_resume_received.connect(func(epoch, snapshot): authority_snapshots.append([epoch, snapshot]))
	expect(host.send_resume_snapshot({"host_tick": 120, "progress": [1, 0]}) == OK, "host sends reliable authority snapshot during resync")
	expect(client.send_resume_snapshot({}) != OK, "client cannot forge authority snapshot")
	deadline = Time.get_ticks_msec() + 1000
	while authority_snapshots.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	expect(authority_snapshots.size() == 1 and authority_snapshots[0][1].host_tick == 120, "resume state actually crosses native transport")
	# 验证传输与屏障，不将样例数据宣称为实际赛车物理快照。
	expect(host.confirm_resume(host.recovery.epoch, "TESTROOM", 0, "race-live"), "host confirms same race after resync")
	expect(client.confirm_resume(client.recovery.epoch, "TESTROOM", 1, "race-live"), "client confirms same race after resync")
	client._receive_packet(JSON.stringify(stale).to_utf8_buffer())
	expect(received.size() == 1, "stale previous-link packet rejected after reconnect")
	expect(host.send_race_packet("input", {"throttle": 0.0}) == OK, "fresh input after resume")
	deadline = Time.get_ticks_msec() + 1000
	while received.size() < 2 and Time.get_ticks_msec() < deadline: await process_frame
	expect(received.size() == 2 and received[-1][1].throttle == 0.0, "fresh packet arrives without old throttle replay")
	expect(attempts == [1, 2, 3], "exactly three real reconnect requests")
	host.leave_room()
	client.leave_room()
	expect(not host.is_connected_to_peer() and not client.is_connected_to_peer(), "manual leave closes native channels")
	host.free()
	client.free()
	# 同步信号中退出房间，不应让当前帧再访问已清理的通道。
	var leaving_host: Node = session.new()
	var leaving_client: Node = session.new()
	root.add_child(leaving_host)
	root.add_child(leaving_client)
	leaving_host.signaling_message.connect(leaving_client.apply_signaling)
	leaving_client.signaling_message.connect(leaving_host.apply_signaling)
	leaving_host.join_room("EXITROOM", 0)
	leaving_client.join_room("EXITROOM", 1)
	leaving_host.transport_connected.connect(leaving_host.leave_room)
	leaving_client.start_link("exit-link", false)
	leaving_host.start_link("exit-link", true)
	deadline = Time.get_ticks_msec() + 3000
	while not leaving_host.recovery.room_id.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	expect(leaving_host.recovery.room_id.is_empty() and not leaving_host.is_connected_to_peer(), "connected callback can safely leave room")
	leaving_client.leave_room()
	leaving_host.free()
	leaving_client.free()

func _wait_transport(host: Node, client: Node, resync: bool) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		if host.is_connected_to_peer() and client.is_connected_to_peer():
			if not resync or (host.recovery.phase == host.recovery.Phase.RESYNCING and client.recovery.phase == client.recovery.Phase.RESYNCING): return
		await process_frame
	expect(false, "native transport connection deadline")

func _done() -> void:
	print("ONLINE_RECOVERY_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
