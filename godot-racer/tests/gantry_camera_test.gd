extends SceneTree
## GANTRY-L4-002: real L4/main/third-person projection at the starting grid.
## Machine evidence only; does not replace user visual acceptance.

var _game: Node
var _view: SubViewport
var _passed := 0
var _failed := 0
var _out := "res://../godot-logs/gantry-l4-002"
var _export_model := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--gantry-out="):
			_out = arg.get_slice("=", 1)
		if arg == "--gantry-export-model":
			_export_model = true
	create_timer(90.0, true).timeout.connect(func(): quit(2))
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
	print("GANTRY_CAMERA %s %s" % ["PASS" if ok else "FAIL", message])

func _run() -> void:
	var state := root.get_node("GameState")
	state.set("settings_path", ProjectSettings.globalize_path(_out + "-settings.cfg"))
	state.set("chosen_level", 3)
	_view = SubViewport.new()
	_view.size = Vector2i(1366, 705)
	_view.own_world_3d = true
	_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_view)
	_game = load("res://scenes/main.tscn").instantiate()
	_view.add_child(_game)
	for i in range(1500):
		await process_frame
		if bool(_game.get("_setup_done")):
			break
	_check(bool(_game.get("_setup_done")), "real L4 setup ready")
	if not bool(_game.get("_setup_done")):
		quit(2)
		return
	paused = true
	var camera := _game.get_node("ChaseCamera") as Camera3D
	camera.call("set_view_mode", 2)
	camera.call("_update_camera", 0.0, true)
	var module := _game.get("_start_gantry") as Node3D
	var gate := module.get_node("StartGantry") as Node3D
	if _export_model:
		var document := GLTFDocument.new()
		var gltf_state := GLTFState.new()
		var append_error := document.append_from_scene(gate, gltf_state)
		_check(append_error == OK, "assembled gate export prepared")
		if append_error == OK:
			var export_path := ProjectSettings.globalize_path(_out + "-assembled.glb")
			_check(document.write_to_filesystem(gltf_state, export_path) == OK, "assembled gate GLB saved")
	for size in [Vector2i(1366, 705), Vector2i(1280, 720), Vector2i(1920, 1080)]:
		_view.size = size
		await process_frame
		await RenderingServer.frame_post_draw
		var rect := Rect2()
		var first := true
		var behind := false
		for mesh in gate.find_children("*", "MeshInstance3D", true, false):
			var m := mesh as MeshInstance3D
			if not m.is_visible_in_tree():
				continue
			var box := m.mesh.get_aabb()
			for k in range(8):
				var point := m.global_transform * box.get_endpoint(k)
				behind = behind or camera.is_position_behind(point)
				var uv := camera.unproject_position(point)
				if first:
					rect = Rect2(uv, Vector2.ZERO)
					first = false
				else:
					rect = rect.expand(uv)
		_check(not first and not behind, "%s gate meshes in front of camera" % size)
		_check(Rect2(Vector2.ZERO, Vector2(size)).encloses(rect),
			"%s entire gate projected inside frame: %s" % [size, rect])
		var path := ProjectSettings.globalize_path("%s-%dx%d.png" % [_out, size.x, size.y])
		var error := _view.get_texture().get_image().save_png(path)
		_check(error == OK, "%s screenshot saved" % size)
	_game.queue_free()
	paused = false
	await process_frame
	_view.queue_free()
	await process_frame
	print("GANTRY_CAMERA_SUMMARY PASS=%d FAIL=%d" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
