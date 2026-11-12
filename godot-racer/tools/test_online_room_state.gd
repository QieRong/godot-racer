extends SceneTree
## 房间规则/准备/加载屏障定向验证，不连接服务或写玩家存档。
var checks := 0
var failures := 0

func expect(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		print("FAIL " + label)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var script: GDScript = load("res://scripts/online_room_state.gd")
	if script == null or not script.can_instantiate():
		expect(false, "room state module loads")
		_done()
		return
	var room: RefCounted = script.new()
	var config := {"level_id":1,"combination":0,"race_seed":20261106,"speed_kmh":180.0,"laps":2,"collision":true,"rules_hash":"a".repeat(64)}
	var variants: GDScript = load("res://scripts/race_variants.gd")
	var base: Resource = load("res://data/levels/level_2.tres")
	var variant: Dictionary = variants.make(base, int(config.race_seed), int(config.combination))
	expect(variant.get("ok",false), "existing L2 variant rules resolve")
	if variant.get("ok",false): config.rules_hash = variant.summary.signature
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--export-rules="):
			FileAccess.open(arg.trim_prefix("--export-rules="), FileAccess.WRITE).store_string(JSON.stringify(config))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--export-room-ui="):
			var cfg: Resource = variant.config
			var info := {"title":"L2 " + base.display_name, "conditions":"%s · %s · 抓地力 ×%.2f" % [cfg.weather_label(), "夜间" if cfg.is_night else "白天", cfg.friction_multiplier]}
			FileAccess.open(arg.trim_prefix("--export-room-ui="), FileAccess.WRITE).store_string(JSON.stringify(info))
	expect(script.normalize_code(" abcd-2345 ") == "ABCD2345", "paste room code")
	expect(script.normalize_code("ABCD0123").is_empty(), "reject ambiguous code")
	var invite: RefCounted = script.HostInvite.new()
	expect(invite.needs_code(1000) and not invite.claim("ABCD2345", 1000), "an unpublished invitation cannot admit")
	expect(invite.publish("ABCD2345", 1000) and invite.expires_ms == 301000, "published code lasts five host minutes")
	expect(not invite.needs_code(300999) and not invite.publish("BCDE3456", 300999), "current code stays stable before expiry")
	expect(invite.needs_code(301000) and not invite.claim("ABCD2345", 301000), "old code expires at the host deadline")
	expect(not invite.publish("ABCD2345", 301000) and invite.publish("BCDE3456", 301100), "rotation replaces the code after successful publication")
	expect(not invite.claim("ABCD2345", 301101) and invite.claim("BCDE3456", 301101), "host rejects the old code and claims the new one")
	expect(not invite.needs_code(601101) and not invite.claim("BCDE3456", 301102), "claimed room stops rotating and cannot admit a second guest")
	expect(not room.create_room("", config), "reject empty room code")
	expect(room.create_room("ABCD2345", config), "create room")
	expect(not room.request_start(0, 1, room.config_digest(), "race-a"), "one member cannot start")
	expect(room.set_guest_present(true), "guest joins")
	expect(not room.set_ready(1, true, 1, "bad"), "reject mismatched rules")
	for slot in [0, 1]: expect(room.set_ready(slot, true, 1, room.config_digest()), "ready for revision one")
	config.speed_kmh = 160.0
	expect(not room.update_config(1, config), "guest cannot change rules")
	expect(room.update_config(0, config), "host changes rules")
	var snapshot: Dictionary = room.snapshot()
	expect(snapshot.revision == 2 and snapshot.ready == [false, false], "change invalidates both ready states")
	expect(not room.set_ready(1, true, 1, room.config_digest()), "late ready rejected")
	expect(not room.request_start(0, 2, room.config_digest(), "race-a"), "cannot start before new ready")
	for slot in [0, 1]: expect(room.set_ready(slot, true, 2, room.config_digest()), "ready current rules")
	expect(not room.request_start(1, 2, room.config_digest(), "race-a"), "guest cannot start")
	expect(room.request_start(0, 2, room.config_digest(), "race-a"), "host begins loading")
	expect(not room.set_guest_present(true), "no admission while loading")
	expect(not room.mark_loaded(1, 2, room.config_digest(), "old-race"), "reject stale load")
	expect(room.mark_loaded(0, 2, room.config_digest(), "race-a"), "host loaded")
	expect(not room.schedule_start(0, 10000, 7000), "slow guest blocks countdown")
	expect(room.mark_loaded(1, 2, room.config_digest(), "race-a"), "guest loaded")
	expect(not room.schedule_start(1, 10000, 7000), "guest cannot schedule start")
	expect(not room.schedule_start(0, 7100, 7000), "reject insufficient countdown lead")
	expect(room.schedule_start(0, 10000, 7000), "shared host clock deadline")
	expect(not room.begin_race(9999) and room.begin_race(10000), "GO only at deadline")
	expect(room.return_to_room(0), "return to same room")
	snapshot = room.snapshot()
	expect(snapshot.code == "ABCD2345" and snapshot.config.speed_kmh == 160.0 and snapshot.race_id.is_empty() and snapshot.ready == [false,false], "retain rules clear race and ready")
	var guest: RefCounted = script.new()
	expect(guest.apply_snapshot(JSON.parse_string(JSON.stringify(snapshot))), "JSON snapshot roundtrip")
	var bad: Dictionary = snapshot.duplicate(true)
	bad.code = ""
	expect(not guest.apply_snapshot(bad), "reject empty snapshot code")
	bad = snapshot.duplicate(true)
	bad.config.speed_kmh = 999
	expect(not guest.apply_snapshot(bad), "reject external invalid config")
	bad = snapshot.duplicate(true)
	bad.digest = "f".repeat(64)
	expect(not guest.apply_snapshot(bad), "reject digest mismatch")
	bad = snapshot.duplicate(true)
	bad.revision -= 1
	expect(not guest.apply_snapshot(bad), "reject old snapshot")
	_done()

func _done() -> void:
	print("ONLINE_ROOM_STATE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
