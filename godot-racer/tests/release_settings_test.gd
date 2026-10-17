extends SceneTree
## REL-STEP2A 的验收测试（`godot --script` 直接跑，不进主场景）。
##
## 覆盖四组：
##   T-F*  渲染帧率：60/120 应用、脏值回退 60、命令行覆盖**不写存档**
##   T-W*  窗口策略：首启 1280×720 按可用工作区等比缩小并居中；恢复 + 超屏重约束
##   T-P*  关卡枚举：ResourceLoader.list_directory 拿到 5 关（+ .remap 负对照）
##   T-U*  菜单新增控件的缩放 / 焦点 / 可达性
##
## 判据纪律（AGENTS.md §5.2：新判据必须先问"已知坏状态能否稳定让它失败"）：
##   - T-P2 是 T-P1 的**负对照**：把 DirAccess 在导出包里实际枚举到的那种
##     `level_1.tres.remap` 喂给过滤函数，必须一个都不剩。少了这条，
##     "枚举器被改回 DirAccess"这类回归会一路绿到玩家手上才炸（0 个关卡）。
##   - T-F6 的**存档**断言才是"命令行不改玩家选择"这条需求真正的判据；
##     只看 Engine.max_fps 抓不到它 —— 覆盖前后它都是 120，一样的值。
##   - T-W5 守"拿不到屏幕信息"分支：headless 验收跑时不能连窗口尺寸一起写脏。
##
## 用法：pwsh -File 04-Godot启动器/run-settings-test.ps1

const MENU_SCENE := "res://scenes/menu.tscn"
const DISPLAY_SETTINGS := "res://scripts/display_settings.gd"
const LEVEL_DIR := "res://data/levels"
## 测试专用配置文件：不碰玩家自己的 user://settings.cfg
const TMP_CFG := "user://_rel_step2a_test.cfg"

var _pass := 0
var _fail := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var state := root.get_node_or_null("GameState")
	if state == null:
		_fail += 1
		print("  ✘ T-0 GameState autoload missing")
		_finish()
		return
	_t_fps(state)
	_t_window()
	_t_window_persistence(state)
	_t_levels(state)
	await _t_menu_ui()
	_cleanup()
	_finish()


# ---------------------------------------------------------------- 帧率
func _t_fps(state: Node) -> void:
	if not state.has_method("set_render_fps"):
		_check(false, "T-F1 GameState 有 set_render_fps 出口", "没有这个方法，菜单与命令行都接不上")
		return
	_check(true, "T-F1 GameState 有 set_render_fps 出口")
	state.set("settings_path", TMP_CFG)

	state.call("set_render_fps", 120)
	_check(Engine.max_fps == 120, "T-F2 切到 120 后 Engine.max_fps==120", "实际 %d" % Engine.max_fps)
	state.call("set_render_fps", 60)
	_check(Engine.max_fps == 60, "T-F3 切回 60 后 Engine.max_fps==60", "实际 %d" % Engine.max_fps)

	for bad in [45, 0, 240, -1]:
		state.call("set_render_fps", bad)
		_check(Engine.max_fps == 60, "T-F4 脏值 %d 回退默认 60" % bad, "实际 %d" % Engine.max_fps)

	state.call("set_render_fps", 120)
	var saved120: int = state.call("read_saved_render_fps")
	_check(saved120 == 120, "T-F5 120 落盘后读回 120", "读回 %d" % saved120)
	state.call("set_render_fps", 60)
	var saved60: int = state.call("read_saved_render_fps")
	_check(saved60 == 60, "T-F5 60 落盘后读回 60", "读回 %d" % saved60)

	if not state.has_method("apply_cli_args"):
		_check(false, "T-F6 GameState 有 apply_cli_args 接线口", "命令行 --render-fps 接不上")
		return
	_check(true, "T-F6 GameState 有 apply_cli_args 接线口")
	state.call("apply_cli_args", PackedStringArray(["--render-fps=120"]))
	_check(Engine.max_fps == 120, "T-F6 --render-fps=120 生效", "实际 %d" % Engine.max_fps)
	var after_cli: int = state.call("read_saved_render_fps")
	_check(after_cli == 60, "T-F6 命令行不得改写玩家存档值", "存档被写成了 %d" % after_cli)
	var cur: int = state.get("render_fps")
	_check(cur == 120, "T-F6 生效值确实是命令行给的 120", "render_fps=%d" % cur)
	state.call("apply_cli_args", PackedStringArray(["--render-fps=abc"]))
	_check(Engine.max_fps == 60, "T-F6 命令行脏值回退 60", "实际 %d" % Engine.max_fps)


# ---------------------------------------------------------------- 窗口
func _t_window() -> void:
	if not ResourceLoader.exists(DISPLAY_SETTINGS, "Script"):
		_check(false, "T-W0 窗口策略模块 scripts/display_settings.gd 已就位", "文件不存在，首启缩放居中策略没有落脚点")
		return
	var ds: GDScript = load(DISPLAY_SETTINGS)
	if ds == null:
		_check(false, "T-W0 窗口策略模块可加载", "load 返回 null")
		return

	var big: Rect2i = ds.call("resolve_window_rect", Vector2i(1280, 720), Vector2i(0, 0), Vector2i(1920, 1080))
	_check(big.size == Vector2i(1280, 720), "T-W1 工作区够大时保持 1280×720（只缩不放）", str(big.size))
	_check(big.position == Vector2i(320, 180), "T-W1 1920×1080 里居中", str(big.position))

	# 笔记本 1366×768 的典型可用工作区：任务栏吃掉约 40px，1280×720 **装不下**
	var small: Rect2i = ds.call("resolve_window_rect", Vector2i(1280, 720), Vector2i(0, 30), Vector2i(1366, 700))
	_check(small.size.x <= 1366 and small.size.y <= 700, "T-W2 小工作区必须装得下", str(small.size))
	_check(small.size != Vector2i(1280, 720), "T-W2 负对照：确实缩小了，不是原样返回", str(small.size))
	var ratio := float(small.size.x) / float(small.size.y)
	_check(absf(ratio - 16.0 / 9.0) < 0.01, "T-W2 等比缩小（宽高比仍约 16:9）", "ratio=%f" % ratio)
	_check(small.position.y == 30, "T-W2 居中位置带上工作区原点（避开任务栏）", str(small.position))

	var restore: Rect2i = ds.call("resolve_window_rect", Vector2i(1600, 900), Vector2i(0, 0), Vector2i(1366, 700))
	_check(restore.size.x <= 1366 and restore.size.y <= 700, "T-W3 存档尺寸超屏时重新约束", str(restore.size))
	var keep: Rect2i = ds.call("resolve_window_rect", Vector2i(1024, 576), Vector2i(0, 0), Vector2i(1920, 1080))
	_check(keep.size == Vector2i(1024, 576), "T-W3 存档尺寸没超屏就原样恢复", str(keep.size))

	var dirty: Rect2i = ds.call("resolve_window_rect", Vector2i(0, 0), Vector2i(0, 0), Vector2i(1920, 1080))
	_check(dirty.size == Vector2i(1280, 720), "T-W4 空/脏尺寸回退 1280×720", str(dirty.size))

	var noscreen: Rect2i = ds.call("resolve_window_rect", Vector2i(1280, 720), Vector2i(0, 0), Vector2i(0, 0))
	_check(noscreen.size == Vector2i(1280, 720), "T-W5 拿不到工作区时原样返回（headless 不动窗口）", str(noscreen.size))


func _t_window_persistence(state: Node) -> void:
	if not state.has_method("remember_window_size"):
		_check(false, "T-W6 用户调整窗口尺寸可保存", "缺少保存窗口变化的入口")
		return
	state.call("remember_window_size", Vector2i(1100, 620))
	var cfg := ConfigFile.new()
	var loaded := cfg.load(TMP_CFG) == OK
	var saved: Variant = cfg.get_value("display", "window_size", Vector2i.ZERO) if loaded else Vector2i.ZERO
	_check(saved == Vector2i(1100, 620), "T-W6 调整窗口后尺寸写入 settings.cfg", str(saved))
	var connections := root.size_changed.get_connections()
	var wired := false
	for item in connections:
		if item["callable"].get_object() == state:
			wired = true
	_check(wired, "T-W6 窗口尺寸变化已接线到 GameState")


# ---------------------------------------------------------------- 关卡枚举
func _t_levels(state: Node) -> void:
	if not state.has_method("enumerate_level_names"):
		_check(false, "T-P0 GameState 暴露 enumerate_level_names", "没法不碰文件系统地问它枚举到了什么")
		return
	var names: PackedStringArray = state.call("enumerate_level_names")
	_check(names.size() == 5, "T-P1 枚举到 5 个关卡资源", "实际 %d：%s" % [names.size(), str(names)])
	var all_tres := true
	var any_remap := false
	for n in names:
		if not str(n).ends_with(".tres"):
			all_tres = false
		if str(n).ends_with(".remap"):
			any_remap = true
	_check(all_tres and not any_remap, "T-P1 名字都以 .tres 结尾且不含 .remap", str(names))
	var cnt: int = state.call("level_count")
	_check(cnt == 5, "T-P1 level_count()==5（编辑器内行为不回退）", "实际 %d" % cnt)
	var loadable := 0
	for n in names:
		var res := load("%s/%s" % [LEVEL_DIR, n])
		if res is LevelConfig:
			loadable += 1
	_check(loadable == 5, "T-P1 5/5 名字都能 load 成 LevelConfig", "实际 %d" % loadable)

	if not state.has_method("filter_level_names"):
		_check(false, "T-P0 GameState 暴露 filter_level_names", "负对照要用")
		return
	var dirty: PackedStringArray = state.call("filter_level_names", PackedStringArray([
		"level_1.tres.remap", "level_2.tres.remap", "level_3.tres.remap",
		"level_4.tres.remap", "level_5.tres.remap"]))
	_check(dirty.size() == 0, "T-P2 负对照：DirAccess 那种 .remap 名字一个都不留", str(dirty))


# ---------------------------------------------------------------- 菜单 UI
func _t_menu_ui() -> void:
	var packed := load(MENU_SCENE) as PackedScene
	if packed == null:
		_check(false, "T-U0 菜单场景可以实例化", "load(%s) 失败" % MENU_SCENE)
		return
	var menu := packed.instantiate()
	root.add_child(menu)
	# 布局要等一帧：_ready 里刚 add_child 完，Control 的 global_rect 还没算出来
	await process_frame
	var btn := _find_button(menu, "FPS")
	if btn == null:
		_check(false, "T-U1 菜单里能找到帧率按钮", "没找到 text 含 FPS 的 Button")
		menu.queue_free()
		return
	_check(btn.is_visible_in_tree(), "T-U1 帧率按钮可见")
	var gr := btn.get_global_rect()
	_check(Rect2(0, 0, 1280, 720).encloses(gr), "T-U2 帧率按钮完整落在 1280×720 逻辑画布内", str(gr))
	_check(btn.focus_mode == Control.FOCUS_ALL, "T-U3 帧率按钮可聚焦", str(btn.focus_mode))
	_check(_focus_reachable(menu, btn), "T-U3 沿焦点链能从第一个控件走到帧率按钮（菜单可达）")
	menu.queue_free()


func _find_button(n: Node, needle: String) -> Button:
	for c in n.get_children():
		if c is Button and (c as Button).text.contains(needle):
			return c as Button
		var deep := _find_button(c, needle)
		if deep != null:
			return deep
	return null


## 从菜单第一个可聚焦控件出发沿 find_next_valid_focus 走，看能不能走到 target。
## 为什么用焦点链而不是"数子节点"：真正决定玩家按 ↓ 能不能按到的是焦点链，
## 节点树顺序只是它的一个代理 —— 一旦有人设了 explicit neighbor，两者就分叉了。
func _focus_reachable(n: Node, target: Control) -> bool:
	var first := _first_focusable(n)
	if first == null or not first.has_method("find_next_valid_focus"):
		return false
	var cur: Control = first
	for _i in range(40):
		if cur == target:
			return true
		var nxt: Control = cur.call("find_next_valid_focus")
		if nxt == null or nxt == cur:
			break
		cur = nxt
	return cur == target


func _first_focusable(n: Node) -> Control:
	for c in n.get_children():
		if c is Control and (c as Control).focus_mode != Control.FOCUS_NONE:
			return c as Control
		var deep := _first_focusable(c)
		if deep != null:
			return deep
	return null


# ---------------------------------------------------------------- 收尾
func _cleanup() -> void:
	var abs_path := ProjectSettings.globalize_path(TMP_CFG)
	if FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)


func _check(ok: bool, name: String, detail := "") -> void:
	if ok:
		_pass += 1
		print("  ✔ %s" % name)
	else:
		_fail += 1
		print("  ✘ %s   %s" % [name, detail])


func _finish() -> void:
	print("CASES: %d  PASS: %d  FAIL: %d" % [_pass + _fail, _pass, _fail])
	if _fail == 0:
		print("RELEASE_SETTINGS_PASS")
		quit(0)
		return
	print("RELEASE_SETTINGS_FAIL")
	quit(1)
