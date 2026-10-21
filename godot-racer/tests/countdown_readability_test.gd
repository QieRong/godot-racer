extends SceneTree
## CD-READ-001：真实 main 自然倒计时、五关/分辨率由 runner 逐次传入。
## 截图为离屏 SubViewport；只验证机器契约，真人可读性另验。

const AudioExit := preload("res://tests/audio_exit_probe.gd")

var _game: Node
var _view: SubViewport
var _state: Node
var _level := 0
var _size := Vector2i(1280, 720)
var _ai := true
var _out := "res://../godot-logs/countdown-readability-20261021"
var _passed := 0
var _failed := 0
var _seen: Dictionary = {}
var _go_count := 0
var _initial_position := Vector3.ZERO
var _initial_ai: Array[Vector3] = []
var _max_displacement := 0.0
var _max_ai_displacement := 0.0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--read-level="):
			_level = int(arg.get_slice("=", 1))
		if arg.begins_with("--read-width="):
			_size = Vector2i(1920, 1080) if int(arg.get_slice("=", 1)) == 1920 else Vector2i(1280, 720)
		if arg == "--read-no-ai":
			_ai = false
		if arg.begins_with("--read-out="):
			_out = arg.get_slice("=", 1)
	create_timer(45.0, true).timeout.connect(func():
		print("READABILITY_TIMEOUT")
		quit(2))
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
	print("READABILITY %s %s" % ["PASS" if ok else "FAIL", message])


func _check_text(label: Label) -> void:
	_check(label.get_theme_color("font_color").is_equal_approx(Color("f3f6fa")),
		label.name + " uniform near-white text")
	_check(label.get_theme_constant("outline_size") >= 4
		and label.get_theme_color("font_outline_color").is_equal_approx(Color.BLACK),
		label.name + " opaque black outline >=4px")
	_check(label.get_theme_color("font_shadow_color").a >= 0.8
		and label.get_theme_constant("shadow_offset_y") >= 2,
		label.name + " visible offset shadow")
	_check(Rect2(Vector2.ZERO, Vector2(_size)).encloses(label.get_global_rect())
		and label.get_minimum_size().x <= label.size.x,
		label.name + " text fits viewport and label")


func _check_transparent(node: Node) -> bool:
	if node is ColorRect or node is Panel:
		return false
	if node is Control and node.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		return false
	for child in node.get_children():
		if not _check_transparent(child):
			return false
	return true


func _run() -> void:
	_state = root.get_node("GameState")
	_state.set("settings_path", ProjectSettings.globalize_path(_out + "-settings.cfg"))
	_state.set("chosen_level", _level)
	_state.set("ai_enabled", _ai)
	_view = SubViewport.new()
	_view.size = _size
	_view.own_world_3d = true
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_view)
	_game = load("res://scenes/main.tscn").instantiate()
	_view.add_child(_game)
	for i in range(1500):
		await process_frame
		if bool(_game.get("_setup_done")):
			break
	_check(bool(_game.get("_setup_done")), "real main setup")
	var cd: CanvasLayer = _game.get("_countdown")
	if cd == null:
		_check(false, "interactive countdown exists")
		quit(1)
		return
	cd.finished.connect(func(): _go_count += 1)
	var car: VehicleBody3D = _game.get("_car")
	_initial_position = car.global_position
	for opponent in _game.get("_opponents"):
		_initial_ai.append(opponent.global_position)
	_check(_check_transparent(cd), "transparent overlay and input pass-through")
	for i in range(1200):
		await process_frame
		var label: Label = cd.get("_label")
		var phase: String = _state.call("phase_name")
		if phase == "COUNTDOWN":
			_max_displacement = maxf(_max_displacement, car.global_position.distance_to(_initial_position))
			var opponents: Array = _game.get("_opponents")
			for j in range(opponents.size()):
				_max_ai_displacement = maxf(_max_ai_displacement,
					opponents[j].global_position.distance_to(_initial_ai[j]))
		if label.visible and not label.text.is_empty() and not _seen.has(label.text):
			_seen[label.text] = true
			_check_text(cd.get("_title"))
			_check_text(cd.get("_hint"))
			await RenderingServer.frame_post_draw
			var token := "go" if label.text == "出发！" else label.text
			var path := ProjectSettings.globalize_path("%s-l%d-%d-%s.png" % [_out, _level + 1, _size.x, token])
			_check(_view.get_texture().get_image().save_png(path) == OK, "screenshot " + token)
		if cd.get("_state") == "done":
			break
	_check(_seen.has("3") and _seen.has("2") and _seen.has("1") and _seen.has("出发！"),
		"natural 3/2/1/GO all observed")
	_check(_go_count == 1 and _state.call("phase_name") == "RACING" and not car.get("start_locked"),
		"single natural GO unlocks player and starts race")
	_check(_max_displacement < 0.001 and _max_ai_displacement < 0.001,
		"countdown player/AI held: %.6f/%.6f m" % [_max_displacement, _max_ai_displacement])
	var hint: Label = cd.get("_hint")
	_check(hint.text == ("玩家与 AI 已同时放行" if _ai else "计时已开始，开始你的练习"),
		"GO hint reflects AI setting")
	_check(not cd.get("_root").visible, "overlay hidden after GO hold")
	# 同时观测引擎与雨声；只看Generator会漏掉L3的Ogg异步退场。
	var receipt_ids := AudioExit.capture_tree(_game)
	_game.queue_free()
	paused = false
	await process_frame
	_view.queue_free()
	await process_frame
	_check(await AudioExit.wait_all_released(self, receipt_ids),
		"all scene audio playbacks reclaimed before process quit")
	print("READABILITY_SUMMARY LEVEL=%d WIDTH=%d AI=%s PASS=%d FAIL=%d" % [
		_level + 1, _size.x, str(_ai), _passed, _failed])
	quit(0 if _failed == 0 else 1)
