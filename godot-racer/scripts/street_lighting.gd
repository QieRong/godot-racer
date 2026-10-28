extends Node3D
## 路灯模型全程可见；近车四盏真实聚光灯覆盖当前路段，随场景一同回收。
## 同机weather组件对照显示八盏灯有步频成本；保留灯具亮度和基础环境光。
const MAX_LIGHTS := 4
var _mounts: Array[Transform3D] = []
var _targets: Array[Vector3] = []
var _lights: Array[SpotLight3D] = []
var _focus: Node3D
var _elapsed := 0.0

func setup(mounts: Array[Transform3D], targets: Array[Vector3], focus: Node3D) -> void:
	_mounts = mounts
	_targets = targets
	_focus = focus
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
	if _elapsed < 0.2: return
	_elapsed = 0.0
	_refresh()

func _refresh() -> void:
	if not is_instance_valid(_focus): return
	var position := _focus.global_position
	var order: Array[int] = []
	for i in range(_mounts.size()): order.append(i)
	order.sort_custom(func(a: int,b: int) -> bool:
		return _mounts[a].origin.distance_squared_to(position)<_mounts[b].origin.distance_squared_to(position))
	for i in range(_lights.size()):
		var light := _lights[i]
		if i>=order.size(): light.visible=false;continue
		var index := order[i]
		light.visible = _mounts[index].origin.distance_squared_to(position)<110.0*110.0
		light.global_position = _mounts[index]*Vector3(2.13,5.43,0.0)
		light.look_at(_targets[index],Vector3.UP)
