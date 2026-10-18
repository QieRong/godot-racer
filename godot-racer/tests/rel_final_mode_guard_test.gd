extends SceneTree
## REL-QA-GATE · B7：--check / --shot 模式守卫（真实起进程验证）
##
## 为什么这一份必须**单独起进程**带上 --check= / --shot：
##   main.gd 的接线决策读的是 OS.get_cmdline_user_args()（`_parse_check_args` 与
##   `_screenshot_mode.parse_args`），而 GameState.request_exit() 的"绕过退出确认"分支
##   同样只看命令行。不真把这些参数喂进去，就只能靠读代码下结论 ——
##   而"验收和真实游玩走了两条不同的代码路径"正是本项目踩过的最贵的一个坑
##   （见 main.gd 里 arm_opponents 的注释）。所以这里必须真起进程。
##
## 用法（注意参数要放在 `--` 之后才进 get_cmdline_user_args）：
##   godot --path godot-racer --headless --log-file ..\godot-logs\rel-final-finish-b7-check.log ^
##         --script res://tests/rel_final_mode_guard_test.gd -- --check=rel-qa-b7 --rfmode=check
##   godot --path godot-racer --headless --log-file ..\godot-logs\rel-final-finish-b7-shot.log ^
##         --script res://tests/rel_final_mode_guard_test.gd -- ^
##         --shot --shot-frames=999999 --rfmode=shot
##
## 判据（全部写在日志里，退出码只作辅助）：
##   MODE_ACTIVE_<MODE>=1        证明本进程真的处在 check / shot 模式下（否则下面的断言全是空转）
##   B7_<MODE>_FINISH_UNWIRED=1  race_finished 没有连到 main 的 _on_race_finished
##   B7_<MODE>_SIGNAL_INERT=1    发完成信号也不会进结算（阶段仍是 RACING、无结算面板）
##   B7_<MODE>_EXIT_CALLED=1     已调用 request_exit
##   B7_<MODE>_STILL_ALIVE=1     ← 这一行**出现即为失败**：说明 request_exit 没有直接退出
##   REL_FINAL_MODE_GUARD_PASS / _FAIL

const MAIN_SCENE := "res://scenes/main.tscn"
const FINISH_MENU_SCRIPT := "res://scripts/finish_menu.gd"
const SETUP_FRAMES := 1200

var _mode := ""
var _ok := true
var _msgs: Array[String] = []
var _started := false
var _timed_out := false
var _gs: Node = null


func _phase() -> String:
	return String(_gs.call("phase_name"))


func _initialize() -> void:
	var wd := create_timer(120.0, true)
	wd.timeout.connect(_on_watchdog)
	call_deferred("_run")


func _on_watchdog() -> void:
	if _timed_out:
		return
	_timed_out = true
	print("[B7] WATCHDOG 120s 超时")
	_fail("WATCHDOG 120s 超时")
	_finish()


func _run() -> void:
	if _started:
		return
	_started = true
	# ⚠ 同 rel_final_finish_flow_test.gd：--script 下 GameState 不是编译期标识符，
	# 只能运行时从 root 上取 autoload 节点。
	_gs = root.get_node_or_null("GameState")
	if _gs == null:
		_fail("GameState autoload 节点缺失")
		_finish()
		return
	var args := OS.get_cmdline_user_args()
	var has_check := false
	var has_shot := false
	for a in args:
		if a.begins_with("--check="):
			has_check = true
		if a.begins_with("--shot"):
			has_shot = true
		if a.begins_with("--rfmode="):
			_mode = a.split("=", true, 1)[1]
	if _mode.is_empty():
		_mode = "check" if has_check else ("shot" if has_shot else "unknown")
	print("[B7] args=%s" % str(args))
	print("[B7] mode=%s" % _mode)

	# ---------- ① 模式是否真的生效（防空转的前置断言）----------
	var active := false
	if _mode == "check":
		active = has_check
	elif _mode == "shot":
		active = has_shot
	_expect(active, "命令行缺少 --check= / --shot，本轮断言会全部空转", "MODE_ACTIVE")
	print("MODE_ACTIVE_%s=%d" % [_mode.to_upper(), 1 if active else 0])
	if not active:
		_finish()
		return

	# ---------- ② 起主场景，看 race_finished 有没有被接上 ----------
	var packed: PackedScene = load(MAIN_SCENE)
	if packed == null:
		_fail("无法加载 " + MAIN_SCENE)
		_finish()
		return
	var m := packed.instantiate()
	root.add_child(m)
	current_scene = m
	var ready := false
	for i in range(SETUP_FRAMES):
		await process_frame
		if is_instance_valid(m) and bool(m.get("_setup_done")):
			ready = true
			break
	_expect(ready, "main 场景装配超时", "SCENE_READY")
	if not ready:
		_finish()
		return

	# 模式在场景侧也真的生效了（不是只有命令行上有参数）
	if _mode == "check":
		var ck := String(m.get("_check"))
		_expect(not ck.is_empty(), "main._check 为空 —— 说明没进验收模式", "CHECK_VAR")
		print("[B7] main._check=%s" % ck)
	else:
		var sm = m.get("_screenshot_mode")
		var on := false
		if sm != null and is_instance_valid(sm):
			on = bool(sm.get("mode"))
		_expect(on, "_screenshot_mode.mode 为 false —— 说明没进截图模式", "SHOT_VAR")
		print("[B7] _screenshot_mode.mode=%s" % str(on))

	var car := m.get_node_or_null("RaceCar")
	if car == null:
		_fail("找不到 RaceCar")
		_finish()
		return

	# ---------- ③ race_finished 必须没连到 _on_race_finished ----------
	var wired := false
	for c in car.race_finished.get_connections():
		var cb: Callable = c.get("callable", Callable())
		if cb.get_object() == m and cb.get_method() == "_on_race_finished":
			wired = true
	_expect(not wired, "race_finished 被连到了 _on_race_finished（自动模式不该接交互结算）",
		"FINISH_UNWIRED")
	print("B7_%s_FINISH_UNWIRED=%d" % [_mode.to_upper(), 0 if wired else 1])

	# ---------- ④ 发完成信号也不许进结算 ----------
	car.set("lap_last", 40.0)
	car.set("lap_best", 39.0)
	car.set("laps_done", int(car.get("laps_target")))
	car.emit_signal("race_finished", int(car.get("laps_target")))
	await process_frame
	var phase := _phase()
	var overlays := _count_finish_menus()
	_expect(phase == "RACING", "发完成信号后阶段变成了 %s（自动模式不该进结算）" % phase, "SIGNAL_INERT")
	_expect(overlays == 0, "出现了 %d 个结算面板（自动模式不该弹结算）" % overlays, "NO_OVERLAY")
	print("[B7] after signal: phase=%s overlays=%d" % [phase, overlays])
	print("B7_%s_SIGNAL_INERT=%d" % [_mode.to_upper(), 1 if (phase == "RACING" and overlays == 0) else 0])

	# ---------- ⑤ request_exit 必须直接退出（绕过确认框）----------
	_expect(_phase() != "EXIT_CONFIRM", "调用前就已在退出确认态", "PRE_EXIT")
	# request_exit 之后 Godot 会立刻退出，_finish() 大概率跑不到 ——
	# 所以在**退出之前**先把"退出前有没有已经失败"这条结论打出来，方便机器判定。
	print("B7_%s_PRECHECK_FAIL=%d" % [_mode.to_upper(), _msgs.size()])
	# ⚠ 循环变量别叫 m：上面已经有 `var m := packed.instantiate()`，
	# GDScript 会报 "There is already a variable named "m" declared in this scope"（实测 4.4.1）。
	for em in _msgs:
		print("  !! %s" % em)
	print("B7_%s_EXIT_CALLED=1" % _mode.to_upper())
	_gs.call("request_exit")
	# ⚠ 走到下面这一行 = 进程没被 quit()，即"绕过退出确认"没生效。
	# 正常路径下 Godot 会在本帧末退出，这一行**永远不会打印**。
	for i in range(30):
		await process_frame
	print("B7_%s_STILL_ALIVE=1" % _mode.to_upper())
	_fail("request_exit 后进程仍在运行 —— 自动模式没有绕过退出确认（会被交互弹窗卡住）")
	_finish()


func _count_finish_menus() -> int:
	var s := load(FINISH_MENU_SCRIPT)
	var n := 0
	for node in root.find_children("*", "", true, false):
		if is_instance_valid(node) and node.get_script() == s:
			n += 1
	return n


func _expect(ok: bool, msg: String, tag: String) -> void:
	# ⚠ msg 是"失败时该说什么"，**通过时不要把它打出来**。
	# 第一版写成了 `print("%s %s %s" % [status, tag, msg])`，结果日志里出现
	# `PASS MODE_ACTIVE 命令行缺少 --check= / --shot，本轮断言会全部空转` ——
	# 一眼看是"通过了但理由写着失败原因"，这种日志比没有日志更危险（会被误读成红灯）。
	# 现在：通过只打 tag，失败才带上原因。
	if ok:
		print("[B7] PASS  %s" % tag)
		return
	print("[B7] FAIL  %s  %s" % [tag, msg])
	_fail(msg)


func _fail(msg: String) -> void:
	_ok = false
	_msgs.append(msg)


func _finish() -> void:
	_timed_out = false
	if _ok:
		print("REL_FINAL_MODE_GUARD_PASS")
		quit(0)
		return
	print("REL_FINAL_MODE_GUARD_FAIL")
	for m in _msgs:
		print("  !! %s" % m)
	quit(1)
