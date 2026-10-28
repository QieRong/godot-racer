extends "res://tests/konbini_scene_preview.gd"
## 固定近店机位，检查室内灯实际响应区域的暖色占比；不代替用户视觉验收。
func capture(label: String) -> void:
	await super.capture(label)
	if label != "L3-start-720": return
	var on := Image.load_from_file(output.path_join("konbini-interior-on-1080.png"))
	var off := Image.load_from_file(output.path_join("konbini-interior-off-diagnostic-1080.png"))
	check(on != null and off != null, "暖光对照截图存在")
	if on == null or off == null: return
	# 与父测试的固定1920x1080近店机位对应，覆盖玻璃后的货架和收银区。
	var region := Rect2i(841, 494, 379, 179)
	var responding := 0
	var warm := 0
	var clipped := 0
	var red_blue_sum := 0.0
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var color := on.get_pixel(x, y)
			var delta := color - off.get_pixel(x, y)
			if delta.r + delta.g + delta.b <= 9.0 / 255.0: continue
			responding += 1
			red_blue_sum += color.r - color.b
			if color.r > color.b * 1.1 and color.r - color.b > 10.0 / 255.0: warm += 1
			if maxf(color.r, maxf(color.g, color.b)) > 0.98: clipped += 1
	var fraction := float(warm) / maxi(responding, 1)
	var mean_red_blue := red_blue_sum / maxi(responding, 1)
	check(responding > 1000, "暖光检验包含足够实际受光像素")
	check(fraction >= 0.35 and mean_red_blue >= 6.0 / 255.0,
		"受光室内呈明确暖色：暖色占比%.3f，平均红蓝差%.3f" % [fraction, mean_red_blue])
	check(float(clipped) / maxi(responding, 1) < 0.05, "室内受光区无大片过曝")
	FileAccess.open(output.path_join("konbini-warmth.json"), FileAccess.WRITE).store_string(
		JSON.stringify({"responding_pixels": responding, "warm_fraction": fraction,
			"mean_red_blue": mean_red_blue, "clipped_pixels": clipped}, "  "))
