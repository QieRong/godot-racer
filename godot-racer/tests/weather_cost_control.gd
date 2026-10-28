extends SceneTree
## 原weather专项的组件成本对照；不改原检查、阈值、物理或车辆行为。
var control := ""
var applied := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--weather-cost-control="):
			control=arg.trim_prefix("--weather-cost-control=")
	call_deferred("change_scene_to_file","res://scenes/menu.tscn")

func _process(_delta: float) -> bool:
	if applied or current_scene==null: return false
	var scenery:=current_scene.get_node_or_null("TrackScenery")
	if scenery==null: return false
	var pool:=scenery.get_node_or_null("StreetLighting")
	var posts:=scenery.get_node_or_null("BoundaryDelineators")
	if posts==null: return false
	if control in ["lights-off","both-off"] and pool!=null:
		pool.set_process(false)
		for light in pool.get_children(): light.visible=false
	if control in ["posts-off","both-off"]: posts.visible=false
	applied=true
	print("WEATHER_COST_CONTROL_APPLIED ",control)
	return false
