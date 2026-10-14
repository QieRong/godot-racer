extends RefCounted
## 基础验收族（`--check=enclosure` / `reset` / `oob` / `minimap` / `resetkey` / `escape` /
## `pause`）：围墙全周封闭、复位落点、出界兜底、小地图（Board/RoadRing/CarMarker/障碍标记）、
## R 键保护与复位无敌帧、起点缺口原点复现、ESC 暂停（含跨场景「重新开始」阶段 2）。
## main.gd 的 `match _check:` 分发口经 `_checks_basic.run_enclosure()`（无 await）/
## `await _checks_basic.run_reset()` / `run_out_of_bounds()` / `run_minimap()` /
## `run_reset_key()` / `run_escape()` / `run_pause()` 进入本模块。
##
## 2026-10-14 SPLIT-CHECKS-BASIC-005a：从 scenes/main.gd 整块拆出，**纯迁移、行为零变化**
## —— 逻辑、print 文案（`[自检]` 前缀、缩进、✔/✘ 判定行、%占位顺序全部照搬，A/B 要逐行
## 比对日志）、注释全部照搬，没有第二份实现。
## 迁了什么：`_check_enclosure` → 公开入口 `run_enclosure`、`_check_reset` → `run_reset`、
## `_check_out_of_bounds` → `run_out_of_bounds`、`_check_minimap` → `run_minimap`、
## `_check_reset_key` → `run_reset_key`、`_check_escape` → `run_escape`、`_check_pause` →
## `run_pause`；私有 helper 保持原名与私有性：`_check_minimap_obstacles` /
## `_menu_press_escape`；另 `_cp`（找 order_index==0 的检查点）也随本族迁入 —— 它**只被
## `run_escape` 调用**，所以放消费方一侧（**与计划书把 `_cp` 放 lap 族相反**：计划书的
## helper 归属与实际调用方向正好交叉，照字面放会让两模块互相注入对方 Callable 形成环，
## 或被迫复制第二份 —— 放消费方 = 零耦合、零复制，且同样全部离开 main.gd）。
##
## ⚠ 三条关键决策（逐条定死，以后别悄悄改回去）：
##
##   ① **车 / 赛道 / 小地图 / 暂停菜单 / 障碍场 / 物理世界经 setup() 注入，模块不
##      get_node**：迁移前各 `_check_*` 入口用 `get_node_or_null("Track")`（7 处）、
##      `_check_minimap` 用 `get_node_or_null("Minimap")`、`_check_pause` 用
##      `get_node_or_null("PauseMenu")`（2 处）、`_check_minimap_obstacles` 用
##      `get_node_or_null("Obstacles")`、`_check_enclosure` 用 `get_world_3d()` —— 全改为注入
##      + 保留原 null 检查（§2.4：禁反向持有场景；layout / bench / ai / env_phys 同款约定）。
##      玩家车沿用 `_car` 字段名（main.gd 成员同名），注入后族内代码零 diff。
##      ⚠ `get_node_or_null("Obstacles")` 拿到的就是 main 的 `_obstacle_field` 本体
##      （它是 add_child 进树、name = "Obstacles" 的同一个节点），注入同一实例。
##      ⚠ 本族**不**用 HUD（`get_node_or_null("HUD")` 只出现在反向族的
##      `_find_wrong_way_panel`，那条随 lap 族外迁）；计划书说"pause/minimap/escape 族
##      要用 HUD"与实际不符 —— 这三族分别用 PauseMenu / Minimap / checkpoints，不需要 HUD。
##
##   ② **frame 信号与场景能力经注入提供**：迁移前帧循环里是 `await get_tree().physics_frame`
##      与 `await get_tree().process_frame`；模块是 RefCounted、不在场景树上，没有
##      get_tree()。照 env_phys / bench / ai 约定，`physics_frame` 经 main 的
##      `_shot_physics_frame`（返回 physics_frame 信号本体）以 Callable 递入，模块里
##      `await _physics_frame.call()` 与迁移前 `await get_tree().physics_frame` 是**同一个
##      Signal**，协程恢复时机不变（opponent_spawner 实证：多一层协程 = physics_frame 恢复
##      差 1 物理帧 = 25856 行日志发散）。其余**非信号**的 scene-tree 能力
##      （`process_frame` 信号 / `paused` 标志 / `get_nodes_in_group("checkpoints")` /
##      视口 `push_input`）统一走注入的 `SceneTree` 引用 —— 与 ai.gd 注入 `World3D`
##      （`get_world_3d()`）同属「注入引擎对象而非场景节点」，都不是 get_node、也不反向
##      持有场景（§2.4）。另有 1 个「场景能力」Callable：`_mark_keep_alive`
##      （`run_pause` 要置 main 的 `_keep_alive_after_check`，模块不得直接写 main 成员）。
##
##   ③ **await 数 = 12，一拍不加**：迁移前本族真实 await 12 处 —— 8 处帧循环的
##      physics_frame（注入后为 `await _physics_frame.call()`：run_reset 1 / run_reset_key 5 /
##      run_out_of_bounds 1 / run_escape 1）+ 3 处 `await _tree.process_frame`
##      （run_minimap 1 / run_pause 2）+ 1 处 `await _check_minimap_obstacles(mm)`
##      （run_minimap 内，本族私有）。main.gd 分发口的 `await _checks_basic.run_*()` 留在
##      main 自己那层协程 —— 协程深度与迁移前一致。由
##      split-checks-basic-structcheck.ps1 把这些形态钉死。
##
## ⚠ GameState / InputMap / Input / Engine 直接读全局（layout.gd / bench.gd 同款先例）：
##   GameState 是 autoload 单例、不是场景节点，直连不违反「禁反向持有场景」。
##
## ⚠ 为什么没有 class_name（与全部先例模块同一约定）：验收闸门在**无编辑器**环境跑
##   Godot，全局类缓存（.godot/global_script_class_cache.cfg）只有编辑器会重建；
##   2026-10-12 实测新增 class_name 后 `--check-only` 与游戏运行双双报
##   `Identifier not declared`。消费方一律
##   `const ChecksBasic := preload("res://scripts/checks/basic.gd")`。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car = $RaceCar）。字段名沿用 main 的成员名 → 族内代码零 diff。
var _car: VehicleBody3D = null
## 赛道（迁移前是各 _check_* 里 get_node_or_null("Track") 的静态兄弟节点）。由 setup() 注入。
var _track: Node = null
## 小地图节点（迁移前是 _check_minimap 里 get_node_or_null("Minimap")）。由 setup() 注入。
var _minimap: Node = null
## 暂停菜单 CanvasLayer（迁移前是 _check_pause 里 get_node_or_null("PauseMenu")）。由 setup() 注入。
var _pause_menu: Node = null
## 障碍物场（迁移前是 _check_minimap_obstacles 里 get_node_or_null("Obstacles")，与 main 的
## _obstacle_field 是同一节点本体）。由 setup() 注入。
var _obstacle_field: Node3D = null
## 物理世界（迁移前是 _check_enclosure 里 get_world_3d()）。由 setup() 注入。
var _world_3d: World3D = null
## 场景树（非信号能力：process_frame 信号 / paused / 分组查询 / 视口输入）。由 setup() 注入。
var _tree: SceneTree = null
## physics_frame 信号提供者（main.gd 的 _shot_physics_frame）。由 setup() 注入；
## 模块里 `await _physics_frame.call()` 取代 `await get_tree().physics_frame`，
## 是同一个 Signal，协程恢复时机不变（文件头决策 ②③）。
var _physics_frame: Callable = Callable()
## 置 main 的 _keep_alive_after_check（run_pause 重载场景时用；场景能力 Callable 注入，见文件头决策 ②）。
var _mark_keep_alive: Callable = Callable()


## 注入外部引用（main.gd 在 _after_world_ready 里调用一次）。
func setup(car: VehicleBody3D, track: Node, minimap: Node,
		pause_menu: Node, obstacle_field: Node3D, world_3d: World3D,
		tree: SceneTree, physics_frame: Callable, mark_keep_alive: Callable) -> void:
	_car = car
	_track = track
	_minimap = minimap
	_pause_menu = pause_menu
	_obstacle_field = obstacle_field
	_world_3d = world_3d
	_tree = tree
	_physics_frame = physics_frame
	_mark_keep_alive = mark_keep_alive


# ======================== 复位验收（--check=reset）========================
#
## 复位验收：把车放到赛道外的 8 个方位，调用 reset_to_track()，
## 要求每次都落回赛道路面内（离中心线 < 路面半宽）。
func run_reset() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var road_half := float(track.call("road_half_width"))
	var bearings: Array[Vector3] = [
		Vector3(120, 0.6, 120), Vector3(-120, 0.6, 120),
		Vector3(120, 0.6, -120), Vector3(-120, 0.6, -120),
		Vector3(360, 0.6, 0), Vector3(-360, 0.6, 0),
		Vector3(0, 0.6, 260), Vector3(0, 0.6, -260),
	]
	var fails := 0
	print("[自检] 复位验收：8 个赛道外方位，逐个瞬移后调用 reset_to_track()")
	for i in range(bearings.size()):
		var p: Vector3 = bearings[i]
		_car.global_position = p
		_car.linear_velocity = Vector3.ZERO
		_car.angular_velocity = Vector3.ZERO
		_car.call("reset_to_track")
		var after: Vector3 = _car.global_position
		var near := track.call("nearest_on_centerline", after, -1.0) as Dictionary
		var dev := float(near.get("dist", 999.0))
		var ok := dev < road_half
		if not ok:
			fails += 1
		print("[自检]   方位%d 从 %s → %s  离中心线 %.2fm  %s"
			% [i + 1, p, after, dev, "✔" if ok else "✘ 不在路面上"])
		await _physics_frame.call()
	print("[自检] 复位验收：%d/%d 成功%s" % [bearings.size() - fails, bearings.size(),
		" ✔" if fails == 0 else " ✘"])


# ======================== 出界兜底验收（--check=oob）========================
#
## 出界兜底验收：把车放到界外静置，等自动拉回。
func run_out_of_bounds() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var road_half := float(track.call("road_half_width"))
	var p := Vector3(360.0, 0.6, 0.0)
	_car.global_position = p
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	print("[自检] 出界兜底：把车放到 %s（界外）静置，等待自动拉回…" % p)
	var frames := 0
	var fired := false
	while frames < 60 * 6:
		frames += 1
		await _physics_frame.call()
		var after: Vector3 = _car.global_position
		if after.distance_to(p) > 5.0:
			fired = true
			var near := track.call("nearest_on_centerline", after, -1.0) as Dictionary
			print("[自检] 出界兜底：第 %.1fs 被拉回 → %s  离中心线 %.2fm %s"
				% [float(frames) / 60.0, after, float(near.get("dist", 999.0)),
				   "✔" if float(near.get("dist", 999.0)) < road_half else "✘"])
			break
	if not fired:
		printerr("[自检] 出界兜底 ✘ 6 秒内没有被拉回")


# ======================== R 键保护 + 复位无敌帧验收（--check=resetkey）========================
#
## R 键保护 + 复位无敌帧验收
func run_reset_key() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	# 1) 车贴着中心线且未翻车：按 R 应该只扶正、**不传送**
	_car.global_position = Vector3(320.0, 0.55, 0.0)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	for i in range(5):
		await _physics_frame.call()
	var before: Vector3 = _car.global_position
	_car.call("request_reset")
	await _physics_frame.call()
	var after: Vector3 = _car.global_position
	var moved := before.distance_to(after)
	print("[自检] R 键保护：车在中心线旁按 R → 位移 %.2fm  %s"
		% [moved, "✔ 只扶正未传送" if moved < 0.6 else "✘ 不该传送"])

	# 2) 翻车时按 R 应该复位（这里直接用"离中心线很远"来触发复位分支）
	_car.global_position = Vector3(360.0, 0.6, 0.0)
	await _physics_frame.call()
	_car.call("request_reset")
	await _physics_frame.call()
	var near := track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary
	print("[自检] 界外按 R → 落点离中心线 %.2fm  %s"
		% [float(near.get("dist", 999.0)),
		   "✔ 已回赛道" if float(near.get("dist", 999.0)) < float(track.call("road_half_width")) else "✘"])

	# 3) 无敌帧：复位后应处于无敌，之后应自动恢复。
	# 注意物理帧在这台工程里是 120Hz（project.godot: physics_ticks_per_second=120），
	# 所以"等 N 个 physics_frame"其实是 N/120 秒 —— 我第一版按 60 算，等少了，误判成没恢复。
	var physics_hz := float(Engine.physics_ticks_per_second)
	# reset_immunity_time 是车上的导出属性（main.gd 里没有这个符号，别直接引用）
	var immune_time := float(_car.get("reset_immunity_time"))
	var immune_now := bool(_car.call("is_reset_immune"))
	var samples: Array[String] = []
	var waited := 0.0
	while waited < immune_time + 0.8:
		await _physics_frame.call()
		waited += 1.0 / physics_hz
		if int(waited * 2.0) != int((waited - 1.0 / physics_hz) * 2.0):
			samples.append("%.1fs=%s" % [waited, str(_car.call("is_reset_immune"))])
	var immune_after := bool(_car.call("is_reset_immune"))
	print("[自检] 复位无敌帧：刚复位 immune=%s（应 true）；%.1fs 后 immune=%s（应 false）  %s"
		% [immune_now, waited, immune_after,
		   "✔" if (immune_now and not immune_after) else "✘"])
	print("[自检]   物理帧率=%dHz 采样：%s" % [Engine.physics_ticks_per_second, " ".join(samples)])


# ======================== 小地图验收（--check=minimap）========================
#
## 小地图验收：确认小地图世界搭起来了、相机对得上、车点在动。
func run_minimap() -> void:
	var mm := _minimap
	if mm == null:
		printerr("[CHECK] 找不到 Minimap 节点")
		return
	var board := mm.get_node_or_null("Board") as MeshInstance3D
	var ring := mm.get_node_or_null("RoadRing") as MeshInstance3D
	var marker := mm.get_node_or_null("CarMarker") as Node3D
	print("[自检] 小地图节点：Board=%s RoadRing=%s CarMarker=%s"
		% ["有" if board != null else "缺", "有" if ring != null else "缺",
		   "有" if marker != null else "缺"])
	if board != null:
		var bm := board.mesh as BoxMesh
		print("[自检]   底板 size=%s 位置=%s" % [bm.size, board.position])
	if ring != null:
		print("[自检]   路面环 顶点数=%d 位置=%s" % [ring.mesh.get_surface_count(), ring.position])
	for n in mm.get_children():
		if n is MeshInstance3D:
			var mi: MeshInstance3D = n
			var aabb: AABB = mi.get_aabb()
			print("[自检]   %s 世界AABB pos=%s size=%s" % [mi.name, aabb.position, aabb.size])
	var vp := mm.get_node_or_null("SubViewport") as SubViewport
	if vp != null:
		print("[自检]   SubViewport size=%s update=%d world=%s children=%d"
			% [vp.size, vp.render_target_update_mode, vp.world_3d, vp.get_child_count()])
		var cam := vp.get_node_or_null("TopCam") as Camera3D
		if cam != null:
			print("[自检]   TopCam pos=%s size=%.1f cull_mask=%d" % [cam.global_position, cam.size, cam.cull_mask])
	# 车点是否跟着车动：等几帧看它有没有挪位
	if marker != null and _car != null:
		var before: Vector3 = marker.global_position
		var car_before: Vector3 = _car.global_position
		_car.global_position = car_before + Vector3(40.0, 0.0, 40.0)
		for i in range(3):
			await _tree.process_frame
		var after: Vector3 = marker.global_position
		print("[自检]   车点跟随：车 %s → %s ；车点 %s → %s  %s"
			% [car_before, _car.global_position, before, after,
			   "✔" if after.distance_to(before) > 30.0 else "✘ 没动"])
		_car.global_position = car_before
	# ---- 障碍物标记：必须有、必须在相机的可视范围内、必须在 MAP_LAYER ----
	# 为什么用"硬校验"而不是看截图：小地图只有 200 来像素，红点小到肉眼难分辨，
	# "截图上好像有"不能算证据。这里直接量标记的世界坐标有没有落在相机视野内。
	await _check_minimap_obstacles(mm)


## 校验小地图上的障碍物标记（数量 / 图层 / 是否落在相机视野内）。
func _check_minimap_obstacles(mm: Node) -> void:
	var obs := _obstacle_field
	if obs == null:
		print("[自检]   障碍物标记：本关没有障碍物节点，跳过 ⊘")
		return
	var positions: Array = obs.call("marker_positions")
	var markers: Array = mm.get("obstacle_markers")
	print("[自检]   障碍物标记：障碍 %d 个，小地图标记 %d 个"
		% [positions.size(), markers.size()])
	if positions.is_empty():
		print("[自检]   障碍物标记：本关障碍数为 0，跳过 ⊘")
		return
	if markers.size() != positions.size():
		printerr("[自检]   ✘ 标记数量与障碍数量不一致")
		return
	var vp := mm.get_node_or_null("SubViewport") as SubViewport
	var cam: Camera3D = null
	if vp != null:
		cam = vp.get_node_or_null("TopCam") as Camera3D
	var inside := 0
	var wrong_layer := 0
	# 相机是正交俯视：用 size（正交高度）和 viewport 宽高比算可视矩形
	var half_h := 0.0
	var half_w := 0.0
	if cam != null and vp != null:
		half_h = cam.size * 0.5
		half_w = half_h * float(vp.size.x) / maxf(float(vp.size.y), 1.0)
	var cpos := cam.global_position if cam != null else Vector3.ZERO
	for i in range(markers.size()):
		var holder := markers[i] as Node3D
		if holder == null or not is_instance_valid(holder):
			continue
		# 标记是个 Node3D 容器，取它第一个 MeshInstance3D 来判图层
		var sample: MeshInstance3D = null
		for c in holder.get_children():
			if c is MeshInstance3D:
				sample = c
				break
		if sample != null and sample.layers != (1 << 16):
			wrong_layer += 1
		var p := holder.global_position
		if cam == null or (absf(p.x - cpos.x) <= half_w and absf(p.z - cpos.z) <= half_h):
			inside += 1
	if wrong_layer == 0:
		print("[自检]   ✔ 全部标记都在小地图图层（1<<16），主视角不会看到")
	else:
		printerr("[自检]   ✘ %d 个标记的渲染层不对，会漏进主视角" % wrong_layer)
	if cam == null:
		print("[自检]   找不到 TopCam，无法校验视野 ⊘")
	elif inside == markers.size():
		print("[自检]   ✔ 全部 %d 个障碍标记都落在小地图相机视野内（半宽 %.0f 半高 %.0f）"
			% [inside, half_w, half_h])
	else:
		printerr("[自检]   ✘ 只有 %d/%d 个障碍标记在视野内，其余会看不见"
			% [inside, markers.size()])


# ======================== 起点缺口原点复现验收（--check=escape）========================
#
## 按 order_index 找检查点节点（run_escape 用；group 查询走注入的 _tree，不用 get_tree()）。
func _cp(order: int) -> Node3D:
	for node in _tree.get_nodes_in_group("checkpoints"):
		if int(node.get("order_index")) == order:
			return node as Node3D
	return null


## 原点复现验收：从起点起步、满油门 + 打满方向**直冲原来那个缺口**，
## 全程记录离中心线的最大偏离，要求始终没穿出围墙通道。
## 这是用户报的"起点旁边能从旁边开出去"的回归测试。
func run_escape() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var rail_half := float(track.call("rail_half_width"))
	# 摆回起点区（起终点门后 2.5m），关掉自动兜底，免得它把车拉走掩盖问题
	var gate := _cp(0)
	if gate != null:
		_car.global_position = gate.global_position - Vector3(0, 0, 2.5)
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	_car.set("auto_recover", false)
	_car.set("auto_reset_out_of_bounds", false)
	print("[自检] 原点复现：从 %s 起步，满油门 + 打满方向冲 12 秒，看能否穿出围墙（护栏在 %.1fm）"
		% [_car.global_position, rail_half])
	var max_dev := 0.0
	var max_speed := 0.0
	var frames := 0
	# 左舵、右舵各试一轮（原来那个口子在缝的一侧）
	for direction: int in [1, -1]:
		_car.global_position = gate.global_position - Vector3(0, 0, 2.5) if gate != null else _car.global_position
		_car.linear_velocity = Vector3.ZERO
		for i in range(int(Engine.physics_ticks_per_second) * 12):
			Input.action_press("accelerate")
			Input.action_press("steer_left" if direction > 0 else "steer_right")
			await _physics_frame.call()
			frames += 1
			var near := track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary
			max_dev = maxf(max_dev, float(near.get("dist", 0.0)))
			max_speed = maxf(max_speed, _car.linear_velocity.length())
			if bool(_car.call("is_reset_immune")):
				break
		Input.action_release("accelerate")
		Input.action_release("steer_left")
		Input.action_release("steer_right")
		print("[自检]   %s满舵 12 秒结束：当前偏离 %.2fm"
			% ["左" if direction > 0 else "右",
			   float((track.call("nearest_on_centerline", _car.global_position, -1.0) as Dictionary).get("dist", 0.0))])
	print("[自检] 原点复现：%d 帧内最大偏离中心线 %.2fm（护栏 %.1fm），最高速度 %.1f m/s  %s"
		% [frames, max_dev, rail_half, max_speed,
		   "✔ 没能穿出去" if max_dev < rail_half else "✘ 有穿墙风险"])


# ======================== 暂停菜单验收（--check=pause）========================
#
## 暂停菜单验收：ESC 能暂停、能选"重新开始"、重开后状态是干净的。
##
## 这条链路以前从没被验证过 —— 代码写得挺完整，但"没人按过 ESC"。
## 所以这里**喂真实按键事件**（Input.parse_input_event）而不是直接调 pause()，
## 走的就是玩家按 ESC 的那条路：ui_cancel → _unhandled_input → pause()。
##
## 分两阶段：点"重新开始"会 reload_current_scene，本脚本会在新场景里**再跑一次**
## （--check 参数还在命令行里）。所以用 GameState 的 meta 当跨场景标记
## （autoload 不随场景重载销毁），第二阶段只做"重开后状态是否干净"的确认。
func run_pause() -> void:
	var menu := _pause_menu
	# ---------- 第二阶段：刚刚点了"重新开始"，现在验证新场景是干净的 ----------
	if GameState.has_meta("pause_restart_pending"):
		GameState.remove_meta("pause_restart_pending")
		var ok2 := true
		print("[自检] 暂停验收·阶段2：重开后的新场景已就绪，检查初始状态")
		if _tree.paused:
			printerr("[自检]   ✘ 重开后游戏仍处于暂停状态")
			ok2 = false
		else:
			print("[自检]   ✔ 重开后未处于暂停")
		var laps := int(_car.get("laps_done")) if _car != null else -1
		var lap_last := float(_car.get("lap_last")) if _car != null else -1.0
		var pos := _car.global_position if _car != null else Vector3.ZERO
		print("[自检]   新场景：圈数=%d 上圈=%.3f 位置=%s" % [laps, lap_last, pos])
		if laps != 0 or lap_last > 0.001:
			printerr("[自检]   ✘ 重开后计圈状态没清零（圈数=%d 上圈=%.3f）" % [laps, lap_last])
			ok2 = false
		else:
			print("[自检]   ✔ 计圈状态已清零（重新开始是「干净」的）")
		var m2 := _pause_menu
		if m2 != null and bool(m2.get("visible")):
			printerr("[自检]   ✘ 重开后暂停菜单仍然可见")
			ok2 = false
		else:
			print("[自检]   ✔ 暂停菜单已隐藏")
		if ok2:
			print("[自检] 暂停验收 ✔ ESC 暂停 → 选「重新开始」→ 新场景状态干净")
		else:
			printerr("[自检] 暂停验收 ✘ 见上方 ✘ 行")
		return

	# ---------- 第一阶段：验证 ESC 暂停 + 菜单内容 ----------
	var ok := true
	if menu == null:
		printerr("[自检] 暂停验收 ✘ 找不到 PauseMenu 节点")
		return
	# ① ESC 是否真的映射到 ui_cancel（这是"按 ESC 有没有用"的前提）
	var esc_mapped := false
	for e in InputMap.action_get_events("ui_cancel"):
		if e is InputEventKey:
			var k: InputEventKey = e
			if k.physical_keycode == KEY_ESCAPE or k.keycode == KEY_ESCAPE:
				esc_mapped = true
	print("[自检] 暂停验收：ui_cancel 绑定 ESC = %s" % str(esc_mapped))
	if not esc_mapped:
		printerr("[自检]   ✘ ESC 没有映射到 ui_cancel，玩家按 ESC 不会有反应")
		ok = false
	# ② 初始状态
	print("[自检]   初始：paused=%s 菜单可见=%s" % [str(_tree.paused), str(menu.visible)])
	if _tree.paused or bool(menu.get("visible")):
		printerr("[自检]   ✘ 初始状态就不对（应该是未暂停且菜单隐藏）")
		ok = false
	# ③ 喂一个真实的 ESC 按键事件
	_menu_press_escape()
	for i in range(4):
		await _tree.process_frame
	print("[自检]   按下 ESC 后：paused=%s 菜单可见=%s"
		% [str(_tree.paused), str(menu.get("visible"))])
	if not _tree.paused:
		printerr("[自检]   ✘ ESC 没有让游戏暂停")
		ok = false
	if not bool(menu.get("visible")):
		printerr("[自检]   ✘ ESC 没有让暂停菜单显示出来")
		ok = false
	# ④ 菜单里必须有四个选项，且文字要好认
	var labels: Array[String] = []
	for b in (menu.get("_buttons") as Array):
		if b is Button:
			labels.append((b as Button).text)
	print("[自检]   菜单选项：%s" % str(labels))
	for want in ["继续游戏", "重新开始", "返回选关", "退出游戏"]:
		if not (want in labels):
			printerr("[自检]   ✘ 缺少选项「%s」" % want)
			ok = false
	if not (("重新开始" in labels) and ("返回选关" in labels)):
		printerr("[自检]   ✘ 玩家没法重开或返回选关")
		ok = false
	# ⑤ 再按一次 ESC 应该恢复。
	# ⚠ 这一步必须**以第③步真的暂停成功为前提**：否则"恢复"会假通过
	# —— 从没暂停过，检查"现在没暂停"当然成立。第一版就是这么骗过自己的。
	if not _tree.paused:
		printerr("[自检]   ✘ 跳过恢复检查：前面就没暂停成功，此时的「未暂停」不算数")
	else:
		_menu_press_escape()
		for i in range(4):
			await _tree.process_frame
		print("[自检]   再按 ESC：paused=%s 菜单可见=%s"
			% [str(_tree.paused), str(menu.get("visible"))])
		if _tree.paused or bool(menu.get("visible")):
			printerr("[自检]   ✘ 再按 ESC 没有恢复游戏")
			ok = false
		else:
			print("[自检]   ✔ 再按 ESC 已恢复")
	if not ok:
		printerr("[自检] 暂停验收 ✘（阶段1：ESC 暂停）")
		return
	# ⑥ 点"重新开始"：走真实的按钮回调，然后跨场景验证（阶段2）
	print("[自检]   阶段1 通过，现在模拟点击「重新开始」…")
	GameState.set_meta("pause_restart_pending", true)
	_mark_keep_alive.call()            # 重载后由新场景收尾，本场景不要退出
	var pressed_restart := false
	for b in (menu.get("_buttons") as Array):
		if b is Button and (b as Button).text == "重新开始":
			(b as Button).emit_signal("pressed")
			pressed_restart = true
			break
	if not pressed_restart:
		printerr("[自检]   ✘ 找不到「重新开始」按钮，无法验证重开")
		GameState.remove_meta("pause_restart_pending")
		printerr("[自检] 暂停验收 ✘")


## 造一个真实的 ESC 按下事件喂给**视口**，走玩家按 ESC 的同一条链路。
##
## 为什么用 push_input 而不是 Input.parse_input_event：
##   parse_input_event 是"模拟操作系统级输入"，实测在验收环境里喂进去之后
##   PauseMenu._unhandled_input **收不到**（paused 一直是 false，看起来像
##   "ESC 暂停坏了"）。push_input 直接推进 Viewport 的输入管线，
##   也就是 _input/_unhandled_input 真正监听的那一条，才能测到真实行为。
## ⚠ 视口经注入的 _tree 取根视口（_tree.root 就是 main 的 get_viewport() 那个根 Window），
##   模块是 RefCounted、没有 get_viewport()。
func _menu_press_escape() -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_ESCAPE
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	_tree.root.push_input(ev)


# ======================== 围墙封闭验收（--check=enclosure）========================
#
func run_enclosure() -> void:
	var track := _track
	if track == null:
		printerr("[CHECK] 找不到 Track 节点")
		return
	var total := float(track.get("_road_length"))
	var rail_half := float(track.call("rail_half_width"))
	var space := _world_3d.direct_space_state
	var params := PhysicsRayQueryParameters3D.new()
	params.collision_mask = 1          # 只打 terrain（空气墙/路面都在 layer 1）
	params.collide_with_areas = false
	var step := 0.1
	var d := 0.0
	var samples := 0
	var misses := 0
	var first_miss := -1.0
	var last_miss := -1.0
	var hit_dist_min := INF
	var hit_dist_max := 0.0
	# 把缺口按"连续区间 + 侧别"汇总，一眼看出是散点还是成段
	var runs: Array = []
	var cur_side := ""
	var cur_start := -1.0
	var cur_end := -1.0
	while d < total:
		var pos := Vector3(track.call("centerline_point", d))
		var fwd := Vector3(track.call("centerline_forward", d))
		var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
		for s: float in [-1.0, 1.0]:
			# 从**中心线**朝一侧打出去（不是从墙的位置起打：起点正好落在墙面上时
			# 射线会与墙面共面而打空，那是测量方法的假阳性，不是真的缺口）
			var origin: Vector3 = pos + Vector3.UP * 0.6
			params.from = origin
			params.to = origin + side * s * 60.0
			samples += 1
			var sname := "左" if s > 0.0 else "右"
			var hit := space.intersect_ray(params)
			if hit.is_empty():
				misses += 1
				if first_miss < 0.0:
					first_miss = d
				last_miss = d
				if cur_side == sname and d - cur_end <= step * 1.5:
					cur_end = d
				else:
					if cur_start >= 0.0:
						runs.append([cur_side, cur_start, cur_end])
					cur_side = sname
					cur_start = d
					cur_end = d
			else:
				var hd := origin.distance_to(hit["position"])
				hit_dist_min = minf(hit_dist_min, hd)
				hit_dist_max = maxf(hit_dist_max, hd)
		d += step
	if cur_start >= 0.0:
		runs.append([cur_side, cur_start, cur_end])
	print("[自检] 命中距离范围 %.2f ~ %.2f m（护栏中心线应在 %.2f m 附近）"
		% [hit_dist_min, hit_dist_max, rail_half])
	print("[自检] 缺口共 %d 段（按侧别/连续性合并）：" % runs.size())
	for r in runs:
		print("[自检]   %s侧 弧长 %.1f ~ %.1f m（长 %.1f m）" % [r[0], r[1], r[2], float(r[2]) - float(r[1]) + step])
	print("[自检] 围墙封闭：弧长 %.1fm 上每 %.1fm 两侧各一条射线，共 %d 条，缺口 %d 条"
		% [total, step, samples, misses])
	if misses == 0:
		print("[自检] 围墙封闭 ✔ 全周无缺口（含起终点缝）")
	else:
		printerr("[自检] 围墙封闭 ✘ 有 %d 条射线打不到墙，弧长 %.1f ~ %.1f m"
			% [misses, first_miss, last_miss])
	# 顺便报一下物理节点数，确认没有按段拆节点
	var body_count := 0
	for c in track.get_children():
		if c is StaticBody3D:
			body_count += 1
	print("[自检] 赛道下 StaticBody3D 物理节点数 = %d（应远小于路段数）" % body_count)
