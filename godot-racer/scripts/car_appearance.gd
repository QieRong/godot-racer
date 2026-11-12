extends Resource
## 统一车辆视觉配置。换模型仍需满足CarModel/轮网格契约，不调整碰撞或物理。
@export var model_scene: PackedScene
@export var vehicle_transform := Transform3D(Basis(Vector3(4.37114e-08, 0, 1), Vector3.UP, Vector3(-1, 0, 4.37114e-08)), Vector3.ZERO)

@export var trim_material: StringName
@export var trim_color := Color.WHITE

func instantiate_model() -> Node3D:
	var model := model_scene.instantiate() as Node3D
	if trim_material.is_empty():
		return model
	var trim: StandardMaterial3D
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		for surface in range(mesh.mesh.get_surface_count()):
			var material := mesh.get_active_material(surface) as StandardMaterial3D
			if material == null or material.resource_name != trim_material:
				continue
			if trim == null:
				trim = material.duplicate() as StandardMaterial3D
				trim.albedo_color = trim_color
			mesh.set_surface_override_material(surface, trim)
	return model

func apply_to_vehicle(car: Node3D) -> void:
	var current := car.get_node("CarModel") as Node3D
	if current.scene_file_path == model_scene.resource_path:
		current.transform = vehicle_transform
		return
	var visual := instantiate_model()
	car.remove_child(current)
	current.queue_free()
	visual.name = "CarModel"
	visual.transform = vehicle_transform
	car.add_child(visual)
