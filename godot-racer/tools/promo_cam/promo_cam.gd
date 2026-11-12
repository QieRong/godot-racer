extends Node3D
## 宣传片取景夹具（只读采集，不属于游戏玩法；不动物理、不改车、不改 HUD 逻辑）。
##
## 为什么需要它：游戏自带的 ChaseCamera 只有三档（第一/第二/第三人称），
## 拍宣传片缺鸟瞰、缺路边过弯机位、缺低机位。这里用**外层容器场景 + 独立相机**
## 接管画面，游戏场景本身按 `scenes/main.tscn` 原样跑 —— 巡览、倒计时、发车、
## 冲线、结算全部走真实流程，只在录制时换机位。
##
## 用法（`--` 之后是用户参数）：
##   godot --path <工程> --write-movie out.avi --fixed-fps 30 --quit-after N \
##         res://tools/promo_cam/promo_capture.tscn -- --level=2 \
##         --cam=aerial --cam-drive=1
##
## --cam=game       不接管（用游戏自己的相机，录制 HUD 完整画面）
## --cam=aerial     鸟瞰：绕车缓慢环绕，高度/半径可用参数改
## --cam=aerial_wide 大范围鸟瞰
## --cam=trackside  路边机位：自动找前方曲率最大的弯，站在弯外侧拍车驶过
## --cam=low        低机位近距离跟随（过弯时车身侧倾、贴地速度感）
## --cam=fpv        第一人称车头视角（与游戏内视角 0 同参数）
## --cam-orbit=<rad/s>  鸟瞰环绕角速度（默认 0.16）
## --cam-radius=<m> / --cam-height=<m>
## --cam-drive=1    用工程自带自动驾驶把车真的开起来（与验收同一套 drive_track）
## --cam-nohud=1    取景时隐藏 HUD（只用于纯环境/鸟瞰镜头）

const DEFAULT_AHEAD := 45.0

var _cam: Camera3D = null
var _main: Node = null
var _car: VehicleBody3D = null
var _track: Node = null
var _hud: CanvasLayer = null
var _autopilot = null

var _mode := "game"
var _orbit := 0.16
var _radius := 24.0
var _height := 19.0
var _drive := false
var _nohud := false
var _t := 0.0
var _sideline_arc := -99999.0
var _sideline_pos := Vector3.ZERO
var _sideline_ok := false
var _pos := Vector3.ZERO
var _look := Vector3.ZERO
var _primed := false
var _level_req := -1
var _debug := false
var _dbg_n := 0
var _cd_started := false
var _cd_reported := false
var _cd_ai0 := Vector3.ZERO
var _cd_ai_max := 0.0
var _cd_pl_max := 0.0
var _cd_pl0 := Vector3.ZERO


## ⚠ 必须在 _enter_tree 里定关卡：`--level=` 只有 menu.gd 解析，直接跑本容器场景
## 不经过菜单，GameState 会停在默认第 0 关 —— 五个机位会全拍成训练营。
## _enter_tree 早于子节点 Main 的 _ready，赶在它读 current_level() 之前生效。
func _enter_tree() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--level="):
			# 不在这里 clamp：此刻 GameState 的关卡表可能还没读完（level_count()==0），
			# 用 level_count() 夹会把任何关卡都压成 0。
			_level_req = int(a.split("=", true, 1)[1])
			GameState.chosen_level = _level_req


func _ready() -> void:
	_parse_args()
	_main = get_node_or_null("Main")
	if _level_req >= 0:
		GameState.chosen_level = _level_req
		var cfg := GameState.current_level()
		print("[宣传取景] 关卡=%d / %s" % [GameState.chosen_level,
			cfg.display_name if cfg != null else "?"])
	_cam = Camera3D.new()
	_cam.name = "PromoCamera"
	_cam.fov = 62.0
	_cam.near = 0.2
	_cam.far = 6000.0
	add_child(_cam)
	set_physics_process(true)
	print("[宣传取景] mode=%s orbit=%.2f radius=%.1f height=%.1f drive=%s nohud=%s"
		% [_mode, _orbit, _radius, _height, str(_drive), str(_nohud)])


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cam="):
			_mode = a.split("=", true, 1)[1]
		elif a.begins_with("--cam-orbit="):
			_orbit = float(a.split("=", true, 1)[1])
		elif a.begins_with("--cam-radius="):
			_radius = float(a.split("=", true, 1)[1])
		elif a.begins_with("--cam-height="):
			_height = float(a.split("=", true, 1)[1])
		elif a.begins_with("--cam-drive="):
			_drive = int(a.split("=", true, 1)[1]) != 0
		elif a.begins_with("--cam-nohud="):
			_nohud = int(a.split("=", true, 1)[1]) != 0
		elif a.begins_with("--cam-debug="):
			_debug = int(a.split("=", true, 1)[1]) != 0


func _resolve() -> void:
	if _main == null:
		_main = get_node_or_null("Main")
		if _main == null:
			return
	if _car == null or not is_instance_valid(_car):
		_car = _main.get_node_or_null("RaceCar") as VehicleBody3D
	if _track == null or not is_instance_valid(_track):
		_track = _main.get_node_or_null("Track")
	if _hud == null or not is_instance_valid(_hud):
		_hud = _main.get_node_or_null("HUD") as CanvasLayer
	if _autopilot == null:
		_autopilot = _main.get("_autopilot")
	# 游戏自带「视角 3/3：第三人称」提示条会在开场亮 1.8 秒，宣传素材里是穿帮。
	# ⚠ 只能隐藏、**绝不能 queue_free**：main.gd 的 _on_race_go() 第一行就是
	#   get_node("ChaseCamera/ViewToastLayer").visible = true，节点不在就抛
	#   "null instance" 并中断整个发车回调 —— 玩家解锁和 AI 发车都不会执行。
	var toast := _main.get_node_or_null("ChaseCamera/ViewToastLayer")
	if toast != null:
		(toast as CanvasLayer).visible = false


func _physics_process(delta: float) -> void:
	_resolve()
	if _car == null or _track == null:
		return
	var phase := GameState.phase_name()
	var live := phase == "RACING" or phase == "FINISHED"
	if _debug:
		_dbg_diag(phase)
	if _drive and live and _autopilot != null:
		_autopilot.call("drive_track", _track, DEFAULT_AHEAD)
	if _mode == "game":
		return
	# 巡览与装配阶段保持游戏自己的相机（那段是 TrackOverviewCamera 的环绕）
	if phase == "INTRO" or phase == "LOADING" or phase == "MENU":
		_primed = false
		return
	_t += delta
	match _mode:
		"trackside":
			_pose_trackside()
		"low":
			_pose_low(delta)
		"fpv":
			_pose_fpv()
		_:
			_pose_aerial(delta)
	_cam.make_current()
	if _nohud and _hud != null:
		_hud.visible = false


func _pose_aerial(_delta: float) -> void:
	var center := _car.global_position
	var ang := _t * _orbit
	var target := center + Vector3(cos(ang) * _radius, _height, sin(ang) * _radius)
	if not _primed:
		_pos = target
		_primed = true
	var k := 6.0
	_pos = _pos.lerp(target, 1.0 - exp(-k * 0.0167))
	_cam.global_position = _pos
	_cam.look_at(center + Vector3(0.0, 0.8, 0.0), Vector3.UP)


func _pose_low(delta: float) -> void:
	var b := _car.global_transform.basis
	var pos_target := _car.global_position + b * Vector3(-2.1, 1.05, 5.6)
	var look_target := _car.global_position + b * Vector3(0.0, 0.55, -4.0)
	if not _primed:
		_pos = pos_target
		_look = look_target
		_primed = true
	_pos = _pos.lerp(pos_target, 1.0 - exp(-9.0 * delta))
	_look = _look.lerp(look_target, 1.0 - exp(-12.0 * delta))
	_cam.global_position = _pos
	if _pos.distance_to(_look) > 0.05:
		_cam.look_at(_look, Vector3.UP)


func _pose_fpv() -> void:
	var b := _car.global_transform.basis
	_cam.global_position = _car.global_position + b * Vector3(0.0, 0.78, -1.95)
	_cam.global_transform.basis = b
	_primed = true


func _tangent(arc: float) -> Vector3:
	var p0: Vector3 = _track.call("centerline_point", arc - 3.0)
	var p1: Vector3 = _track.call("centerline_point", arc + 3.0)
	var t := p1 - p0
	t.y = 0.0
	if t.length() < 0.0001:
		return Vector3.FORWARD
	return t.normalized()


## 曲率近似：一段 16m 弧上切线的夹角（越大越弯）
func _curvature(arc: float) -> float:
	var a := _tangent(arc)
	var b := _tangent(arc + 16.0)
	return rad_to_deg(a.angle_to(b))


func _ensure_sideline() -> void:
	if _sideline_ok:
		return
	var near: Dictionary = _track.call("nearest_on_centerline", _car.global_position, -1.0)
	if near.is_empty():
		return
	var base := float(near.get("arc", 0.0))
	var best_arc := base + 80.0
	var best_k := -1.0
	var off := 20.0
	while off <= 150.0:
		var k := _curvature(base + off)
		if k > best_k:
			best_k = k
			best_arc = base + off
		off += 4.0
	var p: Vector3 = _track.call("centerline_point", best_arc)
	var f := _tangent(best_arc)
	var f2 := _tangent(best_arc + 12.0)
	var turn := (f.cross(f2)).y
	var left := Vector3(f.z, 0.0, -f.x)
	var outside := -left if turn > 0.0 else left
	var half := 9.0
	if _track.has_method("road_half_width"):
		half = float(_track.call("road_half_width"))
	_sideline_arc = best_arc
	_sideline_pos = p + outside * (half + 9.0) + Vector3(0.0, 3.4, 0.0)
	_sideline_ok = true
	print("[宣传取景] 路边机位 arc=%.1f 曲率=%.1f° 位置=%s" % [_sideline_arc, best_k, _sideline_pos])


func _pose_trackside() -> void:
	_ensure_sideline()
	if not _sideline_ok:
		return
	_cam.global_position = _sideline_pos
	_cam.look_at(_car.global_position + Vector3(0.0, 0.7, 0.0), Vector3.UP)
	_primed = true


## 诊断：量「倒计时期间车到底动没动」。用户反馈 AI 车在倒计时里像提前起步，
## 这里直接记玩家与 AI0 在 COUNTDOWN 相位内相对第一帧的最大位移，GO 时打印。
func _dbg_diag(phase: String) -> void:
	_dbg_n += 1
	if _dbg_n % 40 == 0:
		print("[诊断] tick=%d phase=%s" % [_dbg_n, phase])
	if phase == "COUNTDOWN":
		var ai0 := _main.get_node_or_null("Opponents/AiCar0") as VehicleBody3D
		if not _cd_started:
			_cd_started = true
			_cd_pl0 = _car.global_position
			if ai0 != null:
				_cd_ai0 = ai0.global_position
		_cd_pl_max = maxf(_cd_pl_max, _car.global_position.distance_to(_cd_pl0))
		if ai0 != null:
			_cd_ai_max = maxf(_cd_ai_max, ai0.global_position.distance_to(_cd_ai0))
	elif phase == "RACING" and _cd_started and not _cd_reported:
		_cd_reported = true
		print("[诊断] 倒计时期间最大位移：玩家 %.3f m / AI0 %.3f m"
			% [_cd_pl_max, _cd_ai_max])
