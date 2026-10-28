extends SceneTree
var passed := 0
func _initialize() -> void:
	print("CURSOR_UIDS ", ResourceUID.id_to_text(ResourceUID.create_id()), " ", ResourceUID.id_to_text(ResourceUID.create_id()))
	call_deferred("_run")
func _run() -> void:
	var theme := root.get_node_or_null("CursorTheme")
	if theme == null:
		print("CURSOR_COMPLETE PASS=0 FAIL=1 missing runtime cursor theme")
		quit(1)
		return
	for shape in theme.CURSORS:
		var entry: Array = theme.CURSORS[shape]
		var texture: Texture2D = theme.textures[shape]
		var hotspot: Vector2 = entry[1]
		if texture.get_size() != Vector2(64,64) or not Rect2(Vector2.ZERO,texture.get_size()).has_point(hotspot):
			print("CURSOR_COMPLETE PASS=%d FAIL=1 bad texture or hotspot" % passed)
			quit(1)
			return
		Input.set_default_cursor_shape(shape)
		await process_frame
		passed += 1
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	print("CURSOR_COMPLETE PASS=%d FAIL=0" % passed)
	quit(0)
