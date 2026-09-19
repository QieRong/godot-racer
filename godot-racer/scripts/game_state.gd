extends Node
## 全局状态（autoload）：负责在"主菜单 ↔ 关卡"之间传递玩家选择。
##
## 为什么需要 autoload：菜单用 change_scene_to_file 切场景，旧场景会被销毁，
## 选择必须存在场景之外的地方。这里只存**极少量**状态：
##   - chosen_level: 要加载哪个关卡（索引）
##   - max_speed_kmh: 玩家在调校滑条上设的极速（跨关卡保留）

## 可选的极速范围（km/h）。滑条用这个范围。
const MIN_SPEED := 80.0
const MAX_SPEED := 240.0
const DEFAULT_SPEED := 180.0

## 当前选中的关卡索引（对应 data/levels 下的顺序）
var chosen_level := 0
## 玩家调校的极速（km/h）
var max_speed_kmh := DEFAULT_SPEED
## 玩家是否显式调过极速（没调过就用关卡的 suggested_speed_kmh）
var speed_user_set := false

## 关卡配置缓存（读盘一次，菜单和游戏都用它）
var _levels: Array[LevelConfig] = []


func _ready() -> void:
	_load_levels()
	print("[GameState] 已加载 %d 个关卡配置" % _levels.size())


## 从 res://data/levels 读全部 .tres，按文件名排序保证顺序稳定
func _load_levels() -> void:
	_levels.clear()
	var dir := DirAccess.open("res://data/levels")
	if dir == null:
		push_warning("[GameState] 找不到 res://data/levels 目录")
		return
	var files: Array[String] = []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.ends_with(".tres"):
			files.append(f)
		f = dir.get_next()
	dir.list_dir_end()
	files.sort()
	for name in files:
		var cfg := load("res://data/levels/%s" % name) as LevelConfig
		if cfg != null:
			_levels.append(cfg)
		else:
			push_warning("[GameState] %s 不是 LevelConfig，已跳过" % name)


func level_count() -> int:
	return _levels.size()


func get_level(idx: int) -> LevelConfig:
	if _levels.is_empty():
		return null
	return _levels[clampi(idx, 0, _levels.size() - 1)]


func current_level() -> LevelConfig:
	return get_level(chosen_level)


## 本局实际使用的极速：玩家调过就用玩家的，否则用关卡建议值
func effective_speed() -> float:
	var cfg := current_level()
	if cfg == null:
		return max_speed_kmh
	if speed_user_set:
		return max_speed_kmh
	return cfg.suggested_speed_kmh
