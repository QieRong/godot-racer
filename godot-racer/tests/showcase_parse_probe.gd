extends SceneTree
## autoload就绪后仅加载全部自有GDScript；不实例化、不运行驾驶/AI测试。

var _paths: PackedStringArray = []


func _initialize() -> void:
	print("PARSE_GENERATED_UID=", ResourceUID.id_to_text(ResourceUID.create_id()))
	call_deferred("_run")


func _scan(directory: String) -> void:
	for file in DirAccess.get_files_at(directory):
		if file.ends_with(".gd") and file != "_parse_all.gd": _paths.append(directory.path_join(file))
	for child in DirAccess.get_directories_at(directory):
		if child not in [".godot", "addons", ".git"]: _scan(directory.path_join(child))


func _run() -> void:
	_scan("res://")
	_paths.sort()
	var failed := 0
	for path in _paths:
		# 每个进程首次加载已真实解析；复用缓存，避免替换正在执行的本探针脚本。
		var script := ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_REUSE) as GDScript
		var valid := script != null and script.can_instantiate()
		if not valid: failed += 1
		print("FINAL_PARSE %s %s" % ["PASS" if valid else "FAIL", path])
	print("FINAL_PARSE_COMPLETE PASS=%d FAIL=%d" % [_paths.size() - failed, failed])
	quit(0 if failed == 0 and not _paths.is_empty() else 1)
