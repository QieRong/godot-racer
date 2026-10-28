extends Node
## 菜单使用用户光标；装配、倒计时与驾驶隐藏，暂停及结算恢复。不截获输入。
const CURSORS := {
	Input.CURSOR_ARROW: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_default.png", Vector2(12, 5)],
	Input.CURSOR_POINTING_HAND: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_hover.png", Vector2(6, 5)],
	Input.CURSOR_MOVE: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_rotate.png", Vector2(32, 32)],
	Input.CURSOR_DRAG: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_grabbing.png", Vector2(32, 32)],
	Input.CURSOR_FORBIDDEN: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_disabled.png", Vector2(6, 5)],
}

var textures := {}
var _last_phase := ""

func _ready() -> void:
	# 倒计时、暂停及退出确认会暂停场景树，光标仍须响应界面状态。
	process_mode = Node.PROCESS_MODE_ALWAYS
	for shape in CURSORS:
		var entry: Array = CURSORS[shape]
		var texture := load(entry[0]) as Texture2D
		textures[shape] = texture
		Input.set_custom_mouse_cursor(texture, shape, entry[1])
	_sync_visibility()

func _process(_delta: float) -> void:
	_sync_visibility()

func _sync_visibility() -> void:
	var phase: String = GameState.phase_name()
	if phase == _last_phase:
		return
	_last_phase = phase
	# HIDDEN只隐藏箭头；不捕获或锁定鼠标，保留现有右键环视输入。
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if phase in ["LOADING", "COUNTDOWN", "RACING"] else Input.MOUSE_MODE_VISIBLE

func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for shape in CURSORS:
		Input.set_custom_mouse_cursor(null, shape)
	textures.clear()
