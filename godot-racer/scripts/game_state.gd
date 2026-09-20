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
## 玩家是否要 AI 对手（主菜单开关，跨关卡保留）。
## 关掉时所有关卡都不生成对手 —— 关卡配置里的 ai_opponents 只作为"上限"，
## 最终数量由 effective_ai_count() 决定，避免在 main.gd 里到处写 if。
var ai_enabled := true

## 关卡配置缓存（读盘一次，菜单和游戏都用它）
var _levels: Array[LevelConfig] = []


func _ready() -> void:
	# 命令行也能切 AI 对手开关（和主菜单那个按钮同一条路径，便于自动化验证）。
	#   --aioff  关掉对手   --aion  打开对手
	# 注意与 main.gd 的 --noai 区分：--noai 是"物理 A/B 用，不生成对手"，
	# --aioff 是"模拟玩家在菜单里关掉"，走的是 GameState 这条真实链路。
	var args := OS.get_cmdline_user_args()
	if "--aioff" in args:
		ai_enabled = false
	elif "--aion" in args:
		ai_enabled = true
	_load_levels()
	print("[GameState] 已加载 %d 个关卡配置（AI 对手：%s）"
		% [_levels.size(), "开" if ai_enabled else "关"])


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


## 本局实际要生成几台 AI 对手。
## 唯一出口：关卡配置给"最多几台"，玩家开关决定"要不要"。
## 这样 main.gd / 菜单都只问这里，不会各写一份判断而漂移。
func effective_ai_count() -> int:
	if not ai_enabled:
		return 0
	var cfg := current_level()
	if cfg == null:
		return 0
	return maxi(0, cfg.ai_opponents)


## 该关卡"本来"有几台对手（用于菜单提示：被玩家关掉了要说清楚）
func level_ai_count(idx: int = -1) -> int:
	var cfg := get_level(chosen_level if idx < 0 else idx)
	if cfg == null:
		return 0
	return maxi(0, cfg.ai_opponents)
