extends Node
## 可选本地开发桥接；发行模板不加载第三方插件，也不创建网络连接。
const RUNTIME_PATH := "res://addons/godot_mcp/runtime/mcp_runtime.gd"

func _ready() -> void:
	if not OS.has_feature("editor"):
		return
	if not ResourceLoader.exists(RUNTIME_PATH):
		return
	var runtime: GDScript = load(RUNTIME_PATH)
	var bridge: Node = runtime.new()
	bridge.name = "Bridge"
	add_child(bridge)
