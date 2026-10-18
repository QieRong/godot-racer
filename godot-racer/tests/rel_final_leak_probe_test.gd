extends SceneTree
## REL-QA-GATE · 资源泄漏定位探针
##
## 背景：rel-final-finish-green2.log 末尾出现过一次
##   WARNING: ObjectDB instances leaked at exit (run with --verbose for details).
##   ERROR: 2 resources still in use at exit (run with --verbose for details).
## 但同样的脚本再跑（rel-final-finish-green.log / rel-final-leak-verbose.log）又没有 —— 也就是说
## 这条告警**不可复现**，追它本身追不出结论（--verbose 那一跑也没出现，拿不到对象清单）。
##
## 真正该回答的问题不是"退出时有没有两行告警"，而是：
##   **玩家反复「完成比赛 → 返回选关 → 再玩一局」时，对象/资源会不会一轮一轮地累积？**
## 累积才是玩家机器上的真实缺陷；退出瞬间的一次性残留在 Godot 里也可能是
## 关闭顺序造成的假象（队列里的 queue_free 还没执行完进程就退了）。
##
## 所以这里直接**逐轮量**：
##   · OBJECT_NODE_COUNT        树上还活着多少节点
##   · OBJECT_ORPHAN_NODE_COUNT 脱离父节点但仍活着的"孤儿"节点（叠音/残弹窗就藏在这里）
##   · OBJECT_RESOURCE_COUNT    资源对象数（脚本/材质/网格/PackedScene）
##   · OBJECT_COUNT             全部 Object
## 判据：预热 1 轮之后（第 1 轮会把关卡资源真正 load 进来，那是正常的一次性增长），
##       第 2 轮 → 第 5 轮的增量必须很小且**不单调增长**。
##
## 用法：
##   pwsh -File 04-Godot启动器\run-rel-final-test.ps1 ^
##        -Script res://tests/rel_final_leak_probe_test.gd -LogName rel-final-leak-probe
##
## ⚠ --script 下没有编译期 GameState 标识符，走 root.get_node_or_null(...) + call/get/set。

const MAIN_SCENE := "res://scenes/main.tscn"
const FINISH_MENU_SCRIPT := "res://scripts/finish_menu.gd"
const CYCLES := 5
const SETUP_FRAMES := 1200
## 第 2 轮 → 第 5 轮允许的总增量。设得小是为了能抓到"每轮泄漏几个"，
## 但也不能是 0：引擎自己的懒加载缓存（字体、主题、材质）在头几轮仍会补一点。
const RESOURCE_GROWTH_LIMIT := 24
const NODE_GROWTH_LIMIT := 8

var passed := 0
var failed := 0
var _msgs: Array[String] = []
var _started := false
var _timed_out := false
var _gs: Node = null
var _finish_script: Script = null
var _rows: Array[Dictionary] = []


func _initialize() -> void:
	var wd := create_timer(280.0, true)
	wd.timeout.connect(_on_watchdog)
	call_deferred("_run")


func _on_watchdog() -> void:
	if _timed_out:
		return
	_timed_out = true
	print("[LEAK] WATCHDOG 280s")
	_fail("WATCHDOG 280s")
	_finish()


func _run() -> void:
	if _started:
		return
	_started = true
	_finish_script = load(FINISH_MENU_SCRIPT)
	_gs = root.get_node_or_null("GameState")
	if _gs == null:
		_fail("GameState autoload 缺失")
		_finish()
		return
	_gs.set("settings_path", "user://rel-final-qa-settings.cfg")

	_snapshot("baseline")
	for i in range(CYCLES):
		await _cycle(i + 1)
	_analyze()
	_finish()


func _cycle(n: int) -> void:
	await _free_scene()
	_gs.set("chosen_level", n % 5)
	var packed: PackedScene = load(MAIN_SCENE)
	var m := packed.instantiate()
	root.add_child(m)
	current_scene = m
	for i in range(SETUP_FRAMES):
		await process_frame
		if is_instance_valid(m) and bool(m.get("_setup_done")):
			break
	# 打到终点（走真实信号，不直接调 API）
	var car := m.get_node_or_null("RaceCar")
	if car != null:
		car.set("lap_last", 40.0)
		car.set("lap_best", 39.0)
		car.set("laps_done", int(car.get("laps_target")))
		car.emit_signal("race_finished", int(car.get("laps_target")))
	await _frames(4)
	# 返回选关（玩家最常走的那条路）
	_gs.call("back_to_menu")
	await _frames(24)
	# 把菜单场景也收掉，模拟"玩家又开了一局"之前的上一个状态彻底结束
	await _free_scene()
	await _frames(12)
	_snapshot("cycle%d" % n)


func _snapshot(tag: String) -> void:
	var row := {
		"tag": tag,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"orphan": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"finish": _count_script_nodes(_finish_script),
	}
	_rows.append(row)
	print("[LEAK] %-9s nodes=%4d orphan=%3d resources=%4d objects=%5d finish_overlay=%d"
		% [tag, int(row["nodes"]), int(row["orphan"]), int(row["resources"]),
		   int(row["objects"]), int(row["finish"])])


func _analyze() -> void:
	if _rows.size() < 3:
		_fail("样本不足")
		return
	var warm := _rows[1]      # 第 1 轮之后（关卡资源已 load 完，作为基准）
	var last := _rows[_rows.size() - 1]
	var d_res := int(last["resources"]) - int(warm["resources"])
	var d_node := int(last["nodes"]) - int(warm["nodes"])
	var d_orphan := int(last["orphan"]) - int(warm["orphan"])
	var d_obj := int(last["objects"]) - int(warm["objects"])
	print("[LEAK] 第1轮 → 第%d 轮增量：resources=%+d nodes=%+d orphan=%+d objects=%+d"
		% [_rows.size() - 1, d_res, d_node, d_orphan, d_obj])
	# 单调性：逐轮差分里只要有 >=3 轮都是正的，就是"一轮一轮往上长"
	var grows := 0
	for i in range(2, _rows.size()):
		if int(_rows[i]["resources"]) > int(_rows[i - 1]["resources"]):
			grows += 1
	print("[LEAK] 资源数逐轮上升的轮次 = %d / %d" % [grows, _rows.size() - 2])
	_check(d_res <= RESOURCE_GROWTH_LIMIT,
		"资源数 第1轮→第%d轮 增量 %+d（上限 %d）" % [_rows.size() - 1, d_res, RESOURCE_GROWTH_LIMIT])
	_check(d_node <= NODE_GROWTH_LIMIT,
		"节点数 第1轮→第%d轮 增量 %+d（上限 %d）" % [_rows.size() - 1, d_node, NODE_GROWTH_LIMIT])
	_check(int(last["orphan"]) <= 4,
		"孤儿节点数 = %d（上限 4，孤儿是残弹窗/残播放器的藏身处）" % int(last["orphan"]))
	_check(int(last["finish"]) == 0,
		"循环结束后结算面板残留 %d 个（应 0）" % int(last["finish"]))
	_check(grows < 3,
		"资源数逐轮上升 %d 次（>=3 说明在累积，玩家反复重开会越跑越占内存）" % grows)


func _count_script_nodes(s: Script) -> int:
	if s == null:
		return 0
	var n := 0
	for node in root.find_children("*", "", true, false):
		if is_instance_valid(node) and node.get_script() == s:
			n += 1
	return n


func _free_scene() -> void:
	if current_scene != null and is_instance_valid(current_scene):
		current_scene.queue_free()
		current_scene = null
	for i in range(60):
		await process_frame
		if _count_script_nodes(_finish_script) == 0:
			return


func _frames(n: int) -> void:
	for i in range(n):
		await process_frame


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("  [LEAK] PASS %s" % label)
	else:
		_fail(label)


func _fail(label: String) -> void:
	failed += 1
	_msgs.append(label)
	printerr("  [LEAK] FAIL %s" % label)


func _finish() -> void:
	_timed_out = false
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	if _msgs.is_empty():
		print("REL_FINAL_LEAK_PROBE_PASS")
		quit(0)
		return
	for msg in _msgs:
		print("  !! %s" % msg)
	print("REL_FINAL_LEAK_PROBE_FAIL")
	quit(1)
