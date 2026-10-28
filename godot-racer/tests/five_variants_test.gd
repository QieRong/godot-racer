extends SceneTree
const Variants := preload("res://scripts/race_variants.gd")
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("FIVE_VARIANT_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	var state := root.get_node("GameState")
	check(state.race_variants_enabled, "普通运行入口默认启用随机，不依赖专用CMD")
	for level in range(5):
		state.enter_menu()
		state.chosen_level = level
		var original: Resource = state.get_level(level)
		var before := JSON.stringify([original.elevation_profile, original.obstacle_count, original.obstacle_seed])
		state.apply_cli_args(PackedStringArray(["--race-seed=12345", "--race-combination=8"]))
		state.ensure_race_variant()
		var cfg: Resource = state.current_level()
		var summary: Dictionary = state.race_variant_summary()
		check(cfg != original and not cfg.elevation_profile.is_empty() and cfg.obstacle_count > 0,
			"L%d普通开赛实际采用坡道与障碍副本" % (level+1))
		check(summary.get("combination", -1) == 8, "L%d组合8可指定重放" % (level+1))
		state.prepare_race()
		state.ensure_race_variant()
		check(state.current_level() == cfg and state.race_variant_summary() == summary, "L%d同局准备/重试不重抽" % (level+1))
		check(JSON.stringify([original.elevation_profile, original.obstacle_count, original.obstacle_seed]) == before,
			"L%d基础资源无污染" % (level+1))
		var hashes: Array[String] = []
		for combo in range(9):
			var a := Variants.make(original, 12345, combo)
			check(a.get("ok", false), "L%d组合%d目录有效" % [level+1, combo])
			if not a.get("ok", false): continue
			var b := Variants.make(original, 12345, combo)
			check(a.summary == b.summary and not hashes.has(a.summary.signature), "L%d组合%d稳定且不同" % [level+1, combo])
			hashes.append(a.summary.signature)
		var choices: Dictionary = {}
		for seed_value in range(32):
			var pick := Variants.make(original, seed_value)
			if pick.get("ok", false): choices[pick.summary.combination] = true
		check(choices.size() >= 6, "L%d随机种子能抽到多个组合" % (level+1))
		state.enter_menu()
		state.apply_cli_args(PackedStringArray(["--fixed-race"]))
		state.ensure_race_variant()
		check(state.current_level() == original and state.race_variant_summary().is_empty(), "L%d固定对照保留原配置" % (level+1))
		state.apply_cli_args(PackedStringArray(["--race-variants"]))
	state.enter_menu()
	state.apply_cli_args(PackedStringArray(["--check=layout"]))
	check(not state.race_variants_enabled, "旧验收默认固定，基线未重冻")
	state.apply_cli_args(PackedStringArray(["--check=layout", "--race-variants"]))
	check(state.race_variants_enabled, "显式随机验收仍可启用")
	var alien: Resource = state.get_level(0).duplicate()
	alien.resource_path = "res://data/levels/level_99.tres"
	check(not Variants.make(alien, 1).get("ok", true), "未知关卡拒绝冒用其他目录")
	print("FIVE_VARIANT_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
