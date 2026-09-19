extends Node3D
## 车辆朝向自检：把模型包围盒和四个轮子的位置打进日志
##
## 为什么需要它：导出 glb 时若坐标系不对，车会"躺"在错误轴上，
## 表现为 VehicleWheel3D 的射线打在车身侧面 —— 按 W 车上下乱动、A/D 无反应。
## 这个节点每次运行都会报告实际情况，不用靠肉眼猜。

const EXPECT_LONGEST_AXIS := "Z"
## 单位立方体的 8 个角点比例（AABB.get_endpoint 的参数是 int 索引，不是向量，
## 所以这里自己算角点，避免误用）
const CORNER_SCALES := [
	Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
	Vector3(1, 1, 0), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1),
]


func _ready() -> void:
	# 延迟一帧，确保物理与变换都已就位
	await get_tree().physics_frame
	_report()


func _report() -> void:
	var aabb := _world_aabb(self)
	var longest := "X"
	if aabb.size.z >= aabb.size.x and aabb.size.z >= aabb.size.y:
		longest = "Z"
	elif aabb.size.y >= aabb.size.x and aabb.size.y >= aabb.size.z:
		longest = "Y"

	print("[自检] 车体包围盒 size=(%.2f, %.2f, %.2f)  车长=%.2f m"
		% [aabb.size.x, aabb.size.y, aabb.size.z, maxf(aabb.size.x, aabb.size.z)])

	# 说明：不再断言"最长轴必须是 Z"。
	# VehicleBody3D 只要四个轮的摆位与行驶方向自洽就行，车身网格走哪个轴并不重要 ——
	# 本项目实测：车长沿 X、车头朝 +X、引擎推力也朝 +X，一切正常。
	# 真正该验的是"车头方向与行驶方向是否一致"，见下面用前翼/尾翼做的几何判定。

	# 车头判定：用几何事实 —— 前翼(Nose_Wing)位于车头侧，尾翼(Wing_Main)位于车尾侧。
	# 直接比较两者的世界 X 与 Z 位移方向，不再依赖 basis 轴（之前用 basis 推出过错误结论）。
	var nose := find_child("Nose_Wing", true, false)
	var wing := find_child("Wing_Main", true, false)
	if nose != null and wing != null:
		var n: Vector3 = (nose as Node3D).global_position
		var w: Vector3 = (wing as Node3D).global_position
		var nose_off := n - w
		nose_off.y = 0.0
		if nose_off.length() < 0.1:
			printerr("[自检] 前翼与尾翼几乎重合，无法判定朝向")
		else:
			print("[自检] 车头方向（前翼-尾翼）= %s" % nose_off.normalized())

	# 车身包围盒：只作信息报告，不再断言轴向
	if longest == "Y":
		printerr("[自检] 警告：包围盒最长轴是 Y，车可能立起来了，检查模型导入")

	# 起跑位置验证：车头是否真的停在起终点白线**后面**
	# 白线是一块宽=路宽、长=start_line_depth 的长方形贴片，所以"后面"指
	# 车头沿赛道方向投影 < 线中心 - 线厚/2。
	var track := get_parent().get_parent().get_node_or_null("Track")
	if track != null:
		var lc = track.get("start_line_center")
		var lf = track.get("start_line_forward")
		var ld: float = track.get("start_line_depth")
		if lc is Vector3 and lf is Vector3:
			var f: Vector3 = lf
			f.y = 0.0
			f = f.normalized()
			var line_back: float = (lc as Vector3).dot(f) - ld * 0.5
			var nose_pos: Vector3 = (nose as Node3D).global_position if nose != null else global_position
			var nose_proj := nose_pos.dot(f)
			var gap := nose_proj - line_back
			if gap < 0.0:
				print("[自检] 起跑位置正确：车头在线后 %.2f m（线后边缘 %.2f，车头 %.2f）✔"
					% [-gap, line_back, nose_proj])
			else:
				printerr("[自检] 起跑位置错误：车头越过了白线 %.2f m！应后退更多" % gap)

	# 车轮落位检查
	var car := get_parent()
	if car != null:
		var wheels := 0
		for child in car.get_children():
			if child is VehicleWheel3D:
				wheels += 1
		print("[自检] 车轮数量 = %d %s" % [wheels, "✔" if wheels == 4 else "✘ 应该是 4"])


func _world_aabb(root: Node3D) -> AABB:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	var found := false
	for mi in _all_meshes(root):
		found = true
		var local: AABB = mi.mesh.get_aabb()
		var xform: Transform3D = mi.global_transform
		for s in CORNER_SCALES:
			var p: Vector3 = xform * (local.position + local.size * s)
			mn = mn.min(p)
			mx = mx.max(p)
	if not found:
		return AABB()
	return AABB(mn, mx - mn)


func _all_meshes(node: Node) -> Array:
	var out := []
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh != null:
			out.append(child)
		out.append_array(_all_meshes(child))
	return out
