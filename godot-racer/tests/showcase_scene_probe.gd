extends SceneTree
## 真实menu.tscn→main.tscn；不覆写路由，不装配AI，不代表驾驶或真人U验收。

var _mode := "level"
var _tag := "probe"
var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("SCENE_GENERATED_UID=", ResourceUID.id_to_text(ResourceUID.create_id()))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene-probe="): _mode = arg.get_slice("=", 1)
		if arg.begins_with("--tag="): _tag = arg.get_slice("=", 1)
	call_deferred("_run")


func _check(ok: bool, detail: String) -> void:
	if ok: _pass += 1
	else: _fail += 1
	print("SCENE_ASSERT %s %s" % ["PASS" if ok else "FAIL", detail])


func _run() -> void:
	var state := root.get_node("GameState")
	state.settings_path = ProjectSettings.globalize_path(
		"res://../godot-logs/showcase-capture-20261025/%s-settings.cfg" % _tag)
	_check(not state.ai_enabled, "真实--aioff已关闭对手")
	_check(change_scene_to_file("res://scenes/menu.tscn") == OK, "真实加载menu.tscn")
	var deadline := Time.get_ticks_msec() + 15000
	var main: Node
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if current_scene == null or current_scene.scene_file_path != "res://scenes/main.tscn": continue
		main = current_scene
		if main.get("_setup_done"): break
	_check(main != null and main.get("_setup_done"), "真实场景替换且赛道装配完成")
	if main == null:
		_finish()
		return
	_check(int(state.chosen_level) == (0 if _mode == "check" else 1), "实际装配目标关卡正确")
	_check(main.get_node_or_null("Track") != null and main.get_node_or_null("RaceCar") != null,
		"实际赛道及玩家节点存在")
	_check(main.get("_opponents").is_empty(), "实际对手数组为空")
	_check(root.find_children("HomeCarShowcase", "", true, false).is_empty(), "首页展台已随菜单释放")
	if _mode == "check":
		_check(main.get("_check") == "minimap", "实际检查解析进入minimap，继续由生产分派执行")
	else:
		_check(main.get("_check") == "", "普通CLI入口没有误进检查模式")
	print("SCENE_READY MODE=%s PASS=%d FAIL=%d path=%s phase=%s" % [
		_mode, _pass, _fail, main.scene_file_path, state.call("phase_name")])
	if _mode == "check" and _fail == 0: return # 生产检查自行输出完成标记并退出。
	paused = false
	var music := state.find_child("MenuMusic", false, false)
	if music != null: _check(await music.call("shutdown_and_wait"), "菜单BGM实际回收")
	current_scene = null
	main.free()
	await process_frame
	await process_frame
	_finish()


func _finish() -> void:
	print("SCENE_COMPLETE MODE=%s PASS=%d FAIL=%d" % [_mode, _pass, _fail])
	quit(0 if _fail == 0 else 1)
