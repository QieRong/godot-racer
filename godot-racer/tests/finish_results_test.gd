extends SceneTree
## PHASE3-RACE-RESULTS · 结算页扩展 + HUD 总时间标签（TDD：先红后绿）。
##
## 覆盖（plan/racing-system-design-20261018.md §7.2 / §7.3 / §9）：
##   A1 结算页内容：结果行（「最终名次 第 X 名（共 N 车）」、第 1 名附加「你获得了冠军」）、
##      成绩区（完成 X/Y 圈 · 总时间 mm:ss.mmm · 末圈 · 最快圈）、
##      对手成绩表（每行 名次 · AI#n · 圈数 · 状态 完赛/未完赛，玩家行高亮）、
##      按钮文案（返回主菜单（ESC）/ 再玩一局 / 退出游戏）
##   A2 AC-07 玩家完赛一次性：重复完成信号只出一个结算页、快照不被改写
##   A3 AC-09 关闭 AI：无对手节点、不渲染对手成绩表，仍可正常完赛（practice）
##   A4 AC-11 再玩一局：先清成绩进 LOADING，再重载出新比赛场景 →
##      重新倒计时（COUNTDOWN）且成绩/AI/面板全部重置
##   A5 HUD 总时间标签：GO 前显示 --:--.---，GO 后从 0 开始递增
##      （R15：总时间从「出发！」race_start_ms 起算，与圈速口径分离）
##
## ⚠ 为什么全篇用 `_gs.call(...)` / `_gs.get(...)` 而不是直接写 `GameState.xxx`：
##   `--script` 跑起来的脚本**本身**就是 MainLoop，它在 autoload 注册**之前**就被编译，
##   此时 `GameState` 标识符在编译期不存在（与 rel_final_finish_flow_test.gd 同因，
##   实测报 `Compile Error: Identifier not found: GameState`）。autoload 节点运行时
##   挂在 root 下，所以走 root.get_node_or_null("GameState") 再 call/get/set。
##
## ⚠ 信号链摆位：装配完成等 `_setup_done`（此时相位 COUNTDOWN、树暂停）→
##   本测试自己调 `m.call("_on_race_go")`（与游玩同一个发车入口）→ 置成绩后
##   `car.emit_signal("race_finished", target)` → 等若干帧让 main 的 deferred/同步
##   回调把快照写齐、结算面板挂好，再做断言。
##
## 用法（仓库根目录）：
##   pwsh -File 04-Godot启动器\run-rel-final-test.ps1 `
##        -Script res://tests/finish_results_test.gd -LogName phase3-red-1

const MAIN_SCENE := "res://scenes/main.tscn"
const FINISH_MENU_SCRIPT := "res://scripts/finish_menu.gd"

## 主场景装配（赛道 + 对手）就绪的等待上限。实测这台机器 4s 量级，给 1500 帧是保守的。
const SETUP_FRAMES := 1500
const WATCHDOG_SEC := 300.0

var passed := 0
var failed := 0
var _msgs: Array[String] = []
var _started := false
var _timed_out := false
var _gs: Node = null
var _finish_script: Script = null


func _initialize() -> void:
	var wd := create_timer(WATCHDOG_SEC, true)
	wd.timeout.connect(_on_watchdog)
	call_deferred("_run")


func _on_watchdog() -> void:
	if _timed_out:
		return
	_timed_out = true
	print("[R] WATCHDOG: %.0fs 超时，判为失败（多半是某个 await 一直没回）" % WATCHDOG_SEC)
	_fail("WATCHDOG: %.0fs 超时" % WATCHDOG_SEC)
	_finish()


func _run() -> void:
	# ⚠ 必须防重入：实测这台机器上 --script 跑 SceneTree 脚本时 _run() 会被跑两次。
	if _started:
		print("[R] _run() 重复调用，已忽略")
		return
	_started = true
	_finish_script = load(FINISH_MENU_SCRIPT)
	_gs = root.get_node_or_null("GameState")
	if _gs == null or _finish_script == null:
		_fail("GameState autoload 节点缺失，或 finish_menu.gd 加载失败")
		_finish()
		return
	# 别把测试写进玩家自己的 settings.cfg（GameState.settings_path 就是为测试留的口子）
	_gs.set("settings_path", "user://rel-final-qa-settings.cfg")

	# ---- A5：HUD 总时间标签（GO 前 / GO 后）；同一局接着做 A1/A2 ----
	var m := await _new_race(3)
	if m == null:
		_finish()
		return
	await _a5_hud_total_time(m)
	await _a1_finish_menu_contents(m)
	await _a2_finish_once(m)
	await _a4_play_again(m)

	# ---- A3：关闭 AI 一局（另起场景，回到本函数前恢复开关）----
	await _a3_no_ai()
	_gs.set("ai_enabled", true)
	_finish()


# ============================================================ A5：HUD 总时间标签

func _a5_hud_total_time(m: Node) -> void:
	var label := m.get_node_or_null("HUD/TotalTimeLabel") as Label
	_check(label != null, "A5-1 HUD 有「总时间」标签节点（HUD/TotalTimeLabel）")
	if label != null:
		var before := String(label.text)
		_check("总时间" in before, "A5-2 总时间标签带「总时间」字样（实际「%s」）" % before)
		_check("--:--.---" in before,
			"A5-3 GO 前总时间显示占位 --:--.---（实际「%s」，R15：没出发不计时）" % before)
	# ⚠ 无论标签在不在都要发车：后续 A1/A2 用例都在 RACING 状态下完赛，
	#   这里若提前 return，整条链会停在 COUNTDOWN，后面全部变成无意义红。
	m.call("_on_race_go")
	_check(_phase() == "RACING" and not paused,
		"A5-4 调 _on_race_go → RACING 且树解冻（实际 %s，paused=%s）" % [_phase(), str(paused)])
	if label == null:
		await _frames(2)
		return
	await _frames(30)
	var t1 := _parse_mmss(String(label.text))
	_check(t1 > 0.0, "A5-5 GO 后总时间开始计时（实际「%s」）" % String(label.text))
	await _frames(30)
	var t2 := _parse_mmss(String(label.text))
	_check(t2 > t1, "A5-6 GO 后总时间持续递增（%.3fs → %.3fs）" % [t1, t2])


# ================================================== A1：结算页内容（结果行/成绩/对手表/按钮）

func _a1_finish_menu_contents(m: Node) -> void:
	_finish_now(m)
	await _frames(8)
	_check(_phase() == "FINISHED" and paused,
		"A1-0a 完赛 → FINISHED 且树暂停（实际 %s，paused=%s）" % [_phase(), str(paused)])
	var snap: Dictionary = _gs.get("finish_snapshot")
	_check(int(snap.get("position", 0)) == 1,
		"A1-0b 快照有最终名次 position=1（实际 %d）" % int(snap.get("position", 0)))
	_check(int(snap.get("field_size", 0)) == 2,
		"A1-0c 快照有全场车数 field_size=2（实际 %d）" % int(snap.get("field_size", 0)))
	_check(String(snap.get("outcome", "")) == "win",
		"A1-0d 快照有胜负判定 outcome=win（实际 %s）" % String(snap.get("outcome", "")))
	_check(int(Array(snap.get("entrants", [])).size()) == 2,
		"A1-0e 快照有成绩表 entrants=2 行（实际 %d）" % int(Array(snap.get("entrants", [])).size()))
	_check(float(snap.get("total", 0.0)) > 0.0,
		"A1-0f 快照有总时间 total>0（实际 %.3f，R15 从出发起算）" % float(snap.get("total", 0.0)))

	var panel := _find_finish_menu()
	_check(panel != null, "A1-1 结算面板已挂载")
	if panel == null:
		return
	var labels := _collect_labels(panel)
	var all := "\n".join(labels)
	# ---- 结果行 ----
	_check("最终名次" in all, "A1-2 结果行含「最终名次」（实际文本：%s）" % _brief(all))
	_check("第 1 名" in all, "A1-3 结果行含「第 1 名」（实际文本：%s）" % _brief(all))
	_check("共 2 车" in all, "A1-4 结果行含「共 2 车」（实际文本：%s）" % _brief(all))
	_check("你获得了冠军" in all, "A1-5 第 1 名附加「你获得了冠军」（实际文本：%s）" % _brief(all))
	# ---- 成绩区 ----
	_check("总时间" in all, "A1-6 成绩区含「总时间」（实际文本：%s）" % _brief(all))
	var mm := _find_mmss(labels)
	_check(mm != "", "A1-7 成绩区总时间是 mm:ss.mmm 格式（实际：%s）" % _brief(all))
	_check("末圈" in all and "最快" in all, "A1-8 成绩区含末圈/最快圈（实际文本：%s）" % _brief(all))
	_check("完成" in all, "A1-9 成绩区含完成圈数（实际文本：%s）" % _brief(all))
	# ---- 对手成绩表 ----
	var ai_rows := _rows_with(labels, "AI#1")
	_check(ai_rows.size() >= 1, "A1-10 对手成绩表有 AI#1 行（实际文本：%s）" % _brief(all))
	if not ai_rows.is_empty():
		var row := String(ai_rows[0])
		_check("圈" in row, "A1-11 对手行含圈数（%s）" % row)
		_check("未完赛" in row,
			"A1-12 未完赛的对手行状态为「未完赛」（%s，本局 AI 未完成比赛）" % row)
	var player_rows := _rows_with(labels, "玩家")
	_check(player_rows.size() >= 1, "A1-13 成绩表有玩家行（实际文本：%s）" % _brief(all))
	var ai_row_label := _find_label(panel, "AI#1")
	var player_row_label := _find_label(panel, "玩家")
	if ai_row_label != null and player_row_label != null:
		var c_player: Color = player_row_label.get_theme_color("font_color")
		var c_ai: Color = ai_row_label.get_theme_color("font_color")
		_check(c_player != c_ai,
			"A1-14 玩家行高亮：颜色与对手行不同（玩家=%s，AI=%s）" % [str(c_player), str(c_ai)])
		_check(player_row_label.has_theme_color_override("font_color"),
			"A1-15 玩家行显式设置了高亮色（override 在位，不是碰巧同色）")
	else:
		_check(false, "A1-14 找不到玩家行/AI 行标签，无法验高亮（实际文本：%s）" % _brief(all))
	# ---- 按钮文案 ----
	_check(_has_button(panel, "返回主菜单（ESC）"), "A1-16 按钮「返回主菜单（ESC）」在位")
	_check(_has_button(panel, "再玩一局"), "A1-17 按钮「再玩一局」在位")
	_check(_has_button(panel, "退出游戏"), "A1-18 按钮「退出游戏」在位")


# ============================================ A2：AC-07 玩家完赛一次性（复用 A1 的结算面板）

func _a2_finish_once(m: Node) -> void:
	var before: Dictionary = _gs.get("finish_snapshot")
	var car := m.get_node_or_null("RaceCar")
	if car == null:
		_fail("A2 找不到 RaceCar 节点")
		return
	# 改花成绩再发一次完成信号：必须被 main 的一次性门闩挡掉
	car.set("lap_last", 777.0)
	car.set("lap_best", 999.0)
	car.emit_signal("race_finished", int(car.get("laps_target")))
	await _frames(8)
	_check(_count_finish_menus() == 1,
		"A2-1 重复完成信号只出一个结算面板（实际 %d）" % _count_finish_menus())
	var after: Dictionary = _gs.get("finish_snapshot")
	_check(float(after.get("last", -1.0)) == float(before.get("last", -2.0)),
		"A2-2 重复信号不改写末圈（%.2f → %.2f）"
			% [float(before.get("last", -1.0)), float(after.get("last", -1.0))])
	_check(int(after.get("position", 0)) == int(before.get("position", 0)),
		"A2-3 重复信号不改写名次（%d → %d）"
			% [int(before.get("position", 0)), int(after.get("position", 0))])
	_check(int(Array(after.get("entrants", [])).size())
		== int(Array(before.get("entrants", [])).size()),
		"A2-4 重复信号不改写成绩表（%d → %d 行）"
			% [int(Array(before.get("entrants", [])).size()),
				int(Array(after.get("entrants", [])).size())])


# ============================================ A4：AC-11 再玩一局（LOADING → COUNTDOWN）

func _a4_play_again(m: Node) -> void:
	var clicked := _click_button(_find_finish_menu(), "再玩一局")
	_check(clicked, "A4-1 结算面板上有「再玩一局」按钮且点得动")
	if not clicked:
		return
	# restart_race = prepare_race（清成绩、进 LOADING）+ reload_current_scene
	_check(_phase() == "LOADING",
		"A4-2 再玩一局 → 先清成绩进 LOADING（实际 %s）" % _phase())
	_check(Dictionary(_gs.get("finish_snapshot")).is_empty(),
		"A4-3 再玩一局 → 成绩快照立即清零")
	var fresh := await _await_scene_change(m)
	_check(fresh != null, "A4-4 再玩一局 → 新比赛场景就绪")
	if fresh != null:
		_check(_phase() == "COUNTDOWN" and paused,
			"A4-5 再玩一局 → 重新倒计时且树暂停（实际 %s，paused=%s）" % [_phase(), str(paused)])
		var car2 := fresh.get_node_or_null("RaceCar")
		if car2 != null:
			_check(int(car2.get("laps_done")) == 0 and float(car2.get("lap_last")) <= 0.001,
				"A4-6 再玩一局 → 成绩清零（圈数=%d，末圈=%.3f）"
					% [int(car2.get("laps_done")), float(car2.get("lap_last"))])
		else:
			_fail("A4-6 重开后找不到 RaceCar")
		var opp: Array = fresh.get("_opponents")
		_check(int(opp.size()) == 1, "A4-7 再玩一局 → AI 重新生成（实际 %d 台）" % int(opp.size()))
	_check(_count_finish_menus() == 0, "A4-8 再玩一局 → 旧结算面板已清理")
	_check(Dictionary(_gs.get("finish_snapshot")).is_empty(),
		"A4-9 再玩一局 → 新比赛成绩快照为空")
	_check(float(_gs.get("race_start_ms")) == 0.0,
		"A4-10 再玩一局 → 总时间起点归零（重开后重新起算，实际 %.1f）"
			% float(_gs.get("race_start_ms")))


# ==================================== A3：AC-09 关闭 AI（无对手节点、无对手表、可正常完赛）

func _a3_no_ai() -> void:
	await _free_scene()
	_gs.set("ai_enabled", false)
	var m := await _new_race(3)
	if m == null:
		return
	_check(_phase() == "COUNTDOWN" and paused,
		"A3-1 关闭 AI → 倒计时照常走（实际 %s，paused=%s）" % [_phase(), str(paused)])
	var holder := m.get_node_or_null("Opponents")
	_check(holder == null or int(holder.get_child_count()) == 0,
		"A3-2 关闭 AI → 无对手节点（Opponents 子节点数 %d）"
			% (int(holder.get_child_count()) if holder != null else 0))
	var opp: Array = m.get("_opponents")
	_check(int(opp.size()) == 0, "A3-3 关闭 AI → main 的对手数组为空（实际 %d）" % int(opp.size()))
	m.call("_on_race_go")
	_check(_phase() == "RACING", "A3-4 关闭 AI → 玩家照常发车（实际 %s）" % _phase())
	# ⚠ 发车后必须真等几帧再完赛：GO 与完赛若落在同一毫秒内，
	#   race_total_time()（毫秒墙钟）会返回 0.0，总时间显示占位 —— 那是测试
	#   构造出来的假象，不是产品行为（真实比赛不可能 <1ms）。等 10 帧拉开间距。
	await _frames(10)
	_finish_now(m)
	await _frames(8)
	_check(_phase() == "FINISHED", "A3-5 关闭 AI → 玩家仍可正常完赛（实际 %s）" % _phase())
	var snap: Dictionary = _gs.get("finish_snapshot")
	_check(int(snap.get("field_size", 0)) == 1,
		"A3-6 无对手 → field_size=1（实际 %d）" % int(snap.get("field_size", 0)))
	_check(String(snap.get("outcome", "")) == "practice",
		"A3-7 无对手 → outcome=practice（实际 %s）" % String(snap.get("outcome", "")))
	_check(float(snap.get("total", 0.0)) > 0.0,
		"A3-7b 无对手 → 总时间仍从出发起算（实际 %.3f）" % float(snap.get("total", 0.0)))
	var panel := _find_finish_menu()
	_check(panel != null, "A3-8 无对手 → 结算面板仍挂载")
	if panel == null:
		return
	var all := "\n".join(_collect_labels(panel))
	_check(not ("AI#" in all),
		"A3-9 无对手 → 不渲染对手成绩表（实际文本：%s）" % _brief(all))
	_check("练习" in all, "A3-10 无对手 → 结算页显示练习文案（实际文本：%s）" % _brief(all))
	_check(not ("你获得了冠军" in all),
		"A3-11 无对手 → 不显示冠军文案（实际文本：%s）" % _brief(all))
	_check(_has_button(panel, "返回主菜单（ESC）") and _has_button(panel, "再玩一局")
		and _has_button(panel, "退出游戏"),
		"A3-12 无对手 → 三个出口按钮齐全")


# ================================================================= 工具

## 起一局新比赛（等装配完成即返回，**不发车**：相位停在 COUNTDOWN、树暂停）。
## 发车由各用例自己调 `m.call("_on_race_go")`，与游玩共用同一个入口。
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
			return m
	_fail("等待 main 场景装配超时（%d 帧）" % SETUP_FRAMES)
	return null


## 等"换了新场景"：restart_race 会 reload_current_scene，current_scene 会换成新实例。
## ⚠ 用**实例 ID** 而不是持有旧节点来排除旧场景：旧场景在重载时会被释放，
##   届时对它的任何属性访问/比较都会抛 "previously freed" 脚本错误，直接把协程
##   打断（实测过一次：整个 _run 中断、进程空转到看门狗）。实例 ID 是整数，安全。
func _await_scene_change(old: Node) -> Node:
	var old_id := old.get_instance_id() if old != null else 0
	for i in range(SETUP_FRAMES):
		await process_frame
		var s := current_scene
		if s != null and is_instance_valid(s) and s.get_instance_id() != old_id \
			and s.get("_setup_done") != null and bool(s.get("_setup_done")):
			return s
	_fail("等待重载后的比赛场景超时（%d 帧）" % SETUP_FRAMES)
	return null


## 释放当前场景（reload_current_scene / change_scene_to_file 之外的手动清理路径）。
## ⚠ 必须**等到它真的没了**再返回：queue_free 是帧末才真正摘除，脚本提前往下走
##   会在场景还"待删"时操作下一局，收尾还可能报 ObjectDB 泄漏。
func _free_scene() -> void:
	var victim := current_scene
	if victim != null and is_instance_valid(victim):
		victim.queue_free()
		current_scene = null
	for i in range(120):
		await process_frame
		var gone := victim == null or not is_instance_valid(victim)
		if gone and _count_finish_menus() == 0:
			return


## 把当前这局"打到终点"（圈数置满 → 发真实完成信号）。
func _finish_now(m: Node) -> void:
	var car := m.get_node_or_null("RaceCar")
	if car == null:
		_fail("找不到 RaceCar，无法触发完成")
		return
	var target := int(car.get("laps_target"))
	car.set("lap_last", 41.25)
	car.set("lap_best", 39.5)
	car.set("laps_done", target)
	car.emit_signal("race_finished", target)


## 全树数一遍挂了 finish_menu.gd 的节点（含"挂着只是 queue_free 待删"的残弹窗）。
func _count_finish_menus() -> int:
	if _finish_script == null:
		return 0
	var n := 0
	for node in root.find_children("*", "", true, false):
		if is_instance_valid(node) and node.get_script() == _finish_script:
			n += 1
	return n


func _find_finish_menu() -> CanvasLayer:
	for node in root.find_children("*", "", true, false):
		if is_instance_valid(node) and node.get_script() == _finish_script:
			return node as CanvasLayer
	return null


## 收面板下全部 Label 的文字（按钮文字不算 —— 按钮单独按文本断言）。
func _collect_labels(panel: CanvasLayer) -> Array:
	var out: Array = []
	if panel == null:
		return out
	for node in panel.find_children("*", "Label", true, false):
		if is_instance_valid(node):
			out.append(String((node as Label).text))
	return out


func _rows_with(labels: Array, needle: String) -> Array:
	var out: Array = []
	for t in labels:
		if needle in String(t):
			out.append(String(t))
	return out


func _find_label(panel: CanvasLayer, needle: String) -> Label:
	if panel == null:
		return null
	for node in panel.find_children("*", "Label", true, false):
		if is_instance_valid(node) and needle in String((node as Label).text):
			return node as Label
	return null


## 在标签文本里找第一个 mm:ss.mmm（用来验总时间是"分:秒.毫秒"口径）。
func _find_mmss(labels: Array) -> String:
	var re := RegEx.new()
	var err := re.compile("([0-9]{2}):([0-9]{2})\\.([0-9]{3})")
	if err != OK:
		return ""
	for t in labels:
		var hit := re.search(String(t))
		if hit != null:
			return hit.get_string(0)
	return ""


## 把 "总时间   00:00.123" 这样的文本解析成秒；解析不到返回 -1。
func _parse_mmss(text: String) -> float:
	var re := RegEx.new()
	var err := re.compile("([0-9]{2}):([0-9]{2})\\.([0-9]{3})")
	if err != OK:
		return -1.0
	var hit := re.search(text)
	if hit == null:
		return -1.0
	return float(hit.get_string(1)) * 60.0 + float(hit.get_string(2)) \
		+ float(hit.get_string(3)) / 1000.0


## 只**查**按钮在不在（不发射 pressed）—— 查存在性的动作绝不能有副作用：
## 实测把"存在性检查"写成"点一下试试"时，A1 的按钮检查当场把返回主菜单
## 点了出去，后面整个用例链在错误的状态上跑。
func _has_button(panel: CanvasLayer, text: String) -> bool:
	if panel == null:
		return false
	for btn in panel.find_children("*", "Button", true, false):
		if is_instance_valid(btn) and String((btn as Button).text) == text:
			return true
	return false


## 点真实按钮（发出 pressed 信号），而不是直接调 GameState 的同名方法 ——
## 后者绕过 UI 接线，"按钮没接上/文案不对"这种故障会漏网。
func _click_button(panel: CanvasLayer, text: String) -> bool:
	if panel == null:
		return false
	for btn in panel.find_children("*", "Button", true, false):
		if is_instance_valid(btn) and String((btn as Button).text) == text:
			(btn as Button).emit_signal("pressed")
			return true
	return false


func _phase() -> String:
	return String(_gs.call("phase_name"))


func _frames(n: int) -> void:
	for i in range(n):
		await process_frame


## 日志里贴长文本时截断，免得一行刷屏看不清判据。
func _brief(text: String) -> String:
	var flat := text.replace("\n", " / ")
	if flat.length() <= 160:
		return flat
	return flat.substr(0, 160) + "…"


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("  [R] PASS %s" % label)
	else:
		_fail(label)


func _fail(label: String) -> void:
	failed += 1
	_msgs.append(label)
	printerr("  [R] FAIL %s" % label)


func _finish() -> void:
	_timed_out = false
	# 退出前再空转几帧：让所有 queue_free 真正落到 ObjectDB 上，
	# 免得"待删对象"被算成退出期泄漏（那是**测试的收尾问题**，不是产品的）。
	await _frames(10)
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	if _msgs.is_empty():
		print("FINISH_RESULTS_PASS")
		quit(0)
		return
	for msg in _msgs:
		print("  !! %s" % msg)
	print("FINISH_RESULTS_FAIL")
	quit(1)
