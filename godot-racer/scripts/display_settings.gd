extends RefCounted
## 窗口尺寸策略：**纯几何计算**，一行 DisplayServer 都不碰。
##
## 为什么单独拆成模块（而不是塞进 game_state.gd 的 _ready 里）：
##   这段逻辑是"给一个目标尺寸 + 一块可用工作区，算出该用多大、放哪"的算术题，
##   无状态、无引擎依赖 —— 拆出来测试才能**直接喂假屏幕**把它钉死。
##   否则"首启按可用工作区等比缩小并居中"这种需求只能靠人肉看一眼窗口，
##   哪天回归了没人会复现（笔记本 1366×768 的可用工作区只有约 1366×700，
##   1280×720 是**装不下**的 —— 这正是要测的那个分支）。
##
## 刻意不做的事（Windows 首版的承诺）：
##   - 不切桌面分辨率、不进独占全屏、不改刷新率 —— 那会把玩家的桌面搞乱，
##     而且一旦崩在独占全屏里，玩家连关掉都很费劲。
##   - 不记窗口位置，只记尺寸 —— 位置永远按**当前**工作区重算居中。
##     换显示器 / 拔外接屏时，记住的位置会让窗口跑到屏幕外，得不偿失。
##
## 保护它的测试：tests/release_settings_test.gd 的 T-W1 ~ T-W5。
## 调用方：GameState._apply_window()（唯一出口）。

## 目标逻辑画布。与 project.godot 的 viewport_width/height 保持一致；
## 改这里**必须**同时改 project.godot，否则逻辑分辨率与窗口比例会分叉。
const TARGET_SIZE := Vector2i(1280, 720)


## 把 target 等比塞进 work_size 并居中。
##   target     期望窗口尺寸（首启 = TARGET_SIZE，之后 = 存档里的 window_size）
##   work_pos   当前屏幕**可用工作区**的原点（屏幕绝对坐标，已排除任务栏）
##   work_size  当前屏幕可用工作区的尺寸
## 返回的 Rect2i 用屏幕绝对坐标表示。
##
## 三条不变量（T-W1 ~ T-W5 逐条钉死）：
##   ① 装得下优先：拿不到可用工作区（headless / 无显示器）时原样返回，调用方就别动窗口
##   ② 只缩不放：工作区比目标大时保持 1280×720，绝不为了"填满"而放大
##   ③ 等比：缩放后宽高比与 target 一致，画面不会被拉扁
static func resolve_window_rect(target: Vector2i, work_pos: Vector2i, work_size: Vector2i) -> Rect2i:
	var t := _sanitize_target(target)
	if work_size.x <= 0 or work_size.y <= 0:
		return Rect2i(work_pos, t)
	var s := minf(1.0, minf(float(work_size.x) / float(t.x), float(work_size.y) / float(t.y)))
	# roundi 而不是 floori：s 常常是 wa/t 的精确商，浮点误差会把它算成 699.9999，
	# 一 floor 就凭空少 1 像素（T-W2 的第一版就是这么抖的）。再夹一次保证仍然装得下。
	var size := Vector2i(
		clampi(roundi(float(t.x) * s), 1, work_size.x),
		clampi(roundi(float(t.y) * s), 1, work_size.y))
	var pos := work_pos + Vector2i(
		int(floor(float(work_size.x - size.x) * 0.5)),
		int(floor(float(work_size.y - size.y) * 0.5)))
	return Rect2i(pos, size)


## 存档里的尺寸可能是 (0,0)（没存过）或被人手改成负数 —— 一律回退到目标画布。
static func _sanitize_target(target: Vector2i) -> Vector2i:
	if target.x <= 0 or target.y <= 0:
		return TARGET_SIZE
	return target
