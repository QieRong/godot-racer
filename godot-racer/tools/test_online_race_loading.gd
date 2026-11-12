extends Node
## 单端真实L2 + 另一端延迟加载回执；不是两台设备实车比赛或车辆同步验收。
class DelayedRoomSession:
	extends "res://scripts/online_room_session.gd"
	var delay_ms := 0
	var loss_every := 0
	var discarded := 0
	var seen := 0
	var pending: Array[Dictionary] = []

	func _receive(message: Dictionary) -> void:
		if message.get("kind") not in ["drive_input", "vehicle_state"]:
			super._receive(message)
			return
		seen += 1
		if loss_every > 0 and seen % loss_every == 0:
			discarded += 1
			return
		pending.append({"due":Time.get_ticks_msec() + delay_ms,"message":message})

	func _process(delta: float) -> void:
		super._process(delta)
		while connected and not pending.is_empty() and pending[0].due <= Time.get_ticks_msec():
			super._receive(pending.pop_front().message)

var checks := 0
var failures := 0
var host: Node
var guest: Node
var loader: Node
var server: ENetMultiplayerPeer
var client: ENetMultiplayerPeer
var errors: Array[String] = []

func expect(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		print("FAIL " + label)

func _ready() -> void:
	_run.call_deferred()

func _wait(predicate: Callable, timeout_ms := 5000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and errors.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return predicate.call()

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--online-pair="):
			await _run_pair(argument.trim_prefix("--online-pair="))
			return
	var state_script := preload("res://scripts/online_room_state.gd")
	var config := {"level_id":1,"combination":0,"race_seed":20261106,"speed_kmh":160.0,"laps":2,"collision":true,"rules_hash":""}
	var variant: Dictionary = GameState.RaceVariants.make(GameState.get_level(1), config.race_seed, config.combination)
	config.rules_hash = variant.summary.signature
	var original := {"ai":GameState.ai_enabled,"ghost":GameState.ghost_enabled,"records":GameState.record_results_enabled,"level":GameState.chosen_level,"speed":GameState.max_speed_kmh}
	var bad: Dictionary = config.duplicate(true)
	bad.rules_hash = "a".repeat(64)
	expect(not GameState.begin_online_context(bad) and GameState.chosen_level == original.level, "bad local rule signature leaves game state unchanged")
	server = ENetMultiplayerPeer.new()
	server.set_bind_ip("127.0.0.1")
	expect(server.create_server(0, 1) == OK, "loopback scene server")
	client = ENetMultiplayerPeer.new()
	expect(client.create_client("127.0.0.1", server.get_host().get_local_port()) == OK, "loopback scene client")
	var ids := [0, 0]
	server.peer_connected.connect(func(id: int): ids[0] = id)
	client.peer_connected.connect(func(id: int): ids[1] = id)
	var deadline := Time.get_ticks_msec() + 3000
	while (ids[0] == 0 or ids[1] == 0) and Time.get_ticks_msec() < deadline:
		server.poll()
		client.poll()
		await get_tree().process_frame
	expect(ids[0] != 0 and ids[1] != 0, "two scene protocol endpoints connected")
	if failures > 0:
		_done()
		return
	host = preload("res://scripts/online_room_session.gd").new()
	guest = preload("res://scripts/online_room_session.gd").new()
	add_child(host)
	add_child(guest)
	var state := state_script.new()
	expect(state.create_room("L2AB2345", config), "scene room created")
	var rules_check := func(value: Dictionary) -> bool: return state_script.valid_config(value) and value.rules_hash == config.rules_hash
	host.attach(server, ids[0], 0, state, "real-scene-test", rules_check)
	guest.attach(client, ids[1], 1, state_script.new(), "real-scene-test", rules_check)
	loader = preload("res://scripts/online_race_loader.gd").new()
	add_child(loader)
	loader.setup(host, self)
	loader.load_failed.connect(func(reason: String): errors.append(reason))
	var loaded_id := [""]
	loader.loaded.connect(func(id: String): loaded_id[0] = id)
	expect(await _wait(func(): return guest.clock_ready and not guest.snapshot().is_empty()), "guest sync before real load")
	if failures > 0:
		_done()
		return
	host.set_ready(true)
	guest.set_ready(true)
	expect(await _wait(func(): return host.can_start()), "both ready before loading main")
	expect(host.request_start(), "host requests real scene load")
	expect(await _wait(func(): return not loaded_id[0].is_empty(), 45000), "actual L2 world and start grid ready")
	if failures > 0:
		_done()
		return
	var SyncScript := preload("res://scripts/online_race_sync.gd")
	var main: Node3D = loader.race_scene
	var car: VehicleBody3D = main.get_node("RaceCar")
	var sync: Node = main.get_node("OnlineRaceSync")
	var remote: VehicleBody3D = main.get_node("RaceCarRemote")
	expect(main.get_node("Track").is_world_ready(), "actual track generated")
	expect(car.freeze and car.start_locked and GameState.phase_name() == "LOADING", "actual car stays frozen while guest loads")
	expect(host.snapshot().loaded == [true,false] and GameState.race_start_ms == 0, "real loaded receipt does not start clock alone")
	expect(not GameState.ai_enabled and not GameState.ghost_enabled and not GameState.record_results_enabled and GameState.effective_ai_count() == 0, "online context excludes AI ghost and solo records")
	expect(car.max_speed_kmh == 160 and GameState.race_variant_summary().signature == config.rules_hash, "actual car and track use shared room rules")
	expect(not loader.race_scene.begin_online_go("old-race"), "old GO cannot unlock real car")
	expect(guest.mark_loaded(loaded_id[0]), "guest confirms current race")
	expect(await _wait(func(): return host.snapshot().phase == "COUNTDOWN"), "both loaders arm common deadline")
	expect(not get_tree().paused and host.process_mode == Node.PROCESS_MODE_ALWAYS, "network and world keep ticking during shared countdown")
	expect(car.freeze and GameState.race_start_ms == 0, "countdown keeps car locked and clock stopped")
	expect(await _wait(func(): return GameState.phase_name() == "RACING" and host.remote_started, 6000), "real car GO through existing main entry")
	expect(not car.freeze and not car.start_locked, "actual car unlocks at GO")
	expect(GameState.race_start_ms == host.local_go_deadline_ms(), "race and lap clock anchor to shared local deadline")
	expect(sync != null and sync.cars.size() == 2 and car.network_slot == 0 and remote.network_slot == 1 \
		and sync.cars.has(car) and sync.cars.has(remote), "real host scene has two actual network cars")
	expect(not car.network_replicated and not remote.network_replicated and remote.external_input_enabled \
		and sync.opponents == [remote] and remote != car, "host owns physics for local and remote car")
	expect(car.global_position.distance_to(remote.global_position) > 3.0, "two online cars use distinct start slots")
	expect(guest.send_race_packet("drive_input", {"race_id":loaded_id[0],"seq":1,"tick":100,"throttle":1.0,
		"steering":-0.5,"handbrake":false,"drift":false}), "guest submits real drive input packet")
	expect(await _wait(func(): return sync.last_input_sequence() == 1, 300), "host receives current drive input")
	expect(remote.get("_external_input").get("throttle") == 1.0 \
		and remote.get("_external_input").get("steering") == -0.5, "remote car consumes guest InputMap intent")
	expect(guest.send_race_packet("drive_input", {"race_id":loaded_id[0],"seq":1,"tick":101,"throttle":0.0,
		"steering":0.0,"handbrake":true,"drift":true}), "stale drive input sequence submitted")
	await get_tree().create_timer(0.1).timeout
	expect(sync.last_input_sequence() == 1, "host rejects stale drive input sequence")
	expect(guest.send_race_packet("drive_input", {"race_id":"old-race","seq":2,"tick":102,"throttle":1.0,
		"steering":0.0,"handbrake":false,"drift":false}), "old race drive input submitted")
	await get_tree().create_timer(0.1).timeout
	expect(sync.last_input_sequence() == 1, "host rejects old race drive input")
	var snapshots: Array = []
	guest.race_packet_received.connect(func(kind: String, payload: Dictionary):
		if kind == "vehicle_state": snapshots.append(payload))
	expect(await _wait(func(): return not snapshots.is_empty() and sync.last_snapshot_bytes > 0, 1000), "host sends car state snapshots")
	expect(sync.last_snapshot_bytes <= 1000 and snapshots[0].get("race_id") == loaded_id[0], "vehicle snapshot stays within packet budget")
	expect(SyncScript.valid_snapshot(snapshots[0]) and snapshots[0].get("cars", []).size() == 2, "snapshot contains two authoritative car states")
	await get_tree().create_timer(0.35).timeout
	expect(remote.get("_external_input").get("throttle") == 0.0, "expired drive input clears to zero")
	expect(guest.send_race_packet("vehicle_state", {"race_id":loaded_id[0],"seq":999,"tick":1000,"ack":0,
		"cars":[snapshots[0].cars[0],snapshots[0].cars[1]]}), "guest cannot send vehicle state")
	await get_tree().create_timer(0.1).timeout
	expect(sync.latest_snapshot().is_empty(), "host ignores forged vehicle snapshot direction")
	expect(not SyncScript.valid_input({"race_id":loaded_id[0],"seq":3,"tick":103,"throttle":2.0,
		"steering":0.0,"handbrake":false,"drift":false}), "out of range throttle rejected")
	expect(not SyncScript.valid_snapshot({"race_id":loaded_id[0],"seq":3,"tick":103,"ack":0,
		"cars":[snapshots[0].cars[0],{"p":"bad"}]}), "invalid car state rejected")
	await _test_prediction(main, sync, car, remote, loaded_id[0])
	expect(host.return_to_room(), "return to room unloads real race")
	await get_tree().process_frame
	expect(loader.race_scene == null and GameState.phase_name() == "MENU", "scene removed while original room remains owned by session")
	expect(GameState.ai_enabled == original.ai and GameState.ghost_enabled == original.ghost and GameState.record_results_enabled == original.records and GameState.chosen_level == original.level and GameState.max_speed_kmh == original.speed, "restore offline options without saving settings")
	GameState.prepare_race()
	expect(GameState.enter_countdown() and get_tree().paused, "offline countdown retains original paused behavior")
	expect(GameState.start_race() and not get_tree().paused, "offline default GO still starts normally")
	GameState.enter_menu()
	_done()


func _run_pair(role: String) -> void:
	# 两个独立进程各加载真实L2；只走127.0.0.1 ENet，不涉及手机/EOS。
	var is_host := role == "host"
	var peer := ENetMultiplayerPeer.new()
	if is_host:
		server = peer
		peer.set_bind_ip("127.0.0.1")
		expect(peer.create_server(0, 1) == OK, "pair host bound to loopback")
		print("ONLINE_PAIR_PORT=%d" % peer.get_host().get_local_port())
	else:
		client = peer
		var port := 0
		for argument in OS.get_cmdline_user_args():
			if argument.begins_with("--online-port="): port = argument.trim_prefix("--online-port=").to_int()
		expect(peer.create_client("127.0.0.1", port) == OK, "pair guest connects to loopback")
	var ids := [0]
	peer.peer_connected.connect(func(id: int): ids[0] = id)
	var deadline := Time.get_ticks_msec() + 15000
	while ids[0] == 0 and Time.get_ticks_msec() < deadline:
		peer.poll()
		await get_tree().process_frame
	expect(ids[0] != 0, "pair transport connected")
	if failures > 0:
		_done()
		return
	var StateScript := preload("res://scripts/online_room_state.gd")
	var config := {"level_id":1,"combination":0,"race_seed":20261106,"speed_kmh":160.0,"laps":2,"collision":true,"rules_hash":""}
	config.rules_hash = GameState.RaceVariants.make(GameState.get_level(1), config.race_seed, config.combination).summary.signature
	var state := StateScript.new()
	if is_host: expect(state.create_room("L2AB2345", config), "pair room created")
	var room := DelayedRoomSession.new()
	var drive_seconds := 1.5
	var road_case := ""
	var playtest_seconds := 0
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--online-delay-ms="): room.delay_ms = argument.trim_prefix("--online-delay-ms=").to_int()
		if argument.begins_with("--online-loss-every="): room.loss_every = argument.trim_prefix("--online-loss-every=").to_int()
		if argument.begins_with("--online-drive-seconds="): drive_seconds = argument.trim_prefix("--online-drive-seconds=").to_float()
		if argument.begins_with("--online-road-case="): road_case = argument.trim_prefix("--online-road-case=")
		if argument.begins_with("--online-playtest="): playtest_seconds = argument.trim_prefix("--online-playtest=").to_int()
	add_child(room)
	if is_host: host = room
	else: guest = room
	var rules_check := func(value: Dictionary) -> bool: return StateScript.valid_config(value) and value.rules_hash == config.rules_hash
	expect(room.attach(peer, ids[0], 0 if is_host else 1, state, "two-real-scenes", rules_check) == OK, "pair session attached")
	loader = preload("res://scripts/online_race_loader.gd").new()
	add_child(loader)
	loader.setup(room, self)
	loader.load_failed.connect(func(reason: String): errors.append(reason))
	expect(await _wait(func(): return room.can_ready(), 15000), "pair clock and room ready")
	expect(room.set_ready(true), "pair sends ready")
	if is_host:
		expect(await _wait(func(): return room.can_start(), 10000), "pair both ready")
		expect(room.request_start(), "pair starts both real loaders")
	if playtest_seconds == 0:
		for number in ["3", "2", "1"]:
			var shown := await _wait(func(): return _visible_countdown() == number, 60000 if number == "3" else 1800)
			expect(shown and GameState.phase_name() == "COUNTDOWN" and not get_tree().paused \
				and GameState.race_start_ms == 0, "pair shows " + number + " before the shared GO with network running")
	expect(await _wait(func(): return GameState.phase_name() == "RACING", 60000), "pair real world reaches shared GO")
	if playtest_seconds == 0:
		expect(await _wait(func(): return _visible_countdown() == "出发！", 600) \
			and GameState.race_start_ms == room.local_go_deadline_ms(), "pair shows GO after authoritative race clock starts")
	if failures > 0:
		_done()
		return
	var main: Node3D = loader.race_scene
	var car: VehicleBody3D = main.get_node("RaceCar")
	var sync: Node = main.get_node("OnlineRaceSync")
	var other: VehicleBody3D = main.get_node("RaceCarRemote")
	expect(car.network_slot == (0 if is_host else 1) and other.network_slot == (1 if is_host else 0), "pair local car identity and remote identity")
	expect(main.get_node("Track").is_world_ready() and sync.cars.size() == 2, "pair actual L2 and two real cars")
	if is_host:
		expect(not car.network_replicated and not other.network_replicated, "pair host simulates both cars")
	else:
		expect(car.network_predicted and not car.freeze and other.freeze, "pair guest predicts local car and freezes remote replica")
	if playtest_seconds > 0:
		await _run_playtest(room, sync, playtest_seconds, is_host)
		return
	var origin := car.global_position
	var remote_origin := other.global_position
	if road_case.is_empty():
		Input.action_press("accelerate")
		await get_tree().create_timer(drive_seconds).timeout
		Input.action_release("accelerate")
		expect(car.global_position.distance_to(origin) > 0.5, "pair local real car moves under InputMap input")
		expect(other.global_position.distance_to(remote_origin) > 0.5, "pair remote real car moves through network")
	else:
		await _exercise_road(main.get_node("Track"), car, other, sync, road_case, is_host)
	if is_host:
		expect(sync.last_input_sequence() > 30 and sync.last_snapshot_bytes <= 1000, "pair host receives sustained input and bounded snapshots")
		await get_tree().create_timer(0.5).timeout
		expect(room.return_to_room(), "pair host returns both endpoints to original room")
	else:
		expect(not sync.latest_snapshot().is_empty() and sync.latest_snapshot().ack > 0, "pair guest receives actual host snapshots and applied input ack")
		var latest: Dictionary = sync.latest_snapshot()
		var age_ticks := float(Engine.get_physics_frames() - int(latest.tick))
		# 两进程tick起点不同，误差报告只比较当前位置与收到的原始权威位置，不冒充同tick误差。
		var position: Array = latest.cars[1].p
		var separation := car.global_position.distance_to(Vector3(position[0],position[1],position[2]))
		print("ONLINE_PAIR_GUEST raw_snapshot_distance_m=%.3f tick_origin_difference=%.0f" % [separation, age_ticks])
	if room.loss_every > 0: expect(room.discarded > 0, "pair actually injected packet loss")
	print("ONLINE_PAIR_NETWORK role=%s delay_ms=%d received=%d discarded=%d" % [role, room.delay_ms, room.seen, room.discarded])
	expect(await _wait(func(): return room.snapshot().phase == "ROOM" and loader.race_scene == null, 5000), "pair unloads actual world and retains room")
	# 返回后保持连接，等待客端下一次准备；不能在可靠包尚未送达时退出房主进程。
	if not is_host: expect(room.set_ready(true), "pair guest can ready again after return")
	expect(await _wait(func(): return room.snapshot().ready[1], 5000), "pair return is acknowledged through next ready")
	if is_host: await get_tree().create_timer(0.2).timeout
	print("ONLINE_PAIR role=%s checks=%d failures=%d" % [role, checks, failures])
	_done()


func _visible_countdown() -> String:
	if loader.race_scene == null: return ""
	var countdown: CanvasLayer = loader.race_scene.get("_countdown")
	if countdown == null: return ""
	var label: Label = countdown.get("_label")
	return label.text if label.is_visible_in_tree() else ""


func _run_playtest(room: DelayedRoomSession, sync: Node, seconds: int, is_host: bool) -> void:
	var close_requested := [false]
	if is_host:
		Input.action_press("handbrake")
	else:
		get_tree().set_auto_accept_quit(false)
		get_tree().root.close_requested.connect(func(): close_requested[0] = true)
	var ready := await _wait(func():
		if is_host: return sync.last_input_sequence() > 0
		return int(sync.latest_snapshot().get("ack", 0)) > 0, 5000)
	expect(ready, "playtest receives live driving packets")
	if ready:
		print("ONLINE_PLAYTEST_READY role=%s" % ("host" if is_host else "guest"))
		await _wait(func(): return not room.connected or close_requested[0],
			seconds * 1000 + (2000 if is_host else 0))
	if is_host:
		Input.action_release("handbrake")
	if room.connected:
		room.leave_room()
		var peer := server if is_host else client
		peer.get_host().flush()
	_done()


func _exercise_road(track: Node3D, car: VehicleBody3D, other: VehicleBody3D, sync: Node,
		road_case: String, is_host: bool) -> void:
	# 只在开头放车到指定赛段，后续行驶、接触和复位走真实物理与网络输入。
	var turn := road_case == "turn"
	var contact := road_case == "contact"
	var arc := 325.0 if turn else (40.0 if contact else float(track.road_length()) * 0.075)
	var collisions := [0]
	var resets := [0]
	var tested_car: VehicleBody3D = other if is_host else car
	var adjustment := [0.0, 0.0, 0.0]
	if not is_host and not contact:
		tested_car.prediction_corrected.connect(func(p: Vector3, q: Quaternion, v: Vector3, _w: Vector3):
			adjustment[0] += p.y
			adjustment[1] += v.y
			adjustment[2] += Vector2(q.x, q.z).length())
	if contact:
		tested_car.contact_monitor = true
		tested_car.max_contacts_reported = 8
		var contact_target := car if is_host else other
		tested_car.body_entered.connect(func(body: Node):
			if body == contact_target: collisions[0] += 1)
		tested_car.trajectory_discontinuity.connect(func(): resets[0] += 1)
	for vehicle: VehicleBody3D in [car, other]:
		var start_arc := arc + (10.0 if contact and vehicle.network_slot == 0 else 0.0)
		var lane := 0.0 if contact else (-2.5 if vehicle.network_slot == 0 else 2.5)
		var surface: Transform3D = track.surface_frame(start_arc, lane)
		vehicle.global_transform = Transform3D(Basis.looking_at(surface.basis.z, surface.basis.y),
			surface.origin + surface.basis.y * 0.18)
		vehicle.linear_velocity = surface.basis.z * 16.0 if turn else Vector3.ZERO
		vehicle.angular_velocity = Vector3.ZERO
	var forward_at_start: Vector3 = -tested_car.global_basis.z
	var height_at_start := tested_car.global_position.y
	var brake_speed := 0.0
	var drift_frames := 0
	var offroad := 0
	var airborne := 0
	var longest_airborne := 0
	var car_arc := arc
	var frames := 450 if turn else 600
	for frame in range(frames):
		if not is_host or not contact:
			if frame == 0: Input.action_press("accelerate")
			if frame == frames - 120:
				brake_speed = car.linear_velocity.length()
				Input.action_release("accelerate")
				Input.action_press("handbrake")
			if turn:
				var nearest: Dictionary = track.nearest_on_centerline(car.global_position, car_arc)
				car_arc = float(nearest.arc)
				var lane := -2.5 if car.network_slot == 0 else 2.5
				var target: Transform3D = track.surface_frame(car_arc + 12.0, lane)
				var direction := target.origin - car.global_position
				direction.y = 0.0
				var nose := -car.global_basis.z
				nose.y = 0.0
				var strength := clampf(nose.normalized().signed_angle_to(direction.normalized(), Vector3.UP) * 2.4, -1.0, 1.0)
				if frame >= 75 and frame < 105:
					Input.action_press("drift")
					strength = signf(strength) * maxf(0.32, absf(strength))
				else:
					Input.action_release("drift")
				Input.action_release("steer_left")
				Input.action_release("steer_right")
				if absf(strength) > 0.01:
					Input.action_press("steer_left" if strength > 0.0 else "steer_right", absf(strength))
		await get_tree().physics_frame
		if frame > 90:
			airborne = airborne + 1 if tested_car.grounded_wheel_count() == 0 else 0
			longest_airborne = maxi(longest_airborne, airborne)
			if frame % 6 == 0:
				var nearest: Dictionary = track.nearest_on_centerline(tested_car.global_position)
				if float(nearest.dist) > track.road_half_width(): offroad += 1
				if not is_host and not contact:
					var snapshot: Dictionary = sync.latest_snapshot()
					if not snapshot.is_empty() and (airborne > 0 or absf(adjustment[0]) > 0.015 or absf(adjustment[1]) > 0.1):
						print("ONLINE_ROAD_CORRECTION frame=%d ground=%d y=%.3f host_y=%.3f vy=%.3f host_vy=%.3f dy=%.3f dvy=%.3f tilt=%.4f" % [
							frame, tested_car.grounded_wheel_count(), tested_car.global_position.y, snapshot.cars[1].p[1],
							tested_car.linear_velocity.y, snapshot.cars[1].v[1], adjustment[0], adjustment[1], adjustment[2]])
					adjustment.fill(0.0)
		if bool(tested_car.get("_drifting")): drift_frames += 1
	for action in ["accelerate", "handbrake", "steer_left", "steer_right", "drift"]:
		Input.action_release(action)
	var end: Dictionary = track.nearest_on_centerline(tested_car.global_position)
	var heading := rad_to_deg(forward_at_start.angle_to(-tested_car.global_basis.z))
	var rise := tested_car.global_position.y - height_at_start
	print("ONLINE_ROAD case=%s role=%s progress=%.2fm heading=%.1fdeg rise=%.2fm offroad=%d airborne_frames=%d drift_frames=%d local_speed=%.2f->%.2fm/s contacts=%d" % [
		road_case, "host" if is_host else "guest", float(end.arc) - arc, heading, rise, offroad, longest_airborne,
		drift_frames, brake_speed, car.linear_velocity.length(), collisions[0]])
	if not contact:
		expect(float(end.arc) - arc > 25.0 and offroad == 0, "road test completes inside the actual L2 lane envelope")
		expect(longest_airborne <= 18, "no sustained wheel contact loss after placement")
		expect(brake_speed - car.linear_velocity.length() > 4.0, "local handbrake slows car before segment ends")
		if turn: expect(heading > 20.0 and drift_frames > 0, "turn produces steering and actual drift")
		else: expect(rise > 0.8, "car climbs the actual L2 grade")
		return
	expect((collisions[0] > 0) == is_host, "car-to-car contact is solved only on the authority")
	if not is_host:
		var event := InputEventAction.new()
		event.action = &"reset"
		event.pressed = true
		Input.parse_input_event(event)
		await get_tree().create_timer(0.15).timeout
		Input.action_release("reset")
	await get_tree().create_timer(1.2).timeout
	expect(resets[0] == (1 if is_host else 0), "guest R is executed exactly once by the authority")
	if not is_host:
		var snapshot: Dictionary = sync.latest_snapshot()
		var p: Array = snapshot.cars[1].p
		var error := tested_car.global_position.distance_to(Vector3(p[0], p[1], p[2]))
		print("ONLINE_ROAD reset_settled_separation=%.3fm" % error)
		expect(error < 1.0, "guest settles near the authoritative reset pose")


func _test_prediction(main: Node3D, old_sync: Node, car: VehicleBody3D, local: VehicleBody3D, race_id: String) -> void:
	# 同一真实L2改绑为加入端视角；房主快照由测试注入，不冒充双实景验收。
	old_sync.queue_free()
	await get_tree().process_frame
	var sync := preload("res://scripts/online_race_sync.gd").new()
	main.add_child(sync)
	sync.setup_existing(guest, local, car)
	sync.begin()
	expect(local.network_predicted and not local.network_replicated and not local.freeze \
		and car.network_replicated and car.freeze, "guest predicts only its own real car after GO")
	expect(car.collision_layer == 0 and (car.collision_mask & 2) == 0 and (local.collision_mask & 2) == 0, "guest does not solve authoritative car contact twice")
	Input.action_press("accelerate")
	var before := local.global_position
	await get_tree().create_timer(0.3).timeout
	Input.action_release("accelerate")
	expect(sync.get("_input_seq") > 5 and local.global_position.distance_to(before) > 0.1, "real guest car drives before receiving any authoritative snapshot")
	expect(sync.latest_snapshot().is_empty(), "prediction movement did not depend on a host snapshot")
	sync.set_physics_process(false)
	local.set_external_drive_input({"throttle":0.0,"steering":0.0,"handbrake":true,"drift":false})
	var ack: int = sync.get("_input_seq")
	var reference: Dictionary = sync.get("_predictions")[ack].duplicate(true)
	var authoritative: Dictionary = reference.duplicate(true)
	authoritative.p[2] += 1.0
	authoritative.l = 1
	var remote_state: Dictionary = car.capture_network_state()
	remote_state.v = [0.0,0.0,12.0]
	var packet := {"race_id":race_id,"seq":1,"tick":1000,"ack":ack,"cars":[remote_state,authoritative]}
	expect(host.send_race_packet("vehicle_state", packet), "host submits prediction correction over ENet")
	expect(await _wait(func(): return not sync.latest_snapshot().is_empty(), 500), "guest receives authoritative correction")
	expect(local.laps_done == 1, "guest lap progress comes from host")
	await get_tree().physics_frame
	var pending: Dictionary = local.get("_network_correction")
	expect(not pending.is_empty() and pending.p.length() > 0.01 and pending.p.length() < 1.0, "small prediction error is corrected gradually by real physics integration")
	await get_tree().create_timer(0.5).timeout
	pending = local.get("_network_correction")
	expect(pending.is_empty() or pending.p.length() < 0.05, "small prediction correction converges")
	var rebased: Dictionary = sync.get("_predictions")[ack]
	expect(float(rebased.p[2]) > float(reference.p[2]) + 0.9, "applied correction rebases unacknowledged history")
	var next: Dictionary = packet.duplicate(true)
	next.seq = 2
	next.tick = 1006
	next.cars[0].p[2] += 0.6
	sync._on_race_packet("vehicle_state", next)
	for i in range(15): sync._render_remote(1.0 / 120.0)
	var displayed := car.global_position.z
	expect(displayed > float(packet.cars[0].p[2]) and displayed < float(next.cars[0].p[2]), "remote real car interpolates between two host ticks")
	sync._render_remote(10.0)
	expect(absf(car.global_position.z - float(next.cars[0].p[2])) < 0.001, "missing remote snapshots stop at latest authority without unlimited extrapolation")
	var stale: Dictionary = next.duplicate(true)
	stale.seq = 3
	stale.tick = 1005
	sync._on_race_packet("vehicle_state", stale)
	expect(sync.latest_snapshot().seq == 2, "new sequence cannot rewind host simulation tick")
	stale.tick = 1012
	stale.ack = ack + 100
	sync._on_race_packet("vehicle_state", stale)
	expect(sync.latest_snapshot().seq == 2, "ack for unsent input is rejected")
	stale.ack = maxi(0, ack - 1)
	sync._on_race_packet("vehicle_state", stale)
	expect(sync.latest_snapshot().seq == 2, "regressing input ack is rejected")
	stale = next.duplicate(true)
	stale.seq = 3
	stale.tick = 1012
	stale.cars[0].q = [0.0,0.0,0.0,0.0]
	sync._on_race_packet("vehicle_state", stale)
	expect(sync.latest_snapshot().seq == 2, "zero quaternion is rejected before normalization")
	stale = next.duplicate(true)
	stale.seq = 3
	stale.tick = 1012
	stale.cars[0].p[2] += 30.0
	stale.cars[1] = sync.get("_predictions")[ack].duplicate(true)
	stale.cars[1].p[2] += 20.0
	sync._on_race_packet("vehicle_state", stale)
	expect(sync.get("_remote_states").size() == 1 and absf(car.global_position.z - float(stale.cars[0].p[2])) < 0.001, "remote reset clears interpolation rather than sweeping across track")
	await get_tree().physics_frame
	await get_tree().physics_frame
	expect(local.get("_network_correction").is_empty(), "large prediction discrepancy realigns in one physics integration")
	var laps: int = local.laps_done
	await get_tree().physics_frame
	expect(local.laps_done == laps, "prediction physics does not award local laps")
	for i in range(130): sync._send_input()
	expect(sync.get("_predictions").size() <= sync.MAX_PREDICTIONS, "prediction history stays bounded if acknowledgements stop")
	sync.queue_free()
	await get_tree().process_frame

func _done() -> void:
	if loader != null: loader.unload()
	if host != null: host.detach()
	if guest != null: guest.detach()
	if client != null: client.close()
	if server != null: server.close()
	if loader != null: loader.queue_free()
	if host != null: host.queue_free()
	if guest != null: guest.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	for reason in errors: print("LOAD_ERROR " + reason)
	expect(errors.is_empty(), "no real scene loading errors")
	print("ONLINE_REAL_LOAD checks=%d failures=%d" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)
