extends SceneTree
## 解析几何红例：沿斜向道路的盒形车，不能先取世界轴对齐包围盒再投影。
class StubTrack extends Node:
	func nearest_on_centerline(_pos: Vector3, _hint: float = -1.0) -> Dictionary:
		return {"pos":Vector3.ZERO,"forward":Vector3(1.0,0.0,1.0).normalized()}

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var track := StubTrack.new()
	root.add_child(track)
	var car := VehicleBody3D.new()
	root.add_child(car)
	var model := MeshInstance3D.new()
	model.name = "CarModel"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.6,0.7,3.4)
	model.mesh = mesh
	car.add_child(model)
	var forward := Vector3(1.0,0.0,1.0).normalized()
	var side := Vector3(forward.z,0.0,-forward.x)
	car.global_basis = Basis.looking_at(forward,Vector3.UP)
	car.global_position = side*8.5
	# GameState autoload注册完成后再载入现有验收模块，与正常场景时序相同。
	var checks = load("res://scripts/checks/env_phys.gd").new()
	checks.setup(car,track,null,null,null,Callable())
	var measured: float = checks._visual_lateral_extent(track)
	var correct := absf(measured-9.3)<0.0001
	print("PROJECTION_ASSERT %s diagonal box exact 9.3m; measured %.6f" % ["PASS" if correct else "FAIL",measured])
	var limit := 10.57
	car.global_position = side*(limit-0.8+0.05)
	var outside: float = checks._visual_lateral_extent(track)
	var rejects := outside>limit
	print("PROJECTION_ASSERT %s real 0.05m protrusion rejected; measured %.6f limit %.6f" % ["PASS" if rejects else "FAIL",outside,limit])
	car.free()
	track.free()
	print("PROJECTION_COMPLETE PASS=%d FAIL=%d" % [int(correct)+int(rejects),int(not correct)+int(not rejects)])
	quit(0 if correct and rejects else 1)
