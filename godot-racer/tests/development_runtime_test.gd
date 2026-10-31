extends SceneTree
## 用编辑器程序、发行模板和缺插件工程分别运行，验证真实自动加载行为。
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	await process_frame
	var runtime := root.get_node_or_null("MCPRuntime")
	var configured := str(ProjectSettings.get_setting("autoload/MCPRuntime", ""))
	var plugin_present := ResourceLoader.exists("res://addons/godot_mcp/runtime/mcp_runtime.gd")
	var should_load := OS.has_feature("editor") and plugin_present
	var bridge := runtime.get_node_or_null("Bridge") if runtime != null else null
	var valid := runtime != null and configured == "*res://scripts/development_runtime.gd"
	valid = valid and ((bridge != null) == should_load)
	if not should_load and runtime != null:
		valid = valid and runtime.get_child_count() == 0 and not runtime.is_processing()
	print("DEVELOPMENT_RUNTIME editor=%s plugin=%s bridge=%s PASS=%s" % [
		OS.has_feature("editor"), plugin_present, bridge != null, valid])
	quit(0 if valid else 1)
