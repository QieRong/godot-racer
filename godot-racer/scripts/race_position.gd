extends CanvasLayer
## 名次的单一排序入口：实时 HUD 与最终成绩表使用相同口径。

var _player: VehicleBody3D = null
var _track: Node3D = null
var _opponents: Array = []
var _finished: Dictionary = {}
var _player_initial_progress := 0.0
var _rank_label: Label = null
var _notice_label: Label = null
var _sample_time := 0.0
var _notice_time := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rank_label = Label.new()
	_rank_label.name = "RankLabel"
	_rank_label.offset_left = 30.0
	_rank_label.offset_top = 246.0
	_rank_label.offset_right = 360.0
	_rank_label.offset_bottom = 280.0
	_rank_label.add_theme_font_size_override("font_size", 25)
	_rank_label.add_theme_color_override("font_color", Color.WHITE)
	_rank_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_rank_label.add_theme_constant_override("outline_size", 4)
	_rank_label.text = "准备"
	add_child(_rank_label)
	_notice_label = Label.new()
	_notice_label.name = "AiFinishNotice"
	_notice_label.offset_left = 30.0
	_notice_label.offset_top = 280.0
	_notice_label.offset_right = 440.0
	_notice_label.offset_bottom = 314.0
	_notice_label.add_theme_font_size_override("font_size", 23)
	_notice_label.add_theme_color_override("font_color", Color.WHITE)
	_notice_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_notice_label.add_theme_constant_override("outline_size", 4)
	_notice_label.visible = false
	add_child(_notice_label)


func _process(delta: float) -> void:
	if _notice_time > 0.0:
		_notice_time = maxf(0.0, _notice_time - delta)
		_notice_label.visible = _notice_time > 0.0
	if _rank_label == null:
		return
	if GameState.phase_name() == "LOADING" or GameState.phase_name() == "COUNTDOWN":
		_rank_label.text = "准备"
		return
	if _opponents.is_empty():
		_rank_label.text = "练习"
		return
	if GameState.phase_name() != "RACING":
		return
	_sample_time += delta
	if _sample_time < 0.25:
		return
	_sample_time = 0.0
	var rows := standings()
	for row in rows:
		if row.get("id") == "player":
			var rank := int(row.get("rank", 1))
			var tied := false
			for other in rows:
				if other.get("id") != "player" and int(other.get("rank", 0)) == rank:
					tied = true
					break
			_rank_label.text = ("并列第 %d / %d" if tied else "名次 %d / %d") % [rank, rows.size()]
			break


func setup(player: VehicleBody3D, track: Node3D, opponents: Array) -> void:
	_player = player
	_track = track
	_opponents = opponents
	_player_initial_progress = _raw_player_progress()


func record_finish(car: VehicleBody3D, laps: int) -> bool:
	var id := car.get_instance_id()
	if _finished.has(id):
		return false
	_finished[id] = {"frame": Engine.get_physics_frames(), "laps": laps,
		"total": GameState.race_total_time()}
	if car != _player:
		# 车仍参与地面碰撞并继续由原 AI 控制；只移除车辆层的双向碰撞。
		car.set_collision_layer_value(2, false)
		car.set_collision_mask_value(2, false)
		if _notice_label != null:
			var index := _opponents.find(car) + 1
			_notice_label.text = "AI#%d 已完赛" % index
			_notice_label.visible = true
			_notice_time = 3.0
	return true


func standings() -> Array:
	if _player == null:
		return []
	var entries: Array = [_entry(_player, "player", "玩家", player_progress())]
	for i in range(_opponents.size()):
		var ai: VehicleBody3D = _opponents[i]
		var progress := float(ai.call("progress")) if ai.has_method("progress") else 0.0
		if is_nan(progress) or is_inf(progress):
			progress = 0.0
		entries.append(_entry(ai, "ai%d" % (i + 1), "AI#%d" % (i + 1), maxf(0.0, progress)))
	return rank_entries(entries)


func player_progress() -> float:
	return maxf(_player_initial_progress, _raw_player_progress())


func _raw_player_progress() -> float:
	if _player == null or _track == null:
		return 0.0
	var length := maxf(1.0, float(_track.call("road_length")))
	var nearest: Dictionary = _track.call("nearest_on_centerline", _player.global_position, -1.0)
	var arc := float(nearest.get("arc", 0.0))
	if is_nan(arc) or is_inf(arc):
		return 0.0
	var crossings := int(_player.get("laps_done"))
	if _player.has_method("current_lap_time") and float(_player.call("current_lap_time")) > 0.0:
		crossings += 1
	return float(crossings) * length + clampf(arc, 0.0, length)


func _entry(car: VehicleBody3D, id: String, label: String, progress: float) -> Dictionary:
	var finish: Dictionary = _finished.get(car.get_instance_id(), {})
	var laps := 0
	if car.has_method("laps_done"):
		laps = int(car.call("laps_done"))
	else:
		var value: Variant = car.get("laps_done")
		if value is int:
			laps = value
	if finish.has("laps"):
		laps = int(finish["laps"])
	return {"id": id, "label": label, "progress": progress,
		"finished": not finish.is_empty(), "finish_frame": int(finish.get("frame", -1)),
		"laps": laps,
		"total": float(finish.get("total", 0.0))}


func rank_entries(entries: Array) -> Array:
	var ranked: Array = entries.duplicate(true)
	ranked.sort_custom(_precedes)
	for i in range(ranked.size()):
		var rank := i + 1
		if i > 0 and _same_position(ranked[i - 1], ranked[i]):
			rank = int(ranked[i - 1]["rank"])
		ranked[i]["rank"] = rank
	return ranked


func player_outcome(ranked: Array) -> String:
	if ranked.size() <= 1:
		return "practice"
	var player_rank := 0
	var leaders := 0
	for entry in ranked:
		if int(entry.get("rank", 0)) == 1:
			leaders += 1
		if String(entry.get("id", "")) == "player":
			player_rank = int(entry.get("rank", 0))
	if player_rank <= 0:
		return ""
	if player_rank > 1:
		return "lose"
	return "tie" if leaders > 1 else "win"


func _precedes(a: Dictionary, b: Dictionary) -> bool:
	var a_done := bool(a.get("finished", false))
	var b_done := bool(b.get("finished", false))
	if a_done != b_done:
		return a_done
	if a_done:
		return int(a.get("finish_frame", -1)) < int(b.get("finish_frame", -1))
	return float(a.get("progress", 0.0)) > float(b.get("progress", 0.0))


func _same_position(a: Dictionary, b: Dictionary) -> bool:
	if bool(a.get("finished", false)) != bool(b.get("finished", false)):
		return false
	if bool(a.get("finished", false)):
		return int(a.get("finish_frame", -1)) == int(b.get("finish_frame", -1))
	return float(a.get("progress", 0.0)) == float(b.get("progress", 0.0))
