extends SceneTree
## REL-QA-GATE · B 组：结算 / 退出状态机专项验收（7 类用例）
##
## 为什么单独这一份：既有测试只覆盖了"契约层"（release_flow_test.gd）与一条 Happy Path
## （release_flow_scene_test.gd）。最终门控要的是 **7 类用例逐类留证据**，尤其是
## "按住驾驶键完成比赛""三个出口各自状态""取消回到进入前的精确状态""重开但设置保留"
## 这四条 —— 它们各自对着一个玩家能直接感知的故障。
##
## 用法：
##   pwsh -File 04-Godot启动器\run-rel-final-test.ps1 -LogName rel-final-finish-green
##
## 覆盖：
##   B1 重复完成信号 → 结算只触发一次（含"圈数不足不许结算"的负对照）
##   B2 完成瞬间仍按住五个驾驶键 → FINISHED 后全部释放
##   B3 三个出口：返回主菜单 / 再玩一局 / 退出游戏，各自状态正确（点真实按钮，不调 API）
##   B4 结算状态下 ESC → 返回选关，而不是恢复比赛
##   B5 退出取消回到进入前的精确状态；结算态取消**不能**恢复比赛
##   B6 重开：清理弹窗与输入、解除暂停、成绩重新初始化，但**设置保留**
##   （B7 check/shot 模式守卫在 rel_final_mode_guard_test.gd —— 那一份必须带 --check=/--shot
##    真实起进程，不能在本进程里假装）
##
## ⚠ 与 tests/rel_step2c_audio_test.gd 同一运行方式（extends SceneTree + --script）。
##   放在 tests/：parse-check.ps1 不聚合 tests/，但 lint-gdscript.ps1 照样管它。
##
## ⚠⚠ 为什么全篇用 `_gs.call(...)` 而不是直接写 `GameState.xxx`：
##   `--script` 跑起来的脚本**本身**就是 MainLoop，它在 autoload 注册**之前**就被编译，
##   此时 `GameState` 这个标识符在编译期不存在 —— 实测报
##   `Compile Error: Identifier not found: GameState`（见 rel-final-finish-green 首跑日志）。
##   但 autoload 节点运行时确实挂在 root 下，所以走 root.get_node_or_null("GameState")
##   再 call/get/set（与 release_settings_test.gd 的既有写法一致）。

const MAIN_SCENE := "res://scenes/main.tscn"
const FINISH_MENU_SCRIPT := "res://scripts/finish_menu.gd"
const EXIT_CONFIRM_SCRIPT := "res://scripts/exit_confirm.gd"

## 主场景装配（赛道 + 对手）就绪的等待上限。实测这台机器 4s 量级，给 1200 帧是保守的。
const SETUP_FRAMES := 1200

var passed := 0
var failed := 0
var _msgs: Array[String] = []
var _started := false
var _timed_out := false
var _gs: Node = null
var _finish_script: Script = null
var _exit_script: Script = null


func _initialize() -> void:
	var wd := create_timer(300.0, true)
	wd.timeout.connect(_on_watchdog)
	call_deferred("_run")


func _on_watchdog() -> void:
	if _timed_out:
		return
	_timed_out = true
	print("[B] WATCHDOG: 300s 超时，判为失败（多半是某个 await 一直没回）")
	_fail("WATCHDOG: 300s 超时")
	_finish()


func _run() -> void:
	# ⚠ 必须防重入：实测这台机器上 --script 跑 SceneTree 脚本时 _run() 会被跑两次。
	if _started:
		print("[B] _run() 重复调用，已忽略")
		return
	_started = true
	_finish_script = load(FINISH_MENU_SCRIPT)
	_exit_script = load(EXIT_CONFIRM_SCRIPT)
	_gs = root.get_node_or_null("GameState")
	if _gs == null:
		_fail("GameState autoload 节点缺失")
		_finish()
		return
	# 别把测试写进玩家自己的 settings.cfg（GameState.settings_path 就是为测试留的口子）
	_gs.set("settings_path", "user://rel-final-qa-settings.cfg")

	await _b1_duplicate_finish()
	await _b2_finish_while_holding_input()
	await _b4_esc_from_finish()
	await _b3_three_exits()
	await _b5_cancel_returns_exact_state()
	await _b6_restart_keeps_settings()
	await _free_scene()
	_finish()


func _phase() -> String:
	return String(_gs.call("phase_name"))


# ============================================================ B1 重复完成信号

func _b1_duplicate_finish() -> void:
	var m := await _new_race(0)
	if m == null:
		return
	var car := m.get_node_or_null("RaceCar")
	if car == null:
		_fail("B1 找不到 RaceCar 节点")
		return
	var target := int(car.get("laps_target"))
	# ---- 负对照：没跑够圈数时不许进结算 ----
	var accepted := bool(_gs.call("finish_race", 0, 1.0, 1.0, target))
	_check(not accepted and _phase() == "RACING",
		"B1-1 负对照：圈数不足时 finish_race 被拒绝，仍为 RACING")
	# ---- 真实完成信号 ----
	car.set("lap_last", 42.5)
	car.set("lap_best", 40.0)
	car.set("laps_done", target)
	car.emit_signal("race_finished", target)
	_check(_phase() == "FINISHED" and paused,
		"B1-2 完成信号 → 阶段 %s 且树已暂停（paused=%s）" % [_phase(), str(paused)])
	var n1 := _count_script_nodes(_finish_script)
	_check(n1 == 1, "B1-3 结算面板恰好 1 个（实际 %d）" % n1)
	# ---- 重复信号 ----
	car.set("lap_last", 999.0)
	car.emit_signal("race_finished", target)
	var n2 := _count_script_nodes(_finish_script)
	_check(n2 == 1, "B1-4 重复完成信号不叠加结算面板（实际 %d）" % n2)
	var again := bool(_gs.call("finish_race", target, 1.0, 1.0, target))
	_check(not again, "B1-5 第二次 finish_race 返回 false")
	var snap: Dictionary = _gs.get("finish_snapshot")
	_check(float(snap.get("last", -1.0)) == 42.5,
		"B1-6 重复信号未改写成绩快照（last=%.2f，应 42.5）" % float(snap.get("last", -1.0)))
	_check(int(snap.get("laps", -1)) == target and int(snap.get("target", -1)) == target,
		"B1-7 快照内容正确（laps/target）")


# ============================================ B2 按住驾驶键完成比赛也要全部释放

func _b2_finish_while_holding_input() -> void:
	var m := await _new_race(0)
	if m == null:
		return
	var car := m.get_node_or_null("RaceCar")
	if car == null:
		_fail("B2 找不到 RaceCar 节点")
		return
	var acts: Array = _gs.get("DRIVE_ACTIONS")
	_check(acts.size() == 5, "B2-0 DRIVE_ACTIONS 恰好 5 个（实际 %d）" % acts.size())
	for a in acts:
		Input.action_press(a)
	var held := 0
	for a in acts:
		if Input.is_action_pressed(a):
			held += 1
	_check(held == acts.size(), "B2-1 前置：%d/%d 个驾驶键已按住" % [held, acts.size()])
	var target := int(car.get("laps_target"))
	car.set("lap_last", 30.0)
	car.set("lap_best", 29.0)
	car.set("laps_done", target)
	car.emit_signal("race_finished", target)
	_check(_phase() == "FINISHED", "B2-2 完成瞬间 → FINISHED（实际 %s）" % _phase())
	var still := []
	for a in acts:
		if Input.is_action_pressed(a):
			still.append(a)
	_check(still.is_empty(), "B2-3 进入 FINISHED 后全部驾驶输入已释放（仍按住：%s）" % str(still))
	# 挂若干帧再复查：有些释放在下一帧被重新写入才算数
	for i in range(6):
		await process_frame
	var later := []
	for a in acts:
		if Input.is_action_pressed(a):
			later.append(a)
	_check(later.is_empty(), "B2-4 6 帧后仍保持释放（仍按住：%s）" % str(later))


# ==================================== B4 结算状态下 ESC 返回选关（不是恢复比赛）

func _b4_esc_from_finish() -> void:
	var m := await _new_race(0)
	if m == null:
		return
	var car := m.get_node_or_null("RaceCar")
	if car == null:
		_fail("B4 找不到 RaceCar 节点")
		return
	var target := int(car.get("laps_target"))
	car.set("lap_last", 33.0)
	car.set("lap_best", 32.0)
	car.set("laps_done", target)
	car.emit_signal("race_finished", target)
	_check(_phase() == "FINISHED" and paused, "B4-1 前置：已进结算且暂停")
	_push_escape()
	for i in range(8):
		await process_frame
	_check(_phase() == "MENU", "B4-2 结算态按 ESC → MENU（实际 %s，绝不能是 RACING）" % _phase())
	_check(not paused, "B4-3 结算态按 ESC → 树已解除暂停")
	_check(current_scene != null and current_scene.name == "Menu",
		"B4-4 已切到菜单场景（实际 %s）" % (str(current_scene.name) if current_scene != null else "null"))
	_check(Dictionary(_gs.get("finish_snapshot")).is_empty(), "B4-5 回菜单后成绩快照已清空")


# ================================= B3 三个出口（点真实按钮，状态各自正确）

func _b3_three_exits() -> void:
	# ---- 出口 1：再玩一局 ----
	var m := await _new_race(1)
	if m == null:
		return
	_finish_now(m)
	_check(_phase() == "FINISHED", "B3-1a 前置：再次到达结算（实际 %s）" % _phase())
	var clicked := _click_finish_button("再玩一局")
	_check(clicked, "B3-1b 结算面板上有「再玩一局」按钮")
	if clicked:
		var fresh := await _await_scene_change()
		_check(fresh != null and bool(fresh.get("_setup_done")),
			"B3-1c 点「再玩一局」→ 新比赛场景就绪")
		if fresh != null:
			var car2 := fresh.get_node_or_null("RaceCar")
			# Phase 01：再玩一局 = 完整新比赛，从倒计时重新开始（策划案 R14/G9）——
			# 判据从"reload 后直接 RACING"改为"重新进入 COUNTDOWN 且树暂停"
			_check(_phase() == "COUNTDOWN", "B3-1d 再玩一局 → 重新倒计时（实际 %s）" % _phase())
			_check(paused, "B3-1e 再玩一局 → 树暂停等待出发")
			if car2 != null:
				_check(int(car2.get("laps_done")) == 0,
					"B3-1f 再玩一局 → 圈数归零（实际 %d）" % int(car2.get("laps_done")))
	var n1 := _count_script_nodes(_finish_script)
	_check(n1 == 0, "B3-1g 再玩一局 → 结算面板已清理（实际 %d）" % n1)

	# ---- 出口 2：退出游戏 ----
	var m2 := await _new_race(1)
	if m2 == null:
		return
	_finish_now(m2)
	var clicked_quit := _click_finish_button("退出游戏")
	_check(clicked_quit, "B3-2a 结算面板上有「退出游戏」按钮")
	if clicked_quit:
		await process_frame
		_check(_phase() == "EXIT_CONFIRM",
			"B3-2b 点「退出游戏」→ EXIT_CONFIRM（实际 %s）" % _phase())
		_check(paused, "B3-2c 退出确认期间树保持暂停")
		var n2 := _count_script_nodes(_exit_script)
		_check(n2 == 1, "B3-2d 退出确认面板恰好 1 个（实际 %d）" % n2)
		_gs.call("cancel_exit")
		for i in range(4):
			await process_frame
		_check(_phase() == "FINISHED", "B3-2e 取消后回到结算态（实际 %s）" % _phase())

	# ---- 出口 3：返回主菜单（ESC）----
	var m3 := await _new_race(1)
	if m3 == null:
		return
	_finish_now(m3)
	var clicked_back := _click_finish_button("返回主菜单（ESC）")
	_check(clicked_back, "B3-3a 结算面板上有「返回主菜单（ESC）」按钮")
	if clicked_back:
		for i in range(8):
			await process_frame
		_check(_phase() == "MENU", "B3-3b 返回主菜单 → MENU（实际 %s）" % _phase())
		_check(not paused, "B3-3c 返回主菜单 → 未暂停")
		_check(current_scene != null and current_scene.name == "Menu", "B3-3d 已切到菜单场景")
		var n3 := _count_script_nodes(_finish_script)
		_check(n3 == 0, "B3-3e 返回主菜单 → 结算面板已清理（实际 %d）" % n3)


# ==================== B5 退出取消回到进入前的精确状态（结算态取消不许恢复比赛）

func _b5_cancel_returns_exact_state() -> void:
	# ---- 从 RACING 取消 ----
	var m := await _new_race(0)
	if m == null:
		return
	_gs.call("request_exit")
	await process_frame
	_check(_phase() == "EXIT_CONFIRM" and paused, "B5-1a RACING → 退出确认（树暂停）")
	var n1 := _count_script_nodes(_exit_script)
	_check(n1 == 1, "B5-1b 退出确认面板 1 个（实际 %d）" % n1)
	_check(_click_exit_button("取消，返回游戏"), "B5-1c 退出面板上有「取消，返回游戏」按钮")
	for i in range(5):
		await process_frame
	_check(_phase() == "RACING", "B5-1d 取消后精确回到 RACING（实际 %s）" % _phase())
	_check(not paused, "B5-1e 取消后树恢复运行")
	var n2 := _count_script_nodes(_exit_script)
	_check(n2 == 0, "B5-1f 取消后退出确认面板已释放（实际 %d）" % n2)

	# ---- 从 FINISHED 取消：不许变成 RACING ----
	_finish_now(m)
	_check(_phase() == "FINISHED", "B5-2a 前置：已进结算（实际 %s）" % _phase())
	_gs.call("request_exit")
	await process_frame
	_check(_phase() == "EXIT_CONFIRM", "B5-2b 结算态 request_exit → EXIT_CONFIRM")
	_check(_click_exit_button("取消，返回游戏"), "B5-2c 取消按钮可点")
	for i in range(5):
		await process_frame
	_check(_phase() == "FINISHED",
		"B5-2d 结算态取消后仍是 FINISHED（实际 %s，绝不能变成 RACING）" % _phase())
	_check(paused, "B5-2e 结算态取消后树仍然暂停（比赛没有被恢复）")
	var n3 := _count_script_nodes(_exit_script)
	_check(n3 == 0, "B5-2f 取消后退出确认面板已释放（实际 %d）" % n3)
	var n4 := _count_script_nodes(_finish_script)
	_check(n4 == 1, "B5-2g 结算态取消后结算面板仍在（实际 %d）" % n4)
	_check(not Dictionary(_gs.get("finish_snapshot")).is_empty(),
		"B5-2h 结算态取消后成绩快照仍在")

	# ---- 二次进出确认框：_phase_before_exit 不能被写坏 ----
	_gs.call("request_exit")
	await process_frame
	_gs.call("cancel_exit")
	for i in range(5):
		await process_frame
	_check(_phase() == "FINISHED" and paused,
		"B5-2i 二次进出确认框后仍精确回到 FINISHED（实际 %s，paused=%s）" % [_phase(), str(paused)])

	# ---- 从 MENU 取消 ----
	await _free_scene()
	_gs.call("enter_menu")
	await process_frame
	_gs.call("request_exit")
	await process_frame
	_check(_phase() == "EXIT_CONFIRM", "B5-3a MENU → 退出确认（实际 %s）" % _phase())
	_gs.call("cancel_exit")
	for i in range(5):
		await process_frame
	_check(_phase() == "MENU" and not paused,
		"B5-3b 取消后精确回到 MENU 且未暂停（实际 %s，paused=%s）" % [_phase(), str(paused)])


# ============== B6 重开：清弹窗 / 清输入 / 解暂停 / 成绩重初始化，但设置保留

func _b6_restart_keeps_settings() -> void:
	var m := await _new_race(2)
	if m == null:
		return
	var fps_before := int(_gs.get("render_fps"))
	_gs.set("max_speed_kmh", 200.0)
	var saved_path := String(_gs.get("settings_path"))
	_check(float(_gs.get("max_speed_kmh")) == 200.0, "B6-0a 前置：极速哨兵值已设成 200.0")
	_check(saved_path == "user://rel-final-qa-settings.cfg",
		"B6-0b 前置：设置落盘路径已被测试重定向（不碰玩家 settings.cfg）")

	_finish_now(m)
	_check(_phase() == "FINISHED", "B6-1a 前置：已进结算（实际 %s）" % _phase())
	# 结算态再叠一层退出确认框，检验"重开会把所有弹窗清掉"
	_gs.call("request_exit")
	await process_frame
	_check(_phase() == "EXIT_CONFIRM", "B6-1b 前置：退出确认框已弹出（实际 %s）" % _phase())
	var n0 := _count_script_nodes(_exit_script)
	_check(n0 == 1, "B6-1c 前置：退出确认面板存在（实际 %d）" % n0)
	# 重开瞬间还按着键：重开后必须全部释放
	var acts: Array = _gs.get("DRIVE_ACTIONS")
	for a in acts:
		Input.action_press(a)
	_gs.call("restart_race")
	var fresh := await _await_scene_change()
	_check(fresh != null and bool(fresh.get("_setup_done")), "B6-2a 重开 → 新比赛场景就绪")
	if fresh != null:
		var still := []
		for a in acts:
			if Input.is_action_pressed(a):
				still.append(a)
		_check(still.is_empty(), "B6-2b 重开后驾驶输入已全部释放（仍按住：%s）" % str(still))
		# Phase 01：重开必然重新倒计时（R14）；"解除暂停"的旧判据改为"停在 COUNTDOWN"
		_check(_phase() == "COUNTDOWN", "B6-2c 重开 → 重新倒计时（实际 %s）" % _phase())
		_check(paused, "B6-2d 重开 → 树暂停等待出发")
		var car := fresh.get_node_or_null("RaceCar")
		if car != null:
			_check(int(car.get("laps_done")) == 0 and float(car.get("lap_last")) <= 0.001,
				"B6-2e 重开 → 成绩重新初始化（圈数=%d 上圈=%.3f）"
					% [int(car.get("laps_done")), float(car.get("lap_last"))])
		else:
			_fail("B6-2f 重开后找不到 RaceCar")
	_check(Dictionary(_gs.get("finish_snapshot")).is_empty(), "B6-2g 重开 → 成绩快照已清空")
	var n5 := _count_script_nodes(_finish_script)
	_check(n5 == 0, "B6-2h 重开 → 结算面板已清理（实际 %d）" % n5)
	var n6 := _count_script_nodes(_exit_script)
	_check(n6 == 0, "B6-2i 重开 → 退出确认面板已清理（实际 %d）" % n6)
	# ---- 设置保留 ----
	var fps_after := int(_gs.get("render_fps"))
	_check(fps_after == fps_before,
		"B6-3a 重开后渲染帧率保留（%d → %d）" % [fps_before, fps_after])
	var speed_after := float(_gs.get("max_speed_kmh"))
	_check(absf(speed_after - 200.0) < 0.001,
		"B6-3b 重开后极速设置保留（实际 %.1f，应 200.0）" % speed_after)
	_check(String(_gs.get("settings_path")) == saved_path, "B6-3c 重开后设置落盘路径未被改写")


# ================================================================= 工具

## 起一局新比赛。会先把上一局（含它的弹窗）彻底释放。
func _new_race(level_idx: int) -> Node:
	await _free_scene()
	_gs.set("chosen_level", level_idx)
	var packed: PackedScene = load(MAIN_SCENE)
	if packed == null:
		_fail("无法加载 " + MAIN_SCENE)
		return null
	var m := packed.instantiate()
	root.add_child(m)
	current_scene = m
	for i in range(SETUP_FRAMES):
		await process_frame
		if is_instance_valid(m) and bool(m.get("_setup_done")):
			# Phase 01：互动路径装配完进 COUNTDOWN（树暂停）。各 B 用例都假设
			# "比赛正在进行"，这里统一触发"出发！"（与游玩同一个入口 _on_race_go）
			# 再返回。幂等安全：万一倒计时已自动到点，再调一次只是让 start_race 返回 false。
			m.call("_on_race_go")
			return m
	_fail("等待 main 场景装配超时（%d 帧）" % SETUP_FRAMES)
	return null


## 等"换了新场景"：restart_race 会 reload_current_scene，current_scene 会换成新实例。
func _await_scene_change() -> Node:
	for i in range(SETUP_FRAMES):
		await process_frame
		var s := current_scene
		if s != null and is_instance_valid(s) and s.get("_setup_done") != null \
			and bool(s.get("_setup_done")):
			return s
	_fail("等待重载后的比赛场景超时（%d 帧）" % SETUP_FRAMES)
	return null


## 释放当前场景（reload_current_scene / change_scene_to_file 之外的手动清理路径）。
##
## ⚠ 必须**等到它真的没了**再返回。第一版只等到"弹窗计数归零"就返回（通常 1 帧），
## 而 queue_free 是帧末才真正摘除 —— 于是在场景还在"待删"状态时脚本就 quit() 了，
## 引擎在退出期报 `ObjectDB instances leaked at exit` + `2 resources still in use`
## （rel-final-finish-green2.log 出现过一次，同代码再跑又不出现 —— 典型的收尾顺序问题）。
## 现在显式等 `is_instance_valid(victim) == false`，即对象真的被销毁。
func _free_scene() -> void:
	var victim := current_scene
	if victim != null and is_instance_valid(victim):
		victim.queue_free()
		current_scene = null
	for i in range(120):
		await process_frame
		var gone := victim == null or not is_instance_valid(victim)
		if gone and _count_script_nodes(_finish_script) == 0 \
			and _count_script_nodes(_exit_script) == 0:
			return


## 把当前这局"打到终点"并返回目标圈数。
func _finish_now(m: Node) -> int:
	var car := m.get_node_or_null("RaceCar")
	if car == null:
		_fail("找不到 RaceCar，无法触发完成")
		return 0
	var target := int(car.get("laps_target"))
	car.set("lap_last", 40.0)
	car.set("lap_best", 38.0)
	car.set("laps_done", target)
	car.emit_signal("race_finished", target)
	return target


## 全树数一遍挂了某个脚本的节点。
## ⚠ 为什么必须全树递归 + owned=false：只查 current_scene 的直接子节点会漏掉
##   "挂在别处 / 还挂着只是 queue_free 待删"的残弹窗 —— 那正是"没了"和"以为没了"的差别。
func _count_script_nodes(s: Script) -> int:
	if s == null:
		return 0
	var n := 0
	for node in root.find_children("*", "", true, false):
		if is_instance_valid(node) and node.get_script() == s:
			n += 1
	return n


func _find_finish_menu() -> CanvasLayer:
	for node in root.find_children("*", "", true, false):
		if is_instance_valid(node) and node.get_script() == _finish_script:
			return node as CanvasLayer
	return null


func _find_exit_panel() -> CanvasLayer:
	for node in root.find_children("*", "", true, false):
		if is_instance_valid(node) and node.get_script() == _exit_script:
			return node as CanvasLayer
	return null


## 点真实按钮（发出 pressed 信号），而不是直接调 GameState 的同名方法 ——
## 后者绕过 UI 接线，"按钮没接上"这种故障会漏网。
func _click_button(layer: CanvasLayer, text: String) -> bool:
	if layer == null:
		return false
	for btn in layer.find_children("*", "Button", true, false):
		if is_instance_valid(btn) and String(btn.get("text")) == text:
			(btn as Button).emit_signal("pressed")
			return true
	return false


func _click_finish_button(text: String) -> bool:
	return _click_button(_find_finish_menu(), text)


func _click_exit_button(text: String) -> bool:
	return _click_button(_find_exit_panel(), text)


## 喂一个真实的 ESC 按键（走 Viewport 输入管线，与 basic.gd 的 _menu_press_escape 同法）。
func _frames(n: int) -> void:
	for i in range(n):
		await process_frame


func _push_escape() -> void:
	var down := InputEventKey.new()
	down.physical_keycode = KEY_ESCAPE
	down.keycode = KEY_ESCAPE
	down.pressed = true
	root.push_input(down)
	var up := InputEventKey.new()
	up.physical_keycode = KEY_ESCAPE
	up.keycode = KEY_ESCAPE
	up.pressed = false
	root.push_input(up)


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("  [B] PASS %s" % label)
	else:
		_fail(label)


func _fail(label: String) -> void:
	failed += 1
	_msgs.append(label)
	printerr("  [B] FAIL %s" % label)


func _finish() -> void:
	_timed_out = false
	# 退出前再空转几帧：让所有 queue_free 真正落到 ObjectDB 上，
	# 免得"待删对象"被算成退出期泄漏（那是**测试的收尾问题**，不是产品的）。
	await _frames(10)
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	if _msgs.is_empty():
		print("REL_FINAL_FINISHFLOW_PASS")
		quit(0)
		return
	for msg in _msgs:
		print("  !! %s" % msg)
	print("REL_FINAL_FINISHFLOW_FAIL")
	quit(1)
