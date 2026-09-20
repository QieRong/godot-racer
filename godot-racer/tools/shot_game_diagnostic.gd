extends SceneTree
## 截图诊断：真的把游戏画面渲染出来存成 PNG，用来核对"渲染内容"与"物理状态"是否一致。
##
## 背景：无头模拟里车能跑完整圈，但用户实际运行时只看到草地和天空、车和赛道都不见了。
## 这种"物理对但画面错"的问题只能靠看真实渲染结果来定位。
##
## 运行：godot --path <项目> --script res://shot_game.gd
## 输出：写到项目目录的上一级（即 data-analysis/godot-shot.png）

const SHOT_FRAME := 120        # 等多久再截图（让相机完成平滑跟随）

var _main: Node = null
var _frames := 0


func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	_main = packed.instantiate()
	root.add_child(_main)
	print("SHOT 主场景已加载")


func _process(_delta: float) -> bool:
	_frames += 1
	# 前 3 秒模拟按住 W，让车跑起来，顺便验证 HUD 是否真的在刷新
	if _frames <= 180:
		Input.action_press("accelerate")
	elif _frames == 181:
		Input.action_release("accelerate")
	if _frames == 5:
		_dump_state()
	if _frames < SHOT_FRAME:
		return false
	_do_capture()
	return true


func _dump_state() -> void:
	var car := _main.get_node_or_null("RaceCar")
	var cam := _main.get_node_or_null("ChaseCamera")
	print("SHOT --- 场景状态 ---")
	if car is Node3D:
		print("SHOT 车 位置=%s  旋转=%.1f°"
			% [(car as Node3D).global_position, rad_to_deg((car as Node3D).global_rotation.y)])
		print("SHOT 车 可见=%s  父节点=%s"
			% [(car as Node3D).visible, (car as Node3D).get_parent().name])
		var model := (car as Node3D).get_node_or_null("CarModel")
		if model is Node3D:
			print("SHOT 模型 位置=%s 可见=%s"
				% [(model as Node3D).global_position, (model as Node3D).visible])
			var meshes := _count_meshes(model)
			print("SHOT 模型下网格节点数=%d" % meshes)
	if cam is Camera3D:
		print("SHOT 相机 位置=%s" % (cam as Camera3D).global_position)
		print("SHOT 相机 当前=%s  朝向=%s"
			% [(cam as Camera3D).current, -(cam as Camera3D).global_transform.basis.z])
		print("SHOT 相机 near=%.3f far=%.1f fov=%.1f"
			% [(cam as Camera3D).near, (cam as Camera3D).far, (cam as Camera3D).fov])
	var track := _main.get_node_or_null("Track")
	if track != null:
		var road := track.get_node_or_null("RoadMesh")
		if road is MeshInstance3D:
			var mi: MeshInstance3D = road
			print("SHOT 路面 网格=%s  可见=%s  包围盒=%s"
				% [mi.mesh, mi.visible, mi.get_aabb()])
		else:
			print("SHOT 路面节点 RoadMesh 不存在！Track 的子节点: %s" % _child_names(track))


## 输出路径从项目目录反推，不写死绝对路径：
## res:// 打包后只读，所以先 globalize 拿到真实磁盘路径，再往上退一级
## （本脚本位于 <项目根>/godot-racer/ 下）。
func _do_capture() -> void:
	_dump_state()
	var out_path := ProjectSettings.globalize_path("res://").path_join("..").simplify_path().path_join("godot-shot.png")
	var img := root.get_texture().get_image()
	if img == null:
		print("SHOT 截图失败：拿不到 viewport 图像")
		return
	img.save_png(out_path)
	print("SHOT 已保存 %s  尺寸=%s" % [out_path, img.get_size()])


func _count_meshes(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if c is MeshInstance3D:
			n += 1
		n += _count_meshes(c)
	return n


func _child_names(node: Node) -> String:
	var out := PackedStringArray()
	for c in node.get_children():
		out.append(c.name)
	return ", ".join(out)
