extends SceneTree
## 只测本地控制接口，不加载赛道、不安装WebRTC、不访问玩家存档。
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
	if not FileAccess.file_exists("res://scripts/online_room_client.gd"):
		expect(false, "Godot房间客户端已实现")
		_done()
		return
	var script: GDScript = load("res://scripts/online_room_client.gd")
	var host: Node = script.new()
	var guest: Node = script.new()
	root.add_child(host)
	root.add_child(guest)
	var base := OS.get_cmdline_user_args()[0]
	expect(host.configure("http://example.com", true) != OK, "拒绝公网明文HTTP")
	expect(host.configure(base) != OK, "本地HTTP也必须显式启用")
	expect(host.configure(base, true) == OK and guest.configure(base, true) == OK, "显式本地测试配置")
	var config := {"level_id": 1, "combination": 2, "race_seed": 123, "speed_kmh": 180, "laps": 2, "collision": true, "rules_hash": "a".repeat(64)}
	var created: Dictionary = await host.create_room("房主", config, "Windows")
	expect(created.get("ok", false), "实际HTTP建房")
	if not created.get("ok", false):
		print("建房失败代号：", created.get("error", "UNKNOWN"))
		host.queue_free()
		guest.queue_free()
		_done()
		return
	var room: Dictionary = host.get_room_snapshot()
	var code: String = room.code
	var queried: Dictionary = await guest.query_room(code.to_lower())
	expect(queried.get("ok", false) and queried.room.members.size() == 1, "查询不占席")
	expect(guest.get_room_snapshot().is_empty(), "预览不是成员身份")
	var joined: Dictionary = await guest.join_room(code, "朋友", "Android")
	expect(joined.get("ok", false) and guest.local_slot == 1, "安卓加入并保留自己的席位")
	expect(not JSON.stringify(guest.get_room_snapshot()).contains("token"), "公开快照不含凭据")
	var denied: Dictionary = await guest.request_command("config", {"config": config})
	expect(denied.get("error") == "HOST_ONLY", "房主权限由服务判定")
	await host.set_ready(true, 1)
	await guest.set_ready(true, 1)
	config.level_id = 2
	await host.update_room_config(config)
	var polled: Dictionary = await guest.poll_room()
	expect(polled.get("ok", false), "实际轮询事件")
	room = guest.get_room_snapshot()
	expect(int(room.revision) == 2 and int(room.config.level_id) == 2, "P2得到改关和新版本")
	expect(room.members.all(func(m: Dictionary) -> bool: return not m.ready), "改关清双方准备")
	var stale: Dictionary = await guest.set_ready(true, 1)
	expect(stale.get("error") == "STALE_REVISION", "旧版准备拒绝")
	room.config.level_id = 4
	expect(int(guest.get_room_snapshot().config.level_id) == 2, "快照副本不可改内部状态")
	expect((await guest.leave_room()).get("ok", false), "加入者退出")
	await host.poll_room()
	expect(host.get_room_snapshot().members.size() == 1, "退出清理服务席位")
	expect((await host.leave_room()).get("ok", false), "房主退出关闭房间")
	expect((await guest.query_room(code)).get("error") == "ROOM_NOT_FOUND", "原码失效")
	# 同一帧发起和取消：取消可先到服务端，迟到响应不得复活本地身份。
	var pending: Node = script.new()
	root.add_child(pending)
	pending.configure(base, true)
	pending.create_room("取消测试", config, "Windows")
	var cancelled: Dictionary = await pending.leave_room()
	expect(cancelled.get("ok", false), "在途建房取消得到服务确认")
	await create_timer(0.2).timeout
	expect(pending.get_room_snapshot().is_empty() and pending.local_slot == -1, "取消后迟到响应不复活身份")
	pending.queue_free()
	var uncertain: Node = script.new()
	root.add_child(uncertain)
	uncertain.configure(OS.get_cmdline_user_args()[1], true)
	var lost: Dictionary = await uncertain.create_room("响应丢失", config, "Windows")
	expect(not lost.get("ok", false) and uncertain.has_pending_cleanup(), "已占席后500保留取消凭据")
	expect((await uncertain.leave_room()).get("ok", false), "500后仍可取消服务席位")
	uncertain.queue_free()
	var reentrant: Node = script.new()
	root.add_child(reentrant)
	reentrant.configure(base, true)
	await reentrant.create_room("信号退出", config, "Windows")
	var old_events := [0]
	reentrant.room_events.connect(func(_events: Array, _resync: bool) -> void: old_events[0] += 1)
	reentrant.room_changed.connect(func(snapshot: Dictionary) -> void:
		if not snapshot.is_empty(): reentrant.leave_room())
	var interrupted: Dictionary = await reentrant.poll_room()
	expect(interrupted.get("error") == "CANCELLED" and old_events[0] == 0, "信号回调退出后不派发旧轮询事件")
	await create_timer(0.2).timeout
	expect(reentrant.get_room_snapshot().is_empty(), "信号回调退出完成清理")
	reentrant.queue_free()
	var join_callback: Node = script.new()
	root.add_child(join_callback)
	join_callback.configure(base, true)
	join_callback.room_changed.connect(func(snapshot: Dictionary) -> void:
		if not snapshot.is_empty(): join_callback.leave_room())
	var callback_result: Dictionary = await join_callback.create_room("入房即退", config, "Windows")
	expect(callback_result.get("error") == "CANCELLED", "建房信号内退出不能向调用者假报入房成功")
	await create_timer(0.2).timeout
	join_callback.queue_free()
	host.queue_free()
	guest.queue_free()
	_done()

func _done() -> void:
	print("ROOM_CLIENT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
