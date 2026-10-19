extends RefCounted
## 只读证据输出器。场景对象由 setup 注入；不调度、不推进时间、不改车辆。
## ASSERT 的 source_predicate 保留原表达式；复合判据不在解析器重算另一套公式。
var _car: VehicleBody3D
var _track: Node
var _opponents: Array = []
var _identity: Dictionary = {}
var _facts: Dictionary = {}
var _active := false
var _failed := 0
var _assertions := 0
var _samples := 0
var _start_frame := 0
var _last_frame := -1
var _first_frame := -1
var _frame_gaps: Array = []
var _previous: Dictionary = {}
var _contacts_available := false
var _rescues: Dictionary = {}
var _proxy_observers: Dictionary = {}
var _proxy_counts: Dictionary = {}

func setup(car: VehicleBody3D, track: Node, opponents: Array, identity: Dictionary,
		proxy_factory: Callable) -> void:
	_car = car
	_track = track
	_opponents = opponents
	_identity = identity.duplicate(true)
	_active = true
	_start_frame = Engine.get_physics_frames()
	_identity["physics_hz"] = Engine.physics_ticks_per_second
	_identity["render_fps"] = Engine.max_fps
	_identity["level"] = GameState.chosen_level
	_identity["engine_version"] = Engine.get_version_info().get("string", "")
	_identity["physics_engine"] = ProjectSettings.get_setting("physics/3d/physics_engine", "")
	_identity["seed"] = preload("res://scripts/obstacle_field.gd").SEED
	_identity["level_config_hash"] = FileAccess.get_sha256(GameState.current_level().resource_path)
	_identity["effective_settings"] = {"player_speed_cap_kmh": _car.get("max_speed_kmh"),
		"ai_enabled": GameState.ai_enabled, "friction_multiplier": GameState.current_level().friction_multiplier,
		"laps_to_finish": GameState.current_level().laps_to_finish}
	_emit("RUNID", _identity)
	_emit("COVERAGE", {"phase": "BEGIN", "frame": _start_frame})
	_contacts_available = _car.contact_monitor and _car.max_contacts_reported > 0
	for opponent in _opponents:
		_contacts_available = _contacts_available and opponent.contact_monitor and opponent.max_contacts_reported > 0
	if _track != null and proxy_factory.is_valid():
		_proxy_observers["player"] = proxy_factory.call(_car)
		for index in range(_opponents.size()):
			_proxy_observers["ai:%d" % index] = proxy_factory.call(_opponents[index])

func _clean(value: Variant) -> Variant:
	if value is float and not is_finite(value):
		return "NAN" if is_nan(value) else "INF" if value > 0 else "-INF"
	if value is Dictionary:
		var out: Dictionary = {}
		for key in value:
			out[str(key)] = _clean(value[key])
		return out
	if value is Array:
		var out: Array = []
		for item in value:
			out.append(_clean(item))
		return out
	if value == null or value is bool or value is int or value is float or value is String:
		return value
	return str(value)

func _emit(tag: String, value: Dictionary) -> void:
	if _active:
		print(tag + "|" + JSON.stringify(_clean(value)))

func assertion(id: String, value: Variant, unit: String, threshold: Variant,
		op: String, result: String, kind := "contract", context: Dictionary = {}) -> void:
	if not _active:
		return
	_assertions += 1
	if result == "FAIL":
		_failed += 1
	_emit("ASSERT", {"id": id, "value": value, "unit": unit, "threshold": threshold,
		"op": op, "result": result, "kind": kind, "frame": Engine.get_physics_frames(),
		"context": context})

func branch(id: String, result: String, predicate: String, observations: Dictionary) -> void:
	assertion(id, observations, "source_predicate", predicate, "original_expression", result, "branch")

func legacy(id: String, message: Variant, error := false, predicate := "") -> void:
	# 原消息只求值、打印一次；附加锚点不调用原判据函数。
	if error:
		printerr(message)
	else:
		print(message)
	var text := str(message)
	var result := "INFO"
	if text.contains("✔"):
		result = "PASS"
	elif text.contains("✘"):
		result = "FAIL"
	elif text.contains("⊘"):
		result = "SKIP"
	assertion(id, text, "legacy_message", predicate, "original_branch", result, "legacy")

func fact(values: Dictionary) -> void:
	for key in values:
		_facts[key] = values[key]

func event(kind: String, entity: String, values: Dictionary = {}) -> void:
	_emit("EVENT", {"type": kind, "entity": entity, "frame": Engine.get_physics_frames(), "data": values})

func sample() -> void:
	if not _active:
		return
	var frame := Engine.get_physics_frames()
	if frame == _last_frame:
		return
	if _last_frame >= 0 and frame != _last_frame + 1:
		_frame_gaps.append([_last_frame, frame])
	if _first_frame < 0:
		_first_frame = frame
	_last_frame = frame
	_samples += 1
	_observe_contacts(_car, "player", frame)
	_sample_proxy(_car, "player", frame)
	for index in range(_opponents.size()):
		_observe_contacts(_opponents[index], "ai:%d" % index, frame)
		_sample_proxy(_opponents[index], "ai:%d" % index, frame)
		var entity := "ai:%d" % index
		if not _opponents[index].has_method("rescue_count"):
			continue
		var rescues := int(_opponents[index].call("rescue_count"))
		var previous := int(_rescues.get(entity, 0))
		if rescues != previous:
			event("RESCUE_COUNT_OBSERVED", entity, {"previous": previous, "current": rescues,
				"timing": "observation_frame_not_reconstructed_event_time"})
		_rescues[entity] = rescues

func _sample_proxy(body: VehicleBody3D, entity: String, frame: int) -> void:
	if not _proxy_observers.has(entity):
		return
	var observer = _proxy_observers[entity]
	# 复用既有诊断定义，不复制速度突降表达式；独立实例只持有诊断历史。
	observer.set("_f", frame)
	observer.note_speed(_track, body.linear_velocity.length() * 3.6, false)
	var count := int(observer.get("_impact_n"))
	var previous := int(_proxy_counts.get(entity, 0))
	if count != previous:
		event("COLLISION_PROXY", entity, {"previous": previous, "current": count,
			"definition": "l4_debug_diag.note_speed", "is_real_contact": false})
	_proxy_counts[entity] = count

func _observe_contacts(body: RigidBody3D, entity: String, frame: int) -> void:
	if not body.contact_monitor or body.max_contacts_reported <= 0:
		return
	var current: Dictionary = {}
	# 仅消费原配置已提供的接触报告；不打开 contact_monitor，不修改容量。
	for other in body.get_colliding_bodies():
		var other_id := str(other.get_path())
		current[other_id] = true
		if not _previous.get(entity, {}).has(other_id):
			_emit("CONTACT", {"frame": frame, "entity": entity, "other": other_id,
				"phase": "BEGIN", "definition": "existing_engine_contact_monitor"})
	for other_id in _previous.get(entity, {}):
		if not current.has(other_id):
			_emit("CONTACT", {"frame": frame, "entity": entity, "other": other_id,
				"phase": "END", "definition": "existing_engine_contact_monitor"})
	_previous[entity] = current

func finish(check_name: String) -> void:
	if not _active:
		return
	var ai_states: Array = []
	for index in range(_opponents.size()):
		var opponent = _opponents[index]
		ai_states.append({"entity": "ai:%d" % index,
			"laps_done": opponent.call("laps_done") if opponent.has_method("laps_done") else null,
			"rescue_count": opponent.call("rescue_count") if opponent.has_method("rescue_count") else null,
			"armed": opponent.get("armed")})
	var outcome := _facts.duplicate(true)
	var proxy_total := 0
	for entity in _proxy_counts:
		proxy_total += int(_proxy_counts[entity])
	outcome["collision_proxy_count"] = proxy_total
	outcome["collision_proxy_by_entity"] = _proxy_counts.duplicate()
	outcome.merge({"check": check_name, "finished": true, "measurement_status": "COMPLETE",
		"ai": ai_states, "failed_assertions": _failed, "assertion_records": _assertions,
		"reset_count": null, "stuck_count": null, "collision_count": null,
		"exit_code_requested": 0}, false)
	_emit("COVERAGE", {"phase": "END", "sample_frames": _samples,
		"first_sample_frame": _first_frame, "last_sample_frame": _last_frame, "missing_frame_gaps": _frame_gaps,
		"start_frame": _start_frame, "end_frame": Engine.get_physics_frames(),
		"contact_observation_available": _contacts_available,
		"collision_proxy_available": _proxy_observers.size() == _opponents.size() + 1,
		"collision_proxy_entities": _proxy_observers.keys(),
		"collision_proxy_definition": "l4_debug_diag.note_speed",
		"contact_definition": "existing_engine_contact_monitor",
		"note": "unavailable contacts are unknown, not zero"})
	_emit("OUTCOME", outcome)
	_active = false
