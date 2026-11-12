extends "res://tests/variant_loading_probe.gd"
## 单变量渲染对照；仅诊断，不改变正式30秒门及生产装配逻辑。
var hidden_group := ""
var no_cast := false
var two_splits := false
var stage_times: Array[Dictionary] = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--probe-hide-group="):
			hidden_group = arg.trim_prefix("--probe-hide-group=")
		if arg == "--probe-no-cast": no_cast = true
		if arg == "--probe-two-splits": two_splits = true
	node_added.connect(_observe_node)
	super._initialize()

func _observe_node(node: Node) -> void:
	if node.name in ["TrackScenery", "SceneryDressing", "GroundRelief", "OpponentHolder", "Countdown"]:
		var entry := {"node": str(node.name), "ticks_ms": Time.get_ticks_msec()}
		stage_times.append(entry)
		print("SCENERY_STAGE ", JSON.stringify(entry))
	if no_cast and node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if two_splits and node is MultiMeshInstance3D:
		var sun: DirectionalLight3D = current_scene.get_node_or_null("Sun")
		if sun != null: sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	if not hidden_group.is_empty() and node is Node3D:
		if str(node.name) == hidden_group:
			node.visible = false

func sample() -> void:
	super.sample()
	rows[-1]["video_memory_bytes"] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	FileAccess.open(output.path_join("stages.json"), FileAccess.WRITE).store_string(
		JSON.stringify(stage_times, "\t"))
