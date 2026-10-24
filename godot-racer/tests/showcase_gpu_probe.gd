extends SceneTree
## 隔离图形初始化：不加载菜单、展台或车型，不用来证明产品验收。


func _initialize() -> void:
	print("SHOWCASE_GPU_PROBE script_ready")
	call_deferred("_run")


func _run() -> void:
	for i in range(3):
		await RenderingServer.frame_post_draw
		await process_frame
	print("SHOWCASE_GPU_PROBE_COMPLETE frames=%d" % Engine.get_frames_drawn())
	quit(0 if Engine.get_frames_drawn() > 0 else 1)
