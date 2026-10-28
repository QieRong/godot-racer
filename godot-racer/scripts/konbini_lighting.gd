extends Node3D
## 九间店共用一组近车檐灯/室内灯，照亮地面、雨丝和真实室内商品；无新增地面网格。
var _stores: Array[Transform3D] = []
var _focus: Node3D
var _lamp: SpotLight3D
var _interior: OmniLight3D
var _elapsed := 0.0

func setup(stores: Array[Transform3D], focus: Node3D) -> void:
	_stores=stores
	_focus=focus
	_lamp=SpotLight3D.new()
	_lamp.name="WarmCanopyPool"
	_lamp.light_color=Color(1.0,0.70,0.35)
	_lamp.light_energy=4.4
	_lamp.light_specular=0.08
	_lamp.spot_range=15.0
	_lamp.spot_angle=73.0
	_lamp.spot_attenuation=1.2
	_lamp.spot_angle_attenuation=0.7
	_lamp.shadow_enabled=false
	_lamp.visible=false
	add_child(_lamp)
	_interior=OmniLight3D.new()
	_interior.name="WarmInteriorPool"
	# 冷色环境补光下，原暖白灯的实际室内响应仍偏蓝；用琥珀暖色建立可见对比。
	_interior.light_color=Color(1.0,0.62,0.28)
	_interior.light_energy=7.0
	_interior.light_specular=0.05
	_interior.omni_range=7.4
	_interior.omni_attenuation=1.2
	_interior.shadow_enabled=false
	_interior.visible=false
	add_child(_interior)
	_refresh()

func _process(delta: float) -> void:
	_elapsed+=delta
	if _elapsed<0.2: return
	_elapsed=0.0
	_refresh()

func _refresh() -> void:
	if not is_instance_valid(_focus): return
	var index := -1
	var best := 140.0*140.0
	for i in range(_stores.size()):
		var distance := _stores[i].origin.distance_squared_to(_focus.global_position)
		if distance<best: best=distance;index=i
	_lamp.visible=index>=0
	_interior.visible=index>=0
	set_meta("active_store",index)
	if index<0: return
	var mount := _stores[index]
	_lamp.global_position=mount*Vector3(0,2.8,-4.3)
	_lamp.look_at(mount*Vector3(0,0.05,-8.0),Vector3.UP)
	_interior.global_position=mount*Vector3(0,2.7,0)
