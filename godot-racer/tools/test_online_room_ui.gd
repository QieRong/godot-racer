extends SceneTree
## 真实本机双端连接驱动房间控件；不加载赛车，不改存档。
var checks := 0
var failures := 0
var server: ENetMultiplayerPeer
var client: ENetMultiplayerPeer
var host: Node
var guest: Node
var host_view: Control
var guest_view: Control
var shot_dir := ""

func expect(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		print("FAIL " + label)

func _initialize() -> void:
	call_deferred("_run")

func _wait(predicate: Callable, timeout_ms := 4000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not predicate.call() and Time.get_ticks_msec() < deadline: await process_frame
	return predicate.call()

func _shot(name: String, view: Control) -> void:
	if shot_dir.is_empty(): return
	host_view.visible = view == host_view
	guest_view.visible = view == guest_view
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(shot_dir.path_join(name + ".png"))

func _layout_samples(source: Control) -> void:
	for dimensions in [Vector2i(640, 360), Vector2i(900, 400), Vector2i(800, 450), Vector2i(1024, 640)]:
		var viewport := SubViewport.new()
		viewport.size = dimensions
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(viewport)
		var view: Control = source.get_script().new()
		view.configure(guest, load("res://scripts/racing_style.gd"), source._info)
		viewport.add_child(view)
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var bounds := Rect2(Vector2.ZERO, Vector2(dimensions))
		expect(bounds.encloses(view._ready_button.get_global_rect()), "ready touch target inside viewport %s" % dimensions)
		expect(view._ready_button.size.y >= 48 and view._speed_plus.size.x >= 48 and view._speed_plus.size.y >= 48, "thumb touch target sizes %s" % dimensions)
		expect(bounds.encloses(view._apply_button.get_global_rect()), "speed actions fully visible %s" % dimensions)
		expect(view.find_children("*", "ScrollContainer", true, false).is_empty(), "landscape room has no scrolling %s" % dimensions)
		viewport.get_texture().get_image().save_png(shot_dir.path_join("layout-%dx%d.png" % [dimensions.x, dimensions.y]))
		viewport.queue_free()
		await process_frame

func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--screenshots="): shot_dir = arg.trim_prefix("--screenshots=")
	if not shot_dir.is_empty(): DirAccess.make_dir_recursive_absolute(shot_dir)
	var session_script: GDScript = load("res://scripts/online_room_session.gd")
	var view_script: GDScript = load("res://scripts/online_room_view.gd")
	var state_script: GDScript = load("res://scripts/online_room_state.gd")
	expect(session_script != null and session_script.can_instantiate() and view_script != null and view_script.can_instantiate(), "new room modules instantiate")
	if failures > 0:
		_done()
		return
	var config := {"level_id":1,"combination":0,"race_seed":20261106,"speed_kmh":180.0,"laps":2,"collision":true,"rules_hash":"a".repeat(64)}
	var variants: GDScript = load("res://scripts/race_variants.gd")
	var base: Resource = load("res://data/levels/level_2.tres")
	var variant: Dictionary = variants.make(base, config.race_seed, config.combination)
	config.rules_hash = variant.summary.signature
	var rules_check := func(value: Dictionary) -> bool:
		return state_script.valid_config(value) and value.rules_hash == config.rules_hash and value.level_id == config.level_id \
			and value.combination == config.combination and value.race_seed == config.race_seed
	server = ENetMultiplayerPeer.new()
	server.set_bind_ip("127.0.0.1")
	expect(server.create_server(0, 1) == OK, "loopback room server")
	client = ENetMultiplayerPeer.new()
	expect(client.create_client("127.0.0.1", server.get_host().get_local_port()) == OK, "loopback room client")
	var ids := [0, 0]
	server.peer_connected.connect(func(id: int): ids[0] = id)
	client.peer_connected.connect(func(id: int): ids[1] = id)
	var deadline := Time.get_ticks_msec() + 3000
	while (ids[0] == 0 or ids[1] == 0) and Time.get_ticks_msec() < deadline:
		server.poll()
		client.poll()
		await process_frame
	expect(ids[0] != 0 and ids[1] != 0, "two authenticated transport bindings")
	if failures > 0:
		_done()
		return
	host = session_script.new()
	guest = session_script.new()
	root.add_child(host)
	root.add_child(guest)
	var state: RefCounted = state_script.new()
	state.create_room("ABCD2345", config)
	expect(host.attach(server, ids[0], 0, state, "local-ui-test", rules_check) == OK, "host controller attached")
	expect(guest.attach(client, ids[1], 1, state_script.new(), "local-ui-test", rules_check) == OK, "guest controller attached")
	var info := {"title":base.display_name,"conditions":"晴天 · 抓地力 ×1.00", "preview":load("res://assets/ui/tracks/level_2.png")}
	var style: GDScript = load("res://scripts/racing_style.gd")
	host_view = view_script.new()
	guest_view = view_script.new()
	host_view.configure(host, style, info)
	guest_view.configure(guest, style, info)
	root.add_child(host_view)
	root.add_child(guest_view)
	expect(await _wait(func(): return guest.clock_ready and not guest.snapshot().is_empty()), "guest receives rules and measures clock")
	if failures > 0:
		_done()
		return
	expect(not guest_view._start_button.visible and not guest_view._speed.editable and guest_view._apply_button.disabled, "guest cannot edit or start")
	expect(host_view._start_button.disabled and host_view._speed.editable, "host cannot start before ready")
	expect(not guest.update_config(config) and not guest.request_start(), "controller enforces guest permissions")
	await _shot("room-guest", guest_view)
	if not shot_dir.is_empty(): await _layout_samples(guest_view)
	host_view._ready_button.pressed.emit()
	guest_view._ready_button.pressed.emit()
	expect(await _wait(func(): return host.can_start()), "both real ready controls enable start")
	host_view._speed_plus.pressed.emit()
	expect(host_view._speed.value == 190 and host.snapshot().config.speed_kmh == 180 and not host_view._apply_button.disabled, "speed stepper changes draft only")
	host_view._speed_minus.pressed.emit()
	expect(host_view._speed.value == 180 and host_view._apply_button.disabled, "unchanged speed cannot clear ready again")
	host_view._speed_slider.value = 160
	host_view._apply_button.pressed.emit()
	expect(await _wait(func(): return guest.snapshot().revision == 2), "host setting arrives at guest")
	expect(host.snapshot().ready == [false,false] and guest.snapshot().ready == [false,false], "rule change clears both ready flags")
	expect(guest.snapshot().config.speed_kmh == 160 and guest_view._rules.text.contains("160"), "view shows effective speed")
	await _shot("room-host-revised", host_view)
	var rejected := [false]
	guest.action_failed.connect(func(reason: String):
		if reason == "STALE_RULES": rejected[0] = true)
	client.set_target_peer(ids[1])
	client.put_packet(JSON.stringify({"kind":"ready","nonce":"local-ui-test","ready":true,"revision":1,"digest":host.snapshot().digest}).to_utf8_buffer())
	expect(await _wait(func(): return rejected[0]), "stale network ready rejected")
	expect(host.snapshot().ready == [false,false], "stale packet cannot restore ready")
	host_view._ready_button.pressed.emit()
	guest_view._ready_button.pressed.emit()
	expect(await _wait(func(): return host.can_start()), "both ready again for current revision")
	var load_ids := ["", ""]
	host.load_requested.connect(func(_cfg: Dictionary, id: String): load_ids[0] = id)
	guest.load_requested.connect(func(_cfg: Dictionary, id: String): load_ids[1] = id)
	var started := [false, false]
	host.race_started.connect(func(_s: Dictionary): started[0] = true)
	guest.race_started.connect(func(_s: Dictionary): started[1] = true)
	host_view._start_button.pressed.emit()
	expect(await _wait(func(): return not load_ids[1].is_empty()), "start control requests loading on both ends")
	expect(load_ids[0] == load_ids[1] and guest_view._ready_button.disabled, "same race id and no ready during loading")
	expect(not host.mark_loaded("stale-load"), "old load cannot confirm current race")
	expect(host.mark_loaded(load_ids[0]) and host.snapshot().phase == "LOADING", "host load alone cannot start countdown")
	await _shot("room-loading", guest_view)
	expect(guest.mark_loaded(load_ids[1]), "guest loader confirms same race")
	expect(await _wait(func(): return guest.snapshot().phase == "COUNTDOWN"), "shared countdown after both loaded")
	client.set_target_peer(ids[1])
	client.put_packet(JSON.stringify({"kind":"started","nonce":"local-ui-test","race_id":load_ids[0]}).to_utf8_buffer())
	expect(await _wait(func(): return host.remote_started, 300), "early same-race GO acknowledgement retained")
	expect(host.snapshot().phase == "COUNTDOWN", "remote acknowledgement cannot trigger local early GO")
	client.put_packet(JSON.stringify({"kind":"started","nonce":"local-ui-test","race_id":"old-race"}).to_utf8_buffer())
	await create_timer(0.08).timeout
	expect(host.remote_started, "old-race GO cannot clear current acknowledgement")
	var early: Dictionary = host.snapshot().duplicate(true)
	early.phase = "RACING"
	early.version += 1
	server.set_target_peer(ids[0])
	server.put_packet(JSON.stringify({"kind":"snapshot","nonce":"local-ui-test","snapshot":early}).to_utf8_buffer())
	await create_timer(0.08).timeout
	expect(guest.snapshot().phase == "COUNTDOWN" and not started[1], "early host snapshot cannot bypass guest GO deadline")
	expect(await _wait(func(): return started == [true,true] and host.remote_started, 6000), "both GO by shared deadline and acknowledgement")
	expect(host.return_to_room(), "host returns to original room")
	expect(await _wait(func(): return guest.snapshot().phase == "ROOM" and host.remote_revision == 3), "guest acknowledges same room return")
	expect(guest.snapshot().code == "ABCD2345" and guest.snapshot().race_id.is_empty() and guest.snapshot().ready == [false,false], "return retains room and clears race ready")
	guest.leave_room()
	expect(await _wait(func(): return not host.connected), "leaving is delivered to remote controller")
	expect(host_view._ready_button.disabled and host_view._start_button.disabled, "disconnect disables controls")
	_done()

func _done() -> void:
	if host != null: host.detach()
	if guest != null: guest.detach()
	if client != null: client.close()
	if server != null: server.close()
	print("ONLINE_ROOM_UI checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
