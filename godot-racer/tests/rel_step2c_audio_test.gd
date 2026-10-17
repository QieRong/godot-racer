extends SceneTree
## REL-STEP2C 雨声接线验证（红 -> 绿）。
##
## 用法：
##   godot --headless --path godot-racer --script res://tests/rel_step2c_audio_test.gd ^
##         --log-file ..\godot-logs\rel-step2c-red.log
##
## 只断言**可自动化**的部分：
##   ① 总线结构（SFX / BGM / Ambient 挂在 Master 下，初始 0 dB）
##   ② rain_loop.ogg 导入后 stream.loop == true
##   ③ 雨天挂载 RainAmbient、挂在 Ambient 总线、正在播放；非雨天不挂载
##   ④ 重复进入同一关（同一 car 上重复 apply）+ 新模块实例 -> RainAmbient 节点数恒为 1
##   ⑤ 暂停时 stream_paused == true，恢复后 == false
##   ⑥ 场景释放后节点归零（切关释放）
##
## **不能**自动化的（必须人工听音，见 rel-step2c-audio-report.md）：
##   实际音量是否合适、雨声与引擎声的比例、循环接缝是否有咔哒声。
##
## ⚠ 和 tests/release_settings_test.gd 同一运行方式（extends SceneTree + --script）。
## 本文件放在 tests/ 而不是 scripts/：parse-check.ps1 只聚合 scripts/scenes/tools，
## 验收闸门不会把它当产品代码解析；但它仍受 lint-gdscript.ps1 管辖。

const RAIN_LEVEL := "res://data/levels/level_3.tres"
const CLEAR_LEVEL := "res://data/levels/level_1.tres"
const RAIN_NODE := "RainAmbient"
const BUS_AMBIENT := "Ambient"

var _fails: Array[String] = []
var _car: Node = null
var _mod: RefCounted = null
var _timed_out := false
## ⚠ 必须防重入：实测这台机器上 --script 跑 SceneTree 脚本时 _run() 会**被跑两次**
## （两个协程并发，后一个走到 _prepare_integration 把 _car 置空，前一个还在用 ——
##  症状就是"莫名其妙的 null 调用"和主场景提前启动）。一个闩锁让它只跑一次。
var _started := false


func _initialize() -> void:
	var wd := create_timer(120.0, true)
	wd.timeout.connect(_on_watchdog)
	call_deferred("_run")


func _on_watchdog() -> void:
	if _timed_out:
		return
	_timed_out = true
	print("[REL-STEP2C] WATCHDOG: 120s timeout, abort")
	quit(2)


func _run() -> void:
	if _started:
		print("[REL-STEP2C] _run() 被重复调用，已忽略（见 _started 的说明）")
		return
	_started = true
	_check_bus_layout()
	_check_rain_loop_import()
	_setup_module()
	# ⚠ 下面几个 _check_* 内部都有 await（要等 queue_free / 播放状态落地），
	# 于是它们**整个变成协程**。不 await 就等于"同时启动、各跑各的" ——
	# 实测症状：_prepare_integration 先把 _car 释放并置空，而 _check_rain_mounts
	# 还在用 _car，于是报"Cannot call method on a null value"。
	# 这正是本项目在 main.gd 里踩过两次的坑（协程没 await），这里原样再踩了一次。
	await _check_rain_mounts()
	await _check_reentry_no_stack()
	await _check_pause_api()
	await _check_non_rain_release()
	await _probe_engine_pause_behavior()
	await _prepare_integration()
	await _check_integration()
	_finish()


# ---------------------------------------------------------------- ① 总线

func _check_bus_layout() -> void:
	print("[REL-STEP2C] bus count = %d" % AudioServer.get_bus_count())
	for name in ["SFX", "BGM", "Ambient"]:
		var idx := AudioServer.get_bus_index(name)
		if idx < 0:
			_fail("bus %s is missing (get_bus_index = -1)" % name)
			continue
		var send := AudioServer.get_bus_send(idx)
		var vdb := AudioServer.get_bus_volume_db(idx)
		print("[REL-STEP2C] bus %s idx=%d send=%s volume_db=%.2f" % [name, idx, send, vdb])
		_expect(send == "Master", "bus %s send = %s, expect Master" % [name, send])
		_expect(absf(vdb) < 0.0001, "bus %s volume_db = %.2f, expect 0 dB" % [name, vdb])
	var master_idx := AudioServer.get_bus_index("Master")
	_expect(master_idx == 0, "Master bus index = %d, expect 0" % master_idx)


# ------------------------------------------------- ② 导入流程开启循环

func _check_rain_loop_import() -> void:
	var s := load("res://assets/audio/rain_loop.ogg")
	if s == null:
		_fail("rain_loop.ogg failed to load")
		return
	if not (s is AudioStreamOggVorbis):
		_fail("rain_loop.ogg is not AudioStreamOggVorbis (got %s)" % s.get_class())
		return
	var loop := bool(s.get("loop"))
	print("[REL-STEP2C] rain stream loop = %s, length = %.2f s" % [str(loop), s.get_length()])
	_expect(loop, "rain_loop.ogg import loop = false, expect true (循环没开会在接缝处断掉)")


# ---------------------------------------------------------- 模块级用例

func _setup_module() -> void:
	var sc := load("res://scripts/environment.gd")
	if sc == null:
		_fail("scripts/environment.gd failed to load")
		return
	_mod = sc.new()
	_car = Node.new()
	_car.name = "FakeCar"
	root.add_child(_car)
	for m in ["apply_weather_audio", "set_paused", "release", "weather_audio_state"]:
		if not _mod.has_method(m):
			_fail("environment.gd is missing method: %s" % m)


func _rain_cfg() -> Resource:
	return load(RAIN_LEVEL)


func _clear_cfg() -> Resource:
	return load(CLEAR_LEVEL)


func _count_rain_nodes() -> int:
	return root.find_children(RAIN_NODE, "AudioStreamPlayer", true, false).size()


func _check_rain_mounts() -> void:
	if _mod == null:
		return
	var cfg := _rain_cfg()
	if cfg == null:
		_fail("level_3.tres (rain) failed to load")
		return
	_mod.call("apply_weather_audio", cfg, _car)
	await create_timer(0.2, true).timeout
	var n := _count_rain_nodes()
	_expect(n == 1, "rain level: RainAmbient count = %d, expect 1" % n)
	var p := _car.get_node_or_null(RAIN_NODE) as AudioStreamPlayer
	if p == null:
		_fail("rain level: RainAmbient node not mounted on car")
		return
	print("[REL-STEP2C] mounted: bus=%s playing=%s loop=%s path=%s"
		% [p.bus, str(p.playing), str(bool(p.stream.get("loop"))), p.stream.resource_path])
	_expect(p.bus == BUS_AMBIENT, "rain player bus = %s, expect Ambient" % p.bus)
	_expect(p.playing, "rain player is not playing")
	_expect(bool(p.stream.get("loop")), "rain player stream.loop = false")


## 叠音防护：同一辆车重复 apply、以及换一个模块实例（模拟重建 main）都不能叠加。
func _check_reentry_no_stack() -> void:
	if _mod == null:
		return
	var cfg := _rain_cfg()
	for i in 3:
		_mod.call("apply_weather_audio", cfg, _car)
	await create_timer(0.2, true).timeout
	var n1 := _count_rain_nodes()
	_expect(n1 == 1, "re-apply x3 on same car: RainAmbient count = %d, expect 1" % n1)

	var sc := load("res://scripts/environment.gd")
	var mod2: RefCounted = sc.new()
	for i in 2:
		mod2.call("apply_weather_audio", cfg, _car)
	await create_timer(0.2, true).timeout
	var n2 := _count_rain_nodes()
	_expect(n2 == 1, "fresh module instance x2: RainAmbient count = %d, expect 1" % n2)


## 暂停 API 本身（真正随 SceneTree.paused 翻转的接线在 _check_integration 里验）。
func _check_pause_api() -> void:
	if _mod == null:
		return
	_mod.call("set_paused", true)
	await create_timer(0.2, true).timeout
	var st: Dictionary = _mod.call("weather_audio_state")
	print("[REL-STEP2C] set_paused(true) -> %s" % str(st))
	_expect(bool(st.get("stream_paused", false)), "set_paused(true): stream_paused = false")
	_mod.call("set_paused", false)
	await create_timer(0.2, true).timeout
	st = _mod.call("weather_audio_state")
	_expect(not bool(st.get("stream_paused", true)), "set_paused(false): stream_paused = true")


## 非雨天：必须把上一关留下的雨声释放掉，节点归零。
func _check_non_rain_release() -> void:
	if _mod == null:
		return
	var cfg := _clear_cfg()
	if cfg == null:
		_fail("level_1.tres (clear) failed to load")
		return
	_mod.call("apply_weather_audio", cfg, _car)
	await create_timer(0.3, true).timeout
	var n := _count_rain_nodes()
	_expect(n == 0, "clear level: RainAmbient count = %d, expect 0 (非雨天不该有雨声)" % n)
	var st: Dictionary = _mod.call("weather_audio_state")
	_expect(not bool(st.get("mounted", true)), "clear level: weather_audio_state.mounted = true")


## 诊断（**不做断言**）：`get_tree().paused` 到底会不会**自己**停掉 AudioStreamPlayer？
##
## 为什么必须单独探一次：上面的用例里"树暂停"和"我们设 stream_paused"是**同时发生**的，
## 两者都能让 playing 变 false，分不清是谁的功劳。这里挂一个裸播放器（不挂在任何
## 业务节点下），只暂停树、不动 stream_paused，把引擎的真实行为打印出来。
## 结论只用来写文档 / 决定 set_paused 要不要补 play()，不参与红绿灯。
func _probe_engine_pause_behavior() -> void:
	var probe := AudioStreamPlayer.new()
	probe.name = "PauseProbe"
	probe.stream = load("res://assets/audio/rain_loop.ogg")
	root.add_child(probe)
	probe.play()
	await create_timer(0.5, true).timeout
	var before := probe.playing
	self.paused = true
	await create_timer(0.8, true).timeout
	var during := probe.playing
	self.paused = false
	await create_timer(0.8, true).timeout
	var after := probe.playing
	print("[REL-STEP2C] engine pause probe: playing before=%s during_pause=%s after_resume=%s"
		% [str(before), str(during), str(after)])
	probe.queue_free()
	await create_timer(0.3, true).timeout


# --------------------------------------------------------- 集成（真场景）

func _prepare_integration() -> void:
	if _car != null:
		_car.queue_free()
		_car = null
	await create_timer(0.3, true).timeout


func _main_state(main: Node) -> Dictionary:
	var m = main.get("_weather_audio")
	if m == null:
		return {}
	if not m.has_method("weather_audio_state"):
		return {}
	return m.call("weather_audio_state")


func _check_integration() -> void:
	var gs := root.get_node_or_null("GameState")
	if gs == null:
		_fail("integration: GameState autoload missing")
		return
	gs.set("chosen_level", 2)   # level_3 = 雨夜街道（weather_type = rain）
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		_fail("integration: main.tscn failed to load")
		return
	var main := packed.instantiate()
	root.add_child(main)
	await create_timer(4.0, true).timeout

	var n := _count_rain_nodes()
	print("[REL-STEP2C] integration(rain level): RainAmbient count = %d" % n)
	_expect(n == 1, "integration: RainAmbient count = %d, expect 1" % n)
	var first := root.find_child(RAIN_NODE, true, false) as AudioStreamPlayer
	if first != null:
		_expect(first.bus == BUS_AMBIENT, "integration: bus = %s, expect Ambient" % first.bus)
		_expect(first.playing, "integration: rain player is not playing")
	# 引擎声必须归 SFX（race_car.tscn 里显式写了 bus；不写的话默认走 Master）
	var eng := root.find_child("EngineSound", true, false) as AudioStreamPlayer3D
	if eng == null:
		_fail("integration: EngineSound node not found")
	else:
		print("[REL-STEP2C] integration: EngineSound bus = %s" % eng.bus)
		_expect(eng.bus == "SFX", "integration: EngineSound bus = %s, expect SFX" % eng.bus)

	self.paused = true
	await create_timer(0.6, true).timeout
	var st := _main_state(main)
	print("[REL-STEP2C] integration: tree paused -> %s" % str(st))
	_expect(bool(st.get("stream_paused", false)),
		"integration: after get_tree().paused = true, stream_paused = false (雨声没跟着暂停)")
	self.paused = false
	await create_timer(0.6, true).timeout
	st = _main_state(main)
	print("[REL-STEP2C] integration: tree resumed -> %s" % str(st))
	_expect(not bool(st.get("stream_paused", true)),
		"integration: after resume, stream_paused = true (雨声没恢复)")
	# ⚠ 这条才是"暂停一次雨声会不会永久没了"的判据：树暂停会把 playing 翻成 false，
	# 恢复时必须重新 play()，否则 stream_paused 是 false 但根本没有声音。
	_expect(bool(st.get("playing", false)),
		"integration: after resume, playing = false (雨声暂停后没恢复出声)")

	# 重复进入同一关：重建场景后节点数不能增长
	main.queue_free()
	await create_timer(0.6, true).timeout
	_expect(_count_rain_nodes() == 0, "integration: after scene free, RainAmbient count != 0 (切关没释放)")
	var main2 := packed.instantiate()
	root.add_child(main2)
	await create_timer(4.0, true).timeout
	var n2 := _count_rain_nodes()
	print("[REL-STEP2C] integration(re-enter): RainAmbient count = %d" % n2)
	_expect(n2 == 1, "integration: re-enter level -> RainAmbient count = %d, expect 1 (叠音)" % n2)
	main2.queue_free()
	await create_timer(0.5, true).timeout

	# ---- 晴天关卡：一个雨声节点都不许有（"不要所有关卡都放"）----
	gs.set("chosen_level", 0)   # level_1 = 新兵训练营（weather_type = clear）
	var clear_main := packed.instantiate()
	root.add_child(clear_main)
	await create_timer(4.0, true).timeout
	var n3 := _count_rain_nodes()
	print("[REL-STEP2C] integration(clear level): RainAmbient count = %d" % n3)
	_expect(n3 == 0, "integration: clear level -> RainAmbient count = %d, expect 0 (非雨天也在放雨声)" % n3)
	var cs := _main_state(clear_main)
	_expect(not bool(cs.get("mounted", true)), "integration: clear level -> weather_audio_state.mounted = true")
	clear_main.queue_free()
	await create_timer(0.5, true).timeout


# ---------------------------------------------------------------- 收尾

func _expect(ok: bool, msg: String) -> void:
	if not ok:
		_fail(msg)


func _fail(msg: String) -> void:
	_fails.append(msg)
	print("[REL-STEP2C] FAIL: %s" % msg)


func _finish() -> void:
	if _fails.is_empty():
		print("[REL-STEP2C] ALL PASS")
		quit(0)
		return
	print("[REL-STEP2C] %d FAILURE(S):" % _fails.size())
	for f in _fails:
		print("  - %s" % f)
	quit(1)
