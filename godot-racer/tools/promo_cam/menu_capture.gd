extends Node
## 菜单取景夹具（只读采集）：把 menu.tscn 当子节点挂进来，用**真实鼠标事件**
## 驱动 GUI（不是直接调函数、不改 GameState 里的关卡/纪录），
## 让"首页 → 选关 → 点击开始 → 加载 → 巡览"这条链路按真实交互跑一遍。
##
## 用法：
##   godot --path <工程> --write-movie out.avi --fixed-fps 30 --quit-after N \
##         res://tools/promo_cam/menu_capture.tscn -- --flow=levels
##
## --flow=home      只录首页展车
## --flow=levels    首页 → 选关 → 切换三张关卡详情 → 点开始（继续进加载/巡览）
## --flow=settings  首页 → 点设置

var _root: Node = null
var _frame := 0
var _flow := "levels"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--flow="):
			_flow = a.split("=", true, 1)[1]
	_root = load("res://scenes/menu.tscn").instantiate()
	add_child(_root)
	# 只数「真正画出来的帧」：加载期间主循环可能多跑几轮而不渲染，
	# 用 _process 计数会让时间轴比成片快出去（实测 360 计次只写到 268 帧）。
	RenderingServer.frame_post_draw.connect(_on_drawn)
	print("[菜单夹具] flow=%s 启动" % _flow)


func _on_drawn() -> void:
	_frame += 1
	match _flow:
		"levels":
			match _frame:
				90: _click("HomeStartButton")
				180: _click("LevelCard1")
				240: _click("LevelCard2")
				300: _click("LevelCard4")
				360: _click("LevelCard2")
				420: _click("StartButton")
		"settings":
			match _frame:
				90: _click("HomeSettingsButton")
		_:
			pass


func _click(node_name: String) -> void:
	var n := _root.find_child(node_name, true, false)
	if n == null:
		printerr("[菜单夹具] 找不到节点 %s" % node_name)
		return
	var c := n as Control
	if c == null:
		printerr("[菜单夹具] %s 不是 Control" % node_name)
		return
	var p := c.get_global_transform_with_canvas() * (c.size * 0.5)
	# 不发鼠标移动事件：关卡卡片有 tooltip，悬停会弹出「布局参考：Willow Springs…」
	# 压住右侧详情文字，录进宣传片就是穿帮。这里只触发按钮自己的 pressed 处理器，
	# 页面跳转、关卡选择、纪录读取全部还是真实逻辑，没有伪造任何数据。
	var button := n as BaseButton
	if button != null:
		button.emit_signal("pressed")
		print("[菜单夹具] 帧%d 触发 %s（按钮 pressed，位置 %s）" % [_frame, node_name, p])
		return
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.pressed = true
	down.position = p
	down.global_position = p
	get_viewport().push_input(down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = p
	up.global_position = p
	get_viewport().push_input(up)
	print("[菜单夹具] 帧%d 鼠标点击 %s @ %s" % [_frame, node_name, p])
