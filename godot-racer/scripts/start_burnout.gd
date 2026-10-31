extends Node
## 倒计时烧胎仅表现：整棵物理树仍冻结，不施力、不写车体位置或速度。
const Wheels := preload("res://scripts/vehicle_wheel_visuals.gd")
var _car: VehicleBody3D
var _rev: AudioStreamPlayer
var _smoke: Array[CPUParticles3D] = []
var _level := 0.0

func setup(car: VehicleBody3D) -> void:
	_car = car
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rev = AudioStreamPlayer.new()
	_rev.bus = "SFX"
	var stream := load("res://assets/audio/sfx/引擎轰鸣循环.ogg").duplicate() as AudioStreamOggVorbis
	stream.loop = true
	_rev.stream = stream
	_rev.volume_db = -70.0
	add_child(_rev)
	var radial := GradientTexture2D.new()
	radial.width = 32
	radial.height = 32
	radial.fill = GradientTexture2D.FILL_RADIAL
	radial.fill_from = Vector2(0.5,0.5)
	radial.fill_to = Vector2(1.0,0.5)
	radial.gradient = Gradient.new()
	radial.gradient.colors = PackedColorArray([Color.WHITE,Color(1,1,1,0)])
	var material := StandardMaterial3D.new()
	material.albedo_texture = radial
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE
	mesh.material = material
	for child in car.get_children():
		if not child is VehicleWheel3D or not child.use_as_traction: continue
		var particles := CPUParticles3D.new()
		particles.name = "StartTireSmoke"
		particles.process_mode = Node.PROCESS_MODE_ALWAYS
		particles.emitting = false
		particles.amount = 24
		particles.lifetime = 1.1
		particles.local_coords = false
		particles.mesh = mesh
		particles.direction = Vector3.UP
		particles.spread = 25.0
		particles.gravity = Vector3(0,0.4,0)
		particles.initial_velocity_min = 0.6
		particles.initial_velocity_max = 1.1
		particles.scale_amount_min = 0.35
		particles.scale_amount_max = 1.2
		var fade := Gradient.new()
		fade.offsets = PackedFloat32Array([0.0,0.2,1.0])
		fade.colors = PackedColorArray([Color(0.75,0.77,0.78,0),Color(0.75,0.77,0.78,0.22),Color(0.75,0.77,0.78,0)])
		particles.color_ramp = fade
		car.add_child(particles)
		particles.position = car.to_local(child.get_contact_point()) + Vector3.UP * 0.06
		_smoke.append(particles)

func _process(delta: float) -> void:
	if _car == null: return
	var countdown := GameState.phase_name() == "COUNTDOWN"
	var gas := countdown and Input.is_action_pressed("accelerate")
	var burning := gas and Input.is_action_pressed("brake_reverse")
	_level = move_toward(_level, 1.0 if gas else 0.0, delta*5.0)
	_rev.volume_db = lerpf(-70.0,-22.0,_level)
	_rev.pitch_scale = lerpf(0.85,1.75,_level)
	if gas and not _rev.playing: _rev.play()
	if _level<=0.0 and _rev.playing: _rev.stop()
	for particles in _smoke:
		particles.emitting = burning
		particles.speed_scale = 0.0 if GameState.phase_name() == "EXIT_CONFIRM" else 1.0
	if burning: Wheels.start_burnout(_car.get("_wheel_visuals"),delta)

func _exit_tree() -> void:
	if is_instance_valid(_rev): _rev.stop()
