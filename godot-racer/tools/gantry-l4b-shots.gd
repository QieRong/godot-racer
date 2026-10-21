extends SceneTree
## 【临时截图夹具 · GANTRY-L4-001B】自由机位渲染：真实第四关赛道 + 真实门架模块。
##
## 为什么不用现成的 --shot：--shot 只有追车相机（车在起跑线后方、镜头朝赛道前方），
## 拍得到"门横跨路面"，但**拍不到柱身与柱头的接缝**，也拍不到 90° 侧视 ——
## 而"柱头悬空""护栏穿柱身"正是用户反馈的落点，光靠数字断言不算"看得见"。
##
## 为什么又**不**直接跑 main.tscn：`godot --script` 模式下 autoload 不会被注册
## （Godot 4.4.1 实测：Identifier not found: GameState），main.gd 编译不过。
## 所以这里手工搭一个最小渲染环境（天空 + 平行光 + **真实的 Track** + **真实的
## start_gantry 模块**），机位自由 —— 渲染的是真资源，不是概念图。
##
## ⚠ 本轮（001B）修掉的一个真 bug：上一版是"先 add_child(track) 再 apply_to_track"，
##   而 track 的 defer_build_to_owner 已关 → _ready() 在 add_child 时就 build_world()
##   了，**关卡配置来得太晚**，拍出来的是默认 14m 宽的默认赛道。本版改成入树**之前**
##   挂 level_config（build_world 内部会自己 apply 一次，幂等）。
##
## 用法：
##   godot --path godot-racer --script res://tools/gantry-l4b-shots.gd -- \
##         --gantry-level=3 --gantry-out=<前缀绝对路径>
## 用完是否删除由主理人决定。

var _track: Node3D = null
var _frames := 0
var _poses: Array = []
var _idx := 0
var _wait := 0
var _level := 3
var _out := ""
var _ready_frame := -1
var _gantry: Node3D


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--gantry-level="):
			_level = int(a.split("=", true, 1)[1])
		elif a.begins_with("--gantry-out="):
			_out = a.split("=", true, 1)[1]
	if _out.is_empty():
		_out = ProjectSettings.globalize_path("res://").path_join("..").simplify_path().path_join("gantry-shot")
	print("SHOTS 关卡索引=%d 输出前缀=%s" % [_level, _out])
	var world := Node3D.new()
	world.name = "ShotWorld"
	root.add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.65
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 35.0, 0.0)
	sun.light_energy = 1.25          # ⚠ 不是 `energy`（那是别的东西的属性名）
	world.add_child(sun)
	# 真实赛道。⚠ 顺序：先关 defer 开关 + 挂关卡配置，**再**入树（_ready 里 build_world）。
	_track = load("res://scenes/track.tscn").instantiate()
	_track.set("defer_build_to_owner", false)
	var cfg: Resource = load("res://data/levels/level_%d.tres" % (_level + 1))
	if cfg != null:
		cfg.call("set_level_index", _level + 1)   # 地面贴图按索引拼约定路径，不设会退回 L1 草地绿
		_track.set("level_config", cfg)
		print("SHOTS 关卡配置 %s 已挂载（入树后由 build_world 自己 apply）" % cfg.get("display_name"))
	world.add_child(_track)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames > 1800:
		print("SHOTS 超时：赛道始终未就绪，放弃（避免挂死进程）")
		quit(2)
	if _ready_frame < 0:
		if _track != null and _track.has_method("is_world_ready") and bool(_track.call("is_world_ready")):
			_ready_frame = _frames
			_mount_gantry()
			_build_poses()
			print("SHOTS 赛道已就绪（第 %d 帧）：路宽 %s · 起跑线 %s"
				% [_frames, _track.get("road_width"), _track.get("start_line_center")])
		return false
	if _frames < _ready_frame + 4:
		return false
	_wait += 1
	if _wait == 1:
		_apply_pose(_poses[_idx])
		return false
	if _wait == 3:
		_capture(_poses[_idx]["name"])
		_idx += 1
		_wait = 0
		if _idx >= _poses.size():
			print("SHOTS 全部完成（%d 张）" % _poses.size())
			quit(0)
	return false


func _mount_gantry() -> void:
	var mod: Node3D = load("res://scripts/start_gantry.gd").new()
	mod.call("setup", _track, _level)
	_track.get_parent().add_child(mod)
	_gantry = mod.get_node_or_null("StartGantry")


func _build_poses() -> void:
	var c: Vector3 = _gantry.global_position if _gantry != null else _track.get("start_line_center")
	var fwd: Vector3 = _track.get("start_line_forward")
	fwd.y = 0.0
	fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var rw := float(_track.get("road_width"))
	# 柱心横向坐标：与 start_gantry.gd 同一套口径（护栏视觉外侧面 + 净距 + 半个柱厚），
	# 只用于取景，不参与摆放。
	var constants: Dictionary = load("res://scripts/start_gantry.gd").get_script_constant_map()
	var height: float = constants["GATE_TARGET_HEIGHT_M"]
	var s: float = height / float(constants["MODEL_HEIGHT_M"])
	var rail_half := float(_track.call("rail_half_width"))
	var rt: Variant = _track.get("rail_visual_thickness")
	var rail_thick := float(rt) if rt != null else 0.35
	var post_c: float = rail_half + rail_thick + float(constants["GATE_CLEARANCE_M"]) \
		+ float(constants["POST_THICKNESS_M"]) * s * 0.5
	_poses = [
		# ① 正视：从起跑线后方沿赛道看过去 → 判"横跨且不占路面""柱子在护栏外"
		{"name": "front", "pos": c - fwd * 36.0 + Vector3.UP * height * 0.55,
			"target": c + Vector3.UP * height * 0.5},
		# ② 侧视：垂直于赛道看整座门 → 判柱脚在护栏外、门洞净高、柱身不内倾
		{"name": "side", "pos": c + side * 30.0 + Vector3.UP * height * 0.6,
			"target": c + Vector3.UP * height * 0.5},
		# ③ 柱头特写：贴着右侧柱子的柱身/柱头接缝看 → 判"柱头落在柱身上"（无缝）
		{"name": "capital", "pos": c + side * (post_c + 10.0) + fwd * 1.5 + Vector3.UP * height * 0.86,
			"target": c + side * post_c + Vector3.UP * float(constants["CAPITAL_BOTTOM_Y"]) * s},
	]
	print("SHOTS 路宽 %.2f · 护栏内 %.3f/外 %.3f · 柱心横向 %.3f · 机位 %d 个"
		% [rw, rail_half, rail_half + rail_thick, post_c, _poses.size()])


func _apply_pose(p: Dictionary) -> void:
	var cam := root.get_node_or_null("GantryShotCam") as Camera3D
	if cam == null:
		cam = Camera3D.new()
		cam.name = "GantryShotCam"
		cam.fov = 55.0
		root.add_child(cam)
	cam.make_current()
	cam.global_position = p["pos"]
	cam.look_at(p["target"], Vector3.UP)
	print("SHOTS 机位 %s：pos=%s → target=%s" % [p["name"], p["pos"], p["target"]])


func _capture(name: String) -> void:
	var img := root.get_texture().get_image()
	if img == null:
		print("SHOTS 截图失败：拿不到 viewport 图像")
		return
	var path := "%s-%s.png" % [_out, name]
	var err := img.save_png(path)
	print("SHOTS 已保存 %s（%dx%d，err=%d）" % [path, img.get_size().x, img.get_size().y, err])
