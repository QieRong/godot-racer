extends SceneTree
## 真实MultiMesh九实例：远处不绘制，移动后恢复，实例数据不丢失。
var failed := 0
func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok: failed += 1
	print("STORE_VISIBILITY_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	var scenery := preload("res://scripts/track_scenery.gd").new()
	root.add_child(scenery)
	check(scenery.has_method("_refresh_store_visibility"), "便利店有独立实例距离可见性刷新")
	if failed > 0: scenery.free(); quit(1); return
	var focus := Node3D.new()
	root.add_child(focus)
	scenery.set("_store_focus", focus)
	var group := Node3D.new()
	group.set_meta("asset", "konbini_aoi_01")
	scenery.add_child(group)
	var placements: Array[Transform3D] = []
	for i in range(9): placements.append(Transform3D(Basis.IDENTITY, Vector3(i * 100, 0, 0)))
	scenery.call("_stamp", "konbini_aoi_01", placements, group, 450.0, "rain")
	scenery.call("_refresh_store_visibility")
	check(group.get_child_count() == 16, "九间店仍共用16个材质批次")
	var batch: MultiMesh = group.get_child(0).multimesh
	var original: Array[float] = []
	for i in range(9): original.append(batch.get_instance_transform(i).origin.x)
	original.sort()
	var near_visible := true
	for visual in group.get_children():
		near_visible = near_visible and visual.multimesh.instance_count == 9 and visual.multimesh.visible_instance_count == 5
	check(near_visible, "起点只绘制450m内的五间，保留九实例")
	focus.position.x = 800
	scenery.call("_refresh_store_visibility")
	var restored: Array[float] = []
	for i in range(9): restored.append(batch.get_instance_transform(i).origin.x)
	restored.sort()
	check(restored == original and batch.visible_instance_count == 5, "移到另一端后远店恢复且九实例位置完整")
	focus.position = Vector3(2000, 0, 0)
	scenery.call("_refresh_store_visibility")
	check(batch.visible_instance_count == 0 and batch.instance_count == 9, "全部远离时仅停绘，不销毁模型")
	scenery.free()
	focus.free()
	print("STORE_VISIBILITY_COMPLETE FAIL=", failed)
	quit(0 if failed == 0 else 1)
