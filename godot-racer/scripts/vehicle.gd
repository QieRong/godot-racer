extends VehicleBody3D
signal trajectory_discontinuity
var finish_input_locked := false:
	set(value):
		finish_input_locked = value
		if value:
			_driving = false
			_clear_drift()
var input_prefix := ""
## 联机席位与输入源只改变指令来源，复用原有车辆物理公式。
var network_slot := -1
var network_finish_time := 0.0
var network_replicated := false
var network_predicted := false
signal prediction_corrected(offset: Vector3, rotation: Quaternion, velocity: Vector3, angular: Vector3)
var _network_correction: Dictionary = {}
var external_input_enabled := false
var _external_input := {"throttle":0.0,"steering":0.0,"handbrake":false,"drift":false}
@export var appearance: Resource = preload("res://data/car_appearance.tres")
## 迁移的说明性注释原文见 vehicle-notes.md；控制实现仍只在本文件。
## 只读取证回执：发送原读取点的局部值，不替换 Input，不参与控制计算。
signal evidence_input_read(kind: String, frame: int, values: Dictionary)

const RacingLine := preload("res://scripts/racing_line.gd")
const WheelVisuals := preload("res://scripts/vehicle_wheel_visuals.gd")
const EngineAudio := preload("res://scripts/engine_audio.gd")
const VehicleDrive := preload("res://scripts/vehicle_drive.gd")
const RaceLaps := preload("res://scripts/race_laps.gd")
var _safe_reset := preload("res://scripts/vehicle_safe_reset.gd").new()
var _steering_stability := preload("res://scripts/vehicle_steering_stability.gd").new()

@export_group("动力")
@export var max_engine_force := 4000.0
@export var reverse_force := 1800.0
@export var engine_brake := 2.5
@export var max_speed_kmh := 100.0

@export_group("转向")
@export var max_steer := RacingLine.STEER_MAX
@export var steer_speed := 6.0
@export var steer_return_speed := 8.0
@export var steering_stability_enabled := true
@export var steer_speed_falloff := RacingLine.STEER_FALLOFF
@export var roll_guard_angle := 14.0
@export var roll_guard_limit := 34.0
@export var max_lateral_accel := RacingLine.GRIP_BASE

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
var _steering_grip := 1.0
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

var _race_laps := RaceLaps.new()
var _reverse_line_crossings: int:
	get: return _race_laps._reverse_crossings
	set(value): _race_laps._reverse_crossings = value
var _lap_armed: bool:
	get: return _race_laps._armed
	set(value): _race_laps._armed = value
var _prev_line_signed: float:
	get: return _race_laps._previous_side
	set(value): _race_laps._previous_side = value
var _lap_running: bool:
	get: return _race_laps.running
	set(value): _race_laps.running = value
var _lap_start_ms: float:
	get: return _race_laps.lap_start_ms / 1000.0
	set(value): _race_laps.lap_start_ms = roundi(value * 1000.0)
var _lap_suppressed := true
var lap_last: float:
	get: return _race_laps.last
	set(value): _race_laps.last = value
var lap_best: float:
	get: return _race_laps.best
	set(value): _race_laps.best = value
var lap_times: Array[float]:
	get: return _race_laps.times
var laps_done: int:
	get: return _race_laps.laps
	set(value): _race_laps.laps = value
var laps_target := 0
var start_line_crossed: bool:
	get: return _race_laps.started
	set(value): _race_laps.started = value
var tuned_max_speed := 0.0

signal lap_completed(last_lap: float, best_lap: float)
signal start_positioned
var start_position_ready := false

const CORNER_SCALES := [
	Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
	Vector3(1, 1, 0), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1),
]

const DRIFT_ENTRY_SPEED_KMH := 55.0
const DRIFT_EXIT_SPEED_KMH := 40.0
const DRIFT_REAR_GRIP := 0.60
const DRIFT_SUPPORTED_GRIP := 0.90
const DRIFT_GRIP_RATE := 3.5

const VEHICLE_LAYER := 2
const NEAR_TRACK_RESET_DIST := 3.0
const RESET_LANE_HORIZON := 45.0
const RESET_LANE_LOOKBACK := 4.0

var _steer_wheels: Array[VehicleWheel3D] = []
var _drive_wheels: Array[VehicleWheel3D] = []
var _all_wheels: Array[VehicleWheel3D] = []
var _wheel_visuals: Array = []
var _drifting := false
var _drift_grip := 1.0

@onready var _engine_sound: AudioStreamPlayer3D = $EngineSound


func _ready() -> void:
	appearance.apply_to_vehicle(self)
	_gravity_scale_normal = gravity_scale
	_apply_center_of_mass()
	classify_wheels()
	GameState.drive_input_released.connect(_clear_drift)
	trajectory_discontinuity.connect(_clear_drift)
	_apply_friction(1.0)
	_measure_wheel_base()
	_find_track()
	_deferred_setup()


func _deferred_setup() -> void:
	if _track != null and _track.has_method("await_world_ready"):
		await _track.call("await_world_ready")
		if not _track.call("is_world_ready"):
			return # 赛道失败时不摆车、不启动圈钟或恢复协程；main负责错误提示。
	_place_on_start_line()
	_bind_wheel_visuals()
	if _engine_sound and _engine_sound.stream:
		_engine_sound.volume_db = -80.0
		_engine_sound.play()
		_engine_sound.stream_paused = GameState.phase_name() in ["MENU", "LOADING", "INTRO"]
	if _track != null:
		var near := _nearest_track_point()
		if not near.is_empty():
			_arc_hint = float(near["arc"])
	_reset_lap_state()
	_safe_reset.seed(self, _track)
	start_position_ready = true
	start_positioned.emit()
	print("[车辆] 赛道就绪后初始化完成：出生点 %s" % global_position)


func _reset_lap_state() -> void:
	_race_laps = RaceLaps.new()
	_lap_suppressed = true
	if _track == null:
		return
	_race_laps.configure(_track, _rail_half_width() * 2.0)
	_race_laps.rebase(global_position)
	_release_lap_suppression()


func _release_lap_suppression() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	_lap_suppressed = false
	_lap_running = false
	_lap_armed = true
	_lap_start_ms = GameState.race_clock_ms() / 1000.0
	_race_laps.mark_behind()
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
	if network_slot in [0, 1]:
		target += Vector3(fwd.z, 0.0, -fwd.x) * track.road_half_width() / 3.0 * (1.0 if network_slot == 1 else -1.0)
	elif GameState.split_screen:
		target += Vector3(fwd.z, 0.0, -fwd.x) * track.road_half_width() / 3.0 * (1.0 if input_prefix == "p2_" else -1.0)
	elif GameState.effective_ai_count() > 0:
		# 单对手：左边界—玩家—AI—右边界三段等距。无AI则保持居中。
		target -= Vector3(fwd.z, 0.0, -fwd.x) * track.road_half_width() / 3.0
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
	_all_wheels.clear()
	_steer_wheels.clear()
	_drive_wheels.clear()
	for child in get_children():
		if child is VehicleWheel3D:
			var wheel: VehicleWheel3D = child
			_all_wheels.append(wheel)
			var n := wheel.name.to_lower()
			if n.contains("front"):
				wheel.use_as_steering = true
				_steer_wheels.append(wheel)
			if n.contains("rear"):
				wheel.use_as_traction = true
				_drive_wheels.append(wheel)

	if _steer_wheels.is_empty() or _drive_wheels.is_empty():
		push_warning("车轮命名未包含 Front/Rear，按子节点顺序退化分配")
		var all := _all_wheels
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
	if network_replicated:
		_update_wheel_visuals(delta)
		_update_engine_sound(delta)
		return
	if belly_test_hover:
		gravity_scale = 0.0
		linear_velocity.y = 0.0
	elif _gravity_scale_normal >= 0.0:
		gravity_scale = _gravity_scale_normal
	_update_drive()
	_update_steering(delta)
	_update_drift(delta)
	if steering_stability_enabled: _steering_stability.tick(self, _track)
	if not (finish_input_locked and freeze):
		_update_wheel_visuals(delta)
	_update_engine_sound(delta)
	# 加入端只预测驾驶；计圈、脱困和复位仍由房主决定。
	if network_predicted:
		return
	if finish_input_locked:
		return
	_check_recovery(delta)
	_check_out_of_bounds(delta)
	_check_wrong_way()
	_check_start_line_crossing()
	_safe_reset.observe(self, _track, obstacle_field, delta)
	if _immunity > 0.0:
		_immunity = maxf(_immunity - delta, 0.0)
		if _immunity == 0.0:
			_set_ghost(false)
	if _reset_cooldown > 0.0:
		_reset_cooldown = maxf(_reset_cooldown - delta, 0.0)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if network_predicted:
		if not _network_correction.is_empty():
			var weight := 1.0 if _network_correction.hard else 1.0 - exp(-state.step / 0.12)
			var offset: Vector3 = _network_correction.p * weight
			var rotation := Quaternion.IDENTITY.slerp(_network_correction.q, weight)
			var velocity: Vector3 = _network_correction.v * weight
			var angular: Vector3 = _network_correction.w * weight
			var pose := state.transform
			pose.origin += offset
			pose.basis = Basis(rotation * pose.basis.get_rotation_quaternion())
			state.transform = pose
			state.linear_velocity += velocity
			state.angular_velocity += angular
			_network_correction.p -= offset
			_network_correction.q = rotation.inverse() * _network_correction.q
			_network_correction.v -= velocity
			_network_correction.w -= angular
			prediction_corrected.emit(offset, rotation, velocity, angular)
			if weight == 1.0 or (_network_correction.p.length() < 0.001 and _network_correction.v.length() < 0.001 \
					and _network_correction.w.length() < 0.001 and _network_correction.q.get_angle() < 0.001):
				_network_correction.clear()
		return
	_safe_reset.integrate(state)


func _check_start_line_crossing() -> void:
	if _track == null or _lap_suppressed:
		return
	if _race_laps.track != _track: _race_laps.configure(_track, _rail_half_width() * 2.0)
	if not _race_laps.observe(global_position): return
	if _reset_isolate_until_ms > 0.0:
		var moved := global_position.distance_to(_reset_isolate_from)
		if Time.get_ticks_msec() < _reset_isolate_until_ms and moved < lap_min_distance_after_reset:
			return
		_reset_isolate_until_ms = 0.0
	_on_lap_crossed()


func _on_lap_crossed() -> void:
	var crossing: int = _race_laps.cross(GameState.race_clock_ms(), laps_target, _safe_reset.consume_replayed_finish())
	if crossing == RaceLaps.Crossing.START:
		print("[计圈] 首发压线 pos=%s 速度=%.1f km/h" % [global_position, linear_velocity.length() * 3.6])
	if crossing < RaceLaps.Crossing.LAP: return
	print("[计圈] 完成第 %d 圈：%.3f 秒（最快 %.3f，目标 %d 圈）pos=%s 速度=%.1f km/h"
		% [laps_done, lap_last, lap_best, laps_target, global_position, linear_velocity.length() * 3.6])
	lap_completed.emit(lap_last, lap_best)
	if crossing == RaceLaps.Crossing.FINISH:
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
	_steering_grip = clampf(mult, 0.2, 2.0)
	for child in get_children():
		if child is VehicleWheel3D:
			var w: VehicleWheel3D = child
			if not _wheel_friction_base.has(w):
				_wheel_friction_base[w] = w.wheel_friction_slip
			var drift_multiplier := _drift_grip if w in _drive_wheels else 1.0
			w.wheel_friction_slip = float(_wheel_friction_base[w]) * _steering_grip * drift_multiplier


var _wheel_friction_base := {}


func current_lap_time() -> float:
	if not _lap_running:
		return 0.0
	return GameState.race_clock_ms() / 1000.0 - _lap_start_ms


## 由 main 唯一发车回调 _on_race_go() 调用（仅互动路径）：圈钟与总时间同一时刻起算。
## R6 修订（2026-10-19 用户拍板 D1）：本圈也从「出发！」起算、首圈含起跑爬行，
## 于是 总时间 ≡ 各圈之和，「起步」段恒为 0。go_ms 传 GameState.race_start_ms。
## 幂等：_lap_running 已为真直接返回（重复 GO 不重新起表）。
func begin_lap_timing(go_ms := -1) -> void:
	if _lap_running:
		return
	_race_laps.begin(go_ms if go_ms > 0 else GameState.race_clock_ms())
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

	var just_crashed := was_fast and now_stalled

	if now_stalled and (_driving or just_crashed):
		_stuck_time += delta
	else:
		_stuck_time = 0.0

	var surface_height := 0.0
	if _track != null:
		var recovery_near := _nearest_track_point()
		if not recovery_near.is_empty(): surface_height = Vector3(recovery_near.pos).y
	if global_position.y-surface_height >= 3.0:
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
	trajectory_discontinuity.emit()
	var v := linear_velocity
	var into_wall := v.dot(-best_normal)
	if into_wall > 0.0:
		linear_velocity = v + best_normal * into_wall
	_reset_cooldown = 0.3
	_debug_rec("wedge_rescue_ok")
	print("[车辆] 楔入救援：离墙 %.2fm，沿墙法线推出 %.2fm（%s → %s），保留车速 %.1f km/h"
		% [best_dist, wedge_rescue_push, before, global_position, linear_velocity.length() * 3.6])
	return true


func set_external_drive_input(intent: Dictionary) -> void:
	external_input_enabled = true
	_external_input.throttle = clampf(float(intent.get("throttle", 0.0)), -1.0, 1.0)
	_external_input.steering = clampf(float(intent.get("steering", 0.0)), -1.0, 1.0)
	_external_input.handbrake = bool(intent.get("handbrake", false))
	_external_input.drift = bool(intent.get("drift", false))


func clear_external_drive_input() -> void:
	external_input_enabled = true
	_external_input = {"throttle":0.0,"steering":0.0,"handbrake":false,"drift":false}
	input_brake_reverse = 0.0
	_clear_drift()


func set_network_replicated(value: bool) -> void:
	network_replicated = value
	set_process_unhandled_input(not value)
	if value: clear_external_drive_input()


func set_network_predicted() -> void:
	network_predicted = true
	set_network_replicated(false)
	set_process_unhandled_input(false) # R请求由同步器发给房主，不能本地执行。
	collision_mask &= ~2 # 两车接触由房主解算，复制车不再次推挤预测车。
	freeze = false


func reconcile_network_state(authoritative: Dictionary, predicted: Dictionary) -> void:
	var target := _network_pose(authoritative)
	var reference := _network_pose(predicted)
	var offset := target.origin - reference.origin
	var rotation := target.basis.get_rotation_quaternion() * reference.basis.get_rotation_quaternion().inverse()
	if rotation.w < 0.0: rotation = -rotation
	var velocity := _network_vector(authoritative.v) - _network_vector(predicted.v)
	var angular := _network_vector(authoritative.w) - _network_vector(predicted.w)
	var hard := offset.length() > 6.0 or rotation.get_angle() > PI / 3.0
	# 小误差下让本机悬挂继续解算。预测车回弹或暂时失去接触时，
	# 切回三维校正会把过时的权威悬挂相位叠加到回弹上。
	if not hard and absf(offset.y) < 0.5 and absf(float(authoritative.v[1])) < 2.0:
		offset.y = 0.0
		velocity.y = 0.0
		angular.x = 0.0
		angular.z = 0.0
		rotation = Quaternion(0.0, rotation.y, 0.0, rotation.w).normalized()
	_network_correction = {"p":offset,"q":rotation,
		"v":velocity,"w":angular,"hard":hard}
	apply_network_progress(authoritative)


static func _network_vector(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])


static func _network_pose(state: Dictionary) -> Transform3D:
	var q: Array = state.q
	return Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3]).normalized()), _network_vector(state.p))


func capture_network_state() -> Dictionary:
	var q := global_basis.get_rotation_quaternion().normalized()
	return {
		"p":[_q(global_position.x),_q(global_position.y),_q(global_position.z)],
		"q":[_q(q.x),_q(q.y),_q(q.z),_q(q.w)],
		"v":[_q(linear_velocity.x),_q(linear_velocity.y),_q(linear_velocity.z)],
		"w":[_q(angular_velocity.x),_q(angular_velocity.y),_q(angular_velocity.z)],
		"s":_q(steering),"d":_drifting,"l":laps_done,"c":start_line_crossed,
		"ll":_q(lap_last),"lb":_q(lap_best)
	}


func clear_network_correction() -> void:
	_network_correction.clear()


func capture_lap_clock() -> Array:
	return [_race_laps.lap_start_ms - GameState.race_start_ms,
		lap_times.map(func(time: float): return roundi(time * 1000.0))]


func apply_lap_clock(clock: Array) -> void:
	_race_laps.lap_start_ms = GameState.race_start_ms + int(clock[0])
	lap_times.assign(clock[1].map(func(ms: float): return ms / 1000.0))


func apply_network_state(state: Dictionary) -> void:
	global_transform = _network_pose(state)
	linear_velocity = _network_vector(state.v)
	angular_velocity = _network_vector(state.w)
	_steer = float(state.s)
	steering = _steer
	_drifting = bool(state.d)
	apply_network_progress(state)


func apply_network_progress(state: Dictionary) -> void:
	var next_lap := int(state.l)
	if next_lap < laps_done: return
	var new_lap := next_lap > laps_done
	laps_done = next_lap
	start_line_crossed = bool(state.c)
	lap_last = float(state.ll)
	lap_best = float(state.lb)
	if new_lap: lap_completed.emit(lap_last, lap_best)


static func _q(value: float) -> float:
	return snappedf(value, 0.0001)


func _drive_throttle() -> float:
	return float(_external_input.throttle) if external_input_enabled else VehicleDrive.throttle(input_prefix)


func _drive_steering() -> float:
	return float(_external_input.steering) if external_input_enabled else VehicleDrive.steering_input(input_prefix)


func _drive_pressed(action: String) -> bool:
	return bool(_external_input.get(action, false)) if external_input_enabled else Input.is_action_pressed(input_prefix + action)


func _drive_strength(action: String) -> float:
	if external_input_enabled:
		return absf(float(_external_input.throttle)) if action == "brake_reverse" and float(_external_input.throttle) < 0.0 else 0.0
	return Input.get_action_strength(input_prefix + action)


func _update_drive() -> void:
	if finish_input_locked:
		VehicleDrive.hold(_all_wheels, engine_brake)
		return
	if start_locked:
		VehicleDrive.hold(_steer_wheels + _drive_wheels, 10.0)
		return
	var throttle := _drive_throttle()
	input_brake_reverse = maxf(-throttle, 0.0)
	var handbrake := _drive_pressed("handbrake")
	var forward_speed := (-global_basis.z).dot(linear_velocity)
	# 反向输入先刹车，接近停车后才换向；同一动作也支持手柄/触控模拟量。
	var service_brake := absf(throttle) if throttle * forward_speed < 0.0 and absf(forward_speed) > 0.5 else 0.0
	_braking = handbrake or service_brake > 0.0
	evidence_input_read.emit("drive", Engine.get_physics_frames(), {"throttle": throttle, "handbrake": handbrake})
	_driving = absf(throttle) > 0.05 and not _braking

	var drive := throttle if _driving and (throttle > 0.0 or forward_speed > -6.0) else 0.0
	if drive != 0.0:
		var planar_speed := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()
		if planar_speed * 3.6 > max_speed_kmh:
			drive = 0.0

	var b := 0.0
	if handbrake:
		b = brake_force
	elif service_brake > 0.0:
		b = brake_force * service_brake
	elif not _driving:
		b = engine_brake
	VehicleDrive.apply_drive(_all_wheels, _drive_wheels, drive, max_engine_force, reverse_force, b)


func _update_drift(delta: float) -> void:
	var target := 1.0
	if _drive_pressed("drift") and GameState.phase == GameState.Phase.RACING \
			and not start_locked and not finish_input_locked and not _braking \
			and _drive_strength("brake_reverse") <= 0.1:
		var forward_speed := (-global_basis.z).dot(linear_velocity)
		var forward_kmh := forward_speed * 3.6
		var steering_input := _drive_steering()
		var can_enter := forward_kmh >= DRIFT_ENTRY_SPEED_KMH and absf(steering_input) >= 0.2
		var can_hold := _drifting and forward_kmh >= DRIFT_EXIT_SPEED_KMH
		_drifting = (can_enter or can_hold) and grounded_wheel_count() >= 3
		if _drifting:
			var lateral_speed := global_basis.x.dot(linear_velocity)
			var slip_angle := rad_to_deg(atan2(absf(lateral_speed), forward_speed))
			# 入漂仍用原抓地力。角度拉大时逐步补回后轮抓地，玩家的反打更容易收住车尾。
			var angle_support := smoothstep(7.0, 20.0, slip_angle)
			var countersteer := maxf(0.0, -steering_input * signf(lateral_speed))
			var correction_support := countersteer * smoothstep(4.0, 10.0, slip_angle) * 0.65
			target = lerpf(DRIFT_REAR_GRIP, DRIFT_SUPPORTED_GRIP, maxf(angle_support, correction_support))
	else:
		_drifting = false
	_set_drift_grip(move_toward(_drift_grip, target, DRIFT_GRIP_RATE * delta))


func _clear_drift() -> void:
	_drifting = false
	_set_drift_grip(1.0)


func _set_drift_grip(value: float) -> void:
	if value == _drift_grip:
		return
	_drift_grip = value
	for wheel in _drive_wheels:
		wheel.wheel_friction_slip = float(_wheel_friction_base[wheel]) * _steering_grip * value


func _update_steering(delta: float) -> void:
	if finish_input_locked:
		return
	if start_locked:
		return
	if steer_fixture_active:
		_steer = steer_fixture_angle
		VehicleDrive.steer(self, _steer)
		return
	var input := _drive_steering()   # D = -1，A = +1
	evidence_input_read.emit("steering", Engine.get_physics_frames(), {"steering": input})
	var speed := linear_velocity.length()
	var limit := RacingLine.steer_limit(speed, max_steer, steer_speed_falloff)
	# 先约束指令，再由倾斜保护收紧；复用AI已有曲率→舵角公式，不等车侧立才补救。
	limit = minf(limit, absf(RacingLine.steering_from_curvature(1.0, _wheel_base,
		speed, max_lateral_accel*_steering_grip)))
	limit *= _roll_guard_factor(speed)
	# 最大转角与响应速率分开调：低速保留渐变，高速小转角更快响应；
	# 松手/反打先用回中速率卸掉旧舵，再平滑建立新舵，不增加横向加速度预算。
	var target_steer := input * limit
	var rate := steer_speed
	if input * _steer < 0.0 or absf(target_steer) < absf(_steer): rate = steer_return_speed
	rate *= GameState.steering_sensitivity
	# 起伏/碰撞造成缺轮接地时沿用原4rad/s归一化响应，避免快速反打加剧落地和撞墙翻滚。
	# 四轮稳定接地时才使用新响应；不直接修改车体姿态、速度、质量或悬挂。
	if grounded_wheel_count() < 4: rate = minf(rate, 4.0)
	_steer = move_toward(_steer, target_steer, rate * minf(1.0, limit/maxf(max_steer,0.001)) * delta)
	_steer = clampf(_steer, -limit, limit)
	VehicleDrive.steer(self, _steer)


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

	var state := EngineAudio.update_sound(self, [] if finish_input_locked and freeze else _drive_wheels, delta, _driving,
		idle_pitch, max_pitch, gear_span, _gear_count)
	_gear = int(state.x)
	_rpm01 = state.y


func _unhandled_input(event: InputEvent) -> void:
	if network_replicated:
		return
	if event.is_action_pressed(input_prefix + "reset"):
		request_reset()


func request_reset() -> void:
	if finish_input_locked: return
	if _reset_cooldown > 0.0:
		return
	var saved: Dictionary = _safe_reset.target(self, _track, obstacle_field)
	if saved.is_empty():
		push_warning("[车辆] R：没有可用安全位置，保留当前位置")
		return
	reset_to_track(saved)


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


func reset_to_track(saved: Dictionary = {}) -> void:
	_debug_rec("reset_to_track")
	var near := _nearest_track_point() if saved.is_empty() else saved
	if near.is_empty():
		reset_to_checkpoint()
		return
	var target: Vector3 = near["pos"]
	var fwd: Vector3 = near["forward"]
	var lane := 0.0 if near.get("safe_restore", false) else _clear_reset_lane(float(near["arc"]))
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
	_race_laps.mark_behind()
	global_transform.basis = Basis.looking_at(fwd, near.get("normal", Vector3.UP))
	global_position = near.get("restore_position", target + Vector3.UP * 0.8)
	trajectory_discontinuity.emit()
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_safe_reset.queue_pose(global_transform)
	steering = 0.0
	_steer = 0.0
	_stuck_time = 0.0
	_out_time = 0.0
	_reset_cooldown = 0.5
	_reset_isolate_until_ms = Time.get_ticks_msec() + 6000
	_reset_isolate_from = global_position
	_grant_immunity()
	var now_ms := Time.get_ticks_msec()
	if saved.is_empty() and now_ms - _last_reset_ms < 3000.0 and global_position.distance_to(_last_reset_pos) < 8.0:
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
	trajectory_discontinuity.emit()
	global_transform.basis = Basis(Vector3.UP, best.global_rotation.y + PI)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


func recover_upright() -> void:
	trajectory_discontinuity.emit()
	_debug_rec("recover_upright")
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	global_transform.basis = Basis.looking_at(fwd.normalized(), Vector3.UP)
	global_position += Vector3.UP * 0.3    # 抬离地面一点，免得扶正瞬间卡进路面
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_safe_reset.queue_pose(global_transform)


func recover_from_belly_slide() -> void:
	_debug_rec("recover_from_belly_slide")
	recover_upright()                       # 扶正 + 抬 0.3m + 清零线速度与角速度
	global_position += Vector3.UP * maxf(belly_lift - 0.3, 0.0)
	apply_central_impulse(Vector3.UP * belly_impulse_dv * mass)
	_safe_reset.queue_pose(global_transform, linear_velocity)
	belly_recovery_count += 1
	_belly_time = 0.0


