extends SceneTree
## REL-QA-GATE · C 组：天气环境音（雨声）专项验收
##
## 只断言**机器能证明**的部分。听感（音量配比 / 循环接缝咔哒声 / 叠加听感 /
## 暂停恢复听感 / 雨转晴残留 / 导出包内听感）**一律不做断言**，见报告的人工听音清单。
##
## 用法：
##   pwsh -File 04-Godot启动器\run-rel-final-test.ps1 ^
##        -Script res://tests/rel_final_audio_test.gd -LogName rel-final-audio-green
##
## 覆盖：
##   C1 总线结构：SFX / BGM / Ambient 挂在 Master 下，初始 0 dB
##   C2 rain_loop.ogg 导入后 loop == true，且长度约 204.55 s
##   C3 雨天挂载 RainAmbient → 挂在 Ambient 总线 → 正在播；非雨天释放
##   C4 暂停同步暂停（stream_paused == true）、恢复续播（playing 且位置不回到 0）
##   C5 重复进入不叠音：全树递归计数恒为 1，**每帧采样取最大值**（见 _count_rain_nodes 注释）
##   C6 真场景集成：雨关 1 个 / 晴关 0 个 / 树暂停跟着停 / 恢复接着播 / 重进不增长
##   C7 引擎声归 SFX（不写总线就退回 Master，那等于雨声之外的另一半接线也断了）
##
## ⚠ 与 tests/rel_step2c_audio_test.gd 有重叠，但**不是重复劳动**：
##   那一份是 STEP2C 接线时的红→绿证据；这一份是最终门控，加了
##   ①素材长度断言 ②恢复续播的位置断言 ③每帧采样的叠音上限断言 ④孤儿/待删节点的计数口径。
##
## ⚠⚠ 同 rel_final_finish_flow_test.gd：--script 下不能用编译期标识符，
##   一律走 root.get_node_or_null(...) + call/get/set。

const RAIN_LEVEL_IDX := 2      # level_3.tres = 雨夜街道（weather_type = rain）
const CLEAR_LEVEL_IDX := 0     # level_1.tres = 新兵训练营（weather_type = clear）
const RAIN_NODE := "RainAmbient"
const BUS_AMBIENT := "Ambient"
const BUS_SFX := "SFX"
const RAIN_STREAM := "res://assets/audio/rain_loop.ogg"
## 素材标称长度（秒）。导入后可能差几十毫秒，给 0.5s 容差。
const RAIN_LENGTH_EXPECT := 204.55
const RAIN_LENGTH_TOL := 0.5

var passed := 0
var failed := 0
var _msgs: Array[String] = []
var _started := false
var _timed_out := false
var _mod: RefCounted = null
var _car: Node = null
var _max_seen := 0


func _initialize() -> void:
	var wd := create_timer(240.0, true)
	wd.timeout.connect(_on_watchdog)
	call_deferred("_run")


func _on_watchdog() -> void:
	if _timed_out:
		return
	_timed_out = true
	print("[C] WATCHDOG 240s 超时")
	_fail("WATCHDOG 240s 超时")
	_finish()


func _run() -> void:
	if _started:
		return
	_started = true
	_c1_bus_layout()
	_c2_loop_and_length()
	if not _setup_module():
		_finish()
		return
	await _c3_rain_mounts()
	await _c5_no_stacking()
	await _c4_pause_resume()
	await _c3b_non_rain_release()
	await _c6_integration()
	_finish()


# ------------------------------------------------------------------ C1 总线

func _c1_bus_layout() -> void:
	print("[C] bus count = %d" % AudioServer.get_bus_count())
	for name in ["SFX", "BGM", "Ambient"]:
		var idx := AudioServer.get_bus_index(name)
		if idx < 0:
			_fail("C1 总线 %s 不存在（get_bus_index = -1）：导出包里会退回 Master" % name)
			continue
		var send := AudioServer.get_bus_send(idx)
		var vdb := AudioServer.get_bus_volume_db(idx)
		print("[C] bus %s idx=%d send=%s volume_db=%.2f" % [name, idx, send, vdb])
		_check(send == "Master", "C1 总线 %s 挂在 Master 下（实际 send=%s）" % [name, send])
		_check(absf(vdb) < 0.0001, "C1 总线 %s 初始 0 dB（实际 %.2f dB）" % [name, vdb])
	_check(AudioServer.get_bus_index("Master") == 0, "C1 Master 是 0 号总线")


# --------------------------------------------------------------- C2 循环/长度

func _c2_loop_and_length() -> void:
	var s := load(RAIN_STREAM)
	if s == null:
		_fail("C2 %s 加载失败" % RAIN_STREAM)
		return
	if not (s is AudioStreamOggVorbis):
		_fail("C2 %s 不是 AudioStreamOggVorbis（实际 %s）" % [RAIN_STREAM, s.get_class()])
		return
	var loop := bool(s.get("loop"))
	var length := float(s.get_length())
	print("[C] rain stream: loop=%s length=%.3f s" % [str(loop), length])
	_check(loop, "C2 rain_loop.ogg 导入后 loop == true（否则 204s 放完就断了）")
	_check(absf(length - RAIN_LENGTH_EXPECT) <= RAIN_LENGTH_TOL,
		"C2 素材长度 %.3f s，应约 %.2f s（±%.2f）" % [length, RAIN_LENGTH_EXPECT, RAIN_LENGTH_TOL])


# ------------------------------------------------------------- 模块级用例

func _setup_module() -> bool:
	var sc := load("res://scripts/environment.gd")
	if sc == null:
		_fail("C3 scripts/environment.gd 加载失败")
		return false
	_mod = sc.new()
	_car = Node.new()
	_car.name = "FakeCar"
	root.add_child(_car)
	for m in ["apply_weather_audio", "set_paused", "release", "weather_audio_state"]:
		if not _mod.has_method(m):
			_fail("C3 environment.gd 缺少方法 %s" % m)
	return true


func _rain_cfg() -> Resource:
	return load("res://data/levels/level_3.tres")


func _clear_cfg() -> Resource:
	return load("res://data/levels/level_1.tres")


## 全树数一遍 RainAmbient。
##
## ⚠ 三个口径都必须到位，少一个都可能漏掉叠音：
##   ① recursive=true（不只查直接子节点）
##   ② owned=false（find_children 默认 owned=true 会漏掉**没有 owner 的节点**，
##      而运行时 add_child 出来的节点恰恰没有 owner —— 这就是"孤儿"的主要来源）
##   ③ 每帧采样取最大值：queue_free 要到帧末才真正摘除，所以"先删旧的再加新的"
##      那一帧树上会**同时有两个**。只在事后数一次会漏掉这个瞬间。
##   （真正被 remove_child 摘出树、且没有父节点的节点，GDScript 没有 API 能枚举 ——
##    这一层只能靠 ③ 在它还挂在树上的那几帧里抓到。）
func _count_rain_nodes() -> int:
	# ⚠ 不能只按名字数：Godot 给重名子节点会自动改名（RainAmbient → @RainAmbient@2），
	#   所以"按名字数恒为 1"**抓不到真正的叠音**（注入缺陷那跑实测：真的叠了两个，
	#   名字计数仍然是 1，红灯没亮 —— 见 rel-final-audio-red 首跑）。
	#   真正的判据是"树上有几个在放雨声素材的播放器"，按 stream 资源路径数。
	var n := 0
	for node in root.find_children("*", "AudioStreamPlayer", true, false):
		if not is_instance_valid(node):
			continue
		var p := node as AudioStreamPlayer
		if p.stream != null and p.stream.resource_path == RAIN_STREAM:
			n += 1
	if n > _max_seen:
		_max_seen = n
	return n


## 名字计数只作**参考指标**打印，不当判据（理由见 _count_rain_nodes）。
func _count_rain_by_name() -> int:
	return root.find_children(RAIN_NODE, "AudioStreamPlayer", true, false).size()


func _c3_rain_mounts() -> void:
	var cfg := _rain_cfg()
	if cfg == null:
		_fail("C3 level_3.tres（雨）加载失败")
		return
	_mod.call("apply_weather_audio", cfg, _car)
	await _frames(12)
	var n := _count_rain_nodes()
	print("[C] rain players: by_stream=%d by_name=%d" % [n, _count_rain_by_name()])
	_check(n == 1, "C3 雨天挂载后雨声播放器计数 = %d（应 1）" % n)
	var p := _car.get_node_or_null(RAIN_NODE) as AudioStreamPlayer
	if p == null:
		_fail("C3 车上没有 RainAmbient 节点")
		return
	print("[C] mounted: bus=%s playing=%s loop=%s" %
		[p.bus, str(p.playing), str(bool(p.stream.get("loop")))])
	_check(p.bus == BUS_AMBIENT, "C3 雨声走 Ambient 总线（实际 %s）" % p.bus)
	_check(p.playing, "C3 雨声正在播放")
	_check(bool(p.stream.get("loop")), "C3 播放器上的 stream.loop == true")


## 叠音防护：同车重复 apply + 换模块实例都不能让计数增长；
## 并且**逐帧采样**的最大值也必须是 1（抓"删旧的+加新的"那一帧的两个）。
func _c5_no_stacking() -> void:
	var cfg := _rain_cfg()
	_max_seen = 0
	for i in 3:
		_mod.call("apply_weather_audio", cfg, _car)
		await _frames(6)
	_check(_count_rain_nodes() == 1,
		"C5 同车重复 apply×3 后雨声播放器计数 = %d（应 1）" % _count_rain_nodes())
	_check(_max_seen == 1,
		"C5 同车重复 apply×3 期间**逐帧采样**最大值 = %d（应 1，>1 说明出现过瞬时叠音）" % _max_seen)

	var sc := load("res://scripts/environment.gd")
	var mod2: RefCounted = sc.new()
	_max_seen = 0
	for i in 2:
		mod2.call("apply_weather_audio", cfg, _car)
		await _frames(6)
	_check(_count_rain_nodes() == 1,
		"C5 换模块实例 apply×2 后雨声播放器计数 = %d（应 1）" % _count_rain_nodes())
	_check(_max_seen == 1,
		"C5 换模块实例期间逐帧采样最大值 = %d（应 1）" % _max_seen)


## 暂停同步暂停 + 恢复续播（位置不回到起点）。
func _c4_pause_resume() -> void:
	var p := _car.get_node_or_null(RAIN_NODE) as AudioStreamPlayer
	if p == null:
		_fail("C4 没有 RainAmbient 可测")
		return
	await _frames(30)
	var pos_before := float(p.get_playback_position())
	_mod.call("set_paused", true)
	await _frames(12)
	var st: Dictionary = _mod.call("weather_audio_state")
	print("[C] set_paused(true) -> %s" % str(st))
	_check(bool(st.get("stream_paused", false)), "C4 暂停后 stream_paused == true（雨声没跟着停）")
	var pos_during := float(p.get_playback_position())
	print("[C] playback position: before=%.3f during_pause=%.3f" % [pos_before, pos_during])
	_mod.call("set_paused", false)
	await _frames(30)
	st = _mod.call("weather_audio_state")
	print("[C] set_paused(false) -> %s" % str(st))
	_check(not bool(st.get("stream_paused", true)), "C4 恢复后 stream_paused == false（雨声没恢复）")
	_check(bool(st.get("playing", false)),
		"C4 恢复后 playing == true（stream_paused 解了但根本没出声）")
	var pos_after := float(p.get_playback_position())
	print("[C] playback position after resume = %.3f" % pos_after)
	# 续播：不能回到起点（204s 的素材，暂停一次就从头开始是玩家能直接听出来的）
	_check(pos_after >= pos_during - 0.05,
		"C4 恢复后是**续播**不是重头（暂停时 %.3f → 恢复后 %.3f）" % [pos_during, pos_after])
	_check(pos_after > 0.0, "C4 恢复后播放位置 > 0（%.3f）" % pos_after)


## 非雨天必须把雨声收掉（雨天切晴天关卡后不许残留）。
func _c3b_non_rain_release() -> void:
	var cfg := _clear_cfg()
	if cfg == null:
		_fail("C3b level_1.tres（晴）加载失败")
		return
	_mod.call("apply_weather_audio", cfg, _car)
	await _frames(20)
	var n := _count_rain_nodes()
	_check(n == 0, "C3b 晴天关卡雨声播放器计数 = %d（应 0，雨天切晴天不能残留）" % n)
	var st: Dictionary = _mod.call("weather_audio_state")
	_check(not bool(st.get("mounted", true)), "C3b 晴天关卡 mounted == false")


# ------------------------------------------------------------------ C6 集成

func _main_state(main: Node) -> Dictionary:
	var m = main.get("_weather_audio")
	if m == null or not m.has_method("weather_audio_state"):
		return {}
	return m.call("weather_audio_state")


func _c6_integration() -> void:
	var gs := root.get_node_or_null("GameState")
	if gs == null:
		_fail("C6 GameState autoload 缺失")
		return
	# 先把模块级那辆假车收掉，免得它树上的节点混进全树计数
	if _car != null:
		_car.queue_free()
		_car = null
	await _frames(20)

	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		_fail("C6 main.tscn 加载失败")
		return

	# ---- 雨关 ----
	gs.set("chosen_level", RAIN_LEVEL_IDX)
	var main := packed.instantiate()
	root.add_child(main)
	await _wait_setup(main)
	_max_seen = 0
	await _frames(30)
	var n := _count_rain_nodes()
	print("[C] integration(rain): RainAmbient=%d max_seen=%d" % [n, _max_seen])
	_check(n == 1, "C6 雨关雨声播放器计数 = %d（应 1）" % n)
	_check(_max_seen == 1, "C6 雨关 30 帧逐帧采样最大值 = %d（应 1）" % _max_seen)
	var first := root.find_child(RAIN_NODE, true, false) as AudioStreamPlayer
	if first == null:
		_fail("C6 雨关找不到 RainAmbient")
	else:
		print("[C] integration(rain): bus=%s playing=%s loop=%s" %
			[first.bus, str(first.playing), str(bool(first.stream.get("loop")))])
		_check(first.bus == BUS_AMBIENT, "C6 雨关雨声走 Ambient（实际 %s）" % first.bus)
		_check(first.playing, "C6 雨关雨声正在播")

	# 引擎声必须归 SFX
	var eng := root.find_child("EngineSound", true, false) as AudioStreamPlayer3D
	if eng == null:
		_fail("C6 找不到 EngineSound 节点")
	else:
		print("[C] integration: EngineSound bus = %s" % eng.bus)
		_check(eng.bus == BUS_SFX, "C6 引擎声走 SFX（实际 %s）" % eng.bus)

	# ---- 树暂停 → 雨声跟着停；恢复 → 接着播 ----
	self.paused = true
	await _frames(20)
	var st := _main_state(main)
	print("[C] integration: tree paused -> %s" % str(st))
	_check(bool(st.get("stream_paused", false)),
		"C6 树暂停后 stream_paused == true（雨声没跟着暂停）")
	self.paused = false
	await _frames(30)
	st = _main_state(main)
	print("[C] integration: tree resumed -> %s" % str(st))
	_check(not bool(st.get("stream_paused", true)),
		"C6 树恢复后 stream_paused == false（实际 %s）" % str(st.get("stream_paused")))
	_check(bool(st.get("playing", false)),
		"C6 树恢复后 playing == true（实际 %s，暂停一次雨声就不能没了）"
			% str(st.get("playing")))

	# ---- 重进同一关：计数不许增长 ----
	main.queue_free()
	await _frames(30)
	_check(_count_rain_nodes() == 0,
		"C6 场景释放后雨声播放器计数 = %d（应 0，切关没释放）" % _count_rain_nodes())
	var main2 := packed.instantiate()
	root.add_child(main2)
	await _wait_setup(main2)
	_max_seen = 0
	await _frames(30)
	var n2 := _count_rain_nodes()
	print("[C] integration(re-enter rain): RainAmbient=%d max_seen=%d" % [n2, _max_seen])
	_check(n2 == 1, "C6 重进雨关雨声播放器计数 = %d（应 1，叠音）" % n2)
	_check(_max_seen == 1, "C6 重进雨关逐帧采样最大值 = %d（应 1）" % _max_seen)
	main2.queue_free()
	await _frames(30)

	# ---- 晴关：一个雨声节点都不许有 ----
	gs.set("chosen_level", CLEAR_LEVEL_IDX)
	var clear_main := packed.instantiate()
	root.add_child(clear_main)
	await _wait_setup(clear_main)
	_max_seen = 0
	await _frames(30)
	var n3 := _count_rain_nodes()
	print("[C] integration(clear): RainAmbient=%d max_seen=%d" % [n3, _max_seen])
	_check(n3 == 0, "C6 晴关雨声播放器计数 = %d（应 0）" % n3)
	_check(not bool(_main_state(clear_main).get("mounted", true)), "C6 晴关 mounted == false")
	clear_main.queue_free()
	await _frames(20)


func _wait_setup(main: Node) -> void:
	for i in range(1200):
		await process_frame
		if is_instance_valid(main) and bool(main.get("_setup_done")):
			return
	_fail("C6 等待 main 场景装配超时")


func _frames(n: int) -> void:
	for i in range(n):
		await process_frame


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("  [C] PASS %s" % label)
	else:
		_fail(label)


func _fail(label: String) -> void:
	failed += 1
	_msgs.append(label)
	printerr("  [C] FAIL %s" % label)


func _finish() -> void:
	_timed_out = false
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	if _msgs.is_empty():
		print("REL_FINAL_AUDIO_PASS")
		quit(0)
		return
	for msg in _msgs:
		print("  !! %s" % msg)
	print("REL_FINAL_AUDIO_FAIL")
	quit(1)
