extends SceneTree
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("VARIANT_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	var state := root.get_node("GameState")
	check(state.has_method("ensure_race_variant"), "正式比赛入口持有唯一的组合配置")
	if not state.has_method("ensure_race_variant"):
		print("VARIANT_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
		quit(1)
		return
	state.chosen_level = 1
	var original: Resource = state.get_level(1)
	state.apply_cli_args(PackedStringArray(["--race-variants", "--race-seed=12345", "--race-combination=8"]))
	state.ensure_race_variant()
	var cfg: Resource = state.current_level()
	var first: Dictionary = state.race_variant_summary()
	check(first.get("combination", -1) == 8 and first.get("seed", -1) == 12345, "指定组合与种子可重放")
	check(cfg != original and cfg.elevation_profile != "" and cfg.obstacle_count > 0, "坡道障碍注入副本，基础关卡不变")
	check(original.elevation_profile == "" and original.obstacle_count == 0, "固定版缓存没有被随机污染")
	var target := preload("res://scripts/track_generator.gd").new()
	cfg.apply_to_track(target)
	check(target.ground_texture_path.ends_with("ground_L2_sunny.png"), "关卡副本保留L2位置身份与主题贴图")
	target.free()
	state.prepare_race()
	state.ensure_race_variant()
	check(state.race_variant_summary() == first and state.current_level() == cfg, "准备与跨圈复用同局组合")
	# restart_race只清时钟并重载；组合只在enter_menu失效，使用同一生产入口验证。
	state.prepare_race()
	state.ensure_race_variant()
	check(state.race_variant_summary() == first, "重试准备保持同局种子与组合")
	state.enter_menu()
	state.apply_cli_args(PackedStringArray(["--race-seed=54321", "--race-combination=0"]))
	state.ensure_race_variant()
	check(state.race_variant_summary().get("seed", -1) == 54321 and state.race_variant_summary().get("combination", -1) == 0,
		"返回菜单新开比赛能够重新选组合")
	state.enter_menu()
	state.chosen_level = 0
	state.apply_cli_args(PackedStringArray(["--fixed-race"]))
	state.ensure_race_variant()
	check(state.current_level() == state.get_level(0) and state.race_variant_summary().is_empty(), "显式固定对照保留L1基础版")
	state.apply_cli_args(PackedStringArray(["--race-variants"]))
	state.chosen_level = 1
	state.enter_menu()
	state.apply_cli_args(PackedStringArray(["--race-combination=99"]))
	state.ensure_race_variant()
	check(state.current_level().layout == "invalid-variant:99" and state.current_level().strict_layout,
		"非法组合明确拒绝发车，不回退固定版")
	state.enter_menu()
	state.apply_cli_args(PackedStringArray(["--race-combination=-1", "--race-seed=7"]))
	var hashes: Array[String] = []
	for combo in range(9):
		state.enter_menu()
		state.apply_cli_args(PackedStringArray(["--race-combination=%d" % combo]))
		state.ensure_race_variant()
		var summary: Dictionary = state.race_variant_summary()
		check(not hashes.has(summary.get("signature", "")), "组合%d具有独立稳定摘要" % combo)
		hashes.append(summary.get("signature", ""))
	print("VARIANT_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
