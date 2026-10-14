extends RefCounted
## 环境物理验收族（`--check=weather` / `phys` / `friction` / `wallslide` / `stuck` / `flip`）：
## 天气粒子与环境对比度、物理步频开销测量、抓地力倍率是否真的进了物理、卡墙（怼墙能否继续开
## + 车尾穿模）、卡墙几何取证、翻车恢复（底朝天 / 合成腹部贴地 / 真实姿态复现 / 自动搜复现）。
## main.gd 的 `match _check:` 分发口经
## `await _checks_envphys.run_weather()` / `run_phys()` / `run_friction()` /
## `run_wallslide()` / `run_stuck()` / `run_flip()` 进入本模块；
## 另有 `probe_blocker()`（卡住取证，非分发入口）供卡住时调用。
##
## 2026-10-14 SPLIT-CHECKS-ENVPHYS-004：从 scenes/main.gd 整块拆出，**纯迁移、
## 行为零变化** —— 逻辑、print 文案（`[自检]` 前缀、缩进、✔/✘ 判定行、%占位顺序全部
## 照搬，A/B 要逐行比对日志）、注释全部照搬，没有第二份实现。
## 迁了什么：
##   · 6 个函数：`_check_weather` → 公开入口 `run_weather`、`_check_phys` → `run_phys`、
##     `_check_friction` → `run_friction`、`_check_wallslide` → `run_wallslide`、
##     `_check_stuck` → `run_stuck`、`_check_flip` → `run_flip`；`_probe_blocker`
##     → 公开 `probe_blocker`（非分发入口，供 `_check_lap` 卡住取证调用）；
##     私有 helper 保持原名与私有性：`_luminance` / `_friction_probe` /
##     `_visual_lateral_extent` / `_flip_state` / `_flip_case_inverted` /
##     `_flip_case_belly` / `_flip_case_hover` / `_flip_hunt_trial` /
##     `_report_hunt_finding` / `_flip_case_hunt`，逐一对应、可 audit；
##   · 6 个常量：`MIN_WEATHER_CONTRAST` / `BELLY_TEST_KMH` / `BELLY_TEST_SECONDS` /
##     `BELLY_ONSET` / `BELLY_RECOVER` / `FLIP_UPRIGHT_ANGLE`（check-docs.ps1 未登记、
##     非 ADR-001 永久居民，随族迁移；**不在此复制闸门登记的三 CASES 常量**）；
##   · 2 个模块级状态：`_flip_reproduced` / `_flip_fails`（本族原实现就有，随迁）。
##
## ⚠ 四处关键决策（逐条定死，以后别悄悄改回去）：
##
##   ① **车 / 赛道 / 环境 / 物理世界经 setup() 注入，模块不 get_node**：迁移前各
##      `_check_*` 入口用 `get_node_or_null("Track")` 取静态兄弟节点、`_check_weather`
##      用 `get_node_or_null("WorldEnvironment")`、`_check_stuck`/`_flip_state` 用
##      `get_world_3d()` —— 全改为注入 + 保留原 null 检查（§2.4：禁反向持有场景；
##      layout / bench / ai 同款约定）。玩家车沿用 `_car` 字段名（main.gd 成员同名，
##      迁移前各 `_check_*` 就读 main 的 `_car`），注入后族内代码零 diff。
##
##   ② **physics_frame 经 Callable 注入**：迁移前帧循环里是 `await get_tree().physics_frame`；
##      模块是 RefCounted、不在场景树上，没有 get_tree()，由 main 把 `_shot_physics_frame`
##      （返回 physics_frame 信号本体）以 Callable 递进来。模块里 `await _physics_frame.call()`
##      与迁移前 `await get_tree().physics_frame` 是**同一个 Signal**，协程恢复时机不变
##      （bench / ai / screenshot_mode 同款决策）。
##
##   ③ **await 数 = 29，一拍不加**：迁移前本族真实 await 29 处 —— 16 处帧循环的
##      physics_frame（注入后为 `await _physics_frame.call()`）+ 1 处
##      `await _friction_probe(...)`（run_friction 内）+ 9 处 run_flip 里
##      `await _flip_case_*()` + 3 处 `_flip_case_hunt` 里 `await _flip_hunt_trial(...)`。
##      main.gd 分发口的 `await _checks_envphys.run_*()` 留在 main 自己那层协程 ——
##      协程深度与迁移前一致（opponent_spawner 实证：多一层协程 = physics_frame 恢复
##      时机差 1 物理帧 = 25856 行日志发散）。由
##      split-checks-envphys-structcheck.ps1 把这些形态钉死。
##
##   ④ **`_opponents` 是只读代理**：`_check_phys` 只读 `_opponents.size()`，真身在
##      `opponent_spawner`（module 持注入的 `_opponent_spawner` 实例 + 同名只读 getter），
##      不在此持第二份数组（§5.3）。
##
## ⚠ GameState.current_level() / effective_speed() 直接读 autoload（layout.gd / bench.gd
##   同款先例）：GameState 是全局单例、不是场景节点，直连不违反「禁反向持有场景」。
##
## ⚠ 为什么没有 class_name（与全部先例模块同一约定）：验收闸门在**无编辑器**环境跑
##   Godot，全局类缓存（.godot/global_script_class_cache.cfg）只有编辑器会重建；
##   2026-10-12 实测新增 class_name 后 `--check-only` 与游戏运行双双报
##   `Identifier not declared`。消费方一律
##   `const ChecksEnvPhys := preload("res://scripts/checks/env_phys.gd")`。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car = $RaceCar）。字段名沿用 main 的成员名 → 族内代码零 diff。
var _car: VehicleBody3D = null
## 赛道（迁移前是各 _check_* 里 get_node_or_null("Track") 的静态兄弟节点）。由 setup() 注入。
var _track: Node = null
## 世界环境（迁移前是 _check_weather 里 get_node_or_null("WorldEnvironment")）。由 setup() 注入。
var _world_environment: WorldEnvironment = null
## 物理世界（迁移前是 _check_stuck / _flip_state 里 get_world_3d()）。由 setup() 注入。
var _world_3d: World3D = null
## 对手生成模块（_check_phys 要 arm_opponents()）。注入**本文件持有的实例**（状态在实例上）。
var _opponent_spawner = null
## 对手数组只读代理：真身在 _opponent_spawner（不复制第二份数组，§5.3）。
var _opponents: Array:
	get:
		return _opponent_spawner.opponents
## physics_frame 信号提供者（main.gd 的 _shot_physics_frame）。由 setup() 注入；
## 模块里 `await _physics_frame.call()` 取代 `await get_tree().physics_frame`，
## 是同一个 Signal，协程恢复时机不变（文件头决策 ②③）。
var _physics_frame: Callable = Callable()
## 摆位纯函数（static func pose_facing，无状态可直调，§2.4 约定）。
const Autopilot := preload("res://scripts/autopilot.gd")


## 注入外部引用（main.gd 在 _after_world_ready 里调用一次）。
func setup(car: VehicleBody3D, track: Node, world_environment: WorldEnvironment,
		world_3d: World3D, opponent_spawner, physics_frame: Callable) -> void:
	_car = car
	_track = track
	_world_environment = world_environment
	_world_3d = world_3d
	_opponent_spawner = opponent_spawner
	_physics_frame = physics_frame


# ======================== 卡墙验收（--check=wallslide）========================
#
## 卡墙验收：以 5°/10°/20° 角怼向墙，全油门跑 4 秒，要求车能继续前进（不卡死）。
## 这是用户报的"快回到起点卡墙"的回归测试。
func run_wallslide() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var road_half := float(track.call("road_half_width"))
	var rail_half := float(track.call("rail_half_width"))
	_car.set("auto_recover", true)          # 允许楔入救援生效，但不允许出界兜底干扰
	_car.set("auto_reset_out_of_bounds", false)
	var fails := 0
	var cases := 0
	var worst_visual := 0.0
	var rail_thick := 0.35
	var rt = track.get("rail_visual_thickness")
	if rt != null:
		rail_thick = float(rt)
	print("[自检] 卡墙验收：3 个角度 × 内外两侧，全油门怼墙 4 秒，要求结束时速度 > 12 km/h")
	print("[自检]   同时量「车尾穿模」：要求车**视觉模型**的横向最远处 ≤ 护栏碰撞面 %.2fm + 墙厚 %.2fm"
		% [rail_half, rail_thick])
	for arc: float in [1630.0, 400.0]:
		for side_sign: float in [-1.0, 1.0]:
			for deg: float in [5.0, 10.0, 20.0]:
				cases += 1
				var c0 := Vector3(track.call("centerline_point", arc))
				var f0 := Vector3(track.call("centerline_forward", arc))
				var s0 := Vector3(f0.z, 0.0, -f0.x).normalized() * side_sign
				# 摆在离墙 1.5m 处，车头朝"沿赛道方向偏 deg 度指向墙"
				var start: Vector3 = c0 + s0 * (rail_half - 1.5) + Vector3.UP * 0.6
				_car.global_position = start
				_car.linear_velocity = Vector3.ZERO
				_car.angular_velocity = Vector3.ZERO
				var heading := (f0 + s0 * tan(deg_to_rad(deg))).normalized()
				_car.global_transform.basis = Basis.looking_at(heading, Vector3.UP)
				_car.set("_reset_cooldown", 0.0)
				for i in range(6):
					await _physics_frame.call()
				var min_speed := INF
				var wedge_rescues := 0
				var case_visual := 0.0
				for i in range(int(Engine.physics_ticks_per_second) * 4):
					Input.action_press("accelerate")
					await _physics_frame.call()
					var sp: float = _car.linear_velocity.length() * 3.6
					min_speed = minf(min_speed, sp)
					case_visual = maxf(case_visual, _visual_lateral_extent(track))
					# 楔入救援日志出现次数（从日志里数不方便，这里直接看位移是否被推过）
				Input.action_release("accelerate")
				worst_visual = maxf(worst_visual, case_visual)
				var end_speed: float = _car.linear_velocity.length() * 3.6
				var near := track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary
				var ok := end_speed > 12.0
				var poke := case_visual - rail_half
				if not ok:
					fails += 1
				print("[自检]   %s侧 %2.0f° 怼墙：结束速度 %5.1f km/h 最低 %5.1f 偏离 %.2fm 视觉最远 %.2fm（探出墙面 %+.2fm）  %s"
					% ["内" if side_sign < 0.0 else "外", deg, end_speed, min_speed,
					   float(near["dist"]), case_visual, poke,
					   "✔ 能继续开" if ok else "✘ 卡住了"])
	# 穿模判据：视觉探出量必须小于墙厚（探进墙里 = 被墙体挡住，看不见）
	if worst_visual > rail_half + rail_thick + 0.02:
		fails += 1
		printerr("[自检]   ✘ 车尾穿模：视觉最远 %.2fm > 墙面 %.2fm + 墙厚 %.2fm（会从墙背面露出来）"
			% [worst_visual, rail_half, rail_thick])
	else:
		print("[自检]   车尾穿模检查 ✔ 全程视觉最远 %.2fm，探出墙面 %.2fm < 墙厚 %.2fm（藏在墙体里）"
			% [worst_visual, worst_visual - rail_half, rail_thick])
	print("[自检] 卡墙验收：%d/%d 通过%s" % [cases - fails, cases, " ✔" if fails == 0 else " ✘ 有卡墙"])
	_car.set("auto_reset_out_of_bounds", true)


## 车**视觉模型**相对中心线的最大横向距离（用来验"车尾穿模"）。
##
## 为什么要单独量视觉而不是碰撞：碰撞盒是 1.6×3.4，视觉包围盒是 1.73×3.74，
## 车斜着贴墙时视觉角点会比碰撞角点多探出最多约 0.18m —— 如果护栏只是一张
## 零厚度的面，这 0.18m 会从墙的背面露出来，相机在墙外就正好看见"车尾扎进墙里"。
func _visual_lateral_extent(track: Node) -> float:
	if _car == null or track == null:
		return 0.0
	var near: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
	var c: Vector3 = near.get("pos", _car.global_position)
	var fwd: Vector3 = near.get("forward", Vector3.FORWARD)
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	if side.length() < 0.001:
		return 0.0
	side = side.normalized()
	var worst := 0.0
	var stack: Array = [_car.get_node_or_null("CarModel")]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n == null:
			continue
		if n is VisualInstance3D:
			var vi: VisualInstance3D = n
			var g: AABB = vi.global_transform * vi.get_aabb()
			for i in range(8):
				var lat := absf((g.get_endpoint(i) - c).dot(side))
				worst = maxf(worst, lat)
		for ch in n.get_children():
			stack.append(ch)
	return worst


# ======================== 卡墙诊断取证（--check=stuck）========================
#
## 卡墙诊断：用户报"跑完一圈快回到起点时会卡墙"。
## 这里不放任何修复，只**测量事实**：
##   ① 用射线在多个弧长处量出内/外墙的真实位置，看墙有没有洞或厚度异常；
##   ② 把车摆到"贴墙"的各种深度，朝墙里推 2 秒，看它能穿进墙多深、会不会卡住；
##   ③ 报告卡住时的完整几何关系（车中心/车外缘 vs 内墙）。
func run_stuck() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var total := float(track.call("road_length"))
	var rail_half := float(track.call("rail_half_width"))
	var road_half := float(track.call("road_half_width"))
	var space := _world_3d.direct_space_state
	var params := PhysicsRayQueryParameters3D.new()
	params.collision_mask = 1
	params.collide_with_areas = false

	# ---- ① 量墙：从中心线朝两侧打，报告命中距离（含墙的"内表面"位置）----
	print("[自检] ① 墙体实测（中心线为 0，正值=外侧/负值=内侧）")
	var worst_inner := 0.0
	var worst_outer := 0.0
	var d := 0.0
	while d < total:
		var pos := Vector3(track.call("centerline_point", d))
		var fwd := Vector3(track.call("centerline_forward", d))
		var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
		# 朝外侧打
		params.from = pos + Vector3.UP * 0.5
		params.to = params.from + side * 60.0
		var ho := space.intersect_ray(params)
		# 朝内侧打
		params.to = params.from - side * 60.0
		var hi := space.intersect_ray(params)
		if not ho.is_empty():
			worst_outer = maxf(worst_outer, absf((params.from.distance_to(ho["position"])) - rail_half))
		if not hi.is_empty():
			worst_inner = maxf(worst_inner, absf((params.from.distance_to(hi["position"])) - rail_half))
		d += 5.0
	print("[自检]   外侧墙位置偏差最大 %.3fm，内侧墙位置偏差最大 %.3fm（都应在 %.1fm 附近）"
		% [worst_outer, worst_inner, rail_half])

	# ---- ② 贴墙推：把车摆到离中心线 road_half-0.5 处并朝墙里推 ----
	print("[自检] ② 贴墙推进测试（起点区弧长 0 附近，朝内墙推 2 秒）")
	var arc0 := 1630.0
	var c0 := Vector3(track.call("centerline_point", arc0))
	var f0 := Vector3(track.call("centerline_forward", arc0))
	var s0 := Vector3(f0.z, 0.0, -f0.x).normalized()
	for depth: float in [0.0, 0.5, 1.0]:
		var start_pos: Vector3 = c0 - s0 * (road_half - 0.5 - depth) + Vector3.UP * 0.6
		_car.global_position = start_pos
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		# 朝内墙方向摆正车头
		_car.global_transform.basis = Basis.looking_at(-s0, Vector3.UP)
		_car.set("auto_recover", false)
		_car.set("auto_reset_out_of_bounds", false)
		for i in range(4):
			await _physics_frame.call()
		for i in range(int(Engine.physics_ticks_per_second) * 2):
			Input.action_press("accelerate")
			await _physics_frame.call()
			# 每 0.5 秒打一次状态：车到底被什么挡住了
			if i % 60 == 0:
				var pf: Vector3 = _car.global_position
				var nf := track.call("nearest_on_centerline", pf, -1.0) as Dictionary
				var upv := _car.global_transform.basis.y.normalized()
				var lean := rad_to_deg(acos(clampf(upv.dot(Vector3.UP), -1.0, 1.0)))
				print("[自检]     t=%.1fs pos=%s 速度=%.1fkm/h 偏离=%.2fm 侧倾=%.1f° 转向=%.2f"
					% [float(i) / Engine.physics_ticks_per_second, pf,
					   _car.linear_velocity.length() * 3.6, float(nf["dist"]), lean, _car.steering])
				# 从车中心朝"墙那一侧"和"朝下"各打一条射线，看它贴着/压着什么
				var sp := _world_3d.direct_space_state
				var pr := PhysicsRayQueryParameters3D.new()
				pr.collision_mask = 1
				pr.exclude = [_car.get_rid()]
				pr.collide_with_areas = false
				# 朝下
				pr.from = pf
				pr.to = pf + Vector3.DOWN * 3.0
				var hd := sp.intersect_ray(pr)
				# 朝内墙方向
				var f2 := Vector3(track.call("centerline_forward", float(nf["arc"])))
				var s2 := Vector3(f2.z, 0.0, -f2.x).normalized()
				pr.from = pf + Vector3.UP * 0.5
				pr.to = pr.from - s2 * 12.0
				var hw := sp.intersect_ray(pr)
				print("[自检]       朝下命中=%s   朝内墙命中=%s"
					% ["无" if hd.is_empty() else "%.2fm @ %s" % [pf.distance_to(hd["position"]), hd["collider"]],
					   "无" if hw.is_empty() else "%.2fm @ %s" % [(pf + Vector3.UP * 0.5).distance_to(hw["position"]), hw["collider"]]])
		Input.action_release("accelerate")
		var p: Vector3 = _car.global_position
		var rel := p - Vector3(track.call("centerline_point", arc0))
		var lateral := rel.dot(s0)          # 负 = 内侧
		var near := track.call("nearest_on_centerline", p, -1.0) as Dictionary
		# 车外缘（朝墙那一侧）离中心线多远
		var outer_edge := absf(lateral) + 0.95
		print("[自检]   起始偏移 %.2fm → 推到 %s：车中心横向 %.2fm，车外缘 %.2fm；内墙在 %.2fm；速度 %.1fkm/h；偏离中心线 %.2fm"
			% [road_half - 0.5 - depth, p, lateral, outer_edge, -rail_half,
			   _car.linear_velocity.length() * 3.6, float(near["dist"])])
		if outer_edge > rail_half:
			print("[自检]   ⚠ 车外缘已越过内墙 %.2fm（说明车被挤进/穿过墙了）"
				% (outer_edge - rail_half))

	# ---- ③ 结论 ----
	print("[自检] ③ 判定：若②里出现'车外缘越过内墙'且速度接近 0，就是卡墙；"
		+ "若①的偏差很小，说明墙本身没洞，问题在碰撞求解（需要换更硬的墙或加脱困）")
	_car.set("auto_recover", true)
	_car.set("auto_reset_out_of_bounds", true)


## 卡住取证：用**车体真实碰撞盒**朝 6 个方向各扫一次，报告"最先撞到谁"。
##
## 为什么必须有这一问（2026-10 实测教训）：L4 上反复出现"车静止、满油门、
## 四轮接地"的卡死，而 `obstacle_field.pick_clear_lane()` 认为那条车道**是通的**
## —— 也就是说挡住它的东西**不在 `obstacles[]` 里**。光看坐标区分不了
## 「石头 / 护栏 / 检查点 / 别的物理体 / 根本没有东西」，必须去问物理世界。
##
## 口径与 `ai_opponent._probe_collision_geometry()` 一致（同一套 `cast_motion` +
## 射线指名），只保留"被谁挡住"这一问。**只在卡住时跑一次**，不进正常路径。
func probe_blocker() -> void:
	var body := _car.get_node_or_null("BodyCollision") as CollisionShape3D
	if body == null:
		print("[自检]       [卡住取证] 找不到 BodyCollision 节点，跳过")
		return
	var bshape := body.shape as BoxShape3D
	if bshape == null:
		print("[自检]       [卡住取证] BodyCollision 不是 BoxShape3D，跳过")
		return
	var bt := body.global_transform
	var space := _world_3d.direct_space_state
	var dirs := {"前(-Z)": -bt.basis.z, "后(+Z)": bt.basis.z, "右(+X)": bt.basis.x,
		"左(-X)": -bt.basis.x, "上(+Y)": Vector3.UP, "下(-Y)": Vector3.DOWN}
	print("[自检]       [卡住取证] 车体盒 size=%s 世界中心=%s" % [str(bshape.size), str(bt.origin)])
	for k in dirs.keys():
		var d: Vector3 = (dirs[k] as Vector3).normalized()
		var pq := PhysicsShapeQueryParameters3D.new()
		pq.shape = bshape
		pq.transform = bt
		pq.collision_mask = 1
		pq.collide_with_bodies = true
		pq.collide_with_areas = false
		pq.exclude = [_car.get_rid()]
		pq.motion = d * 8.0
		var fr: PackedFloat32Array = space.cast_motion(pq)
		var frac := 1.0 if fr.size() < 2 else minf(fr[0], fr[1])
		var dist := 8.0 * frac
		# 形状投射只给比例、不给对象，所以再用一条射线问"是谁"。
		# 终点必须**越过**接触面（dist + 0.15），落在面上会打空（AI 那边踩过这个坑）。
		var who := "—"
		var rq := PhysicsRayQueryParameters3D.new()
		rq.from = bt.origin
		rq.to = bt.origin + d * (dist + 0.15)
		rq.collision_mask = 1
		rq.exclude = [_car.get_rid()]
		var hit := space.intersect_ray(rq)
		if not hit.is_empty():
			var col = hit.get("collider")
			who = ("%s" % (col.name if col != null else "?"))
		print("[自检]       [卡住取证] %s：最近实体 %.2fm（%s）" % [k, dist, who])


# ======================== 物理开销测量（--check=phys）========================
#
## 物理开销测量（**可做 A/B 的版本**）。
##
## 为什么单独做一个检查，而不是塞进 --check=opponents：
## 原来我在对手生成前后各测一次来算"增量"，但两次采样点一个在赛道刚建好时（冷态：
## 几千个静态体刚注册、着色器刚编译），一个在几百帧后（热态），**冷热态不可比**。
## 实测就出现了"0 台对手 3.61ms、4 台对手 3.04ms"这种自相矛盾的数字。
##
## 现在：充分预热（丢掉 300 帧）后连测 240 帧，同一套流程跑不同关卡，
## 得到的就是**同一热态下**的可比数字：
##   godot --path <工程> -- --check=phys --level=0   # 0 台对手（基线）
##   godot --path <工程> -- --check=phys --level=4   # 4 台对手
func run_phys() -> void:
	var cfg: LevelConfig = GameState.current_level()
	# 让对手真的跑起来，测的才是"有对手在实际行驶"的开销
	_opponent_spawner.arm_opponents()
	var hz := float(Engine.physics_ticks_per_second)
	# 预热：丢掉 300 帧（赛道刚建好时静态体注册/着色器编译会让前若干帧异常重）
	for i in range(300):
		await _physics_frame.call()
	# 主指标 = **实际达成的物理步频**。
	# 为什么不用 Performance.TIME_PHYSICS_PROCESS 下结论：同一套配置连测 5 次
	# 得到 3.04 / 3.31 / 3.81 / 5.53 / 6.36 ms，波动 2 倍，噪声盖过了对手的真实开销，
	# 甚至出现过"4 台对手比 0 台还便宜"的荒谬结论。步频是端到端事实，
	# 而且直接回答我们真正关心的问题：120Hz 稳不稳。
	print("[自检] 物理开销：关卡=%s 对手=%d 台 玩家=1 台（目标 %d Hz）"
		% [cfg.display_name if cfg != null else "?", _opponents.size(), int(hz)])
	var achieved_min := 1e9
	var achieved_max := 0.0
	var ms_max := 0.0
	var ms_sum := 0.0
	var ms_n := 0
	for round_i in range(3):
		var frames := 600
		var t0 := Time.get_ticks_usec()
		for i in range(frames):
			await _physics_frame.call()
			var ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			ms_sum += ms
			ms_n += 1
			ms_max = maxf(ms_max, ms)
		var dt := float(Time.get_ticks_usec() - t0) / 1_000_000.0
		var achieved := float(frames) / maxf(dt, 0.0001)
		achieved_min = minf(achieved_min, achieved)
		achieved_max = maxf(achieved_max, achieved)
		print("[自检]   第 %d 轮：%d 帧用了 %.2f 秒 → 实际 %.1f Hz" % [round_i + 1, frames, dt, achieved])
	var avg_ms := ms_sum / float(maxi(ms_n, 1))
	# 场景规模用**自己数出来**的节点数，不用 Performance 的 PHYSICS_3D_ACTIVE_OBJECTS /
	# COLLISION_PAIRS —— 这两个监视器在本项目实测恒为 0（拿不到有效值），
	# 打印一个恒为 0 的指标只会误导人。
	var vehicles := 1 + _opponents.size()
	var statics := 0
	var track := _track
	if track != null:
		for c in track.get_children():
			if c is StaticBody3D:
				statics += 1
	print("[自检]   实际步频：最低 %.1f Hz / 最高 %.1f Hz（目标 %d Hz）"
		% [achieved_min, achieved_max, int(hz)])
	print("[自检]   物理耗时（仅供参考，逐帧读数噪声大）：均 %.2f ms / 峰 %.2f ms（预算 8.33 ms）"
		% [avg_ms, ms_max])
	print("[自检]   场景规模：车轮体 %d 台 = %d 个轮子，赛道静态体 %d 个"
		% [vehicles, vehicles * 4, statics])
	if achieved_min >= hz - 2.0:
		print("[自检]   物理开销 ✔ 稳定维持 %d Hz（未掉帧）" % int(hz))
	else:
		printerr("[自检]   ✘ 物理步频掉到 %.1f Hz，低于目标 %d Hz —— 物理确实吃不消"
			% [achieved_min, int(hz)])


# ======================== 天气验收（--check=weather）========================
#
## 天气粒子的最低对比度（相对亮度差）。低于这个值肉眼就基本看不见。
## 参考：纯白(1.0) 与 中灰(0.45) 的差约 0.55；原来的"白雪花 vs 惨白天空"只有约 0.07。
const MIN_WEATHER_CONTRAST := 0.25


## 感知亮度（Rec.709 权重）。用来把"颜色差多少"变成一个数。
func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


## 天气验收：粒子**该有的时候有、该没有的时候没有**，且**不拖垮帧率**。
##
## 为什么要单独验收：天气很容易"看起来做了但实际没生效"（节点建了但 emitting=false、
## 或者晴天也挂着粒子）。所以这里既查存在性，也查帧率影响。
func run_weather() -> void:
	var cfg: LevelConfig = GameState.current_level()
	var want := cfg.weather_type != "clear"
	var node := _car.get_node_or_null("WeatherParticles") if _car != null else null
	print("[自检] 天气验收：本关天气=%s（%s），期望粒子=%s"
		% [cfg.weather_type, cfg.weather_label(), "有" if want else "无"])
	var ok := true
	if want and node == null:
		printerr("[自检]   ✘ 期望有天气粒子，但没找到 WeatherParticles 节点")
		ok = false
	elif not want and node != null:
		printerr("[自检]   ✘ 晴天不应有天气粒子，却找到了节点")
		ok = false
	elif want:
		var p := node as GPUParticles3D
		var pm := p.process_material as ParticleProcessMaterial
		print("[自检]   粒子数 %d，寿命 %.1fs，发射盒 %s，emitting=%s，local_coords=%s"
			% [p.amount, p.lifetime, str(pm.emission_box_extents), str(p.emitting), str(p.local_coords)])
		if not p.emitting:
			printerr("[自检]   ✘ emitting = false，粒子不会出现")
			ok = false
		if p.amount <= 0:
			printerr("[自检]   ✘ amount = 0")
			ok = false
		# 必须查 draw_pass_1：光看 emitting/amount 会漏掉"配好了但根本不渲染"。
		# 这个检查是补上的 —— 第一版只查了前两项，结果 draw_pass_1 是空的
		# （我把网格挂成了子 MeshInstance3D），日志一切正常但画面一个粒子都没有。
		if p.draw_pass_1 == null:
			printerr("[自检]   ✘ draw_pass_1 为空：粒子已配置但**不会被画出来**")
			ok = false
		else:
			print("[自检]   draw_pass_1 = %s（粒子外观正常）" % p.draw_pass_1.get_class())
		if p.process_material == null:
			printerr("[自检]   ✘ process_material 为空，粒子不会运动")
			ok = false
		# 对比度：把"看不看得清"变成一个可校验的数。
		# 雪花/雨丝要打在天空上，所以拿**粒子颜色**和**环境背景色**的相对亮度差来判。
		# 为什么必须定量：雪天第一版是白雪花打惨白天空，粒子和节点全都正常、
		# 日志一切正常，就是肉眼看不见 —— 这种问题只有量化才守得住。
		var flake := pm.color
		var we := _world_environment
		if we != null and we.environment != null:
			var sky := we.environment.background_color
			var lf := _luminance(flake)
			var ls := _luminance(sky)
			var contrast := absf(lf - ls)
			print("[自检]   对比度：粒子亮度 %.2f vs 天空亮度 %.2f → 差 %.2f（要求 ≥ %.2f）"
				% [lf, ls, contrast, MIN_WEATHER_CONTRAST])
			if contrast < MIN_WEATHER_CONTRAST:
				printerr("[自检]   ✘ 对比度不足，粒子在画面上会看不清（粒子和背景太接近）")
				ok = false
			else:
				print("[自检]   ✔ 对比度足够，粒子在天空上看得见")
	else:
		print("[自检]   晴天：无粒子节点，符合预期")
	# 帧率影响：天气粒子是纯 GPU 的，不应显著影响物理步频
	var hz := float(Engine.physics_ticks_per_second)
	for i in range(120):
		await _physics_frame.call()
	var t0 := Time.get_ticks_usec()
	for i in range(600):
		await _physics_frame.call()
	var dt := float(Time.get_ticks_usec() - t0) / 1_000_000.0
	var achieved := 600.0 / maxf(dt, 0.0001)
	print("[自检]   物理步频在天气粒子下：%.1f Hz（目标 %d Hz）" % [achieved, int(hz)])
	if achieved < hz - 2.0:
		printerr("[自检]   ✘ 步频掉到 %.1f Hz" % achieved)
		ok = false
	if ok:
		print("[自检] 天气验收 ✔ 粒子和环境配置符合本关天气，且未拖垮帧率")
	else:
		printerr("[自检] 天气验收 ✘ 见上方 ✘ 行")


# ======================== 抓地力验收（--check=friction）========================
#
## 天气抓地力验收：**证明倍率真的进了物理**，而不只是换了个环境颜色。
##
## 做法：同一初始条件下（加速到 60km/h、直线、满舵一段）分别用 ×1.0 和低倍率跑，
## 比较**实际达成的侧向加速度** v·ω 与**侧滑角**（速度方向与车头方向的夹角）。
##
## ⚠ 这里纠正过一个错误的指标：第一版量的是"相对初始航向的横向位移"并叫它"侧滑"，
## 结果抓到高抓地力反而位移更大（2.762m vs 0.510m），看起来像"倍率反了"。
## 其实那正是正确的物理 —— 抓地力高时车**真的转过去了**（并把速度刮到 3km/h），
## 抓地力低时车推头直着冲出去（横向位移自然小）。位移量的是"转了多少"，
## 不是"滑了多少"，名字和判据都用错了。现在改用 v·ω（向心加速度）：
## 同样的打舵输入下，抓地力越高能达成的侧向加速度越大。
func run_friction() -> void:
	var cfg: LevelConfig = GameState.current_level()
	var mult := cfg.friction_multiplier if cfg != null else 1.0
	# 扫一串倍率，看侧向加速度是否**单调**随抓地力上升。
	# 为什么用扫描而不是"两档比一个 25% 阈值"：单点比较太脆（实测 ×1.00 vs ×0.25
	# 只差 26%，刚好压在阈值线上，稍微抖一下就会翻）。单调性在 5 个点上同时成立，
	# 既难假阳性，还能直接看出倍率的梯度是否有实际手感差异。
	var mults := [1.0, 0.75, 0.5, 0.33, 0.2]
	print("[自检] 抓地力验收：扫描倍率 %s（本关配置 ×%.2f）"
		% [str(mults), mult])
	var accels: Array[float] = []
	var yaws: Array[float] = []
	for m in mults:
		var r: Dictionary = await _friction_probe(m)
		accels.append(float(r.get("lateral_accel", 0.0)))
		yaws.append(float(r.get("yaw_deg", 0.0)))
		print("[自检]   ×%.2f：侧向加速度 %5.1f m/s²，转过 %4.0f°，侧滑角 %4.1f°，末速 %3.0f km/h，离路面中心线 %.2fm"
			% [m, r.get("lateral_accel", 0.0), r.get("yaw_deg", 0.0),
			   r.get("slip_deg", 0.0), r.get("speed", 0.0), r.get("off_road", 0.0)])
	if accels[0] < 0.5:
		printerr("[自检] 抓地力验收 ✘ ×1.00 下侧向加速度只有 %.2f m/s²，探针本身没生效" % accels[0])
		return
	# 判据一：单调性（倍率降低，侧向加速度不得上升）
	var monotonic := true
	for i in range(1, accels.size()):
		if accels[i] > accels[i - 1] + 0.5:      # 0.5 m/s² 容差，避免被噪声判死
			monotonic = false
			printerr("[自检]   ✘ 非单调：×%.2f 的 %.1f > ×%.2f 的 %.1f"
				% [mults[i], accels[i], mults[i - 1], accels[i - 1]])
	# 判据二：两端差距要足够大，否则说明倍率对手感几乎没影响
	var spread := (accels[0] - accels[accels.size() - 1]) / maxf(accels[0], 0.01)
	print("[自检]   单调性：%s；两端差距：%.1f → %.1f m/s²（降 %.0f%%）"
		% ["✔ 成立" if monotonic else "✘ 不成立", accels[0], accels[accels.size() - 1], spread * 100.0])
	if monotonic and spread >= 0.10:
		print("[自检] 抓地力验收 ✔ 倍率确实进了物理：倍率越低侧向加速度越小，且梯度可感知")
	elif monotonic:
		print("[自检] 抓地力验收 △ 单调性成立但梯度偏小（降 %.0f%%）" % [spread * 100.0])
		printerr("[自检]   提示：轮胎 wheel_friction_slip 基准值本来就很高（前 3.0 / 后 2.6），"
			+ "倍率再低也还剩不少抓地力，天气手感可能不明显")
	else:
		printerr("[自检] 抓地力验收 ✘ 倍率没有单调影响物理，链路可能断了")


## 抓地力探针：**确定性摆放**后满舵 0.7 秒，测实际达成的侧向加速度（v·ω）。
##
## ⚠ 这条探针返工过两次，两次都是"夹具不可复现"，值得记下来：
##   第一版量"横向位移"当侧滑 —— 量到的其实是"转了多少"，名字和判据都错了。
##   第二版用 reset_to_track() 摆车 —— 那个函数把人送到"最后一个检查点"，
##     每次落点都不一样（还可能带着上一轮的姿态），于是同一倍率测出的侧向加速度
##     在 20~33 m/s² 之间乱跳，扫描出来的曲线完全不单调，根本得不出结论。
##   现在：固定摆在起终点直道、朝赛道前进方向、**速度直接给到 60km/h**
##     （省掉加速段，加速段的终点速度受弯道和撞墙影响，是最大的噪声源），
##     并临时关掉 auto_recover，防止探针中途被出界兜底搬走。
func _friction_probe(mult: float) -> Dictionary:
	var track := _track
	if track == null or _car == null:
		return {"lateral_accel": 0.0, "slip_deg": 0.0, "yaw_deg": 0.0, "speed": 0.0}
	var hz := float(Engine.physics_ticks_per_second)
	_car.call("apply_level_setup", GameState.effective_speed(), 99, mult)
	var total := maxf(1.0, float(track.call("road_length")))
	var sf = track.get("start_finish_t")
	var d := total * float(sf) if sf != null else 0.0
	var fwd: Vector3 = track.call("centerline_forward", d)
	fwd.y = 0.0
	fwd = fwd.normalized()
	var prev_recover = _car.get("auto_recover")
	_car.set("auto_recover", false)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	_car.global_transform = Autopilot.pose_facing(track.call("centerline_point", d) + Vector3(0, 0.6, 0), fwd)
	_car.linear_velocity = fwd * (60.0 / 3.6)
	var start_pos: Vector3 = _car.global_position
	await _physics_frame.call()
	var yaw0 := _car.global_rotation.y
	Input.action_press("accelerate")
	Input.action_press("steer_left")
	var lat_sum := 0.0
	var lat_peak := 0.0
	var slip_sum := 0.0
	var slip_n := 0
	var steer_frames := int(hz * 0.7)
	for i in range(steer_frames):
		await _physics_frame.call()
		var vel := _car.linear_velocity
		var planar := Vector2(vel.x, vel.z).length()
		# 侧向加速度 = v · ω（向心加速度），抓地力越高能达成的越大
		var lat := planar * absf(_car.angular_velocity.y)
		lat_sum += lat
		lat_peak = maxf(lat_peak, lat)
		if planar > 3.0:
			var nose := -_car.global_transform.basis.z
			nose.y = 0.0
			var vdir := Vector3(vel.x, 0.0, vel.z)
			if nose.length() > 0.001:
				slip_sum += rad_to_deg(nose.normalized().angle_to(vdir.normalized()))
				slip_n += 1
	Input.action_release("steer_left")
	Input.action_release("accelerate")
	var res := {
		"lat_avg": lat_sum / float(maxi(steer_frames, 1)),
		"lateral_accel": lat_peak,
		"slip_deg": slip_sum / float(maxi(slip_n, 1)),
		"yaw_deg": rad_to_deg(absf(angle_difference(yaw0, _car.global_rotation.y))),
		"speed": _car.linear_velocity.length() * 3.6,
		# 探针本身要能自证有效：跑完还在路面上才算数
		"off_road": _car.global_position.distance_to(
			track.call("nearest_on_centerline", _car.global_position, -1.0).get("pos", start_pos)),
	}
	_car.set("auto_recover", prev_recover)
	var cfg: LevelConfig = GameState.current_level()
	_car.call("apply_level_setup", GameState.effective_speed(),
		cfg.laps_to_finish if cfg != null else 2,
		cfg.friction_multiplier if cfg != null else 1.0)
	_car.call("reset_to_track")
	return res


# ======================== 翻车恢复验收（--check=flip）========================
#
# 玩家的原话是"翻车被扶正之后，车贴着地横向滑，速度不低但完全不可控"。
# 这个状态（**四轮全不接地 + 车身基本水平 + 仍在动**）现有代码里没有任何判定管它：
#   - 翻车判定看的是 up·UP（腹部贴地时≈1，判不出）
#   - 卡住判定看的是"速度低"（腹部滑行时 27km/h，也判不出）
# 所以本项检查分两步：① 用**物理状态硬数据**把能复现的姿态找出来（探针，打状态表）；
# ② 再断言恢复时间。找不到复现姿态就明确报"未复现"，绝不假装通过。

## 用例 B 的侧滑速度（km/h）。取 27 是因为日志里实测就是这个量级。
const BELLY_TEST_KMH := 27.0
## 每个候选姿态最多观察多少秒
const BELLY_TEST_SECONDS := 8.0
## 连续"四轮全不接地"要达到这么久，才算真的复现了腹部贴地
const BELLY_ONSET := 1.0
## 连续"四轮接地"要达到这么久，才算真的恢复了（单帧接地不算 —— 实测会抖）
const BELLY_RECOVER := 0.6
## 姿态在多少度以内算"基本水平"（不是腾空翻车）
const FLIP_UPRIGHT_ANGLE := 25.0

## 本项验收里成功复现腹部贴地的候选姿态数
var _flip_reproduced := 0
## 本项验收的失败计数
var _flip_fails := 0


## 采样车的接地/姿态状态。全部来自物理状态与射线，**不读脚本内部变量** ——
## 这样"轮子是不是真的不接地"是独立证据，而不是拿实现给自己打分。
func _flip_state() -> Dictionary:
	var up: Vector3 = _car.global_transform.basis.y.normalized()
	var wheels := 0
	var contact := 0
	var rayhit := 0
	var space := _world_3d.direct_space_state
	for child in _car.get_children():
		if child is VehicleWheel3D:
			var w: VehicleWheel3D = child
			wheels += 1
			if w.is_in_contact():
				contact += 1
			var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
				w.global_position,
				w.global_position + Vector3.DOWN * (w.wheel_radius + 0.6),
				1, [_car.get_rid()])
			if not space.intersect_ray(q).is_empty():
				rayhit += 1
	return {
		"wheels": wheels,
		"contact": contact,
		"rayhit": rayhit,
		"up_dot": up.dot(Vector3.UP),
		"y": _car.global_position.y,
		"kmh": Vector2(_car.linear_velocity.x, _car.linear_velocity.z).length() * 3.6,
	}


## 用例 A：底朝天。翻 180° 放到路面上，要求 ≤2s 原地扶正且四轮接地。
func _flip_case_inverted(track: Node, arc: float) -> void:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	# 第二个参数传 DOWN：基的 Y 轴朝下 = 整车倒扣，车头仍沿赛道方向
	_car.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.DOWN), c + Vector3.UP * 0.9)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	var t := 0.0
	var recovered := -1.0
	while t < 4.0:
		await _physics_frame.call()
		t += tick
		var s := _flip_state()
		if float(s["up_dot"]) > cos(deg_to_rad(FLIP_UPRIGHT_ANGLE)) and int(s["contact"]) == 4:
			recovered = t
			break
	if recovered > 0.0 and recovered <= 2.0:
		print("[自检]   用例 A 底朝天：%.2fs 扶正且四轮接地 ✔" % recovered)
		return
	_flip_fails += 1
	var why := "4 秒内没恢复"
	if recovered > 0.0:
		why = "恢复太慢 %.2fs（>2.0s）" % recovered
	print("[自检]   用例 A 底朝天：✘ %s" % why)


## 用例 C 的一个真实姿态：摆好 → 给 27km/h 侧向速度 → 观察"恢复"还是"一直贴地滑"。
##
## ⚠ 实测结论（960 帧/姿态，逐帧统计）：从这些姿态出发，**四轮全不接地最多只维持
##   0.2~0.33 秒**（占全程 1~7%），车很快就落回四个轮子 —— 也就是说**合成姿态复现不出
##   "持续贴地滑行"**。所以本函数现在的定位是**证据收集**：它把接地时序图打出来，
##   真的复现出来就必须 ≤2s 恢复；复现不出来就明确写"未能复现"，绝不当成通过。
##   持续状态由用例 B（belly_test_hover 夹具）稳定构造并断言。
##
## roll_deg / pitch_deg：绕前进轴 / 绕右轴旋转；height：车体中心离路面的高度（米）。
func _flip_case_belly(track: Node, arc: float, roll_deg: float, pitch_deg: float,
		height: float, label: String) -> void:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var b := Basis.looking_at(fwd, Vector3.UP)
	if absf(roll_deg) > 0.01:
		b = b.rotated(fwd, deg_to_rad(roll_deg))
	if absf(pitch_deg) > 0.01:
		b = b.rotated(b.x.normalized(), deg_to_rad(pitch_deg))
	_car.global_transform = Transform3D(b, c + Vector3.UP * height)
	_car.linear_velocity = side * (BELLY_TEST_KMH / 3.6)
	_car.angular_velocity = Vector3.ZERO

	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	var t := 0.0
	var frames := 0
	var zero_frames := 0
	var run_zero := 0.0          # 当前这一段的连续 0/4 时长
	var max_zero := 0.0          # 最长的一段连续 0/4
	var run_four := 0.0          # 当前这一段的连续 4/4 时长
	var onset_armed := -1.0      # 当前 0/4 段的起点
	var onset := -1.0            # 贴地成立（连续达 BELLY_ONSET）之后的段落起点
	var recovered := -1.0        # 恢复用时（连续 4/4 达 BELLY_RECOVER 那刻）
	var bin_frames := 0
	var bin_zero := 0
	var pattern := ""
	while t < BELLY_TEST_SECONDS:
		await _physics_frame.call()
		t += tick
		var s := _flip_state()
		var level_ok: bool = float(s["up_dot"]) > cos(deg_to_rad(FLIP_UPRIGHT_ANGLE))
		var near_surface: bool = (float(s["y"]) - c.y) < 1.0
		var moving: bool = float(s["kmh"]) > 5.0
		frames += 1
		bin_frames += 1
		if int(s["contact"]) == 0:
			zero_frames += 1
			bin_zero += 1
		# 贴地段：四轮全不接地 + 车身水平 + 还贴着路面 + 还在动（排除腾空飞跃）
		if int(s["contact"]) == 0 and level_ok and near_surface and moving:
			if run_zero <= 0.0:
				onset_armed = t
			run_zero += tick
			if run_zero >= BELLY_ONSET and onset < 0.0:
				onset = onset_armed
			max_zero = maxf(max_zero, run_zero)
		else:
			run_zero = 0.0
		# 恢复：必须**连续**接地够久才算，单帧接地不算（实测会抖）
		if int(s["contact"]) == 4 and level_ok:
			run_four += tick
			if onset > 0.0 and recovered < 0.0 and run_four >= BELLY_RECOVER:
				recovered = t - onset
		else:
			run_four = 0.0
		# 每 0.25s 按多数票压成一个字符，一眼看出抖不抖
		if bin_frames >= int(0.25 / tick):
			var ch := "0"
			if bin_zero * 2 < bin_frames:
				ch = "4"
			pattern += ch
			bin_frames = 0
			bin_zero = 0
		if recovered > 0.0 and t > onset + recovered + 0.75:
			break

	var frac := 0.0
	if frames > 0:
		frac = float(zero_frames) / float(frames)
	print("[自检]   候选「%s」观察 %.1fs：帧数 %d，0/4 占比 %.0f%%，最长连续 0/4 = %.2fs"
		% [label, t, frames, frac * 100.0, max_zero])
	print("[自检]     接地时序（每字符 0.25s：0=四轮全不接地，4=四轮接地）：%s" % pattern)
	if max_zero < BELLY_ONSET:
		print("[自检]   候选「%s」：**未能复现**（连续 0/4 最长仅 %.2fs < %.1fs 门限）→ 不计入判定"
			% [label, max_zero, BELLY_ONSET])
		return
	_flip_reproduced += 1
	if recovered > 0.0 and recovered <= 2.0:
		print("[自检]   候选「%s」：贴地后 %.2fs 恢复四轮接地 ✔（判据 ≤2.0s）" % [label, recovered])
		return
	_flip_fails += 1
	if recovered > 0.0:
		print("[自检]   候选「%s」：✘ 恢复太慢 %.2fs（>2.0s）" % [label, recovered])
	else:
		print("[自检]   候选「%s」：✘ 观察 %.1fs 内四轮从未连续接地 %.1fs 以上 —— 一直贴地滑（占比 %.0f%%）"
			% [label, t, BELLY_RECOVER, frac * 100.0])


## 用例 B：**合成**腹部贴地状态（四轮全不接地 + 车身水平 + 贴着路面 + 27km/h 在动）。
##
## 为什么要合成：用例 C 的 6 个真实姿态实测只能让"四轮全不接地"维持 0.2~0.33s
## （车很快落回四个轮子），复现不出"持续贴地滑行"。这里用车的 belly_test_hover 夹具
## 把车托在路面上方，从而**稳定地**产生那个状态。
##   - 被测量的量（接地数 / 姿态 / 速度 / 离路面高度）**全是真实物理读数**，没有伪造；
##   - 夹具只负责"托住"，不参与判定；
##   - 断言分两段：① 状态成立后 ≤2s 必须触发恢复；② 关掉夹具后必须真的落回四轮接地。
##     第二段是关键 —— 只把车抬高、不补向上速度的话，第二段会失败。
func _flip_case_hover(track: Node, arc: float) -> void:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	_car.set("belly_test_hover", true)
	_car.set("belly_recovery_count", 0)
	_car.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), c + Vector3.UP * 0.8)
	# ⚠ 速度必须**沿赛道方向**给：第一版给的是侧向速度，结果车在 1 秒内横着撞上护栏、
	# 速度从 24km/h 掉到 1.2km/h，状态根本维持不住（实测数据）。
	# 腹部贴地判定与方向无关，所以沿赛道给速度更稳、更能稳定复现这个状态。
	_car.linear_velocity = fwd * (BELLY_TEST_KMH / 3.6)
	_car.angular_velocity = Vector3.ZERO

	var t := 0.0
	var zero_run := 0.0
	var onset := -1.0
	var fired_at := -1.0
	var max_zero := 0.0
	var next_diag := 0.5
	while t < 5.0:
		await _physics_frame.call()
		t += tick
		var s := _flip_state()
		if int(s["contact"]) == 0 and float(s["up_dot"]) > cos(deg_to_rad(FLIP_UPRIGHT_ANGLE)):
			zero_run += tick
			max_zero = maxf(max_zero, zero_run)
			if zero_run >= BELLY_ONSET and onset < 0.0:
				onset = t - zero_run          # 状态真正成立的那一刻
		else:
			zero_run = 0.0
		if t >= next_diag:
			next_diag += 0.5
			# 把**车自己**的判据读数打出来：不猜，直接看它为什么没触发
			print("[自检]     t=%.2fs 接地 %d/4 belly_time=%.2f auto=%s immunity=%.2f y=%.2f 路面y=%.2f up·UP=%.2f %.1f km/h"
				% [t, int(s["contact"]), float(_car.get("_belly_time")),
				   str(_car.get("auto_recover")), float(_car.get("_immunity")),
				   float(s["y"]), c.y, float(s["up_dot"]), float(s["kmh"])])
		if int(_car.get("belly_recovery_count")) > 0:
			fired_at = t - onset
			break
	_car.set("belly_test_hover", false)

	# 第二段：夹具关掉后必须真的落回四个轮子
	var t2 := 0.0
	var run_four := 0.0
	var landed := -1.0
	while t2 < 3.0:
		await _physics_frame.call()
		t2 += tick
		if int(_flip_state()["contact"]) == 4:
			run_four += tick
			if run_four >= BELLY_RECOVER:
				landed = t2
				break
		else:
			run_four = 0.0

	var fired_txt := "未触发"
	if fired_at > 0.0:
		fired_txt = "%.2fs" % fired_at
	var landed_txt := "未落地"
	if landed > 0.0:
		landed_txt = "%.2fs" % landed
	print("[自检]   用例 B 合成腹部贴地：状态持续 %.2fs，恢复触发 %s，夹具关闭后落地 %s"
		% [max_zero, fired_txt, landed_txt])
	if fired_at > 0.0 and fired_at <= 2.0 and landed > 0.0:
		print("[自检]   用例 B 合成腹部贴地 ✔")
		return
	_flip_fails += 1
	var why := "5 秒内没有触发恢复（belly_recovery_count 一直是 0）"
	if fired_at > 2.0:
		why = "恢复触发太慢 %.2fs（判据 ≤2.0s）" % fired_at
	elif fired_at > 0.0:
		why = "触发了恢复，但夹具关闭后 3 秒内没能落回四轮接地"
	print("[自检]   用例 B 合成腹部贴地：✘ %s" % why)


## 一次搜索试验。mode：
##   "wall" —— 以 angle_deg 斜向护栏全冲（先让悬挂稳定，再给速度）
##   "flip" —— 沿赛道冲起来后强制翻转（复刻"撞完翻车"那一刻）
##   "drop" —— 从 2.5/4.5m 高处砸到路面（复刻"飞出去砸底盘"，最可能压死悬挂）
##
## ⚠ 必须先 settle 再测量：实测刚瞬移/摆好姿态后的 ~0.33s 内四个轮子都报"不接地"，
##   那是物理 settle 瞬态、不是贴地滑行。不去掉它的话，每一组都会报"0/4 最长 0.33s"，
##   看起来像发现了什么，其实只是噪声。
## 返回 {found, max_zero, recovered, kmh, y, min_kmh}
func _flip_hunt_trial(track: Node, arc: float, angle_deg: float, kmh: float,
		mode: String, seconds: float) -> Dictionary:
	var c: Vector3 = track.call("centerline_point", arc)
	var fwd: Vector3 = track.call("centerline_forward", arc)
	var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var heading := (fwd + side * tan(deg_to_rad(angle_deg))).normalized()
	var tick := 1.0 / float(Engine.physics_ticks_per_second)
	_car.set("belly_recovery_count", 0)
	_car.set("auto_recover", true)
	var start_y := 0.55
	if mode == "drop":
		start_y = 2.5
	_car.global_transform = Transform3D(Basis.looking_at(heading, Vector3.UP), c + Vector3.UP * start_y)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO

	# 先落地稳定，再给冲撞速度（drop 模式例外：砸下去本身就是事件）
	if mode != "drop":
		var settle := 0.45
		var ts := 0.0
		while ts < settle:
			await _physics_frame.call()
			ts += tick
		_car.linear_velocity = heading * (kmh / 3.6)

	var t := 0.0
	var run_zero := 0.0
	var max_zero := 0.0
	var onset := -1.0
	var recovered := -1.0
	var flipped_done := false
	var min_kmh := 1e9
	while t < seconds:
		await _physics_frame.call()
		t += tick
		if mode == "flip" and not flipped_done and t > 0.4:
			var b := _car.global_transform.basis
			_car.global_transform = Transform3D(b.rotated(b.z.normalized(), PI),
				_car.global_position + Vector3.UP * 0.5)
			flipped_done = true
		var s := _flip_state()
		var level_ok: bool = float(s["up_dot"]) > cos(deg_to_rad(FLIP_UPRIGHT_ANGLE))
		# near_surface 同时起到"排除正常腾空/下落"的作用（高空砸地的空中段不算贴地）
		var near_surface: bool = (float(s["y"]) - c.y) < 1.5
		if int(s["contact"]) == 0 and level_ok and near_surface and float(s["kmh"]) > 5.0:
			if run_zero <= 0.0:
				onset = t
			run_zero += tick
			max_zero = maxf(max_zero, run_zero)
		else:
			run_zero = 0.0
		min_kmh = minf(min_kmh, float(s["kmh"]))
		if onset > 0.0 and recovered < 0.0 and int(_car.get("belly_recovery_count")) > 0:
			recovered = t - onset
	var last := _flip_state()
	return {
		"found": max_zero >= BELLY_ONSET, "max_zero": max_zero, "recovered": recovered,
		"kmh": float(last["kmh"]), "y": float(last["y"]), "min_kmh": min_kmh,
	}


## 把一次搜索试验的结论打出来；搜到"持续贴地"就必须按 2 秒判据断言恢复。
func _report_hunt_finding(label: String, r: Dictionary) -> void:
	_flip_reproduced += 1
	var rec := float(r["recovered"])
	if rec > 0.0 and rec <= 2.0:
		print("[自检]     ★ 搜到持续贴地：%s（0/4 最长 %.2fs）→ %.2fs 恢复 ✔"
			% [label, float(r["max_zero"]), rec])
		return
	_flip_fails += 1
	if rec > 0.0:
		print("[自检]     ✘ 搜到持续贴地：%s（0/4 最长 %.2fs）但恢复太慢 %.2fs（判据 ≤2.0s）"
			% [label, float(r["max_zero"]), rec])
	else:
		print("[自检]     ✘ 搜到持续贴地：%s（0/4 最长 %.2fs）且**未触发恢复**（末速度 %.1f km/h y=%.2f）"
			% [label, float(r["max_zero"]), float(r["kmh"]), float(r["y"])])


## 用例 D：自动搜复现 —— 用多种"撞墙 / 翻车"方式去撞出持续贴地滑行。
##
## 为什么必须有这一步：用例 B 的合成夹具只能证明"判定与恢复逻辑是对的"，
## **不能证明真实游玩里到底会不会进这个状态**。所以这里做一次**有界**的自动搜索：
## 以 5 个角度 × 2 个速度怼护栏，外加 2 组高速强制翻转，逐帧找"持续 0/4"。
##   找到 → 立刻按 2 秒判据断言恢复（这就是回归保护）；
##   找不到 → 如实报告"本次没搜到"，并说明这不等于真实游玩不会进这个状态。
##
## 搜到的组合会在日志里以 ★ 标出，并带上 0/4 持续时长与恢复用时。
func _flip_case_hunt(track: Node, arc: float) -> void:
	const HUNT_SECONDS := 4.0
	var angles := [5.0, 12.0, 25.0, 45.0, 70.0]
	var speeds := [60.0, 110.0]
	var prev_oob = _car.get("auto_reset_out_of_bounds")
	_car.set("auto_reset_out_of_bounds", false)
	var trials := 0
	var found := 0
	print("[自检]   用例 D 自动搜复现：%d 组（角度 × 速度）怼护栏 + 2 组高速翻转 + 4 组高空砸地，每组最多 %.0fs"
		% [angles.size() * speeds.size(), HUNT_SECONDS])
	for ang: float in angles:
		for kmh: float in speeds:
			trials += 1
			var r := await _flip_hunt_trial(track, arc, ang, kmh, "wall", HUNT_SECONDS)
			if bool(r["found"]):
				found += 1
				_report_hunt_finding("撞墙 %.0f° @ %.0fkm/h" % [ang, kmh], r)
			else:
				print("[自检]     试 %2.0f° @ %3.0fkm/h → 未出现持续贴地（0/4 最长 %.2fs，最低速 %.0f km/h）"
					% [ang, kmh, float(r["max_zero"]), float(r["min_kmh"])])
	for kmh: float in [80.0, 130.0]:
		trials += 1
		var r2 := await _flip_hunt_trial(track, arc, 0.0, kmh, "flip", HUNT_SECONDS)
		if bool(r2["found"]):
			found += 1
			_report_hunt_finding("高速翻转 @ %.0fkm/h" % kmh, r2)
		else:
			print("[自检]     试 高速翻转 @ %3.0fkm/h → 未出现持续贴地（0/4 最长 %.2fs）"
				% [kmh, float(r2["max_zero"])])
	for kmh: float in [0.0, 60.0]:
		for ang2: float in [0.0, 20.0]:
			trials += 1
			var r3 := await _flip_hunt_trial(track, arc, ang2, kmh, "drop", HUNT_SECONDS)
			if bool(r3["found"]):
				found += 1
				_report_hunt_finding("2.5m 砸地 %.0f° @ %.0fkm/h" % [ang2, kmh], r3)
			else:
				print("[自检]     试 2.5m 砸地 %2.0f° @ %3.0fkm/h → 未出现持续贴地（0/4 最长 %.2fs）"
					% [ang2, kmh, float(r3["max_zero"])])
	_car.set("auto_reset_out_of_bounds", prev_oob)
	if found > 0:
		print("[自检]   用例 D 结论：%d 组里搜到持续贴地 %d 组，每一组都已断言 ≤2s 恢复"
			% [trials, found])
	else:
		print("[自检]   用例 D 结论：%d 组都没搜到持续贴地 —— 如实报告" % trials)
		print("[自检]     ⚠ 这不等于真实游玩不会进这个状态：本次搜索只覆盖了"
			+ "直线怼墙与高速翻转，真实成因（例如特定地形/多车挤压）可能不在这里面。")


## 翻车恢复验收：用例 A（真实底朝天）+ 用例 B（合成腹部贴地，硬断言）
## + 用例 C（6 个真实姿态的复现尝试，证据收集）+ 用例 D（撞墙/翻车自动搜复现）。
func run_flip() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	# 关掉出界兜底：否则车滑远了会被瞬移回赛道，"到底有没有扶正"就被掩盖了
	var prev_oob = _car.get("auto_reset_out_of_bounds")
	_car.set("auto_reset_out_of_bounds", false)
	_car.set("auto_recover", true)
	_flip_reproduced = 0
	_flip_fails = 0
	var total := float(track.call("road_length"))
	var arc := 260.0
	if total < 400.0:
		arc = total * 0.3
	print("[自检] 翻车恢复验收：起点弧长 %.0fm（赛道全长 %.0fm）" % [arc, total])
	print("[自检]   用例 A 真实底朝天 → ≤2s 扶正；用例 B 合成腹部贴地 → ≤2s 触发恢复并落地")
	print("[自检]   用例 C 6 个真实姿态：收集证据（复现出持续贴地就必须 ≤2s 恢复）")
	print("[自检]   用例 D 自动搜复现：多种角度/速度撞墙 + 高速翻转，找真实成因")
	await _flip_case_inverted(track, arc)
	await _flip_case_hover(track, arc)
	await _flip_case_belly(track, arc, 0.0, 0.0, 0.55, "水平 · 落地高度+0.55")
	await _flip_case_belly(track, arc, 0.0, 0.0, 0.40, "水平 · 落地高度+0.40")
	await _flip_case_belly(track, arc, 0.0, 0.0, 0.25, "水平 · 落地高度+0.25")
	await _flip_case_belly(track, arc, 20.0, 0.0, 0.50, "滚转 20°")
	await _flip_case_belly(track, arc, 35.0, 0.0, 0.45, "滚转 35°")
	await _flip_case_belly(track, arc, 0.0, -18.0, 0.50, "俯仰 -18°")
	await _flip_case_hunt(track, arc)
	_car.set("auto_reset_out_of_bounds", prev_oob)
	_car.set("belly_test_hover", false)
	_car.call("reset_to_track")
	if _flip_fails == 0:
		print("[自检] 翻车恢复验收 ✔ 用例 A/B 全过；用例 C 复现持续贴地 %d/6 个（0 个只说明合成姿态造不出持续贴地，不代表没问题）"
			% _flip_reproduced)
	else:
		printerr("[自检] 翻车恢复验收 ✘ 失败 %d 项（用例 C 复现 %d/6 个）"
			% [_flip_fails, _flip_reproduced])
