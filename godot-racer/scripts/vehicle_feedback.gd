extends Node
## 共用轮胎/换挡反馈；比赛音乐与环境声仍由RaceAudio独占。
signal body_impact(speed_change: float)
const IMPACT_TITLE := "碰撞-轻"
const IMPACT_STREAM := preload("res://assets/audio/sfx/碰撞-轻.ogg")
const IMPACT_START := 0.095
var _car: VehicleBody3D
var _spatial := false
var _tire: AudioStreamPlayer3D
var _short: AudioStreamPlayer3D
var _previous_gear := 1
var _squeal_cooldown := 0.0
var _impact_pending := false
var _impact_cooldown := 0.0
var _previous_velocity := Vector3.ZERO
var _previous_position := Vector3.ZERO

func setup(car: VehicleBody3D, spatial: bool) -> void:
	_car = car
	_spatial = spatial
	process_mode = Node.PROCESS_MODE_ALWAYS
	_tire = AudioStreamPlayer3D.new()
	_tire.name = "TireLoop"
	var stream := load("res://assets/audio/sfx/轮胎-啸叫循环.ogg").duplicate() as AudioStreamOggVorbis
	stream.loop = true
	_tire.stream = stream
	_short = AudioStreamPlayer3D.new()
	_short.name = "VehicleOneShot"
	for player in [_tire, _short]:
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		player.bus = "SFX"
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE if spatial else AudioStreamPlayer3D.ATTENUATION_DISABLED
		player.unit_size = 5.0
		player.max_distance = 45.0 if spatial else 0.0
		player.volume_db = -70.0
		_car.add_child(player)
	_previous_gear = int(car.get("_gear"))
	_previous_position = car.global_position
	car.contact_monitor = true
	car.max_contacts_reported = maxi(car.max_contacts_reported, 8)
	car.body_entered.connect(_on_contact)

func _process(delta: float) -> void:
	var phase := GameState.phase_name()
	var racing := phase == "RACING" and (_spatial or not bool(_car.get("finish_input_locked")))
	var speed := _car.linear_velocity.length()
	var sideways := absf(_car.global_basis.x.dot(_car.linear_velocity))
	var contacts := 0
	var braking_slip := 0.0
	for child in _car.get_children():
		if child is VehicleWheel3D and child.is_in_contact():
			contacts += 1
			if child.brake > 5.0:
				braking_slip = maxf(braking_slip, 1.0 - child.get_skidinfo())
	var slip := clampf((sideways - 2.5) / 7.0, 0.0, 1.0) if racing and speed > 7.0 and contacts >= 2 else 0.0
	if racing and speed > 7.0 and contacts >= 2: slip = maxf(slip, braking_slip)
	# 只有玩家倒计时提示读取输入；AI完全由自己的车辆状态驱动。
	if not _spatial and phase == "COUNTDOWN":
		var prefix: String = _car.get("input_prefix")
		if Input.is_action_pressed(prefix + "accelerate") and Input.is_action_pressed(prefix + "brake_reverse"):
			slip = 0.5
	_tire.volume_db = move_toward(_tire.volume_db, lerpf(-70.0, -16.0, slip) - (6.0 if _spatial else 0.0), delta * 75.0)
	_tire.stream_paused = phase not in ["INTRO", "COUNTDOWN", "RACING", "FINISHED"]
	if not _tire.stream_paused and not _tire.playing: _tire.play()
	_short.stream_paused = _tire.stream_paused
	_squeal_cooldown = maxf(0.0, _squeal_cooldown - delta)
	if slip > 0.75 and _squeal_cooldown <= 0.0:
		_play_short("轮胎-尖叫", -23.0)
		_squeal_cooldown = 2.0
	var gear := int(_car.get("_gear"))
	if racing and gear != _previous_gear: _play_short("换挡-短", -29.0, 0.10)
	_previous_gear = gear

func _physics_process(delta: float) -> void:
	_impact_cooldown = maxf(0.0, _impact_cooldown - delta)
	# AI复位同样不能当成撞击；位移突变只抑制声音，不改物理和复位行为。
	var relocated := _car.global_position.distance_to(_previous_position) > _previous_velocity.length() * delta + 3.0
	if _impact_pending and GameState.phase_name() == "RACING" and not relocated:
		var impulse_speed := (_previous_velocity - _car.linear_velocity).length()
		var immune := not _spatial and bool(_car.call("is_reset_immune"))
		if impulse_speed > 2.0 and _impact_cooldown <= 0.0 and not immune:
			var intensity := clampf(inverse_lerp(2.0, 12.0, impulse_speed), 0.0, 1.0)
			_play_short(IMPACT_TITLE, lerpf(-23.0, -13.0, intensity), IMPACT_START)
			if not _spatial and impulse_speed >= 5.0:
				body_impact.emit(impulse_speed)
			_impact_cooldown = 0.6
	_impact_pending = false
	_previous_velocity = _car.linear_velocity
	_previous_position = _car.global_position

func _on_contact(body: Node) -> void:
	if GameState.phase_name() != "RACING" or (not _spatial and bool(_car.get("finish_input_locked"))):
		return
	# 玩家与 AI 相撞时，由玩家的一声碰撞提示覆盖这次接触。
	if _spatial and body is VehicleBody3D and body.has_method("is_reset_immune"):
		return
	_impact_pending = true

func _play_short(title: String, gain: float, from_position := 0.0) -> void:
	if not _spatial:
		Sfx.play_clip(title, gain, 1.0, from_position)
	elif title == IMPACT_TITLE or not _short.playing:
		_short.stream = IMPACT_STREAM if title == IMPACT_TITLE else load("res://assets/audio/sfx/%s.ogg" % title)
		_short.volume_db = gain - 6.0
		_short.play(from_position)

func _exit_tree() -> void:
	_tire.stop()
	_short.stop()
