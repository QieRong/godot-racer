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

const Ui := preload("res://scripts/ui_theme.gd")

var _label: Label = null
var _root: Control
var _title: Label
var _hint: Label
var _lights: Array[Panel] = []
var _accent := Ui.SKY
var _number_tween: Tween
var _elapsed := -1.0          # <0 = 尚未进入 COUNTDOWN；≥0 = 已累计秒数
var _state := "idle"          # idle → running → go → done


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 高于普通HUD，低于退出确认100；不依赖同层的入树先后顺序。
	layer = 90
	_build_ui()


func _build_ui() -> void:
	_accent = Ui.accent(GameState.current_level())
	_root = Control.new()
	_root.name = "CountdownRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	Ui.install(_root)
	var shade := ColorRect.new()
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.043137, 0.05098, 0.066667, 0.42)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)
	var stage := Ui.stage(_root)
	stage.name = "CountdownStage"
	var panel := Ui.panel(stage, "CountdownPanel", Rect2(443, 182, 480, 340), _accent)
	panel.add_theme_stylebox_override("panel", Ui.box(Ui.PANEL, _accent, 2, 24))
	_title = Ui.label(stage, "CountdownTitle", "准备发车", 24, _accent)
	Ui.place(_title, Rect2(467, 206, 432, 38))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label = Ui.label(stage, "CountdownNumber", "", 96)
	Ui.place(_label, Rect2(443, 254, 480, 144))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.pivot_offset = Vector2(240, 72)
	# Label实际主题常量是outline_size，不是font_outline_size。
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	var lights := Control.new()
	lights.name = "SignalLights"
	lights.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Ui.place(lights, Rect2(638, 407, 90, 18))
	stage.add_child(lights)
	for i in range(3):
		var light := Ui.panel(lights, "Light%d" % i, Rect2(i * 36, 0, 18, 18))
		_lights.append(light)
	_hint = Ui.label(stage, "CountdownHint", "可按住 W 准备起步\n倒计时结束后统一发车与计时", 18, Ui.MUTED)
	Ui.place(_hint, Rect2(467, 458, 432, 52))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.visible = false
	_root.visible = false


## 仅表现：Tween没有发车回调，不改_elapsed，不等待动画完成。
func _present_number(text: String) -> void:
	if _label.text == text:
		return
	_label.text = text
	if _number_tween != null and _number_tween.is_valid():
		_number_tween.kill()
	_label.scale = Vector2.ONE * 1.2
	_number_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_number_tween.tween_property(_label, "scale", Vector2.ONE, 0.20).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var lit := 3 if text == "出发！" else 4 - int(text)
	for i in range(_lights.size()):
		_lights[i].add_theme_stylebox_override("panel", Ui.box(_accent if i < lit else Ui.BORDER, _accent, 1, 0))


func _process(delta: float) -> void:
	match _state:
		"idle":
			# 等 main 挂载并把相位切到 COUNTDOWN（同一帧尾完成，这里下一帧才跑）
			if GameState.phase == GameState.Phase.COUNTDOWN:
				_state = "running"
				_elapsed = 0.0
				_root.visible = true
				_label.visible = true
				_present_number(str(int(COUNTDOWN_SECONDS)))
		"running":
			# 退出确认弹出时相位不是 COUNTDOWN → 不累计（冻结）
			if GameState.phase != GameState.Phase.COUNTDOWN:
				return
			_elapsed += delta
			var left := COUNTDOWN_SECONDS - _elapsed
			if left > 0.0:
				_present_number(str(int(ceil(left))))
				return
			# 到点：亮"出发！"并通知 main（只发一次）
			_state = "go"
			_present_number("出发！")
			_title.text = "比赛开始"
			_hint.text = "玩家与 AI 已同时放行" if GameState.effective_ai_count() > 0 else "计时已开始，开始你的练习"
			finished.emit()
		"go":
			# GO 后相位已是 RACING —— 按时间收旗，不看相位
			_elapsed += delta
			if _elapsed >= COUNTDOWN_SECONDS + GO_HOLD_SECONDS:
				_label.visible = false
				_root.visible = false
				_state = "done"
		"done":
			pass
