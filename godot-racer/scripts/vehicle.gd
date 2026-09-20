extends VehicleBody3D
## 赛车控制器：W/S 油门倒车，A/D 转向，空格刹车，R 复位，V 切换视角
##
## 使用前提：
##   1. 本脚本挂在 VehicleBody3D 节点上（extends 已声明 VehicleBody3D）
##   2. VehicleBody3D 下必须有 4 个 VehicleWheel3D 子节点
##   3. 轮子的 use_as_traction / use_as_steering 建议在编辑器里勾好；
##      本脚本在 _ready() 里会按节点名兜底再设一遍，避免漏勾

# ---------------------------------------------------------------- 可调参数
@export_group("动力")
## 驱动轮最大力矩（整车质量 1200kg）。实测：Jolt+120Hz 下 4000 时
## 3 秒约 13 km/h、7 秒约 45 km/h，手感属"敏捷但不失控"。
@export var max_engine_force := 4000.0
## 倒车力矩（一般取前进的 40%~60%）
@export var reverse_force := 1800.0
## 松油门时的自然减速。
## 注意：这个值会直接抵消驱动力，实测 8.0 时把 W 的加速拖掉一大半，
## 所以给得很小；想更"溜车"就调到 0。
@export var engine_brake := 2.5
## 限速（km/h）。
## 这个值不是随手定的，而是按赛道几何反推：
##   本赛道两端弯道半径约 150 m，轮胎摩擦系数约 1.0，
##   可通过速度上限 v = sqrt(μ·g·r) = sqrt(1.0×9.8×150) ≈ 38 m/s ≈ 138 km/h。
##   实测车在 127 km/h 冲进弯道仍会转不过来（悬架/侧倾会吃掉一部分抓地），
##   所以保守取 100 km/h，让"不刹车也能过弯"。
## 想要更高极速，就相应放大 _build_curve() 里的弯道半径。
@export var max_speed_kmh := 100.0

@export_group("转向")
## 最大转向角（弧度）。0.5 rad ≈ 28.6°
@export var max_steer := 0.5
## 转向平滑速度，越大越灵敏
@export var steer_speed := 4.0
## 高速削弱转向的比例，避免高速一打方向就翻车
@export var steer_speed_falloff := 0.55
## 侧倾保护：车身横倾超过这个角度（度）就开始收转向权限。
## 为什么需要：A/D 打太猛时侧倾力矩超过轮距就翻车（实测按住 A/D 必翻）。
## 质心压低只是治本的一半，剩下靠"快翻的时候不让你继续加大方向"。
@export var roll_guard_angle := 14.0
## 侧倾到多少度时转向权限归零（越大越晚介入、越容易翻）
@export var roll_guard_limit := 34.0
## 单帧横向加速度上限（m/s²），超过就按比例削转向，防止"高速猛打方向"直接掀翻
@export var max_lateral_accel := 16.0

@export_group("制动")
## 刹车力矩（1000kg 建议 25~35）
@export var brake_force := 30.0

@export_group("音效")
@export var idle_pitch := 0.75
@export var max_pitch := 2.4
## 每挡覆盖的轮速区间，按手感调
@export var gear_span := 1400.0

@export_group("脱困")
## 是否开启自动脱困（翻车原地扶正 / 卡住后回到最近的检查点）
@export var auto_recover := true
## 判定"卡住"的条件：水平速度低于此值（m/s）且持续时间超过 recover_delay
@export var stuck_speed := 1.0
## 连续卡住多少秒后自动复位
@export var recover_delay := 4.0
## 楔入救援：车中心离墙多近才认为"贴墙楔入"（米）
@export var wedge_rescue_distance := 1.2
## 楔入救援：沿墙法线推出去多远（米）。够把 0.2m 的楔入拔出来，又不至于突兀。
@export var wedge_rescue_push := 0.8
## 车身偏离"上方向"超过此角度（度）视为翻车
@export var flip_angle := 70.0
## 腹部贴地滑行：四轮全不接地 + 车身基本水平 + 贴着路面在动，持续这么多秒就扶正。
##
## 为什么必须单列一条判据：这个状态**速度不低、姿态也不翻**，所以
##   - 翻车判定（看 up·UP）判不出它（车身是平的）
##   - 低速卡住判定（看速度 <1 m/s）也判不出它（它以 27km/h 在滑）
## 实测日志里它能横向滑行 10 秒以上一直脱不了困 —— 玩家感受就是"车不听使唤"。
@export var belly_slide_grace := 1.5
## 腹部贴地判定：车身偏离"上方向"在这个角度以内算基本水平（排除腾空翻车）
@export var belly_upright_angle := 25.0
## 腹部贴地判定：车体中心离路面低于这个高度才算"贴着路面"（排除正常腾空飞跃）
@export var belly_near_surface := 1.5
## 从腹部贴地状态扶起时，抬离地面多少米
@export var belly_lift := 0.45
## 从腹部贴地状态扶起时补的**向上速度增量**（m/s，不是冲量）
##
## ⚠ 单位坑：apply_central_impulse 收的是 N·s（kg·m/s）。本车约 1000kg，
## 直接给 0.5 N·s 只能产生 0.5mm/s 的速度增量，**等于没给** ——
## 下一帧车还会贴着地面。所以这里存"速度增量"，施加时乘以 mass。
@export var belly_impulse_dv := 0.5

@export_group("稳定性")
## 质心高度（车体本地 y）。**必须手动压低**：
## Godot 的 VehicleBody3D 默认按碰撞盒自动算质心，本车得到约 0.55 m，
## 而轮距只有 ±0.68 m —— 侧倾力矩一超过轮距就翻车（实测：按住 A/D 几秒必翻）。
## 0.2 大致在轮轴线略上方，既压住侧倾，又不至于像"贴地"那样失真。
@export var center_of_mass_height := 0.2

@export_group("出界兜底")
## 是否开启出界自动回赛道
@export var auto_reset_out_of_bounds := true
## 界外判定余量（米）：允许偏离中心线的上限 = 护栏中心线 + 车身半宽 + 这个余量。
##
## ⚠ 这里踩过一个很严重的坑：最初我把"高速时的余量"设成 0.3m（想的是"高速飞出要立刻拉回"），
## 但判定基线是**护栏中心线 8.2m**，而车宽 1.89m —— 贴着墙走时车的**中心**离中心线本来
## 就能到 8.2+0.95≈9.15m。结果只要贴着墙跑到 8.5m/s 以上，就被判"出界"→ 复位 →
## 又贴墙 → 再复位，形成**死循环**（实测日志里每帧一次，复位点固定不动，
## 表现就是"快回到起点时一直在重置"）。
## 现在改成：基线 = 护栏中心线 + 车身半宽 + 余量，且**不随速度收紧**。
## 物理上，通道封闭时车永远到不了这个距离，所以不可能再误判；
## 真要掉出赛道/被挤出墙外时，它一定会超过这个值，兜底照样生效。
@export var out_of_bounds_margin := 4.0
## 车身半宽估值（米）。用于把"车中心"换算成"车外缘"：
## 判定要看的是车有没有出通道，不是车中心有没有压到墙。
@export var body_half_width := 1.0
## 界外停留多久才拉回（秒）。给一点宽限，避免单帧抖动触发。
@export var out_of_bounds_delay := 0.5
## 复位后至少要开多远（米）才允许计圈。
## 为什么需要：复位会把车瞬移到中心线上，如果那一下正好穿过起终点平面，
## 几何判定就会**白记一圈**（实测复现：复位落点在起点，瞬间多出一圈 60.9s、速度 0）。
## 正常跑一圈要一千多米，100m 的门槛不影响真实计圈，只挡瞬移造成的假圈。
@export var lap_min_distance_after_reset := 100.0
## 复位后的无敌时间（秒）。这段时间内不与其它车辆碰撞、也不触发检查点，
## 免得刚回到赛道上就被后车顶飞或被判定成压线。
@export var reset_immunity_time := 2.0

@export_group("车轮动画")
## 让模型里的车轮网格跟着物理轮转。
##
## VehicleWheel3D 只有物理、没有视觉 —— race_car.glb 里的
## Tire_*/Rim_*/Hub_* 是独立节点，**必须手动驱动**，否则车在跑、轮子一动不动。
@export var spin_wheel_meshes := true

# ---------------------------------------------------------------- 内部状态
var _steer := 0.0                 # 平滑后的转向角
var _wheel_base := 2.1            # 轴距，_ready 里实测
var _driving := false
var _braking := false
## 本帧的"倒车意图"（0~1）：玩家按住 S 时 > 0。
##
## 为什么把它存成成员变量，而不是在 `_check_wrong_way` 里直接
## `Input.is_action_pressed("brake_reverse")`：验收/回放里的输入是脚本合成的，
## 直接读 Input 在不同时序下不稳；而 `_update_drive` 已经把"W=+1 / S=−1"这个
## 意图解析好了 —— 复用它才是**同一份真相**（本项目最忌两处各判一次）。
var input_brake_reverse := 0.0
var _gear := 1
var _gear_count := 5
var _rpm01 := 0.0                 # 0~1 的挡内转速比例
var _stuck_time := 0.0
var _prev_planar_speed := 0.0      # 上一帧水平速度，用于识别"撞上东西"的速度骤降
## 四轮全不接地已持续多久（秒）。腹部贴地滑行判定用。
var _belly_time := 0.0
## 腹部贴地扶正的次数。供验收读取（--check=flip 用它确认"确实触发了恢复"）
var belly_recovery_count := 0
## **仅供验收用**的夹具：置 true 时临时关掉重力，把车"悬"在路面上方。
##
## 为什么需要它：腹部贴地（四轮全不接地 + 车身水平 + 贴在路面 + 还在动）在真实物理里
## 很难稳定构造 —— 实测用 6 个合成姿态都只能维持 0.2~0.33s 就落回四轮接地。
## 这个夹具不改任何被测量的状态（接地数/姿态/速度全是真实物理读数），
## 只是让车停在原地不往下掉，好让检验能稳定地跑起来。正常游玩永远不会打开它。
var belly_test_hover := false
## 夹具用：进夹具前的 gravity_scale（-1 = 还没记录过）
var _gravity_scale_normal := -1.0

# ---- 出界兜底 / 复位 用的状态 ----
## 赛道节点（提供中心线查询）。_ready 里找一次，之后不再 get_node。
var _track: Node3D = null
## 「开反了」状态机的实现模块（`track_layout.gd`，纯静态函数）。
## 为什么从模块里调而不是本文件写一套阈值：见 `_check_wrong_way` 的说明。
var _wrong_way_mod: GDScript = null

# ---- 「开反了」提示的状态（HUD 直接读这两个）----
## 是否正在提示"开反了"。**带迟滞**，所以它是一个跨帧保持的状态，
## 不是"每帧按当前朝向现算"的表达式。
var wrong_way := false
## 最近一次状态迁移的原因（只用于日志/排查，判定不看它）
var wrong_way_reason := ""
# ---- 「方向反了」的三个门限（从 LevelConfig 读；缺配置时用 track_layout 的默认值）----
## 速度阈值（km/h）
var _reverse_speed_kmh := 15.0
## 进入角度阈值（度）
var _reverse_enter_deg := 120.0
## 退出角度阈值（度）
var _reverse_exit_deg := 105.0
## 最近一次算出的"我在中心线上的弧长"，作为下次局部搜索的起点
var _arc_hint := -1.0
## 连续处于界外的时间
var _out_time := 0.0
## 复位后的剩余无敌时间
var _immunity := 0.0
## 最近通过的检查点顺序（当前保留作诊断用；复位落点由中心线查询决定）
var _last_checkpoint_order := -1
## 复位冷却，避免同一帧/连续帧反复瞬移
var _reset_cooldown := 0.0
## 复位后的隔离：这段时间/距离内不计圈。
## 复位是瞬移，会穿过起终点平面；不隔离就会"白记一圈"，
## 表现就是用户看到的"上圈和最快圈显示成同一个时间、而且本圈不计时"。
var _reset_isolate_until_ms := 0.0
var _reset_isolate_from := Vector3.ZERO
## 上一次复位的时间与位置，用于识别"复位死循环"（复位后又回到同一处又被判出界）
var _last_reset_ms := 0.0
var _last_reset_pos := Vector3.ZERO
var _reset_loop_count := 0

# ---- 圈速状态 ----
## 车是否在起终点线**后面**（起跑时在，向前越过白线即完成一次压线）
var _lap_armed := true
## 上一帧"车在起终点线前方的有符号距离"
var _prev_line_signed := -1.0
## 本圈是否已经开始计时
var _lap_running := false
var _lap_start_ms := 0.0
## 计圈抑制：出生/复位瞬间车压在起终点平面上，这段时间内一律不判压线。
## **默认必须是 true** —— 出生后第一帧物理就会跑判定，那时车还在赛道中心线
## （起点平面正穿过那里），实测会误报一次"第一次压线"。
var _lap_suppressed := true
## 已完成的上圈 / 最快圈（秒，0 = 还没有）
var lap_last := 0.0
var lap_best := 0.0
## 已完成圈数（暂停菜单显示进度用）
var laps_done := 0
## 本关要跑几圈（由 GameState 注入；<=0 表示不限）
var laps_target := 0
## 玩家在菜单里调的极速（km/h）。加载关卡时由 main.gd 写入。
var tuned_max_speed := 0.0

## 压线信号：按顺序给出 (上圈秒数, 最快秒数)。HUD 连它来刷新显示。
signal lap_completed(last_lap: float, best_lap: float)

## 单位立方体的 8 个角点比例，用于手动变换包围盒
## （AABB.get_endpoint 的参数是 int 索引，不是向量，所以自己算角点）
const CORNER_SCALES := [
	Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
	Vector3(1, 1, 0), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1),
]

## 车辆所在的物理层号（project.godot: 3d_physics/layer_2 = "vehicle"）
const VEHICLE_LAYER := 2
## 离中心线多近时，按 R 只扶正不传送（米）
const NEAR_TRACK_RESET_DIST := 3.0

var _steer_wheels: Array[VehicleWheel3D] = []
var _drive_wheels: Array[VehicleWheel3D] = []
## 每个车轮角一份：物理轮 + 它的视觉网格 + 静止姿态 + 自转/转向轴
var _wheel_visuals: Array = []

@onready var _engine_sound: AudioStreamPlayer3D = $EngineSound


func _ready() -> void:
	# 记下原始重力倍率：验收夹具（belly_test_hover）会临时把它置 0，用完要还原
	_gravity_scale_normal = gravity_scale
	_apply_center_of_mass()
	classify_wheels()
	_measure_wheel_base()
	_find_track()
	# 出生点/车轮视觉都要读赛道数据，而赛道是"延迟构建"的
	# （Track 的 _ready 总在 main.gd 之前跑，见 track_generator 的说明），
	# 所以这里必须等赛道就绪 —— 否则车会被放到世界原点、检查点也连不上。
	_deferred_setup()


func _deferred_setup() -> void:
	if _track != null and _track.has_method("await_world_ready"):
		await _track.call("await_world_ready")
	_place_on_start_line()
	# 车轮视觉要在 _place_on_start_line 之后绑定：那里会改车的朝向，
	# 而自转轴是按"模型 Z 轴在世界里的方向"换算到车轮本地的。
	_bind_wheel_visuals()
	if _engine_sound and _engine_sound.stream:
		_engine_sound.play()
	# 记下起跑弧长，作为之后中心线局部搜索的起点
	if _track != null:
		var near := _nearest_track_point()
		if not near.is_empty():
			_arc_hint = float(near["arc"])
	_reset_lap_state()
	print("[车辆] 赛道就绪后初始化完成：出生点 %s" % global_position)


## 出生瞬间把计圈状态对齐到"车尾在线后"。
##
## 为什么必须做：车出生在赛道中心线上，而起终点平面正好穿过那里 ——
## 不处理的话第一帧就会被判成"压线"，本圈计时从出生开始跑，
## 玩家真正压线那一下还会被当成"已经压过了"。实测日志里就有
## `[计圈] 开始计时（第一次压线）pos=(320.0, 0.55, 0.0) 速度=0.0 km/h`。
func _reset_lap_state() -> void:
	_lap_running = false
	_lap_armed = true
	_prev_line_signed = -1.0      # 强制下一次判定为"在线后"
	# 显式抑制：出生/复位那一瞬间车正压在起终点平面上，不能算"压线"。
	# 只靠 _prev_line_signed 不够 —— 实测仍会误判一次（因为判定在摆位之前就跑过了）。
	_lap_suppressed = true
	laps_done = 0
	lap_last = 0.0
	lap_best = 0.0
	if _track == null:
		return
	var lc = _track.get("start_line_center")
	var lf = _track.get("start_line_forward")
	if lc is Vector3 and lf is Vector3:
		var f: Vector3 = (lf as Vector3)
		f.y = 0.0
		if f.length() > 0.01:
			_prev_line_signed = (global_position - (lc as Vector3)).dot(f.normalized())
	# 摆位完成、进入稳定状态后才允许计圈
	_release_lap_suppression()


func _release_lap_suppression() -> void:
	# 等两帧：确保车已经被摆到起跑线后、物理也稳定了
	await get_tree().physics_frame
	await get_tree().physics_frame
	_lap_suppressed = false
	_lap_running = false
	_lap_armed = true
	_lap_start_ms = Time.get_ticks_msec() / 1000.0
	_prev_line_signed = -1.0
	print("[计圈] 计圈已就绪（出生位置不计圈，出发后第一次压线才开始计时）")


## 找到赛道节点（提供中心线查询）。找不到就退化为"没有出界兜底"，
## 老行为（纯检查点复位）仍然可用。
func _find_track() -> void:
	var p := get_parent()
	if p != null:
		_track = p.get_node_or_null("Track") as Node3D
	if _track != null:
		print("[车辆] 已接上赛道数据源，出界兜底/中心线复位可用")
	# 「开反了」判定的纯函数模块。加载失败不致命：检测只是提示，不该拖垮开车。
	_wrong_way_mod = load("res://scripts/track_layout.gd")
	if _wrong_way_mod == null or not _wrong_way_mod.has_method("wrong_way_state"):
		_wrong_way_mod = null
		push_warning("[车辆] track_layout.gd 不可用 → 「方向反了」提示停用（不影响驾驶）")
	else:
		# 三个门限从**本关配置**读（规格要求"不得硬编码，必须可配置"）。
		# found_node: Track 是兄弟节点，LevelConfig 由 main.gd 注入到它身上。
		var found_cfg: LevelConfig = null
		if _track != null:
			var c = _track.get("level_config")
			if c is LevelConfig:
				found_cfg = c
		if found_cfg != null:
			_reverse_speed_kmh = found_cfg.reverse_speed_threshold_kmh
			_reverse_enter_deg = found_cfg.reverse_angle_enter_deg
			_reverse_exit_deg = found_cfg.reverse_angle_exit_deg
			print("[车辆] 「方向反了」门限取自本关配置：速度 %.0f km/h、进入 %.0f°、退出 %.0f°"
				% [_reverse_speed_kmh, _reverse_enter_deg, _reverse_exit_deg])
		else:
			# 兜底：用 track_layout.gd 的默认常量（同样是"一份来源"，不是这里另写数字）
			var m: GDScript = _wrong_way_mod
			_reverse_speed_kmh = float(m.get("REVERSE_SPEED_KMH"))
			_reverse_enter_deg = float(m.get("REVERSE_ANGLE_ENTER_DEG"))
			_reverse_exit_deg = float(m.get("REVERSE_ANGLE_EXIT_DEG"))
			print("[车辆] 没读到 LevelConfig → 「方向反了」用默认门限：%.0f km/h / %.0f° / %.0f°"
				% [_reverse_speed_kmh, _reverse_enter_deg, _reverse_exit_deg])


## 查询"我离中心线最近的点"（含该点切线方向与弧长）
func _nearest_track_point() -> Dictionary:
	if _track == null or not _track.has_method("nearest_on_centerline"):
		return {}
	return _track.call("nearest_on_centerline", global_position, _arc_hint)


## 「开反了」检测：赛道只允许**顺时针**行驶，反着开要提示玩家。
##
## ⚠ 判据是「**车头**朝着赛道反方向 且 玩家在朝前开」，**不是**"行进方向反了"。
##   这条口径来自项目所有者 2026-09 的明确要求：
##     「倒车不属于反方向。万一因为碰撞导致车反了，允许玩家倒车以调整方向」
##   两件事必须分开，用行进方向判会把它们混成一个：
##     · **开反了** —— 车头朝赛道反方向，而玩家按 W 往前开 → 提示
##     · **倒车救车** —— 玩家主动按 S。车头朝后时按 S 恰恰是"沿赛道正方向退出去"，
##       是**正确**的救车动作，提示它等于骂玩家做对了事 → 一律不提示
##
## 阈值全部来自 `track_layout.wrong_way_state()`（纯状态机，`--check=layout` 第⑤组
## 穷举断言）。**这里不许再写一套阈值** —— 两套逻辑漂移是本项目吃过最大的亏。
##
## 为什么状态要存在车身上（而不是每帧现算）：阈值有**迟滞**（进出门限不同），
## 迟滞天生是状态机，必须记住上一帧的判断，否则死区根本不存在、提示会闪。
func _check_wrong_way() -> void:
	if _wrong_way_mod == null:
		return
	if _track == null or not _track.has_method("nearest_on_centerline"):
		return
	var near := _nearest_track_point()
	if near.is_empty():
		return
	var fwd: Vector3 = near.get("forward", Vector3.FORWARD)
	fwd.y = 0.0
	var vel := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var speed := vel.length()
	# 车头方向（本地 -Z 是车头，见 _update_drive 的方向说明）
	var nose := -global_transform.basis.z
	nose.y = 0.0
	var dot := 0.0
	if fwd.length() > 0.001 and nose.length() > 0.001:
		dot = nose.normalized().dot(fwd.normalized())
	# 玩家是否在主动倒车：input_brake_reverse 由 _update_drive 同帧写入（见那里的注释）。
	# 为什么不用 `Input.is_action_pressed("brake_reverse")` 直接读：验收/回放里
	# 输入是脚本合成的，读 Input 在 headless 与不同时序下不稳；而 _update_drive
	# 已经把这个意图解析好了（W 为 +1、S 为 −1），复用它才是同一份真相。
	var reversing := input_brake_reverse > 0.5
	# 三个门限来自**本关配置**（LevelConfig，见 reverse_* 字段），不在这里写死。
	# 速度按规格用 km/h 传入（规格表里就是 km/h）。
	var d: Dictionary = _wrong_way_mod.call("wrong_way_state", wrong_way, dot, speed * 3.6,
		reversing, _reverse_enter_deg, _reverse_exit_deg, _reverse_speed_kmh)
	wrong_way = bool(d.get("wrong_way", false))
	wrong_way_reason = str(d.get("reason", ""))


## 护栏中心线半宽（米）
func _rail_half_width() -> float:
	if _track != null and _track.has_method("rail_half_width"):
		return float(_track.call("rail_half_width"))
	return 8.2


## 路面半宽（米）
func _road_half_width() -> float:
	if _track != null and _track.has_method("road_half_width"):
		return float(_track.call("road_half_width"))
	return 7.0


## 手动压低质心。
## Godot 的 VehicleBody3D 默认 center_of_mass_mode = AUTO，会按碰撞盒算出
## 约 y=0.55 的质心；而本车轮距只有 ±0.68，侧倾力矩一超过轮距就侧翻
## （实测：按住 A/D 几秒必翻）。这是三个手感问题里最根本的一个。
func _apply_center_of_mass() -> void:
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, center_of_mass_height, 0.0)
	print("[车辆] 质心已设为 y=%.2f（AUTO 默认约 0.55，会侧翻）" % center_of_mass_height)


## 把车停在起终点线**后面**。
##
## 为什么需要这个：起终点线不是一个"面"，而是一块横跨路面的长方形贴片
## （宽 = 路面宽，长 = start_line_depth）。如果只把车放在线的中心，
## 车就会骑在线上、一半在线前 —— 这不是合法的起跑位置。
##
## 正确做法：沿赛道方向**后退**，退到"车头刚好压在线后边缘"的位置。
## 后退距离 = 线厚/2 + 车头到车体中心的距离 + 一点余量。
## 这样换赛道形状或换车模型都会自动适配，不必手调坐标。
func _place_on_start_line() -> void:
	var track := get_parent().get_node_or_null("Track")
	if track == null:
		return
	var line_center = track.get("start_line_center")
	var line_fwd = track.get("start_line_forward")
	var line_depth: float = track.get("start_line_depth")
	if not (line_center is Vector3) or not (line_fwd is Vector3):
		return

	var fwd: Vector3 = line_fwd
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return
	fwd = fwd.normalized()

	# 车头到车体中心的距离：用**车头/车尾零件**的实测距离更准，
	# 包围盒会把尾翼和前翼算进去、比轴距大，用它会让车停得过远。
	var half_length := _measure_nose_to_center()
	var clearance := 0.08       # 只留一点点余量，让车头紧贴线后沿（标准起跑位）
	var back := line_depth * 0.5 + half_length + clearance

	var target: Vector3 = (line_center as Vector3) - fwd * back
	global_position = Vector3(target.x, global_position.y, target.z)

	# 车头朝向必须与赛道前进方向一致（车头在本地 -Z，所以要 +PI）
	rotation.y = atan2(fwd.x, fwd.z) + PI

	print("[车辆] 出生点已按白线计算：线中心 z=%.2f，线厚 %.2f，车长 %.2f"
		% [(line_center as Vector3).z, line_depth, half_length * 2.0])
	print("[车辆] 沿赛道后退 %.2f m  →  出生位置 %s  （车头朝向赛道方向）"
		% [back, global_position])


## 量"车头到车体中心"的距离。
## 用前翼(Nose_Wing)与尾翼(Wing_Main)的世界位置：车体中心取两者中点，
## 车头到中心的距离 = 前翼到中点距离。这比包围盒准，因为包围盒受翼板影响。
func _measure_nose_to_center() -> float:
	var model := get_node_or_null("CarModel")
	if model == null:
		return 1.85
	var nose := model.find_child("Nose_Wing", true, false)
	var wing := model.find_child("Wing_Main", true, false)
	if nose is Node3D and wing is Node3D:
		var d := (nose as Node3D).global_position - (wing as Node3D).global_position
		d.y = 0.0
		return d.length() * 0.5
	# 退路：用包围盒的一半
	return _measure_body_length() * 0.5


## 量车体包围盒的车长（取 X/Z 中较大的那个水平尺寸）
func _measure_body_length() -> float:
	var model := get_node_or_null("CarModel")
	if model == null:
		return 3.7
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	var found := false
	for mi in _all_meshes(model):
		found = true
		var local: AABB = mi.mesh.get_aabb()
		for s in CORNER_SCALES:
			var p: Vector3 = mi.global_transform * (local.position + local.size * s)
			mn = mn.min(p)
			mx = mx.max(p)
	if not found:
		return 3.7
	var size := mx - mn
	return maxf(size.x, size.z)


func _all_meshes(node: Node) -> Array:
	var out := []
	for c in node.get_children():
		if c is MeshInstance3D and c.mesh != null:
			out.append(c)
		out.append_array(_all_meshes(c))
	return out


## 按节点名把车轮分成转向轮 / 驱动轮，并顺手写好开关
func classify_wheels() -> void:
	for child in get_children():
		if child is VehicleWheel3D:
			var wheel: VehicleWheel3D = child
			var n := wheel.name.to_lower()
			if n.contains("front"):
				wheel.use_as_steering = true
				_steer_wheels.append(wheel)
			if n.contains("rear"):
				wheel.use_as_traction = true
				_drive_wheels.append(wheel)

	# 名字里既没有 front 也没有 rear 时，退化为「前两个转向、后两个驱动」
	if _steer_wheels.is_empty() or _drive_wheels.is_empty():
		push_warning("车轮命名未包含 Front/Rear，按子节点顺序退化分配")
		var all: Array[VehicleWheel3D] = []
		for child in get_children():
			if child is VehicleWheel3D:
				all.append(child)
		if all.size() >= 4:
			_steer_wheels = [all[0], all[1]]
			_drive_wheels = [all[2], all[3]]
			all[0].use_as_steering = true
			all[1].use_as_steering = true
			all[2].use_as_traction = true
			all[3].use_as_traction = true


## 轴距 = 前轮平均 Z 与后轮平均 Z 之差
## 注意：Godot 里车长沿 Z 轴（车头朝 -Z），横向才是 X 轴。
## 一开始这里误读了 position.x，而前轮与后轮的 X 都是 ±0.68，
## 平均值相同、相减恒为 0，导致轴距恒被判定为异常。
func _measure_wheel_base() -> void:
	var front_z := 0.0
	var rear_z := 0.0
	var fn := 0
	var rn := 0
	for w in _steer_wheels:
		front_z += w.position.z
		fn += 1
	for w in _drive_wheels:
		rear_z += w.position.z
		rn += 1
	if fn > 0 and rn > 0:
		_wheel_base = absf(front_z / float(fn) - rear_z / float(rn))
	if _wheel_base < 0.5:
		push_warning("轴距测量异常（%.2f m），回退默认值 2.1" % _wheel_base)
		_wheel_base = 2.1


## 按角名找对应的 VehicleWheel3D（WheelFrontLeft -> front_left）
func _find_wheel(key: String) -> VehicleWheel3D:
	var want := key.replace("_", "")
	for child in get_children():
		if child is VehicleWheel3D:
			var n: String = child.name.to_lower().replace("wheel", "").replace("_", "")
			if n == want:
				return child
	return null


## 车轮视觉绑定：把四个角上的 Tire_/Rim_/Hub_ 网格和对应的物理轮关联起来。
##
## 关键点：模型是 90° 旋转过的 —— 车体横向对应**模型 Z 轴**、车体上方向对应模型 Y 轴。
## 所以自转轴必须取"模型 Z 轴在世界里的方向，换算到该网格的本地坐标系"，
## 直接按网格本地的 X 轴转会变成车轮左右摇摆（这是最容易写错的一步）。
func _bind_wheel_visuals() -> void:
	if not spin_wheel_meshes:
		return
	var model_node := get_node_or_null("CarModel")
	if not (model_node is Node3D):
		push_warning("没有 CarModel 节点，车轮动画跳过")
		return
	var model: Node3D = model_node

	var corners := {
		"front_left": ["Tire_Front_L", "Rim_Front_L", "Hub_Front_L"],
		"front_right": ["Tire_Front_R", "Rim_Front_R", "Hub_Front_R"],
		"rear_left": ["Tire_Rear_L", "Rim_Rear_L", "Hub_Rear_L"],
		"rear_right": ["Tire_Rear_R", "Rim_Rear_R", "Hub_Rear_R"],
	}
	for key in corners.keys():
		var wheel := _find_wheel(key)
		if wheel == null:
			continue
		var meshes: Array[Node3D] = []
		var rests: Array[Basis] = []
		var spins: Array[Vector3] = []
		var ups: Array[Vector3] = []
		for nm in corners[key]:
			var n := model.find_child(nm, true, false)
			if not (n is Node3D):
				continue
			var node: Node3D = n
			meshes.append(node)
			rests.append(node.basis)
			spins.append((node.global_transform.basis.inverse() * model.global_transform.basis.z).normalized())
			ups.append((node.global_transform.basis.inverse() * model.global_transform.basis.y).normalized())
		if meshes.is_empty():
			continue
		_wheel_visuals.append({
			"wheel": wheel,
			"meshes": meshes,
			"rests": rests,
			"spins": spins,
			"ups": ups,
			"angle": 0.0,
		})
	print("[车辆] 车轮视觉已绑定 %d 个角（自转轴 = 模型 Z 轴）" % _wheel_visuals.size())


## 车轮视觉：自转 + 前轮转向。
## 自转角速度直接取"前进速度 / 轮半径"，比用 get_rpm() 少一层符号不确定性。
func _update_wheel_visuals(delta: float) -> void:
	if _wheel_visuals.is_empty():
		return
	# 前进速度 = 速度在车头方向上的投影（车头在本地 -Z）
	var forward_speed := linear_velocity.dot(-global_transform.basis.z)
	for entry in _wheel_visuals:
		var wheel: VehicleWheel3D = entry["wheel"]
		if wheel == null or not is_instance_valid(wheel):
			continue
		var radius: float = maxf(wheel.wheel_radius, 0.05)
		var angle: float = float(entry["angle"]) + forward_speed / radius * delta
		entry["angle"] = angle
		var steer: float = steering if wheel.use_as_steering else 0.0
		var meshes: Array = entry["meshes"]
		var rests: Array = entry["rests"]
		var spins: Array = entry["spins"]
		var ups: Array = entry["ups"]
		for i in meshes.size():
			var node: Node3D = meshes[i]
			var rest: Basis = rests[i]
			var up: Vector3 = ups[i]
			var spin_axis: Vector3 = spins[i]
			# 先绕本地"上"转转向角，再绕（转完之后的）本地自转轴转滚动角
			node.basis = rest * Basis(up, steer) * Basis(spin_axis, angle)


func _physics_process(delta: float) -> void:
	if belly_test_hover:
		# 验收夹具（见 belly_test_hover 的说明）：临时关掉重力把车"悬"在路面上方。
		#
		# 为什么不用"施加向上力"：实测施加 mass*9.8 的升力**托不住** —— 车在 0.5s 内
		# 就掉回地面、轮子重新抓地，速度从 24.4km/h 掉到 1.2km/h，状态根本没维持住。
		# 直接关重力是确定性的：没有净力，车就停在原地保持水平。
		gravity_scale = 0.0
		linear_velocity.y = 0.0
	elif _gravity_scale_normal >= 0.0:
		gravity_scale = _gravity_scale_normal
	_update_drive()
	_update_steering(delta)
	_update_wheel_visuals(delta)
	_update_engine_sound(delta)
	_check_recovery(delta)
	_check_out_of_bounds(delta)
	_check_wrong_way()
	_check_start_line_crossing()
	if _immunity > 0.0:
		_immunity = maxf(_immunity - delta, 0.0)
		if _immunity == 0.0:
			_set_ghost(false)
	if _reset_cooldown > 0.0:
		_reset_cooldown = maxf(_reset_cooldown - delta, 0.0)


## 压线判定：用**几何平面穿越**，不用 Area3D 信号。
##
## 为什么换掉 Area3D：实测出现过"上圈和最快圈显示成同一个时间、本圈压根不计时"的
## 症状 —— 那是门体信号在高速下漏检/误触发。车每帧位移不到 1m，而门只有 1m 厚，
## 用平面穿越判定是确定的，不存在漏检。
##
## 判据：把车的水平位置投影到起终点线的"前方轴"上，取有符号距离 s。
##   起跑时车在白线**后面**（s < 0）。s 从负变正 = 向前压线，完成一圈。
func _check_start_line_crossing() -> void:
	if _track == null or _lap_suppressed:
		return
	var line_center = _track.get("start_line_center")
	if not (line_center is Vector3):
		return
	var fwd: Vector3 = _track.get("start_line_forward")
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return
	fwd = fwd.normalized()
	var p: Vector3 = global_position - (line_center as Vector3)
	var s := p.dot(fwd)
	# 只在贴近白线时判定，避免远处（椭圆另一侧的对称点）也被算成压线
	var lateral := (p - fwd * s).length()
	if lateral > _rail_half_width() * 2.0:
		_prev_line_signed = s
		return
	if _lap_armed and _prev_line_signed < 0.0 and s >= 0.0:
		# 复位隔离：刚被瞬移过就不认这次压线（否则复位本身会白送一圈）
		if _reset_isolate_until_ms > 0.0:
			var moved := global_position.distance_to(_reset_isolate_from)
			if Time.get_ticks_msec() < _reset_isolate_until_ms and moved < lap_min_distance_after_reset:
				_lap_armed = s < 0.0
				_prev_line_signed = s
				return
			_reset_isolate_until_ms = 0.0
		_on_lap_crossed()
	_lap_armed = s < 0.0
	_prev_line_signed = s


func _on_lap_crossed() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not _lap_running:
		# 第一次压线：只开始计时，不算一圈（起跑到压线之间的时间不是圈速）
		_lap_running = true
		_lap_start_ms = now
		print("[计圈] 开始计时（第一次压线）pos=%s 速度=%.1f km/h"
			% [global_position, linear_velocity.length() * 3.6])
		return
	var lap := now - _lap_start_ms
	lap_last = lap
	laps_done += 1
	if lap_best <= 0.0 or lap < lap_best:
		lap_best = lap
	_lap_start_ms = now
	print("[计圈] 完成第 %d 圈：%.3f 秒（最快 %.3f，目标 %d 圈）pos=%s 速度=%.1f km/h"
		% [laps_done, lap, lap_best, laps_target, global_position, linear_velocity.length() * 3.6])
	lap_completed.emit(lap_last, lap_best)
	if laps_target > 0 and laps_done >= laps_target:
		print("[计圈] 已达成目标圈数 %d，本关完成" % laps_target)
		race_finished.emit(laps_done)


## 本关完成（达到目标圈数）时发出
signal race_finished(total_laps: int)


## 加载关卡时注入：目标圈数 + 玩家调校的极速 + 天气带来的抓地力倍率
func apply_level_setup(speed_kmh: float, laps: int, friction_mult: float) -> void:
	if speed_kmh > 1.0:
		max_speed_kmh = speed_kmh
		tuned_max_speed = speed_kmh
	laps_target = laps
	_apply_friction(friction_mult)
	print("[车辆] 关卡设置：极速上限 %.0f km/h，目标 %d 圈，抓地力 ×%.2f"
		% [max_speed_kmh, laps, friction_mult])


## 抓地力倍率：直接乘到每个轮胎的 wheel_friction_slip 上（雨天/雪天用）。
## 记录原始值，保证换关卡时不会越乘越小。
func _apply_friction(mult: float) -> void:
	for child in get_children():
		if child is VehicleWheel3D:
			var w: VehicleWheel3D = child
			if not _wheel_friction_base.has(w):
				_wheel_friction_base[w] = w.wheel_friction_slip
			w.wheel_friction_slip = float(_wheel_friction_base[w]) * clampf(mult, 0.2, 2.0)


var _wheel_friction_base := {}


## 本圈已用时（秒）。没在计时就返回 0。
func current_lap_time() -> float:
	if not _lap_running:
		return 0.0
	return Time.get_ticks_msec() / 1000.0 - _lap_start_ms


## 四个轮子里有几个正在接地（0~4）。
##
## 为什么单独抽成一个函数：它是"腹部贴地滑行"判据的核心读数，
## 而验收（--check=flip）也要用同一口径来判定"到底恢复没有"。
## 用 VehicleWheel3D.is_in_contact()，与日志里的"接地=N/4"完全一致。
func grounded_wheel_count() -> int:
	var n := 0
	for child in get_children():
		if child is VehicleWheel3D and (child as VehicleWheel3D).is_in_contact():
			n += 1
	return n


## 自动脱困：撞护栏卡住、翻车后自动扶正。
##
## 重要教训：最初我把"水平速度长期接近 0"当成卡住的唯一判据，
## 结果玩家停车不动、只想环视看看车时也会被判定为卡住并瞬移到检查点 ——
## 实测复现：静止 4 秒后车被挪动 2.36m，表现为"车一直跳、像被重置"。
## 现在要求同时满足：确实在给油（说明玩家想动却动不了），或者速度刚发生骤降（说明撞上了东西）。
func _check_recovery(delta: float) -> void:
	if not auto_recover or _immunity > 0.0:
		return

	# 翻车判定：车身"上方向"与世界上方夹角过大
	var up := global_transform.basis.y.normalized()
	var flipped := up.dot(Vector3.UP) < cos(deg_to_rad(flip_angle))

	var planar := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
	var was_fast := _prev_planar_speed > 5.0
	var now_stalled := planar < stuck_speed
	_prev_planar_speed = planar

	# ---- 腹部贴地滑行计时 ----
	# 四条同时成立才算：四轮全不接地、车身基本水平、贴着路面、而且还在动。
	# 用"累计时长"而不是瞬时判断：撞一下弹起一两帧不算贴地滑行。
	var gcount := grounded_wheel_count()
	var upright := up.dot(Vector3.UP) > cos(deg_to_rad(belly_upright_angle))
	var near_surface := true
	if _track != null:
		var near := _nearest_track_point()
		if not near.is_empty():
			near_surface = (global_position.y - float(near["pos"].y)) < belly_near_surface
	if gcount == 0 and upright and near_surface and planar > 2.0:
		_belly_time += delta
	else:
		_belly_time = 0.0

	# 只有"想动却动不了"才算卡住：
	#   - 玩家正在踩油门/刹车，速度却上不去；或
	#   - 上一帧还挺快，这一帧突然瘫了（撞击特征）
	var wants_to_move := _driving or _braking
	var just_crashed := was_fast and now_stalled

	if now_stalled and (wants_to_move or just_crashed):
		_stuck_time += delta
	else:
		_stuck_time = 0.0

	if global_position.y >= 3.0:
		return
	# 翻车 -> 原地扶正（保留位置和朝向），不瞬移；
	# 卡住 -> 才退回最近检查点（这是"想动却动不了"，需要换位置）
	if flipped:
		print("[车辆] 翻车，原地扶正（保留位置与朝向）")
		recover_upright()
		_stuck_time = 0.0
		_belly_time = 0.0
	elif _belly_time >= belly_slide_grace:
		# 腹部贴地滑行：扶正 + 抬起 + 清零速度 + 补一点向上速度。
		# 这一步不做的话，车会一直以几十 km/h 横向乱飘，玩家完全控制不了。
		print("[车辆] 腹部贴地滑行 %.1fs（四轮全不接地、姿态水平 y=%.2f、速度 %.1f km/h）→ 扶正并抬起"
			% [_belly_time, global_position.y, planar * 3.6])
		recover_from_belly_slide()
		_stuck_time = 0.0
	elif _stuck_time >= recover_delay:
		# 先试"楔入救援"：车头楔进墙里时，沿墙法线推出来就能继续开，
		# 不瞬移、不清速度、不打断玩家操作。
		if _try_wedge_rescue():
			_stuck_time = 0.0
			return
		print("[车辆] 想动却停住 %.1fs，回到赛道" % _stuck_time)
		if _track != null:
			reset_to_track()
		else:
			reset_to_checkpoint()
		_stuck_time = 0.0


## 楔入救援：车贴墙卡住时，**不瞬移**地把车沿墙的法线方向推出来。
##
## 为什么需要这层（实测数据）：车以浅角度贴上椭圆内凹的墙时，车头会楔进墙面约 0.2m，
## 前后受力抵消，满油门也只能把车速维持在 0.3~3 km/h —— 玩家表现为"卡墙了，只能重来"。
## 换低摩擦墙材质已经能大幅缓解，但楔入本身还需要一次"拔出来"的动作。
##
## 做法：从车中心朝**最近的一侧墙**打射线，命中方向就是墙的内法线；
## 沿它平移一小段（默认 0.8m），只清零"朝墙里"的那部分速度，保留沿墙方向的速度，
## 所以车会顺着墙滑出去继续开，而不是被重置。
func _try_wedge_rescue() -> bool:
	if _track == null:
		return false
	var near := _nearest_track_point()
	if near.is_empty():
		return false
	var arc := float(near["arc"])
	var fwd: Vector3 = near["forward"]
	var side := Vector3(fwd.z, 0.0, -fwd.x).normalized()
	var space := get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.new()
	params.collision_mask = 1
	params.exclude = [get_rid()]
	params.collide_with_areas = false
	var origin: Vector3 = global_position + Vector3.UP * 0.5
	var best_normal := Vector3.ZERO
	var best_dist := INF
	# 朝内外两侧各打一条，取更近的那面墙
	for s: float in [-1.0, 1.0]:
		params.from = origin
		params.to = origin + side * s * 8.0
		var hit := space.intersect_ray(params)
		if hit.is_empty():
			continue
		var d: float = origin.distance_to(hit["position"])
		if d < best_dist:
			best_dist = d
			# 命中面的法线取反 = 从墙指向车外的方向
			best_normal = -(hit["normal"] as Vector3)
			best_normal.y = 0.0
			if best_normal.length() < 0.01:
				best_normal = -side * s
	# 只有确实"贴着墙"才救，否则交给通用脱困
	if best_dist > wedge_rescue_distance:
		return false
	best_normal = best_normal.normalized()
	var before := global_position
	global_position = before + best_normal * wedge_rescue_push
	# 只清掉朝墙里的速度分量，保留沿墙滑行的分量
	var v := linear_velocity
	var into_wall := v.dot(-best_normal)
	if into_wall > 0.0:
		linear_velocity = v + best_normal * into_wall
	_reset_cooldown = 0.3
	print("[车辆] 楔入救援：离墙 %.2fm，沿墙法线推出 %.2fm（%s → %s），保留车速 %.1f km/h"
		% [best_dist, wedge_rescue_push, before, global_position, linear_velocity.length() * 3.6])
	return true


func _update_drive() -> void:
	# W = accelerate = +1；S = brake_reverse = -1
	var throttle := Input.get_axis("brake_reverse", "accelerate")
	# 把"倒车意图"存下来给别的模块用（见 input_brake_reverse 的说明）：
	# `throttle` 为负就是按了 S。取绝对值当强度（键盘是 0/1，手柄可能更细腻）。
	input_brake_reverse = maxf(-throttle, 0.0)
	_braking = Input.is_action_pressed("handbrake")
	_driving = absf(throttle) > 0.05 and not _braking

	# 方向说明（实测得出，与直觉相反但很重要）：
	# 本车几何上车头在本地 -Z（前翼 z=-1.66 一侧）。
	# 实测：施加**正** engine_force 会让车朝"车尾所指方向"移动，等于倒着开。
	# 因此把车头对准行驶方向后，前进要用**负**力矩，倒车用正力矩。
	# （这也是为什么 W 键会给负值 —— 看起来别扭，但是实测结果。）
	var force := 0.0
	if _driving:
		if throttle > 0.0:
			force = -max_engine_force * throttle
		elif linear_velocity.length() < 6.0:
			# 倒车：力矩更小，且要基本停稳才允许挂倒挡
			force = reverse_force * absf(throttle)

	# 限速：超过上限就断开动力。
	# 这里刻意用"速度矢量的水平模长"而不是"沿车头方向的投影" ——
	# 后者一旦车头方向判定错误就会得到负值，导致限速永远不触发
	# （我踩过这个坑：车以 198 km/h 越过 100 的限速而毫无反应）。
	if force != 0.0:
		var planar_speed := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
		if planar_speed * 3.6 > max_speed_kmh:
			force = 0.0

	for w in _drive_wheels:
		w.engine_force = force

	# 刹车：空格全轮制动；松油门时给一点发动机制动
	var b := 0.0
	if _braking:
		b = brake_force
	elif not _driving:
		b = engine_brake
	for child in get_children():
		if child is VehicleWheel3D:
			child.brake = b


func _update_steering(delta: float) -> void:
	var input := Input.get_axis("steer_right", "steer_left")   # D = -1，A = +1
	var speed := linear_velocity.length()
	# 车速越高，允许的转向角越小
	var limit := max_steer * (1.0 - clampf(speed / 40.0, 0.0, 1.0) * steer_speed_falloff)
	# 防翻车：侧倾越大，允许的方向越小；再加上横向加速度上限
	limit *= _roll_guard_factor(speed)
	_steer = move_toward(_steer, input * limit, steer_speed * delta)
	steering = _steer                                          # VehicleBody3D 总转向


## 侧倾保护系数（0~1）。
##
## 为什么需要：A/D 打太猛 → 侧倾力矩超过轮距 → 翻车（实测按住 A/D 几秒必翻）。
## 质心压低（center_of_mass_height）只解决了一半，剩下靠"快翻的时候不让你继续加大方向"。
## 两个限制取较小值：
##   - 侧倾角越接近 roll_guard_limit，权限越小（14° 开始收，34° 归零）；
##   - 横向加速度超过 max_lateral_accel 就按比例削（高速猛打方向直接压制）。
func _roll_guard_factor(speed: float) -> float:
	if speed < 0.5:
		return 1.0
	var up := global_transform.basis.y.normalized()
	var lean_deg := rad_to_deg(acos(clampf(up.dot(Vector3.UP), -1.0, 1.0)))
	if lean_deg <= roll_guard_angle:
		return 1.0
	var lean_factor := 1.0 - (lean_deg - roll_guard_angle) / maxf(roll_guard_limit - roll_guard_angle, 1.0)
	lean_factor = clampf(lean_factor, 0.0, 1.0)
	var lateral := speed * speed * tan(absf(_steer)) / maxf(_wheel_base, 0.5)
	var accel_factor := 1.0
	if lateral > max_lateral_accel:
		accel_factor = clampf(max_lateral_accel / lateral, 0.0, 1.0)
	return minf(lean_factor, accel_factor)


func _update_engine_sound(delta: float) -> void:
	if _engine_sound == null or _engine_sound.stream == null:
		return

	# 用驱动轮实际转速估算引擎转速
	var rpm := 0.0
	for w in _drive_wheels:
		rpm = maxf(rpm, absf(w.get_rpm()))

	# 轮速 -> 挡内比例，到 1 就升挡让音调回落，制造换挡顿挫感
	var raw := rpm / gear_span + 0.12                          # +0.12 保证怠速有底噪
	_gear = clampi(int(raw) + 1, 1, _gear_count)
	_rpm01 = clampf(raw - float(_gear - 1), 0.0, 1.0)

	# 给油时音调更高，松油门时沉闷
	var load_boost := 0.18 if _driving else 0.0
	var pitch := clampf(lerpf(idle_pitch, max_pitch, _rpm01) + load_boost, 0.5, 3.0)
	_engine_sound.pitch_scale = lerpf(_engine_sound.pitch_scale, pitch, 6.0 * delta)

	# 音量：**停车且没给油时彻底静音**。
	# 占位音源是合成的锯齿波，原来怠速也给 -5 dB 的底噪，听上去就是
	# "车都停下来了还在响"，很出戏。现在按"速度或油门"取较大者来定音量，
	# 两者都接近 0 就淡出到 -60 dB。
	var speed01 := clampf(linear_velocity.length() / 15.0, 0.0, 1.0)
	var gas01 := 1.0 if _driving else 0.0
	var level := maxf(speed01, gas01)
	var target_db := -60.0 if level < 0.02 else lerpf(-20.0, -6.0, level)
	_engine_sound.volume_db = lerpf(_engine_sound.volume_db, target_db, 4.0 * delta)


## 翻车或冲出赛道时按 R 复位到最近的检查点
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		request_reset()


## R 键的入口（带保护，不要直接调 reset_to_track）。
##
## 保护逻辑：车还在路面上（离中心线 < 3m）且没有翻车时，R 只做"原地扶正"，
## 不传送 —— 否则玩家想摆正车头却会被瞬移到中心线上，手感很糟。
func request_reset() -> void:
	if _reset_cooldown > 0.0:
		return
	var near := _nearest_track_point()
	var dev := float(near.get("dist", 999.0)) if not near.is_empty() else 999.0
	var flipped := _is_flipped()
	if dev < NEAR_TRACK_RESET_DIST and not flipped:
		print("[车辆] R：离中心线 %.2fm 且未翻车 → 只扶正，不传送" % dev)
		recover_upright()
		return
	print("[车辆] R：离中心线 %.2fm 翻车=%s → 复位回赛道" % [dev, flipped])
	reset_to_track()


func _is_flipped() -> bool:
	var up := global_transform.basis.y.normalized()
	return up.dot(Vector3.UP) < cos(deg_to_rad(flip_angle))


## 复位回赛道：落点取"离我最近的中心线点"，姿态对齐该点切线，速度清零。
##
## 为什么不复用 reset_to_checkpoint：检查点是**门**，按直线距离找最近的门在外侧
## 场地上会选错；而且门的朝向只保证横跨路面，落点不保证在赛道内侧。
## 中心线查询是几何上唯一正确的答案，任何位置都能算。
func reset_to_track() -> void:
	var near := _nearest_track_point()
	if near.is_empty():
		# 赛道数据源不可用时的退路：老逻辑
		reset_to_checkpoint()
		return
	var target: Vector3 = near["pos"]
	var fwd: Vector3 = near["forward"]
	# 诊断上下文：出问题时用这些数字判断是谁触发的、当时车在哪
	var from := global_position
	var dev_before := float(near["dist"])
	var speed_before := linear_velocity.length() * 3.6
	var driving_before := _driving
	_arc_hint = float(near["arc"])
	_prev_line_signed = -1.0
	global_transform.basis = Basis.looking_at(fwd, Vector3.UP)
	global_position = target + Vector3.UP * 0.8
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	steering = 0.0
	_steer = 0.0
	_stuck_time = 0.0
	_out_time = 0.0
	_reset_cooldown = 0.5
	# 瞬移隔离：复位后短时间内、且没跑够距离，不认压线（防止"复位白送一圈"）
	_reset_isolate_until_ms = Time.get_ticks_msec() + 6000
	_reset_isolate_from = global_position
	_grant_immunity()
	# 复位死循环检测：如果 3 秒内又回到同一个地方复位，说明判定条件本身有问题。
	# 这种情况一定要吼出来，不能静默地一直重置 —— 用户看到的就是"循环刷新"。
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_reset_ms < 3000.0 and global_position.distance_to(_last_reset_pos) < 8.0:
		_reset_loop_count += 1
		push_warning("[车辆] 疑似复位死循环：第 %d 次在 %s 附近重复复位（距上次 %.1fs）。"
			% [_reset_loop_count, global_position, (now_ms - _last_reset_ms) / 1000.0]
			+ "请检查出界判定阈值与自动脱困条件。")
		print("[车辆] ⚠ 复位死循环第 %d 次 @ %s（上次复位点 %s）"
			% [_reset_loop_count, global_position, _last_reset_pos])
		# 连撞 3 次就**停掉兜底**，绝不允许无限循环刷屏、把玩家钉在原地。
		# 宁可这次不兜底（玩家还能自己开），也不要"循环重置回不了起点"。
		if _reset_loop_count >= 3:
			auto_reset_out_of_bounds = false
			auto_recover = false
			print("[车辆] ⚠⚠ 已自动停用「出界兜底」与「自动脱困」：判定条件疑似误伤。"
				+ "请把这次日志里的偏离距离/阈值发出来。")
	else:
		_reset_loop_count = 0
	_last_reset_ms = now_ms
	_last_reset_pos = global_position
	print("[车辆] 已复位到赛道：弧长 %.1fm 落点=%s（复位前 pos=%s 偏离 %.2fm 速度=%.1fkm/h 在给油=%s）"
		% [float(near["arc"]), global_position, from, dev_before, speed_before, str(driving_before)])


## 复位后的短暂无敌：不与其它车辆碰撞，也不触发检查点/计圈，
## 避免刚回到赛道上就被后车顶飞、或被判定成压线刷圈。
func _grant_immunity() -> void:
	_immunity = reset_immunity_time
	_set_ghost(true)
	print("[车辆] 复位无敌 %.1fs（忽略与车辆的碰撞、不触发检查点）" % reset_immunity_time)


func _set_ghost(on: bool) -> void:
	set_collision_mask_value(VEHICLE_LAYER, not on)


## 复位无敌期间为 true。检查点用它来跳过触发（见 checkpoint.gd）。
func is_reset_immune() -> bool:
	return _immunity > 0.0


## 出界兜底：车跑到围墙通道之外就自动拉回赛道。
##
## 判定基线 = 护栏中心线 + 车身半宽 + 余量（约 8.2+1.0+4.0 = 13.2m），**与速度无关**。
## 为什么不按速度收紧（我踩过的坑）：收紧到接近护栏位置时，正常贴墙行驶就会被
## 误判成出界，然后"复位→又贴墙→再复位"死循环。
## 余量给到 4m 也是被实测逼出来的：车被挤进墙里时中心能到 12.1m，2m 余量照样误报。
## 通道封闭的前提下界的可达上限就是"护栏 + 车半宽"，13.2m 之后一定是真出事了。
func _check_out_of_bounds(delta: float) -> void:
	if not auto_reset_out_of_bounds or _track == null or _reset_cooldown > 0.0:
		return
	var near := _nearest_track_point()
	if near.is_empty():
		return
	_arc_hint = float(near["arc"])
	var dev := float(near["dist"])
	var speed := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
	var limit := _rail_half_width() + body_half_width + out_of_bounds_margin
	if dev > limit:
		_out_time += delta
		if _out_time >= out_of_bounds_delay:
			print("[车辆] 出界兜底触发：偏离 %.2fm > 允许 %.2fm，速度 %.1f m/s（%.0f km/h），位置 %s，持续 %.2fs"
				% [dev, limit, speed, speed * 3.6, global_position, _out_time])
			reset_to_track()
	else:
		_out_time = 0.0


func reset_to_checkpoint() -> void:
	var best: Node3D = null
	var best_d := INF
	for node in get_tree().get_nodes_in_group("checkpoints"):
		var cp := node as Node3D
		if cp == null:
			continue
		var d := global_position.distance_to(cp.global_position)
		if d < best_d:
			best_d = d
			best = cp
	if best == null:
		return
	# 复位到检查点上方一点，姿态对齐检查点朝向。
	# 注意要 +PI：赛道的检查点门是让**本地 +Z** 朝赛道前进方向（见 track_generator
	# 的 Basis(Vector3.UP, atan2(fwd.x, fwd.z))），而本车车头在**本地 -Z** ——
	# 直接照抄门的朝向，车会倒着落在赛道上。
	global_position = best.global_position + Vector3.UP * 0.8
	global_transform.basis = Basis(Vector3.UP, best.global_rotation.y + PI)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


## 原地扶正：把车身摆回水平、**保留当前位置**，清零速度。
##
## 为什么不瞬移到检查点：玩家在起跑区翻车时，"最近的检查点"就是起终点线，
## 表现成"翻个车就被扔回起点"，非常打断手感。扶正只付出一点时间代价。
func recover_upright() -> void:
	# 车头在车体本地 -Z，把它投影到水平面，作为扶正后的朝向
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	# Basis.looking_at 生成的基：-Z 指向目标方向、+Y 朝上，正合本车约定
	global_transform.basis = Basis.looking_at(fwd.normalized(), Vector3.UP)
	global_position += Vector3.UP * 0.3    # 抬离地面一点，免得扶正瞬间卡进路面
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


## 从"腹部贴地滑行"状态扶起来：扶正 + 抬到 belly_lift 高度 + 清零速度 + 补向上速度。
##
## 为什么必须补一点向上速度：只把位置抬高、速度清零的话，车仍然处于"贴着地面"的
## 接触状态，下一个物理帧立刻重新贴回去 —— 表现就是"扶了跟没扶一样"。
## 给一个明确向上的 Δv 才能让它真正离开地面、落回四个轮子。
##
## ⚠ 冲量的单位：apply_central_impulse 收 N·s，所以要乘 mass 才能得到想要的速度增量。
func recover_from_belly_slide() -> void:
	recover_upright()                       # 扶正 + 抬 0.3m + 清零线速度与角速度
	global_position += Vector3.UP * maxf(belly_lift - 0.3, 0.0)
	apply_central_impulse(Vector3.UP * belly_impulse_dv * mass)
	belly_recovery_count += 1
	_belly_time = 0.0
