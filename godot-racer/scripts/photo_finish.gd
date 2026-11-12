extends Node
## 真实结果冻结后，仅重放最近三秒的视觉代理，不操作真实车体或比赛时钟。
signal completed
const Visual := preload("res://scripts/ghost_car.gd")
const THRESHOLD := 0.75
const DURATION := 2.5
var cars: Array = []
var traces: Array[PackedFloat32Array] = []
var proxies: Array[Node3D] = []
var track: Node3D
var camera: Camera3D
var old_camera: Camera3D
var overlay: CanvasLayer
var next_sample := 0.0
var playing := false
var elapsed := 0.0
var replay_start := 0.0
var replay_end := 0.0
var invalid_until := 0.0

func setup(player: VehicleBody3D, opponents: Array, road: Node3D) -> void:
	name = "PhotoFinish"
	process_mode = Node.PROCESS_MODE_ALWAYS
	track = road
	if opponents.size() != 1 or GameState.endless_mode: return
	cars = [player, opponents[0]]
	traces.assign([PackedFloat32Array(), PackedFloat32Array()])
	player.trajectory_discontinuity.connect(invalidate)
	opponents[0].trajectory_discontinuity.connect(invalidate)

func invalidate() -> void:
	invalid_until = GameState.race_total_time() + 3.0
	for i in range(traces.size()): traces[i].clear()

func begin() -> void:
	next_sample = 0.0
	invalid_until = 0.0
	for i in range(traces.size()): traces[i].clear()
	sample(true)

func sample(force := false) -> void:
	if cars.is_empty() or not GameState.photo_finish_enabled or GameState.phase_name() != "RACING": return
	var now := GameState.race_total_time()
	if not force and now < next_sample: return
	next_sample = now + 0.04
	for i in range(cars.size()):
		var trace := traces[i]
		if not trace.is_empty():
			var offset := trace.size() - 9
			if now <= trace[offset]: continue
			var previous := Vector3(trace[offset+1], trace[offset+2], trace[offset+3])
			var allowed: float = 5.0 + cars[i].linear_velocity.length() * (now - trace[offset]) * 2.0
			if previous.distance_to(cars[i].global_position) > allowed:
				invalidate()
				return
		trace = Visual.append_sample(trace, now, cars[i].global_transform, 0.0)
		while trace.size() > 9 * 80 or (trace.size() >= 18 and trace[9] < now - 3.0): trace = trace.slice(9)
		traces[i] = trace

func _physics_process(_delta: float) -> void:
	sample()

func start(entries: Array) -> bool:
	if not GameState.photo_finish_enabled or cars.size() != 2 or entries.size() != 2: return false
	if not entries[0].finished or not entries[1].finished: return false
	var gap := absf(float(entries[0].total) - float(entries[1].total))
	if gap > THRESHOLD: return false
	replay_end = maxf(float(entries[0].total), float(entries[1].total))
	if replay_end < invalid_until: return false
	replay_start = maxf(0.0, minf(float(entries[0].total), float(entries[1].total)) - 0.9)
	for trace in traces:
		if trace.size() < 18 or trace[0] > replay_start or trace[trace.size()-9] < replay_end - 0.02: return false
	old_camera = get_viewport().get_camera_3d()
	for i in range(cars.size()):
		var proxy := Visual.new()
		add_child(proxy)
		proxy.build(cars[i], false)
		proxy.samples = traces[i]
		proxies.append(proxy)
		cars[i].visible = false
	camera = Camera3D.new()
	add_child(camera)
	var arc: float = track.road_length() * float(track.get("start_finish_t"))
	var center: Vector3 = track.centerline_point(arc)
	var forward: Vector3 = track.centerline_forward(arc)
	var side := Vector3(forward.z, 0, -forward.x).normalized()
	camera.global_position = center + side * (track.road_half_width() + 8.0) + Vector3.UP * 5.0 - forward * 2.0
	camera.look_at(center + Vector3.UP - forward * 4.0, Vector3.UP)
	camera.fov = 55.0
	camera.make_current()
	overlay = CanvasLayer.new()
	add_child(overlay)
	var label := Label.new()
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.offset_top = 50
	label.add_theme_font_size_override("font_size", 36)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 6)
	var tied: bool = entries[0].finish_frame == entries[1].finish_frame
	label.text = "%s\n%s" % [tr("终点摄影"), tr("%s · 时间差 %.3f 秒") % [
		tr("同帧并列") if tied else tr("真实冲线回放"), gap]]
	label.add_theme_font_override("font", preload("res://scripts/ui_theme.gd").ui_font)
	overlay.add_child(label)
	playing = true
	elapsed = 0.0
	_process(0.0)
	return true

func _process(delta: float) -> void:
	if not playing or GameState.phase_name() != "FINISHED": return
	elapsed += delta
	for proxy in proxies:
		proxy.play_at(lerpf(replay_start, replay_end, minf(elapsed / DURATION, 1.0)))
	if elapsed >= DURATION:
		playing = false
		for proxy in proxies: proxy.queue_free()
		proxies.clear()
		for car in cars: car.visible = true
		camera.queue_free()
		overlay.queue_free()
		if is_instance_valid(old_camera): old_camera.make_current()
		completed.emit()
