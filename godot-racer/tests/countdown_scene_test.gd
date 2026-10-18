extends SceneTree
## Phase 01 · 倒计时与同步发车场景测试（TDD：先红后绿）。
##
## 覆盖验收用例（plan/racing-system-design-20261018.md §9）：
##   AC-01 装配期间按住 W：start_locked 为真（输入锁在位，_update_drive 早退）
##   AC-02/03 同步发车：调用与游玩**同一个入口**（倒计时 finished 连的 _on_race_go），
##            同一帧内 玩家解锁 + 全部 AI armed + phase=RACING + 树解冻
##   AC-04 GO 后玩家不按键，AI 自行达到 ≥10 km/h（不再等玩家 4 km/h）
##   AC-05/E6 按住 W 到"出发！"不吞键：GO 后车立即动
##   AC-10 倒计时中 ESC → 退出确认；取消 → 回 COUNTDOWN 且仍暂停
##   AC-11 重开 = 完整新比赛（重新倒计时、快照清空）
##   AC-16 总时间口径：GO 瞬间 race_start_ms 置位，快照带 total
##
## 为什么用 process_frame 而不是 physics_frame 等待：倒计时期间树是暂停的，
## 暂停态下 physics_frame 不保证发射，而 process_frame 保证发射
## （现行绿色检查 --check=pause 的阶段1⑤就是暂停态下 await process_frame）。

const MAIN_SCENE := "res://scenes/main.tscn"
const COUNTDOWN_SCRIPT := "res://scripts/start_countdown.gd"
const SETUP_FRAMES := 1500
const WATCHDOG_SEC := 180.0

var passed := 0
var failed := 0
var _timed_out := false


func _initialize() -> void:
	var wd := create_timer(WATCHDOG_SEC, true)
	wd.timeout.connect(_on_watchdog)
	call_deferred("_run")


func _on_watchdog() -> void:
	if _timed_out:
		return
	_timed_out = true
	print("[倒计时测试] WATCHDOG %.0fs 超时" % WATCHDOG_SEC)
	_check(false, "watchdog %.0fs timeout" % WATCHDOG_SEC)
	_finish()


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("  ✔ " + label)
	else:
		failed += 1
		printerr("  ✘ " + label)


func _phase(gs: Node) -> String:
	return String(gs.call("phase_name"))


## 带默认值的属性读取。为什么不能直接 `obj.get(name, def)`：
## Godot 4.4 的 Object.get() 只收 1 个参数（双参数版只属于 Dictionary），
## 基线代码里还没有 start_locked / race_start_ms 这些字段，读不到要给默认值。
func _getp(obj: Object, name: String, def: Variant) -> Variant:
	var v: Variant = obj.get(name)
	return def if v == null else v


func _count_countdown_uis(scene: Node) -> int:
	var s := load(COUNTDOWN_SCRIPT)
	if s == null:
		return -1
	var n := 0
	for child in scene.get_children():
		if child is CanvasLayer and child.get_script() == s:
			n += 1
	return n


func _wait_setup(scene: Node) -> bool:
	for _i in range(SETUP_FRAMES):
		await process_frame
		if is_instance_valid(scene) and bool(scene.get("_setup_done")):
			return true
	return false


## 等车速达到 min_kmh（km/h）。用 process_frame 等待（暂停态也发射），
## 每帧读一次速度 —— 速度本身只在物理步更新，读多读少不影响结论。
func _wait_car_speed(car: VehicleBody3D, min_kmh: float, max_frames: int) -> float:
	var v := 0.0
	for _i in range(max_frames):
		await process_frame
		v = car.linear_velocity.length() * 3.6
		if v >= min_kmh:
			break
	return v


func _wait_ai_speed(ai: Node, min_kmh: float, max_frames: int) -> float:
	var v := 0.0
	for _i in range(max_frames):
		await process_frame
		v = float(ai.call("speed_kmh"))
		if v >= min_kmh:
			break
	return v


func _press_escape() -> void:
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)


func _run() -> void:
	var state := root.get_node_or_null("GameState")
	if state == null:
		_check(false, "GameState autoload exists")
		_finish()
		return
	# 选一关有对手的（L4 = 索引 3，ai_opponents = 1），验"全部 AI 同时发车"
	state.set("chosen_level", 3)
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		_check(false, "main scene loads")
		_finish()
		return
	var game := packed.instantiate()
	root.add_child(game)
	current_scene = game
	# ⚠ 为什么不在实例化后立刻按住 W：装配期 main._ready() 的 prepare_race()
	# 会 release_drive_input() 清掉残留输入（刻意设计——清掉上一局/菜单里
	# 按着的键），更早按会被它清掉。E6 的真实场景是"倒计时期间按住 W"，
	# 见 ④-B（ESC/取消之后）的那一次 action_press。
	var ready := await _wait_setup(game)
	_check(ready, "race scene finishes setup")
	if not ready:
		Input.action_release("accelerate")
		_finish()
		return

	# ① COUNTDOWN 相位 + 树暂停（基线现状是 RACING 且未暂停 → 红）
	_check(_phase(state) == "COUNTDOWN", "after setup phase is COUNTDOWN (got %s)" % _phase(state))
	_check(paused, "tree is paused during countdown")

	# ② 赛前输入锁（基线无此字段 → 红）
	var car := game.get_node("RaceCar") as VehicleBody3D
	_check(bool(_getp(car, "start_locked", false)), "player input locked before GO")

	# ③ 倒计时 UI 已挂载且只有一个（基线无此模块 → 红）
	var cd_count := _count_countdown_uis(game)
	_check(cd_count == 1, "countdown overlay mounted once (got %d)" % cd_count)

	# ④ 倒计时中 ESC → 退出确认；取消 → 回 COUNTDOWN 且仍暂停
	_press_escape()
	for _i in range(4):
		await process_frame
	_check(_phase(state) == "EXIT_CONFIRM" and paused,
		"ESC during countdown opens exit confirm (got %s, paused=%s)" % [_phase(state), str(paused)])
	state.call("cancel_exit")
	_check(_phase(state) == "COUNTDOWN" and paused,
		"cancel returns to countdown and stays paused (got %s, paused=%s)" % [_phase(state), str(paused)])

	# ④-B E6：倒计时期间按住 W（必须在 cancel_exit 之后按——它也 release_drive_input）。
	# 等几帧让输入状态稳定；GO 时 start_race() 刻意不碰输入，按着的键必须保持按着。
	Input.action_press("accelerate")
	for _i in range(8):
		await process_frame

	# ⑤ 同步发车：调用与游玩同一个入口（倒计时 finished 信号连的就是它）。
	# ⚠ 必须 has_method 守卫：基线代码没有这个方法，直接 call 会抛运行时错误
	# **中断整个协程**（实测：后续断言全部不执行，白等 180s 看门狗）。
	# 先红后绿的正确形态是：跳过调用，让后续断言自然地红。
	if game.has_method("_on_race_go"):
		game.call("_on_race_go")
	_check(not bool(_getp(car, "start_locked", true)), "GO unlocks the player in the same frame")
	var ai_all_armed := true
	var ai_count := 0
	for ai in game.get("_opponents"):
		ai_count += 1
		if not bool(ai.get("armed")):
			ai_all_armed = false
	_check(ai_count > 0, "level has AI opponents (got %d)" % ai_count)
	_check(ai_all_armed, "GO arms every AI in the same frame")
	_check(_phase(state) == "RACING" and not paused,
		"GO switches to RACING and unpauses (got %s, paused=%s)" % [_phase(state), str(paused)])
	_check(float(_getp(state, "race_start_ms", 0.0)) > 0.0, "GO stamps race_start_ms")

	# ⑥ E6：按住 W 到"出发！"不吞键 —— GO 后车必须动起来
	var player_kmh := await _wait_car_speed(car, 5.0, 420)
	_check(player_kmh >= 5.0, "held throttle takes effect right after GO (%.1f km/h)" % player_kmh)
	Input.action_release("accelerate")

	# ⑦ AC-04：玩家完全不按键，AI 自行达到 ≥10 km/h
	var ai0: Node = game.get("_opponents")[0]
	var ai_kmh := await _wait_ai_speed(ai0, 10.0, 900)
	_check(ai_kmh >= 10.0, "AI self-accelerate without player input (%.1f km/h)" % ai_kmh)

	# ⑧ 完赛链路在倒计时之后仍然有效 + 快照带总时间（AC-16）
	car.set("lap_last", 42.5)
	car.set("lap_best", 40.0)
	car.set("laps_done", int(car.get("laps_target")))
	car.emit_signal("race_finished", int(car.get("laps_target")))
	_check(_phase(state) == "FINISHED" and paused, "finish works after countdown (got %s)" % _phase(state))
	var snap: Dictionary = state.get("finish_snapshot")
	_check(int(snap.get("laps", 0)) == int(car.get("laps_target")) and float(snap.get("total", 0.0)) > 0.0,
		"snapshot carries laps and total time (total=%.3f)" % float(snap.get("total", 0.0)))

	# ⑨ AC-11：重开 = 完整新比赛（重新倒计时、快照清空）
	state.call("restart_race")
	var again := false
	for _i in range(SETUP_FRAMES):
		await process_frame
		var cur := current_scene
		if cur != null and is_instance_valid(cur) and cur != game and bool(cur.get("_setup_done")):
			again = true
			break
	_check(again, "restart loads a fresh race scene")
	if again:
		_check(_phase(state) == "COUNTDOWN" and paused,
			"restart re-enters countdown (got %s, paused=%s)" % [_phase(state), str(paused)])
		_check(state.get("finish_snapshot").is_empty(), "restart clears the result snapshot")
	_finish()


func _finish() -> void:
	_timed_out = true
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	print("COUNTDOWN_SCENE_PASS" if failed == 0 else "COUNTDOWN_SCENE_FAIL")
	quit(0 if failed == 0 else 1)
