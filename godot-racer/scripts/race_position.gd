extends CanvasLayer
## 名次的单一排序入口：实时 HUD 与最终成绩表使用相同口径。

var _player: VehicleBody3D = null
var human_opponents := false
var online_slot := -1
var online_exit_requested: Callable
var online_ranks: Array = []
var _track: Node3D = null
var _opponents: Array = []
var _finished: Dictionary = {}
var _player_initial_progress := 0.0
var _rank_label: Label = null
var _notice_label: Label = null
var _recovery_label: Label
var _sample_time := 0.0
var _notice_time := 0.0
var _rank_caption: Label = null
var _pause_hint: Label = null
var _pause_button: Button = null
const Ui := preload("res://scripts/ui_theme.gd")
const RaceLaps := preload("res://scripts/race_laps.gd")

class PauseIcon extends Control:
	func _draw() -> void:
		for x in [0, 9]:
			draw_rect(Rect2(x, 0, 4, 18), Ui.TEXT)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var font := Ui.ui_font
	Ui.panel(self, "RankPanel", Rect2(946, 24, 220, 58), Ui.RACE_EDGE, Ui.RACE_SURFACE)
	_rank_caption = Ui.label(self, "RankCaption", "赛事", 18, Ui.TEXT)
	_rank_label = Ui.label(self, "RankLabel", "准备", 20, Ui.TEXT)
	_rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	Ui.place(_rank_caption, Rect2(952, 35, 90, 35))
	Ui.place(_rank_label, Rect2(1044, 26, 116, 50))
	_pause_button = Button.new()
	_pause_button.name = "PauseButton"
	_pause_button.focus_mode = Control.FOCUS_NONE
	_pause_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_pause_button.tooltip_text = "暂停比赛（Esc / 手柄菜单键）"
	Ui.place(_pause_button, Rect2(1178, 24, 164, 58))
	var fill := Ui.RACE_SURFACE
	_pause_button.add_theme_stylebox_override("normal", Ui.box(fill, Ui.RACE_EDGE, 1, 0))
	_pause_button.add_theme_stylebox_override("hover", Ui.box(fill.lightened(0.12), Ui.TEXT, 1, 0))
	_pause_button.add_theme_stylebox_override("pressed", Ui.box(fill.lightened(0.18), Ui.RED, 1, 0))
	_pause_button.add_theme_stylebox_override("disabled", Ui.box(fill, Ui.RACE_EDGE, 1, 0))
	_pause_button.pressed.connect(_pause_pressed)
	add_child(_pause_button)
	_pause_button.visible = online_slot < 0 or online_exit_requested.is_valid()
	var pause_icon := PauseIcon.new()
	pause_icon.name = "PauseIcon"
	pause_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.place(pause_icon, Rect2(16, 20, 14, 18))
	_pause_button.add_child(pause_icon)
	var pause_caption := Ui.label(_pause_button, "PauseCaption", "暂停", 18, Ui.TEXT)
	Ui.place(pause_caption, Rect2(35, 13, 74, 32))
	_pause_hint = Ui.label(_pause_button, "PauseHint", "Esc", 14, Ui.MUTED)
	_pause_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(_pause_hint, Rect2(108, 16, 50, 26))
	if online_slot >= 0:
		pause_icon.hide()
		_pause_hint.hide()
		pause_caption.text = tr("离开比赛")
		pause_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		Ui.place(pause_caption, Rect2(8, 0, 148, 58))
		_pause_button.tooltip_text = tr("离开比赛")
	_notice_label = Ui.label(self, "AiFinishNotice", "", 18, Ui.TEXT)
	Ui.place(_notice_label, Rect2(946, 90, 396, 31))
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_notice_label.add_theme_color_override("font_outline_color", Color(0.02, 0.04, 0.08))
	_notice_label.add_theme_constant_override("outline_size", 4)
	_notice_label.visible = false
	if online_slot >= 0:
		_recovery_label = Ui.label(self, "RecoveryNotice", "", 18, Ui.TEXT)
		Ui.place(_recovery_label, Rect2(790, 122, 552, 31))
		_recovery_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_recovery_label.add_theme_color_override("font_outline_color", Color(0.02, 0.04, 0.08))
		_recovery_label.add_theme_constant_override("outline_size", 4)
		_recovery_label.hide()
	for label in [_rank_caption, _rank_label, pause_caption, _pause_hint, _notice_label]:
		label.add_theme_font_override("font", font)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	get_viewport().size_changed.connect(_fit_rank_view)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_on_joy_connection_changed(0, false)
	_fit_rank_view()


func _fit_rank_view() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	var factor := minf(viewport_size.x / Ui.BASE_SIZE.x, viewport_size.y / Ui.BASE_SIZE.y)
	transform = Transform2D(0.0, Vector2.ONE * factor, 0.0, (viewport_size - Ui.BASE_SIZE * factor) * 0.5)


func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	_pause_hint.text = "Esc" if Input.get_connected_joypads().is_empty() else "菜单"


func _pause_pressed() -> void:
	if online_slot >= 0:
		if online_exit_requested.is_valid(): online_exit_requested.call()
		return
	get_parent().get_node("PauseMenu").pause()


func _process(delta: float) -> void:
	_pause_button.disabled = GameState.phase_name() != "RACING"
	if _notice_time > 0.0:
		_notice_time = maxf(0.0, _notice_time - delta)
		_notice_label.visible = _notice_time > 0.0
	if _rank_label == null:
		return
	if GameState.phase_name() == "LOADING" or GameState.phase_name() == "COUNTDOWN":
		_rank_caption.text = "赛事"
		_rank_label.text = "准备"
		return
	if _opponents.is_empty():
		_rank_caption.text = "模式"
		_rank_label.text = "无限" if GameState.endless_mode else "练习"
		return
	if GameState.phase_name() != "RACING":
		return
	_sample_time += delta
	if _sample_time < 0.25:
		return
	_sample_time = 0.0
	if online_slot == 1:
		if online_ranks.size() == 2:
			_rank_caption.text = "并列" if online_ranks[0] == online_ranks[1] else "名次"
			_rank_label.text = "%d / 2" % int(online_ranks[1])
		else:
			_rank_caption.text = "名次"
			_rank_label.text = "— / 2"
		return
	var rows := standings()
	for row in rows:
		if row.get("id") == "player":
			var rank := int(row.get("rank", 1))
			var tied := false
			for other in rows:
				if other.get("id") != "player" and int(other.get("rank", 0)) == rank:
					tied = true
					break
			_rank_caption.text = "并列" if tied else "名次"
			_rank_label.text = "%d / %d" % [rank, rows.size()]
			break


func show_online_finish_waiting() -> void:
	_notice_time = 0.0
	_notice_label.text = tr("已完赛，等待另一位车手")
	_notice_label.show()


func show_online_recovery(message: String, slot: int) -> void:
	_recovery_label.visible = not message.is_empty()
	_recovery_label.text = tr(message)
	if not message.is_empty() and slot == 1:
		_recovery_label.text += " · " + tr("成绩待房主确认")


func setup(player: VehicleBody3D, track: Node3D, opponents: Array) -> void:
	_player = player
	_track = track
	_opponents = opponents
	_player_initial_progress = _raw_player_progress()


func record_finish(car: VehicleBody3D, laps: int) -> bool:
	if GameState.phase != GameState.Phase.RACING or (car != _player and car not in _opponents):
		return false
	var target: int = car.laps_target
	if target <= 0 or laps < target: return false
	var id := car.get_instance_id()
	if _finished.has(id):
		return false
	_finished[id] = {"frame": Engine.get_physics_frames(), "laps": laps,
		"total": GameState.race_total_time(), "last":car.lap_last, "best":car.lap_best,
		"lap_times":car.lap_times.duplicate()}
	if car != _player:
		# 车仍参与地面碰撞并继续由原 AI 控制；只移除车辆层的双向碰撞。
		car.set_collision_layer_value(2, false)
		car.set_collision_mask_value(2, false)
		if _notice_label != null and (online_slot < 0 or not is_finished(_player)):
			var index := _opponents.find(car) + 1
			_notice_label.text = (tr("P%d 已完赛") if human_opponents else tr("AI#%d 已完赛")) % (index + 1 if human_opponents else index)
			_notice_label.visible = true
			_notice_time = 3.0
	return true


func standings() -> Array:
	if _player == null:
		return []
	var entries: Array = [_entry(_player, "player", "P1" if human_opponents else tr("玩家"), player_progress())]
	for i in range(_opponents.size()):
		var ai: VehicleBody3D = _opponents[i]
		var progress := _raw_player_progress(ai) if human_opponents else (float(ai.call("progress")) if ai.has_method("progress") else 0.0)
		if is_nan(progress) or is_inf(progress):
			progress = 0.0
		entries.append(_entry(ai, "p%d" % (i + 2) if human_opponents else "ai%d" % (i + 1), "P%d" % (i + 2) if human_opponents else "AI#%d" % (i + 1), maxf(_player_initial_progress if human_opponents else 0.0, progress)))
	return rank_entries(entries)


func is_finished(car: Node) -> bool:
	return car != null and _finished.has(car.get_instance_id())


func player_progress() -> float:
	return maxf(_player_initial_progress, _raw_player_progress())


func _raw_player_progress(car: VehicleBody3D = null) -> float:
	if car == null: car = _player
	if _player == null or _track == null:
		return 0.0
	var length := maxf(1.0, float(_track.call("road_length")))
	var nearest: Dictionary = _track.call("nearest_on_centerline", car.global_position, -1.0)
	var arc := float(nearest.get("arc", 0.0))
	if is_nan(arc) or is_inf(arc):
		return 0.0
	var value: Variant = car.get("laps_done")
	# 2026-10-19（R6 修订 D1）：GO 锚定圈钟后 current_lap_time() 从出发起就 >0，
	# 不能再当压线判据（否则玩家进度瞬间多出整整一圈、名次错乱）—— 改读压线标志。
	# ⚠ 不用 bool(car.get(...))：GDScript 的 bool() 构造器不接受 null（测试里的
	# 裸 VehicleBody3D 没有该字段，get() 返回 null 会直接报构造器错误）。== true 安全降级。
	return RaceLaps.progress(value if value is int else 0, car.get("start_line_crossed") == true, arc, length)


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
		"laps": laps, "total":float(finish.get("total", 0.0)),
		"last":float(finish.get("last", 0.0)), "best":float(finish.get("best", 0.0)),
		"lap_times":finish.get("lap_times", [])}


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
	for entry: Dictionary in ranked:
		if String(entry.get("id", "")) == "player":
			return GameState.race_outcome(ranked, int(entry.get("rank", 0)))
	return GameState.race_outcome(ranked, 0)


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
