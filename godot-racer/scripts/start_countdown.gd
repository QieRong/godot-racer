extends CanvasLayer
## 3 秒发车倒计时 UI（Phase 01 · 竞速系统策划案 R2/R3，2026-10-18）。
##
## 仓库模块约定（与九个先例模块一致）：无 class_name（消费方 preload）、
## 不 get_node / get_tree、场景能力由 main 注入或经信号连接、默认不写 await。
##
## 时序（策划案 §5.2 同步发车序列）：
##   main 装配完成 → GameState.enter_countdown()（树暂停）→ add_child(本模块)
##   → 本模块 _process 在 phase == COUNTDOWN 时按 delta 累计
##   → COUNTDOWN_SECONDS 到点：显示"出发！"并 emit finished（只发一次）
##   → main 的发车回调**同步**完成三步：玩家解锁 + arm_opponents + start_race
##
## 为什么计时走 _process(delta) 而不是物理帧：倒计时期间树是暂停的，
## 物理帧不保证发射；本节点 process_mode = ALWAYS，_process 照走，
## 且 delta 是真实帧时间 —— 60 / 120 FPS 下总时长一致（AC-02）。
##
## 为什么退出确认能冻结倒计时：累计只在 phase == COUNTDOWN 时进行；
## ESC 弹出退出确认后相位是 EXIT_CONFIRM → 不累计；取消回 COUNTDOWN
## 从原秒数继续（R3/E7，配合 game_state.cancel_exit() 的保持暂停）。

signal finished   ## "出发！"到点，只发一次

## 倒计时总长（秒）。改时长只改这一处 —— 刻意**不**放进 LevelConfig：
## 倒计时是流程参数，不是关卡设计参数（策划案 §8，避免动关卡数据契约）。
const COUNTDOWN_SECONDS := 3.0
## "出发！"字样停留时长（秒）。给玩家一个明确的"现在可以走了"的瞬间；
## 它不阻挡输入（mouse_filter = IGNORE），只是视觉收旗。
const GO_HOLD_SECONDS := 0.5

var _label: Label = null
var _elapsed := -1.0          # <0 = 尚未进入 COUNTDOWN；≥0 = 已累计秒数
var _state := "idle"          # idle → running → go → done


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 高于 HUD；退出确认层也是 100 但它后加入树，同层按树序画在上面。
	layer = 100
	_build_ui()


func _build_ui() -> void:
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 96)
	_label.add_theme_color_override("font_color", Color.WHITE)
	# 白字黑描边：追尾视角下视线正中，无需低头；系统字体显式指定中文字形。
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("font_outline_size", 12)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 不阻挡驾驶输入
	_label.visible = false
	add_child(_label)


func _process(delta: float) -> void:
	match _state:
		"idle":
			# 等 main 挂载并把相位切到 COUNTDOWN（同一帧尾完成，这里下一帧才跑）
			if GameState.phase == GameState.Phase.COUNTDOWN:
				_state = "running"
				_elapsed = 0.0
				_label.visible = true
				_label.text = str(int(COUNTDOWN_SECONDS))
		"running":
			# 退出确认弹出时相位不是 COUNTDOWN → 不累计（冻结）
			if GameState.phase != GameState.Phase.COUNTDOWN:
				return
			_elapsed += delta
			var left := COUNTDOWN_SECONDS - _elapsed
			if left > 0.0:
				_label.text = str(int(ceil(left)))
				return
			# 到点：亮"出发！"并通知 main（只发一次）
			_state = "go"
			_label.text = "出发！"
			finished.emit()
		"go":
			# GO 后相位已是 RACING —— 按时间收旗，不看相位
			_elapsed += delta
			if _elapsed >= COUNTDOWN_SECONDS + GO_HOLD_SECONDS:
				_label.visible = false
				_state = "done"
		"done":
			pass
