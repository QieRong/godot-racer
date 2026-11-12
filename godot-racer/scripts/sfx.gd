extends Node
## 短音效固定8声部池；UI与比赛事件共享，循环声由所属场景管理。
const OVANI_UI := {
	"界面点击": "Click Bounce.wav", "界面悬停": "Hover Over.wav", "界面返回": "Quit Out.wav",
	"界面肯定": "Select.wav", "界面否定": "Error.wav", "界面错误": "Error.wav",
}
var _voices: Array[AudioStreamPlayer] = []
var _streams: Dictionary = {}
var _last_played: Dictionary = {}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in range(8):
		var voice := AudioStreamPlayer.new()
		voice.bus = "SFX"
		add_child(voice)
		_voices.append(voice)

func play_clip(title: String, level := -16.0, pitch := 1.0, from_position := 0.0) -> void:
	var now := Time.get_ticks_msec()
	if now - int(_last_played.get(title, -1000)) < 100: return
	_last_played[title] = now
	var path := "res://assets/audio/sfx/%s.ogg" % title
	if title in ["countdown_tick", "countdown_go"]: path = "res://assets/audio/sfx/%s.wav" % title
	if title in OVANI_UI:
		var licensed_path: String = "res://assets/audio/ovani/" + OVANI_UI[title]
		# 专有素材不随公开源码分发；未安装素材时仍可使用原有音效。
		if ResourceLoader.exists(licensed_path): path = licensed_path
	if not _streams.has(path): _streams[path] = load(path)
	for voice in _voices:
		if voice.playing: continue
		voice.stream = _streams[path]
		voice.volume_db = level
		voice.pitch_scale = pitch
		voice.play(from_position)
		return

func button_pressed(button: Button) -> void:
	var title := "界面点击"
	if "返回" in button.text or "取消" in button.text: title = "界面返回"
	elif "确认" in button.text or "确定" in button.text: title = "界面肯定"
	play_clip(title, -20.0)

func button_hovered() -> void:
	play_clip("界面悬停", -30.0)

func _process(_delta: float) -> void:
	# 退出确认不让旧比赛提示继续响；UI反馈仍可播放。
	if GameState.phase_name() == "LOADING":
		for voice in _voices:
			if voice.playing: voice.stop()
