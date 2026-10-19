extends RefCounted
## [DEBUG-L4] 变道走廊 / 卡死时间线诊断（开发期，只读）。
##
## 2026-10-12 SPLIT-L4DIAG-001：从 scenes/main.gd 整块拆出，**纯迁移、行为零变化** ——
## 常量数值、状态语义、print 文案全部原样搬入，没有第二份实现。
## 结构变化仅三类：
##   ① 原先直接读 Main 场景成员（_car / _obstacle_field / _check）的地方，改为
##      **setup() 注入 + check_name 公开变量**；本模块不反向持有场景；
##   ② 原先引用自动驾驶侧常量（DRIVE_BODY_HALF / DRIVE_AVOID_HORIZON）与函数
##      （_drive_decision_horizon()）的地方，改为 **参数传入**（body_half / horizon），
##      不在本模块复制第二份常量或公式（单一来源，AGENTS.md §5.3）；
##   ③ 原先散在 Main 上的诊断状态（_tl / _f / _sw_* / _corr_* / _rate_hist …）
##      收为本模块的实例状态 —— main.gd 每场景持一个实例。
##
## ⚠ 为什么没有 class_name（与 racing_line.gd / environment.gd / engine_audio.gd
##   同一约定）：本项目的验收闸门（parse-check / run-check / run-all-checks）在
##   **无编辑器**环境里跑 Godot，而 class_name 的全局注册表
##   （.godot/global_script_class_cache.cfg）**只有编辑器会重建**。2026-10-12
##   实测：新增 class_name 后 --check-only 与游戏运行双双报
##   `Identifier "X" not declared in the current scope`。因此消费方一律用
##   `const X := preload("res://scripts/l4_debug_diag.gd")` 引用本模块，
##   不依赖全局类缓存（详见 environment.gd 文件头）。
##
## 整块只在 `--check=lap` 里跑，**不参与任何判定**；查完 grep '[DEBUG-L4]' 一整块删掉。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car）。由 setup() 注入。
var _car: VehicleBody3D = null
## 障碍场（main.gd 的 _obstacle_field）。由 setup() 注入；无障碍关卡时为 null。
var _field: Node3D = null
## 当前验收模式（main.gd 的 _check）。只有 lap 时诊断才输出。
##
## 为什么必须是运行时可改的公开变量而不是 setup 参数：`_check` 在
## `_parse_check_args()` 里才被解析出来，比障碍物建好还晚；且 `--shot-drive=1`
## 也调用 _drive_track，而那里 push() 永远不被调用（_l4_f 恒 0）——
## 没有这道门限速条件会恒真、每帧刷屏（实测抓图模式日志几秒涨到几十万行）。
var check_name := ""
## 车体半宽（米）——main.gd 自动驾驶侧常量 DRIVE_BODY_HALF，注入而非复制。
var _body_half := 0.0
## 避障视距（米）——main.gd 自动驾驶侧常量 DRIVE_AVOID_HORIZON，注入而非复制
## （本模块只在一处打印标签里用到它）。
var _avoid_horizon := 0.0


## 注入外部引用与车身常量（main.gd 在 _after_world_ready 里、障碍物建好后调用一次）。
func setup(car: VehicleBody3D, field: Node3D, body_half: float, avoid_horizon: float) -> void:
	_car = car
	_field = field
	_body_half = body_half
	_avoid_horizon = avoid_horizon


## ==================== 变道走廊诊断（[DEBUG-L4] TRANSITION，开发期只读）====================
#
# 这一组常量**只服务诊断**，不参与任何判定、不改 lane / steering / speed。
# 要回答的问题（本轮任务）：
#   「目标车道最终安全」是否掩盖了「车从当前横向位置移动到目标车道的**过程**会穿过障碍」。
# 为什么不能只看目标车道：pick_clear_lane() 只回答「如果车已经在这条道上，它通不通」
#   （lane_blocked 在**同一个 arc** 上比横向差），它没有回答「从 A 挪到 B 的路上会不会
#   压到第三块障碍」。L4 实测里 cur_lat=+1.10 / target=-2.34 / 石头横向≈+0.08 正是
#   这种形态：终点在石头占用带之外、起点在带内，中间必然穿带。
#
# ⚠ 网格是**保守离散**，不是连续轨迹预测：横向取 5 档内插（含起终点与 25/50/75%），
#   纵向取决策前瞻内 n 档等距弧长（弧长不足时按 L4_CORR_MIN_SEG 减少条数）。
#   它只会**高估**被挡住（采样点之间可能漏，采样点本身不会误报），所以只用于取证。
const L4_CORR_ARCS := 6
## 走廊纵向采样的最小相邻间距（米）：弧长太短时减少采样条数，避免采样点挤在一处
const L4_CORR_MIN_SEG := 3.0
## 直接打印「过渡走廊受阻」两行日志的最小间隔（物理帧）：防日志爆炸
const L4_CORR_PRINT_EVERY := 12
## 目标车道变化判定阈值（米，计划 §11）：> 该值才算一次「目标跳变」
const L4_SWITCH_EPS := 0.05
## 「大跨度跳变」的诊断阈值（米，**不是验收阈值**）
const L4_SWITCH_BIG := 2.0
## 「两次目标切换间隔过短」的诊断阈值（秒，**不是验收阈值**）
const L4_SWITCH_FAST_SEC := 0.5
## 横向速率采样的最小纵向间隔（米）与最小横向位移（米）：滤掉静止噪声
const L4_RATE_MIN_DARC := 0.30
const L4_RATE_MIN_DLAT := 0.002

# ==================== [DEBUG-L4] 卡死时间线取证（开发期，只读）====================
# 为什么要有这一整块：定位"骑石头"发生在 reset **之前**还是**之后**，单帧快照答不出来
# —— 必须把 T±30 帧的车态与最近障碍放进同一条时间线。
# 全部只在 `--check=lap` 里跑，**不参与任何判定**；查完 grep '[DEBUG-L4]' 一整块删掉。
const L4_TL_CAP := 400
## 卡住事件要回看的帧偏移（相对卡住帧）
const L4_DUMP_OFFSETS := [-30, -15, -5, -1, 0, 1, 5, 15, 30]
## 每帧一条的环形缓冲
var _tl: Array = []
var _f := 0
## 等 T+30 帧到齐再落盘的卡住事件
var _pending: Array = []
## 动态障碍 ETA 日志的节流
var _eta_f := -999
## 换道诊断：观测到的横向速率样本（m 横向 / m 纵向，只在换道进行中采样）
var _lat_rate: Array = []
## 横向速率样本（m 横向 / m 纵向）—— 由 rate_sampler() 每帧按速度段采样
var _prev_lat := 0.0
var _prev_lane := 0.0
var _last_target := 0.0
var _lane_f := -999
## 目标车道翻转统计（计划 §10/§11）：每次 target_lane 真正变化都记一笔
var _sw_delta: Array = []
var _sw_gap: Array = []
var _sw_t: Array = []
var _sw_rev := 0
var _sw_big := 0
var _sw_fast := 0
var _sw_blocked := 0
var _target_prev := 0.0
var _target_has := false
## 横向速率分速度段的样本（计划 §18）：每项 {rate, kmh, arc}
var _rate_hist: Array = []
## 撞车（首次真实碰撞）取证（计划 §8）：靠一帧内速度崩掉识别，**不参与判定**
var _prev_spd := 0.0
var _impact_n := 0
## 上一帧的走廊/车道读数，供碰撞那一刻对齐（由 transition_report 每帧写入）
var _cur_trans := false
var _cur_lat := 0.0
var _cur_tgt := 0.0
var _cur_arc := 0.0
## 过渡走廊诊断（计划 §4~§8）的状态
var _prev_arc_lat := -1.0
var _corr_f := -999
var _corr_prev := false
var _corr_prev_tgt := 0.0
var _corr_has := false
var _corr_grid: Array = []


## 每物理帧采一条（车态 + 最近两个障碍）。只在 _check_lap 的循环里调用。
func push(track: Node, head_deg: float) -> void:
	# ⚠ 用**物理帧号**当唯一时钟：vehicle.gd / main.gd 两套恢复的打点也用同一个，
	#   这样 `[DEBUG-L4] REC f=…` 与时间线的 `f=…` 可以直接按 f 排序对齐（实验 4）。
	_f = Engine.get_physics_frames()
	var near: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
	var f := Vector3(near.get("forward", Vector3.FORWARD))
	f.y = 0.0
	var lat := 0.0
	if f.length() > 0.001:
		f = f.normalized()
		lat = (_car.global_position - Vector3(near.get("pos", _car.global_position))).dot(
			Vector3(f.z, 0.0, -f.x))
	var obs: Array = []
	if _field != null and _field.has_method("debug_obstacles_near"):
		obs = _field.call("debug_obstacles_near", _car.global_position, 2)
	_tl.append({
		"f": _f, "pos": _car.global_position, "arc": float(near.get("arc", -1.0)),
		"lat": lat, "spd": _car.linear_velocity.length() * 3.6, "head": head_deg,
		"g": int(_car.call("grounded_wheel_count")), "obs": obs,
	})
	if _tl.size() > L4_TL_CAP:
		_tl = _tl.slice(_tl.size() - L4_TL_CAP)
	# 到点的卡住事件落盘
	for i in range(_pending.size() - 1, -1, -1):
		var p: Dictionary = _pending[i]
		if _f - int(p["f0"]) >= 30:
			_dump_window(p)
			_pending.remove_at(i)


## [DEBUG-L4] 撞车识别（计划 §8）：**只读**。一帧内速度崩掉 >25 km/h（或 >40 → <12）就是硬撞。
## 为什么用速度而不是碰撞回调：本项目已知 Area3D / 接触信号不可靠，而「速度一帧崩掉」
## 是物理事实（既有实测减速度 180~200 m/s²，轮胎在任何摩擦系数下都给不出）。
## 由 _check_lap 每物理帧调用一次（紧接 push() 之后，口径与迁移前逐行一致）。
func note_speed(track: Node, spd_kmh: float, emit_legacy := true) -> void:
	if (_prev_spd > 30.0 and spd_kmh < _prev_spd - 25.0) \
			or (_prev_spd > 40.0 and spd_kmh < 12.0):
		_impact_n += 1
		# 独立证据观察器只消费既有代理计数，不打印其未初始化的车道辅助字段。
		if emit_legacy:
			var inear: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
			print("[DEBUG-L4] IMPACT n=%d f=%d arc=%.1f lat=%+.2f v_before=%.1f v_after=%.1f "
				% [_impact_n, _f, float(inear.get("arc", -1.0)), _cur_lat,
				   _prev_spd, spd_kmh]
				+ "target_lane=%+.2f transition_blocked=%s"
				% [_cur_tgt, str(_cur_trans)])
	_prev_spd = spd_kmh


func _at(f: int) -> Dictionary:
	for e in _tl:
		if int(e["f"]) == f:
			return e
	return {}


## 卡住事件的结构化记录（实验 1）+ T±30 帧时间线（实验 2）。
func stuck_record(track: Node, near: Dictionary, head_deg: float, head_idx: int) -> void:
	var pos: Vector3 = _car.global_position
	var f := Vector3(near.get("forward", Vector3.FORWARD))
	f.y = 0.0
	var lat := 0.0
	if f.length() > 0.001:
		f = f.normalized()
		lat = (pos - Vector3(near.get("pos", pos))).dot(Vector3(f.z, 0.0, -f.x))
	var obs: Array = []
	if _field != null and _field.has_method("debug_obstacles_near"):
		obs = _field.call("debug_obstacles_near", pos, 3)
	print("[DEBUG-L4] STUCK#%d f=%d t=%.1fs pos=(%.2f,%.2f,%.2f) arc=%.1f lat=%+.2f speed=%.2f "
		% [head_idx, _f, float(_f) / float(Engine.physics_ticks_per_second),
		   pos.x, pos.y, pos.z, float(near.get("arc", -1.0)), lat,
		   _car.linear_velocity.length() * 3.6]
		+ "heading_error=%.1f grounded=%d/4 belly_time=%.2f stuck_time=%.2f reason=speed+displacement_probe"
		% [head_deg, int(_car.call("grounded_wheel_count")),
		   float(_car.get("_belly_time")), float(_car.get("_stuck_time"))])
	for k in range(obs.size()):
		var o: Dictionary = obs[k]
		print("[DEBUG-L4] STUCK#%d OBST%d id=%d kind=%s arc=%.1f lateral=%+.2f hw=%.2f dyn=%s world=(%.2f,%.2f,%.2f) dist=%.2f"
			% [head_idx, k, int(o["id"]), String(o["kind"]), float(o["arc"]), float(o["lateral"]),
			   float(o["half_width"]), str(o["dynamic"]),
			   (o["world"] as Vector3).x, (o["world"] as Vector3).y, (o["world"] as Vector3).z,
			   float(o["dist"])])
	_pending.append({"idx": head_idx, "f0": _f, "arc": float(near.get("arc", -1.0)), "lat": lat})


func _dump_window(p: Dictionary) -> void:
	print("[DEBUG-L4] STUCK#%d WINDOW arc=%.1f lat=%+.2f" % [int(p["idx"]), float(p["arc"]), float(p["lat"])])
	for off in L4_DUMP_OFFSETS:
		var e: Dictionary = _at(int(p["f0"]) + int(off))
		if e.is_empty():
			print("[DEBUG-L4]   T%+d <无采样>" % int(off))
			continue
		var ob: Dictionary = {}
		if not (e["obs"] as Array).is_empty():
			ob = (e["obs"] as Array)[0]
		var ps: Vector3 = e["pos"]
		print("[DEBUG-L4]   T%+d f=%d pos=(%.2f,%.2f,%.2f) arc=%.1f lat=%+.2f spd=%.1f g=%d/4 head=%.0f "
			% [int(off), int(e["f"]), ps.x, ps.y, ps.z, float(e["arc"]), float(e["lat"]),
			   float(e["spd"]), int(e["g"]), float(e["head"])]
			+ ("| obst=—（%.0fm 内无）" % _avoid_horizon if ob.is_empty()
			   else "| obst=%s id=%d arc=%.1f lat=%+.2f hw=%.2f dyn=%s dist=%.2f"
				% [String(ob["kind"]), int(ob["id"]), float(ob["arc"]), float(ob["lateral"]),
				   float(ob["half_width"]), str(ob["dynamic"]), float(ob["dist"])]))


## 实验 5：规划车道时，把"规划时"与"预计到达时"的动态障碍横向位置一起打出来。
## 只做取证，**不实现任何预测修正**。节流：车道变化时或每 30 帧一次。
func eta_report(track: Node, plan_arc: float, plan_lane: float) -> void:
	# ⚠ 第一版只覆盖**动态**障碍，结果石头那两个卡死点（arc 1288.8）在规划侧是盲区。
	#   现在改成：只要**前方 60m 内有任何障碍**（静态或动态）就记一行，
	#   并把规划器的"车道占用"视角（debug_ahead）一起打出来。
	if _field == null or not _field.has_method("debug_dynamic_state"):
		return
	if _f - _eta_f < 30:
		return
	var rows: Array = []
	if _field.has_method("debug_ahead"):
		rows = _field.call("debug_ahead", plan_arc, 60.0, plan_lane, _body_half)
	var dyn: Array = _field.call("debug_dynamic_state")
	if rows.is_empty() and dyn.is_empty():
		return
	# 规划道 vs 车的**实际**横向：这一栏是"命令了但没跟到位"的直接证据
	var near_now: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
	var f_now := Vector3(near_now.get("forward", Vector3.FORWARD))
	f_now.y = 0.0
	var act_lat := 0.0
	if f_now.length() > 0.001:
		f_now = f_now.normalized()
		act_lat = (_car.global_position - Vector3(near_now.get("pos", _car.global_position))).dot(
			Vector3(f_now.z, 0.0, -f_now.x))
	if not rows.is_empty():
		_eta_f = _f
		print("[DEBUG-L4] PLAN f=%d plan_arc=%.1f plan_lane=%+.2f actual_lat=%+.2f spd=%.1f 前方60m有障碍："
			% [_f, plan_arc, plan_lane, act_lat, _car.linear_velocity.length() * 3.6])
		for r in rows:
			print("[DEBUG-L4]   PLANROW %s" % r)
	var total := maxf(1.0, float(track.call("road_length")))
	var spd := maxf(0.1, _car.linear_velocity.length())
	var any := false
	var line := ""
	for d in dyn:
		var it: Dictionary = d
		var dist := fposmod(float(it["arc"]) - plan_arc, total)
		if dist > 120.0:
			continue
		var eta := dist / spd
		# ⚠ 相位由 _process 的**渲染帧** delta 推进（见 obstacle_field._process），
		#   而 eta 是物理秒 —— 两者只有在渲染≈物理帧率时才可比。这里把两个口径都留下。
		var half_travel := float(it["travel"]) * 0.5
		var cur_lat := float(it["center"]) + sin(float(it["phase"])) * half_travel
		var pred := float(it["center"]) + sin(float(it["phase"]) + float(it["speed"]) * eta) * half_travel
		line += " [dyn arc=%.1f dist=%.1f cur_lat=%+.2f phase=%.2f pred_lat=%+.2f gate=%s]" % [
			float(it["arc"]), dist, cur_lat, float(it["phase"]), pred,
			("占用规划道" if absf(pred - plan_lane) < float(it["half_width"]) + _body_half + 0.35 else "可通行")]
		any = true
	if any:
		_eta_f = _f
		print("[DEBUG-L4] ETA f=%d plan_arc=%.1f plan_lane=%+.2f spd=%.1f%s"
			% [_f, plan_arc, plan_lane, spd, line])


## 本帧的**决策前瞻**（米）。默认 DRIVE_DECISION_HORIZON；开发期 A/B 用环境变量覆盖。
## [DEBUG-L4] 变道走廊判定（**纯只读**，计划 §4~§7）。
##
## 采样「车从 cur_lat 挪到 target_lat 的路上真正会经过的 (弧长, 横向)」网格，每一格都问
## **已有的唯一真相源** obstacle_field.lane_blocked() —— 本文件不复制 _occupies() 的公式
## （AGENTS.md §5.3）。「是谁挡的」用同样只读的 blockers_for()，不另造一套占用判定。
##
## 返回：
##   corridor_blocked —— 网格里有没有任何一格被障碍占用
##   transition_blocked —— **目标车道本身安全**、但网格里有格子被占（= 计划要找的形态）
##   cur_blocked / target_blocked —— 起点与终点各自的占用情况（用于排除「起点本来就在石头里」）
##   band —— 占用带宽度 `car_half + OBSTACLE_MARGIN`（米）
##   clearance —— 网格各格到最近障碍**横向边**的余量最小值（米，负 = 采样点落在足迹内）
##   who / at_lane / at_dist —— 最近的**被占格**：障碍种类、采样横向、纵向采样距离（米）
func _transition_corridor(track: Node, arc: float, cur_lat: float, target_lat: float,
		horizon: float, car_half: float) -> Dictionary:
	var out := {
		"corridor_blocked": false, "transition_blocked": false,
		"cur_blocked": false, "target_blocked": false,
		"band": car_half + 0.35, "clearance": 999.0,
		"who": "—", "at_lane": 0.0, "at_dist": -1.0,
	}
	if _field == null or not _field.has_method("lane_blocked"):
		return out
	var n := L4_CORR_ARCS
	var seg := horizon / float(n)
	if seg < L4_CORR_MIN_SEG:
		n = maxi(2, int(horizon / L4_CORR_MIN_SEG))
		seg = horizon / float(n)
	# 网格：内插横向 × 等距弧长。起终点两档单独问，不放进网格（避免重复计数）。
	var grid: Array = []
	for li in range(5):
		var lane_i := lerpf(cur_lat, target_lat, float(li) / 4.0)
		for di in range(n):
			grid.append(Vector2(lane_i, (float(di) + 0.5) * seg))
	_corr_grid = grid
	out["cur_blocked"] = bool(_field.call("lane_blocked", cur_lat, arc, 0.1, car_half))
	out["target_blocked"] = bool(_field.call("lane_blocked", target_lat, arc, horizon,
		car_half))
	var best_d := 1.0e9
	var who := "—"
	var at_lane := 0.0
	var at_dist := -1.0
	# ⚠ 只有**被占**的采样点才去算「离障碍边还有多远」（`_corridor_edge` 要问世界坐标，
	#   比 `lane_blocked` 贵一个量级）。走廊通畅时这一栏没有信息量，省下的时间留给物理帧。
	var low := 999.0
	for gi in range(grid.size()):
		var p: Vector2 = grid[gi]
		var blk := bool(_field.call("lane_blocked", p.x, arc + p.y, 0.1, car_half))
		if not blk:
			continue
		out["corridor_blocked"] = true
		if p.y < best_d:
			best_d = p.y
			at_lane = p.x
			at_dist = p.y
			who = _corridor_who(p.x, arc + p.y, car_half)
		var edge := _corridor_edge(track, p.x, arc + p.y, car_half)
		if edge < low:
			low = edge
	out["clearance"] = low
	out["who"] = who
	out["at_lane"] = at_lane
	out["at_dist"] = at_dist
	out["transition_blocked"] = bool(out["corridor_blocked"]) and not bool(out["target_blocked"])
	return out


## [DEBUG-L4] 某个采样点上是**哪一类**障碍挡住了（只读）：用已有的 blockers_for() 取最近一条。
## 取不到时返回「—」——不猜。
func _corridor_who(lane: float, at_arc: float, car_half: float) -> String:
	if _field == null or not _field.has_method("blockers_for"):
		return "—"
	var bl: Array = _field.call("blockers_for", lane, at_arc, 0.1, car_half)
	if bl.is_empty():
		return "—"
	var b: Dictionary = bl[0]
	var tag := String(b["kind"])
	if bool(b["dynamic"]):
		tag += "(dyn)"
	return tag


## [DEBUG-L4] 某个采样点到最近障碍**横向边**的余量（米，只读）。
##
## 为什么单独写：clearance 要回答「还差多少才碰到」，而这必须与占用判定用同一批障碍、
## 同一个半宽口径。返回 999 表示该采样点附近暂时没有障碍。
func _corridor_edge(track: Node, lane: float, at_arc: float, car_half: float) -> float:
	if _field == null or not _field.has_method("debug_obstacles_near"):
		return 999.0
	var c: Vector3 = track.call("centerline_point", at_arc)
	var f: Vector3 = track.call("centerline_forward", at_arc)
	f.y = 0.0
	var wp := c
	if f.length() > 0.001:
		f = f.normalized()
		wp = c + Vector3(f.z, 0.0, -f.x) * lane
	var near: Array = _field.call("debug_obstacles_near", wp, 1)
	if near.is_empty():
		return 999.0
	var o: Dictionary = near[0]
	return absf(lane - float(o["lateral"])) - float(o["half_width"]) - car_half - 0.35


## [DEBUG-L4] 走廊受阻时输出的采样梯度：每一纵列（弧长）上哪些横向采样点被占。
##
## 为什么要打这一行：只报 blocked=true 无法回答「是石头压在走廊中间，还是走廊整段被堵死」。
func _corridor_ladder(arc: float) -> String:
	if _corr_grid.is_empty():
		return "—"
	var cols: Array = []
	for p in _corr_grid:
		var pt: Vector2 = p
		var seen := false
		for c in cols:
			if absf(float(c) - pt.y) < 0.01:
				seen = true
				break
		if not seen:
			cols.append(pt.y)
	cols.sort()
	var line := ""
	for c in cols:
		var xs: Array = []
		for p in _corr_grid:
			var pt: Vector2 = p
			if absf(pt.y - float(c)) < 0.01:
				var hit := bool(_field.call("lane_blocked", pt.x, arc + pt.y, 0.1,
					_body_half))
				if hit:
					xs.append("%.2f" % pt.x)
		line += " [%+.1fm: %s]" % [float(c), ("无" if xs.is_empty() else ",".join(xs))]
	return line


## [DEBUG-L4] 过渡走廊报告（计划 §6）：目标变化 / 走廊状态翻转时打，其余按节流打。
## **纯只读**：本函数不写任何输入，也不参与选道。
func transition_report(track: Node, arc: float, cur_lat: float, target_lane: float,
		horizon: float) -> void:
	# ⚠ 只在 --check=lap 里跑（与整块 [DEBUG-L4] 的既有约定一致）：
	#   `--shot-drive=1` 也调用 _drive_track，而那里 `_f` 永远不被推进（push() 只在
	#   _check_lap 的循环里跑）→ 节流条件 `_f - _corr_f >= N` 恒为真 → **每帧刷屏**。
	#   实测：抓图模式下逐帧输出，日志几秒内涨到几十万行。
	if check_name != "lap":
		return
	if _field == null or not _field.has_method("lane_blocked"):
		return
	var c: Dictionary = _transition_corridor(track, arc, cur_lat, target_lane, horizon,
		_body_half)
	var cblk := bool(c["transition_blocked"])
	var tgt_blk := bool(c["target_blocked"])
	var tgt_jump := _corr_has and absf(target_lane - _corr_prev_tgt) > 0.50
	var state_flip := not _corr_has or cblk != _corr_prev
	var in_transit := absf(target_lane - cur_lat) > 0.50
	if in_transit or state_flip or tgt_jump:
		if state_flip or tgt_jump or not cblk or _f - _corr_f >= L4_CORR_PRINT_EVERY:
			_corr_f = _f
			_corr_prev = cblk
			_corr_prev_tgt = target_lane
			_corr_has = true
			print("[DEBUG-L4] TRANSITION f=%d arc=%.1f current=%+.2f target=%+.2f delta=%+.2f "
				% [_f, arc, cur_lat, target_lane, target_lane - cur_lat]
				+ "blocked=%s transition_blocked=%s cur_occ=%s tgt_occ=%s blocker=%s sample_lane=%+.2f "
				% [str(bool(c["corridor_blocked"])), str(cblk), str(bool(c["cur_blocked"])),
				   str(tgt_blk), String(c["who"]), float(c["at_lane"])]
				+ "sample_arc_dist=%.1f clearance=%+.2f band=%.2f"
				% [float(c["at_dist"]), float(c["clearance"]), float(c["band"])])
			if cblk:
				print("[DEBUG-L4]   CORRIDOR%s" % _corridor_ladder(arc))
				# 计划 §6 要求的固定字段行：撞车那一刻要能直接与这些字段对齐。
				print("[DEBUG-L4] TRANSITION_FULL f=%d arc=%.1f current=%+.2f target=%+.2f delta=%+.2f "
					% [_f, arc, cur_lat, target_lane, target_lane - cur_lat]
					+ "blocked=%s transition_blocked=%s blocker=%s sample_lane=%+.2f sample_arc_dist=%.1f"
					% [str(bool(c["corridor_blocked"])), str(cblk), String(c["who"]),
					   float(c["at_lane"]), float(c["at_dist"])])
	_corr_has = true
	_corr_prev_tgt = target_lane
	# 供撞车记录对齐用：本帧的走廊 / 车道读数（只读快照，不影响任何控制量）。
	_cur_trans = cblk
	_cur_lat = cur_lat
	_cur_tgt = target_lane
	_cur_arc = arc


## [DEBUG-L4] 横向执行速率分**速度段**采样（计划 §18）。
##
## 为什么按速度分段：横向能力随速度、转向权限、车身姿态变化，混在一起的中位数会掩盖
## 「高速段根本挪不动」这种形态。速率为 m 横向 / m 纵向。**纯只读**：只记录。
func rate_sampler(arc: float, cur_lat: float, target_lane: float) -> void:
	# ⚠ 只在 --check=lap 里跑（与整块 [DEBUG-L4] 的既有约定一致）：
	#   `--shot-drive=1` 也调用 _drive_track，而那里 `_f` 永远不被推进（push() 只在
	#   _check_lap 的循环里跑）→ 节流条件 `_f - _corr_f >= N` 恒为真 → **每帧刷屏**。
	#   实测：抓图模式下逐帧输出，日志几秒内涨到几十万行。
	if check_name != "lap":
		return
	if _prev_arc_lat >= 0.0:
		# 复位 / 瞬移会让 d_arc 变成巨大的负数 —— 那不是「横向执行速率」，直接丢弃该样本。
		var d_arc := arc - _prev_arc_lat
		if d_arc < -10.0:
			d_arc = 0.0
		var d_lat := absf(cur_lat - _prev_lat)
		var in_transit := absf(target_lane - cur_lat) > 0.10 or absf(target_lane - _prev_lane) > 0.10
		if in_transit and d_arc > L4_RATE_MIN_DARC and d_lat > L4_RATE_MIN_DLAT:
			var r := d_lat / d_arc
			_rate_hist.append({
				"rate": r,
				"kmh": _car.linear_velocity.length() * 3.6,
				"arc": arc,
			})
			# 同一份样本喂给「来不来得及」用的滚动窗口（口径必须一致，不能两套速率）。
			_lat_rate.append(r)
			if _lat_rate.size() > 300:
				_lat_rate = _lat_rate.slice(_lat_rate.size() - 300)
			if _rate_hist.size() > 4000:
				_rate_hist = _rate_hist.slice(_rate_hist.size() - 4000)
	_prev_arc_lat = arc


## 分位数（p 为 0~1）。样本为空时返回 0。
func _quantile(vals: Array, p: float) -> float:
	if vals.is_empty():
		return 0.0
	var s: Array = vals.duplicate()
	s.sort()
	var i := int(round(p * float(s.size() - 1)))
	return float(s[clampi(i, 0, s.size() - 1)])


## [DEBUG-L4] 收尾汇总（计划 §11 / §18）：目标车道翻转 + 横向速率分布。
## 打印在「卡住事件」那一节旁边，**只报数，不参与判定**。
func summary_report() -> void:
	var nsw := _sw_delta.size()
	var mx := 0.0
	for d in _sw_delta:
		mx = maxf(mx, absf(float(d)))
	var med := _quantile(_sw_delta, 0.5)
	var gmed := _quantile(_sw_gap, 0.5)
	var gmin := _quantile(_sw_gap, 0.0)
	print("[DEBUG-L4] SUMMARY L4TSWITCH count=%d max_lane_delta=%.2f median_lane_delta=%.2f "
		% [nsw, mx, med]
		+ "big_gt_%.1fm=%d fast_lt_%.1fs=%d direction_reversal=%d corridor_blocked_at_switch=%d "
		% [L4_SWITCH_BIG, _sw_big, L4_SWITCH_FAST_SEC, _sw_fast, _sw_rev, _sw_blocked]
		+ "gap_min=%.2fs gap_median=%.2fs" % [gmin, gmed])
	var r_all: Array = []
	var b0: Array = []
	var b1: Array = []
	var b2: Array = []
	var b3: Array = []
	for s in _rate_hist:
		var it: Dictionary = s
		var rate := float(it["rate"])
		var kmh := float(it["kmh"])
		r_all.append(rate)
		if kmh < 40.0:
			b0.append(rate)
		elif kmh < 80.0:
			b1.append(rate)
		elif kmh < 120.0:
			b2.append(rate)
		else:
			b3.append(rate)
	print("[DEBUG-L4] SUMMARY L4RATE n=%d p25=%.4f median=%.4f p75=%.4f max=%.4f"
		% [r_all.size(), _quantile(r_all, 0.25), _quantile(r_all, 0.5),
		   _quantile(r_all, 0.75), _quantile(r_all, 1.0)])
	print("[DEBUG-L4] SUMMARY L4RATE_BUCKET 0-40kmh n=%d med=%.4f | 40-80 n=%d med=%.4f | "
		% [b0.size(), _quantile(b0, 0.5), b1.size(), _quantile(b1, 0.5)]
		+ "80-120 n=%d med=%.4f | 120+ n=%d med=%.4f"
		% [b2.size(), _quantile(b2, 0.5), b3.size(), _quantile(b3, 0.5)])


## [DEBUG-L4] 计划第四步：换道目标是否瞬时跳变 + "来不来得及"的定量判断。
##
## 两个量：
##   lane_delta = 目标车道 − 本车**实际**横向（不是上次的命令值）
##   required   = lane_delta ÷ 观测到的横向速率（m 横向 / m 纵向），
##                速率只在本车**正在换道**的帧上采样，避免把静止噪声当速率。
## 判据：required > 到最近障碍的纵向距离 → **已经来不及**。
## 纯只读，不参与任何判定。
func lane_change_report(track: Node, arc: float, cur_lat: float,
		target_lane: float, clear: bool, horizon: float) -> void:
	var total := maxf(1.0, float(track.call("road_length")))
	# ---- 速率采样已移到 rate_sampler()（按速度分段，计划 §18）----
	# 这里只取中位数用于「来不来得及」一行；采样本身仍然只读。
	var rate := _median_rate()
	_prev_lat = cur_lat
	_prev_lane = target_lane
	# ---- 是否要打：目标变化就打；否则每 10 帧在有横向差时打 ----
	var jumped := absf(target_lane - _last_target) > 0.50
	var busy := absf(target_lane - cur_lat) > 0.05
	if not jumped and not busy:
		_last_target = target_lane
		return
	if not jumped and _f - _lane_f < 10:
		return
	_lane_f = _f
	# ---- 到最近障碍的纵向距离（沿赛道）----
	var blk := -1.0
	var blk_kind := "—"
	if _field != null and _field.has_method("debug_obstacles_near"):
		var obs: Array = _field.call("debug_obstacles_near", _car.global_position, 4)
		for o in obs:
			var d := fposmod(float(o["arc"]) - arc, total)
			if d <= 0.0 or d > 150.0:
				continue
			if blk < 0.0 or d < blk:
				blk = d
				blk_kind = String(o["kind"])
	var delta := target_lane - cur_lat
	var required := -1.0
	if rate > 0.000001:
		required = absf(delta) / rate
	var verdict := "—"
	if required > 0.0 and blk > 0.0:
		verdict = "来不及" if required > blk else "来得及"
	# ⚠ decision= 必须打出来：A/B 全靠环境变量覆盖，没有这一栏就无法证明
	#   "这一组真的用了 90/120"，也就无法证明对照有效。
	print("[DEBUG-L4] LANE f=%d arc=%.1f decision=%.0f cur_lat=%+.2f target=%+.2f delta=%+.2f blocker=%.1f(%s) "
		% [_f, arc, horizon, cur_lat, target_lane, delta, blk, blk_kind]
		+ "rate=%.4f required=%.1fm jump=%s clear=%s verdict=%s"
		% [rate, required, str(jumped), str(clear), verdict])
	# ---- 目标车道翻转记账（计划 §10/§11）----
	# 判据用「与上一次**记录到**的目标相差 > L4_SWITCH_EPS」，而不是「本帧与上帧不同」：
	# 后者会把浮点抖动数成几十次切换。这些只是诊断阈值，**不是验收阈值**。
	if not _target_has:
		_target_has = true
		_target_prev = target_lane
	elif absf(target_lane - _target_prev) > L4_SWITCH_EPS:
		var d_sw := target_lane - _target_prev
		_sw_delta.append(d_sw)
		_sw_t.append(float(_f) / float(Engine.physics_ticks_per_second))
		if _sw_t.size() >= 2:
			_sw_gap.append(float(_sw_t[_sw_t.size() - 1]) - float(_sw_t[_sw_t.size() - 2]))
		if absf(d_sw) > L4_SWITCH_BIG:
			_sw_big += 1
		if _sw_gap.size() > 0 and float(_sw_gap[_sw_gap.size() - 1]) < L4_SWITCH_FAST_SEC:
			_sw_fast += 1
		# 方向反转：这一次的位移方向与上一次相反（右→左 / 左→右）
		if _sw_delta.size() >= 2:
			var prev_d := float(_sw_delta[_sw_delta.size() - 2])
			if prev_d * d_sw < 0.0:
				_sw_rev += 1
		# 这次切换发生时，过渡走廊是否被占（= 换过去的目标本身就不安全）
		if _corr_prev:
			_sw_blocked += 1
		_target_prev = target_lane
	_last_target = target_lane


## 观测到的横向速率中位数（m 横向 / m 纵向）。样本不足时返回 0（表示"还不知道"）。
func _median_rate() -> float:
	if _lat_rate.size() < 20:
		return 0.0
	var s: Array = _lat_rate.duplicate()
	s.sort()
	return float(s[s.size() / 2])


## 主侧恢复打点（实验 4）：与 vehicle.gd 的 _debug_rec() 用同一个前缀与 f= 口径，
## 这样"同一次事故里两套恢复谁在哪一帧动手"可以直接按 f 排序拼出来。
func note_rec(action: String) -> void:
	print("[DEBUG-L4] REC f=%d owner=main action=%s pos=%s v=%.2f"
		% [Engine.get_physics_frames(), action, str(_car.global_position),
		   _car.linear_velocity.length()])
