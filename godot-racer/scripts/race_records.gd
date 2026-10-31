extends RefCounted
## 本地个人纪录；普通两圈总时间与无限单圈分开，整数毫秒落盘。
const DEFAULT_PATH := "user://race_records.json"
const VERSION := 1
const MAX_EXACT_MS := 9007199254740991.0
var path := DEFAULT_PATH
var last_error := ""
var _times: Dictionary = {}
var _writable := true

func load_from(file_path: String = DEFAULT_PATH) -> bool:
	path = file_path
	_times.clear()
	last_error = ""
	_writable = true
	if not FileAccess.file_exists(path): return true
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return _load_error("无法读取最佳纪录：%s" % error_string(FileAccess.get_open_error()))
	var parser := JSON.new()
	var status := parser.parse(file.get_as_text())
	file.close()
	if status != OK: return _load_error("最佳纪录文件损坏，原文件已保留")
	var document: Variant = parser.data
	if not document is Dictionary or document.get("version") != VERSION or not document.get("levels") is Dictionary:
		return _load_error("最佳纪录文件格式或版本不受支持，原文件已保留")
	for level in document.levels:
		var entry: Variant = document.levels[level]
		if not entry is Dictionary: return _load_error("最佳纪录条目损坏，原文件已保留")
		var normalized := {}
		for key in ["race_ms", "endless_lap_ms"]:
			var value: Variant = entry.get(key, 0)
			if not (value is int or value is float): return _load_error("最佳纪录时间类型错误")
			var number := float(value)
			if not is_finite(number) or number < 0.0 or number > MAX_EXACT_MS or number != floor(number):
				return _load_error("最佳纪录时间无效")
			if number > 0.0: normalized[key] = int(number)
		_times[level] = normalized
	return true

func _load_error(message: String) -> bool:
	_times.clear()
	_writable = false
	return _error(message)

func _error(message: String) -> bool:
	last_error = message
	push_warning(message)
	return false

func best_time(level: String, endless: bool) -> float:
	return float(_times.get(level, {}).get("endless_lap_ms" if endless else "race_ms", 0)) / 1000.0

func update_record(level: String, endless: bool, seconds: float) -> bool:
	if not _writable or not is_finite(seconds) or seconds <= 0.0 or seconds * 1000.0 > MAX_EXACT_MS:
		return false
	var milliseconds := roundi(seconds * 1000.0)
	if milliseconds <= 0: return false
	var key := "endless_lap_ms" if endless else "race_ms"
	var old: Dictionary = _times.get(level, {}).duplicate()
	if int(old.get(key, 0)) > 0 and milliseconds >= int(old[key]): return false
	var entry := old.duplicate()
	entry[key] = milliseconds
	_times[level] = entry
	if not _save():
		_times[level] = old
		return false
	return true

func _save() -> bool:
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return _error("最佳纪录保存失败：%s" % error_string(FileAccess.get_open_error()))
	file.store_string(JSON.stringify({"version": VERSION, "levels": _times}, "\t"))
	file.flush()
	var status := file.get_error()
	file.close()
	if status != OK: return _error("最佳纪录写入失败：%s" % error_string(status))
	if FileAccess.file_exists(path):
		status = DirAccess.copy_absolute(path, path + ".bak")
		if status != OK: return _error("最佳纪录备份失败：%s" % error_string(status))
	status = DirAccess.rename_absolute(temporary, path)
	if status != OK: return _error("最佳纪录替换失败：%s" % error_string(status))
	last_error = ""
	return true

static func time_text(seconds: float) -> String:
	if seconds <= 0.0: return "暂无纪录"
	var total_ms := roundi(seconds * 1000.0)
	return "%02d:%02d.%03d" % [total_ms / 60000, (total_ms / 1000) % 60, total_ms % 1000]
