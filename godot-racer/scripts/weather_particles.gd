extends GPUParticles3D
## 发射体跟随当前视角，已发射粒子保持世界坐标，风向不随车转弯。
var sand := false
var follow_camera: Camera3D
var _wind_time := 0.0

func _process(delta: float) -> void:
	var camera: Camera3D = follow_camera if is_instance_valid(follow_camera) else get_viewport().get_camera_3d()
	if camera == null: return
	global_transform = Transform3D(Basis.IDENTITY, camera.global_position + Vector3.UP * 8.0)
	var far := get_node_or_null("FarRain") as GPUParticles3D
	if far != null:
		far.global_position = camera.global_position - camera.global_basis.z * 45.0 + Vector3.UP * 23.0
	if sand:
		_wind_time += delta
		var material := process_material as ParticleProcessMaterial
		material.gravity = Vector3(1.4 + sin(_wind_time * 0.7) * 0.7, -1.8, 0.5)
