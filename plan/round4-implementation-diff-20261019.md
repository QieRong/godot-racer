# 实施 diff 清单（ENG-2026-10-19-01 · v1.0 · 2026-10-19 17:20）

> **用途**：用户确认本清单后，另出 TDD 交接文案；新对话按 A/B/C/D 四步实施。
> **基线**：HEAD `0cb669d`，工作区仅 2 个 `.import` 噪声。所有行号为当前实测行号。
> **决策绑定**：D1 统一原点（修订 R6）· D2 冻结带重冻结 · D3 龙门架带碰撞 · D4 AC-13 降级。
> **纪律**：TDD 先红后绿；不为变绿放宽判据；验收项数不变（Quick 15 / 全量 20）。

---

## 0. 先回答「加倒计时状态机 / 改 AI 生成时机」：**零代码改动**

用户清单里这两项，现行代码**已经成立**，不需要写任何代码，只补回归断言：

| 用户条目 | 现状（证据） | 本次动作 |
|---|---|---|
| 加倒计时状态机 | COUNTDOWN 相位已存在（`scripts/game_state.gd:27`）；树暂停（`:140-146`）；玩家输入锁 `start_locked`（vehicle.gd，装配期置真）；AI 锁 `armed=false`（`scripts/ai_opponent.gd:417-420`）——四重锁死 | **不改**。`game_state.gd`/`start_countdown.gd` 一个字不动 |
| 改 AI 生成时机 | AI 在装配期生成（`scenes/main.gd:316-322`），早于 `:345 enter_countdown()`——倒计时数字「3」出现时 AI 已在起跑格；旧「玩家动了才生成」规则 2026-10-18 已删除 | **不改**。`opponent_spawner.gd`/`ai_opponent.gd` 一个字不动；只在测试里加「倒计时期间 AI 在场未发车」断言（A-4） |

**明确不碰的文件**：`game_state.gd`、`start_countdown.gd`、`opponent_spawner.gd`、`ai_opponent.gd`、`scripts/checks/*.gd`、`data/levels/level_*.tres`、`project.godot`、`race_car.tscn`、任何 `.tscn`。

---

## 1. 提交 A：统一计时原点（5 个文件，必须同一提交）

### A-1 `godot-racer/scripts/vehicle.gd`（+33 行；1413 → ~1446，登记在册超限不阻塞）

**Hunk A-1.1** —— 新增压线标志。位置：L103（`var laps_target := 0`）之后。

```gdscript
 var laps_target := 0
+var start_line_crossed := false   # 已压过起点线。GO 锚定圈钟后首发压线只标记不完圈；
+                                  # race_position.gd 进度公式读它 —— 勿改语义。
 var tuned_max_speed := 0.0
```

**Hunk A-1.2** —— 新增 GO 锚定方法。位置：L555-558（`current_lap_time()`）之后。

```gdscript
 func current_lap_time() -> float:
 	if not _lap_running:
 		return 0.0
 	return Time.get_ticks_msec() / 1000.0 - _lap_start_ms
+
+## 由 main 唯一发车回调 _on_race_go() 调用（仅互动路径）：圈钟与总时间同一时刻起算。
+## R6 修订（2026-10-19 用户拍板 D1）：本圈也从「出发！」起算、首圈含起跑爬行，
+## 于是 总时间 ≡ 各圈之和，「起步」段恒为 0。go_ms 传 GameState.race_start_ms。
+## 幂等：_lap_running 已为真直接返回（重复 GO 不重新起表）。
+func begin_lap_timing(go_ms := -1) -> void:
+	if _lap_running:
+		return
+	_lap_running = true
+	_lap_start_ms = (go_ms / 1000.0) if go_ms > 0.0 else (Time.get_ticks_msec() / 1000.0)
+	print("[计圈] 圈钟已由「出发！」锚定（首圈含起跑段，与总时间同原点）")
```

**Hunk A-1.3** —— `_on_lap_crossed()` 首发压线分支改写。位置：L508-527 整体替换。

```gdscript
 func _on_lap_crossed() -> void:
 	var now := Time.get_ticks_msec() / 1000.0
 	if not _lap_running:
-		_lap_running = true
-		_lap_start_ms = now
-		print("[计圈] 开始计时（第一次压线）pos=%s 速度=%.1f km/h"
-			% [global_position, linear_velocity.length() * 3.6])
-		return
+		# 自动化路径（--check / --shot，无「出发！」事件）：首发压线即起表 ——
+		# 旧口径原样保留，lap/stress 等既有圈速证据零变化。
+		_lap_running = true
+		_lap_start_ms = now
+		start_line_crossed = true
+		print("[计圈] 开始计时（第一次压线）pos=%s 速度=%.1f km/h"
+			% [global_position, linear_velocity.length() * 3.6])
+		return
+	if not start_line_crossed:
+		# 互动路径：圈钟已由 begin_lap_timing() 在 GO 锚定 → 首发压线只标记，
+		# 不完圈、不重新起表（首圈含起跑段，R6 修订 D1）。
+		start_line_crossed = true
+		print("[计圈] 首发压线已标记（圈速自「出发！」起算，含起跑段）pos=%s 速度=%.1f km/h"
+			% [global_position, linear_velocity.length() * 3.6])
+		return
 	var lap := now - _lap_start_ms
 	lap_last = lap
 	laps_done += 1
 	# ……以下原样不动：lap_best / _lap_start_ms=now / print / lap_completed.emit /
 	#     race_finished.emit（L519-527 原文保留）
```

**Hunk A-1.4** —— 两个重置点补 flag 清零（防御性；重开实际走整场景重载）。

```gdscript
 # 位置一：_reset_lap_state()（L149-166），在 _lap_suppressed = true 之后插入
 	_lap_suppressed = true
+	start_line_crossed = false
 	laps_done = 0
```

```gdscript
 # 位置二：_release_lap_suppression()（L169-177），在 _prev_line_signed = -1.0 之后插入
 	_prev_line_signed = -1.0
+	start_line_crossed = false
 	print("[计圈] 计圈已就绪（出生位置不计圈，出发后第一次压线才开始计时）")
```
> 注：该 print 文案在 D1 后对互动路径已不准确（现在是「出发即起表」），同步改为：
> `print("[计圈] 计圈已就绪（互动路径圈钟由「出发！」锚定；自动化路径首次压线起表）")`

### A-2 `godot-racer/scripts/race_position.gd`（±8 行；陷阱修复，必须与 A-1 同提交）

位置：L124-126。

```gdscript
 	var crossings := int(_player.get("laps_done"))
-	if _player.has_method("current_lap_time") and float(_player.call("current_lap_time")) > 0.0:
-		crossings += 1
+	# 2026-10-19（R6 修订 D1）：GO 锚定圈钟后 current_lap_time() 从出发起就 >0，
+	# 不能再当压线判据（否则玩家进度瞬间多出整整一圈、名次错乱）—— 改读压线标志。
+	if bool(_player.get("start_line_crossed")):
+		crossings += 1
```
`get()` 缺失返回 null → `bool(null)` = false，安全降级；AI 侧公式（`ai_opponent.gd:917`）不动。

### A-3 `godot-racer/scenes/main.gd`（+6 行；886 → ~892）

**Hunk A-3.1** —— 函数文档注释补一行。位置：L367（③ 行）之后。

```gdscript
 ##   ③ GameState 切 RACING + 解冻 + 盖总时间起点 race_start_ms（start_race，R15）
+##   ③'（2026-10-19 D1）start_race() 返回真时（仅互动路径）紧接着
+##      _car.begin_lap_timing(race_start_ms) —— 圈钟与总时间同一时刻起算。
 ## ⚠ ③ 不能用 begin_race()：它会 release_drive_input() 吞掉按住的方向键。
```

**Hunk A-3.2** —— 函数体门控。位置：L369-375。

```gdscript
 func _on_race_go() -> void:
 	_car.start_locked = false
 	_opponent_spawner.arm_opponents()
-	GameState.start_race()
+	# start_race() 仅在 COUNTDOWN→RACING 时返回真：互动路径返回真 → 接着锚定圈钟；
+	# 自动化路径（aistart/aidiag，相位在 begin_race() 时已是 RACING）返回假 →
+	# 圈钟保持「首次压线」旧口径，验收路径逐字节不变。
+	if GameState.start_race():
+		_car.begin_lap_timing(GameState.race_start_ms)
 	_check_evidence.event("GO", "race", {"player_start_locked": _car.start_locked,
 		"opponent_count": _opponents.size()})
 	print("[main] 出发！玩家与 %d 台对手同步发车（总时间从此刻起算）" % _opponents.size())
```
> 顺序保持原 ①②③（arm 不动）；`begin_lap_timing` 读 `start_race()` 刚盖的 `race_start_ms`，两时钟同一时刻；四步仍同一回调 → 下一物理帧同时生效。E6 不受影响（不碰输入）。

### A-4 `godot-racer/tests/countdown_scene_test.gd`（+约 55 行）

**Hunk A-4.1** —— ④-C 回归守护。插入位置：L167（④-B 的 `for _i in range(8): await process_frame`）之后、L168（`# ⑤ 同步发车`）之前。

```gdscript
	# ④-C 回归守护（2026-10-19 D1 轮新增）：倒计时期间 AI 必须已在场且未发车。
	# 守护的"已知坏状态"是旧规则「加载即 arm」——若有人改回去，这里必红。
	var grid_ai: Array = game.get("_opponents")
	_check(grid_ai.size() >= 1, "AI 在倒计时期间已在起跑格（got %d）" % grid_ai.size())
	var ai_idle_ok := true
	var ai_beside_ok := true
	for ai in grid_ai:
		if bool(ai.get("armed")):
			ai_idle_ok = false
		if car.global_position.distance_to(ai.global_position) > 6.0:
			ai_beside_ok = false
	_check(ai_idle_ok, "倒计时期间全部 AI 未发车（armed=false）")
	_check(ai_beside_ok, "倒计时期间 AI 与玩家并排在起跑区（<6m）")

```

**Hunk A-4.2** —— ⑤-B/C/D 统一原点断言。插入位置：L185（`_check(float(_getp(state, "race_start_ms", 0.0)) > 0.0, "GO stamps race_start_ms")`）之后、L186（`# ⑥ E6`）之前。

```gdscript
	# ⑤-B 统一计时原点（D1）：GO 即锚定圈钟 —— 本圈从 0 起走、尚未压线。
	# 对 HEAD 必红（现状 GO 不锚定，current_lap_time() 在首发压线前恒 0）。
	_check(float(car.call("current_lap_time")) > 0.0,
		"GO anchors the lap clock (lap 1 starts at GO, includes launch crawl)")
	_check(int(car.get("laps_done")) == 0 and not bool(car.get("start_line_crossed")),
		"GO 后尚未压线：laps_done=0 且 start_line_crossed=false")
	# ⑤-C 陷阱守护：未压线时玩家进度不得含 +1 圈。
	# 只改 vehicle.gd 不改 race_position.gd → 此条必红（现存把守者是
	# race_position_scene_test.gd:63 的名次断言，这里双保险）。
	var track: Node3D = game.get_node_or_null("Track")
	var rp: Node = game.get("_race_position")
	if rp != null and track != null and rp.has_method("player_progress"):
		var prog: float = float(rp.call("player_progress"))
		var tlen: float = float(track.call("road_length"))
		_check(prog < tlen, "未压线时玩家进度 < 一圈（%.1f < %.1f）—— race_position 公式已联动"
			% [prog, tlen])
	# ⑤-D 首发压线只标记不完圈：保持 ④-B 按住的 W，轮询到首发压线后验证
	# 圈钟未被重置、laps_done 不计、HUD 本圈行离开占位（对 HEAD 必红：无此标志）。
	var hz := float(Engine.physics_ticks_per_second)
	var crossed := false
	for _i in range(int(hz * 8.0)):
		await process_frame
		if bool(car.get("start_line_crossed")):
			crossed = true
			break
	_check(crossed, "按住 W 后 8 秒内完成首发压线")
	if crossed:
		var t1: float = float(car.call("current_lap_time"))
		for _i in range(30):
			await process_frame
		var t2: float = float(car.call("current_lap_time"))
		_check(int(car.get("laps_done")) == 0, "首发压线不计圈（laps_done 仍为 0）")
		_check(t2 > t1 and (t2 - t1) < 1.0, "首发压线不重置圈钟（Δt=%.3fs）" % (t2 - t1))
		var hud: Node = game.get_node_or_null("HUD")
		if hud != null:
			var lap_text := String(hud.get_node("TimeLabel").text)
			_check(not lap_text.contains("--:--"), "HUD 本圈行已离开占位（%s）" % lap_text)

```

### A-5 `godot-racer/tests/race_position_test.gd`（+约 14 行）

**Hunk A-5.1** —— PlayerStub 加字段。位置：L16-21。

```gdscript
 class PlayerStub extends VehicleBody3D:
 	var laps_done := 0
 	var lap_running := false
+	var start_line_crossed := false
 
 	func current_lap_time() -> float:
 		return 1.0 if lap_running else 0.0
```

**Hunk A-5.2** —— 模拟首发压线的桩改新口径。位置：L82。

```gdscript
-	p2.lap_running = true
+	p2.start_line_crossed = true
```
> 断言集一条不减（`:79-103` 四条边界断言原样）：新旧公式在此桩下取值相同。

**Hunk A-5.3** —— 新增「圈钟在跑但未压线」断言（**对 HEAD 必红**）。插入位置：L103（跨圈回绕断言）之后、L104（`live.free()`）之前。

```gdscript
	# 新增（D1，对 HEAD 必红）：圈钟在跑但尚未压线 → 进度恰为弧长、不含 +1 圈。
	# 旧公式用 current_lap_time()>0 推断压线：setup 瞬间即算成 crossings=1 → 1500，翻红。
	var p3 := PlayerStub.new()
	var a3 := AiStub.new()
	root.add_child(p3)
	root.add_child(a3)
	p3.lap_running = true
	p3.start_line_crossed = false
	p3.position.x = 500.0
	var live2: Node = script.new()
	live2.call("setup", p3, track, [a3])
	var prog3: float = float(live2.call("player_progress"))
	_check(is_equal_approx(prog3, 500.0),
		"圈钟在跑未压线：进度=弧长 500（got %.1f）—— 进度公式只认压线标志" % prog3)
	live2.free()
	p3.free()
	a3.free()
```

---

## 2. 提交 B：删「起步」行（2 个文件）

### B-1 `godot-racer/scripts/hud.gd`（−45 行；491 → ~446）

```gdscript
# B-1.1 删 L59-62（变量与注释块）
-## 「起步」段：GO → 第一次压线的耗时（R15 与 R6 两个计时口径之差）。
-## 0 表示还没取到（本圈尚未第一次走动），显示占位。取值见 _process。
-var _launch_split := 0.0
-var _launch_label: Label = null

# B-1.2 删 L99（_ready() 内调用）
-	_build_launch_label()

# B-1.3 删 L235-261（_build_launch_label() 函数整体，含文件头注释）
#   （从 `## 建「起步」标签。位置：…` 到函数结尾 `	add_child(_launch_label)` 整段删除）

# B-1.4 删 L347-353（_process 取值块）
-		# 「起步」段：GO → 第一次压线 = 总时间 − 本圈（第一圈进行中恒成立，
-		# 两个计时都量到"现在"；取一次后冻结，口径见 _build_launch_label）。
-		if _launch_label != null and _launch_split <= 0.0:
-			var lap_now := float(car.call("current_lap_time"))
-			if lap_now > 0.0:
-				_launch_split = maxf(GameState.race_total_time() - lap_now, 0.0)
-				_launch_label.text = "起步   %s" % _fmt(_launch_split)
```
> 总时间行（`:220-232`）与圈速行不动；`_fmt()` 不动（finish_menu.gd 同口径，双向钉住）。

### B-2 `godot-racer/scripts/chase_camera.gd`（±2 行，仅注释）

```gdscript
 # L212-214
 	# ⚠ 2026-10-19：214 会压住 HUD 的「圈 1/2」（204~238）和名次行 —— HUD 左列
-	#   后来加长了（圈 204 / 名次 246 / AI 完赛 280 / 总时间 318 / 起步 358，各到 +34），
-	#   提示挪到整列最底下（398），1.8 秒后自动隐藏，不占常驻空间。
+	#   后来加长了（圈 204 / 名次 246 / AI 完赛 280 / 总时间 318~352）；
+	#   「起步」行同日移除（D1：圈速亦从「出发！」起算，总时间 ≡ 各圈之和）。
+	#   提示挪到整列最底下（398），1.8 秒后自动隐藏，不占常驻空间。
```
> 提示条位置 398 不动（不叠字，最小改动）。

---

## 3. 提交 C：起点龙门架（1 个新模块 + 1 个手写 .uid + main.gd 3 处）

### C-1 新文件 `godot-racer/scripts/start_gantry.gd`（全文，~140 行）

```gdscript
extends Node3D
## 起点龙门架（2026-10-19 用户反馈；D3 拍板：跨线而立、立柱带碰撞、撞上不穿模）。
##
## 资源：res://models/environment/desert_ruin_gate.glb（安装指南登记：216 三角形、
## 包围盒 4.80×4.44×1.36 m，Y-up 米制、底部约 y=0）。GLB **纯网格无碰撞体** ——
## 碰撞由本模块自建：每根立柱一个 BoxShape3D（StaticBody3D，场地层 1，车 mask=3
## 都会撞），盒体与视觉立柱同址同厚。为什么必须同厚：视觉比碰撞大会「车头陷进
## 网格才被盒体挡住」（视觉穿模），碰撞比视觉大会「离网格还有距离就被空气挡住」。
##
## 几何保证（正常驾驶不可能碰到）：X 缩放公式令**立柱内侧面 = 路面边缘 + 0.20m**：
##     s = (road_w + 2c) / (S_m − 2·t_m)
##     S_m=4.80（模型跨径）  t_m=实测立柱厚度  c=0.20（净距）
## 推导：模型腿内侧面在 ±(S_m/2 − t_m)，缩放 s 后要等于 road_w/2 + c。
## 横梁在高处（模型高 4.44m，车含翻车 <3m 碰不到），不建碰撞。
##
## 仓库约定：无 class_name（消费方 preload）/ setup() 注入 track / 不 get_node /
## 模块内 await = 0 / 任一步拿不到数据 → push_warning 后静默跳过（不炸验收）。
## 小地图不画：网格放第 18 渲染层（小地图相机只画第 17 层，minimap.gd）。

const GATE_SCENE := "res://models/environment/desert_ruin_gate.glb"
const GATE_SPAN_X := 4.80           # 模型包围盒 X（米）= 原始跨径（安装指南登记值）
const GATE_POST_T_FALLBACK := 0.50  # 立柱厚度兜底值（米）：实测失败时用，日志会声明
const GATE_CLEARANCE_M := 0.20      # 立柱内侧面距路面边缘净距（米）
const GATE_COLLIDE_H := 3.60        # 立柱碰撞盒高（米）：覆盖立柱、不含横梁
const GATE_COLLIDE_D := 1.20        # 立柱碰撞盒纵深（米）
const GATE_GROUND_LAYER := 1        # 场地层：玩家/AI 车 mask=3（地面+车辆）都会撞上
const GATE_RENDER_LAYER := 1 << 17  # 第 18 层：小地图相机（第 17 层）不绘制

var _track: Node3D = null


## 一次性注入赛道（main 在 _after_world_ready 调用）。本模块不反向认识场景树。
func setup(track: Node3D) -> void:
	_track = track


func _ready() -> void:
	_build()


func _build() -> void:
	if _track == null:
		push_warning("[龙门架] 未注入 Track，跳过（不影响验收）")
		return
	var lc: Variant = _track.get("start_line_center")
	var lf: Variant = _track.get("start_line_forward")
	var rw: Variant = _track.get("road_width")
	if not (lc is Vector3) or not (lf is Vector3) or not (rw is float):
		push_warning("[龙门架] Track 缺 start_line_center/forward 或 road_width，跳过")
		return
	var packed: PackedScene = load(GATE_SCENE)
	if packed == null:
		push_warning("[龙门架] 无法加载 %s，跳过" % GATE_SCENE)
		return
	var gate: Node3D = packed.instantiate()
	# ① 实测立柱厚度 t_m（局部 AABB 中心 |x| 超过跨径 35% 的网格的最大 X 尺寸）
	var t_m := _measure_post_thickness(gate)
	# ② 解算 X 缩放：令立柱内侧面 = 路宽/2 + CLEARANCE（推导见文件头）
	var road_w := float(rw)
	var s := (road_w + 2.0 * GATE_CLEARANCE_M) / maxf(0.5, GATE_SPAN_X - 2.0 * t_m)
	var t_v := t_m * s                                       # 视觉立柱厚 = 碰撞盒厚
	var post_x := (GATE_SPAN_X * 0.5 - t_m * 0.5) * s        # 立柱中心横向坐标
	# ③ 摆放：骑在起跑线上（跨线而立），基座贴路面（start_line_center 含高度剖面）
	var fwd := (lf as Vector3)
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var lift: Variant = _track.get("road_lift")
	var lift_y := float(lift) if (lift is float) else 0.0
	gate.name = "StartGantry"
	gate.transform = Transform3D(Basis(side * s, Vector3.UP, fwd),
		(lc as Vector3) + Vector3.UP * lift_y)
	for m in gate.find_children("*", "MeshInstance3D", true, false):
		m.layers = GATE_RENDER_LAYER
	add_child(gate)
	# ④ 碰撞：每根立柱一个静态盒，与视觉同址同厚（D3 硬性要求：不穿模）
	for sign in [1.0, -1.0]:
		var body := StaticBody3D.new()
		body.name = "StartGantryPost%s" % ("R" if sign > 0.0 else "L")
		body.collision_layer = GATE_GROUND_LAYER
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(t_v, GATE_COLLIDE_H, GATE_COLLIDE_D)
		shape.shape = box
		body.add_child(shape)
		add_child(body)
		body.position = side * (sign * post_x) + Vector3.UP * (GATE_COLLIDE_H * 0.5)
	print("[龙门架] 已就位：路宽 %.1f → 跨径 %.2f（缩放 ×%.2f，立柱厚 %.2f%s），立柱内侧面离路面 %.2fm，带碰撞（场地层 %d）"
		% [road_w, GATE_SPAN_X * s, s, t_v,
			"（兜底值）" if t_m == GATE_POST_T_FALLBACK else "",
			GATE_CLEARANCE_M, GATE_GROUND_LAYER])


## 实测立柱厚度：取局部 AABB 中心 |x| 超过跨径 35% 的网格的最大 X 尺寸。
## 单网格模型（立柱与横梁一体）或嵌套变换测不到 → 返回 0，由调用方走兜底值。
func _measure_post_thickness(gate: Node3D) -> float:
	var best := 0.0
	for m in gate.find_children("*", "MeshInstance3D", true, false):
		var aabb: AABB = m.transform * m.get_aabb()
		if absf(aabb.get_center().x) > GATE_SPAN_X * 0.35 and aabb.size.x > best:
			best = aabb.size.x
	if best <= 0.05:
		print("[龙门架] 立柱厚度实测失败（单网格模型？）→ 用兜底值 %.2fm，请以截图核对"
			% GATE_POST_T_FALLBACK)
		return GATE_POST_T_FALLBACK
	return best
```

### C-2 新文件 `godot-racer/scripts/start_gantry.gd.uid`（手写，headless 不生成 .uid）

```
uid://startgantry01
```
> 照 `start_countdown.gd.uid`（`uid://startcountd01`）先例；13 位、与现存 uid 不碰撞（实施时 `grep` 一遍确认）。

### C-3 `godot-racer/scenes/main.gd` —— 文件头声明。位置：L59（`var _countdown: CanvasLayer = null`）之后。

```gdscript
 ## 倒计时 UI 实例（互动路径才有；自动化路径为 null）
 var _countdown: CanvasLayer = null
 
+## 起点龙门架模块（2026-10-19 用户反馈 D3）：desert_ruin_gate.glb 跨线而立、
+## 立柱带碰撞（场地层）。互动与自动化路径都挂（纯场景装饰 + 静态碰撞，无行为读取方）。
+## 同样 preload 而不是 class_name，原因同 EnvironmentFX。
+const StartGantry := preload("res://scripts/start_gantry.gd")
+var _start_gantry := StartGantry.new()
```

### C-4 `godot-racer/scenes/main.gd` —— 挂载。位置：L322（`spawn_opponents(...)` 行）之后、L323（`if _parse_check_args():`）之前。

```gdscript
		_opponent_spawner.spawn_opponents(GameState.current_level(), track, want_opponents)
+	# 起点龙门架（2026-10-19 D3）：赛道就绪后即可摆放（start_line_* / road_width 已落定）。
+	# 挂在 _parse_check_args() 的 return **之前** → 自动化路径也有龙门架（--shot 截图可验）。
+	_start_gantry.setup(track)
+	add_child(_start_gantry)
	if _parse_check_args():
```

---

## 4. 提交 D：文档同步（4 处，文本闸门误伤规避）

| 文件 | 改动 | 规避要点 |
|---|---|---|
| `plan/racing-system-design-20261018.md` | 加 v1.2 修订记录；R6 改「圈速亦从『出发！』起算（首圈含起跑段）」；R15 删「与 R6 有意分离」改「同原点」；AC-05 同步 | plan/ 不在闸门扫描范围，可写实数 |
| `README.md:25` | 「AI 在玩家起步后才出发」→「3 秒倒计时结束后同时出发」（既存漂移顺手修） | 不新写「全部 N 项」 |
| `godot-racer/docs/portfolio-design.md:11`（两个口径刻意分开→统一原点）+ `:26`（4 km/h 旧规则→同步发车） | 同上 | 同左；反引号路径只写真实存在的 |
| `godot-racer/docs/testing.md` | 新增本轮小节（先红后绿证据 + commit 绑定，AGENTS §15 模板）；校正 `:143` aistart 旧规则表述 | 同左 |

---

## 5. 提交顺序、回退点与验证锚点

| 步 | 提交 | 内容 | 必跑验证（全绿才能进下一步） |
|---|---|---|---|
| 1 | 先红（不提交） | 只改 A-4/A-5 测试 | `countdown_scene_test` 新断言红、旧断言绿；`race_position_test` 新断言红、旧 4 条绿 → 归档 `godot-logs/round4-*-red.log` |
| 2 | **A** | A-1+A-2+A-3+A-4+A-5（原子） | 两个测试转绿；`race_position_scene_test`/`finish_results_test`/`release_flow_scene_test` 复跑绿；`lint-gdscript.ps1` + `parse-check.ps1` |
| 3 | **B** | B-1+B-2 | `finish_results_test`（总时间行）+ tests/ 全部门复跑；lint+parse |
| 4 | **C** | C-1~C-4 | parse-check（新模块可编译）；`--check=minimap`（龙门架不进小地图）；截图三张（L1 宽路 / L5 窄路 / L4 穿门） |
| 5 | **D** | 文档 4 处 | `check-docs.ps1` + `check-readme.ps1` 全绿 |
| 6 | 冻结带（D2） | calibrate → freeze → aidiag 复验 3~4 次 | `tape-preflight.ps1` 退出码 0；`--check=aidiag` 10 断言 0 失败、measurement_status=COMPLETE；**阈值一个不改** |
| 7 | 套件 | `run-all-checks.ps1 -Quick`（15）→ 全量 20 项（60 FPS） | 20/20、RUNALL_EXIT=0；`--check=aistart -Level 3` 单独留证 |
| 8 | AC-13 降级（D4） | lap×1 + opponents L4×1 + L5×1（60/120 各一次关键项，或先 60 FPS 三项） | 判据与 60 FPS 完全相同；完整 18 次挂发布前 |
| 9 | lap 双稳态 | A/B 前「同代码两跑」定模式 | 模式不变（自动化路径逐字节不变的预期）；若变先查环境 |
| 10 | 试玩确认 | 用户实机：L5 倒计时 → GO → 本圈/总时间同时起走、无起步行、AI 并排、龙门架跨线 | 截屏留证后才可称「试玩缺陷已修复」 |

**回退点**：每提交独立可回退；A 必须原子（vehicle 与 race_position 拆开必红 `race_position_scene_test.gd:63`——故意为之，证明联动必要）。

---

## 6. 龙门架观感核对清单（C 提交的截图项，D3 衍生）

1. 门骑在起跑线上、与 1.6m 白线重合；
2. 立柱内侧面离路面 ≥0.2m（日志打印值核对），正常驾驶线路不碰；
3. 基座贴路面不悬空（L4/L5 高程关卡重点看）；
4. L1（宽 14m）立柱外侧面会越过护栏线 ~0.9m——**已知偏差，用户确认可接受**；不可接受再议（唯一旋钮是模型腿厚，属资产改动）；
5. 穿门不撞（`-Frames 400` 穿门截图）；
6. 小地图上看不到龙门架。
