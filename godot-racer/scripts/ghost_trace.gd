extends Node
const Visual := preload("res://scripts/ghost_car.gd")
const PERIOD := 1.0 / 25.0
const MAX_SECONDS := 600.0
const MAX_BYTES := 1024 * 1024
const MAX_SAMPLES := 15004
const NO_TRACE_NOTICE_SECONDS := 3.0
var directory := "user://ghosts"
var identity := ""
var context: Dictionary = {}
var data := PackedFloat32Array()
var playback := PackedFloat32Array()
var car: VehicleBody3D
var ranking: Node
var visual: Node3D
var origin := 0.0
var next_sample := 0.0
var active := false
var valid := true
var status: Label
var notice_until := 0.0

func setup(player: VehicleBody3D, track: Node3D, position: Node, field: Node3D) -> void:
	name = "GhostTrace"
	car = player
	ranking = position
	# 导出配置和实际几何一起签名；不采用每次变化的原始随机种子。
	var cfg := GameState.current_level()
	context = {"level": GameState.chosen_level + 1, "mode": "endless_lap" if GameState.endless_mode else "race",
		"laps": car.laps_target, "variant": GameState.race_variant_summary()}
	var properties: Array = ["ghost-v1", GameState.chosen_level, GameState.endless_mode, car.laps_target]
	for prop in cfg.get_property_list():
		if int(prop.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE and int(prop.usage) & PROPERTY_USAGE_STORAGE:
			properties.append([prop.name, var_to_str(cfg.get(prop.name))])
	for i in range(0, ceili(track.road_length()), 5):
		properties.append(var_to_str(track.centerline_point(float(i))))
	# 同时覆盖本次生成的真实障碍位置；算法调整后也不会误播旧路线。
	if field != null:
		properties.append(var_to_str(field.obstacles))
		for obstacle in field._dynamic:
			properties.append([obstacle.arc, obstacle.center, obstacle.travel, obstacle.speed, obstacle.half_width])
	identity = JSON.stringify(properties).sha256_text()
	playback = read_trace(file_path()).get("samples", PackedFloat32Array())
	var layer := CanvasLayer.new()
	add_child(layer)
	status = Label.new()
	status.name = "GhostStatus"
	status.size = Vector2(520, 52)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_font_override("font", preload("res://scripts/ui_theme.gd").ui_font)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	status.add_theme_font_size_override("font_size", 16)
	status.add_theme_color_override("font_outline_color", Color.BLACK)
	status.add_theme_constant_override("outline_size", 4)
	layer.add_child(status)
	get_viewport().size_changed.connect(_fit_status)
	_fit_status()
	status.text = "幽灵：该组合/模式暂无有效轨迹" if playback.is_empty() else "幽灵：当前组合最佳有效轨迹"
	status.visible = false
	car.trajectory_discontinuity.connect(invalidate)
	car.lap_completed.connect(_lap_completed)
	if GameState.ghost_enabled and not playback.is_empty():
		visual = Visual.new()
		add_child(visual)
		visual.build(car)
		visual.add_ghost_label(playback[playback.size() - Visual.STRIDE])
		visual.samples = playback
		visual.visible = false

func _fit_status() -> void:
	var base: Vector2 = preload("res://scripts/ui_theme.gd").BASE_SIZE
	var view_size := get_viewport().get_visible_rect().size
	var factor := minf(view_size.x / base.x, view_size.y / base.y)
	status.scale = Vector2.ONE * factor
	var top_center := Vector2((base.x - status.size.x) * 0.5, 16)
	status.position = (view_size - base * factor) * 0.5 + top_center * factor

func file_path() -> String:
	return directory.path_join(identity + ".ghost")

func begin() -> void:
	origin = GameState.race_total_time()
	next_sample = 0.0
	data.clear()
	valid = true
	active = true
	notice_until = origin + NO_TRACE_NOTICE_SECONDS
	_sample(0.0)
	if GameState.ghost_enabled and not playback.is_empty():
		if visual == null:
			visual = Visual.new()
			add_child(visual)
			visual.build(car)
			visual.add_ghost_label(playback[playback.size() - Visual.STRIDE])
		visual.samples = playback
		visual.cursor = 0
		visual.get_node("GhostName").text = tr("幽灵车\n%s") % preload("res://scripts/race_records.gd").time_text(playback[playback.size() - Visual.STRIDE])

func invalidate() -> void:
	if not active: return
	valid = false
	notice_until = GameState.race_total_time() + 4.0
	if status != null and GameState.ghost_enabled:
		status.text = "幽灵：本圈复位，保留原轨迹" if GameState.endless_mode else "幽灵：本场复位，保留原轨迹"

func _sample(seconds: float) -> void:
	if seconds > MAX_SECONDS or data.size() / Visual.STRIDE >= MAX_SAMPLES:
		valid = false
		return
	if not data.is_empty() and seconds <= data[data.size() - Visual.STRIDE]: return
	data = Visual.append_sample(data, seconds, car.global_transform, ranking.player_progress())

func _physics_process(_delta: float) -> void:
	if not active or GameState.phase_name() != "RACING": return
	status.visible = GameState.ghost_enabled and (playback.is_empty() or not valid) and GameState.race_total_time() < notice_until
	var seconds := GameState.race_total_time() - origin
	if seconds >= next_sample:
		if valid: _sample(seconds)
		next_sample += PERIOD
	if visual != null: visual.play_at(seconds)

func _lap_completed(_last: float, _best: float) -> void:
	if not active or not GameState.endless_mode: return
	complete()
	begin()
	if status != null and GameState.ghost_enabled:
		status.text = "幽灵：当前组合最佳有效轨迹" if not playback.is_empty() else "幽灵：该组合/模式暂无有效轨迹"

func complete() -> void:
	if not active: return
	var seconds := GameState.race_total_time() - origin
	_sample(seconds)
	active = false
	if status != null: status.visible = false
	if visual != null: visual.visible = false
	if valid and GameState.record_results_enabled:
		save_trace(seconds)

func save_trace(seconds: float) -> bool:
	if seconds <= 0.0 or seconds > MAX_SECONDS or data.size() < Visual.STRIDE * 2: return false
	var old := read_trace(file_path())
	if not old.is_empty() and float(old.time) <= seconds: return false
	var document := {"version": 1, "identity": identity, "context": context, "time": seconds, "samples": data}
	if var_to_bytes(document).size() > MAX_BYTES: return false
	if DirAccess.make_dir_recursive_absolute(directory) != OK: return _save_error()
	var temporary := file_path() + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return _save_error()
	file.store_var(document, false)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK: return _save_error()
	if FileAccess.file_exists(file_path()) and DirAccess.copy_absolute(file_path(), file_path() + ".bak") != OK: return _save_error()
	if DirAccess.rename_absolute(temporary, file_path()) != OK: return _save_error()
	playback = data.duplicate()
	return true

func _save_error() -> bool:
	push_warning("幽灵轨迹保存失败，保留原轨迹；正常成绩不受影响")
	return false

func read_trace(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	if file.get_length() > MAX_BYTES: return {}
	var parsed: Variant = file.get_var(false)
	file.close()
	if not parsed is Dictionary: return {}
	var entry: Dictionary = parsed
	if entry.get("version") != 1 or entry.get("identity") != identity: return {}
	var samples: Variant = entry.get("samples")
	if not samples is PackedFloat32Array or samples.size() < 18 or samples.size() % 9 != 0 or samples.size() > MAX_SAMPLES * 9: return {}
	var seconds: Variant = entry.get("time")
	if not (seconds is float or seconds is int) or not is_finite(seconds) or seconds <= 0 or seconds > MAX_SECONDS: return {}
	var previous := -1.0
	for i in range(0, samples.size(), 9):
		for j in range(9):
			if not is_finite(samples[i+j]): return {}
		if samples[i] <= previous or samples[i] > MAX_SECONDS: return {}
		var q := Quaternion(samples[i+4], samples[i+5], samples[i+6], samples[i+7])
		if absf(q.length_squared() - 1.0) > 0.05: return {}
		previous = samples[i]
	if absf(previous - float(seconds)) > 0.02 or absf(samples[0]) > 0.001: return {}
	return entry
