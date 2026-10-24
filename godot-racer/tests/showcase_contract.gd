extends SceneTree
## 首页展台专项；真实物理射线与 Viewport 输入。自动操作不代表真人 U。

var _menu: Control
var _display: Control
var _state: Node
var _pass := 0
var _fail := 0
var _mode := "p0"
var _tag := "run"
var _size := Vector2i(1366, 705)
var _variant := "current"


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--case="): _mode = arg.get_slice("=", 1)
		if arg.begins_with("--tag="): _tag = arg.get_slice("=", 1)
		if arg.begins_with("--variant="): _variant = arg.get_slice("=", 1)
		if arg.begins_with("--size="):
			var parts := arg.get_slice("=", 1).split("x")
			_size = Vector2i(int(parts[0]), int(parts[1]))
	call_deferred("_run")


func _check(ok: bool, detail: String) -> void:
	if ok: _pass += 1
	else: _fail += 1
	print("SHOWCASE_ASSERT %s %s" % ["PASS" if ok else "FAIL", detail])


func _run() -> void:
	_state = root.get_node("GameState")
	_state.settings_path = ProjectSettings.globalize_path("res://../godot-logs/showcase-20261023/test-settings.cfg")
	root.size = _size
	_menu = load("res://scripts/menu.gd").new()
	_menu.suppress_scene_change = true
	root.add_child(_menu)
	_display = _menu.find_child("HomeCarShowcase", true, false)
	if _mode == "perf": print("SHOWCASE_PHASE scene_ready")
	if _variant == "original":
		var old := GDScript.new()
		old.source_code = FileAccess.get_file_as_string("res://../godot-logs/showcase-20261023/car_showcase.before.gd.txt")
		_check(old.reload() == OK, "历史展车脚本可加载")
		var parent := _display.get_parent()
		var rect := Rect2(_display.position, _display.size)
		_display.free()
		_display = old.new()
		_display.position = rect.position
		_display.size = rect.size
		parent.add_child(_display)
	if _variant == "no_shadows":
		for light in _display.get("_lights"): light.shadow_enabled = false
	if _variant == "no_pick":
		for body in _display.find_children("*", "PhysicsBody3D", true, false): body.free()
	await process_frame
	await process_frame
	if DisplayServer.get_name() != "headless": root.grab_focus()
	await create_timer(0.2).timeout
	_display.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	if _mode not in ["intro", "capture"] and "_intro" in _display and _display.get("_intro").running:
		if _mode == "perf": print("SHOWCASE_PHASE intro_wait")
		await _display.get("_intro").finished
		await process_frame # 不在finished信号发射栈内释放其所有者。
	if _mode == "perf":
		print("SHOWCASE_PHASE intro_settled")
		await _performance()
	elif _mode == "gaps":
		await _gaps()
	elif _mode == "art":
		await _art()
	elif _mode == "intro":
		await _intro_contract()
	elif _mode == "logo":
		await _logo_contract()
	elif _mode == "capture":
		await _capture()
	else:
		await _p0()
	var music := _state.find_child("MenuMusic", false, false)
	if music != null: music.shutdown()
	_menu.free()
	await create_timer(0.2, true, false, true).timeout
	print("SHOWCASE_COMPLETE CASE=%s PASS=%d FAIL=%d" % [_mode, _pass, _fail])
	quit(0 if _fail == 0 else 1)


func _motion(local: Vector2, relative := Vector2.ZERO) -> void:
	var event := InputEventMouseMotion.new()
	event.position = _display.get_global_transform_with_canvas() * local
	event.global_position = event.position
	event.relative = relative
	root.push_input(event)
	await physics_frame
	await process_frame
	await process_frame


func _p0() -> void:
	await create_timer(0.1).timeout
	await _motion(Vector2(15, 15))
	_check(not _display.hovered, "HIT-02 展示区空白不能冻结赛车")
	_check(_display.has_method("pick_car"), "HIT-01 必须使用真实车型射线")
	if not _display.has_method("pick_car"): return
	await _verify_hits()


func _verify_hits() -> void:
	var names := {}
	var attributed := true
	_check(_display.find_children("*", "PhysicsBody3D", true, false).size() == 1,
		"PICK-COST 共享一个拾取体，避免逐网格更新126个物理体")
	var hit_point := Vector2.ZERO
	for degrees in [0, 90, 180, 270]:
		_display.set_angle(deg_to_rad(degrees))
		await physics_frame
		await physics_frame
		var count := 0
		print("SHOWCASE_PICK_STATE focus=%s suspended=%s" % [_display.get("_focused"), _display.suspended])
		# 每个方向遍历屏幕网格，记录真实物理返回的网格归属。
		for y in range(40, 470, 18):
			for x in range(40, 840, 18):
				var point := Vector2(x, y) * _display.size / Vector2(874, 510)
				var hit: Dictionary = _display.pick_car(point)
				if hit.is_empty(): continue
				count += 1
				hit_point = point
				var visual: Node = hit.get("visual_mesh", hit.collider.get_parent())
				attributed = attributed and hit.get("visual_mesh") is MeshInstance3D
				names[visual.name] = true
		_check(count > 0, "HIT-01 真实车型命中 angle=%d samples=%d" % [degrees, count])
		_check(_display.model_fits_view(), "完整旋转包络 angle=%d" % degrees)
	print("SHOWCASE_HIT_MESHES ", names.keys())
	_check(attributed, "真实射线仍能追溯命中的可见网格部件")
	_check(names.size() >= 4, "命中多个真实网格部件")
	for part in ["Body", "Tire_Front_L", "Tire_Rear_L", "Wing_Main"]:
		_check(names.has(part), "HIT-01 部件命中 " + part)
	# 镜头近侧台沿是实际可见展台，而非控件空白或车体。
	var camera: Camera3D = _display.get("_camera")
	var bounds: AABB = _display.get("_bounds")
	var radius := 0.0
	for i in range(8):
		var corner := bounds.get_endpoint(i)
		radius = maxf(radius, Vector2(corner.x, corner.z).length())
	var near_direction := Vector3(camera.position.x, 0, camera.position.z).normalized()
	var rim_pixel := camera.unproject_position(near_direction * radius * 1.09 + Vector3(0, -0.03, 0))
	var rim_local := rim_pixel * _display.size / Vector2(_display.viewport.size)
	await _motion(rim_local)
	_check(not _display.hovered, "HIT-02 实体展台近侧台沿不冻结")
	await _button(rim_local, true)
	_check(not _display.dragging, "HIT-02 实体展台不能启动拖拽")
	await _button(rim_local, false)
	await _motion(hit_point)
	_check(_display.hovered, "真实输入命中进入HOVER")
	var frozen: float = _display.angle
	await create_timer(0.1).timeout
	_check(is_equal_approx(_display.angle, frozen), "HOVER自转冻结")
	await _button(hit_point, true)
	_check(_display.dragging, "HIT-04 真命中开始DRAG")
	await _motion(Vector2(-30, -30), Vector2(1500, 0) * _display.get_global_transform().get_scale().x)
	_check(_display.dragging and _display.angle > frozen + TAU, "移出区域仍可连续拖拽超过360度")
	await _button(Vector2(-30, -30), false)
	_check(not _display.dragging, "区域外松开结束DRAG")
	frozen = _display.angle
	await create_timer(0.15).timeout
	_check(is_equal_approx(_display.angle, frozen), "恢复前保留0.35秒等待")
	await create_timer(0.5).timeout
	_check(_display.angle > frozen, "等待后渐入AUTO")
	await _button(Vector2(15, 15), true)
	_check(not _display.dragging, "空白不能开始拖拽")
	await _button(Vector2(15, 15), false)
	var home: Control = _menu.get("_home")
	for kind in ["settings", "help"]:
		await _motion(hit_point)
		await _button(hit_point, true)
		_menu.call("_open_overlay", kind, home.controls()[1])
		_check(_display.suspended and not _display.dragging, "HIT-05 弹层阻断 " + kind)
		_menu.call("_close_overlay")
		await physics_frame
		_check(not _display.suspended, "关闭弹层恢复 " + kind)
	await _motion(hit_point)
	await _button(hit_point, true)
	_display.notification(Node.NOTIFICATION_WM_MOUSE_EXIT)
	_check(not _display.dragging and not _display.hovered, "移出窗口取消拖拽和旧悬停")
	_menu.call("_request_exit")
	_check(_display.suspended and not _display.dragging, "退出确认阻断输入")
	_state.cancel_exit()
	await process_frame
	await process_frame
	_check(not _display.suspended, "取消退出恢复输入")
	_display.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(_display.suspended and not _display.dragging, "失焦阻断")
	_display.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(not _display.suspended, "重新聚焦恢复")
	_menu.call("_show_level_select")
	await process_frame
	_check(_display.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "离开首页禁用展示渲染")
	_menu.call("_show_home")
	await process_frame
	_check(_display.viewport.render_target_update_mode == SubViewport.UPDATE_ALWAYS, "返回首页恢复展示")


func _button(local: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = _display.get_global_transform_with_canvas() * local
	event.global_position = event.position
	root.push_input(event)
	await physics_frame
	await process_frame
	await process_frame


func _performance() -> void:
	if _variant == "no_podium": _display.get("_podium").hide()
	if _variant == "reduced_viewport": _display.viewport.size = Vector2i(768, 448)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	# 入场结束后再请求焦点，避免启动时的焦点请求在演出期间失效。
	if DisplayServer.get_name() != "headless": root.grab_focus()
	await create_timer(0.2).timeout
	# 旧实现读真实鼠标位置；仅 push_input 不会移动系统指针。
	root.warp_mouse(Vector2(10, 10))
	await _motion(Vector2(-20, -20))
	print("SHOWCASE_PHASE warmup_start focused=%s suspended=%s" % [root.has_focus(), _display.suspended])
	await create_timer(3.0).timeout
	# 预热期间可能被系统切走；仅在采样前重获焦点，采样中不强制抢焦点。
	if DisplayServer.get_name() != "headless": root.grab_focus()
	await create_timer(0.2).timeout
	root.warp_mouse(Vector2(10, 10))
	await _motion(Vector2(-20, -20))
	print("SHOWCASE_PHASE sample_start focused=%s suspended=%s" % [root.has_focus(), _display.suspended])
	var samples: Array[float] = []
	var cpu: Array[float] = []
	var previous := Time.get_ticks_usec()
	var physics: Array[float] = []
	var inactive_frames := 0
	var rendered_before := Engine.get_frames_drawn()
	var angle_before: float = _display.angle
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if not root.has_focus() or _display.suspended or _display.viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
			inactive_frames += 1
		var now := Time.get_ticks_usec()
		samples.append((now - previous) / 1000.0)
		cpu.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		previous = now
	samples.sort()
	cpu.sort()
	physics.sort()
	print("SHOWCASE_PERF_STATE focused=%s suspended=%s inactive_frames=%d rendered_frames=%d angle_delta=%.4f" % [
		root.has_focus(), _display.suspended, inactive_frames, Engine.get_frames_drawn() - rendered_before,
		_display.angle - angle_before])
	_check(inactive_frames == 0 and not _display.suspended and root.has_focus(), "PERF-01 采样全程展车未停渲染且窗口有焦点")
	_check(Engine.get_frames_drawn() > rendered_before and absf(_display.angle - angle_before) > 0.1,
		"PERF-01 采样包含真实绘制和持续自转")
	print("SHOWCASE_PERF variant=%s size=%s samples=%d p50_ms=%.3f p95_ms=%.3f cpu_p50_ms=%.3f physics_p50_ms=%.3f bodies=%d adapter=%s renderer=%s" % [
		_variant, _size, samples.size(), samples[samples.size()/2], samples[int(samples.size()*0.95)], cpu[cpu.size()/2],
		physics[physics.size()/2], _display.find_children("*", "PhysicsBody3D", true, false).size(),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_method()])
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://../godot-logs/showcase-20261023/%s.png" % _tag)
	_check(root.get_texture().get_image().save_png(path) == OK, "SCREENSHOT " + path)


## 独立光栅轮廓判据：临时只渲染车模透明底，比较透明像素与物理命中。
## 不使用被测射线挑选“应该为空”的像素，避开抗锯齿边缘2像素。
func _gaps() -> void:
	if DisplayServer.get_name() == "headless":
		_check(false, "gaps 必须使用图形渲染")
		return
	_display.set_process(false)
	var podium := _display.find_child("ShowcasePlinth", true, false)
	if podium == null: podium = _display.find_child("PodiumRoot3D", true, false)
	if podium != null: podium.hide()
	var total_wheel_gaps := 0
	var total_wing_gaps := 0
	for degrees in [0, 90, 180, 270]:
		_display.set_angle(deg_to_rad(degrees))
		await physics_frame
		await physics_frame
		await RenderingServer.frame_post_draw
		var picture: Image = _display.viewport.get_texture().get_image()
		var gaps := 0
		var solid_hits := 0
		var wheel_gaps := 0
		var wing_gaps := 0
		var camera: Camera3D = _display.get("_camera")
		var pivot: Node3D = _display.get("_pivot")
		var front: MeshInstance3D = pivot.find_child("Tire_Front_L", true, false)
		var rear: MeshInstance3D = pivot.find_child("Tire_Rear_L", true, false)
		var wing: MeshInstance3D = pivot.find_child("Wing_Main", true, false)
		var airbox: MeshInstance3D = pivot.find_child("Airbox", true, false)
		var front_pixel := camera.unproject_position(front.global_transform * front.get_aabb().get_center())
		var rear_pixel := camera.unproject_position(rear.global_transform * rear.get_aabb().get_center())
		var wing_pixel := camera.unproject_position(wing.global_transform * wing.get_aabb().get_center())
		var body_pixel := camera.unproject_position(airbox.global_transform * airbox.get_aabb().get_center())
		var wheel_region := Rect2(front_pixel, rear_pixel-front_pixel).abs().grow(5)
		var wing_region := Rect2(wing_pixel, body_pixel-wing_pixel).abs().grow(5)
		var bounds: AABB = _display.get("_bounds")
		var rect := Rect2(camera.unproject_position(pivot.global_transform * bounds.position), Vector2.ZERO)
		for i in range(8): rect = rect.expand(camera.unproject_position(pivot.global_transform * bounds.get_endpoint(i)))
		for y in range(maxi(3, int(rect.position.y)), mini(picture.get_height()-3, int(rect.end.y)), 8):
			for x in range(maxi(3, int(rect.position.x)), mini(picture.get_width()-3, int(rect.end.x)), 8):
				var hit: Dictionary = _display.pick_car(Vector2(x,y) * _display.size / Vector2(picture.get_size()))
				if picture.get_pixel(x,y).a > 0.99 and not hit.is_empty(): solid_hits += 1
				var clear := true
				for offset in [Vector2i.ZERO, Vector2i(2,0), Vector2i(-2,0), Vector2i(0,2), Vector2i(0,-2)]:
					clear = clear and picture.get_pixelv(Vector2i(x,y)+offset).a < 0.01
				if not clear: continue
				gaps += 1
				if wheel_region.has_point(Vector2(x,y)): wheel_gaps += 1
				if wing_region.has_point(Vector2(x,y)): wing_gaps += 1
				if not hit.is_empty():
					_check(false, "HIT-03 透明轮廓误判 angle=%d pixel=%s" % [degrees, Vector2i(x,y)])
		_check(gaps > 20, "HIT-03 独立渲染间隙/空角落 angle=%d samples=%d" % [degrees,gaps])
		_check(solid_hits > 20, "光栅与射线正例防空跑 angle=%d samples=%d" % [degrees,solid_hits])
		total_wheel_gaps += wheel_gaps
		total_wing_gaps += wing_gaps
		print("SHOWCASE_VISIBLE_GAPS angle=%d wheel=%d wing=%d" % [degrees,wheel_gaps,wing_gaps])
	# 背向的缝隙可被可见实体遮住。只统计实际光栅为空的样本，逐像素零误判条件不变。
	_check(total_wheel_gaps > 0 and total_wing_gaps > 0,
		"轮间和尾翼均有可见负例 wheel=%d wing=%d" % [total_wheel_gaps,total_wing_gaps])
	if podium != null: podium.show()


func _art() -> void:
	var podium := _display.find_child("PodiumRoot3D", true, false) as Node3D
	_check(podium != null, "ART-01 独立三层实体展台")
	if podium == null: return
	for tier_name in ["BaseTier", "MiddleTier", "TopTier"]:
		var tier: MeshInstance3D = podium.find_child(tier_name, false, false)
		_check(tier != null and tier.mesh is CylinderMesh and tier.mesh.height >= 0.1
			and tier.mesh.radial_segments >= 16 and tier.mesh.radial_segments <= 24, "实体多边形层 " + tier_name)
	var pivot: Node3D = _display.get("_pivot")
	for wheel_name in ["Tire_Front_L", "Tire_Front_R", "Tire_Rear_L", "Tire_Rear_R"]:
		var wheel: MeshInstance3D = pivot.find_child(wheel_name, true, false)
		var box: AABB = pivot.global_transform.affine_inverse() * wheel.global_transform * wheel.get_aabb()
		_check(absf(box.position.y) < 0.025, "轮胎接触台面 " + wheel_name + " y=" + str(box.position.y))
	var fixed := podium.transform
	for degree in range(0,360,30):
		_display.set_angle(deg_to_rad(degree))
		_check(_display.model_fits_view() and podium.transform == fixed, "车转台不转且完整入镜 " + str(degree))
	_check(podium.find_children("*", "CollisionObject3D", true, false).is_empty(), "展台没有车型拾取碰撞")
	if DisplayServer.get_name() != "headless":
		_display.set_angle(0.0)
		await RenderingServer.frame_post_draw
		var path := ProjectSettings.globalize_path("res://../godot-logs/showcase-20261023/%s.png" % _tag)
		_check(root.get_texture().get_image().save_png(path) == OK, "SCREENSHOT " + path)


func _intro_contract() -> void:
	var intro: Node = _display.get("_intro") if "_intro" in _display else null
	_check(intro != null, "INTRO-01 独立入场时间线")
	if intro == null: return
	var lift: Node3D = _display.get("_lift")
	var car: Node3D = _display.get("_pivot")
	var home: Control = _menu.get("_home")
	_check(intro.running and lift.position.y < -0.2, "初次进入低位暗场")
	_check(not car.visible, "INTRO-01 初始不显示车辆，先显示展台")
	_check(home.get("_stage").modulate.a == 1.0 and not home.controls()[0].disabled,
		"第一帧左侧菜单可见可用")
	await _motion(Vector2(-20, -20))
	var start_angle: float = _display.angle
	var car_position: Vector3 = _display.get("_pivot").position
	var podium_transform: Transform3D = _display.get("_podium").transform
	await create_timer(0.45).timeout
	_check(lift.position.y > -0.9 and lift.position.y < 0.0, "升起中间帧")
	_check(not car.visible and is_equal_approx(_display.angle, start_angle), "INTRO-01 展台升起阶段车辆隐藏")
	_check(not intro.can_skip and _display.pick_car(_display.size * 0.5).is_empty(), "隐藏车辆不响应拾取或跳过")
	if DisplayServer.get_name() != "headless": await _save_frame("podium-first")
	await create_timer(0.65).timeout
	var vehicle_mesh: MeshInstance3D = car.find_children("*", "MeshInstance3D", true, false)[0]
	_check(is_zero_approx(lift.position.y) and car.visible and vehicle_mesh.transparency > 0.0
		and vehicle_mesh.transparency < 1.0, "INTRO-01 展台落定后车辆再渐显")
	_check(_display.angle - start_angle > 0.01 and intro.running, "车辆开始显现即自转，不等待2.5秒结束")
	_check(_display.get("_pivot").position == car_position and _display.get("_podium").transform == podium_transform,
		"入场保持车体落点和固定台体局部变换")
	if DisplayServer.get_name() != "headless": await _save_frame("car-appearing")
	await intro.finished
	_check(not intro.running and is_zero_approx(lift.position.y), "2.5秒落定")
	_check(car.visible and is_zero_approx(vehicle_mesh.transparency), "入场结束车辆恢复完整不透明")
	_check(intro.pulse_count == 1, "唯一能量脉冲")
	var fixed := lift.transform
	await create_timer(0.2).timeout
	_check(lift.transform == fixed, "待机不重复升降")
	for i in range(3):
		_menu.free()
		await process_frame
		_menu = load("res://scripts/menu.gd").new()
		_menu.suppress_scene_change = true
		root.add_child(_menu)
		_display = _menu.find_child("HomeCarShowcase", true, false)
		_display.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
		intro = _display.get("_intro")
		_check(intro.duration <= 0.4, "重进快速恢复 " + str(i))
		_check(root.find_children("HomeCarShowcase", "", true, false).size() == 1, "仅一个展台实例 " + str(i))
		# 入场时直接发出真实首页开始按钮的信号，不能等演出结束。
		_menu.get("_home").controls()[0].pressed.emit()
		_check(not _menu.get("_home").visible and not intro.running, "演出不阻塞开始且离场清理 " + str(i))


func _logo_contract() -> void:
	var podium: Node3D = _display.get("_podium")
	var logo := podium.find_child("TopSurfaceIcon", true, false) as MeshInstance3D
	_check(logo != null and podium.find_child("BrandPlaque", true, false) == null, "LOGO-01 顶面印记且无侧壁铭牌")
	if logo == null: return
	_check(logo.mesh is PlaneMesh and logo.mesh.size.x == logo.mesh.size.y, "Logo水平贴面且保持1比1")
	_check(logo.basis.y.is_equal_approx(Vector3.UP) and is_equal_approx(logo.position.y, 0.006), "Logo贴着赛车所在圆形顶面")
	var material := logo.material_override as StandardMaterial3D
	_check(material.albedo_texture.resource_path == "res://icon.svg", "直接复用原始SVG导入纹理")
	_check(material.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and is_equal_approx(material.albedo_color.a, 0.24), "Logo使用24%不透明度")
	var fixed := logo.global_transform
	_display.set_angle(PI)
	await physics_frame
	await physics_frame
	_check(logo.global_transform == fixed, "Logo不随赛车旋转")
	var camera: Camera3D = _display.get("_camera")
	# 选择没有被赛车挡住的印记像素；赛车本身覆盖的区域仍应能拖拽。
	var point := Vector2(-1, -1)
	for x in [-0.4, 0.4]:
		for z in [-0.4, 0.4]:
			var world_point := logo.to_global(Vector3(x * logo.mesh.size.x, 0, z * logo.mesh.size.y))
			var candidate := camera.unproject_position(world_point) * _display.size / Vector2(_display.viewport.size)
			if _display.pick_car(candidate).is_empty(): point = candidate
	_check(point.x >= 0, "找到未被赛车遮挡的台面印记区域")
	await _motion(point)
	_check(not _display.hovered, "悬停Logo不冻结赛车")
	await _button(point, true)
	_check(not _display.dragging, "Logo不启动拖拽")
	await _button(point, false)
	_check(not podium.find_child("PulseRing", false, false).visible, "落定后脉冲隐藏")
	if DisplayServer.get_name() != "headless": await _save_frame("top-mark")


func _capture() -> void:
	if DisplayServer.get_name() == "headless":
		_check(false, "capture必须实际渲染")
		return
	await _save_frame("dark")
	await create_timer(0.45).timeout
	await _save_frame("rising")
	await create_timer(0.6).timeout
	await _save_frame("lighting")
	await create_timer(0.5).timeout
	await _save_frame("pulse")
	if _display.get("_intro").running:
		await _display.get("_intro").finished
	await process_frame
	await _save_frame("idle")
	await physics_frame
	var point := Vector2(-1,-1)
	for y in range(80,440,12):
		for x in range(80,800,12):
			var hit: Dictionary = _display.pick_car(Vector2(x,y))
			if not hit.is_empty() and hit.get("visual_mesh", hit.collider.get_parent()).name == "Body": point = Vector2(x,y)
	_check(point.x > 0, "录像真实车型命中点")
	await _motion(point)
	await _button(point,true)
	_check(_display.dragging, "录像拖拽已启动")
	var start: float = _display.angle
	for i in range(45):
		await _motion(Vector2(890,300), Vector2(30,0)*_display.get_global_transform().get_scale().x)
		if i == 20: await _save_frame("drag")
	_check(_display.dragging and _display.angle-start > TAU, "录像持续旋转超过360度")
	await _button(Vector2(890,300),false)
	await create_timer(0.6).timeout
	_check(not _display.dragging and not _display.hovered, "录像松开恢复")
	await _save_frame("released")


func _save_frame(label: String) -> void:
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://../godot-logs/showcase-20261023/%s-%s.png" % [_tag,label])
	_check(root.get_texture().get_image().save_png(path) == OK, "SCREENSHOT " + path)
