extends Node
## 菜单BGM单实例；由菜单放在持久GameState下，依赖经setup注入。
## 音频偏好独立音频字段，先load再save保留display等既有设置。

signal enabled_changed(value: bool)

const TRACK := preload("res://assets/audio/music/音乐-菜单-霓虹展台.ogg")
const LEVEL_DB := -22.0
const FADE_SECONDS := 0.35

var enabled := true
var _state: Node
var _player: AudioStreamPlayer
var _gain := 0.0
var _menu_context := true
var _resume_position := 0.0
var _closing := false
var _stream_id := 0
var _playback_ids: Array[int] = []


func setup(state: Node) -> void:
	_state = state


func _ready() -> void:
	name = "MenuMusic"
	process_mode = Node.PROCESS_MODE_ALWAYS
	var settings := ConfigFile.new()
	if settings.load(_state.get("settings_path")) == OK:
		var saved: Variant = settings.get_value("audio", "menu_bgm_enabled", true)
		enabled = saved if saved is bool else true
	_player = AudioStreamPlayer.new()
	_player.name = "MenuBgmPlayer"
	var track := TRACK.duplicate() as AudioStreamOggVorbis
	track.loop = true
	_player.stream = track
	_stream_id = track.get_instance_id()
	_player.bus = "BGM"
	_player.volume_db = -80.0
	add_child(_player)


func set_enabled(value: bool) -> void:
	if _closing or enabled == value:
		return
	enabled = value
	var settings := ConfigFile.new()
	settings.load(_state.get("settings_path"))
	settings.set_value("audio", "menu_bgm_enabled", enabled)
	var result := settings.save(_state.get("settings_path"))
	if result != OK:
		push_warning("BGM设置保存失败：%d" % result)
	if not enabled:
		_gain = 0.0
		_resume_position = 0.0
		_stop_playback()
	enabled_changed.emit(enabled)


func _process(delta: float) -> void:
	if _closing:
		return
	var phase: String = _state.call("phase_name")
	# 提前停播给音频服务释放解码引用；取消退出后从原进度恢复。
	if phase == "EXIT_CONFIRM":
		if _player.playing:
			_resume_position = _player.get_playback_position()
			_stop_playback()
		_gain = 0.0
		return
	_menu_context = phase == "MENU"
	var audible := enabled and _menu_context
	if audible and not _player.playing:
		_player.play(_resume_position)
		_resume_position = 0.0
	_gain = move_toward(_gain, 1.0 if audible else 0.0, delta / FADE_SECONDS)
	_player.volume_db = LEVEL_DB + linear_to_db(maxf(_gain, 0.001))
	if not audible and _gain <= 0.0 and _player.playing:
		_stop_playback()


func _exit_tree() -> void:
	# 析构只能发起清理；正常退出必须提前await shutdown_and_wait()。
	shutdown()


func shutdown() -> void:
	# 仅供退出/测试清理，不持久化关闭偏好。
	_closing = true
	set_process(false)
	if is_instance_valid(_player):
		_stop_playback()
		_player.stream = null


func _stop_playback() -> void:
	# stop后AudioServer仍可能持有解码器。保存ID而非强引用，含取消确认前的旧回执。
	_playback_ids = _playback_ids.filter(func(id: int) -> bool: return is_instance_id_valid(id))
	if _player.has_stream_playback():
		var id := _player.get_stream_playback().get_instance_id()
		if id not in _playback_ids:
			_playback_ids.append(id)
	_player.stop()


func shutdown_and_wait(timeout_ms: int = 2000) -> bool:
	shutdown()
	var started := Time.get_ticks_msec()
	var frames := 0
	while not _shutdown_released():
		if Time.get_ticks_msec() - started >= timeout_ms or not is_inside_tree():
			print("MENU_AUDIO_DRAIN_TIMEOUT frames=%d elapsed_ms=%d" % [
				frames, Time.get_ticks_msec() - started])
			return false
		await get_tree().process_frame
		frames += 1
	print("MENU_AUDIO_DRAIN_RELEASED frames=%d elapsed_ms=%d" % [
		frames, Time.get_ticks_msec() - started])
	return true


func _shutdown_released() -> bool:
	if _stream_id != 0 and is_instance_id_valid(_stream_id):
		return false
	for id in _playback_ids:
		if is_instance_id_valid(id):
			return false
	return true
