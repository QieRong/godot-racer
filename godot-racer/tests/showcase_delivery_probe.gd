extends SceneTree
## 最终首页三尺寸离屏渲染/真实CLI参数路由；不装配比赛，不代表真人U。

const ROUTE_SOURCE := "extends \"res://scripts/menu.gd\"\nvar route_calls := 0\nfunc _enter_game() -> void:\n\troute_calls += 1\n"

var _mode := "matrix"
var _tag := "probe"
var _pass := 0
var _fail := 0
var _state: Node
var _base: String


func _initialize() -> void:
	print("DELIVERY_GENERATED_UID=", ResourceUID.id_to_text(ResourceUID.create_id()))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--delivery="): _mode = arg.get_slice("=", 1)
		if arg.begins_with("--tag="): _tag = arg.get_slice("=", 1)
	call_deferred("_run")


func _check(ok: bool, detail: String) -> void:
	if ok: _pass += 1
	else: _fail += 1
	print("DELIVERY_ASSERT %s %s" % ["PASS" if ok else "FAIL", detail])


func _run() -> void:
	_state = root.get_node("GameState")
	_base = ProjectSettings.globalize_path("res://../godot-logs/showcase-delivery-20261025/" + _tag)
	_state.settings_path = _base + "-settings.cfg"
	if _mode == "matrix": await _matrix()
	else: await _cli()
	var music := _state.find_child("MenuMusic", false, false)
	if music != null: _check(await music.call("shutdown_and_wait"), "退出前菜单音频实际回收")
	print("DELIVERY_COMPLETE MODE=%s PASS=%d FAIL=%d" % [_mode, _pass, _fail])
	quit(0 if _fail == 0 else 1)


func _matrix() -> void:
	for dimensions in [Vector2i(1280, 720), Vector2i(1366, 705), Vector2i(1920, 1080)]:
		var view := SubViewport.new()
		view.size = dimensions
		view.disable_3d = true
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(view)
		var menu: Control = load("res://scripts/menu.gd").new()
		menu.suppress_scene_change = true
		view.add_child(menu)
		var home: Control = menu.get("_home")
		var display: Control = home.find_child("HomeCarShowcase", true, false)
		# 离屏夹具显式启用渲染；不把此状态冒充系统窗口前台焦点。
		display.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
		display.call("set_suspended", false)
		var intro: Node = display.get("_intro")
		var deadline := Time.get_ticks_msec() + 6000
		while intro.get("running") and Time.get_ticks_msec() < deadline:
			await process_frame
		_check(not intro.get("running"), "%s 真实入场已结束" % dimensions)
		var stable := 0
		deadline = Time.get_ticks_msec() + 6000
		while stable < 4 and Time.get_ticks_msec() < deadline:
			await RenderingServer.frame_post_draw
			var transparency := 0.0
			for mesh in display.get("_pivot").find_children("*", "MeshInstance3D", true, false):
				transparency = maxf(transparency, mesh.transparency)
			stable = stable + 1 if not intro.get("running") and transparency <= 0.001 else 0
			print("DELIVERY_RENDER_STATE size=%s intro=%s transparency=%f stable=%d" % [
				dimensions, intro.get("running"), transparency, stable])
			await process_frame
		_check(stable == 4, "%s 车网格不透明且连续四个渲染帧稳定" % dimensions)
		_check(home.visible and display.get("_pivot").visible and display.call("model_fits_view"),
			"%s 完整车辆已显示且在安全边界" % dimensions)
		var bounds := Rect2(Vector2.ZERO, Vector2(dimensions))
		var music_rect: Rect2 = home.find_child("HomeMusicButton", true, false).get_global_rect()
		var count_rect: Rect2 = home.find_child("HomeLevelCount", true, false).get_global_rect()
		_check(count_rect.position.y - music_rect.end.y >= 24.0,
			"%s 音乐开关与赛道说明至少24px留白，实际%.2fpx" % [dimensions, count_rect.position.y - music_rect.end.y])
		_check(bounds.encloses(count_rect) and count_rect.end.y <= dimensions.y - 16.0,
			"%s 赛道说明完整可见且底部保留16px安全距离" % dimensions)
		for control in home.controls():
			_check(control.visible and bounds.encloses(control.get_global_rect()),
				"%s 控件边界 %s" % [dimensions, control.name])
		var image := view.get_texture().get_image()
		_check(image.get_size() == dimensions, "%s 实际纹理尺寸" % dimensions)
		var minimum := 1.0
		var maximum := 0.0
		var rect := display.get_global_rect()
		for y in range(1, 16):
			for x in range(1, 24):
				var point := rect.position + rect.size * Vector2(x / 24.0, y / 16.0)
				var color := image.get_pixelv(Vector2i(point))
				var luminance := (color.r + color.g + color.b) / 3.0
				minimum = minf(minimum, luminance)
				maximum = maxf(maximum, luminance)
		_check(maximum - minimum > 0.1, "%s 展车区域存在真实渲染像素变化" % dimensions)
		var path := "%s-%dx%d-offscreen.png" % [_base, dimensions.x, dimensions.y]
		_check(image.save_png(path) == OK, "%s PNG保存成功" % dimensions)
		print("DELIVERY_IMAGE ", JSON.stringify({"size": str(dimensions), "path": path,
			"capture": "offscreen SubViewport; not OS window size", "range": maximum - minimum}))
		view.free()
		await process_frame


func _cli() -> void:
	# autoload注册完成后才编译继承菜单的夹具，避免提前解析GameState失败。
	var script := GDScript.new()
	script.source_code = ROUTE_SOURCE
	var compiled := script.reload() == OK
	_check(compiled, "场景切换边界夹具在autoload就绪后可编译")
	if not compiled: return
	var menu: Control = script.new()
	root.add_child(menu)
	var direct := _mode in ["check", "level"]
	_check((menu.get("_home") == null) == direct, "直连跳过首页；autostart先装配菜单")
	if not direct:
		_check(menu.route_calls == 0 and menu.get("_stage").visible, "autostart未提前进入，先显示选关")
	var deadline := Time.get_ticks_msec() + 4000
	while menu.route_calls == 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(menu.route_calls == 1, "真实参数入口恰好请求一次场景切换")
	_check(int(_state.get("chosen_level")) == (0 if _mode == "check" else 2), "CLI目标关卡正确")
	if not direct: _check(menu.enter_requests == 1, "autostart直接进入，不经过双击状态")
	print("DELIVERY_ROUTE boundary=before_change_scene mode=%s calls=%d level=%d" % [
		_mode, menu.route_calls, _state.get("chosen_level")])
	menu.free()
