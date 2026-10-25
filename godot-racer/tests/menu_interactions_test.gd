extends SceneTree
## 秒级真实控件实例；自动输入不代表真人体验。--interaction=selection|showcase|music

var _state: Node
var _pass := 0
var _fail := 0
var _kind := "selection"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--interaction="):
			_kind = arg.get_slice("=", 1)
	call_deferred("_run")


func _check(ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("INT_%s %s %s" % [_kind, "PASS" if ok else "FAIL", detail])


func _run() -> void:
	_state = root.get_node("GameState")
	_state.settings_path = ProjectSettings.globalize_path("res://../godot-logs/interaction-settings.cfg")
	match _kind:
		"selection": await _selection()
		"showcase": await _showcase()
		"music": await _music()
	var music := _state.find_child("MenuMusic", false, false)
	if music != null:
		_check(await music.call("shutdown_and_wait"), "菜单音频退出前实际回收")
	print("INTERACTION_DONE KIND=%s PASS=%d FAIL=%d" % [_kind, _pass, _fail])
	quit(0 if _fail == 0 else 1)


func _menu() -> Control:
	var menu: Control = load("res://scripts/menu.gd").new()
	menu.suppress_scene_change = true
	root.add_child(menu)
	return menu


func _selection() -> void:
	var menu := _menu()
	menu.call("_show_level_select")
	await process_frame
	var cards: Array = menu.get("_buttons")
	_check(menu.get("_selected_idx") == -1 and cards[0].has_focus()
		and menu.find_child("StartButton", true, false).disabled, "默认空态与焦点分离")
	for i in range(cards.size()):
		menu.call("_on_level_focus", i)
		var card: Button = cards[i]
		var normal := card.get_theme_stylebox("normal") as StyleBoxFlat
		var focus := card.get_theme_stylebox("focus") as StyleBoxFlat
		_check(normal.border_color.is_equal_approx(Color("7fb3e8")), "统一选中颜色%d" % i)
		_check(focus.border_width_left == 1 and focus.border_color.is_equal_approx(Color("f3f6fa"))
			and focus.expand_margin_left < 0, "独立内缩焦点%d" % i)
		var badge := card.find_child("SelectedBadge", true, false) as Label
		_check(badge != null and badge.visible and badge.text == "已选择", "明确选中标记%d" % i)
		for j in range(cards.size()):
			var other := cards[j].find_child("SelectedBadge", true, false) as Label
			_check(other != null and other.visible == (j == i), "仅一张选中%d/%d" % [i, j])
	var slider := menu.find_child("SpeedSlider", true, false) as HSlider
	_check(slider.min_value == 80 and slider.max_value == 240 and slider.step == 5, "数值范围步长不变")
	var minimum := menu.find_child("SpeedMinimum", true, false) as Label
	var maximum := menu.find_child("SpeedMaximum", true, false) as Label
	_check(minimum != null and minimum.text == "80 km/h" and maximum != null
		and maximum.text == "240 km/h", "显示两端真实范围")
	_check(slider.has_theme_stylebox_override("slider") and slider.has_theme_stylebox_override("grabber_area")
		and slider.has_theme_icon_override("grabber"), "完整轨道填充与滑块样式")
	for value in [80, 85, 235, 240]:
		slider.value = value
		_check(_state.max_speed_kmh == value and str(value) in menu.find_child("SpeedValue", true, false).text,
			"调速端点及一步%d" % value)
	slider.value = 80
	slider.grab_focus()
	var arrow := InputEventKey.new()
	arrow.keycode = KEY_RIGHT
	arrow.physical_keycode = KEY_RIGHT
	arrow.pressed = true
	root.push_input(arrow)
	await process_frame
	_check(slider.value == 85, "原生键盘右键增加一步")
	var hit := InputEventMouseButton.new()
	hit.button_index = MOUSE_BUTTON_LEFT
	hit.pressed = true
	hit.position = slider.get_global_rect().position + Vector2(slider.get_global_rect().size.x - 1, 14)
	hit.global_position = hit.position
	var pointer := InputEventMouseMotion.new()
	pointer.position = hit.position
	pointer.global_position = hit.position
	root.push_input(pointer)
	await process_frame
	root.push_input(hit)
	await process_frame
	_check(slider.value == 240, "真实鼠标点击滑条右端达到最大值 actual=%f hit=%s rect=%s" % [
		slider.value, str(hit.position), str(slider.get_global_rect())])
	hit = hit.duplicate()
	hit.pressed = false
	root.push_input(hit)
	menu.call("_show_empty_selection")
	_check(not slider.editable and not slider.visible, "未选关禁止调速")
	menu.free()


func _showcase() -> void:
	var menu := _menu()
	var home: Control = menu.get("_home")
	var display := home.find_child("HomeCarShowcase", true, false) as Control
	_check(display != null, "接入真实3D展车")
	if display == null:
		menu.free()
		return
	# 这些原断言检查稳态；不跳过或改写入场演出，等待真实时间线结束。
	var intro: Node = display.get("_intro")
	var intro_deadline := Time.get_ticks_msec() + 5000
	while intro != null and intro.get("running") and Time.get_ticks_msec() < intro_deadline:
		await process_frame
	_check(intro != null and not intro.get("running"), "入场完成后开始旧稳态交互契约")
	await process_frame
	display.call("set_suspended", false)
	display.set("_pointer", Vector2(-1, -1))
	await physics_frame
	await physics_frame
	print("SHOWCASE_STEADY focus=%s suspended=%s intro=%s" % [
		display.get("_focused"), display.get("suspended"), intro.get("running") if intro != null else "missing"])
	_check(display.get("_focused") and not display.get("suspended"), "稳态交互前焦点与暂停前置条件有效")
	var angle: float = display.get("angle")
	display.call("_process", 1.0)
	_check(is_equal_approx(display.get("angle") - angle, deg_to_rad(10)), "计划初值一秒自动旋转10度")
	await physics_frame
	await physics_frame
	var hit_point := Vector2(-1, -1)
	for y in range(80, 430, 20):
		for x in range(80, 800, 20):
			if not display.call("pick_car", Vector2(x, y)).is_empty():
				hit_point = Vector2(x, y)
	_check(hit_point.x > 0, "真实射线找到汽车轮廓")
	display.set("_pointer", hit_point)
	display.call("_physics_process", 0.0)
	angle = display.get("angle")
	display.call("_process", 1.0)
	_check(is_equal_approx(display.get("angle"), angle), "hover保持当前角度")
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = hit_point
	display.call("_gui_input", down)
	display.call("_physics_process", 0.0)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(100 * display.get_global_transform().get_scale().x, 0)
	display.call("_input", motion)
	_check(is_equal_approx(display.get("angle") - angle, deg_to_rad(30)), "拖动移出后仍旋转30度")
	angle = display.get("angle")
	display.call("_process", 1.0)
	_check(is_equal_approx(display.get("angle"), angle), "拖拽移出不恢复自转")
	down.pressed = false
	display.call("_input", down)
	_check(display.get("dragging") == false, "区域外松开可靠结束拖动")
	display.set("_pointer", Vector2(-1, -1))
	display.call("_physics_process", 0.0)
	display.call("_process", 0.35)
	display.call("_process", 1.0)
	_check(is_equal_approx(display.get("angle") - angle, deg_to_rad(10)), "松开等待后从当前角度继续")
	var view: SubViewport = display.get("viewport")
	_check(view.own_world_3d and not view.audio_listener_enable_3d, "隔离展示世界且无音频监听")
	var isolated := true
	for body in display.find_children("*", "PhysicsBody3D", true, false):
		isolated = isolated and body.collision_layer == (1 << 19) and body.collision_mask == 0
	_check(isolated and not display.find_children("*", "CollisionShape3D", true, false).is_empty(),
		"专用拾取层不参与比赛物理碰撞")
	for degree in range(0, 360, 30):
		display.call("set_angle", deg_to_rad(degree))
		_check(display.call("model_fits_view"), "完整车体旋转边界%d" % degree)
	menu.call("_open_overlay", "help", home.controls()[2])
	_check(display.get("suspended") and view.render_target_update_mode == SubViewport.UPDATE_DISABLED, "弹层停止旋转渲染")
	display.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	display.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(display.get("suspended") and view.render_target_update_mode == SubViewport.UPDATE_DISABLED, "焦点恢复不能越过弹层暂停")
	menu.call("_close_overlay")
	_check(not display.get("suspended"), "关弹层恢复展示")
	display.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(not display.get("dragging") and display.get("suspended"), "失焦取消交互与渲染")
	display.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	menu.call("_show_level_select")
	display.call("_process", 0.0)
	_check(view.render_target_update_mode == SubViewport.UPDATE_DISABLED, "离开首页停止渲染")
	menu.free()


func _music() -> void:
	var seeded := ConfigFile.new()
	seeded.set_value("display", "render_fps", 120)
	seeded.set_value("display", "window_size", Vector2i(1366, 705))
	seeded.set_value("audio", "menu_bgm_enabled", true)
	seeded.save(_state.settings_path)
	var menu := _menu()
	var music: Node = menu.get("_music")
	_check(music != null, "菜单有真实BGM模块")
	if music == null:
		menu.free()
		return
	var home: Control = menu.get("_home")
	var button := home.find_child("HomeMusicButton", true, false) as Button
	_check(button != null, "首页可关闭BGM")
	_check(music.get("_player").stream is AudioStreamOggVorbis, "真实OGG/Vorbis资源")
	_check(music.get("_player").stream.get_length() >= 20, "非空循环音乐")
	music.call("set_enabled", true)
	music.call("_process", 1.0)
	var player: AudioStreamPlayer = music.get("_player")
	_check(player.playing, "菜单真实播放")
	await create_timer(0.12, true, false, true).timeout
	player.seek(player.stream.get_length() - 0.08)
	# 对实际音频线程做有上限的状态等待；固定时刻查询曾落在尾部缓冲区。
	var deadline := Time.get_ticks_msec() + 2000
	while player.get_stream_playback().get_loop_count() < 1 and Time.get_ticks_msec() < deadline:
		await create_timer(0.02, true, false, true).timeout
	_check(player.playing and player.get_stream_playback().get_loop_count() >= 1,
		"实际跨越OGG尾部自动循环 loops=%d position=%f driver=%s latency=%f loop=%s" % [
			player.get_stream_playback().get_loop_count(), player.get_playback_position(), AudioServer.get_driver_name(),
			AudioServer.get_output_latency(), player.stream.loop])
	# 独立解码器从同一尾部混合出超过尾长的非静音PCM；不影响上面的设备播放断言。
	var decoder: AudioStreamPlayback = player.stream.instantiate_playback()
	decoder.start(player.stream.get_length() - 0.08)
	var decoded := decoder.mix_audio(1.0, 22050)
	var energy := 0.0
	for sample in decoded:
		energy += sample.length_squared()
	_check(decoded.size() == 22050 and decoder.get_loop_count() >= 1 and energy > 1.0,
		"独立Vorbis解码跨尾输出非静音PCM loops=%d energy=%f" % [decoder.get_loop_count(), energy])
	decoder.stop()
	var player_id := player.get_instance_id()
	menu.call("_show_level_select")
	music.call("_process", 0.1)
	_check(player.get_instance_id() == player_id and player.playing, "切页连续单实例播放")
	_state.call("request_exit")
	music.call("_process", 0.0)
	_check(not player.playing, "退出确认提前停播释放音频")
	_state.call("cancel_exit")
	music.call("_process", 1.0)
	_check(player.playing, "取消退出恢复菜单音乐")
	menu.call("_show_home")
	button.pressed.emit()
	_check(not music.get("enabled") and not player.playing, "首页关闭立即停播")
	var cfg := ConfigFile.new()
	cfg.load(_state.settings_path)
	_check(cfg.get_value("audio", "menu_bgm_enabled", true) == false, "关闭状态持久化")
	_check(cfg.get_value("display", "render_fps") == 120
		and cfg.get_value("display", "window_size") == Vector2i(1366, 705), "保存音乐偏好保留原显示设置")
	menu.call("_open_overlay", "settings", home.controls()[1])
	var overlay: Control = menu.get("_overlay")
	var toggle := overlay.find_child("MusicButton", true, false) as Button
	_check(toggle != null and toggle.text == "背景音乐：关闭", "设置共享状态")
	if toggle != null:
		toggle.pressed.emit()
		_check(music.get("enabled") and button.text == "背景音乐：开启", "设置开关同步首页")
	menu.call("_close_overlay")
	music.call("_process", 1.0)
	_state.phase = _state.Phase.LOADING
	music.call("_process", 0.2)
	_check(player.playing and player.volume_db < -22, "入赛淡出")
	music.call("_process", 0.2)
	_check(not player.playing, "淡出后停止")
	_state.call("enter_menu")
	music.call("_process", 1.0)
	_check(player.playing, "返回菜单按设置恢复")
	music.call("set_enabled", false)
	menu.free()
	var fresh := _menu()
	_check(fresh.get("_music").get_instance_id() == music.get_instance_id()
		and not player.playing, "重进首页不叠加不擅自开启")
	fresh.free()
	var restarted: Node = load("res://scripts/menu_music.gd").new()
	restarted.setup(_state)
	root.add_child(restarted)
	_check(not restarted.get("enabled"), "全新模块重启读取关闭偏好")
	restarted.free()
