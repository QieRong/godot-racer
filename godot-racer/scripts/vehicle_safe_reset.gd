extends RefCounted
## 玩家R方案A：只记录真实安全状态，不把事故最近点当历史安全点。
const SAMPLE_PERIOD := 0.1
const SAFE_DELAY := 0.4
const HISTORY_SECONDS := 30.0
const MAX_REWIND_METERS := 30.0
var _time := 0.0
var _next_sample := 0.0
var _history: Array[Dictionary] = []
var _spawn: Dictionary = {}
var _pending := false
var _pose := Transform3D.IDENTITY
var _velocity := Vector3.ZERO
var _replayed_finishes := 0
var _route_arc := -1.0
var _route_progress := 0.0

func seed(car: VehicleBody3D, track: Node3D) -> void:
	if track == null: return
	var near: Dictionary = track.nearest_on_centerline(car.global_position, -1.0)
	var frame: Transform3D = track.surface_frame(float(near.arc))
	_spawn = {"arc": float(near.arc), "lane": 0.0, "lap": int(car.laps_done),
		"height": (car.global_position-frame.origin).dot(frame.basis.y), "time": -SAFE_DELAY}
	_spawn.progress = _progress(car, track, float(near.arc))

func observe(car: VehicleBody3D, track: Node3D, field: Node3D, delta: float) -> void:
	_time += delta
	if track == null or not track.is_world_ready() or car.start_locked or car.freeze: return
	if car.get("_reset_cooldown") > 0.0 or car.is_reset_immune(): return
	if _time<_next_sample: return
	if car.grounded_wheel_count()!=4: return
	var near: Dictionary = track.nearest_on_centerline(car.global_position, float(car.get("_arc_hint")))
	var frame: Transform3D = track.surface_frame(float(near.arc))
	var lane := (car.global_position-frame.origin).dot(frame.basis.x)
	var height := (car.global_position-frame.origin).dot(frame.basis.y)
	var half := maxf(car.body_half_width, 0.875)
	var safe: bool = absf(lane)+half+0.25<track.road_half_width() and height>-0.3 and height<1.0
	safe = safe and car.global_basis.y.dot(frame.basis.y)>cos(deg_to_rad(12.0))
	safe = safe and car.angular_velocity.length()<0.5
	safe = safe and _lane_clear(field, float(near.arc), lane, half)
	if not safe: return
	_next_sample = _time+SAMPLE_PERIOD
	_history.append({"arc":float(near.arc), "lane":lane, "height":height,
		"lap":int(car.laps_done), "progress":_progress(car,track,float(near.arc)), "time":_time})
	while not _history.is_empty() and _time-float(_history[0].time)>HISTORY_SECONDS:
		_history.pop_front()

func _lane_clear(field: Node3D, arc: float, lane: float, half: float) -> bool:
	return field==null or not field.lane_blocked(lane, arc-4.0, 8.0, half)

func target(car: VehicleBody3D, track: Node3D, field: Node3D) -> Dictionary:
	if track==null: return {}
	var near: Dictionary = track.nearest_on_centerline(car.global_position,float(car.get("_arc_hint")))
	var current_progress := _progress(car,track,float(near.arc))
	var candidates := _history.duplicate()
	if not _spawn.is_empty(): candidates.push_front(_spawn)
	for i in range(candidates.size()-1,-1,-1):
		var saved: Dictionary = candidates[i]
		if _time-float(saved.time)<SAFE_DELAY: continue
		if float(saved.progress)>current_progress+0.25: continue
		if current_progress-float(saved.progress)>MAX_REWIND_METERS: continue
		if not _lane_clear(field,float(saved.arc),float(saved.lane),maxf(car.body_half_width,0.875)): continue
		var result := _restore_target(car,track,float(saved.arc),float(saved.lane),float(saved.height),float(saved.progress))
		if result.is_empty(): continue
		print("[车辆] R：最后安全位置，沿赛道退回%.2fm" % maxf(0.0,current_progress-float(saved.progress)))
		return result
	# 用户2026-10-28确认：历史点不合用时，仅向当前路段后方30米内寻找路面，禁止远处起点兜底。
	var half := maxf(car.body_half_width,0.875)
	var limit := maxf(0.0,track.road_half_width()-half-0.25)
	for back in range(0,int(MAX_REWIND_METERS)+1,2):
		var arc := fposmod(float(near.arc)-float(back),track.road_length())
		for lane: float in [0.0,-limit*0.5,limit*0.5,-limit,limit]:
			if not _lane_clear(field,arc,lane,half): continue
			var result := _restore_target(car,track,arc,lane,0.05,current_progress-float(back))
			if result.is_empty(): continue
			print("[车辆] R：近处安全路面，沿赛道退回%d米（上限30米）" % back)
			return result
	return {}

func _restore_target(car: VehicleBody3D, track: Node3D, arc: float, lane: float,
		height: float, progress: float) -> Dictionary:
	var frame: Transform3D = track.surface_frame(arc,lane)
	var position := frame.origin+frame.basis.y*height
	if not _space_clear(car,Transform3D(Basis.looking_at(frame.basis.z,frame.basis.y),position)): return {}
	var completed: int = int(car.laps_done) if car.start_line_crossed else -1
	_replayed_finishes = maxi(_replayed_finishes,completed-floori(progress/track.road_length()))
	_route_arc = arc
	_route_progress = progress
	return {"arc":arc,"pos":frame.origin,"forward":frame.basis.z,"restore_position":position,
		"normal":frame.basis.y,"dist":0.0,"safe_restore":true}

func _progress(car: VehicleBody3D, track: Node3D, arc: float) -> float:
	var length: float = track.road_length()
	if _route_arc<0.0:
		var completed: int = int(car.laps_done) if car.start_line_crossed else -1
		_route_progress = float(completed)*length+arc
	else:
		# 记录真实前进/倒退跨线，不能用核心已完成圈数猜车当前属于哪一圈。
		_route_progress += fposmod(arc-_route_arc+length*0.5,length)-length*0.5
	_route_arc = arc
	return _route_progress

func _space_clear(car: VehicleBody3D, pose: Transform3D) -> bool:
	var body: CollisionShape3D = car.get_node("BodyCollision")
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = body.shape
	query.transform = pose*body.transform
	query.collision_mask = 3
	query.exclude = [car.get_rid()]
	query.collide_with_areas = false
	return car.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty()

func consume_replayed_finish() -> bool:
	if _replayed_finishes<=0: return false
	_replayed_finishes-=1
	return true

func queue_pose(pose: Transform3D, velocity := Vector3.ZERO) -> void:
	_pose = pose
	_velocity = velocity
	_pending = true

func integrate(state: PhysicsDirectBodyState3D) -> void:
	if not _pending: return
	state.transform = _pose
	state.linear_velocity = _velocity
	state.angular_velocity = Vector3.ZERO
	state.sleeping = false
	_pending = false
