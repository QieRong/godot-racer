extends SceneTree
## REL-STEP2C 音频**波形测量**（只给数据，不下结论）。
##
## 背景：red/green 那套只能证明"播放器在播、总线对、状态翻转对"，证明不了听感。
## 这里用 AudioEffectCapture 抓**真实波形**，把三个主观项变成可度量的原始数值：
##   ① 雨声 vs 引擎声的 RMS / 峰值（dBFS）与差值
##   ② 循环接缝处相邻样本最大跳变 vs 正常段最大跳变（咔哒声的物理表征）
##   ③ 暂停 / 恢复瞬间有没有样本突变到 ±1.0（爆音的物理表征）
##
## ⚠⚠ 必须跑**真实音频驱动**：`--headless` 会把音频驱动设成 Dummy，音频线程不真的混音，
##    Capture 抓出来全是 0。所以本脚本**不能**用 --headless 跑，必须起窗口化的 Godot。
##
## ⚠⚠ **本脚本不判红绿**。它只打印数值与比值。判据（多大跳变算咔哒、差值多少 dB 算合适）
##    由主理人与质量侧根据这些数据定 —— 实现者不给自己定阈值，这是本仓库的规矩。
##
## ⚠ 自我诊断：如果抓到的样本**全为 0**，说明这台机器没有音频输出设备 / 走了 Dummy 驱动，
##    此时打印 INCONCLUSIVE 并以退出码 2 结束，**绝不假装"没咔哒"**。
##
## 用法（机器空闲时）：
##   godot --path . --script res://tests/rel_step2c_audio_capture.gd ^
##         --log-file ..\godot-logs\rel-step2c-waveform.log

const RAIN_PATH := "res://assets/audio/rain_loop.ogg"
## 素材长度（秒），用来把 seek 停在接缝前一点。由脚本自己读，不写死。
var _rain_len := 0.0

var _rain: AudioStreamPlayer = null
var _cap_ambient: AudioEffectCapture = null
var _cap_sfx: AudioEffectCapture = null
var _car: Node = null
var _engine_audio: RefCounted = null
var _timed_out := false


func _initialize() -> void:
	var wd := create_timer(180.0, true)
	wd.timeout.connect(_on_watchdog)
	process_frame.connect(_on_frame)
	call_deferred("_run")


func _on_watchdog() -> void:
	if _timed_out:
		return
	_timed_out = true
	print("[WAVE] WATCHDOG: 180s timeout, abort")
	quit(2)


## 引擎声是 AudioStreamGenerator 流式合成，必须每帧续填缓冲，否则 0.5 秒后就静音了。
func _on_frame() -> void:
	if _engine_audio != null:
		_engine_audio.call("tick")


func _wait(sec: float) -> void:
	await create_timer(sec, true).timeout


func _run() -> void:
	_setup()
	await _measure_levels()      # ①
	await _measure_loop_seam()   # ②
	await _measure_pause_pop()   # ③
	print("[WAVE] DONE")
	quit(0)


# ------------------------------------------------------------------ 装配

func _setup() -> void:
	var stream: AudioStream = load(RAIN_PATH)
	if stream == null:
		print("[WAVE] INCONCLUSIVE: rain stream failed to load")
		quit(2)
		return
	_rain_len = stream.get_length()
	print("[WAVE] rain length = %.3f s, loop = %s" % [_rain_len, str(bool(stream.get("loop")))])

	# Ambient / SFX 两条总线各挂一个 Capture（抓各自总线上的波形，互不干扰）
	var ai := AudioServer.get_bus_index("Ambient")
	var si := AudioServer.get_bus_index("SFX")
	if ai < 0 or si < 0:
		print("[WAVE] INCONCLUSIVE: Ambient/SFX bus missing (ai=%d si=%d)" % [ai, si])
		quit(2)
		return
	_cap_ambient = AudioEffectCapture.new()
	_cap_ambient.buffer_length = 4.0
	AudioServer.add_bus_effect(ai, _cap_ambient)
	_cap_sfx = AudioEffectCapture.new()
	_cap_sfx.buffer_length = 4.0
	AudioServer.add_bus_effect(si, _cap_sfx)

	# 雨声：与生产环境一致（挂 Ambient、不设 volume_db 即 0 dB）
	_rain = AudioStreamPlayer.new()
	_rain.name = "WaveRainProbe"
	_rain.stream = stream
	_rain.bus = "Ambient"
	root.add_child(_rain)

	# 引擎声：直接用**真车场景 + engine_audio 模块**（不另写一份合成算法，
	# 否则测的就不是出货时那个声音了）
	var car_scene: PackedScene = load("res://scenes/race_car.tscn")
	if car_scene != null:
		_car = car_scene.instantiate()
		root.add_child(_car)
		var sc := load("res://scripts/engine_audio.gd")
		if sc != null:
			_engine_audio = sc.new()
			_engine_audio.call("setup", _car)


# ------------------------------------------------------- ① 电平（RMS / 峰值）

func _measure_levels() -> void:
	print("[WAVE] ---- 1) level: rain alone ----")
	_rain.play()
	await _wait(1.0)
	_drain(_cap_ambient)
	await _wait(2.0)
	var rain_st := _stats(_cap_ambient.get_buffer(200000))
	_dump("rain_alone", rain_st)

	print("[WAVE] ---- 1) level: engine alone ----")
	_rain.stop()
	if _engine_audio != null:
		await _wait(0.5)
		_drain(_cap_sfx)
		await _wait(2.0)
		var eng_st := _stats(_cap_sfx.get_buffer(200000))
		_dump("engine_alone", eng_st)
		print("[WAVE] level: rain_dBFS - engine_dBFS = %.2f dB (RMS), %.2f dB (peak)"
			% [rain_st.rms_db - eng_st.rms_db, rain_st.peak_db - eng_st.peak_db])
	else:
		print("[WAVE] INCONCLUSIVE: engine_audio module unavailable")
	print("[WAVE] ---- 1) level: rain + engine together (Master) ----")
	_rain.play()
	if _engine_audio != null:
		await _wait(2.0)
		# Master 上没有挂 Capture（挂了会改动出货配置），这里只用两条总线的值相加说明不了
		# 实际混合电平，所以**不测 Master**，明确记为未测。
		print("[WAVE] level: Master 混合电平未测（不能为测量去改出货的总线配置）")
	_rain.stop()


# ------------------------------------------------- ② 循环接缝（咔哒的物理表征）

func _measure_loop_seam() -> void:
	print("[WAVE] ---- 2) loop seam ----")
	# 对照组：文件**中段**，理论上不该有接缝
	var ctrl := await _capture_window(100.0)
	_dump_jump("control_mid_file", ctrl)
	# 接缝组：seek 到末尾前 0.5 s，让它在采集窗口里跨过 loop 点
	var seam := await _capture_window(maxf(0.0, _rain_len - 0.5))
	_dump_jump("seam_window", seam)
	if ctrl.frames > 0 and seam.frames > 0 and ctrl.max_jump > 0.0:
		print("[WAVE] seam: max_jump(seam) / max_jump(control) = %.3f"
			% (seam.max_jump / ctrl.max_jump))
	if ctrl.frames > 0 and seam.frames > 0 and ctrl.typical_jump > 0.0:
		print("[WAVE] seam: max_jump(seam) / typical_jump(control) = %.3f"
			% (seam.max_jump / ctrl.typical_jump))


## 在 Ambient 总线上抓一段跨过指定播放位置的波形。
func _capture_window(from_sec: float) -> Stats:
	_drain(_cap_ambient)
	_rain.play(from_sec)
	await _wait(1.4)
	var st := _stats(_cap_ambient.get_buffer(200000))
	_rain.stop()
	return st


# ------------------------------------------------------ ③ 暂停 / 恢复（爆音）

func _measure_pause_pop() -> void:
	print("[WAVE] ---- 3) pause / resume ----")
	_drain(_cap_ambient)
	_rain.play(30.0)
	await _wait(0.6)
	var before := _stats(_cap_ambient.get_buffer(200000))
	_dump_jump("before_pause", before)
	_rain.stream_paused = true
	await _wait(0.6)
	var during := _stats(_cap_ambient.get_buffer(200000))
	_dump_jump("during_pause", during)
	_rain.stream_paused = false
	await _wait(0.6)
	var after := _stats(_cap_ambient.get_buffer(200000))
	_dump_jump("after_resume", after)
	_rain.stop()


# ------------------------------------------------------------------ 工具

func _drain(cap: AudioEffectCapture) -> void:
	if cap != null:
		cap.get_buffer(400000)   # 丢掉旧数据，保证下一段是干净的


## 把一段立体声波形摊成统计量。相邻样本跳变是"咔哒 / 爆音"的物理表征：
## 平滑音频的相邻差值很小，接缝不连续或爆音会出现一个明显的大跳变。
class Stats:
	var frames := 0
	var peak := 0.0
	var rms := 0.0
	var rms_db := -999.0
	var peak_db := -999.0
	var max_jump := 0.0
	var typical_jump := 0.0
	var clipped := 0
	var all_zero := true


func _stats(buf: PackedVector2Array) -> Stats:
	var s := Stats.new()
	var n := buf.size()
	s.frames = n
	if n < 4:
		return s
	var sum_sq := 0.0
	var jumps: Array[float] = []
	jumps.resize(maxi(0, n - 1))
	var prev := 0.0
	for i in n:
		var m := (buf[i].x + buf[i].y) * 0.5
		if absf(m) > 1e-7:
			s.all_zero = false
		var a := absf(m)
		if a > s.peak:
			s.peak = a
		if a >= 0.999:
			s.clipped += 1
		sum_sq += m * m
		if i > 0:
			jumps[i - 1] = absf(m - prev)
			if jumps[i - 1] > s.max_jump:
				s.max_jump = jumps[i - 1]
		prev = m
	s.rms = sqrt(sum_sq / float(n))
	s.rms_db = _to_db(s.rms)
	s.peak_db = _to_db(s.peak)
	# typical_jump 用**中位数**：最大跳变之外的"正常水平"，不被单个尖刺带偏
	var sorted := jumps.duplicate()
	sorted.sort()
	s.typical_jump = sorted[int(sorted.size() * 0.5)]
	return s


func _to_db(v: float) -> float:
	if v <= 1e-9:
		return -999.0
	return 20.0 * log(v) / log(10.0)


func _dump(tag: String, s: Stats) -> void:
	print("[WAVE] %s: frames=%d all_zero=%s rms=%.6f (%.2f dBFS) peak=%.6f (%.2f dBFS) clipped=%d"
		% [tag, s.frames, str(s.all_zero), s.rms, s.rms_db, s.peak, s.peak_db, s.clipped])
	if s.all_zero:
		print("[WAVE] INCONCLUSIVE: %s 抓到全 0 —— 大概率是 Dummy 音频驱动 / 无声卡，"
			% tag + "本次测量不成立（不是「没问题」）")


func _dump_jump(tag: String, s: Stats) -> void:
	print("[WAVE] %s: frames=%d all_zero=%s max_jump=%.6f typical_jump=%.6f clipped=%d"
		% [tag, s.frames, str(s.all_zero), s.max_jump, s.typical_jump, s.clipped])
	if s.all_zero:
		print("[WAVE] INCONCLUSIVE: %s 抓到全 0 —— 大概率是 Dummy 音频驱动 / 无声卡，"
			% tag + "本次测量不成立（不是「没问题」）")
