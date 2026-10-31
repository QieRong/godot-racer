extends Node
## 每局音乐、环境与车辆反馈；节点随比赛回收，不再建立第二套全局比赛状态。
const MUSIC := ["音乐-关卡1-训练营", "音乐-关卡2-阳光竞速场", "音乐-关卡3-雨夜街道",
	"音乐-关卡4-荒漠遗迹", "音乐-关卡5-极地挑战"]
var _car: VehicleBody3D
var _music: AudioStreamPlayer
var _tire: AudioStreamPlayer
var _wind: AudioStreamPlayer
var _ambience: Array[AudioStreamPlayer] = []
var _previous_velocity := Vector3.ZERO
var _previous_gear := 1
var _impact_pending := false
var _impact_cooldown := 0.0
var _squeal_cooldown := 0.0
var _music_gain := -70.0
var _music_enabled := true

func setup(car: VehicleBody3D, cfg: Resource) -> void:
	_car = car
	process_mode = Node.PROCESS_MODE_ALWAYS
	var settings := ConfigFile.new()
	if settings.load(GameState.settings_path) == OK:
		_music_enabled = bool(settings.get_value("audio", "menu_bgm_enabled", true))
	_music = _loop("music/" + MUSIC[GameState.chosen_level], "BGM", -70.0)
	_tire = _loop("sfx/轮胎-啸叫循环", "SFX", -70.0)
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
	_car.contact_monitor = true
	_car.max_contacts_reported = maxi(_car.max_contacts_reported, 8)
	_car.body_entered.connect(_on_contact)
	_car.lap_completed.connect(_on_lap)
	_previous_gear = int(car.get("_gear"))
	var burnout := preload("res://scripts/start_burnout.gd").new()
	burnout.name = "StartBurnout"
	add_child(burnout)
	burnout.setup(car)

func _loop(path: String, bus_name: String, level: float) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	var stream := load("res://assets/audio/%s.ogg" % path).duplicate() as AudioStreamOggVorbis
	stream.loop = true
	player.stream = stream
	player.bus = bus_name
	player.volume_db = level
	add_child(player)
	return player

func _process(delta: float) -> void:
	if _car == null: return
	var phase := GameState.phase_name()
	var racing := phase == "RACING"
	var present := phase in ["INTRO", "COUNTDOWN", "RACING", "FINISHED"]
	_music_gain = move_toward(_music_gain, -30.0 if present and _music_enabled else -70.0, delta*45.0)
	_music.volume_db = _music_gain
	for player in [_music, _tire, _wind] + _ambience:
		player.stream_paused = not present
		if present and not player.playing and (player != _music or _music_enabled): player.play()
	var speed := _car.linear_velocity.length()
	var sideways := absf(_car.global_basis.x.dot(_car.linear_velocity))
	var slip := clampf((sideways-2.5)/7.0, 0.0, 1.0) if racing and speed>7.0 and _car.grounded_wheel_count()>=2 else 0.0
	if phase=="COUNTDOWN" and Input.is_action_pressed("accelerate") and Input.is_action_pressed("brake_reverse"):
		slip = 0.5
	_tire.volume_db = move_toward(_tire.volume_db, lerpf(-70.0,-16.0,slip), delta*75.0)
	_wind.volume_db = move_toward(_wind.volume_db, lerpf(-70.0,-30.0,clampf((speed-12.0)/45.0,0.0,1.0)) if racing else -70.0, delta*45.0)
	_impact_cooldown = maxf(0.0,_impact_cooldown-delta)
	_squeal_cooldown = maxf(0.0,_squeal_cooldown-delta)
	if slip>0.75 and _squeal_cooldown<=0.0:
		Sfx.play_clip("轮胎-尖叫",-23.0)
		_squeal_cooldown=2.0
	var gear := int(_car.get("_gear"))
	if racing and gear != _previous_gear: Sfx.play_clip("换挡-短",-24.0)
	_previous_gear=gear

func _physics_process(_delta: float) -> void:
	if _car == null or GameState.phase_name() != "RACING": return
	if _impact_pending:
		var impulse_speed := (_previous_velocity-_car.linear_velocity).length()
		if impulse_speed>2.0 and _impact_cooldown<=0.0 and not _car.is_reset_immune():
			Sfx.play_clip("碰撞-轻" if impulse_speed<8.0 else "碰撞-金属", -18.0)
			_impact_cooldown=0.6
		_impact_pending=false
	_previous_velocity=_car.linear_velocity

func _on_contact(_body: Node) -> void:
	_impact_pending=true

func _on_lap(_last: float, _best: float) -> void:
	if _car.laps_target<=0 or _car.laps_done<_car.laps_target: Sfx.play_clip("单圈完成",-15.0)

func _exit_tree() -> void:
	for child in get_children():
		if child is AudioStreamPlayer: child.stop()
