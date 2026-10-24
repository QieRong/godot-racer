extends SceneTree
## 仅诊断真实菜单OGG；不加载菜单/展台，不保留音频资源强引用。

const MUSIC_PATH := "res://scripts/menu_music.gd"
const AudioExit := preload("res://tests/audio_exit_probe.gd")

class ProbeState:
	extends Node
	var settings_path := ""
	var phase_value := "MENU"
	func phase_name() -> String:
		return phase_value

var _mode := "shutdown"
var _tag := "probe"
var _driver := "WASAPI"
var _state: Node
var _music: Node
var _player: AudioStreamPlayer
var _stream_id := 0
var _playback_id := 0
var _held_stream: AudioStream
var _pass := 0
var _fail := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="): _mode = arg.get_slice("=", 1)
		if arg.begins_with("--tag="): _tag = arg.get_slice("=", 1)
		if arg.begins_with("--driver="): _driver = arg.get_slice("=", 1)
	call_deferred("_run")


func _check(ok: bool, detail: String) -> void:
	if ok: _pass += 1
	else: _fail += 1
	print("OGG_ASSERT %s %s" % ["PASS" if ok else "FAIL", detail])


func _run() -> void:
	_state = root.get_node("GameState") if _mode.begins_with("state_") else ProbeState.new()
	_state.settings_path = ProjectSettings.globalize_path(
		"res://../godot-logs/ogg-exit-20261024/%s-settings.cfg" % _tag)
	var settings := ConfigFile.new()
	settings.set_value("audio", "menu_bgm_enabled", true)
	_check(settings.save(_state.settings_path) == OK, "独立设置夹具可保存")
	if not _state.is_inside_tree(): root.add_child(_state)
	_music = load(MUSIC_PATH).new()
	_music.setup(_state)
	_state.add_child(_music)
	_player = _music.get("_player")
	_check(AudioServer.get_driver_name() == _driver, "实际音频驱动=" + AudioServer.get_driver_name())
	_check_stream()
	var deadline := Time.get_ticks_msec() + 1500
	while _player.get_playback_position() < 0.04 and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(_player.playing and _player.get_playback_position() >= 0.04, "音频线程已实际推进OGG播放")
	_capture_ids()
	_check(_stream_id != 0 and _playback_id != 0, "真实流及播放回执非零")
	_report("playing")
	if _mode.begins_with("state_"):
		root.tree_exiting.connect(_state_exit_finished)
		if _mode == "state_menu_cli":
			var menu: Control = load("res://scripts/menu.gd").new()
			menu.suppress_scene_change = true
			root.add_child(menu)
			menu.call("_shot_menu_after", 2)
			return
		if _mode == "state_timeout": _held_stream = _player.stream
		if _mode == "state_window" or _mode == "state_cli":
			root.close_requested.emit()
		else:
			_state.call("request_exit")
		if _mode != "state_cli":
			_check(_state.call("phase_name") == "EXIT_CONFIRM" and paused, "真实路由先进入退出确认")
			_state.call("confirm_exit")
			_state.call("cancel_exit")
			_check(_state.call("phase_name") == "EXIT_CONFIRM", "确认后的取消不能打断音频收尾")
			_state.call("confirm_exit")
		return
	if _mode in ["coordinated", "timeout", "rapid"]:
		await _coordinated()
		_finish()
		return
	if _mode == "tree_exit":
		_finish()
		return
	if _mode in ["confirm", "cancel"]:
		_state.phase_value = "EXIT_CONFIRM"
		paused = true
		_music.call("_process", 0.0)
		_check(not _player.playing, "退出确认阶段同步停播")
		_report("exit_confirm")
		if _mode == "confirm":
			_finish()
			return
		_check(await AudioExit.wait_released(self, _playback_id), "取消前旧播放回执已回收")
		_state.phase_value = "MENU"
		paused = false
		_music.call("_process", 1.0)
		_check(_player.playing, "取消退出恢复真实播放")
		_capture_ids()
	if _mode == "free":
		_music.free()
		_music = null
		_player = null
	else:
		_music.call("shutdown")
		_check(not _music.is_processing() and not _player.playing and _player.stream == null,
			"shutdown禁用续播并断开流")
	_report("cleanup_requested")
	if _mode == "legacy_timer":
		await create_timer(0.2, true, false, true).timeout
		_report("legacy_timer_finished")
		_check(AudioExit.released(_playback_id) and AudioExit.released(_stream_id),
			"原0.2秒等待结束时资源已回收")
		_finish()
		return
	var ids: Array[int] = [_playback_id, _stream_id]
	_check(await AudioExit.wait_all_released(self, ids), "退出前播放回执及复制流实际回收")
	_report("cleanup_observed")
	_finish()


func _check_stream() -> void:
	_check(_player.stream is AudioStreamOggVorbis and _player.stream.loop, "真实循环OGG流")


func _coordinated() -> void:
	var supported := _music.has_method("shutdown_and_wait")
	_check(supported, "生产音乐模块提供实际回收关闭接口")
	if not supported:
		_music.call("shutdown")
		var ids: Array[int] = [_playback_id, _stream_id]
		await AudioExit.wait_all_released(self, ids)
		return
	paused = true
	var retired: Array[int] = [_playback_id]
	if _mode == "rapid":
		for i in range(4):
			_state.phase_value = "EXIT_CONFIRM"
			_music.call("_process", 0.0)
			_state.phase_value = "MENU"
			_music.call("_process", 1.0)
			retired.append(AudioExit.capture(_player))
	if _mode == "timeout":
		# 刻意持有自有复制流，证明超时不能冒充成功；随后释放并重试。
		var held: AudioStream = _player.stream
		_check(not await _music.call("shutdown_and_wait", 0), "外部持有流时超时返回失败")
		held = null
	_check(await _music.call("shutdown_and_wait"), "暂停或慢帧下等待实际回收")
	_check(not is_instance_id_valid(_playback_id) and not is_instance_id_valid(_stream_id),
		"成功返回前真实回执和复制流均已销毁")
	for id in retired:
		_check(id != 0 and not is_instance_id_valid(id), "每个停止或重播产生的旧回执已回收")
	_music.call("shutdown")
	_check(await _music.call("shutdown_and_wait", 0), "重复关闭幂等且已回收时立即成功")
	_music.call("_process", 1.0)
	_check(not _player.playing and _player.stream == null, "关闭后不能被后续菜单处理恢复播放")
	var settings := ConfigFile.new()
	settings.load(_state.settings_path)
	_check(settings.get_value("audio", "menu_bgm_enabled", false), "关闭不改写用户音乐偏好")
	_report("coordinated_observed")


func _state_exit_finished() -> void:
	if _mode == "state_timeout":
		_check(is_instance_id_valid(_stream_id), "刻意持有的流触发真实退出超时失败分支")
		_held_stream = null
	_check(not is_instance_id_valid(_playback_id) and not is_instance_id_valid(_stream_id),
		"真实退出路由在树析构前已回收音乐资源")
	print("OGG_COMPLETE MODE=%s PASS=%d FAIL=%d" % [_mode, _pass, _fail])


func _capture_ids() -> void:
	# 同步辅助函数返回后临时引用已释放，不能让诊断本身延长资源寿命。
	_stream_id = _player.stream.get_instance_id()
	_playback_id = AudioExit.capture(_player)


func _report(stage: String) -> void:
	print("OGG_STATE ", JSON.stringify({"stage": stage, "mode": _mode,
		"stream_id": _stream_id, "stream_alive": is_instance_id_valid(_stream_id),
		"playback_id": _playback_id, "playback_alive": is_instance_id_valid(_playback_id),
		"player_alive": is_instance_valid(_player), "mix_since": AudioServer.get_time_since_last_mix()}))


func _finish() -> void:
	print("OGG_COMPLETE MODE=%s PASS=%d FAIL=%d" % [_mode, _pass, _fail])
	quit(0 if _fail == 0 else 1)
