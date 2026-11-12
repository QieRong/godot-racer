extends Node
## 菜单使用用户光标；驾驶时隐藏，不截获右键环视输入。
const CURSORS := {
	Input.CURSOR_ARROW: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_default.png", Vector2(12, 5)],
	Input.CURSOR_POINTING_HAND: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_hover.png", Vector2(6, 5)],
	Input.CURSOR_MOVE: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_rotate.png", Vector2(32, 32)],
	Input.CURSOR_DRAG: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_grabbing.png", Vector2(32, 32)],
	Input.CURSOR_FORBIDDEN: ["res://assets/ui/cursors/Godot_Racer_Cursor_Pack_2026-10-23/godot_ready_64px/cursor_disabled.png", Vector2(6, 5)],
}

var textures := {}
@export_range(0.5, 1.0, 0.05) var cursor_scale := 0.75

func _ready() -> void:
	# 倒计时、暂停及退出确认会暂停场景树，光标仍须响应界面状态。
	process_mode = Node.PROCESS_MODE_ALWAYS
	for shape in CURSORS:
		var entry: Array = CURSORS[shape]
		var texture := load(entry[0]) as Texture2D
		var pixels := texture.get_image()
		pixels.resize(roundi(texture.get_width() * cursor_scale), roundi(texture.get_height() * cursor_scale), Image.INTERPOLATE_LANCZOS)
		var scaled := ImageTexture.create_from_image(pixels)
		textures[shape] = scaled
		Input.set_custom_mouse_cursor(scaled, shape, (Vector2(entry[1]) * cursor_scale).round())
	_sync_visibility()

func _process(_delta: float) -> void:
	_sync_visibility()

func _sync_visibility() -> void:
	var phase: String = GameState.phase_name()
	# HIDDEN只隐藏箭头；不捕获或锁定鼠标，保留现有右键环视输入。
	var mode := Input.MOUSE_MODE_HIDDEN if phase in ["LOADING", "INTRO", "COUNTDOWN", "RACING"] else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != mode:
		Input.mouse_mode = mode

func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	for shape in CURSORS:
		Input.set_custom_mouse_cursor(null, shape)
	textures.clear()
