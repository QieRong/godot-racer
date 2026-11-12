extends RefCounted
## 首页操作帮助和比赛内提示使用同一套分屏键位卡。

const Ui := preload("res://scripts/ui_theme.gd")
const ACTIONS := ["油门 / 刹车与倒车", "左右转向", "手刹", "漂移（按住）", "后视", "切换视角", "车辆复位"]


static func build(parent: Control, player: int, rect: Rect2, editable := false) -> Button:
	var accent := Ui.RED if player == 0 else Ui.SKY
	var card := Ui.panel(parent, "Player%dControls" % (player + 1), rect, accent)
	var compact := rect.size.x < 500
	var heading := Ui.label(card, "Heading", parent.tr("P%d · %s画面") % [
		player + 1, parent.tr("左侧") if player == 0 else parent.tr("右侧")], 20 if compact else 27, accent)
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	Ui.place(heading, Rect2(12, 8 if compact else 20, rect.size.x - 24, 32 if compact else 44))
	var drift_key := GameState.drift_key_name(GameState.drift_keys[player])
	var keys := ["W / S", "A / D", "空格", drift_key, "C（按住）", "V", "R"] if player == 0 else [
		"↑ / ↓", "← / →", "右 Ctrl", drift_key, "右 Shift（按住）", "Enter", "Backspace"]
	var drift_button: Button
	for i in range(ACTIONS.size()):
		var y := (42 + i * 30) if compact else (76 + i * 42)
		var label := Ui.label(card, "Action%d" % i, ACTIONS[i], 16 if compact else 20, Ui.MUTED)
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		Ui.place(label, Rect2(12, y, 206 if compact else 285, 28 if compact else 32))
		var key_rect := Rect2(218, y, 178, 30) if compact else Rect2(310, y, 256, 32)
		if editable and i == 3:
			drift_button = Ui.button(card, "DriftBinding%d" % (player + 1), keys[i], key_rect, accent)
			drift_button.add_theme_font_size_override("font_size", 14)
			for style_name in ["normal", "hover", "pressed", "disabled"]:
				var style: StyleBox = drift_button.get_theme_stylebox(style_name).duplicate()
				style.content_margin_top = 3
				style.content_margin_bottom = 3
				drift_button.add_theme_stylebox_override(style_name, style)
			Ui.place(drift_button, key_rect)
		else:
			var key := Ui.label(card, "Key%d" % i, keys[i], 15 if compact else 21)
			key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			Ui.place(key, key_rect)
	return drift_button
