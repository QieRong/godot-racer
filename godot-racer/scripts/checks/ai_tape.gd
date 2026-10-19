extends RefCounted
## 固定帧输入带：正式模式只播放数据；校准模式只调用玩家跟线能力，不读取 AI 成绩。
## 场景/常量/setup 注入；零协程；仅经 Input 写入动作，不写车辆物理状态。
var _car: VehicleBody3D
var _ai: Node3D
var _track: Node
var _cfg: Dictionary = {}
var _manifest: Dictionary = {}
var _tape: Dictionary = {}
var _calibrator: Callable
var _emit: Callable
var _active := false
var _calibration := false
var _origin := -1
var _go_frame := -1
var _segment := 0
var _current_frame := -1
var _pending: Dictionary = {}
var _recorded: Array = []
var _recoveries: Array = []
var _gap_series: Array = []
var _geometry: Array = []
var _bindings: Dictionary = {}
var _last_window := "WAITING"
var _first_gap_frame := -1
var _max_gap := -1.0
var _closed := false
var _configured := false
var _stop_requested := false
var error := ""

func setup(car: VehicleBody3D, ai: Node3D, track: Node, config: Dictionary,
		calibrator: Callable, emit: Callable) -> bool:
	_car = car
	_ai = ai
	_track = track
	_cfg = config.duplicate(true)
	_calibrator = calibrator
	_emit = emit
	for key in ["mode", "manifest_path", "calibration_output", "channels", "required_tape_frames",
			"geometry_audit_step_m", "contract_sources", "level_config_path", "free_run_gap_m",
			"frame_origin_and_input_phase", "window_rule_version", "observation_deadline"]:
		if not _cfg.has(key):
			return _reject("TAPE_CONFIG_MISSING:" + str(key))
	if _cfg["mode"] not in ["calibrate", "replay"]:
		return _reject("TAPE_MODE_INVALID")
	_calibration = str(_cfg["mode"]) == "calibrate"
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(_cfg["manifest_path"])))
	if not parsed is Dictionary:
		return _reject("SCENARIO_MANIFEST_INVALID")
	_manifest = parsed
	_geometry = _geometry_audit()
	_bindings = _source_bindings()
	if _calibration:
		if FileAccess.file_exists(str(_cfg["calibration_output"])):
			return _reject("CALIBRATION_OUTPUT_EXISTS")
	else:
		if _manifest.get("state") != "FROZEN":
			return _reject("TAPE_NOT_FROZEN")
		for key in _bindings:
			if _manifest.get(key) != _bindings[key]:
				return _reject("SCENARIO_BINDING_MISMATCH:" + str(key))
		if not _contract_equal(_manifest.get("initial_state_contract"), _initial_contract()):
			return _reject("INITIAL_STATE_CONTRACT_MISMATCH")
		if _manifest.get("frame_origin_and_input_phase") != _cfg["frame_origin_and_input_phase"]:
			return _reject("INPUT_PHASE_MISMATCH")
		if _manifest.get("window_rule_version") != _cfg["window_rule_version"]:
			return _reject("WINDOW_RULE_MISMATCH")
		if not _contract_equal(_manifest.get("observation_deadline"), _cfg["observation_deadline"]):
			return _reject("OBSERVATION_DEADLINE_MISMATCH")
		var schedule: Dictionary = _manifest.get("input_schedule", {})
		var data_name := str(schedule.get("data_file", ""))
		if data_name.is_empty() or data_name.get_file() != data_name:
			return _reject("TAPE_PATH_MUST_BE_ADJACENT_FILENAME")
		var tape_path := str(_cfg["manifest_path"]).get_base_dir().path_join(data_name)
		if FileAccess.get_sha256(tape_path) != _manifest.get("input_tape_hash"):
			return _reject("INPUT_TAPE_HASH_MISMATCH")
		var tape_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(tape_path))
		if not tape_value is Dictionary:
			return _reject("TAPE_DATA_INVALID")
		_tape = tape_value
		if not _validate_tape():
			return false
		var review: Dictionary = _manifest.get("coverage_review", {})
		if review.get("track_geometry_hash") != _bindings["track_geometry_hash"] or not review.get("all_segments_reviewed", false):
			return _reject("COVERAGE_PREREVIEW_MISSING")
	if not _car.has_signal("evidence_input_read"):
		return _reject("VEHICLE_INPUT_READ_RECEIPT_UNAVAILABLE")
	_car.connect("evidence_input_read", Callable(self, "_on_vehicle_read"))
	_configured = true
	return true

func _reject(reason: String) -> bool:
	error = reason
	return false

## 清单字段的相等判定：**数值按值、字符串按串**，其余按原样。
##
## ⚠ 为什么不能直接 `!=`：清单走一次 JSON 往返后**所有数字都变成 float**，而运行时
##   算出的 level / physics_hz / nominal_physics_frames 是 int；Godot 的 Dictionary
##   相等比较是**按类型**做的（int 0 与 float 0.0 的哈希不同 → 判不等）。实测因此
##   稳定误报 INITIAL_STATE_CONTRACT_MISMATCH、OBSERVATION_DEADLINE_MISMATCH
##   （诊断日志：godot-logs/cd-tape-diag3.log 里 FROZEN 侧 level=0.0/hz=120.0，
##   实算侧 level=0/hz=120）。只抹平 int/float 这一个类型差，不放宽任何数值判据。
func _contract_equal(frozen: Variant, live: Variant) -> bool:
	if not frozen is Dictionary or not live is Dictionary:
		return false
	if frozen.size() != live.size():
		return false
	for key in live:
		if not frozen.has(key):
			return false
		var left: Variant = frozen[key]
		var right: Variant = live[key]
		if left is String or right is String:
			if str(left) != str(right):
				return false
		elif (left is int or left is float) and (right is int or right is float):
			if float(left) != float(right):
				return false
		elif left != right:
			return false
	return true

func _validate_tape() -> bool:
	if _tape.get("channels") != _cfg["channels"]:
		return _reject("TAPE_CHANNELS_MISMATCH")
	var next := 0
	for row in _tape.get("commands", []):
		if not row is Array or row.size() != 3:
			return _reject("TAPE_ROW_INVALID")
		for bound in [row[0], row[1]]:
			if not (bound is float or bound is int) or not is_finite(float(bound)) or float(bound) != float(int(bound)):
				return _reject("TAPE_FRAME_INDEX_INVALID")
		if int(row[0]) != next or int(row[1]) < next or not row[2] is Array:
			return _reject("TAPE_GAP_OR_OVERLAP")
		if row[2].size() != _cfg["channels"].size():
			return _reject("TAPE_WIDTH_INVALID")
		for value in row[2]:
			if not (value is float or value is int) or not is_finite(float(value)) or value < 0.0 or value > 1.0:
				return _reject("TAPE_STRENGTH_INVALID")
		next = int(row[1]) + 1
	if next != int(_tape.get("frame_count", 0)) or next < int(_cfg["required_tape_frames"]):
		return _reject("TAPE_DURATION_INSUFFICIENT")
	return true

func start() -> void:
	_go_frame = Engine.get_physics_frames()
	_release_inputs()
	_active = true
	_emit.call("TAPE_BEGIN", {"mode": _cfg["mode"], "go_frame": _go_frame,
		"scenario_version": _manifest.get("scenario_version"), "bindings": _bindings,
		"initial_state_contract": _initial_contract(), "initial_state_observed": _state(_car)})

func apply_frame() -> bool:
	if not _active or not error.is_empty():
		return false
	var frame := Engine.get_physics_frames()
	if _origin < 0:
		_origin = frame
	var index := frame - _origin
	_current_frame = frame
	# 前一帧未收到的读取回执不可伪造成已读取。
	for previous in _pending:
		if int(previous) < frame:
			return _reject("VEHICLE_INPUT_READ_MISSING:%d" % int(previous))
	var command: Array = []
	if _calibration:
		_calibrator.call()  # 几何与玩家自身跟线能力；接口没有 AI/目标速度/60% 成绩参数。
		for action in _cfg["channels"]:
			command.append(Input.get_action_strength(str(action)))
	else:
		if index >= int(_tape["frame_count"]):
			return _reject("TAPE_EXHAUSTED")
		var commands: Array = _tape["commands"]
		while index > int(commands[_segment][1]):
			_segment += 1
		command = commands[_segment][2].duplicate()
		for column in range(command.size()):
			var action := str(_cfg["channels"][column])
			Input.action_release(action)
			if float(command[column]) > 0.0:
				Input.action_press(action, float(command[column]))
	_pending[frame] = {"frame": frame, "local_frame": index, "command": command,
		"stage": "CALIBRATION" if _calibration else "FROZEN_REPLAY", "actual_read": {},
		"input_axes_at_apply": {"throttle": Input.get_axis("brake_reverse", "accelerate"),
			"steering": Input.get_axis("steer_right", "steer_left"),
			"handbrake": Input.is_action_pressed("handbrake")},
		"state_phase": "physics_frame_signal_before_node_physics", "player": _state(_car), "ai": _state(_ai)}
	if _calibration:
		_recorded.append(command.duplicate())
	return true

func ledger(window: String, reason: String, gap: float, valid_target_frames: int) -> void:
	if not _pending.has(_current_frame):
		return
	var row: Dictionary = _pending[_current_frame]
	row["window"] = {"state": window, "reason": reason, "valid_target_frames": valid_target_frames}
	row["interaction"] = {"gap_m": gap, "player_layer": _car.collision_layer,
		"player_mask": _car.collision_mask, "ai_layer": _ai.get("collision_layer"),
		"ai_mask": _ai.get("collision_mask"), "player_reference_valid": _ai.get("player") == _car}
	_gap_series.append([_current_frame, gap])
	_max_gap = maxf(_max_gap, gap)
	if _first_gap_frame < 0 and gap >= float(_cfg["free_run_gap_m"]):
		_first_gap_frame = _current_frame
	if window != _last_window:
		_emit.call("TAPE_WINDOW", {"frame": _current_frame, "from": _last_window,
			"to": window, "reason": reason, "gap_m": gap})
	_last_window = window

func _on_vehicle_read(kind: String, frame: int, values: Dictionary) -> void:
	if not _active:
		return
	if kind == "recovery":
		var record := {"frame": frame, "data": values.duplicate(true), "source": "vehicle._debug_rec"}
		_recoveries.append(record)
		_emit.call("TAPE_RECOVERY", record)
		return
	if not _pending.has(frame):
		if _stop_requested:
			_emit.call("TAPE_POST_WINDOW_READ", {"frame": frame, "kind": kind,
				"actual_read": values, "phase": "AFTER_MEASUREMENT"})
		return
	var row: Dictionary = _pending[frame]
	row["actual_read"][kind] = values.duplicate(true)
	if row["actual_read"].has("drive") and row["actual_read"].has("steering"):
		row["actual_read_status"] = "VEHICLE_RECEIPT"
		var intended: Dictionary = row["input_axes_at_apply"]
		row["read_matches_applied_intent"] = row["actual_read"]["drive"]["throttle"] == intended["throttle"] \
			and row["actual_read"]["drive"]["handbrake"] == intended["handbrake"] \
			and row["actual_read"]["steering"]["steering"] == intended["steering"]
		if not row["read_matches_applied_intent"]:
			error = "INPUT_CONSUMPTION_MISMATCH"
		_emit.call("TAPE_FRAME", row)
		_pending.erase(frame)
		if _stop_requested:
			_release_inputs()

func request_stop() -> void:
	_stop_requested = true
	if _pending.is_empty():
		_release_inputs()

func _release_inputs() -> void:
	for action in _cfg.get("channels", []):
		Input.action_release(str(action))

func _state(body: Node3D) -> Dictionary:
	var near: Dictionary = _track.call("nearest_on_centerline", body.global_position, -1.0)
	var position := body.global_position
	var velocity: Vector3 = body.get("linear_velocity")
	return {"position": [position.x, position.y, position.z],
		"velocity": [velocity.x, velocity.y, velocity.z], "arc": near.get("arc"),
		"deviation": near.get("dist"), "basis": str(body.global_basis)}

func _geometry_audit() -> Array:
	var result: Array = []
	var length := float(_track.call("road_length"))
	var stride := float(_cfg["geometry_audit_step_m"])
	for index in range(ceili(length / stride) + 1):
		var arc := minf(float(index) * stride, length)
		var point: Vector3 = _track.call("centerline_point", arc)
		var forward: Vector3 = _track.call("centerline_forward", arc)
		result.append([arc, point.x, point.y, point.z, forward.x, forward.y, forward.z])
	return result

func _source_bindings() -> Dictionary:
	var source_hashes: Dictionary = {}
	for name in _cfg["contract_sources"]:
		source_hashes[name] = FileAccess.get_sha256(str(_cfg["contract_sources"][name]))
	return {"level_config_hash": FileAccess.get_sha256(str(_cfg["level_config_path"])),
		"track_geometry_hash": JSON.stringify(_geometry, "", true, true).sha256_text(),
		"driver_version": FileAccess.get_sha256("res://scripts/checks/ai_tape.gd"),
		"acceptance_contract_hash": JSON.stringify(source_hashes).sha256_text()}

func _initial_contract() -> Dictionary:
	return {"spawn": "existing GameState/main spawn; no fixture pose/velocity writes",
		"level": GameState.chosen_level, "physics_hz": Engine.physics_ticks_per_second,
		"player_speed_cap_kmh": _car.get("max_speed_kmh"),
		"vehicle_source_hash": FileAccess.get_sha256("res://scripts/vehicle.gd"),
		"main_source_hash": FileAccess.get_sha256("res://scenes/main.gd"),
		"autopilot_source_hash": FileAccess.get_sha256("res://scripts/autopilot.gd"),
		"game_state_source_hash": FileAccess.get_sha256("res://scripts/game_state.gd"),
		"scene_source_hash": FileAccess.get_sha256("res://scenes/race_car.tscn"),
		"project_source_hash": FileAccess.get_sha256("res://project.godot"),
		"physical_settling": "observed per run; bitwise initial physical state is not promised"}

func is_calibrating() -> bool:
	return _calibration

func summary() -> Dictionary:
	return {"mode": _cfg.get("mode", "UNCONFIGURED"), "error": error, "first_gap_frame": _first_gap_frame,
		"max_gap_m": _max_gap, "gap_series": _gap_series,
		"player_recovery_events": _recoveries, "fixture_recovery_writes": 0,
		"pending_read_receipts": _pending.keys(), "first_input_frame": _origin, "go_frame": _go_frame}

func close() -> Dictionary:
	if _closed:
		return summary()
	_closed = true
	if not _configured:
		return summary()
	if not _pending.is_empty() and error.is_empty():
		error = "VEHICLE_INPUT_READ_MISSING_AT_END"
	if _calibration:
		_export_calibration()
	_active = false
	if _car.is_connected("evidence_input_read", Callable(self, "_on_vehicle_read")):
		_car.disconnect("evidence_input_read", Callable(self, "_on_vehicle_read"))
	_release_inputs()
	var result := summary()
	_emit.call("TAPE_END", result)
	return result

func _export_calibration() -> void:
	var candidate := _manifest.duplicate(true)
	candidate.merge(_bindings, true)
	candidate["state"] = "CALIBRATED_NOT_FROZEN"
	candidate["initial_state_contract"] = _initial_contract()
	candidate["frame_origin_and_input_phase"] = _cfg["frame_origin_and_input_phase"]
	candidate["window_rule_version"] = _cfg["window_rule_version"]
	candidate["observation_deadline"] = _cfg["observation_deadline"]
	candidate["calibration"] = summary()
	candidate["calibration"]["channels"] = _cfg["channels"]
	candidate["calibration"]["frames"] = _recorded
	candidate["calibration"]["geometry_audit"] = _geometry
	candidate["calibration"]["method"] = "依据赛道几何与玩家自身跟线能力，不依据 AI 的 60% 成绩优化"
	var file := FileAccess.open(str(_cfg["calibration_output"]), FileAccess.WRITE)
	if file == null:
		error = "CALIBRATION_OUTPUT_WRITE_FAILED"
		return
	file.store_string(JSON.stringify(candidate, "\t", true, true) + "\n")
	file.close()
