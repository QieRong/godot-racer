extends SceneTree
## 玩家音频契约；隔离音量包络，不作为真实行驶或真人听感验收。
const EngineAudio := preload("res://scripts/engine_audio.gd")
const AudioExit := preload("res://tests/audio_exit_probe.gd")
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("PLAYER_ENGINE_MIX_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	var car: VehicleBody3D = load("res://scenes/race_car.tscn").instantiate()
	car.freeze = true
	root.add_child(car)
	car.set_physics_process(false)
	var player: AudioStreamPlayer3D = car.get_node("EngineSound")
	var audio := EngineAudio.new()
	audio.setup(car)
	check(player.attenuation_model == AudioStreamPlayer3D.ATTENUATION_DISABLED, "仅本车取消距离衰减")
	check(is_equal_approx(player.panning_strength, 0.15), "本车弱声像0.15（浮点属性近似相等）")
	check(player.attenuation_filter_cutoff_hz >= 20500.0, "车头外视角保留室外高频")
	check(player.doppler_tracking == AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED, "切镜不引入本车多普勒")
	check(player.bus == &"SFX", "沿用SFX总线")
	car.set("_driving", false)
	for i in range(360): car.call("_update_engine_sound", 1.0/120.0)
	check(absf(player.volume_db+20.0) < 0.01, "静止低负载保留-20dB怠速")
	var idle_pitch := player.pitch_scale
	car.set("_driving", true)
	var before := player.volume_db
	car.call("_update_engine_sound", 1.0/120.0)
	check(player.volume_db > before and player.volume_db < 1.5
		and is_equal_approx((player.volume_db-before)/(1.5-before), 4.0/120.0), "踩油门保留原4/s渐变")
	for i in range(360): car.call("_update_engine_sound", 1.0/120.0)
	check(absf(player.volume_db-1.5) < 0.01, "全油门+1.5dB补偿原距离增益，峰值另以录音验证")
	check(player.pitch_scale > idle_pitch, "保留负载音高反馈")
	car.set("_driving", false)
	for i in range(360): car.call("_update_engine_sound", 1.0/120.0)
	check(absf(player.volume_db+20.0) < 0.01, "收油回可辨怠速")
	var camera: Camera3D = load("res://scripts/chase_camera.gd").new()
	camera.target = car
	camera.toast_enabled = false
	root.add_child(camera)
	var receipt := AudioExit.capture(player)
	var pitch := player.pitch_scale
	var db := player.volume_db
	for mode in range(3):
		camera.call("set_view_mode", mode)
		check(AudioExit.capture(player) == receipt and player.pitch_scale == pitch and player.volume_db == db,
			"视角%d不重播或争写本车音高/音量" % mode)
	camera.free()
	car.free()
	check(await AudioExit.wait_released(self, receipt), "本车音频服务实际回收")
	print("PLAYER_ENGINE_MIX_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
