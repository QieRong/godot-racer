extends SceneTree
## EXIT-AUDIO-OWNER：独立弱引用契约，不通过故意访问悬空指针制造崩溃。
## 播放对象可能仍由AudioServer持有，必须在其整个生命周期保护生成器。

const EngineAudio := preload("res://scripts/engine_audio.gd")
var _passed := 0
var _failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
	print("AUDIO_OWNER %s %s" % ["PASS" if ok else "FAIL", message])


func _run() -> void:
	for iteration in range(3):
		var car := Node3D.new()
		var player := AudioStreamPlayer3D.new()
		player.name = "EngineSound"
		player.stream = AudioStreamGenerator.new()
		var source: WeakRef = weakref(player.stream)
		car.add_child(player)
		root.add_child(car)
		player.play()
		var audio := EngineAudio.new()
		audio.setup(car)
		var playback: AudioStreamGeneratorPlayback = player.get_stream_playback()
		_check(playback != null, "round %d real generator playback" % iteration)
		# 模拟音频服务/诊断仍持有回执，音源节点则已离树销毁。
		car.free()
		_check(audio.get("_playback") == null, "round %d module released its receipt" % iteration)
		_check(source.get_ref() != null,
			"round %d live playback retains generator after player destruction" % iteration)
		playback = null
		for i in range(120):
			await process_frame
			if source.get_ref() == null:
				break
		_check(source.get_ref() == null,
			"round %d generator reclaimed after last playback receipt" % iteration)
	print("AUDIO_OWNER_SUMMARY PASS=%d FAIL=%d" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
