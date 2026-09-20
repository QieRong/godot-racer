extends RefCounted
## 竞速线：坡度 / 弯道半径 / 物理限速 / 刹车距离 —— **三处共用同一份**的纯函数模块
##
## 为什么必须抽出来（这是本项目吃过最大的一次亏）：
##   限速要被**三处**用到 —— AI 对手（`ai_opponent.gd`）、验收自动驾驶
##   （`main.gd` 的 `--check=lap` / `--check=elevation`）、以及验收打印。
##   教训是"游玩与验收走了两条不同代码路径 → 验收报 ✔ 而游戏是错的"。
##   所以这三个数字只允许有**一份**实现，谁也不许在旁边再写一遍。
##
## 纯静态函数、不依赖场景与 autoload，所以 AI 与验收用的是同一份逻辑。
## 配套断言在 `main.gd` 的「布局验收 ④ 限速 / 刹车距离用例组」（6 条，见 --check=layout）。
##
## 单位约定（**混用单位是这类物理公式最经典的错源，所以写死在这里**）：
##   · `arc` / `probe` / `ds` / `radius`  米
##   · `a_lat` / `a_brake`                 m/s²（横向可用加速度 / 刹车减速度）
##   · 速度入参 `v_kmh` / `v_target_kmh`  km/h
##   · 返回的 `*_kmh`                      km/h

## 速度换算：1 m/s = 3.6 km/h。GDScript 的 static 不能引用同脚本的 const（GDScript 限制），
## 所以写成 `const` 但在静态函数里用字面量是行不通的 —— 这里统一用下面的私有常量。
const MPS_TO_KMH := 3.6

## 默认安全系数：物理极限**不允许**当目标速度使用。
##
## 为什么是 0.85：`sqrt(a_lat·R)` 是"刚好不滑出去"的理论临界值，实际还要吃
## 转向输入的阶跃、路面起伏、以及 AI 转向的滞后。留 15% 余量后实测才压得住弯心。
## ⚠ 这个值与 §4.4b 的表格是**同一个数**，改它就会改表里所有限速。
const DEFAULT_SAFETY := 0.85

## 车辆/AI 的基准横向可用加速度（m/s²），与 `vehicle.gd` / `ai_opponent.gd` 的
## `max_lateral_accel` 默认值一致。真实值必须按关卡抓地力缩放后再传进来：
##     a_lat = GRIP_BASE × LevelConfig.friction_multiplier
## （L5 雪地 0.5 → 8.0；L4 沙地 0.85 → 13.6；L3 雨夜 0.7 → 11.2）
## 这里只作参考基准，本模块**不**去猜关卡数据（硬编码关卡参数是明令禁止的）。
const GRIP_BASE := 16.0

## 弯道半径/限速前瞻的**最小可信**采样步长（米）。太小会让有限差分吃到数值噪声。
const MIN_DS := 1.0

## 弯度判定的**最小可信线段长**（米）。低于它的线段视为"方向还没成立"，**不参与**夹角。
##
## ⚠ 这道守卫的来历（2026-09 任务 15，有 `--check=aidiag` 实测数据）：
##   原来的守卫是 0.5m，而 AI 恰好一直跑在自己的车道点上，于是"车位置 → 第一个车道点"
##   这段向量只有 **0.5~0.6m**，却要和 12m 的线段求夹角 —— 实测得到 **101.5°~121.1°**
##   （同一段直线，逐次采样读数还能漂 20°：这就是纯数值噪声，不是几何）。
##   更糟的是它被当成"最严格的一档"，策略限速被 `clampf` 压到 0.30 下限 = **43.2 km/h**，
##   而同一时刻的真实折角只有 3.4~4.8°、物理上限 146~260 km/h。
##   所以本任务（②接物理上限）**必须先修这里**，否则 min(43.2, 146) 永远等于 43.2，
##   物理上限在 L1 上根本没有发言机会。
const MIN_BEND_SEG := 3.0


## 弯度（**度**）：点列里相邻两段的夹角，取**最大**的一个。
##
## 「相邻两段行进方向的夹角」才是转弯的物理含义 —— 一段长 d 米的弦，折角 θ 对应半径 R=d/θ。
## 之所以收"点列"而不是收"车位置 + 前方点"：车位置与第一个车道点几乎重合（AI 就跑在车道点上），
## 拿它当参考向量会得到一个**退化向量**（0.5~0.6m），与 12m 的线段求夹角毫无意义。
## 点列的第一个点本身就是"车所在弧长处的车道点"，所以语义等价、又不会退化。
##
## `min_seg` **必须**与生产侧同一个值（`MIN_BEND_SEG`）：0.5m 对 12m 求夹角在数值上不成立。
## 任一相邻段长 ≤ `min_seg` → 这一对**整对跳过**（返回 0 度的贡献），
## 而不是"用另一段的长度放行" —— 守卫要挡的就是这种"一段长一段退化"的组合。
##
## 返回：所有相邻段都不可信（点数 < 3 或全被守卫挡掉）→ **0.0**（读作"这里没量到弯"）。
## 这是刻意的兜底：返回大角度会让 AI 无理由地刹到下限（正是本任务要修的 bug 的病征）。
##
## ⚠ 纯函数，不依赖 track / 场景，所以 `--check=layout` 能用**构造的点列**直接钉住守卫。
static func bend_angle_deg(points: Array, min_seg := MIN_BEND_SEG) -> float:
	if points.size() < 3:
		return 0.0
	var worst := 0.0
	for i in range(1, points.size() - 1):
		var a: Vector3 = points[i] - points[i - 1]
		var b: Vector3 = points[i + 1] - points[i]
		# 只量水平面上的转弯：赛道有起伏时 y 分量会把折角夸大
		# （与 `corner_radius_at` 同一口径，两处必须一致）。
		a.y = 0.0
		b.y = 0.0
		# 守卫：**两段都要够长**，任一段退化就整对跳过（见 MIN_BEND_SEG 的实测数据）
		if a.length() <= min_seg or b.length() <= min_seg:
			continue
		var ang := rad_to_deg(absf(a.normalized().angle_to(b.normalized())))
		if ang > worst:
			worst = ang
	return worst


## 前进 probe 米的高度差 → 坡度（正 = 上坡）。
##
## 语义：`grade = (y(arc+probe) − y(arc)) / probe`，与 §4.4a 的 8 m 前视一致。
## 采样用 `centerline_point()`（它自带弧长环绕），所以跨起点/终点不会断裂。
##   track：`track_generator.gd` 生成的赛道节点（需要 `centerline_point(d) -> Vector3`）
## 返回 0.0 的情形：赛道还没生成、probe 非正 —— 调"没有坡"是安全的兜底
## （比返回 NaN 好：NaN 会顺着乘法污染整条限速链，而且不报错）。
static func slope_at(track: Object, arc: float, probe := 8.0) -> float:
	if track == null or probe <= 0.0:
		return 0.0
	var p0: Vector3 = track.call("centerline_point", arc)
	var p1: Vector3 = track.call("centerline_point", arc + probe)
	return (p1.y - p0.y) / probe


## 弧长 arc 处的**弯道半径**（米），由"走 ds 米航向转了多少"反推：R = ds / Δθ。
##
## 为什么用折角反推而不是解析曲率：赛道是"直线 + 圆弧"拼出来的样条，
## 我们手上只有采样点；从两点朝向差反推半径与车辆实际感受一致
## （车跑过 ds 米，车头转了 Δθ，等效半径就是 ds/Δθ）。
##   ds 取 12 m 的来历：与 §4.4b 的弯道采样量级一致，且远大于 2 m 站距，
##   不会被控制点附近的局部折角带偏。
## 返回：直道（Δθ≈0）→ `INF`；赛道未生成或 ds 非法 → 0.0（0 会让 `speed_limit_kmh`
## 算出 0 km/h，是**故意**的失败可见化，不要改成 INF）。
static func corner_radius_at(track: Object, arc: float, ds := 12.0) -> float:
	if track == null or ds <= 0.0:
		return 0.0
	var a: Vector3 = track.call("centerline_forward", arc)
	var b: Vector3 = track.call("centerline_forward", arc + ds)
	a.y = 0.0
	b.y = 0.0
	if a.length_squared() <= 1e-12 or b.length_squared() <= 1e-12:
		return 0.0
	var theta := absf(a.normalized().signed_angle_to(b.normalized(), Vector3.UP))
	if theta <= 1e-6:
		return INF
	return ds / theta


## 半径 radius、横向可用加速度 a_lat 下的**物理限速**（km/h）。
##
##     v_max = sqrt(a_lat · R) × safety × 3.6
##
## 物理依据：圆周运动的向心加速度 a = v²/R，车能提供的横向加速度上限是 a_lat，
## 所以 v ≤ sqrt(a_lat·R)。**这是"对地面的上限"，不是"对极速的下限"** ——
## 两者取小时物理极限不允许被百分比下限抬回去（§4.4b 的核心结论）：
## L5 冰面发夹 sqrt(8.0×18)=43.2 km/h，而 AI 原来的百分比下限只肯降到 65 km/h，
## 65 > 43.2 → 必然推头出界。这就是本函数存在的理由。
##
## 边界处理：R 为 INF（直道）→ 返回 `INF`（"此处不限制"）；
## R 或 a_lat 非正 → 返回 0.0（不可通行，宁可停住也不要冲出去）。
static func speed_limit_kmh(radius: float, a_lat: float, safety := DEFAULT_SAFETY) -> float:
	if is_inf(radius):
		return INF
	if radius <= 0.0 or a_lat <= 0.0:
		return 0.0
	return sqrt(a_lat * radius) * clampf(safety, 0.0, 1.0) * MPS_TO_KMH


## 前瞻限速：在 arc 之后 distances 里的每个距离处取弯道限速，返回**最小值**（km/h）。
##
##   前瞻距离 = arc + distances[i]，不是绝对弧长 —— 这样调用方（AI / 验收自动驾驶）
##   直接用"前方 N 米"的语义，不需要自己算环绕。
##
## `distances` 里的每个值都会被当**正的前瞻距离**用，负数或 0：忽略。
##
## ⚠ 本函数**不做刹车距离判定**，也不做坡度修正，只回答"前方最近的最紧弯允许多快"：
##   · 刹车距离 → `brake_distance()`，由调用方拿它与"到限速点的距离"比较后决定刹车
##     （§4.4b2：靠刹车距离和前瞻距离两个独立量取小，不在这里混算）
##   · 坡度修正 → §4.4a 的下坡延长前瞻，由调用方乘在 distances 上
##     （坡是车辆姿态的事，不是弯道几何的事，混进来会让本函数没法单测）
## `cap_kmh` 是**上限兜底**（例如直道上没有任何弯时，返回极速而不是 INF）；
## 传 INF（默认）表示不额外封顶。返回可能是 INF，调用方若需要有限值请自备 cap。
static func lookahead_limit_kmh(track: Object, arc: float, distances: Array,
		a_lat: float, cap_kmh: float = INF) -> float:
	if track == null:
		return clampf(cap_kmh, 0.0, INF)
	var worst := cap_kmh
	for d in distances:
		var ahead := float(d)
		if ahead <= 0.0:
			continue
		var r := corner_radius_at(track, arc + ahead, MIN_DS * 12.0)
		var lim := speed_limit_kmh(r, a_lat)
		if lim < worst:
			worst = lim
	return worst


## 从 v_kmh 刹到 v_target_kmh 需要多少米（匀减速）：`d = (v² − v_t²) / (2·a_brake)`。
##
## 这是 §4.4b2 的 `d_need`：若"到下一个需要限速的点"的距离 < d_need → 无条件刹车
## （不看超速死区）。只限速不够 —— 还得**提前**减到那个速度。
##
## 为什么必须有这条：L5 从 65 → 37 km/h、实测 a_brake≈6 m/s² 时 d_need≈18 m，
## 而原来的预判只有 10 m 量级 → 等到弯前再刹已经晚了（这也是"只把限速调低仍然出界"的原因）。
##
## 退化情形**必须返回 0**：`v ≤ v_target`（已经在限速以下 / 正在加速）→ 不该刹。
##   若这里返回正数，AI 会在加速段也无缘无故点刹 —— 现象隐蔽、极难查
##   （所以 `--check=layout` 的第 ⑥ 条用例专门钉住它）。
## `a_brake` 非正 → 返回 0（没有刹车能力时，"需要多少米"没有意义，由兜底逻辑处理）。
static func brake_distance(v_kmh: float, v_target_kmh: float, a_brake: float) -> float:
	if a_brake <= 0.0:
		return 0.0
	var v := v_kmh / MPS_TO_KMH
	var vt := v_target_kmh / MPS_TO_KMH
	var d := (v * v - vt * vt) / (2.0 * a_brake)
	return d if d > 0.0 else 0.0


## AI 的**最终目标速度** = min(策略限速, 物理上限)。本任务（15）的接线点，语义写死在这里。
##
##     v_target = min(策略限速, speed_limit_kmh(maxf(radius, min_radius), a_lat, safety))
##
## 为什么必须是这个方向（2026-09 项目所有者拍板：「物理极限是地面的天花板，
## 策略下限是 AI 愿意降到多慢的地板。地板不允许高于天花板。」）：
##   · `percent_kmh` 是"按弯度折算的百分比限速"，它**含** `min_speed_frac` 那道下限。
##     实测算过两头的错：L5 近似直道 R=6499m 只肯跑 64.8（**慢到物理上限的 9%**），
##     而 L5 冰面 R=34m 竟给 64.8（**比物理上限 51 快 27%，必然推头**）。
##   · 物理上限必须**不受**百分比下限约束 —— 修 `min()` 把下限抬回去，正是本任务立项的原因。
##
## ⚠ 两处 `maxf` 不是防御性编程，各自对应一个已实测的死法：
##   · `maxf(radius, min_radius)`：`corner_radius_at()` 在赛道未生成/参数非法时**故意**返回 0.0
##     （让失败可见化）。若原样传给 `speed_limit_kmh`，它按契约返回 0 km/h → **AI 直接停住**，
##     表现为"AI 不动"，最难查的一类症状。用本关 `min_corner_radius` 兜底是保守侧。
##   · `maxf(percent_kmh, 0.0)`：NaN 会顺着 `min` 传播且不报错，先夹成非法值里**最慢**的那个。
##
## 传 `a_lat` 时必须已经是**缩放后**的值：`GRIP_BASE × LevelConfig.friction_multiplier`
## （L5 冰面 8.0 / L4 沙地 13.6 / L3 雨夜 11.2）。用干燥路的 16.0 会在冰面上把上限
## 算成 96 而不是 51 —— 现象是"AI 在冰面依然推头"，极易被误判成"物理极限这条路走不通"。
static func ai_target_speed_kmh(percent_kmh: float, radius: float, a_lat: float,
		min_radius := 0.0, safety := DEFAULT_SAFETY) -> float:
	var phys := speed_limit_kmh(maxf(radius, min_radius), a_lat, safety)
	return minf(maxf(percent_kmh, 0.0), phys)
