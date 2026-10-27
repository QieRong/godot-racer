extends Node
## 每物理帧只读双车辆观察。玩家恢复还要离线查原始REC事件；不能靠位移阈值替代。
var car: VehicleBody3D
var track: Node3D
var state: Node
var player := false
var directory := ""
var csv: FileAccess
var events: FileAccess
var frame := 0
var done := false
var hint := -1.0
var start_ms := 0
var stop_reason := ""
var target := 2

func setup(actor: VehicleBody3D, road: Node3D, game_state: Node, path: String, is_player: bool) -> void:
	car = actor; track = road; state = game_state; directory = path; player = is_player
	target = state.current_level().laps_to_finish
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 100
	DirAccess.make_dir_recursive_absolute(path)
	csv = FileAccess.open(path.path_join("trace.csv"), FileAccess.WRITE)
	csv.store_line("frame,sim_s,wall_s,x,y,z,vx,vy,vz,arc,global_arc,lane,lateral_error,yaw_deg,steer,engine_force,brake,rescues,laps")
	events = FileAccess.open(path.path_join("gates.jsonl"), FileAccess.WRITE)
	for gate in track.get_children():
		if gate is Area3D: gate.body_entered.connect(_entered.bind(gate))
	start_ms = Time.get_ticks_msec()

func _entered(body: Node3D, gate: Area3D) -> void:
	if body == car and not done:
		events.store_line(JSON.stringify({"frame": frame, "order": gate.order_index,
			"pos": [car.global_position.x,car.global_position.y,car.global_position.z]}))

func _physics_process(_delta: float) -> void:
	if done: return
	frame += 1
	var p := car.global_position
	var v := car.linear_velocity
	var near: Dictionary = track.nearest_on_centerline(p, hint)
	hint = float(near.arc)
	var f: Vector3 = near.forward
	var n := -car.global_basis.z
	n.y = 0.0; f.y = 0.0
	var yaw := rad_to_deg(atan2(f.cross(n).y, f.dot(n)))
	var lateral := (p - Vector3(near.pos)).dot(Vector3(f.z,0,-f.x))
	var laps := int(car.laps_done) if player else int(car.call("laps_done"))
	var rescues := 0 if player else int(car.call("rescue_count"))
	var engine := 0.0
	var brake := 0.0
	for child in car.get_children():
		if child is VehicleWheel3D:
			engine += child.engine_force
			brake = maxf(brake, child.brake)
	var arc: float = float(car.get("_arc_hint")) if player else float(car.get("_arc"))
	var global_arc: float = track.nearest_on_centerline(p, -1.0).arc
	var values := [frame, float(frame) / Engine.physics_ticks_per_second,
		(Time.get_ticks_msec()-start_ms)/1000.0,p.x,p.y,p.z,v.x,v.y,v.z,
		arc,global_arc,lateral,lateral,yaw,car.get("_steer"),engine,brake,rescues,laps]
	var columns := PackedStringArray()
	for value in values: columns.append(str(value))
	csv.store_line(",".join(columns))
	var beyond: float = (p-track.start_line_center).dot(track.start_line_forward)
	if (laps >= target and (player or (beyond >= 2.0 and beyond < 20.0))) or rescues > 0 or frame >= 600 * Engine.physics_ticks_per_second:
		stop_reason = "complete" if laps >= target else "rescue" if rescues > 0 else "timeout"
		done = true
		csv.flush(); events.flush(); csv = null; events = null
