extends RefCounted
## 普通两圈完成经历独立保存；不读取或改写最佳纪录、幽灵。
const DEFAULT_PATH := "user://race_completion.json"
const VERSION := 1
var path := DEFAULT_PATH
var last_error := ""
var load_error := ""
var _level_ids: PackedStringArray = []
var _completed: Dictionary = {}

func load_from(level_ids: PackedStringArray, file_path: String = DEFAULT_PATH) -> bool:
	path = file_path
	_level_ids = level_ids
	_completed.clear()
	last_error = ""
	load_error = ""
	if not FileAccess.file_exists(path): return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return _load_error("无法读取完成记录，原文件已保留")
	var parser := JSON.new()
	var status := parser.parse(file.get_as_text())
	file.close()
	if status != OK: return _load_error("完成记录文件损坏，原文件已保留")
	var document: Variant = parser.data
	if not document is Dictionary or document.get("version") != VERSION or not document.get("completed") is Array:
		return _load_error("完成记录格式或版本不受支持，原文件已保留")
	for level in document.completed:
		if not level is String or not _level_ids.has(level):
			return _load_error("完成记录关卡无效，原文件已保留")
		_completed[level] = true
	return true

func _load_error(message: String) -> bool:
	_completed.clear()
	load_error = message
	return _error(message)

func _error(message: String) -> bool:
	last_error = message
	push_warning(message)
	return false

func is_completed(level: String) -> bool:
	return _completed.has(level)

func completed_count() -> int:
	return _completed.size()

func mark_completed(level: String) -> bool:
	if not load_error.is_empty(): return false
	if not _level_ids.has(level): return _error("完成记录关卡无效")
	if is_completed(level): return true
	_completed[level] = true
	if not _save():
		_completed.erase(level)
		return false
	return true

func _save() -> bool:
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return _error(tr("完成记录保存失败（错误码 %d）") % FileAccess.get_open_error())
	file.store_string(JSON.stringify({"version": VERSION, "completed": _completed.keys()}, "\t"))
	file.flush()
	var status := file.get_error()
	file.close()
	if status != OK: return _error(tr("完成记录写入失败（错误码 %d）") % status)
	if FileAccess.file_exists(path):
		status = DirAccess.copy_absolute(path, path + ".bak")
		if status != OK: return _error(tr("完成记录备份失败（错误码 %d）") % status)
	status = DirAccess.rename_absolute(temporary, path)
	if status != OK: return _error(tr("完成记录替换失败（错误码 %d）") % status)
	last_error = ""
	return true
