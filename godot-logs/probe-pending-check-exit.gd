extends SceneTree
## 无车辆/渲染截图的生命周期探针：仅比较截断与自然完成 RefCounted 协程。

class PendingCheck extends RefCounted:

	func run(tree: SceneTree) -> void:
		var laps: Array[String] = []
		for _frame in range(12):
			await tree.physics_frame
		laps.append("completed")
		print("PROBE_CHECK_COMPLETED=", laps.size())

var check := PendingCheck.new()

func _initialize() -> void:
	call_deferred("_run")

func _wrapper() -> void:
	await check.run(self)

func _run() -> void:
	if OS.get_cmdline_user_args().has("--complete"):
		await _wrapper()
	else:
		_wrapper()
		await process_frame
	print("PROBE_QUIT")
	quit()
