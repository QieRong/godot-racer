extends Node3D
## 主场景装配：把检查点信号接到 HUD，并给引擎声临时合成一个音源
##
## 这样设计是为了让你不用手动连线就能跑起来：
##   - Track 下所有 Area3D（含 StartFinish）的 car_passed 自动连到 HUD
##   - EngineSound 若没挂音频流，就用 AudioStreamGenerator 实时合成引擎声，
##     你把 freesound 下的 engine loop 拖到 EngineSound.stream 后，这段会自动让位

@onready var _car: VehicleBody3D = $RaceCar
@onready var _hud: CanvasLayer = $HUD


func _ready() -> void:
	_connect_checkpoints()
	_setup_placeholder_engine_sound()


## 把所有检查点的 car_passed 信号接到 HUD 的 _on_car_passed
func _connect_checkpoints() -> void:
	var connected := 0
	for node in get_tree().get_nodes_in_group("checkpoints"):
		# 用 has_signal 判断，避免 node.get() 返回 Variant 触发类型推断告警
		if not node.has_signal("car_passed"):
			continue
		var cp := node as Area3D
		if cp == null:
			continue
		if not cp.car_passed.is_connected(_hud._on_car_passed):
			cp.car_passed.connect(_hud._on_car_passed)
			connected += 1
	print("[main] 已连接检查点数量: ", connected)


## 没有引擎音频文件时，用生成器合成一个能出声的占位音源
func _setup_placeholder_engine_sound() -> void:
	var player: AudioStreamPlayer3D = _car.get_node_or_null("EngineSound")
	if player == null:
		return
	if player.stream is AudioStreamGenerator:
		var gen: AudioStreamGenerator = player.stream
		var playback: AudioStreamGeneratorPlayback = player.get_stream_playback()
		if playback == null:
			return
		_fill_engine_buffer(playback, gen.mix_rate)
		print("[main] 已启用占位引擎声（用 Generator 合成）。想要真实轰鸣请给 EngineSound.stream 换 wav")


## 往生成器里灌一段低频锯齿波 + 噪声，循环播放形成"轰鸣"底噪
func _fill_engine_buffer(playback: AudioStreamGeneratorPlayback, mix_rate: float) -> void:
	var frames := playback.get_frames_available()
	var base_hz := 60.0
	var phase := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240517
	for i in frames:
		phase += base_hz / mix_rate
		if phase >= 1.0:
			phase -= 1.0
		# 锯齿波（模拟气缸爆发）+ 一点噪声
		var saw := phase * 2.0 - 1.0
		var noise := rng.randf_range(-0.15, 0.15)
		var sample := clampf(saw * 0.35 + noise, -1.0, 1.0)
		playback.push_frame(Vector2(sample, sample))
