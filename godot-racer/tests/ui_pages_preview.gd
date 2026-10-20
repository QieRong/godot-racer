extends SceneTree
## 秒级UI离屏渲染；结算使用明确标记的合成测试快照，不是实赛证据。
## --script res://tests/ui_pages_preview.gd -- --ui-preview=menu|countdown|finish --ui-size=1920x1080
## 必须使用图形渲染器；不装配赛道。截图存godot-logs/ui-preview-*-fixture-*.png。

var _view: SubViewport
var _gs: Node
var _kind := "menu"
var _size := Vector2i(1366, 705)
var _elapsed := 0.0
var _scheduled := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ui-preview="):
			_kind = arg.get_slice("=", 1)
		if arg.begins_with("--ui-size="):
			var dims := arg.get_slice("=", 1).split("x")
			_size = Vector2i(int(dims[0]), int(dims[1]))
	call_deferred("_boot")


func _boot() -> void:
	_gs = root.get_node("GameState")
	_view = SubViewport.new()
	_view.size = _size
	_view.disable_3d = true
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_view)
	match _kind:
		"menu", "settings", "help":
			var menu: Control = load("res://scripts/menu.gd").new()
			_view.add_child(menu)
			if _kind != "menu":
				menu.call("_open_overlay", _kind, menu.find_child("SettingsButton", true, false))
		"countdown":
			_gs.call("prepare_race")
			_gs.call("enter_countdown")
			var countdown: CanvasLayer = load("res://scripts/start_countdown.gd").new()
			_view.add_child(countdown)
			countdown.set_process(false)
			countdown.call("_process", 0.0)
		"finish":
			_gs.set("phase", 5)
			_gs.set("finish_snapshot", {"laps": 2, "target": 2, "total": 82.5,
				"last": 42.0, "best": 40.0, "position": 1, "field_size": 2, "outcome": "win",
				"entrants": [{"rank": 1, "label": "玩家", "laps": 2, "finished": true, "id": "player"},
					{"rank": 2, "label": "AI#1", "laps": 1, "finished": false, "id": "ai1"}]})
			var finish: CanvasLayer = load("res://scripts/finish_menu.gd").new()
			finish.set("result", _gs.get("finish_snapshot").duplicate(true))
			_view.add_child(finish)


func _process(delta: float) -> bool:
	_elapsed += delta
	if _view != null and _elapsed >= 0.8 and not _scheduled:
		_scheduled = true
		RenderingServer.frame_post_draw.connect(_capture, CONNECT_ONE_SHOT)
	if _elapsed > 5.0:
		quit(2)
	return false


func _capture() -> void:
	var picture := _view.get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://../godot-logs/ui-preview-%s-fixture-%dx%d.png" % [_kind, _size.x, _size.y])
	var error := picture.save_png(path)
	print("UI_PREVIEW_SAVE=%d SIZE=%s PATH=%s" % [error, str(picture.get_size()), path])
	quit(0 if error == OK else 1)
