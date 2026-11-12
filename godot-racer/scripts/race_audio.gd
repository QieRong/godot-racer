extends Node
## 每局音乐、环境与车辆反馈；节点随比赛回收，不再建立第二套全局比赛状态。
const MUSIC := ["音乐-关卡1-训练营", "音乐-关卡2-阳光竞速场", "音乐-关卡3-雨夜街道",
	"音乐-关卡4-荒漠遗迹", "音乐-关卡5-极地挑战"]
var _drivers: Array[VehicleBody3D] = []
var _music: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _ambience: Array[AudioStreamPlayer] = []
var _music_gain := -70.0
var _music_enabled := true
var _countdown_duck := 0.0

func setup(car: VehicleBody3D, cfg: Resource, second: VehicleBody3D = null) -> void:
	_drivers.append(car)
	if second != null:
		_drivers.append(second)
	process_mode = Node.PROCESS_MODE_ALWAYS
	var settings := ConfigFile.new()
	if settings.load(GameState.settings_path) == OK:
		_music_enabled = bool(settings.get_value("audio", "menu_bgm_enabled", true))
	_music = _loop("music/" + MUSIC[GameState.chosen_level], "BGM", -70.0)
	_wind = _loop("sfx/环境风-速度循环", "Ambient", -70.0)
	match cfg.weather_type:
		"rain": _ambience.append(_loop("ambience/环境-雨夜城市循环", "Ambient", -32.0))
		"sand":
			_ambience.append(_loop("ambience/环境-荒漠风声循环", "Ambient", -26.0))
			_ambience.append(_loop("sfx/环境风-低沉循环", "Ambient", -36.0))
		"snow":
			_ambience.append(_loop("ambience/环境-雪原风循环", "Ambient", -28.0))
			_ambience.append(_loop("ambience/环境-暴风雪循环", "Ambient", -35.0))
		_:
			_ambience.append(_loop("ambience/环境-森林鸟鸣循环", "Ambient", -28.0))
			_ambience.append(_loop("sfx/环境风-户外循环", "Ambient", -38.0))
	for driver in _drivers:
		var feedback := preload("res://scripts/vehicle_feedback.gd").new()
		feedback.name = "VehicleFeedback"
		driver.add_child(feedback)
		feedback.setup(driver, false)
		driver.lap_completed.connect(_on_lap.bind(driver))
		var burnout := preload("res://scripts/start_burnout.gd").new()
		burnout.name = "StartBurnout"
		add_child(burnout, true)
		burnout.setup(driver)

func _loop(path: String, bus_name: String, level: float) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	var stream := load("res://assets/audio/%s.ogg" % path).duplicate() as AudioStreamOggVorbis
	stream.loop = true
	player.stream = stream
	player.bus = bus_name
	player.volume_db = level
	player.set_meta("base_gain_db", level)
	add_child(player)
	return player

func _process(delta: float) -> void:
	if _drivers.is_empty(): return
	var phase := GameState.phase_name()
	var racing := phase == "RACING"
	var present := phase in ["INTRO", "COUNTDOWN", "RACING", "FINISHED"]
	# 倒计时为发车信号留出空间，GO 后平滑恢复音乐和天气音量。
	_countdown_duck = move_toward(_countdown_duck, 9.0 if phase == "COUNTDOWN" else 0.0, delta * 42.0)
	var target_gain := -42.0 if phase == "FINISHED" else -37.0
	_music_gain = move_toward(_music_gain, target_gain if present and _music_enabled else -70.0, delta*45.0)
	_music.volume_db = _music_gain - _countdown_duck
	for player in _ambience:
		player.volume_db = float(player.get_meta("base_gain_db")) - _countdown_duck
	for player in [_music, _wind] + _ambience:
		player.stream_paused = not present
		if present and not player.playing and (player != _music or _music_enabled): player.play()
	var speed := 0.0
	for driver in _drivers:
		speed = maxf(speed, driver.linear_velocity.length())
	_wind.volume_db = move_toward(_wind.volume_db, lerpf(-70.0,-30.0,clampf((speed-12.0)/45.0,0.0,1.0)) if racing else -70.0, delta*45.0)

func _on_lap(_last: float, _best: float, driver: VehicleBody3D) -> void:
	if driver.laps_target <= 0 or driver.laps_done < driver.laps_target: Sfx.play_clip("单圈完成",-15.0)

func _exit_tree() -> void:
	for child in get_children():
		if child is AudioStreamPlayer: child.stop()
