extends Node
## 只读记录器：不调用 AI 决策、复位，不写车姿态/速度/输入。
signal completed
var ai: VehicleBody3D
var track: Node3D
var state: Node
var destination := ""
var csv: FileAccess
var events: FileAccess
var frame := 0
var running := false
var done := false
var started_ms := 0
var progress_window: Array = []
var stalled := false
var max_seconds := 600.0

func setup(car: VehicleBody3D, road: Node3D, game_state: Node, output: String) -> void:
	ai = car
	track = road
	state = game_state
	destination = output
	process_priority = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	csv = FileAccess.open(output.path_join("trace.csv"), FileAccess.WRITE)
	csv.store_line("frame,sim_s,wall_s,x,y,z,vx,vy,vz,arc,global_arc,lane,lateral_error,yaw_deg,steer,engine_force,brake,rescues,laps")
	events = FileAccess.open(output.path_join("gates.jsonl"), FileAccess.WRITE)
	for gate in track.get_children():
		if gate is Area3D and gate.get_script() != null and gate.get("order_index") != null:
			gate.body_entered.connect(_gate_entered.bind(gate))

func _gate_entered(body: Node3D, gate: Area3D) -> void:
	if body != ai or not running: return
	events.store_line(JSON.stringify({"frame": frame, "order": int(gate.order_index),
		"pos": [ai.global_position.x, ai.global_position.y, ai.global_position.z]}))

func _physics_process(_delta: float) -> void:
	if done or ai == null: return
	if not running:
		if state.call("phase_name") != "RACING" or not ai.armed: return
		running = true
		started_ms = Time.get_ticks_msec()
	frame += 1
	var hz := float(Engine.physics_ticks_per_second)
	var sim_s := float(frame) / hz
	var v := ai.linear_velocity
	var p := ai.global_position
	var wheels: Array = ai.get("_all_wheels")
	var engine_force := 0.0
	var brake := 0.0
	for wheel in wheels:
		engine_force += wheel.engine_force
		brake = maxf(brake, wheel.brake)
	var values := [frame, sim_s, (Time.get_ticks_msec() - started_ms) / 1000.0,
		p.x, p.y, p.z, v.x, v.y, v.z, ai.get("_arc"), ai.get("_diag_arc_global"),
		ai.get("_lane_now"), ai.get("_diag_lateral_err"), ai.get("_diag_yaw_vs_track_deg"),
		ai.get("_steer"), engine_force, brake, ai.call("rescue_count"), ai.call("laps_done")]
	var columns := PackedStringArray()
	for value in values: columns.append(str(value))
	csv.store_line(",".join(columns))
	progress_window.append([sim_s, float(ai.call("progress"))])
	while progress_window.size() > 1 and sim_s - float(progress_window[0][0]) > 10.0:
		progress_window.pop_front()
	if sim_s > 12.0 and progress_window.size() > 1:
		stalled = float(ai.call("progress")) - float(progress_window[0][1]) < 5.0
	# 核心按弧长量化回绕，可能比门中心平面早约1m。继续只读到车身确实通过门后2m。
	var beyond_line: float = (p - track.start_line_center).dot(track.start_line_forward)
	var physically_finished := int(ai.call("laps_done")) >= 2 and beyond_line >= 2.0 and beyond_line < 20.0
	if physically_finished or int(ai.call("rescue_count")) > 0 or stalled or sim_s >= max_seconds:
		done = true
		csv.flush()
		events.flush()
		csv = null
		events = null
		completed.emit()
