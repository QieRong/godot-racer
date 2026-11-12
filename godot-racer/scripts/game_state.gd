extends Node
## 全局状态（autoload）：负责在"主菜单 ↔ 关卡"之间传递玩家选择，
## 并持有**渲染与窗口设置**（Windows 首版 REL-STEP2A 加进来的）。
##
## 为什么需要 autoload：菜单用 change_scene_to_file 切场景，旧场景会被销毁，
## 选择必须存在场景之外的地方。这里只存**极少量**状态：
##   - chosen_level: 要加载哪个关卡（索引）
##   - max_speed_kmh: 玩家在调校滑条上设的极速（跨关卡保留）
##   - render_fps / window_size: 渲染帧率与窗口尺寸（持久化到 user://settings.cfg）
##
## ⚠ 帧率口径（别被两个 120 搞混）：
##   render_fps 是**渲染**上限（60 / 120），只影响画面顺滑度；
##   物理固定 120 Hz（project.godot 的 physics_ticks_per_second），与它**解耦**，
##   两者分别配置；切档后的实际手感与圈速仍以 60/120 双档回归为准。

const DisplaySettings := preload("res://scripts/display_settings.gd")
const RaceVariants := preload("res://scripts/race_variants.gd")
const RaceRecords := preload("res://scripts/race_records.gd")
const RaceCompletion := preload("res://scripts/race_completion.gd")
var records := RaceRecords.new()
var completion := RaceCompletion.new()
var endless_mode := false
var split_screen := false:
	set(value):
		split_screen = value and supports_local_split_screen()
var record_results_enabled := true
var _online_restore: Dictionary = {}
var race_variants_enabled: bool = true
var _race_variant_config: Resource = null
var _race_variant_level: int = -1
var _race_variant_info: Dictionary = {}
var _requested_race_seed: int = -1
var _requested_combination: int = -1
const EXIT_CONFIRM_UI := preload("res://scripts/exit_confirm.gd")

## 比赛相位机（2026-10-18 Phase 01 扩展，竞速系统策划案 R1）：
##   MENU       主菜单
##   LOADING    关卡装配中（互动路径：树不暂停、玩家输入被 start_locked 锁住）
##   COUNTDOWN  3 秒倒计时中（树暂停、玩家与 AI 都动不了 —— 同步发车的物理前提）
##   RACING     比赛中（"出发！"之后）
##   PAUSED / FINISHED / EXIT_CONFIRM  既有相位
## ⚠ LOADING 期间**不能**暂停树：装配要 await physics_frame 测物理基线，
##   暂停会让那些 await 永不返回（装配死锁）。
enum Phase { MENU, LOADING, COUNTDOWN, RACING, PAUSED, FINISHED, EXIT_CONFIRM, INTRO }
const DRIVE_ACTIONS := ["accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake", "drift"]
const DRIFT_DEFAULT_KEYS := [Vector2i(KEY_SHIFT, KEY_LOCATION_LEFT), Vector2i(KEY_SLASH, KEY_LOCATION_UNSPECIFIED)]
const P2_KEYBOARD := {
	"accelerate": Vector2i(KEY_UP, 0), "brake_reverse": Vector2i(KEY_DOWN, 0),
	"steer_left": Vector2i(KEY_LEFT, 0), "steer_right": Vector2i(KEY_RIGHT, 0),
	"handbrake": Vector2i(KEY_CTRL, KEY_LOCATION_RIGHT), "reset": Vector2i(KEY_BACKSPACE, 0),
	"camera_view": Vector2i(KEY_ENTER, 0), "camera_rear": Vector2i(KEY_SHIFT, KEY_LOCATION_RIGHT),
}
signal drive_input_released
var drift_keys: Array = DRIFT_DEFAULT_KEYS.duplicate()
const MENU_SCENE := "res://scenes/menu.tscn"

var phase: Phase = Phase.MENU
var _phase_before_exit: Phase = Phase.MENU
var finish_snapshot: Dictionary = {}
var _exit_overlay: CanvasLayer = null
var _exit_in_progress := false
## "出发！"瞬间的墙钟（毫秒）；总时间和互动首圈共用该 GO 原点。
## 倒计时不计入成绩；race_clock_ms() 统一扣除 GO 之后的暂停时长。
## 0 = 本局还没出发。自动化路径在 begin_race() 置位，口径与互动路径一致。
var race_start_ms := 0

## 录制专用时钟开关（`--movie-clock`）。
## 为什么需要：`--write-movie --fixed-fps 30` 是逐帧渲染，本机只有实时的 25%~30%，
## 而比赛时钟读的是墙钟（Time.get_ticks_msec），于是录像里 HUD 的「总时间」会比
## 成片时间快 3~4 倍 —— 两圈比赛显示成 8 分钟，宣传片里一眼就是破绽。
## 打开本开关后比赛时钟改成「按帧累积」，录像里的计时就等于成片时间；
## 只影响计时读数，不动物理、判定、发车与名次，默认关闭。
var movie_clock := false
var _movie_ms := 0
var _race_paused_ms := 0
var _race_pause_started_ms := -1
var _race_finished_ms := -1

## 可选的极速范围（km/h）。滑条用这个范围。
const MIN_SPEED := 80.0
const MAX_SPEED := 240.0
const DEFAULT_SPEED := 180.0

## 可选渲染帧率。菜单只在这两档里切；**不接受**第三个值 ——
## 每多一档就要把物理/输入时序在每种机器上重测一遍，首版不承诺。
const RENDER_FPS_OPTIONS: Array[int] = [60, 120]
const DEFAULT_RENDER_FPS := 60
## 命令行开关前缀（验收脚本用 --render-fps=120 起一次高帧率回归）
const ARG_RENDER_FPS := "--render-fps="
## 设置落盘位置：user:// 是玩家可写目录，**导出包里也写得了**（res:// 是只读的）
const LANGUAGES := {
	"automatic": "跟随系统", "zh_CN": "简体中文", "zh_TW": "繁體中文",
	"en": "English", "ru": "Русский", "ja": "日本語", "ko": "한국어",
}
const DEFAULT_LANGUAGE := "zh_CN"
signal language_changed
var language_choice := "automatic"

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "display"
const SETTINGS_KEY_FPS := "render_fps"
const SETTINGS_KEY_WINDOW := "window_size"
## 关卡目录
const LEVEL_DIR := "res://data/levels"

## 当前选中的关卡索引（对应 data/levels 下的顺序）
var chosen_level := 0
var menu_show_level_select := false
## 玩家调校的极速（km/h）
var max_speed_kmh := DEFAULT_SPEED
## 玩家是否显式调过极速（没调过就用关卡的 suggested_speed_kmh）
var speed_user_set := false
## 玩家是否要 AI 对手（主菜单开关，跨关卡保留）。
## 关掉时所有关卡都不生成对手 —— 关卡配置里的 ai_opponents 只作为"上限"，
## 最终数量由 effective_ai_count() 决定，避免在 main.gd 里到处写 if。
var ai_enabled := true
var dynamic_chase_enabled := true
var ghost_enabled := true
var photo_finish_enabled := true
var camera_shake_enabled := true
## 只调玩家转向建立/回中速率，不改变抓地力、最大舵角或AI。
var steering_sensitivity := 1.0

## 当前**生效**的渲染帧率。注意它不是"存档值"：
## --render-fps=120 启动时它是 120，而存档里仍是玩家自己选的 60。
var render_fps: int = DEFAULT_RENDER_FPS
## 存档里的窗口尺寸；(0,0) = 没存过 → 走当前工作区自动适配策略
var window_size := Vector2i(0, 0)
## 设置文件路径。**测试会临时改它**，免得把玩家自己的 settings.cfg 写脏。
var settings_path := SETTINGS_PATH

## 关卡配置缓存（读盘一次，菜单和游戏都用它）
var _levels: Array[LevelConfig] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	record_results_enabled = not OS.get_cmdline_args().has("--script")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--check=") or arg.begins_with("--shot"):
			record_results_enabled = false
	get_tree().auto_accept_quit = false
	get_tree().root.close_requested.connect(request_exit)
	# 顺序有讲究：先读存档 → 再让命令行覆盖 → 最后才落到引擎上。
	# 反过来会让"命令行覆盖"变成"命令行把存档改了"（验收一天跑几十次，
	# 那样跑完玩家自己选的 60 就悄悄变成 120 了）。
	_load_display_settings()
	records.load_from()
	apply_cli_args(OS.get_cmdline_user_args())
	Engine.max_fps = render_fps
	_apply_window()
	var resize_handler := Callable(self, "_on_window_size_changed")
	if not get_tree().root.size_changed.is_connected(resize_handler):
		get_tree().root.size_changed.connect(resize_handler)
	_load_levels()
	var level_ids := PackedStringArray()
	for cfg in _levels:
		level_ids.append(cfg.resource_path.get_file().get_basename())
	completion.load_from(level_ids)
	print("[GameState] 已加载 %d 个关卡配置（AI 对手：%s）"
		% [_levels.size(), "开" if ai_enabled else "关"])
	print("[GameState] 渲染 %d FPS（存档 %d）· 物理 %d Hz · 窗口 %dx%d"
		% [render_fps, read_saved_render_fps(), Engine.physics_ticks_per_second,
			window_size.x, window_size.y])


static func supports_local_split_screen(platform_name: String = "") -> bool:
	return (OS.get_name() if platform_name.is_empty() else platform_name) != "Android"


func phase_name() -> String:
	return Phase.keys()[phase]

func _input(event: InputEvent) -> void:
	preload("res://scripts/ui_theme.gd").update_navigation(event, get_tree().root)

func show_loading(text: String) -> void:
	var loading := get_node_or_null("RaceLoading")
	if loading == null:
		loading = preload("res://scripts/race_loading.gd").new()
		add_child(loading)
	loading.set_stage(text)

func hide_loading() -> void:
	var loading := get_node_or_null("RaceLoading")
	if loading != null:
		remove_child(loading)
		loading.queue_free()


func release_drive_input() -> void:
	for action in DRIVE_ACTIONS:
		Input.action_release(action)
	for prefix in ["p1_", "p2_"]:
		for action in DRIVE_ACTIONS + ["camera_view", "camera_rear", "reset"]:
			if InputMap.has_action(prefix + action): Input.action_release(prefix + action)
	drive_input_released.emit()


func begin_race() -> void:
	_dismiss_exit_overlay()
	finish_snapshot.clear()
	phase = Phase.RACING
	# 自动化路径（--check / --shot）不走倒计时，总时间口径从这里起算（R15）
	_reset_race_clock()
	race_start_ms = _now_ms()
	release_drive_input()
	get_tree().paused = false


## 清成绩并进入 LOADING（关卡装配期）。互动路径由 main._ready() 调用；
## 自动化路径不走这里（它们在 _ready 直接 begin_race 保持旧时序）。
## ⚠ 刻意**不**暂停树：装配期要 await physics_frame 测物理基线，
##   暂停会让 await 永不返回（装配死锁）—— 装配期的"玩家别动"由
##   vehicle.gd 的 start_locked 输入锁负责，不靠暂停。
func prepare_race() -> void:
	_dismiss_exit_overlay()
	finish_snapshot.clear()
	_reset_race_clock()
	phase = Phase.LOADING
	release_drive_input()
	get_tree().paused = false


## 航拍时主场景已冻结起跑车辆；环境与天气继续运行，GO前不起表。
func enter_intro() -> bool:
	if phase != Phase.LOADING:
		return false
	phase = Phase.INTRO
	get_tree().paused = false
	return true


## 倒计时暂停世界，UI由PROCESS_MODE_ALWAYS继续，GO再统一解冻。
func enter_countdown(pause_world := true) -> bool:
	if phase != Phase.LOADING and phase != Phase.INTRO:
		return false
	phase = Phase.COUNTDOWN
	get_tree().paused = pause_world
	return true


## COUNTDOWN → RACING："出发！"的**唯一**相位入口。倒计时 finished 信号 →
## main 的发车回调 → 本函数（三步同帧：玩家解锁 / arm_opponents / 这里）。
##
## ⚠ 为什么不能复用 begin_race()：它会 release_drive_input()，把玩家在
## 倒计时里按住的方向键吞掉（E6"出发前按住 W 应直接给油"）。
## GO 瞬间刻意不碰输入状态 —— 按着的键保持按着。
func start_race(go_ms: int = 0) -> bool:
	if phase != Phase.COUNTDOWN:
		return false
	if go_ms < 0 or go_ms > _now_ms(): return false
	phase = Phase.RACING
	_reset_race_clock()
	race_start_ms = go_ms if go_ms > 0 else _now_ms()
	get_tree().paused = false
	return true


## 本局总时间（秒）：GO 起表，暂停/退出确认停表，结算冻结。
func race_total_time() -> float:
	if race_start_ms <= 0:
		return 0.0
	return (race_clock_ms() - race_start_ms) / 1000.0


## 与墙钟同单位、同 GO 原点的比赛时钟，供总时间与车辆圈钟共同读取。
func race_clock_ms() -> int:
	var now_ms := _now_ms()
	if _race_finished_ms >= 0:
		now_ms = _race_finished_ms
	elif _race_pause_started_ms >= 0:
		now_ms = _race_pause_started_ms
	return now_ms - _race_paused_ms


## 比赛时钟的唯一时间源：正常游玩读墙钟，录制模式读帧累积。
func _now_ms() -> int:
	return _movie_ms if movie_clock else Time.get_ticks_msec()


func _process(delta: float) -> void:
	if movie_clock:
		_movie_ms += int(round(delta * 1000.0))


func _reset_race_clock() -> void:
	race_start_ms = 0
	_race_paused_ms = 0
	_race_pause_started_ms = -1
	_race_finished_ms = -1


func _pause_race_clock() -> void:
	if race_start_ms > 0 and _race_pause_started_ms < 0 and _race_finished_ms < 0:
		_race_pause_started_ms = _now_ms()


func _resume_race_clock() -> void:
	if _race_pause_started_ms >= 0:
		_race_paused_ms += _now_ms() - _race_pause_started_ms
		_race_pause_started_ms = -1


func enter_menu() -> void:
	end_online_context()
	_race_variant_config = null
	_race_variant_level = -1
	_race_variant_info.clear()
	_dismiss_exit_overlay()
	finish_snapshot.clear()
	_reset_race_clock()
	phase = Phase.MENU
	release_drive_input()
	get_tree().paused = false


func pause_race() -> bool:
	if phase != Phase.RACING:
		return false
	_pause_race_clock()
	phase = Phase.PAUSED
	release_drive_input()
	get_tree().paused = true
	return true


func resume_race() -> bool:
	if phase != Phase.PAUSED:
		return false
	_resume_race_clock()
	phase = Phase.RACING
	release_drive_input()
	get_tree().paused = false
	return true


func finish_race(laps: int, last: float, best: float, target: int, classification: Dictionary = {}) -> bool:
	if phase != Phase.RACING or target <= 0 or laps < target:
		return false
	# 完赛先冻结同一比赛时钟，再将 GO 起算的净比赛时长写入唯一快照。
	_race_finished_ms = Time.get_ticks_msec()
	var total := race_total_time()
	finish_snapshot = {"laps": laps, "last": last, "best": best, "target": target, "total": total}
	finish_snapshot.merge(classification, true)
	phase = Phase.FINISHED
	release_drive_input()
	get_tree().paused = true
	return true


func finish_classified_race(entrants: Array, target: int, local_slot := -1) -> bool:
	var local: Dictionary = {}
	if local_slot >= 0:
		local = entrants[local_slot]
	else:
		for row: Dictionary in entrants:
			if row.get("id") == "player":
				local = row
				break
	if local.is_empty(): return false
	var rank: int = int(local.rank)
	return finish_race(int(local.laps), float(local.last), float(local.best), target, {
		"total":local.total, "position":rank, "field_size":entrants.size(),
		"outcome":race_outcome(entrants, rank), "entrants":entrants,
		"lap_times":local.lap_times.duplicate()
	})


static func race_outcome(entrants: Array, rank: int) -> String:
	if entrants.size() <= 1: return "practice"
	if rank <= 0: return ""
	if rank > 1: return "lose"
	var leaders := 0
	for row: Dictionary in entrants:
		if int(row.get("rank", 0)) == 1: leaders += 1
	return "tie" if leaders > 1 else "win"


## 重开 = 完整新比赛：先清成绩进 LOADING，再重载场景。
## 新场景的 _ready() 会再次 prepare_race() 并从 LOADING 走倒计时 ——
## 不会出现"reload 后直接 RACING、跳过倒计时"（策划案 G9/R14）。
func restart_race() -> void:
	prepare_race()
	get_tree().reload_current_scene()


func back_to_menu(to_level_select := false) -> void:
	if endless_mode and phase in [Phase.RACING, Phase.PAUSED]:
		get_tree().current_scene.present_training_summary()
		return
	enter_menu()
	menu_show_level_select = to_level_select
	get_tree().change_scene_to_file(MENU_SCENE)


func request_exit() -> void:
	if _exit_in_progress:
		return
	# 自动验收与截图夹具必须能自行退出，不得被交互弹窗卡住。
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--check=") or arg.begins_with("--shot"):
			quit_after_menu_audio()
			return
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("request_online_race_exit") and scene.request_online_race_exit():
		return
	if phase == Phase.EXIT_CONFIRM:
		return
	_phase_before_exit = phase
	if phase == Phase.RACING:
		_pause_race_clock()
	phase = Phase.EXIT_CONFIRM
	release_drive_input()
	get_tree().paused = true
	_exit_overlay = EXIT_CONFIRM_UI.new()
	get_tree().root.add_child(_exit_overlay)


func cancel_exit() -> void:
	if _exit_in_progress or phase != Phase.EXIT_CONFIRM:
		return
	Sfx.play_clip("界面否定", -23.0)
	phase = _phase_before_exit
	if phase == Phase.RACING:
		_resume_race_clock()
	_dismiss_exit_overlay()
	release_drive_input()
	# COUNTDOWN 必须保持暂停：取消退出确认后倒计时要继续，但不能解冻
	# （否则倒计时期间物理恢复，玩家可以提前走）—— 策划案 G8/R3。
	get_tree().paused = phase == Phase.PAUSED or phase == Phase.FINISHED or phase == Phase.COUNTDOWN


func confirm_exit() -> void:
	if phase == Phase.EXIT_CONFIRM:
		if endless_mode and _phase_before_exit in [Phase.RACING, Phase.PAUSED]:
			phase = _phase_before_exit
			_dismiss_exit_overlay()
			get_tree().current_scene.present_training_summary()
			return
		quit_after_menu_audio()


func quit_after_menu_audio() -> void:
	# 确认后不可重复或取消；仅等待自有菜单BGM，不改变比赛时钟与其他音频。
	if _exit_in_progress:
		return
	_exit_in_progress = true
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("close_online_room"):
		await scene.close_online_room()
	var drained := true
	var music := find_child("MenuMusic", false, false)
	if music != null:
		drained = await music.call("shutdown_and_wait")
	if not drained:
		push_error("Menu OGG audio drain timed out before exit")
	print("MENU_AUDIO_EXIT released=%s" % drained)
	get_tree().quit(0 if drained else 1)


func _dismiss_exit_overlay() -> void:
	if is_instance_valid(_exit_overlay):
		_exit_overlay.queue_free()
	_exit_overlay = null


## 解析玩家 / 验收脚本传进来的命令行开关。
## 拆成可直调的方法（而不是埋在 _ready 里）是为了让测试**喂一个参数数组**就能验证，
## 不用真的重启进程 —— 重启进程的测试不可重复，也没法做负对照。
##   --aioff / --aion   关掉 / 打开对手（和主菜单那个按钮同一条路径）
##                      注意与 main.gd 的 --noai 区分：--noai 是"物理 A/B 用，不生成对手"，
##                      --aioff 是"模拟玩家在菜单里关掉"，走的是 GameState 这条真实链路。
##   --render-fps=N     临时把渲染帧率改成 N（60 / 120），**不写存档**
func apply_cli_args(args: PackedStringArray) -> void:
	# 普通游戏默认随机；旧检查/截图保留原固定配置，显式参数可做随机验收。
	for a in args:
		if a.begins_with("--check=") or a.begins_with("--shot"):
			race_variants_enabled = false
	if "--race-variants" in args: race_variants_enabled = true
	if "--fixed-race" in args: race_variants_enabled = false
	if "--movie-clock" in args:
		movie_clock = true
	if "--aioff" in args:
		ai_enabled = false
	elif "--aion" in args:
		ai_enabled = true
	for a in args:
		if a.begins_with("--race-seed="): _requested_race_seed = int(a.trim_prefix("--race-seed="))
		if a.begins_with("--race-combination="): _requested_combination = int(a.trim_prefix("--race-combination="))
		if a.begins_with(ARG_RENDER_FPS):
			apply_render_fps_override(_to_int(a.substr(ARG_RENDER_FPS.length())))


## 统一应用渲染帧率并存档。这是菜单**唯一**该调的入口。
func set_render_fps(value: int) -> void:
	render_fps = sanitize_render_fps(value)
	Engine.max_fps = render_fps
	_save_display_settings(true)


## 命令行 / 启动期覆盖：**只改本次生效值，不落盘**。
## 与 set_render_fps 的区别就这一条 —— 验收脚本（或玩家想临时试一下 120）
## 不该改写玩家在菜单里做出的选择。
func apply_render_fps_override(value: int) -> void:
	render_fps = sanitize_render_fps(value)
	Engine.max_fps = render_fps


## 白名单过滤：不在 60/120 里的一律退回默认 60。
## 为什么不做"任意整数都收"：max_fps 是个会影响输入采样与渲染时序的全局开关，
## 手改存档改出 3 或 9999 时，宁可按默认跑，也不要让游戏卡在一个荒唐的帧率上。
func sanitize_render_fps(value: int) -> int:
	if RENDER_FPS_OPTIONS.has(value):
		return value
	return DEFAULT_RENDER_FPS


## 存档里的帧率（**不**受命令行覆盖影响）。测试用它证明"命令行没改写存档"。
func read_saved_render_fps(path := "") -> int:
	var p := settings_path if path == "" else path
	var cfg := ConfigFile.new()
	if cfg.load(p) != OK:
		return DEFAULT_RENDER_FPS
	return sanitize_render_fps(_to_int(cfg.get_value(SETTINGS_SECTION, SETTINGS_KEY_FPS, DEFAULT_RENDER_FPS)))


func _load_display_settings() -> void:
	render_fps = DEFAULT_RENDER_FPS
	window_size = Vector2i(0, 0)
	steering_sensitivity = 1.0
	var cfg := ConfigFile.new()
	var loaded := cfg.load(settings_path) == OK
	var saved_language: Variant = cfg.get_value("locale", "language", "automatic") if loaded else "automatic"
	language_choice = saved_language if saved_language is String and LANGUAGES.has(saved_language) else DEFAULT_LANGUAGE
	_apply_language()
	_load_drift_keys(cfg)
	if not loaded:
		return
	for key in ["dynamic_chase_enabled", "ghost_enabled", "photo_finish_enabled", "camera_shake_enabled"]:
		set(key, cfg.get_value("racing", key, true) == true)
	steering_sensitivity = sanitize_steering_sensitivity(cfg.get_value("controls", "steering_sensitivity", 1.0))
	render_fps = sanitize_render_fps(_to_int(cfg.get_value(SETTINGS_SECTION, SETTINGS_KEY_FPS, DEFAULT_RENDER_FPS)))
	var saved: Variant = cfg.get_value(SETTINGS_SECTION, SETTINGS_KEY_WINDOW, Vector2i(0, 0))
	if saved is Vector2i:
		window_size = saved


func _load_drift_keys(cfg: ConfigFile) -> void:
	for player in range(2):
		var key: Variant = cfg.get_value("controls", "drift_p%d" % (player + 1), DRIFT_DEFAULT_KEYS[player])
		drift_keys[player] = key if key is Vector2i and _drift_key_conflict(key).is_empty() else DRIFT_DEFAULT_KEYS[player]
	if _same_keyboard_key(drift_keys[0], drift_keys[1]):
		drift_keys.assign(DRIFT_DEFAULT_KEYS)
	_apply_drift_keys()


## 空字符串表示成功，其余值交给设置页显示具体冲突或保存失败。
func save_drift_key(player: int, key: Vector2i) -> String:
	var conflict := _drift_key_conflict(key)
	if not conflict.is_empty():
		return conflict
	if _same_keyboard_key(key, drift_keys[1 - player]):
		return "p2_drift" if player == 0 else "p1_drift"
	var cfg := ConfigFile.new()
	var error := cfg.load(settings_path)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		return "save_failed"
	cfg.set_value("controls", "drift_p%d" % (player + 1), key)
	if cfg.save(settings_path) != OK:
		return "save_failed"
	drift_keys[player] = key
	_apply_drift_keys()
	return ""


static func _same_keyboard_key(first: Vector2i, second: Vector2i) -> bool:
	return first.x == second.x and (first.y == second.y or first.y == KEY_LOCATION_UNSPECIFIED
		or second.y == KEY_LOCATION_UNSPECIFIED)


func _drift_key_conflict(key: Vector2i) -> String:
	if key.x in [KEY_NONE, KEY_UNKNOWN, KEY_ESCAPE, KEY_ALT, KEY_META, KEY_CAPSLOCK, KEY_NUMLOCK, KEY_SCROLLLOCK] \
			or key.y not in [KEY_LOCATION_UNSPECIFIED, KEY_LOCATION_LEFT, KEY_LOCATION_RIGHT] \
			or OS.get_keycode_string(key.x).is_empty():
		return "reserved"
	if key.x not in [KEY_SHIFT, KEY_CTRL] and key.y != KEY_LOCATION_UNSPECIFIED:
		return "reserved"
	var logical: int = key.x
	if _keyboard_layout_available():
		var mapped := DisplayServer.keyboard_get_keycode_from_physical(key.x)
		if mapped != KEY_NONE:
			logical = mapped
	for action in P2_KEYBOARD:
		if _same_keyboard_key(key, P2_KEYBOARD[action]):
			return "p2_" + action
	for action in InputMap.get_actions():
		if action == &"drift" or String(action).begins_with("p1_") or String(action).begins_with("p2_"):
			continue
		for event in InputMap.action_get_events(action):
			if event is InputEventKey and not (event.alt_pressed or event.shift_pressed or event.ctrl_pressed or event.meta_pressed):
				if event.physical_keycode != KEY_NONE:
					if _same_keyboard_key(key, Vector2i(event.physical_keycode, event.location)):
						return String(action)
				elif _same_keyboard_key(Vector2i(logical, key.y), Vector2i(event.keycode, event.location)):
					return String(action)
	return ""


func _apply_drift_keys() -> void:
	for action in ["drift", "p1_drift", "p2_drift"]:
		if not InputMap.has_action(action):
			continue
		Input.action_release(action)
		InputMap.action_erase_events(action)
		InputMap.action_add_event(action, keyboard_event(drift_keys[1 if action == "p2_drift" else 0]))


static func keyboard_event(key: Vector2i) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = key.x
	event.location = key.y
	return event


static func drift_key_name(key: Vector2i) -> String:
	if key.x == KEY_SHIFT:
		return "左 Shift" if key.y == KEY_LOCATION_LEFT else ("右 Shift" if key.y == KEY_LOCATION_RIGHT else "Shift")
	if key.x == KEY_CTRL:
		return "左 Ctrl" if key.y == KEY_LOCATION_LEFT else ("右 Ctrl" if key.y == KEY_LOCATION_RIGHT else "Ctrl")
	var label: int = key.x
	if _keyboard_layout_available():
		var mapped := DisplayServer.keyboard_get_label_from_physical(key.x)
		if mapped != KEY_NONE:
			label = mapped
	return "主键盘 /" if label == KEY_SLASH and key.x == KEY_SLASH else OS.get_keycode_string(label)


static func _keyboard_layout_available() -> bool:
	return OS.has_feature("pc") and DisplayServer.get_name() != "headless"


static func resolve_language(choice: String, system_locale: String) -> String:
	if choice != "automatic":
		return choice if LANGUAGES.has(choice) else DEFAULT_LANGUAGE
	var locale: String = TranslationServer.standardize_locale(system_locale)
	var base := locale.get_slice("_", 0)
	if base == "zh":
		var parts := locale.split("_")
		if "Hant" in parts:
			return "zh_TW"
		if "Hans" in parts:
			return DEFAULT_LANGUAGE
		return "zh_TW" if "TW" in parts or "HK" in parts or "MO" in parts else DEFAULT_LANGUAGE
	return base if LANGUAGES.has(base) else DEFAULT_LANGUAGE


func set_language(choice: String) -> bool:
	if not LANGUAGES.has(choice):
		return false
	if choice == language_choice:
		return true
	var cfg := ConfigFile.new()
	var error := cfg.load(settings_path)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		return false
	cfg.set_value("locale", "language", choice)
	if cfg.save(settings_path) != OK:
		return false
	language_choice = choice
	_apply_language()
	language_changed.emit()
	return true


func _apply_language() -> void:
	var locale := resolve_language(language_choice, OS.get_locale())
	TranslationServer.set_locale(locale)
	preload("res://scripts/ui_theme.gd").set_font_language(locale)
	var title := tr("棱角飞车")
	get_tree().root.title = title if title == "EDGE RACER" else "%s · EDGE RACER" % title


## 写回设置。先 load 再 save：ConfigFile.save 是整文件覆写，
## 不读回来就会把另一个键抹掉（首版只有两个键，但这条坑值得一开始就避开）。
## include_fps=false 用于"只保存窗口尺寸"——命令行覆盖期就走这条路，
## 保证 --render-fps 永远碰不到存档里的帧率。
func _save_display_settings(include_fps: bool) -> bool:
	var cfg := ConfigFile.new()
	cfg.load(settings_path)
	if include_fps:
		cfg.set_value(SETTINGS_SECTION, SETTINGS_KEY_FPS, render_fps)
	cfg.set_value(SETTINGS_SECTION, SETTINGS_KEY_WINDOW, window_size)
	var err := cfg.save(settings_path)
	if err != OK:
		push_warning("[GameState] 设置保存失败（%s）：error %d" % [settings_path, err])
		return false
	return true


func sanitize_steering_sensitivity(value: Variant) -> float:
	if (value is float or value is int) and is_finite(float(value)):
		return clampf(float(value), 0.6, 1.5)
	return 1.0


func set_steering_sensitivity(value: float) -> bool:
	var next := sanitize_steering_sensitivity(value)
	var cfg := ConfigFile.new()
	cfg.load(settings_path)
	cfg.set_value("controls", "steering_sensitivity", next)
	if cfg.save(settings_path) != OK:
		push_warning("转向灵敏度保存失败，保留原设置")
		return false
	steering_sensitivity = next
	return true


func toggle_racing_option(key: String) -> void:
	if key not in ["dynamic_chase_enabled", "ghost_enabled", "photo_finish_enabled", "camera_shake_enabled"]:
		return
	set(key, not get(key))
	var cfg := ConfigFile.new()
	cfg.load(settings_path)
	for option in ["dynamic_chase_enabled", "ghost_enabled", "photo_finish_enabled", "camera_shake_enabled"]:
		cfg.set_value("racing", option, get(option))
	if cfg.save(settings_path) != OK:
		push_warning("比赛设置保存失败")


## 窗口：只做"窗口化 + 装得下 + 居中"，**不切桌面分辨率、不进独占全屏**。
## 首启按当前工作区90%选16:9窗口；之后优先恢复存档尺寸，超屏时重新等比约束
## （换显示器 / 拔外接屏的玩家不会得到一个跑出屏幕外的窗口）。
func _apply_window() -> void:
	# UI自身已有容器/等比Stage，按真实窗口绘制，避免固定1080p画布放大到2K。
	get_tree().root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_tree().root.content_scale_size = Vector2i.ZERO
	# 嵌入预览由编辑器管理尺寸，不能拿桌面存档覆盖或保存它。
	if Engine.is_embedded_in_editor():
		return
	var screen := DisplayServer.window_get_current_screen()
	if screen < 0:
		screen = 0
	var wa := DisplayServer.screen_get_usable_rect(screen)
	if wa.size.x <= 0 or wa.size.y <= 0:
		# 拿不到可用工作区（headless / 无显示器）→ 一个像素都别动，
		# 也别把 (0,0) 当成玩家的窗口尺寸写进存档。
		return
	var mode := DisplayServer.window_get_mode()
	if mode != DisplayServer.WINDOW_MODE_WINDOWED and mode != DisplayServer.WINDOW_MODE_MAXIMIZED:
		# 最大化是玩家自己选的，别给人家还原掉
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	var target := window_size if window_size.x > 0 and window_size.y > 0 else DisplaySettings.initial_window_size(wa.size)
	var rect := DisplaySettings.resolve_window_rect(target, wa.position + Vector2i(8, 40), wa.size - Vector2i(16, 48))
	DisplayServer.window_set_size(rect.size)
	DisplayServer.window_set_position(rect.position)
	window_size = rect.size
	_save_display_settings(false)


## 用户拖动窗口边缘后的实际尺寸需要写回，否则下次启动只会恢复启动时的计算值。
func _on_window_size_changed() -> void:
	if Engine.is_embedded_in_editor():
		return
	remember_window_size(DisplayServer.window_get_size())


func remember_window_size(size: Vector2i) -> void:
	if size.x <= 0 or size.y <= 0 or size == window_size:
		return
	window_size = size
	_save_display_settings(false)


## 从 res://data/levels 读全部 .tres，按文件名排序保证顺序稳定。
##
## ⚠ 为什么**必须**用 ResourceLoader.list_directory 而不是 DirAccess（REL-STEP2A 实测）：
##   导出成 PCK 之后，包里的关卡条目被写成 level_1.tres.remap
##   （export_presets.cfg 的 script_export_mode=1 会把脚本编译成二进制并重映射）。
##   DirAccess 枚举出来的是**带 .remap 的文件名**，`load()` 一律报
##   "Resource file not found" → 玩家拿到 EXE 会看到「0 个关卡」，游戏直接没法玩。
##   ResourceLoader.list_directory() 返回的是**资源名**（导出前那个名字），5/5 可 load。
##   探针证据：godot-logs/rel-step1-pck-enum.log
##   真机证据：godot-logs/rel-step2a-pck-red.log（0 关）→ rel-step2a-pck-green.log（5 关）
func _load_levels() -> void:
	_levels.clear()
	var names := enumerate_level_names()
	if names.is_empty():
		push_warning("[GameState] %s 下没有枚举到任何 .tres 关卡" % LEVEL_DIR)
	for name in names:
		var cfg := load("%s/%s" % [LEVEL_DIR, name]) as LevelConfig
		if cfg != null:
			_levels.append(cfg)
			# 关卡序号用于拼地面贴图的约定路径（这是"位置"信息，不写进 .tres）
			cfg.set_level_index(_levels.size())
		else:
			push_warning("[GameState] %s 不是 LevelConfig，已跳过" % name)


## 列出 LEVEL_DIR 下的关卡资源名（已排序、已过滤）。
## 单独拆成可直调的方法：测试要能**不碰真实文件系统**就问到"你会枚举出什么"，
## 而真正的对错只有"在导出包里跑一遍"才说得清（见 _load_levels 的注释）。
func enumerate_level_names() -> PackedStringArray:
	return filter_level_names(ResourceLoader.list_directory(LEVEL_DIR))


## 纯过滤：只留 .tres 并排序。
## 负对照（tests/release_settings_test.gd 的 T-P2）：把 DirAccess 在导出包里
## 枚举到的那种 level_1.tres.remap 名字喂进来 → **一个都不剩**。
## 这条断言的意义：哪天有人把枚举器改回 DirAccess，T-P1 与 T-P2 会分头报警，
## 而不是等玩家装好 EXE 才发现 0 个关卡。
static func filter_level_names(raw: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for n in raw:
		if n.ends_with(".tres"):
			out.append(n)
	out.sort()
	return out


## 把 Variant 安全转成 int（存档可以被人手改成任何类型，int(非数值) 会直接报错）
static func _to_int(v: Variant) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is String:
		return int(v)
	return 0


func level_count() -> int:
	return _levels.size()


func get_level(idx: int) -> LevelConfig:
	if _levels.is_empty():
		return null
	return _levels[clampi(idx, 0, _levels.size() - 1)]


## 只供已确认房间规则的联机场景装配使用；不保存设置或单人纪录。
func begin_online_context(config: Dictionary) -> bool:
	if not _online_restore.is_empty() or not preload("res://scripts/online_room_state.gd").valid_config(config): return false
	var variant := RaceVariants.make(get_level(int(config.level_id)), int(config.race_seed), int(config.combination))
	if not variant.get("ok", false) or variant.summary.signature != config.rules_hash: return false
	for key in ["chosen_level", "max_speed_kmh", "speed_user_set", "split_screen", "endless_mode", "ai_enabled", "ghost_enabled", "photo_finish_enabled", "record_results_enabled", "movie_clock", "phase", "_requested_race_seed", "_requested_combination", "_race_variant_config", "_race_variant_level", "_race_variant_info"]:
		_online_restore[key] = get(key)
	chosen_level = int(config.level_id)
	max_speed_kmh = float(config.speed_kmh)
	speed_user_set = true
	split_screen = false
	endless_mode = false
	ai_enabled = false
	ghost_enabled = false
	photo_finish_enabled = false
	record_results_enabled = false
	movie_clock = false
	_requested_race_seed = int(config.race_seed)
	_requested_combination = int(config.combination)
	_race_variant_config = variant.config
	_race_variant_level = chosen_level
	_race_variant_info = variant.summary
	return true

func end_online_context() -> void:
	if _online_restore.is_empty(): return
	for key in _online_restore: set(key, _online_restore[key])
	_online_restore = {}
	finish_snapshot.clear()
	_reset_race_clock()
	release_drive_input()
	get_tree().paused = false

func current_level() -> LevelConfig:
	if _race_variant_config != null and _race_variant_level == chosen_level:
		return _race_variant_config as LevelConfig
	return get_level(chosen_level)


func effective_laps() -> int:
	var cfg := current_level()
	return 2 if split_screen else (0 if endless_mode or cfg == null else cfg.laps_to_finish)


func record_level_id() -> String:
	return get_level(chosen_level).resource_path.get_file().get_basename()


func save_race_record() -> void:
	if endless_mode or int(finish_snapshot.get("target", 0)) != 2: return
	if split_screen:
		for entry in finish_snapshot.get("entrants", []):
			_fill_best_records(entry, record_level_id() + ":split:" + str(entry.id))
	else:
		_fill_best_records(finish_snapshot, record_level_id())


func _fill_best_records(snapshot: Dictionary, level: String) -> void:
	var times: Array = snapshot.get("lap_times", [])
	var updated := false
	if record_results_enabled:
		updated = records.update_record(level, false, float(snapshot.get("total", 0.0)))
		for i in range(mini(2, times.size())):
			updated = records.update_lap(level, i, float(times[i])) or updated
	snapshot["new_record"] = updated
	snapshot["record_error"] = records.last_error
	snapshot["lap_bests"] = [records.best_lap(level, 0), records.best_lap(level, 1)]
	snapshot["total_best"] = records.best_time(level, false)


func finish_training(laps: int, last: float, best: float, times: Array) -> bool:
	if not endless_mode or phase not in [Phase.RACING, Phase.PAUSED]: return false
	_race_finished_ms = _race_pause_started_ms if _race_pause_started_ms >= 0 else _now_ms()
	finish_snapshot = {"training": true, "laps": laps, "last": last, "best": best,
		"target": 0, "total": race_total_time(), "lap_times": times.duplicate(),
		"endless_best": records.best_time(record_level_id(), true), "record_error": records.last_error,
		"field_size": 1, "outcome": "practice"}
	phase = Phase.FINISHED
	release_drive_input()
	get_tree().paused = true
	return true


func save_endless_lap(last: float, _best: float) -> void:
	if not split_screen and record_results_enabled and endless_mode and phase == Phase.RACING:
		records.update_record(record_level_id(), true, last)


## 只由main的玩家真实完赛结算链调用；不以名次或是否有AI作为门槛。
func save_level_completion() -> void:
	if split_screen or not record_results_enabled or endless_mode or phase != Phase.FINISHED \
			or int(finish_snapshot.get("target", 0)) != 2 or int(finish_snapshot.get("laps", 0)) < 2:
		return
	if finish_snapshot.has("completion_saved"): return
	var level := record_level_id()
	var was_completed := completion.is_completed(level)
	var saved := completion.mark_completed(level)
	finish_snapshot["completion_saved"] = saved
	finish_snapshot["completion_new"] = saved and not was_completed
	finish_snapshot["completion_count"] = completion.completed_count()
	finish_snapshot["completion_total"] = level_count()
	finish_snapshot["completion_error"] = "" if saved else completion.last_error


## main装配前调用一次；重试只prepare/reload，不重新抽签；enter_menu才清组合。
func ensure_race_variant() -> void:
	if not race_variants_enabled: return
	if _race_variant_config != null and _race_variant_level == chosen_level: return
	var seed_value := _requested_race_seed
	if seed_value < 0:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		seed_value = rng.randi()
	var result := RaceVariants.make(get_level(chosen_level), seed_value, _requested_combination)
	_race_variant_level = chosen_level
	if not result.get("ok", false):
		_race_variant_config = get_level(chosen_level).duplicate()
		_race_variant_config.layout = "invalid-variant:%d" % _requested_combination
		_race_variant_config.strict_layout = true
		_race_variant_info = {"error": result.get("error", "未知组合错误")}
		return
	_race_variant_config = result.config
	_race_variant_info = result.summary
	print("[随机组合试玩] %s" % JSON.stringify(_race_variant_info))


func race_variant_summary() -> Dictionary:
	return _race_variant_info.duplicate(true)


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
	if split_screen or not ai_enabled:
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
