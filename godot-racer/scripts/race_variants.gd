extends RefCounted
## 有限的L2试验组合；目录数据是唯一变体参数源。不是任意程序化赛道。
const CATALOG_PATH := "res://data/variants/l2-catalog.json"

static func make(base: Resource, seed_value: int, combination: int = -1) -> Dictionary:
	var catalog_file := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if catalog_file == null: return {"ok": false, "error": "组合目录读取失败"}
	var parsed: Variant = JSON.parse_string(catalog_file.get_as_text())
	if not parsed is Dictionary: return {"ok": false, "error": "组合目录不是对象"}
	var catalog: Dictionary = parsed
	if base.resource_path != str(catalog.get("level", "")):
		return {"ok": false, "error": "组合目录与所选关卡不符"}
	var profiles: Array = catalog.get("profiles", [])
	var seeds: Array = catalog.get("obstacle_seeds", [])
	if profiles.size() != 3 or seeds.size() != 3:
		return {"ok": false, "error": "组合目录必须有3个剖面与3个障碍布局"}
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var selected := rng.randi_range(0, 8) if combination == -1 else combination
	if selected < 0 or selected >= 9: return {"ok": false, "error": "非法组合%d" % selected}
	var height_id := selected / 3
	var obstacle_id := selected % 3
	var cfg := base.duplicate() as Resource
	cfg.set_level_index(base.get("_level_index"))
	cfg.elevation_profile = str(profiles[height_id])
	cfg.max_grade = float(catalog.max_grade)
	cfg.obstacle_seed = int(seeds[obstacle_id])
	cfg.obstacle_count = int(catalog.obstacle_count)
	cfg.obstacle_kind = str(catalog.obstacle_kind)
	cfg.dynamic_obstacle_count = 0
	cfg.strict_layout = true
	# 顺序固定的数组序列化；不使用Dictionary迭代顺序或易变resource实例ID。
	var signature := JSON.stringify([int(catalog.version), base.resource_path, base.layout,
		cfg.elevation_profile, cfg.max_grade, cfg.obstacle_seed, cfg.obstacle_count,
		cfg.obstacle_kind, cfg.road_width, cfg.laps_to_finish]).sha256_text()
	return {"ok": true, "config": cfg, "summary": {"combination": selected,
		"height_id": height_id, "obstacle_id": obstacle_id, "seed": seed_value,
		"obstacle_seed": cfg.obstacle_seed, "signature": signature}}
