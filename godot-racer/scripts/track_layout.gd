extends RefCounted
class_name TrackLayout
## 赛道布局（路段 DSL）：解析 → 骨架 → 闭环 → 曲率体检
##
## 为什么要有这个模块：
##   赛道形状原来是"椭圆公式换参数"，所以 5 个关卡本质是同一条赛道。
##   改成"路段拼装"之后形状可以逐关设计，但代价是**文本解析没有编译期检查**。
##   本模块的设计原则就是把这个代价补回来：**任何不合法的输入都必须报错，绝不静默修正**。
##   配套的 `--check=layout` 会把这里每条规则都断言一遍。
##
## 纯静态函数、不依赖场景，所以 track_generator.gd（生成赛道）与 main.gd（验收）
## 用的是**同一份**逻辑 —— 避免"验收一套、生成另一套"这种本项目最惨的坑。
##
## DSL 文法（详见 docs/plans/tracks-and-elevation.md §3.1）：
##   straight:L              直道，L>0 米
##   arc:R:A                 定半径弯；A 有符号角度，正=左转、负=右转，|A|≤270
##   sweeper:R:A             同 arc（语义上表示高速弯，仅用于分档统计）
##   hairpin:R               发夹弯，等价 arc:R:180（左转）
##   chicane:R:OFF           S 弯：两段 ±a 等半径弧，a=acos(1-OFF/(2R))，需 0<OFF<4R
##   ellipse:RX:RZ[:W:AMP]   椭圆（仅阶段 1 做"与旧实现逐点对照"用，阶段 3 必须删除）

## 单个弯的最大角度（超过就不是弯而是掉头了）
const MAX_ANGLE := 270.0
## 闭环残差上限（米）
const CLOSURE_TOL := 0.1
## 每 2m 允许的最大航向变化（度）。
## 8° 的来历：最紧的弯（R=18m）在 2m 站距下是 6.4°，留 25% 余量。
## 当年"直线+圆角矩形"就是因为接点曲率突变把车弹飞（y 从 -0.06 跳到 +0.79），
## 所以这条体检是硬门槛，不是"好看不好看"。
const MAX_HEADING_STEP_DEG := 8.0
## 每 2m 允许的最大曲率跳变（1/m）。
##
## 为什么是 0.07 而不是更小：**直道↔圆弧的接点本来就有 Δκ = 1/R 的跳变**，
## 这是"直线+圆弧"这种拼装的固有属性（椭圆没有，因为它的曲率处处连续）。
## 0.07 对应最小半径约 14.3m —— 刚好容纳"L5 发夹 ≥15m"这条拍板要求。
## 真正会把车弹飞的是**航向不连续（硬折角 = 曲率无穷大）**，那由
## MAX_HEADING_STEP_DEG 拦住；曲率跳变这条只是防止"半径小到不合常理"。
const MAX_DKAPPA := 0.07
## 两条"可调直道"的最小夹角：小于它就无法用解算闭环（行列式接近 0）
const MIN_HINGE_ANGLE_DEG := 11.0
## 解算后直道的最短长度（米）
const MIN_STRAIGHT_AFTER_SOLVE := 5.0
## 解算器**只负责收拾最后几厘米**：残差超过这个值就说明布局长度根本没算过。
##
## 为什么必须有这条：实测 L2 的第一版手写设计残差 **340m**，解算器只能解出
## "-123m" 这种荒谬长度（然后被下限拦住，报的却是"直道太短"，完全误导）。
## 现在的报错直接指向真正的问题：请用 tools/layout_closure.py 把长度解出来再填。
const SOLVE_MAX_RESIDUAL := 5.0
## 内护栏自交保护：最小弯半径至少要比重心到护栏的距离大这么多
const MIN_RAIL_CLEARANCE := 2.0
## 椭圆段的控制点数：**必须与旧实现一致（64）**，否则阶段 1 的逐点对照没有意义
const ELLIPSE_SEGMENTS := 64

## 合法路段类型（报错信息里会列出来，也是"ellipse 真的删掉了"的证明点）
const KINDS := ["straight", "arc", "sweeper", "hairpin", "chicane", "ellipse"]


## 解析 DSL。返回：
##   成功 {ok=true, segments=[{kind,args,length,angle_deg}], length, net_turn_deg, has_ellipse}
##   失败 {ok=false, error="...", at=<第几段, 0 起>}
static func parse(text: String) -> Dictionary:
	var fail := {"ok": false, "error": "", "at": -1, "segments": [], "length": 0.0,
		"net_turn_deg": 0.0, "has_ellipse": false}
	if text == null or text.strip_edges().is_empty():
		var f0 := fail.duplicate()
		f0["error"] = "layout 是空串"
		return f0
	var chunks := text.split(",", true)
	var segments: Array = []
	var total := 0.0
	var net := 0.0
	var has_ellipse := false
	for i in range(chunks.size()):
		var chunk: String = chunks[i].strip_edges()
		if chunk.is_empty():
			return _fail(i, "第 %d 段是空的（多余或尾随的逗号）" % (i + 1))
		var parts := chunk.split(":", true)
		var kind: String = parts[0].strip_edges()
		if not KINDS.has(kind):
			return _fail(i, "第 %d 段「%s」不是合法路段类型（可用：%s）"
				% [i + 1, kind, ", ".join(PackedStringArray(KINDS))])
		var args: Array = []
		for j in range(1, parts.size()):
			var a: String = parts[j].strip_edges()
			if a.is_empty():
				return _fail(i, "第 %d 段「%s」有空的参数（多写了一个冒号？）" % [i + 1, kind])
			args.append(a)
		# ---- 参数个数 ----
		var need := -1
		match kind:
			"straight": need = 1
			"arc": need = 2
			"sweeper": need = 2
			"hairpin": need = 1
			"chicane": need = 2
			"ellipse": need = -2
		if need == -2:
			if args.size() != 2 and args.size() != 4:
				return _fail(i, "第 %d 段「%s」需要 2 或 4 个参数（RX:RZ[:波数:幅度]），实际给了 %d 个"
					% [i + 1, kind, args.size()])
		elif args.size() != need:
			return _fail(i, "第 %d 段「%s」需要 %d 个参数，实际给了 %d 个"
				% [i + 1, kind, need, args.size()])
		# ---- 数值合法性 ----
		var nums: Array = []
		for a in args:
			if not _is_number(str(a)):
				return _fail(i, "第 %d 段「%s」的参数「%s」不是有限数字" % [i + 1, kind, str(a)])
			nums.append(float(a))
		# ---- 逐类型规则 ----
		var seg := {"kind": kind, "args": nums, "length": 0.0, "angle_deg": 0.0}
		match kind:
			"straight":
				var l := float(nums[0])
				if l <= 0.0:
					return _fail(i, "第 %d 段 straight 的长度必须 > 0（给了 %.3f）" % [i + 1, l])
				seg["length"] = l
			"arc", "sweeper":
				var rr := float(nums[0])
				var aa := float(nums[1])
				if rr <= 0.0:
					return _fail(i, "第 %d 段 %s 的半径必须 > 0（给了 %.3f）" % [i + 1, kind, rr])
				if absf(aa) <= 0.0001:
					return _fail(i, "第 %d 段 %s 的角度不能为 0" % [i + 1, kind])
				if absf(aa) > MAX_ANGLE:
					return _fail(i, "第 %d 段 %s 的角度 %.1f° 超过上限 %.0f°"
						% [i + 1, kind, aa, MAX_ANGLE])
				seg["length"] = rr * absf(deg_to_rad(aa))
				seg["angle_deg"] = aa
			"hairpin":
				var hr := float(nums[0])
				if hr <= 0.0:
					return _fail(i, "第 %d 段 hairpin 的半径必须 > 0（给了 %.3f）" % [i + 1, hr])
				seg["length"] = hr * PI
				seg["angle_deg"] = 180.0
			"chicane":
				var cr := float(nums[0])
				var off := float(nums[1])
				if cr <= 0.0:
					return _fail(i, "第 %d 段 chicane 的半径必须 > 0（给了 %.3f）" % [i + 1, cr])
				if off <= 0.0:
					return _fail(i, "第 %d 段 chicane 的横向偏移必须 > 0（给了 %.3f）" % [i + 1, off])
				if off >= cr * 4.0:
					return _fail(i, "第 %d 段 chicane 的偏移 %.2f ≥ 4R=%.2f，无解（acos 参数越界）"
						% [i + 1, off, cr * 4.0])
				var ca := acos(clampf(1.0 - off / (2.0 * cr), -1.0, 1.0))
				seg["length"] = 2.0 * cr * ca
				seg["angle_deg"] = 0.0        # S 弯净转角为 0
				seg["chicane_angle_deg"] = rad_to_deg(ca)
			"ellipse":
				var rx := float(nums[0])
				var rz := float(nums[1])
				if rx <= 0.0 or rz <= 0.0:
					return _fail(i, "第 %d 段 ellipse 的长短半轴都必须 > 0（给了 %.1f × %.1f）"
						% [i + 1, rx, rz])
				if nums.size() == 4:
					var waves := float(nums[2])
					var amp := float(nums[3])
					if waves < 0.0 or amp < 0.0:
						return _fail(i, "第 %d 段 ellipse 的波数与幅度不能为负" % (i + 1))
					if amp > rz * 0.25:
						return _fail(i, "第 %d 段 ellipse 的 S 弯幅度 %.1f 超过短半轴的 25%%（%.1f）"
							% [i + 1, amp, rz * 0.25])
				has_ellipse = true
				seg["length"] = 0.0           # 由 build 阶段实际计算
				seg["angle_deg"] = 360.0
		total += float(seg["length"])
		net += float(seg["angle_deg"])
		segments.append(seg)
	return {"ok": true, "error": "", "at": -1, "segments": segments,
		"length": total, "net_turn_deg": net, "has_ellipse": has_ellipse}


static func _fail(at: int, msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "at": at, "segments": [], "length": 0.0,
		"net_turn_deg": 0.0, "has_ellipse": false}


## 严格的数字判断。
## ⚠ 必须显式排除 nan/inf：Godot 的 `is_valid_float()` 对 "nan"/"inf" 返回 **true**，
## 只靠它会把 NaN 放进几何计算，然后整条赛道变成一堆 NaN 顶点（而且不报错）。
static func _is_number(s: String) -> bool:
	if s.is_empty() or not s.is_valid_float():
		return false
	var low := s.to_lower()
	if low.contains("nan") or low.contains("inf"):
		return false
	return true


## 构建骨架并做全套体检。返回：
##   成功 {ok=true, points, length, closure_gap, min_radius, max_heading_step_deg,
##         max_dkappa, radius_histogram, net_turn_deg, mode_used, doubled}
##   失败 {ok=false, error}
## rail_half > 0 时额外校验"内护栏不自交"（最小弯半径要留出余量）。
static func build(text: String, closure_mode: String, step: float,
		rail_half: float = 0.0) -> Dictionary:
	var p := parse(text)
	if not bool(p["ok"]):
		return {"ok": false, "error": str(p["error"])}
	var segments: Array = p["segments"]
	var mode := closure_mode
	if bool(p["has_ellipse"]) and segments.size() == 1:
		mode = "exact"

	# ---------- 椭圆：自带闭环，控制点必须与旧实现逐点一致 ----------
	if mode == "exact":
		if segments.size() != 1 or str(segments[0]["kind"]) != "ellipse":
			return {"ok": false, "error": "exact 模式只用于单个 ellipse 段（阶段 1 的逐点对照）"}
		var pts := _ellipse_points(segments[0]["args"])
		return _finish(pts, mode, step, false, rail_half, float(p["net_turn_deg"]), true)

	# ---------- 路段拼装 ----------
	var walk := _walk(segments, [])
	var net := float(walk["net_turn_deg"])
	var doubled := false
	if mode == "mirror180":
		# 半条必须**恰好** 180°，否则倍加出来的整圈首尾航向差 180°（车到接缝会掉头）
		if absf(absf(net) - 180.0) > 0.5:
			return {"ok": false, "error": ("mirror180 模式下" + "半条布局的净转角必须恰好 180°，实测 %.1f°"
				+ "（点对称加倍靠这个前提才能精确闭环）") % net}
		walk = _walk(segments, [], true)
		doubled = true
		net = float(walk["net_turn_deg"])
	else:
		# 净转角必须 ≈ 360° 的整数倍
		var r := roundf(net / 360.0)
		if absf(net - r * 360.0) > 0.5 or absf(r) < 0.5:
			return {"ok": false, "error": "净转角 %.1f° 不是 360° 的整数倍，首尾航向对不上（差 %.1f°）"
				% [net, fposmod(360.0 - net, 360.0)]}

	var pts: PackedVector3Array = walk["points"]
	var end_p: Vector3 = walk["end"]
	if mode != "mirror180":
		# ---------- 闭环解算：把残差摊到两条**不平行**的可调直道上 ----------
		var gap_vec := -end_p
		if gap_vec.length() > CLOSURE_TOL:
			if gap_vec.length() > SOLVE_MAX_RESIDUAL:
				return {"ok": false, "error": ("闭环残差 %.1fm 远超解算可修正范围（%.1fm）："
					+ "说明这个布局的长度没真正算过。请用 tools/layout_closure.py 解出长度后重填"
					+ "（净转角对不代表位置对：Σ(位移) 也必须为 0）。")
					% [gap_vec.length(), SOLVE_MAX_RESIDUAL]}
			var solved := _solve_closure(segments, walk, gap_vec)
			if not bool(solved["ok"]):
				return {"ok": false, "error": str(solved["error"])}
			var lens: Array = solved["lengths"]
			walk = _walk(segments, lens)
			pts = walk["points"]
			end_p = walk["end"]
			if end_p.length() > CLOSURE_TOL:
				return {"ok": false, "error": "解算后仍有 %.3fm 残差（线性系统与实际几何不一致，请把 layout 发出来）"
					% end_p.length()}
	return _finish(pts, mode, step, doubled, rail_half, net)


## 把段落序列走成折线。
##   length_override：非空时按下标覆盖 straight 的长度（闭环解算用）
##   double_mirror：true 时返回"点对称加倍"后的**半条**（起点→半程终点），
##                  由调用方再拼出整圈。这里返回的是半条，方便复现推导。
static func _walk(segments: Array, length_override: Array, double_half: bool = false) -> Dictionary:
	var pos := Vector3.ZERO
	var heading := 0.0          # 弧度；0 = +X 方向。正 = 左转（绕 +Y 逆时针）
	# ⚠ 这里用**非 Packed 的 Array** 累积：GDScript 里 Array 明确是引用传递，
	# 而 Packed*Array 的传参语义容易踩坑（传给辅助函数后原地 append 不一定会写回）。
	# 最后再一次性转成 PackedVector3Array。
	var pts: Array = []
	pts.append(pos)
	var net := 0.0
	var straights: Array = []   # [{index, dir: Vector3, length: float}]
	for i in range(segments.size()):
		var seg: Dictionary = segments[i]
		var kind := str(seg["kind"])
		var args: Array = seg["args"]
		match kind:
			"straight":
				var l := float(args[0])
				if length_override.size() > i:
					l = float(length_override[i])
				var d := Vector3(cos(heading), 0.0, -sin(heading))
				straights.append({"index": i, "dir": d, "length": l})
				var walked := 0.0
				while walked < l - 0.001:
					var s := minf(2.0, l - walked)
					walked += s
					pos += d * s
					pts.append(pos)
				var back: Vector3 = pts[pts.size() - 1]
				pos = back
			"arc", "sweeper":
				var rr := float(args[0])
				var aa := deg_to_rad(float(args[1]))
				pos = _walk_arc(pts, pos, heading, rr, aa)
				heading += aa
				net += rad_to_deg(aa)
			"hairpin":
				var hr := float(args[0])
				pos = _walk_arc(pts, pos, heading, hr, PI)
				heading += PI
				net += 180.0
			"chicane":
				var cr := float(args[0])
				var off := float(args[1])
				var ca := acos(clampf(1.0 - off / (2.0 * cr), -1.0, 1.0))
				pos = _walk_arc(pts, pos, heading, cr, ca)
				heading += ca
				pos = _walk_arc(pts, pos, heading, cr, -ca)
				heading -= ca
				# 净转角 0
			"ellipse":
				return {"points": PackedVector3Array(pts), "end": pos, "heading": heading,
					"net_turn_deg": net, "straights": straights}
	if double_half:
		# 点对称加倍：P'(t) = E - P(t)。这样首尾精确重合，且接缝处航向连续
		# （推导：半条净转角 180°，加倍后末端航向 = -180+180 = 0，正好接上起点朝向）。
		var e: Vector3 = pts[pts.size() - 1]
		var full: Array = []
		for p in pts:
			full.append(p)
		for i in range(1, pts.size()):
			var q: Vector3 = pts[i]
			full.append(e - q)
		var packed := PackedVector3Array(full)
		return {"points": packed, "end": packed[packed.size() - 1], "heading": 0.0,
			"net_turn_deg": net * 2.0, "straights": straights}
	return {"points": PackedVector3Array(pts), "end": pos, "heading": heading,
		"net_turn_deg": net, "straights": straights}


## 沿一段圆弧走：pos 原位更新，点追加进 pts。返回新的 pos。
## 左转（angle>0）时圆心在左侧（left = UP × heading），绕圆心按 +angle 旋转。
static func _walk_arc(pts: Array, pos: Vector3, heading: float,
		radius: float, angle: float) -> Vector3:
	var dir := Vector3(cos(heading), 0.0, -sin(heading))
	var left := Vector3.UP.cross(dir).normalized()
	var sgn := 1.0 if angle >= 0.0 else -1.0
	var center := pos + left * (radius * sgn)
	var arc_len := radius * absf(angle)
	var steps := maxi(int(ceil(arc_len / 2.0)), 1)
	var per := angle / float(steps)
	var cur := pos
	for _i in range(steps):
		var v := cur - center
		v = v.rotated(Vector3.UP, per)
		cur = center + v
		pts.append(cur)
	return cur


## 解开环：解 2×2 线性系统，把残差摊到两条"可调直道"的长度上。
## 选哪两条：所有 straight 里夹角最大的那一对（夹角太小则无解，必须报错）。
static func _solve_closure(segments: Array, walk: Dictionary, gap_vec: Vector3) -> Dictionary:
	var straights: Array = walk["straights"]
	if straights.size() < 2:
		return {"ok": false, "error": "闭环残差 %.2fm，但本布局没有两条可调直道可用于收口"
			% gap_vec.length()}
	var best_a := -1
	var best_b := -1
	var best_dot := 2.0
	for i in range(straights.size()):
		for j in range(i + 1, straights.size()):
			var ua: Vector3 = straights[i]["dir"]
			var ub: Vector3 = straights[j]["dir"]
			var d := absf(ua.dot(ub))
			if d < best_dot:
				best_dot = d
				best_a = i
				best_b = j
	if best_a < 0:
		return {"ok": false, "error": "找不到两条可调直道"}
	var u1: Vector3 = straights[best_a]["dir"]
	var u2: Vector3 = straights[best_b]["dir"]
	var det := u1.x * u2.z - u1.z * u2.x
	var min_det := sin(deg_to_rad(MIN_HINGE_ANGLE_DEG))
	if absf(det) < min_det:
		return {"ok": false, "error": ("两条可调直道几乎平行（夹角仅 %.1f°，需要 ≥%.0f°）："
			+ "只有 1 个自由度，无法闭环。请把其中一条改成不同朝向的直道。")
			% [rad_to_deg(acos(clampf(absf(u1.dot(u2)), -1.0, 1.0))), MIN_HINGE_ANGLE_DEG]}
	var gx := gap_vec.x
	var gz := gap_vec.z
	var d1 := (gx * u2.z - gz * u2.x) / det
	var d2 := (u1.x * gz - u1.z * gx) / det
	var lens: Array = []
	for i in range(segments.size()):
		lens.append(-1.0)
	var i1 := int(straights[best_a]["index"])
	var i2 := int(straights[best_b]["index"])
	var l1 := float(straights[best_a]["length"]) + d1
	var l2 := float(straights[best_b]["length"]) + d2
	if l1 < MIN_STRAIGHT_AFTER_SOLVE or l2 < MIN_STRAIGHT_AFTER_SOLVE:
		return {"ok": false, "error": ("闭环需要把直道改成 %.1fm / %.1fm，太短（<%.0fm）："
			+ "说明这个布局的直道总长不够，请调整设计。")
			% [l1, l2, MIN_STRAIGHT_AFTER_SOLVE]}
	lens[i1] = l1
	lens[i2] = l2
	return {"ok": true, "error": "", "lengths": lens}


## 椭圆段的控制点：**必须与旧 track_generator._build_curve() 完全一致**
## （同样的 64 点、同样的 S 弯扰动公式），否则阶段 1 的"逐点对照"就失去意义。
static func _ellipse_points(args: Array) -> PackedVector3Array:
	var rx := float(args[0])
	var rz := float(args[1])
	var waves := 3.0
	var amp := 0.0
	if args.size() == 4:
		waves = float(args[2])
		amp = float(args[3])
	var out := PackedVector3Array()
	for i in range(ELLIPSE_SEGMENTS):
		var a := TAU * float(i) / float(ELLIPSE_SEGMENTS)
		var p := Vector3(cos(a) * rx, 0.0, sin(a) * rz)
		if amp > 0.001:
			var r := p.length()
			if r > 0.001:
				p = p + (p / r) * (sin(a * waves) * amp)
		out.append(p)
	# 闭合处补一个与首点重合的末点，便于统一处理"闭环残差"
	out.append(out[0])
	return out


## 收尾：闭环残差、曲率体检、半径分档统计。
## use_raw=true 时返回**原始控制点**（椭圆逐点对照用：重采样会改变曲线形状）；
## 否则返回按 step 重采样后的均匀点列（当作 Curve3D 的控制点最稳）。
static func _finish(pts: PackedVector3Array, mode: String, step: float, doubled: bool,
		rail_half: float, net_turn: float, use_raw: bool = false) -> Dictionary:
	if pts.size() < 3:
		return {"ok": false, "error": "骨架点太少（%d 个）" % pts.size()}
	var gap := pts[0].distance_to(pts[pts.size() - 1])
	var rs := _resample(pts, step)
	if rs.size() < 3:
		return {"ok": false, "error": "按 %.1fm 重采样后点太少（%d 个）" % [step, rs.size()]}
	# 曲率体检必须在**最终那条 Curve3D** 上做，不能在折线上做：
	# 折线量到的是"64 边形的折角"（椭圆上每角 5.6~7.7°），而车实际跑的是
	# 三次插值后的曲线（那些角被抹圆了）。在折线上量会把好赛道误判成不合格。
	# 返回哪一套点：椭圆逐点对照必须用**原始控制点**（重采样会改变曲线形状）
	var chosen := rs
	if use_raw:
		chosen = pts.duplicate()
	# 解算/重采样后末点可能还差几厘米：闭合精度内直接吸附到首点，保证曲线真正闭合
	if chosen.size() >= 2 and chosen[0].distance_to(chosen[chosen.size() - 1]) <= CLOSURE_TOL:
		chosen[chosen.size() - 1] = chosen[0]
	var stats := _curve_stats(chosen, step)
	var max_step := float(stats["max_heading_step_deg"])
	var max_dk := float(stats["max_dkappa"])
	var min_r := float(stats["min_radius"])
	if max_step > MAX_HEADING_STEP_DEG:
		return {"ok": false, "error": ("曲率体检不过：每 %.0fm 航向变化最大 %.2f° > %.1f°"
			+ "（说明有半径过小的弯：最小半径约 %.1fm）。这条门槛就是当年「接点曲率突变把车弹飞」的护栏。")
			% [step, max_step, MAX_HEADING_STEP_DEG, min_r]}
	if max_dk > MAX_DKAPPA:
		return {"ok": false, "error": ("曲率体检不过：每 %.0fm 曲率跳变最大 %.4f/m > %.3f/m"
			+ "（最硬处在弧长 %.1fm，那里相邻采样间距 %.2fm、航向变化 %.2f°）")
			% [step, max_dk, MAX_DKAPPA, float(stats.get("max_dkappa_arc", -1.0)),
			   float(stats.get("max_kappa_ds", -1.0)), float(stats.get("max_kappa_deg", -1.0))]}
	if rail_half > 0.0 and min_r <= rail_half + MIN_RAIL_CLEARANCE:
		return {"ok": false, "error": ("内护栏会自交：最小弯半径 %.1fm ≤ 护栏半宽 %.1fm + %.1fm 余量"
			+ "（自交会让 --check=enclosure 的射线打到另一侧的墙而**假通过**）")
			% [min_r, rail_half, MIN_RAIL_CLEARANCE]}
	return {"ok": true, "error": "", "points": chosen, "length": _curve_length(chosen),
		"closure_gap": gap, "min_radius": min_r, "max_heading_step_deg": max_step,
		"max_dkappa": max_dk, "radius_histogram": _radius_histogram(stats["samples"], step),
		"net_turn_deg": net_turn, "mode_used": mode, "doubled": doubled,
		"control_points": chosen.size(), "sample_points": rs.size()}


## 点列的**烘焙曲线**长度（与 track_generator 实际用到的长度同一口径）。
##
## ⚠ 四个坑都踩过（第一个直接把游戏搞成虚空）：
##   ① **Godot 4 的 Curve3D 没有 `cubic_interp` 属性**！写 `c.cubic_interp = true` 会报
##      「Invalid assignment of property 'cubic_interp'」→ 曲线对象失效 →
##      `get_baked_length()` 拿到 null → 长度 0 → 路面/护栏全不生成 → 车掉进虚空。
##   ② **Curve3D 默认是折线不是样条**：手柄为零时控制点之间是直线段。
##      现役赛道 64 个控制点 → 其实是 64 边形（每 ~25m 一个 5.6~7.7° 折角）。
##      所以 curve 必须走 make_curve（会按 Catmull-Rom 算手柄）。
##   ③ 必须**先加点、再设 bake_interval**：反过来时烘焙缓存不会因后续 add_point 失效。
##   ④ 即使这样也要验：返回值明显小于折线长度就退回折线长度并告警，绝不返回 0。
static func _curve_length(pts: PackedVector3Array) -> float:
	var poly := _polyline_length(pts)
	if pts.size() < 3:
		return poly
	var baked := make_curve(pts, true).get_baked_length()
	if baked < poly * 0.5:
		push_warning("[赛道布局] 曲线烘焙长度 %.1fm 明显小于折线长度 %.1fm，按折线长度计" % [baked, poly])
		return poly
	return baked


## 在**最终 Curve3D** 上按 step 采样后再量曲率（语义：车每跑 step 米航向变化多少度）。
## 同时返回采样点，供半径分档统计用同一套数据（否则分档会在折线上量，跟体检打架）。
static func _curve_stats(pts: PackedVector3Array, step: float) -> Dictionary:
	var c := make_curve(pts, true)
	var total := c.get_baked_length()
	if total < step * 3.0:
		return {"max_heading_step_deg": 999.0, "max_dkappa": 999.0, "min_radius": 0.0,
			"samples": PackedVector3Array()}
	var samples := PackedVector3Array()
	var d := 0.0
	while d < total:
		samples.append(c.sample_baked(d))
		d += step
	# ⚠ 收尾点要判重：total 常常正好是 step 的整数倍附近，直接 append 会得到一个
	# 与上一个点**几乎重合**的样本（间距 0.00m）→ 曲率 = Δθ/0 → 爆成 0.87/m，
	# 于是好赛道被判不合格（实测就是 L1 那处"弧长 778.0m"）。这不是赛道的问题，是量法的问题。
	var tail := c.sample_baked(total)
	if samples.is_empty() or samples[samples.size() - 1].distance_to(tail) > step * 0.25:
		samples.append(tail)
	var st := _curvature_stats(samples, step)
	st["samples"] = samples
	return st


## 按固定弧长把折线重采样成均匀点列（当作 Curve3D 的控制点最稳）。
static func _resample(pts: PackedVector3Array, step: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if pts.size() < 2:
		return out
	var cum := PackedFloat32Array()
	cum.append(0.0)
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
		cum.append(total)
	out.append(pts[0])
	var target := step
	var i := 1
	while target < total - 0.001:
		while i < pts.size() and cum[i] < target:
			i += 1
		if i >= pts.size():
			break
		var seg_len := cum[i] - cum[i - 1]
		var t := 0.0
		if seg_len > 0.0001:
			t = (target - cum[i - 1]) / seg_len
		out.append(pts[i - 1].lerp(pts[i], t))
		target += step
	return out


static func _polyline_length(pts: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
	return total


## 曲率体检：每站的航向变化、曲率跳变、由 local 曲率反推的最小半径。
static func _curvature_stats(pts: PackedVector3Array, step: float) -> Dictionary:
	var prev_dir := Vector3.ZERO
	var prev_kappa := 0.0
	var max_step := 0.0
	var max_dk := 0.0
	var min_r := INF
	var arc := 0.0
	var max_dk_arc := -1.0
	var max_kappa_ds := -1.0
	var max_kappa_deg := -1.0
	for i in range(1, pts.size()):
		var d := pts[i] - pts[i - 1]
		var ds := d.length()
		# 比 step 的 1/4 还短的间隔一律当"重合点"跳过：除它会得到假曲率
		if ds < step * 0.25:
			continue
		var dir := d / ds
		if prev_dir != Vector3.ZERO:
			var ang := rad_to_deg(prev_dir.angle_to(dir))
			max_step = maxf(max_step, ang)
			var kappa := deg_to_rad(ang) / ds
			var dk := absf(kappa - prev_kappa)
			if dk > max_dk:
				max_dk = dk
				max_dk_arc = arc
				max_kappa_ds = ds
				max_kappa_deg = ang
			if kappa > 0.000001:
				min_r = minf(min_r, 1.0 / kappa)
			prev_kappa = kappa
		prev_dir = dir
		arc += ds
	if min_r == INF:
		min_r = 99999.0
	return {"max_heading_step_deg": max_step, "max_dkappa": max_dk, "min_radius": min_r,
		"max_dkappa_arc": max_dk_arc, "max_kappa_ds": max_kappa_ds, "max_kappa_deg": max_kappa_deg}


## 弯道半径分档统计（便于核对"这关到底设计了几个什么弯"）。
static func _radius_histogram(pts: PackedVector3Array, step: float) -> Dictionary:
	var buckets := {"<20m": 0, "20~40m": 0, "40~80m": 0, "80~150m": 0, ">150m": 0}
	var prev_dir := Vector3.ZERO
	var last_bucket := ""
	var run := 0
	for i in range(1, pts.size()):
		var d := pts[i] - pts[i - 1]
		var ds := d.length()
		if ds < 0.0001:
			continue
		var dir := d / ds
		if prev_dir != Vector3.ZERO:
			var ang := rad_to_deg(prev_dir.angle_to(dir))
			var kappa := deg_to_rad(ang) / ds
			var r := 99999.0
			if kappa > 0.000001:
				r = 1.0 / kappa
			var b := ">150m"
			if r < 20.0:
				b = "<20m"
			elif r < 40.0:
				b = "20~40m"
			elif r < 80.0:
				b = "40~80m"
			elif r < 150.0:
				b = "80~150m"
			if b == last_bucket:
				run += 1
			else:
				if last_bucket != "" and run >= 4:      # 至少 4 站（8m）才算一个弯，滤掉噪声
					buckets[last_bucket] = int(buckets[last_bucket]) + 1
				last_bucket = b
				run = 1
		prev_dir = dir
	if last_bucket != "" and run >= 4:
		buckets[last_bucket] = int(buckets[last_bucket]) + 1
	var out := {}
	for k in buckets.keys():
		if int(buckets[k]) > 0:
			out[k] = buckets[k]
	return out


## 把构建好的点列写成 Curve3D —— **带 Catmull-Rom 手柄的真样条**。
##
## ⚠ 这里有个必须知道的事实（实测踩到）：
##   **Godot 的 Curve3D 默认是折线，不是样条** —— `add_point()` 的 in/out 手柄默认是
##   零向量，此时控制点之间就是直线段。现役赛道一直是 64 个控制点 → 它其实是一条
##   **64 边形**：每 ~25m 一个 5.6~7.7° 的折角（曲率无穷大）。
##   当年"直线+圆角矩形接点曲率突变把车弹飞"的根源就在这类折角上。
##   所以这里按 Catmull-Rom 给每个点算手柄：tangent = (next - prev) / 6，
##   曲线才真正 **C¹ 连续**，曲率体检也才有意义。
## 闭合时末点与首点重合 → 先去重，再用**环形邻居**算首尾手柄，保证接缝处也连续。
static func make_curve(points: PackedVector3Array, closed: bool, bake: float = 0.5) -> Curve3D:
	var c := Curve3D.new()
	if points.size() < 2:
		return c
	var ring := false
	var pts := points
	if closed and points[0].distance_to(points[points.size() - 1]) < 0.001:
		ring = true
		pts = points.slice(0, points.size() - 1)
	var n := pts.size()
	for i in range(n):
		var p: Vector3 = pts[i]
		var prev := p
		var next := p
		if ring:
			prev = pts[(i - 1 + n) % n]
			next = pts[(i + 1) % n]
		else:
			if i > 0:
				prev = pts[i - 1]
			if i < n - 1:
				next = pts[i + 1]
		var tangent := (next - prev) / 6.0
		c.add_point(p, -tangent, tangent)
	if ring:
		# ⚠ 收口那个点**必须给和首点相同的手柄**。给零手柄的话，最后一段就退化成
		# 直线段，两端各出现一个硬折角 —— 实测曲率跳变 0.87/m（R≈1.2m），
		# 曲率体检直接判不合格（而这是测量方法造成的假象，不是赛道真有问题）。
		var t0 := (pts[1] - pts[n - 1]) / 6.0
		c.add_point(pts[0], -t0, t0)
	c.bake_interval = bake
	return c
