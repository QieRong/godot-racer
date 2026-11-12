extends Control
## PC 菜单的建房、搜码和场景切换。房间和比赛沿用现有控制器。

signal back_requested

const Ui := preload("res://scripts/ui_theme.gd")
const RoomState := preload("res://scripts/online_room_state.gd")
const RoomSession := preload("res://scripts/online_room_session.gd")
const RoomView := preload("res://scripts/online_room_view.gd")
const RaceLoader := preload("res://scripts/online_race_loader.gd")
const LEVEL := 1

var _entry: Control
var _create_button: Button
var _join_button: Button
var _back: Button
var _code: LineEdit
var _status: Label
var _room: Node
var _room_view: Control
var _loader: Node
var _backend: Node
var _dialog: ConfirmationDialog
var _leaving := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Ui.install(self)
	_entry = Control.new()
	add_child(_entry)
	_entry.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Ui.BACKGROUND
	_entry.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var stage := Ui.stage(_entry)
	Ui.brand(stage, Rect2(48, 24, 456, 70))
	Ui.place(Ui.label(stage, "OnlineTitle", "联机对战", 36), Rect2(388, 126, 600, 56))
	var track: LevelConfig = GameState.get_level(LEVEL)
	Ui.place(Ui.label(stage, "OnlineTrack", "%s · %s" % [tr(track.display_name), tr("双人两圈")], 20, Ui.MUTED),
		Rect2(388, 188, 600, 44))
	_create_button = Ui.button(stage, "OnlineCreate", "创建房间", Rect2(388, 266, 590, 60), Ui.RED)
	_create_button.pressed.connect(_open.bind(true))
	_code = LineEdit.new()
	_code.name = "OnlineCode"
	_code.placeholder_text = tr("输入 8 位房间码")
	_code.max_length = 16
	_code.add_theme_font_size_override("font_size", 22)
	stage.add_child(_code)
	Ui.place(_code, Rect2(388, 350, 384, 60))
	_code.text_submitted.connect(func(_text: String): _open(false))
	_join_button = Ui.button(stage, "OnlineJoin", "加入房间", Rect2(790, 350, 188, 60), Ui.SKY)
	_join_button.pressed.connect(_open.bind(false))
	_status = Ui.label(stage, "OnlineStatus", "", 18, Ui.MUTED)
	Ui.place(_status, Rect2(388, 434, 590, 94))
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_back = Ui.button(stage, "OnlineBack", "返回（Esc）", Rect2(48, 624, 230, 48), Ui.SKY)
	_back.pressed.connect(_back_or_leave)
	Ui.focus_ring([_create_button, _code, _join_button, _back])


func open() -> void:
	show()
	_status.text = ""
	_create_button.grab_focus()


func _open(host: bool) -> void:
	if _room != null: return
	var code := RoomState.normalize_code(_code.text) if not host else ""
	if not host and code.is_empty():
		_status.text = tr("请输入有效的 8 位房间码。")
		_code.grab_focus()
		return
	if _backend == null:
		_backend = GameState.get_node_or_null("OnlineEosRoom")
		if _backend == null and Engine.has_singleton("IEOS"):
			var script := load("res://scripts/online_eos_room.gd") as GDScript
			if script != null and script.can_instantiate():
				_backend = script.new()
				_backend.name = "OnlineEosRoom"
				GameState.add_child(_backend)
		if _backend == null:
			_status.text = tr("当前无法加载 Windows EOSG 联机组件。")
			return
	if not _backend.invite_changed.is_connected(_on_invite_changed):
		_backend.invite_changed.connect(_on_invite_changed)
		_backend.connection_status.connect(_on_status)
	_set_busy(true)
	_room = RoomSession.new()
	_room.name = "RoomSession"
	_room.setup_recovery(_backend)
	add_child(_room)
	_room.left_room.connect(_finish_room.bind(""), CONNECT_DEFERRED)
	_room.action_failed.connect(_on_room_failed)
	_room.room_changed.connect(_on_room_changed)
	_room.recovery_status.connect(_on_status)
	_loader = RaceLoader.new()
	_loader.name = "OnlineRaceLoader"
	add_child(_loader)
	_loader.setup(_room, get_parent())
	_loader.load_failed.connect(_finish_room, CONNECT_DEFERRED)
	var reason: String = await _backend.open_room(host, code)
	if _leaving: return
	if not reason.is_empty():
		await _finish_room(reason)
		return
	var state: RefCounted = _room.waiting_host_state() if host else RoomState.new()
	if _room.attach(_backend.peer, _backend.remote_peer_id, 0 if host else 1,
			state, _backend.nonce, _matches_rules) != OK or not _room.connected:
		await _finish_room("比赛连接未能接入房间。")
		return
	if host: _room_view.show_connection_status(tr("请核对规则并准备"))
	else: _show_room()


func _on_invite_changed(code: String) -> void:
	if _leaving: return
	if _room_view != null:
		_room.update_waiting_code(code)
		return
	var track: LevelConfig = GameState.get_level(LEVEL)
	var config := {"level_id": LEVEL, "combination": 0, "race_seed": randi() & 0x7fffffff,
		"speed_kmh": clampf(track.suggested_speed_kmh, 80, 240), "laps": 2, "collision": true}
	var variant: Dictionary = GameState.RaceVariants.make(track, config.race_seed, config.combination)
	config.rules_hash = variant.summary.signature
	var state := RoomState.new()
	state.create_room(code, config)
	_room.stage_host(state)
	_show_room()


func _show_room() -> void:
	var track: LevelConfig = GameState.get_level(LEVEL)
	_room_view = RoomView.new()
	_room_view.name = "OnlineRoomView"
	_room_view.configure(_room, preload("res://scripts/racing_style.gd"), {
		"title": track.display_name, "conditions": track.weather_label(),
		"preview": preload("res://assets/ui/tracks/level_2.png")})
	add_child(_room_view)
	_room_view.focus_actions()
	_entry.hide()


func _matches_rules(config: Dictionary) -> bool:
	if not RoomState.valid_config(config) or int(config.level_id) != LEVEL: return false
	var variant: Dictionary = GameState.RaceVariants.make(GameState.get_level(LEVEL),
		int(config.race_seed), int(config.combination))
	return variant.get("ok", false) and variant.summary.signature == config.rules_hash


func _on_status(message: String) -> void:
	_status.text = tr(message)
	if _room_view == null: return
	if not message.is_empty(): _room_view.show_connection_status(tr(message))
	elif _room.snapshot().get("phase") == "ROOM": _room_view.show_connection_status(tr("请核对规则并准备"))


func _on_room_changed(view: Dictionary) -> void:
	if _room_view == null: return
	if view.get("phase") == "LOADING" and _room_view.visible:
		_room_view.hide()
		GameState.show_loading("正在读取赛道资源")
	elif view.get("phase") == "ROOM":
		if _dialog != null: _dispose_dialog()
		_room_view.show()


func _on_room_failed(reason: String) -> void:
	if reason == "STALE_RULES": return
	_finish_room.call_deferred("联机连接已中断，请重新建房或加入。")


func _set_busy(busy: bool) -> void:
	_create_button.disabled = busy
	_join_button.disabled = busy
	_code.editable = not busy


func _back_or_leave() -> void:
	if _room != null:
		_finish_room("")
	elif not _leaving:
		hide()
		back_requested.emit()


func _finish_room(reason: String) -> void:
	if _leaving or _room == null: return
	_leaving = true
	if _dialog != null: _dispose_dialog()
	if _room.connected: await _room.leave_room()
	else: _room.detach()
	_loader.unload()
	if _room_view != null:
		_room_view.queue_free()
		_room_view = null
	_loader.queue_free()
	var closing_room := _room
	_entry.show()
	_status.text = tr("正在关闭 EOS 房间…")
	var closed: bool = await _backend.close_room()
	closing_room.queue_free()
	_room = null
	_loader = null
	_leaving = false
	_status.text = tr(reason) if closed else tr("EOS 房间关闭失败，请重新进入联机页后重试。")
	_set_busy(false)
	_create_button.grab_focus()


func close_for_quit() -> void:
	if _room != null:
		await _finish_room("")
		while _leaving: await get_tree().process_frame


func race_active() -> bool:
	return _room != null and _room.snapshot().get("phase", "ROOM") != "ROOM"


func request_race_exit(quit_game: bool) -> void:
	if _dialog != null: return
	_dialog = ConfirmationDialog.new()
	_dialog.title = tr("离开联机比赛")
	_dialog.dialog_text = tr("离开后将退出当前房间。")
	_dialog.ok_button_text = tr("离开")
	_dialog.cancel_button_text = tr("继续比赛")
	add_child(_dialog)
	_dialog.confirmed.connect(func():
		_dispose_dialog()
		if quit_game: GameState.quit_after_menu_audio()
		else: _finish_room(""))
	_dialog.canceled.connect(_dispose_dialog)
	_dialog.popup_centered(Vector2i(460, 168))


func _dispose_dialog() -> void:
	_dialog.queue_free()
	_dialog = null


func _unhandled_input(event: InputEvent) -> void:
	if not visible or GameState.phase == GameState.Phase.EXIT_CONFIRM or not event.is_action_pressed("ui_cancel"):
		return
	if race_active():
		get_viewport().set_input_as_handled()
		request_race_exit(false)
	elif _entry.visible:
		get_viewport().set_input_as_handled()
		_back_or_leave()
