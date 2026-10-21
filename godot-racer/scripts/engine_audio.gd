extends RefCounted
## 占位引擎声：没挂音频文件时，用 AudioStreamGenerator 实时合成一个能出声的音源。
##
## 2026-10-12 SPLIT-ENV-002：从 scenes/main.gd 整块拆出，**纯迁移、行为零变化** ——
## 逻辑、数值常量、print 文案全部原样搬入，没有第二份实现。
## 结构变化仅两类：① 原先直接读 Main 场景成员（_car）的地方改为**参数传入**；
## ② 原先散在 Main 上的流式缓冲状态（playback / mix_rate / phase / frames_pushed /
## rng）收为本模块的实例状态 —— main.gd 每场景持一个实例，本模块不反向持有场景。
##
## ⚠ 为什么没有 class_name（与 racing_line.gd / environment.gd 同一约定）：
##   本项目的验收闸门（parse-check / run-check / run-all-checks）在**无编辑器**环境里
##   跑 Godot，而 class_name 的全局注册表（.godot/global_script_class_cache.cfg）
##   **只有编辑器会重建**。2026-10-12 实测：新增 class_name 后 --check-only 与游戏
##   运行双双报 `Identifier "X" not declared in the current scope`。因此消费方一律用
##   `const X := preload("res://scripts/engine_audio.gd")` 引用本模块，
##   不依赖全局类缓存（详见 environment.gd 文件头）。
##
## **AudioStreamGenerator 是流式的**。原来的写法只在 _ready 里灌一次缓冲，
## 那 0.5 秒播完就再也没有数据了 —— 表现就是"刚进去有一声轰鸣，几秒后彻底静音"。
## 现在改成每帧调用 tick() 续填（见 tick / _fill_buffer）。
##
## 底噪基频（怠速）。车体的 pitch_scale 会在这个基础上整体升降。
const BASE_HZ := 60.0

# 流式缓冲状态（每个实例一份，随场景创建）
var _playback: AudioStreamGeneratorPlayback = null
var _mix_rate := 22050.0
var _phase := 0.0
## 累计推送帧数。截图诊断会打印它（应远大于单个缓冲 0.5s×22050≈11025，
## 说明是流式续填而非一次灌满）。
var frames_pushed := 0
var _rng := RandomNumberGenerator.new()


## 没有引擎音频文件时，用生成器合成一个能出声的占位音源。
func setup(car: Node) -> void:
	var player: AudioStreamPlayer3D = car.get_node_or_null("EngineSound")
	if player == null:
		return
	if player.stream is AudioStreamGenerator:
		var gen: AudioStreamGenerator = player.stream
		_mix_rate = gen.mix_rate
		_playback = player.get_stream_playback()
		if _playback == null:
			return
		# 在音源资源销毁前停止播放、交还回执；旧诊断引用不能续填离树音源。
		var cleanup := _release_playback.bind(player)
		if not player.tree_exiting.is_connected(cleanup):
			player.tree_exiting.connect(cleanup, CONNECT_ONE_SHOT)
		_rng.seed = 20240517
		_fill_buffer()
		print("[main] 已启用占位引擎声（Generator 流式合成，每帧续填缓冲）。想要真实轰鸣请给 EngineSound.stream 换 wav")


func _release_playback(player: AudioStreamPlayer3D) -> void:
	player.stop()
	_playback = null


## 每帧调用（main.gd 的 _process）：缓冲区续满，就不会见底。
func tick() -> void:
	if _playback == null:
		return
	_fill_buffer()


## 把当前所有空位填满：低频锯齿波（模拟气缸爆发）+ 一点噪声。
## 每帧调用，缓冲区就不会见底。
func _fill_buffer() -> void:
	var frames := _playback.get_frames_available()
	if frames <= 0:
		return
	for i in frames:
		_phase += BASE_HZ / _mix_rate
		if _phase >= 1.0:
			_phase -= 1.0
		var saw := _phase * 2.0 - 1.0
		var noise := _rng.randf_range(-0.15, 0.15)
		var sample := clampf(saw * 0.35 + noise, -1.0, 1.0)
		_playback.push_frame(Vector2(sample, sample))
	frames_pushed += frames
