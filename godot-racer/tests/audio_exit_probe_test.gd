extends SceneTree
## 真实Generator + 真实雨声音源；不装配赛道，不接Quick，不用固定等待。

const EngineAudio := preload("res://scripts/engine_audio.gd")
const EnvironmentAudio := preload("res://scripts/environment.gd")
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var _passed := 0
var _failed := 0


func _initialize() -> void:
	create_timer(25.0, true).timeout.connect(func():
		print("AUDIO_EXIT_TIMEOUT")
		quit(2))
	call_deferred("_run")


func _check(ok: bool, label: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
	print("AUDIO_EXIT %s %s" % ["PASS" if ok else "FAIL", label])


func _run() -> void:
	_check(not AudioExit.released(0), "missing receipt is not successful reclamation")
	_check(not await AudioExit.wait_all_released(self, []), "empty capture cannot pass")
	for iteration in range(3):
		var car := Node3D.new()
		var player := AudioStreamPlayer3D.new()
		player.name = "EngineSound"
		player.stream = AudioStreamGenerator.new()
		car.add_child(player)
		root.add_child(car)
		player.play()
		var engine := EngineAudio.new()
		engine.setup(car)
		var environment := EnvironmentAudio.new()
		environment.apply_weather_audio(load("res://data/levels/level_3.tres"), car)
		await physics_frame
		await process_frame
		var ids := AudioExit.capture_tree(car)
		_check(ids.size() == 2, "round %d captures engine and real rain receipts" % iteration)
		_check(ids.size() == 2 and not AudioExit.released(ids[0]),
			"round %d live receipt remains observable" % iteration)
		car.free()
		environment.release()
		_check(engine.get("_playback") == null, "round %d module receipt returned" % iteration)
		_check(await AudioExit.wait_all_released(self, ids), "round %d both server receipts reclaimed" % iteration)
	print("AUDIO_EXIT_SUMMARY PASS=%d FAIL=%d" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)
