extends Node3D
## 主场景装配：把检查点信号接到 HUD，并给引擎声临时合成一个音源
##
## 这样设计是为了让你不用手动连线就能跑起来：
##   - Track 下所有 Area3D（含 StartFinish）的 car_passed 自动连到 HUD
##   - EngineSound 若没挂音频流，就用 AudioStreamGenerator 实时合成引擎声，
##     你把 freesound 下的 engine loop 拖到 EngineSound.stream 后，这段会自动让位

@onready var _car: VehicleBody3D = $RaceCar
@onready var _hud: CanvasLayer = $HUD

# 截图模式的内部状态（只有带 --shot 启动时才用）
var _shot_mode := false
var _shot_frames := 150
var _shot_hold := 0
var _shot_steer := 0
var _shot_view := -1
var _shot_out := ""
var _shot_frame := 0


func _ready() -> void:
	_connect_checkpoints()
	_setup_placeholder_engine_sound()
	_parse_shot_args()


## 截图模式。
##
## 为什么不挂在 --script 上：本机 Godot 4.4.1 里 **`--path` 与 `--script` 同时使用必崩**
## （signal 11，连一个只 print 然后 quit 的空脚本都崩；而单独用 --script 不带 --path
## 是正常的）。所以截图能力改挂在主场景里，走的是完全没问题的 `--path` 路径。
##
## 用法：
##   godot --path <工程> -- --shot --shot-frames=150 --shot-hold=120 --shot-out=<绝对路径>
##
## 注意**不能加 --headless**：headless 用的是空渲染器，截出来是空图。
## 另外窗口化运行必须用 `start` 分离启动，前台直接跑会段错误。
## 窗口会真的出现几秒，到点存 PNG 后自动退出。
##   --shot-frames=N  第 N 帧截图（默认 150，约 2.5 秒）
##   --shot-hold=N    前 N 帧模拟按住 W（行驶状态，默认 0）
##   --shot-steer=N   前 N 帧模拟按住 A（打方向，默认 0。配合 hold=0 可让车停着打方向，
##                    用来单独检查前轮有没有偏转）
##   --shot-view=N    直接切到第 N 个视角（0 第一人称 / 1 第二人称 / 2 第三人称）
##   --shot-out=PATH  输出路径，默认写到工程目录的上一级 godot-shot.png
func _parse_shot_args() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--shot"):
		return
	_shot_mode = true
	for a in args:
		if a.begins_with("--shot-frames="):
			_shot_frames = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-hold="):
			_shot_hold = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-steer="):
			_shot_steer = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-view="):
			_shot_view = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-out="):
			_shot_out = a.split("=", true, 1)[1]
	if _shot_out.is_empty():
		_shot_out = ProjectSettings.globalize_path("res://").path_join("..").simplify_path().path_join("godot-shot.png")
	if _shot_view >= 0:
		var cam := get_node_or_null("ChaseCamera")
		if cam != null and cam.has_method("set_view_mode"):
			cam.call("set_view_mode", _shot_view)
	print("[截图] 开关已打开：第 %d 帧存到 %s（按住 W %d 帧 / 按住 A %d 帧 / 视角 %d）"
		% [_shot_frames, _shot_out, _shot_hold, _shot_steer, _shot_view])


func _process(_delta: float) -> void:
	# AudioStreamGenerator 是**流式**的：只在启动时灌一次的话，缓冲播完就彻底静音。
	# 实测症状就是"刚进去有一声轰鸣，几秒后没声了"。必须每帧续填。
	if _engine_playback != null:
		_fill_engine_buffer()

	if not _shot_mode:
		return
	_shot_frame += 1
	if _shot_frame <= _shot_hold:
		Input.action_press("accelerate")
	elif _shot_frame == _shot_hold + 1:
		Input.action_release("accelerate")
	# 正数 = 按住 A（左舵），负数 = 按住 D（右舵），0 = 不打方向
	if _shot_steer != 0:
		var act := "steer_left" if _shot_steer > 0 else "steer_right"
		var n := absi(_shot_steer)
		if _shot_frame <= n:
			Input.action_press(act)
		elif _shot_frame == n + 1:
			Input.action_release(act)
	if _shot_frame < _shot_frames:
		return

	_shot_mode = false
	# 顺便把关键状态打出来，便于和画面对照
	var car := get_node_or_null("RaceCar")
	if car is VehicleBody3D:
		print("[截图] 车 pos=%s  steering=%.3f rad  车速=%.1f km/h"
			% [(car as Node3D).global_position, (car as VehicleBody3D).steering,
			   (car as VehicleBody3D).linear_velocity.length() * 3.6])
	# 相机诊断：用来量"相机会不会自己往车尾凑"
	var cam := get_node_or_null("ChaseCamera")
	if cam is Camera3D and car is Node3D:
		var dist := (cam as Camera3D).global_position.distance_to((car as Node3D).global_position)
		print("[截图] 相机 pos=%s  离车 %.2f m  高度 %.2f m"
			% [(cam as Camera3D).global_position, dist, (cam as Camera3D).global_position.y])
	var img := get_viewport().get_texture().get_image()
	if img == null:
		printerr("[截图] 拿不到 viewport 图像")
	else:
		var err := img.save_png(_shot_out)
		print("[截图] save_png -> %d  尺寸=%s  路径=%s" % [err, img.get_size(), _shot_out])
	print("[截图] 累计推送音频帧 = %d（应远大于单个缓冲 0.5s×22050≈11025，说明是流式续填而非一次灌满）"
		% _engine_frames_pushed)
	print("[截图] 结束，退出")
	get_tree().quit()


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


## 底噪基频（怠速）。车体的 pitch_scale 会在这个基础上整体升降。
const ENGINE_BASE_HZ := 60.0

# 占位引擎声的流式缓冲状态
var _engine_playback: AudioStreamGeneratorPlayback = null
var _engine_mix_rate := 22050.0
var _engine_phase := 0.0
var _engine_frames_pushed := 0
var _engine_rng := RandomNumberGenerator.new()


## 没有引擎音频文件时，用生成器合成一个能出声的占位音源。
##
## **AudioStreamGenerator 是流式的**。原来的写法只在 _ready 里灌一次缓冲，
## 那 0.5 秒播完就再也没有数据了 —— 表现就是"刚进去有一声轰鸣，几秒后彻底静音"。
## 现在改成每帧在 _process 里续填（见 _fill_engine_buffer）。
func _setup_placeholder_engine_sound() -> void:
	var player: AudioStreamPlayer3D = _car.get_node_or_null("EngineSound")
	if player == null:
		return
	if player.stream is AudioStreamGenerator:
		var gen: AudioStreamGenerator = player.stream
		_engine_mix_rate = gen.mix_rate
		_engine_playback = player.get_stream_playback()
		if _engine_playback == null:
			return
		_engine_rng.seed = 20240517
		_fill_engine_buffer()
		print("[main] 已启用占位引擎声（Generator 流式合成，每帧续填缓冲）。想要真实轰鸣请给 EngineSound.stream 换 wav")


## 把当前所有空位填满：低频锯齿波（模拟气缸爆发）+ 一点噪声。
## 每帧调用，缓冲区就不会见底。
func _fill_engine_buffer() -> void:
	var frames := _engine_playback.get_frames_available()
	if frames <= 0:
		return
	for i in frames:
		_engine_phase += ENGINE_BASE_HZ / _engine_mix_rate
		if _engine_phase >= 1.0:
			_engine_phase -= 1.0
		var saw := _engine_phase * 2.0 - 1.0
		var noise := _engine_rng.randf_range(-0.15, 0.15)
		var sample := clampf(saw * 0.35 + noise, -1.0, 1.0)
		_engine_playback.push_frame(Vector2(sample, sample))
	_engine_frames_pushed += frames
