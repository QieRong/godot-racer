extends SceneTree
## P0-AUDIO-LIFECYCLE：场景离树时，先停止生成器再释放续填回执。
## 不改音色、输入响应或发车规则；不以此测试宣称历史访问冲突已修复。

const EngineAudio := preload("res://scripts/engine_audio.gd")
var passed := 0
var failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var empty := Node3D.new()
	root.add_child(empty)
	var absent := EngineAudio.new()
	absent.setup(empty)
	absent.tick()
	_check(absent.get("_playback") == null, "缺少音源时保持安全空态")
	empty.queue_free()
	await process_frame
	# 保留模块引用，模拟截图/诊断尚持有旧场景模块的情况。
	# 模块存活不能让已经离树的音源继续播放或继续持有 playback。
	for iteration in range(3):
		var car := Node3D.new()
		var player := AudioStreamPlayer3D.new()
		player.name = "EngineSound"
		var generator := AudioStreamGenerator.new()
		generator.mix_rate = 22050.0
		player.stream = generator
		car.add_child(player)
		root.add_child(car)
		player.play()
		var audio := EngineAudio.new()
		audio.setup(car)
		_check(audio.get("_playback") != null, "第%d轮真实生成器已接入" % iteration)
		audio.tick()
		_check(int(audio.get("frames_pushed")) > 0, "第%d轮缓冲确实续填" % iteration)
		root.remove_child(car)
		_check(not player.playing, "第%d轮离树即停止播放" % iteration)
		_check(audio.get("_playback") == null, "第%d轮离树即释放模块回执" % iteration)
		var before := int(audio.get("frames_pushed"))
		audio.tick()
		_check(int(audio.get("frames_pushed")) == before, "第%d轮离树后不再续填" % iteration)
		car.free()
		await process_frame
		# 给音频服务处理 stop，不把音频线程仍在退场误记为模块引用残留。
		await create_timer(0.05).timeout
	print("CASES: %d PASS: %d FAIL: %d" % [passed + failed, passed, failed])
	print("ENGINE_AUDIO_LIFECYCLE_PASS" if failed == 0 else "ENGINE_AUDIO_LIFECYCLE_FAIL")
	quit(0 if failed == 0 else 1)


func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("PASS " + label)
	else:
		failed += 1
		printerr("FAIL " + label)
