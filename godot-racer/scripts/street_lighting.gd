extends Node3D
## 路灯模型全程可见；四盏真实聚光灯提前覆盖观察方向的路段，随场景回收。
## 同机weather组件对照显示八盏灯有步频成本；保留灯具亮度和基础环境光。
const MAX_LIGHTS := 4
const PREVIEW_METERS := 40.0
var _mounts: Array[Transform3D] = []
var _targets: Array[Vector3] = []
var _lights: Array[SpotLight3D] = []
var _focus: Node3D
var _track: Node3D
var _camera: Camera3D
var _view_sign := 1.0
var _last_arc := -1.0
var _elapsed := 0.0

func setup(mounts: Array[Transform3D], targets: Array[Vector3], focus: Node3D,
		track: Node3D = null, camera: Camera3D = null) -> void:
	_mounts = mounts
	_targets = targets
	_focus = focus
	_track = track
	_camera = camera
	for i in range(MAX_LIGHTS):
		var light := SpotLight3D.new()
		light.name = "RoadLamp%d" % i
		light.light_color = Color(1.0,0.86,0.66)
		light.light_energy = 3.6
		light.light_specular = 0.2
		light.spot_range = 42.0
		light.spot_angle = 65.0
		light.spot_angle_attenuation = 0.7
		light.spot_attenuation = 1.0
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
		_lights.append(light)
	_refresh()

func _process(delta: float) -> void:
	_elapsed += delta
	# C后视/环视转向必须在相机更新后立即准备，不能等下一次0.2s轮询。
	if _elapsed < 0.2 and _observation_sign() == _view_sign: return
	_elapsed = 0.0
	_refresh()

func _observation_sign() -> float:
	if not is_instance_valid(_camera) or not is_instance_valid(_focus): return 1.0
	return -1.0 if (-_camera.global_basis.z).dot(-_focus.global_basis.z) < -0.1 else 1.0

func _preview_position() -> Vector3:
	_view_sign = _observation_sign()
	var position := _focus.global_position
	if is_instance_valid(_track):
		# 复用最终中心线，弯道/坡顶/终点闭环都沿道路预备，不沿直线猜测。
		var near: Dictionary = _track.nearest_on_centerline(position,_last_arc)
		_last_arc = float(near.arc)
		var forward: Vector3 = _track.centerline_forward(float(near.arc))
		var view := -_camera.global_basis.z if is_instance_valid(_camera) else -_focus.global_basis.z
		var direction := -1.0 if view.dot(forward) < 0.0 else 1.0
		return _track.centerline_point(float(near.arc)+PREVIEW_METERS*direction)
	return position-_focus.global_basis.z*PREVIEW_METERS*_view_sign

func _refresh() -> void:
	if not is_instance_valid(_focus): return
	var position := _focus.global_position
	var preview := _preview_position()
	var order: Array[int] = []
	for i in range(_mounts.size()): order.append(i)
	order.sort_custom(func(a: int,b: int) -> bool:
		return _mounts[a].origin.distance_squared_to(preview)<_mounts[b].origin.distance_squared_to(preview))
	# 保留脚下16m内最近一对灯的受光，不能为预备远灯把当前近景突然关掉。
	var nearest := order.duplicate()
	nearest.sort_custom(func(a: int,b: int) -> bool:
		return _targets[a].distance_squared_to(position)<_targets[b].distance_squared_to(position))
	var selected: Array[int] = []
	for index in nearest:
		if selected.size()>=2: break
		if _targets[index].distance_squared_to(position)<16.0*16.0: selected.append(index)
	for index in order:
		if selected.size()>=MAX_LIGHTS: break
		if not selected.has(index): selected.append(index)
	for i in range(_lights.size()):
		var light := _lights[i]
		if i>=selected.size(): light.visible=false;continue
		var index := selected[i]
		light.visible = _mounts[index].origin.distance_squared_to(position)<110.0*110.0
		light.global_position = _mounts[index]*Vector3(2.13,5.43,0.0)
		light.look_at(_targets[index],Vector3.UP)
