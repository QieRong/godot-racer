extends SceneTree
## 资产真实导入后的结构/预算检查；不替代场景截图和真人U。
var passed := 0
var failed := 0

func check(ok: bool, message: String) -> void:
	if ok: passed+=1
	else: failed+=1
	print("KONBINI_ASSERT %s %s" % ["PASS" if ok else "FAIL",message])

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var path := "res://models/environment/konbini_aoi_01.glb"
	check(ResourceLoader.exists(path),"原创便利店GLB已导入")
	if failed>0:
		print("KONBINI_COMPLETE PASS=%d FAIL=%d" % [passed,failed]);quit(1);return
	var model: Node3D = load(path).instantiate()
	root.add_child(model)
	var batches := 0
	var triangles := 0
	var emissive := 0
	var glass := 0
	var lower := Vector3(INF,INF,INF)
	var upper := -lower
	for node in model.find_children("*","MeshInstance3D",true,false):
		batches+=1
		var mesh: Mesh = node.mesh
		var bounds := mesh.get_aabb()
		for i in range(8):
			var point: Vector3 = node.global_transform*bounds.get_endpoint(i)
			lower=lower.min(point);upper=upper.max(point)
		for i in range(mesh.get_surface_count()):
			triangles+=mesh.surface_get_array_index_len(i)/3
			var material := node.get_active_material(i) as StandardMaterial3D
			if material!=null:
				if material.emission_enabled: emissive+=1
				if material.transparency!=BaseMaterial3D.TRANSPARENCY_DISABLED: glass+=1
	var size := upper-lower
	check(batches>5 and batches<=20,"按材质合批的模型网格数量5-20")
	check(triangles>=3000 and triangles<=22000,"门面细节几何存在且三角面预算<=22000：%d" % triangles)
	check(size.x>=10.0 and size.x<=17.0 and size.y>=3.5 and size.y<=7.0 and size.z>=7.0 and size.z<=13.0,
		"真实导入尺寸为米制便利店：%s" % size)
	check(absf(lower.y)<0.03,"店前基座贴地，导入原点Y=0")
	check(emissive>=3,"招牌/室内灯/机器发光材质保留")
	check(glass>0,"门窗有独立玻璃材质")
	check(model.find_children("*","CollisionObject3D",true,false).is_empty(),"装饰模型无碰撞")
	check(model.find_children("*","Light3D",true,false).is_empty(),"模型不附带实时灯光")
	model.free()
	await process_frame
	print("KONBINI_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
