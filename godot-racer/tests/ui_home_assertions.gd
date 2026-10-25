extends RefCounted

var _root: Window
var _state: Node
var _report: Callable


func setup(root: Window, state: Node, report: Callable) -> void:
	_root = root
	_state = state
	_report = report


func run() -> void:
	var menu: Control = load("res://scripts/menu.gd").new()
	menu.set("suppress_scene_change", true)
	_root.add_child(menu)
	var home: Control = menu.get("_home")
	_check("HOME-01", home != null and home.visible and not bool(menu.get("_stage").visible), "启动显示独立首页而非选关")
	if home == null:
		for id in ["HOME-02", "HOME-03", "HOME-04", "HOME-05", "HOME-06"]:
			_check(id, false, "独立首页尚未实现")
		menu.free()
		return
	var controls: Array = home.call("controls")
	_check_artwork(home)
	_check("HOME-01", controls.size() == 5 and home.find_child("HomeMusicButton", true, false) != null,
		"四入口与音乐开关，独立3D展示")
	_check("HOME-05", controls[0].has_focus(), "默认开始焦点")
	for i in range(controls.size()):
		_check("HOME-05", controls[i].get_node(controls[i].focus_next) == controls[(i + 1) % controls.size()], "首页焦点环%d" % i)
	_check("HOME-06", home.find_child("HomeLevelCount", true, false).text == "%d 条赛道 · 从选关开始" % int(_state.call("level_count")), "只显示真实关卡数量")
	controls[0].pressed.emit()
	_check("HOME-02", not home.visible and bool(menu.get("_stage").visible)
		and menu.get("_selected_idx") == -1 and menu.get("enter_requests") == 0, "开始只进入空态选关，不进入赛道")
	menu.find_child("BackHomeButton", true, false).pressed.emit()
	_check("HOME-02", home.visible and not bool(menu.get("_stage").visible), "选关返回首页")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	for i in [1, 2]:
		controls[i].pressed.emit()
		var overlay: Control = menu.get("_overlay")
		_check("HOME-03", overlay != null and overlay.is_visible_in_tree(), "首页可见弹层%d" % i)
		menu.call("_unhandled_input", esc)
		_check("HOME-03", menu.get("_overlay") == null and controls[i].has_focus(), "ESC关弹层恢复首页焦点%d" % i)
	controls[3].grab_focus()
	controls[3].pressed.emit()
	_check("HOME-04", _state.call("phase_name") == "EXIT_CONFIRM", "首页真实退出确认")
	_state.call("cancel_exit")
	menu.call("_process", 0.0)
	_check("HOME-04", _state.call("phase_name") == "MENU" and controls[3].has_focus(), "取消恢复首页退出焦点")
	controls[0].pressed.emit()
	menu.call("_unhandled_input", esc)
	_check("HOME-04", home.visible and _state.call("phase_name") == "MENU", "选关ESC返回首页")
	home.set_anchors_preset(Control.PRESET_TOP_LEFT)
	for dimensions in [Vector2(1366, 705), Vector2(1920, 1080)]:
		home.size = dimensions
		home.resized.emit()
		var stage: Control = home.call("overlay_host")
		var bounds := Rect2(Vector2.ZERO, dimensions)
		for control in stage.get_children():
			if control is Control and control.visible and not control.is_queued_for_deletion():
				var rect := Rect2(stage.position + control.position * stage.scale, control.size * stage.scale)
				_check("HOME-05", bounds.encloses(rect), "%s边界 %s" % [str(dimensions), control.name])
	menu.free()
	var empty: Control = load("res://scripts/homepage.gd").new()
	empty.setup(0)
	_root.add_child(empty)
	var empty_controls: Array = empty.call("controls")
	_check("HOME-06", empty_controls.size() == 5 and empty_controls[0].disabled
		and not empty_controls[1].disabled and not empty_controls[2].disabled and not empty_controls[3].disabled
		and empty.find_child("HomeLevelCount", true, false).text == "暂无可用赛道", "零关卡禁用开始，其余入口可用")
	empty.free()


func _check_artwork(home: Control) -> void:
	# INT-03获批将静态PNG改为真实3D；旧判据完整保存于int-legacy-ui-home-assertions.gd.txt。
	var display := home.find_child("HomeCarShowcase", true, false) as Control
	_check("HOME-07", display != null, "首页展示真实3D车辆")
	if display == null:
		_check("HOME-08", false, "隔离展示尚未接入")
		_check("HOME-09", false, "展示区域尚未接入")
		return
	var view: SubViewport = display.get("viewport")
	_check("HOME-07", not display.find_children("*", "MeshInstance3D", true, false).is_empty(), "展示模型非空")
	_check("HOME-08", view.own_world_3d and view.transparent_bg
		and not view.audio_listener_enable_3d and display.focus_mode == Control.FOCUS_NONE,
		"独立世界透明背景且不抢键盘焦点")
	_check("HOME-09", display.position == Vector2(460, 82) and display.size == Vector2(874, 510), "保留展示区域")
	_check("HOME-10", display.call("model_fits_view"), "完整模型在安全边界内")
	var podium := display.find_child("PodiumRoot3D", true, false)
	_check("HOME-10", podium is Node3D and podium.find_child("TopTier", true, false) is MeshInstance3D,
		"真实圆台与赛车脚下顶台面存在")
	_check("HOME-10", _isolated_pick_world(display, view), "专用拾取层隔离，不加载比赛物理")
	var bodies := display.find_children("*", "PhysicsBody3D", true, false)
	if bodies.size() == 1:
		var body := bodies[0] as StaticBody3D
		if body != null:
			var original_mask := body.collision_mask
			body.collision_mask = 1
			_check("HOME-10", not _isolated_pick_world(display, view), "隔离判据拒绝参与比赛碰撞的mask")
			body.collision_mask = original_mask
			var original_layer := body.collision_layer
			body.collision_layer = 1
			_check("HOME-10", not _isolated_pick_world(display, view), "隔离判据拒绝普通物理层")
			body.collision_layer = original_layer


func _isolated_pick_world(display: Control, view: SubViewport) -> bool:
	var bodies := display.find_children("*", "PhysicsBody3D", true, false)
	var shapes := display.find_children("*", "CollisionShape3D", true, false)
	if not view.own_world_3d or bodies.size() != 1 or shapes.is_empty():
		return false
	var body := bodies[0] as StaticBody3D
	if body == null or body.get_script() != null or body.collision_layer != (1 << 19) or body.collision_mask != 0:
		return false
	if not view.is_ancestor_of(body) or body.get_world_3d() != view.find_world_3d() or body.get_world_3d() == _root.find_world_3d():
		return false
	for shape in shapes:
		if shape.get_parent() != body or shape.disabled or not shape.shape is ConcavePolygonShape3D:
			return false
	return true


func _check(id: String, ok: bool, detail: String) -> void:
	_report.call(id, ok, detail)
