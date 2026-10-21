extends VehicleBody3D
## 迁移的说明性注释原文见 vehicle-notes.md；控制实现仍只在本文件。
## 只读取证回执：发送原读取点的局部值，不替换 Input，不参与控制计算。
signal evidence_input_read(kind: String, frame: int, values: Dictionary)

const RacingLine := preload("res://scripts/racing_line.gd")
const WheelVisuals := preload("res://scripts/vehicle_wheel_visuals.gd")

@export_group("动力")
@export var max_engine_force := 4000.0
@export var reverse_force := 1800.0
@export var engine_brake := 2.5
@export var max_speed_kmh := 100.0

@export_group("转向")
@export var max_steer := RacingLine.STEER_MAX
@export var steer_speed := 4.0
@export var steer_speed_falloff := RacingLine.STEER_FALLOFF
@export var roll_guard_angle := 14.0
@export var roll_guard_limit := 34.0
@export var max_lateral_accel := 16.0

@export_group("制动")
@export var brake_force := 30.0

@export_group("音效")
@export var idle_pitch := 0.75
@export var max_pitch := 2.4
@export var gear_span := 1400.0

@export_group("脱困")
@export var auto_recover := true
@export var stuck_speed := 1.0
@export var recover_delay := 4.0
@export var wedge_rescue_distance := 1.2
@export var wedge_rescue_push := 0.8
@export var flip_angle := 70.0
@export var belly_slide_grace := 1.5
@export var belly_upright_angle := 25.0
@export var belly_near_surface := 1.5
@export var belly_lift := 0.45
@export var belly_impulse_dv := 0.5

@export_group("稳定性")
@export var center_of_mass_height := 0.2

@export_group("出界兜底")
@export var auto_reset_out_of_bounds := true
@export var out_of_bounds_margin := 4.0
@export var body_half_width := 1.0
@export var out_of_bounds_delay := 0.5
@export var lap_min_distance_after_reset := 100.0
@export var reset_immunity_time := 2.0

@export_group("车轮动画")
@export var spin_wheel_meshes := true

var _steer := 0.0                 # 平滑后的转向角
var _wheel_base := 2.1            # 轴距，_ready 里实测
var _driving := false
var _braking := false
var input_brake_reverse := 0.0
var start_locked := false
var _gear := 1
var _gear_count := 5
var _rpm01 := 0.0                 # 0~1 的挡内转速比例
var _stuck_time := 0.0
var _prev_planar_speed := 0.0      # 上一帧水平速度，用于识别"撞上东西"的速度骤降
var _belly_time := 0.0
var belly_recovery_count := 0
var belly_test_hover := false
var _gravity_scale_normal := -1.0
var steer_fixture_active := false
var steer_fixture_angle := 0.0

var _track: Node3D = null
var obstacle_field: Node3D = null
var _wrong_way_mod: GDScript = null

var wrong_way := false
var wrong_way_reason := ""
var _reverse_speed_kmh := 15.0
var _reverse_enter_deg := 120.0
var _reverse_exit_deg := 105.0
var _arc_hint := -1.0
var _out_time := 0.0
var _immunity := 0.0
var _last_checkpoint_order := -1
var _reset_cooldown := 0.0
var _reset_isolate_until_ms := 0.0
var _reset_isolate_from := Vector3.ZERO
var _last_reset_ms := 0.0
var _last_reset_pos := Vector3.ZERO
var _reset_loop_count := 0

var _lap_armed := true
var _prev_line_signed := -1.0
var _lap_running := false
var _lap_start_ms := 0.0
var _lap_suppressed := true
var lap_last := 0.0
var lap_best := 0.0
var laps_done := 0
var laps_target := 0
var start_line_crossed := false   # 已压过起点线。GO 锚定圈钟后首发压线只标记不完圈；
                                  # race_position.gd 进度公式读它 —— 勿改语义。
var tuned_max_speed := 0.0

signal lap_completed(last_lap: float, best_lap: float)

const CORNER_SCALES := [
	Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
	Vector3(1, 1, 0), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1),
]

const VEHICLE_LAYER := 2
const NEAR_TRACK_RESET_DIST := 3.0
const RESET_LANE_HORIZON := 45.0
const RESET_LANE_LOOKBACK := 4.0

var _steer_wheels: Array[VehicleWheel3D] = []
var _drive_wheels: Array[VehicleWheel3D] = []
var _wheel_visuals: Array = []

@onready var _engine_sound: AudioStreamPlayer3D = $EngineSound


func _ready() -> void:
	_gravity_scale_normal = gravity_scale
	_apply_center_of_mass()
	classify_wheels()
	_measure_wheel_base()
	_find_track()
	_deferred_setup()


func _deferred_setup() -> void:
	if _track != null and _track.has_method("await_world_ready"):
		await _track.call("await_world_ready")
	_place_on_start_line()
	_bind_wheel_visuals()
	if _engine_sound and _engine_sound.stream:
		_engine_sound.play()
	if _track != null:
		var near := _nearest_track_point()
		if not near.is_empty():
			_arc_hint = float(near["arc"])
	_reset_lap_state()
	print("[车辆] 赛道就绪后初始化完成：出生点 %s" % global_position)


func _reset_lap_state() -> void:
	_lap_running = false
	_lap_armed = true
	_prev_line_signed = -1.0      # 强制下一次判定为"在线后"
	_lap_suppressed = true
	start_line_crossed = false
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
	_release_lap_suppression()


func _release_lap_suppression() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	_lap_suppressed = false
	_lap_running = false
	_lap_armed = true
	_lap_start_ms = Time.get_ticks_msec() / 1000.0
	_prev_line_signed = -1.0
	start_line_crossed = false
	print("[计圈] 计圈已就绪（互动路径圈钟由「出发！」锚定；自动化路径首次压线起表）")


func _find_track() -> void:
	var p := get_parent()
	if p != null:
		_track = p.get_node_or_null("Track") as Node3D
	if _track != null:
		print("[车辆] 已接上赛道数据源，出界兜底/中心线复位可用")
	_wrong_way_mod = load("res://scripts/track_layout.gd")
	if _wrong_way_mod == null or not _wrong_way_mod.has_method("wrong_way_state"):
		_wrong_way_mod = null
		push_warning("[车辆] track_layout.gd 不可用 → 「方向反了」提示停用（不影响驾驶）")
	else:
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
			var m: GDScript = _wrong_way_mod
			_reverse_speed_kmh = float(m.get("REVERSE_SPEED_KMH"))
			_reverse_enter_deg = float(m.get("REVERSE_ANGLE_ENTER_DEG"))
			_reverse_exit_deg = float(m.get("REVERSE_ANGLE_EXIT_DEG"))
			print("[车辆] 没读到 LevelConfig → 「方向反了」用默认门限：%.0f km/h / %.0f° / %.0f°"
				% [_reverse_speed_kmh, _reverse_enter_deg, _reverse_exit_deg])


func _nearest_track_point() -> Dictionary:
	if _track == null or not _track.has_method("nearest_on_centerline"):
		return {}
	return _track.call("nearest_on_centerline", global_position, _arc_hint)


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
	var nose := -global_transform.basis.z
	nose.y = 0.0
	var dot := 0.0
	if fwd.length() > 0.001 and nose.length() > 0.001:
		dot = nose.normalized().dot(fwd.normalized())
	var reversing := input_brake_reverse > 0.5
	var d: Dictionary = _wrong_way_mod.call("wrong_way_state", wrong_way, dot, speed * 3.6,
		reversing, _reverse_enter_deg, _reverse_exit_deg, _reverse_speed_kmh)
	wrong_way = bool(d.get("wrong_way", false))
	wrong_way_reason = str(d.get("reason", ""))


func _rail_half_width() -> float:
	if _track != null and _track.has_method("rail_half_width"):
		return float(_track.call("rail_half_width"))
	return 8.2


func _road_half_width() -> float:
	if _track != null and _track.has_method("road_half_width"):
		return float(_track.call("road_half_width"))
	return 7.0


func _apply_center_of_mass() -> void:
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, center_of_mass_height, 0.0)
	print("[车辆] 质心已设为 y=%.2f（AUTO 默认约 0.55，会侧翻）" % center_of_mass_height)


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

	var half_length := _measure_nose_to_center()
	var clearance := 0.08       # 只留一点点余量，让车头紧贴线后沿（标准起跑位）
	var back := line_depth * 0.5 + half_length + clearance

	var target: Vector3 = (line_center as Vector3) - fwd * back
	global_position = Vector3(target.x, global_position.y, target.z)

	rotation.y = atan2(fwd.x, fwd.z) + PI

	print("[车辆] 出生点已按白线计算：线中心 z=%.2f，线厚 %.2f，车长 %.2f"
		% [(line_center as Vector3).z, line_depth, half_length * 2.0])
	print("[车辆] 沿赛道后退 %.2f m  →  出生位置 %s  （车头朝向赛道方向）"
		% [back, global_position])


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
	return _measure_body_length() * 0.5


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


func _bind_wheel_visuals() -> void:
	WheelVisuals.bind(self, _wheel_visuals, spin_wheel_meshes)


func _update_wheel_visuals(delta: float) -> void:
	WheelVisuals.update(self, _wheel_visuals, delta)


func _physics_process(delta: float) -> void:
	if belly_test_hover:
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
	var lateral := (p - fwd * s).length()
	if lateral > _rail_half_width() * 2.0:
		_prev_line_signed = s
		return
	if _lap_armed and _prev_line_signed < 0.0 and s >= 0.0:
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
		# 自动化路径（--check / --shot，无「出发！」事件）：首发压线即起表 ——
		# 旧口径原样保留，lap/stress 等既有圈速证据零变化。
		_lap_running = true
		_lap_start_ms = now
		start_line_crossed = true
		print("[计圈] 开始计时（第一次压线）pos=%s 速度=%.1f km/h"
			% [global_position, linear_velocity.length() * 3.6])
		return
	if not start_line_crossed:
		# 互动路径：圈钟已由 begin_lap_timing() 在 GO 锚定 → 首发压线只标记，
		# 不完圈、不重新起表（首圈含起跑段，R6 修订 D1）。
		start_line_crossed = true
		print("[计圈] 首发压线已标记（圈速自「出发！」起算，含起跑段）pos=%s 速度=%.1f km/h"
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


signal race_finished(total_laps: int)


func apply_level_setup(speed_kmh: float, laps: int, friction_mult: float) -> void:
	if speed_kmh > 1.0:
		max_speed_kmh = speed_kmh
		tuned_max_speed = speed_kmh
	laps_target = laps
	_apply_friction(friction_mult)
	print("[车辆] 关卡设置：极速上限 %.0f km/h，目标 %d 圈，抓地力 ×%.2f"
		% [max_speed_kmh, laps, friction_mult])


func _apply_friction(mult: float) -> void:
	for child in get_children():
		if child is VehicleWheel3D:
			var w: VehicleWheel3D = child
			if not _wheel_friction_base.has(w):
				_wheel_friction_base[w] = w.wheel_friction_slip
			w.wheel_friction_slip = float(_wheel_friction_base[w]) * clampf(mult, 0.2, 2.0)


var _wheel_friction_base := {}


func current_lap_time() -> float:
	if not _lap_running:
		return 0.0
	return Time.get_ticks_msec() / 1000.0 - _lap_start_ms


## 由 main 唯一发车回调 _on_race_go() 调用（仅互动路径）：圈钟与总时间同一时刻起算。
## R6 修订（2026-10-19 用户拍板 D1）：本圈也从「出发！」起算、首圈含起跑爬行，
## 于是 总时间 ≡ 各圈之和，「起步」段恒为 0。go_ms 传 GameState.race_start_ms。
## 幂等：_lap_running 已为真直接返回（重复 GO 不重新起表）。
func begin_lap_timing(go_ms := -1) -> void:
	if _lap_running:
		return
	_lap_running = true
	_lap_start_ms = (go_ms / 1000.0) if go_ms > 0.0 else (Time.get_ticks_msec() / 1000.0)
	print("[计圈] 圈钟已由「出发！」锚定（首圈含起跑段，与总时间同原点）")


func grounded_wheel_count() -> int:
	var n := 0
	for child in get_children():
		if child is VehicleWheel3D and (child as VehicleWheel3D).is_in_contact():
			n += 1
	return n


func _check_recovery(delta: float) -> void:
	if not auto_recover or _immunity > 0.0:
		return

	var up := global_transform.basis.y.normalized()
	var flipped := up.dot(Vector3.UP) < cos(deg_to_rad(flip_angle))

	var planar := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
	var was_fast := _prev_planar_speed > 5.0
	var now_stalled := planar < stuck_speed
	_prev_planar_speed = planar

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

	var wants_to_move := _driving or _braking
	var just_crashed := was_fast and now_stalled

	if now_stalled and (wants_to_move or just_crashed):
		_stuck_time += delta
	else:
		_stuck_time = 0.0

	if global_position.y >= 3.0:
		return
	if flipped:
		print("[车辆] 翻车，原地扶正（保留位置与朝向）")
		recover_upright()
		_stuck_time = 0.0
		_belly_time = 0.0
	elif _belly_time >= belly_slide_grace:
		print("[车辆] 腹部贴地滑行 %.1fs（四轮全不接地、姿态水平 y=%.2f、速度 %.1f km/h）→ 扶正并抬起"
			% [_belly_time, global_position.y, planar * 3.6])
		recover_from_belly_slide()
		_stuck_time = 0.0
	elif _stuck_time >= recover_delay:
		if _try_wedge_rescue():
			_stuck_time = 0.0
			return
		print("[车辆] 想动却停住 %.1fs，回到赛道" % _stuck_time)
		if _track != null:
			reset_to_track()
		else:
			reset_to_checkpoint()
		_stuck_time = 0.0


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
	for s: float in [-1.0, 1.0]:
		params.from = origin
		params.to = origin + side * s * 8.0
		var hit := space.intersect_ray(params)
		if hit.is_empty():
			continue
		var d: float = origin.distance_to(hit["position"])
		if d < best_dist:
			best_dist = d
			best_normal = -(hit["normal"] as Vector3)
			best_normal.y = 0.0
			if best_normal.length() < 0.01:
				best_normal = -side * s
	if best_dist > wedge_rescue_distance:
		return false
	best_normal = best_normal.normalized()
	var before := global_position
	global_position = before + best_normal * wedge_rescue_push
	var v := linear_velocity
	var into_wall := v.dot(-best_normal)
	if into_wall > 0.0:
		linear_velocity = v + best_normal * into_wall
	_reset_cooldown = 0.3
	_debug_rec("wedge_rescue_ok")
	print("[车辆] 楔入救援：离墙 %.2fm，沿墙法线推出 %.2fm（%s → %s），保留车速 %.1f km/h"
		% [best_dist, wedge_rescue_push, before, global_position, linear_velocity.length() * 3.6])
	return true


func _update_drive() -> void:
	if start_locked:
		return
	var throttle := Input.get_axis("brake_reverse", "accelerate")
	input_brake_reverse = maxf(-throttle, 0.0)
	_braking = Input.is_action_pressed("handbrake")
	evidence_input_read.emit("drive", Engine.get_physics_frames(), {"throttle": throttle, "handbrake": _braking})
	_driving = absf(throttle) > 0.05 and not _braking

	var force := 0.0
	if _driving:
		if throttle > 0.0:
			force = -max_engine_force * throttle
		elif linear_velocity.length() < 6.0:
			force = reverse_force * absf(throttle)

	if force != 0.0:
		var planar_speed := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
		if planar_speed * 3.6 > max_speed_kmh:
			force = 0.0

	for w in _drive_wheels:
		w.engine_force = force

	var b := 0.0
	if _braking:
		b = brake_force
	elif not _driving:
		b = engine_brake
	for child in get_children():
		if child is VehicleWheel3D:
			child.brake = b


func _update_steering(delta: float) -> void:
	if start_locked:
		return
	if steer_fixture_active:
		_steer = steer_fixture_angle
		steering = _steer
		return
	var input := Input.get_axis("steer_right", "steer_left")   # D = -1，A = +1
	evidence_input_read.emit("steering", Engine.get_physics_frames(), {"steering": input})
	var speed := linear_velocity.length()
	var limit := RacingLine.steer_limit(speed, max_steer, steer_speed_falloff)
	limit *= _roll_guard_factor(speed)
	_steer = move_toward(_steer, input * limit, steer_speed * delta)
	steering = _steer                                          # VehicleBody3D 总转向


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

	var rpm := 0.0
	for w in _drive_wheels:
		rpm = maxf(rpm, absf(w.get_rpm()))

	var raw := rpm / gear_span + 0.12                          # +0.12 保证怠速有底噪
	_gear = clampi(int(raw) + 1, 1, _gear_count)
	_rpm01 = clampf(raw - float(_gear - 1), 0.0, 1.0)

	var load_boost := 0.18 if _driving else 0.0
	var pitch := clampf(lerpf(idle_pitch, max_pitch, _rpm01) + load_boost, 0.5, 3.0)
	_engine_sound.pitch_scale = lerpf(_engine_sound.pitch_scale, pitch, 6.0 * delta)

	var speed01 := clampf(linear_velocity.length() / 15.0, 0.0, 1.0)
	var gas01 := 1.0 if _driving else 0.0
	var level := maxf(speed01, gas01)
	var target_db := -60.0 if level < 0.02 else lerpf(-20.0, -6.0, level)
	_engine_sound.volume_db = lerpf(_engine_sound.volume_db, target_db, 4.0 * delta)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		request_reset()


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


func _clear_reset_lane(arc: float) -> float:
	return _reset_lane_at(arc, RESET_LANE_LOOKBACK)


func _reset_lane_at(arc: float, lookback: float) -> float:
	if obstacle_field == null or not obstacle_field.has_method("pick_clear_lane"):
		return 0.0
	if _track == null or not _track.has_method("road_half_width"):
		return 0.0
	var road_half := float(_track.call("road_half_width"))
	var car_half := maxf(body_half_width, 0.875)
	var lane_limit := maxf(0.0, road_half - car_half - 0.2)
	var res: Dictionary = obstacle_field.call("pick_clear_lane",
		0.0, arc - lookback, RESET_LANE_HORIZON + lookback, car_half, lane_limit)
	if not bool(res.get("found", false)):
		return 0.0
	return float(res.get("lane", 0.0))


func _debug_rec(action: String) -> void:
	evidence_input_read.emit("recovery", Engine.get_physics_frames(), {"action": action, "position": str(global_position)})
	var near := _nearest_track_point()
	var arc := float(near["arc"]) if not near.is_empty() else -1.0
	print("[DEBUG-L4] REC f=%d owner=vehicle action=%s pos=%s arc=%.1f v=%.2f grounded=%d/4"
		% [Engine.get_physics_frames(), action, str(global_position), arc,
		   linear_velocity.length(), grounded_wheel_count()])


func _debug_reset_target_report(near: Dictionary, fwd: Vector3, lane_new: float) -> void:
	var arc := float(near["arc"])
	var base: Vector3 = near["pos"]
	var f := Vector3(fwd.x, 0.0, fwd.z)
	if f.length() < 0.001:
		f = Vector3.FORWARD
	f = f.normalized()
	var side := Vector3(f.z, 0.0, -f.x)
	var lane_old := _reset_lane_at(arc, 0.0)
	var pos_new := base + side * lane_new
	var pos_old := base + side * lane_old
	var cn := debug_reset_target(pos_new, fwd)
	var co := debug_reset_target(pos_old, fwd)
	print("[DEBUG-L4] RESET_TARGET f=%d arc=%.1f lane_new=%+.2f lane_old=%+.2f lookback=%.2f "
		% [Engine.get_physics_frames(), arc, lane_new, lane_old, RESET_LANE_LOOKBACK]
		+ "new_safe=%s new_who=%s new_n=%d | old_safe=%s old_who=%s old_n=%d"
		% [str(not bool(cn["hit"])), str(cn["who"]), int(cn["n"]),
		   str(not bool(co["hit"])), str(co["who"]), int(co["n"])])


func _body_length_debug() -> float:
	var body := get_node_or_null("BodyCollision") as CollisionShape3D
	if body != null and body.shape is BoxShape3D:
		return (body.shape as BoxShape3D).size.z
	return 3.74


func debug_reset_target(pos: Vector3, fwd: Vector3) -> Dictionary:
	var body := get_node_or_null("BodyCollision") as CollisionShape3D
	if body == null:
		return {"hit": false, "who": "无 BodyCollision", "n": 0}
	var bshape := body.shape
	if bshape == null:
		return {"hit": false, "who": "无 shape", "n": 0}
	var f := Vector3(fwd.x, 0.0, fwd.z)
	if f.length() < 0.001:
		f = Vector3.FORWARD
	f = f.normalized()
	var bt := Transform3D(Basis.looking_at(f, Vector3.UP), pos) * body.transform
	var pq := PhysicsShapeQueryParameters3D.new()
	pq.shape = bshape
	pq.transform = bt
	pq.collision_mask = 1
	pq.collide_with_bodies = true
	pq.collide_with_areas = false
	pq.exclude = [get_rid()]
	var hits: Array = []
	var space := get_world_3d().direct_space_state
	if space != null:
		hits = space.intersect_shape(pq, 8)
	var who := "—"
	if not hits.is_empty():
		var c = hits[0].get("collider")
		who = ("%s" % (c.name if c != null else "?"))
	return {"hit": not hits.is_empty(), "who": who, "n": hits.size()}


func reset_to_track() -> void:
	_debug_rec("reset_to_track")
	var near := _nearest_track_point()
	if near.is_empty():
		reset_to_checkpoint()
		return
	var target: Vector3 = near["pos"]
	var fwd: Vector3 = near["forward"]
	var lane := _clear_reset_lane(float(near["arc"]))
	if absf(lane) > 0.001:
		var f := Vector3(fwd.x, 0.0, fwd.z)
		if f.length() > 0.001:
			f = f.normalized()
			target += Vector3(f.z, 0.0, -f.x) * lane
	_debug_reset_target_report(near, fwd, lane)
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
	_reset_isolate_until_ms = Time.get_ticks_msec() + 6000
	_reset_isolate_from = global_position
	_grant_immunity()
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_reset_ms < 3000.0 and global_position.distance_to(_last_reset_pos) < 8.0:
		_reset_loop_count += 1
		push_warning("[车辆] 疑似复位死循环：第 %d 次在 %s 附近重复复位（距上次 %.1fs）。"
			% [_reset_loop_count, global_position, (now_ms - _last_reset_ms) / 1000.0]
			+ "请检查出界判定阈值与自动脱困条件。")
		print("[车辆] ⚠ 复位死循环第 %d 次 @ %s（上次复位点 %s）"
			% [_reset_loop_count, global_position, _last_reset_pos])
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


func _grant_immunity() -> void:
	_immunity = reset_immunity_time
	_set_ghost(true)
	print("[车辆] 复位无敌 %.1fs（忽略与车辆的碰撞、不触发检查点）" % reset_immunity_time)


func _set_ghost(on: bool) -> void:
	set_collision_mask_value(VEHICLE_LAYER, not on)


func is_reset_immune() -> bool:
	return _immunity > 0.0


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
	_debug_rec("reset_to_checkpoint")
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
	global_position = best.global_position + Vector3.UP * 0.8
	global_transform.basis = Basis(Vector3.UP, best.global_rotation.y + PI)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func recover_upright() -> void:
	_debug_rec("recover_upright")
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	global_transform.basis = Basis.looking_at(fwd.normalized(), Vector3.UP)
	global_position += Vector3.UP * 0.3    # 抬离地面一点，免得扶正瞬间卡进路面
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func recover_from_belly_slide() -> void:
	_debug_rec("recover_from_belly_slide")
	recover_upright()                       # 扶正 + 抬 0.3m + 清零线速度与角速度
	global_position += Vector3.UP * maxf(belly_lift - 0.3, 0.0)
	apply_central_impulse(Vector3.UP * belly_impulse_dv * mass)
	belly_recovery_count += 1
	_belly_time = 0.0
