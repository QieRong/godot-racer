extends Camera3D
## 跟随摄像机：第三人称 / 第二人称 / 第一人称，按 V 循环切换。
##
## 挂在场景根下的 Camera3D 上（不要挂在车身下面，否则车翻镜头也跟着翻），
## 在检查器里把 target 指向你的 VehicleBody3D。
##
## 车头在车体本地 **-Z**（见 README「已知的坑」第 7 条），
## 所以"车尾后方"是 **+Z** 侧。

enum ViewMode { FIRST_PERSON, SECOND, THIRD }

@export var target: Node3D

@export_group("视角预设（按 V 切换）")
## 第一人称：贴在车头前方一点。车头在本地 -Z，前翼到 z≈-1.66，
## 所以这里取 -1.95 —— 放在 -1.0 这种"车里"的位置会看到车身内壁的面片。
@export var offset_first := Vector3(0.0, 0.78, -1.95)
## 第二人称：贴着车尾的近距跟随（车尾在 +1.7 附近）
@export var offset_second := Vector3(0.0, 1.55, 2.8)
## 第三人称：远距跟随
@export var offset_third := Vector3(0.0, 2.3, 5.2)

@export_group("跟随手感")
## 位置跟随速度：越小越"拖"，越大越跟脚（第一人称不用它，直接刚性跟随）
@export var position_smooth := 6.0
## 注视点平滑速度
@export var look_smooth := 10.0
## 高速时镜头略微拉远，增强速度感（第一人称不生效）
@export var speed_pullback := 1.4

@export_group("鼠标环视")
@export var orbit_enabled := true
@export var orbit_sensitivity := 0.006
@export var pitch_min := -0.5
@export var pitch_max := 0.9
## 松开右键后镜头回正的速度（弧度/秒）。没有这个的话，环视后镜头会一直
## 停在车侧面，开起来很别扭。
@export var recenter_speed := 1.2

@export_group("提示条")
## 切换视角时在左上角显示 1.8 秒提示
@export var toast_enabled := true
@export var toast_seconds := 1.8

var _mode: int = ViewMode.THIRD
var _yaw := 0.0
var _pitch := 0.0
var _current := Vector3.ZERO
var _look := Vector3.ZERO
var _toast: Label = null
var _toast_left := 0.0


func _ready() -> void:
	# 诊断日志：相机"看不到车"这类问题几乎都是 target 没解析到，所以直接打出来
	print("[相机] _ready 执行，target=%s" % str(target))
	if target == null:
		printerr("[相机] target 未设置！在检查器里把 target 指向 VehicleBody3D 节点。相机将停在原地。")
		set_process(false)
		return
	print("[相机] target 解析成功：%s  位置=%s" % [target.name, target.global_position])
	_build_toast()
	_snap_to_target()
	_show_toast()


## 每个视角的完整参数。rigid=true 表示刚性贴在车上（第一人称）。
func _preset() -> Dictionary:
	match _mode:
		ViewMode.FIRST_PERSON:
			return {
				"label": "第一人称（车头）",
				"offset": offset_first,
				"look": offset_first + Vector3(0.0, -0.1, -14.0),
				"smooth": 0.0,
				"pull": 0.0,
				"rigid": true,
			}
		ViewMode.SECOND:
			return {
				"label": "第二人称（近距）",
				"offset": offset_second,
				"look": Vector3(0.0, 0.9, -2.0),
				"smooth": position_smooth * 2.0,
				"pull": speed_pullback * 0.4,
				"rigid": false,
			}
		_:
			return {
				"label": "第三人称（远距）",
				"offset": offset_third,
				"look": Vector3(0.0, 0.8, 0.0),
				"smooth": position_smooth,
				"pull": speed_pullback,
				"rigid": false,
			}


## 立刻贴到目标位：开场和切视角时用，避免镜头从上一处飞过去
func _snap_to_target() -> void:
	if target == null:
		return
	var p := _preset()
	var off: Vector3 = p["offset"]
	var look_off: Vector3 = p["look"]
	_current = target.global_position + target.global_transform.basis * off
	global_position = _current
	_look = target.global_position + target.global_transform.basis * look_off
	if bool(p["rigid"]):
		global_transform.basis = target.global_transform.basis
	print("[相机] 视角=%s  初始位置=%s" % [p["label"], global_position])


func _unhandled_input(event: InputEvent) -> void:
	if target == null:
		return
	if event.is_action_pressed("camera_view"):
		_mode = (_mode + 1) % 3
		_yaw = 0.0
		_pitch = 0.0
		_snap_to_target()
		_show_toast()
		return
	if not orbit_enabled:
		return
	# 按住右键拖动可环视；左键留给 UI
	if event is InputEventMouseMotion and Input.is_action_pressed("camera_orbit"):
		_yaw -= event.relative.x * orbit_sensitivity
		_pitch = clampf(_pitch - event.relative.y * orbit_sensitivity, pitch_min, pitch_max)


func _process(delta: float) -> void:
	if target == null:
		return
	var p := _preset()

	# 松开右键后，yaw/pitch 平滑回正到"车尾正后方"
	if orbit_enabled and not Input.is_action_pressed("camera_orbit"):
		_yaw = move_toward(_yaw, 0.0, recenter_speed * delta)
		_pitch = move_toward(_pitch, 0.0, recenter_speed * delta)

	var basis_target := target.global_transform.basis
	var orbit := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	var off: Vector3 = p["offset"]

	if bool(p["rigid"]):
		# 第一人称：刚性贴在车上，朝向直接跟车身（叠加鼠标环视），不做平滑。
		# 平滑会让第一人称产生拖影，很容易晕。
		_current = target.global_position + basis_target * off
		global_position = _current
		global_transform.basis = basis_target * orbit
		_look = _current
	else:
		# 高速时镜头略微拉远，增强速度感
		var speed := 0.0
		if target is VehicleBody3D:
			speed = target.linear_velocity.length()
		var extra := Vector3(0.0, 0.0, speed / 40.0 * float(p["pull"]))
		var desired: Vector3 = target.global_position + (basis_target * orbit) * (off + extra)

		# 用 1-exp(-k*dt) 做帧率无关的指数平滑
		_current = _current.lerp(desired, 1.0 - exp(-float(p["smooth"]) * delta))
		global_position = _current

		# 注视点同样平滑，否则镜头会跟着车身抖动一起抖
		var look_off: Vector3 = p["look"]
		var look_target: Vector3 = target.global_position + basis_target * look_off
		_look = _look.lerp(look_target, 1.0 - exp(-look_smooth * delta))
		look_at(_look, Vector3.UP)

	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0 and _toast != null:
			_toast.visible = false


## 运行时建一个提示条，不动 HUD 场景。
## 字体显式指定系统字体：Godot 默认主题字体不含中文字形，直接用会显示成方框。
func _build_toast() -> void:
	if not toast_enabled:
		return
	var layer := CanvasLayer.new()
	layer.name = "ViewToastLayer"
	layer.layer = 128
	add_child(layer)

	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "sans-serif"])

	_toast = Label.new()
	_toast.name = "ViewToast"
	_toast.add_theme_font_override("font", font)
	_toast.add_theme_font_size_override("font_size", 26)
	_toast.add_theme_color_override("font_color", Color(1, 1, 1))
	_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.position = Vector2(30.0, 214.0)      # 排在 HUD 四行文字下面
	_toast.visible = false
	layer.add_child(_toast)


func _show_toast() -> void:
	if _toast == null:
		return
	var p := _preset()
	_toast.text = "视角 %d/3：%s" % [_mode + 1, p["label"]]
	_toast.visible = true
	_toast_left = toast_seconds
