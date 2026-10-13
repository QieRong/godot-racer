extends RefCounted
## 截图模式族（`--shot` / `--shot-frames` / `--shot-hold` / `--shot-steer` /
## `--shot-view` / `--shot-drive=1` / `--shot-wrongway=N` / `--shot-out`）：
## 命令行解析 + 逆方向摆位 + `_process` 里的截图主体（存 PNG / 诊断打印 / 退出）。
## 唯一外部驱动是 `04-Godot启动器/shoot.ps1`；`run-check.ps1` / `run-all-checks.ps1`
## 不引用 shot，CLI 契约零变化，闸门脚本一律不动。
##
## 2026-10-13 SPLIT-SCREENSHOT-001：从 scenes/main.gd 整块拆出，**纯迁移、行为零变化** ——
## 常量数值、逻辑、print 文案（连 `[截图]` 前缀都原样留着，改前缀会让 A/B 日志整片不同）、
## 注释全部照搬（包括 `_shot_block` 这类**过时面包屑**：迁移前就是这样，不顺手"修"），
## 没有第二份实现。
## 迁了什么：
##   · 10 个 `_shot_*` 状态（私有，本模块独有，main.gd 不再持有）；
##   · 3 个函数：`_parse_shot_args` → `parse_args`、`_shot_wrongway_warp` →
##     `wrongway_warp`、`_process` 里的截图主体 → `tick()`，去掉下划线前缀成为
##     公开方法，与 autopilot.gd / l4_debug_diag.gd 的公开 API 风格一致。
##
## ⚠ 与 opponent_spawner.gd 的异同（本次拆分的两处关键决策，逐条定死，以后别悄悄改回去）：
##
##   ① **注入方式相同、对象不同**：car / track / camera 原是 main 里
##      `get_node_or_null("RaceCar"/"Track"/"ChaseCamera")` 取的**静态兄弟节点**
##      （main.tscn 已确认存在），改为 setup() 注入引用，**null 检查原样保留**；
##      autopilot / engine_audio 注入 main 持有的**实例**（同 _l4_diag 先例：
##      preload 第二份会拿到空状态，A/B 与取证全部失真 —— 最终打印要读的
##      `frames_pushed` 正是 main 实例上的计数器）；场景能力（取 viewport 图像 /
##      退出 / physics_frame 信号）用 **Callable 注入**，与 opponent_spawner 的
##      _mount 回调同一约定（§2.4：模块不持有场景）。
##      （备选方案"模块自己 get_node"已否决：那正是 §2.4 禁的反向持有场景；
##        备选方案"capture_image 让模块直接拿 Viewport 纹理"已否决：模块是
##        RefCounted，不在树上，没有 get_viewport()。）
##
##   ② **await 数是 2，不是 0**：两处都在 wrongway_warp（等赛道建好 +
##      等半秒物理稳定），迁移前就在 main 里，一个都没多。本模块不像
##      opponent_spawner 要求 0 await —— 那条专指**物理基线采样路径**
##      （每帧恢复时机差 1 帧就会让跑圈日志发散，实测 25856 行）；这里是截图专用的
##      一次性协程，迁移前同样经 `call_deferred` 从 `_process` 启动、协程深度一致
##      （原来：main._process → main._shot_wrongway_warp 协程；现在：main._process
##       → tick() → 模块协程，await 的都是同一批 Signal）。由
##      split-screenshot-structcheck.ps1 把「2」钉死，禁止第三人加 await 改变协程深度。
##
## ⚠ 为什么没有 class_name（与 environment.gd / engine_audio.gd / l4_debug_diag.gd /
##   autopilot.gd / opponent_spawner.gd 同一约定）：本项目的验收闸门
##   （parse-check / run-check / run-all-checks）在**无编辑器**环境里跑 Godot，
##   而 class_name 的全局注册表（.godot/global_script_class_cache.cfg）**只有编辑器会重建**。
##   2026-10-12 实测：新增 class_name 后 --check-only 与游戏运行双双报
##   `Identifier "X" not declared in the current scope`。因此消费方一律用
##   `const ScreenshotMode := preload("res://scripts/screenshot_mode.gd")` 引用本模块。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car = $RaceCar）。由 setup() 注入。
var _car: VehicleBody3D = null
## 赛道（原是 main 里 get_node_or_null("Track") 的静态兄弟节点）。由 setup() 注入。
var _track: Node3D = null
## 追车相机（原是 main 里 get_node_or_null("ChaseCamera") 的静态兄弟节点）。由 setup() 注入。
var _camera: Node3D = null
## 验收自动驾驶实例（main.gd 的 _autopilot）：`--shot-drive` 分支的 drive_track 用。
## 注入实例而不是 preload 第二份（同 _l4_diag 先例，见文件头决策 ①）。
var _autopilot = null
## 占位引擎声实例（main.gd 的 _engine_audio）：最终打印读 frames_pushed。
var _engine_audio = null
## 取 viewport 一帧图像的回调（main.gd 的 _shot_capture_image）。由 setup() 注入。
var _capture_image: Callable = Callable()
## 退出进程的回调（main.gd 的 _shot_quit_app）。由 setup() 注入。
var _quit_app: Callable = Callable()
## physics_frame 信号提供者（main.gd 的 _shot_physics_frame）。由 setup() 注入；
## 模块里 `await _physics_frame.call()` 取代 `await get_tree().physics_frame`，
## 是同一个 Signal，协程恢复时机不变（文件头决策 ②）。
var _physics_frame: Callable = Callable()
## wrongway_warp 里静态调用（纯函数，无状态可直调，§2.4 约定）。
const Autopilot := preload("res://scripts/autopilot.gd")

# ---------------------------------------------------------------- 本模块持有的状态
# 截图模式的内部状态（只有带 --shot 启动时才用）
var _shot_mode := false
var _shot_frames := 150
var _shot_hold := 0
var _shot_steer := 0
var _shot_view := -1
var _shot_out := ""
var _shot_frame := 0
## `--shot-drive=1`：截图前用**自动驾驶**把车开起来（见 _shot_block 的说明）。
##
## 为什么必须有它：原来 --shot 只能"按住 W 直线冲"或"停着打方向"，
## 于是**没有任何办法给"车在赛道上的实际位置"留一张图**。
## 而"车跑到哪里去了"恰恰是好几类 bug 唯一看得见的证据（掉头后倒着开、
## 卡在护栏内侧、贴墙推头、复位落点错误……），日志里的坐标数字远不如一张图直观。
var _shot_drive := false
## `--shot-wrongway=1`：截图前把车头拧到赛道反方向并以 ~60 km/h 前进，
## 把「方向反了」提示条**拍进图里**（`--shot-wrongway=2` 改为按 S 倒车，用来拍"不提示"）。
var _shot_wrongway := 0
## 车头是否已经拧过（只拧一次，否则每帧重置就永远开不出去）
var _shot_wrongway_flipped := false

## 截图模式是否激活的只读取值口。main.gd 的 _process 钩子
## `if not _screenshot_mode.mode: return` 就是代理到这里（与 _opponents 的只读
## getter 代理同一约定：main 不持有第二份状态）。
var mode: bool:
	get:
		return _shot_mode


## 注入外部引用（main.gd 在 _after_world_ready 里、_autopilot.setup(...) 之后调用一次）。
func setup(car: VehicleBody3D, track: Node3D, autopilot, engine_audio, camera: Node3D,
		capture_image: Callable, quit_app: Callable, physics_frame: Callable) -> void:
	_car = car
	_track = track
	_autopilot = autopilot
	_engine_audio = engine_audio
	_camera = camera
	_capture_image = capture_image
	_quit_app = quit_app
	_physics_frame = physics_frame


## 截图模式。
##
## 为什么不挂在 --script 上：本机 Godot 4.4.1 里 **`--path` 与 `--script` 同时使用必崩**
## （signal 11，连一个只 print 然后 quit 的空脚本都崩；而单独用 --script 不带 --path
## 也时好时坏）。所以截图能力改挂在主场景里，走的是完全没问题的 `--path` 路径。
##
## 用法：
##   godot --path <工程> -- --shot --shot-frames=150 --shot-hold=120 --shot-out=<绝对路径>
##
## 注意**不能加 --headless**（4.4.1 里 --headless 不是有效参数，会被忽略并直接跑主场景）；
## 另外窗口化运行必须用 `start` 分离启动，前台直接跑会段错误。
## 窗口会真的出现几秒，到点存 PNG 后自动退出。
##   --shot-frames=N  第 N 帧截图（默认 150，约 2.5 秒）
##   --shot-hold=N    前 N 帧模拟按住 W（行驶状态，默认 0）
##   --shot-steer=N   前 N 帧模拟按住 A（打方向，默认 0。配合 hold=0 可让车停着打方向，
##                    用来单独检查前轮有没有偏转）
##   --shot-view=N    直接切到第 N 个视角（0 第一人称 / 1 第二人称 / 2 第三人称）
##   --shot-drive=1   截图前用**自动驾驶**开 `--shot-frames` 帧（而不是"按住 W 直冲"）
##   --shot-wrongway=N 截图前把车头拧到赛道反方向：N=1 前进（拍"提示亮起"）、
##                    N=2 倒车（拍"倒车不提示"）。用来给方向提示留图。
##   --shot-out=PATH  输出路径，默认写到工程目录的上一级 godot-shot.png
##
## ⚠ **--shot-drive 是用来"看车在哪里"的**（2026-09 定下的规矩）：
##   日志里的坐标是数字，看不出车在不在路面上；而"掉头后倒着开""卡在护栏内侧"
##   "贴着墙推头"这几类问题**只有一张图能一眼定案**。
##   测试任何跟"车的位置/姿态"有关的东西时，除了数字断言，都必须补一张图。
##   ⚠ 它不做掉头恢复（`_drive_recover` 是验收检查的东西）：就是要让你**看得见**
##     车有没有朝后 —— 被自动修好了反而看不见。
func parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--shot"):
		return
	_shot_mode = true
	for a in args:
		if a.begins_with("--shot-frames="):
			_shot_frames = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-hold="):
			_shot_hold = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-steer="):
			_shot_steer = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-view="):
			_shot_view = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-drive="):
			_shot_drive = int(a.split("=", true, 1)[1]) != 0
		elif a.begins_with("--shot-wrongway="):
			_shot_wrongway = int(a.split("=", true, 1)[1])
		elif a.begins_with("--shot-out="):
			_shot_out = a.split("=", true, 1)[1]
	if _shot_out.is_empty():
		_shot_out = ProjectSettings.globalize_path("res://").path_join("..").simplify_path().path_join("godot-shot.png")
	if _shot_view >= 0:
		var cam := _camera
		if cam != null and cam.has_method("set_view_mode"):
			cam.call("set_view_mode", _shot_view)
	print("[截图] 开关已打开：第 %d 帧存到 %s（按住 W %d 帧 / 按住 A %d 帧 / 视角 %d / 自动驾驶=%s / 倒车=%s）"
		% [_shot_frames, _shot_out, _shot_hold, _shot_steer, _shot_view, str(_shot_drive), str(_shot_wrongway)])


## 等赛道建好，再把车头拧到赛道反方向（`--shot-wrongway` 用）。
##
## 为什么必须是 await 的独立函数：`--shot` 的 `_process` 第一帧就跑，
## 而赛道是延迟构建的。第一版在主循环里直接摆位 → 车落在世界里某个荒谬位置后
## **坠落**（截图：346 km/h、脚下一片空白大地、小地图全黑，看着像 Godot 崩了）。
func wrongway_warp() -> void:
	var track := _track
	if track == null or _car == null:
		printerr("[截图] 方向提示演示：找不到 Track 或玩家车，放弃摆位")
		return
	if track.has_method("await_world_ready"):
		await track.call("await_world_ready")
	# 再等一拍让物理稳定（与验收检查里的做法一致：先落地再判定）
	for i in range(int(Engine.physics_ticks_per_second) * 0.5):
		await _physics_frame.call()
	var wn: Dictionary = track.call("nearest_on_centerline", _car.global_position, -1.0)
	var wf: Vector3 = wn.get("forward", Vector3.FORWARD)
	wf.y = 0.0
	if wf.length() < 0.001:
		printerr("[截图] 方向提示演示：拿不到赛道切线方向，放弃摆位")
		return
	wf = wf.normalized()
	var wc: Vector3 = wn.get("pos", _car.global_position)
	# 位置用中心线、**只抬 0.6m**（与 AI 出生同一口径）：抬太高会"掉下来"，
	# 落地那几帧速度会污染判定。
	_car.global_position = wc + Vector3(0, 0.6, 0)
	_car.global_transform = Autopilot.pose_facing(_car.global_position, -wf)   # 车头反 180°
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	# 给一个初速，好让它达到阈值以上（规格要求"以 60 km/h 行驶"）。
	# ⚠ 速度方向必须是**赛道正方向**：车头朝后 + 沿赛道正向运动 = 正在"开反了"。
	if _shot_wrongway == 1:
		_car.linear_velocity = wf * (60.0 / 3.6)
	print("[截图] 方向提示演示：车头已拧到赛道反方向（模式=%d，1=前进 2=倒车），位置 %s 切线 %s"
		% [_shot_wrongway, _car.global_position, wf])


## 截图主体：由 main.gd 的 _process 在 `if not _screenshot_mode.mode: return` 之后调用。
## **不接收 delta** —— 原主体本来就不用 _delta（迁移前在 main.gd 的 _process 里）。
func tick() -> void:
	_shot_frame += 1
	if _shot_wrongway > 0:
		# ⚠ 提示的判据是「**车头**朝赛道反方向 且 速度 ≥ 阈值」，
		#   所以必须先**把车头拧到反方向**再给油。
		#   `=2` 时相反：按 S 倒车 —— 规格明确要求倒车**不**提示，
		#   用来拍"不显示提示"的那张对照图。
		#
		# ⚠⚠ 这套动作**必须等赛道建好**（实测踩坑，白瞎了两张图）：
		#   `--shot` 的 `_process` 从第一帧就跑，而赛道是**延迟构建**的
		#   （Track 由 main.gd 在 ready 后 `build_world.call_deferred()`）。
		#   第一版在这里直接调 `nearest_on_centerline()` + 摆位 —— 那时中心线还是空的，
		#   摆位落在世界里某个荒谬位置，车随即**坠落**：截图出来是"346 km/h、
		#   脚下一片空白大地、小地图全黑"，看起来像 Godot 的启动段错误，
		#   其实是"在赛道出生之前就把车摆好了"。所以交给一个 await 的辅助函数去做。
		if not _shot_wrongway_flipped:
			_shot_wrongway_flipped = true
			wrongway_warp.call_deferred()
		Input.action_release("accelerate")
		Input.action_release("brake_reverse")
		if _shot_wrongway == 1:
			Input.action_press("accelerate")
		else:
			Input.action_press("brake_reverse")
	elif _shot_drive:
		# 自动驾驶：把车真的开上赛道，这样截图上看到的是"车在赛道上的实际位置/姿态"。
		# 不加 `_drive_recover`（刻意）：恢复会把掉头悄悄修好，而这张图的意义正是
		# **让你看见车有没有朝后/卡住**。
		var track := _track
		if track != null and _car != null:
			_autopilot.drive_track(track, 45.0)
	elif _shot_frame <= _shot_hold:
		Input.action_press("accelerate")
	elif _shot_frame == _shot_hold + 1:
		Input.action_release("accelerate")
	# 正数 = 按住 A（左舵），负数 = 按住 D（右舵），0 = 不打方向
	if _shot_steer != 0:
		var act := "steer_left" if _shot_steer > 0 else "steer_right"
		var n := absi(_shot_steer)
		if _shot_frame <= n:
			Input.action_press(act)
		elif _shot_frame == n + 1:
			Input.action_release(act)
	if _shot_frame < _shot_frames:
		return

	_shot_mode = false
	# 顺便把关键状态打出来，便于和画面对照
	# ⚠ 这里还额外报"离中心线多远 / 车头与赛道夹角"——**截图必须配这两个数**，
	#   否则一张图只能看出"大概在路上"，说不出偏了多少、有没有朝后。
	var car := _car
	if car is VehicleBody3D:
		print("[截图] 车 pos=%s  steering=%.3f rad  车速=%.1f km/h"
			% [(car as Node3D).global_position, (car as VehicleBody3D).steering,
			   (car as VehicleBody3D).linear_velocity.length() * 3.6])
		var sh_track := _track
		if sh_track != null:
			var sh_near: Dictionary = sh_track.call("nearest_on_centerline",
				(car as Node3D).global_position, -1.0)
			var sh_fwd: Vector3 = sh_near.get("forward", Vector3.FORWARD)
			sh_fwd.y = 0.0
			var sh_nose: Vector3 = -(car as Node3D).global_transform.basis.z
			sh_nose.y = 0.0
			var sh_head := -1.0
			if sh_fwd.length() > 0.001 and sh_nose.length() > 0.001:
				sh_head = rad_to_deg(acos(clampf(sh_nose.normalized().dot(sh_fwd.normalized()), -1.0, 1.0)))
			print("[截图] 离中心线 %.2fm（半路宽 %.2fm）  车头与赛道夹角 %.1f°%s"
				% [float(sh_near.get("dist", 0.0)), float(sh_track.call("road_half_width")),
				   sh_head, "  ✘ 车头朝后！" if sh_head > 100.0 else ""])
	# 相机诊断：用来量"相机会不会自己往车尾凑"
	var cam := _camera
	if cam is Camera3D and car is Node3D:
		var dist := (cam as Camera3D).global_position.distance_to((car as Node3D).global_position)
		print("[截图] 相机 pos=%s  离车 %.2f m  高度 %.2f m"
			% [(cam as Camera3D).global_position, dist, (cam as Camera3D).global_position.y])
	var img: Image = _capture_image.call()
	if img == null:
		printerr("[截图] 拿不到 viewport 图像")
	else:
		var err := img.save_png(_shot_out)
		print("[截图] save_png -> %d  尺寸=%s  路径=%s" % [err, img.get_size(), _shot_out])
	print("[截图] 累计推送音频帧 = %d（应远大于单个缓冲 0.5s×22050≈11025，说明是流式续填而非一次灌满）"
		% _engine_audio.frames_pushed)
	print("[截图] 结束，退出")
	_quit_app.call()
