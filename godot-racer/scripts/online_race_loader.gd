extends Node
## 真实main场景的装配/发车接入；不拥有车辆同步、结算或掉线等待策略。
signal loaded(race_id: String)
signal load_failed(reason: String)
signal started(race_id: String)
var race_scene: Node3D
var _room: Node
var _parent: Node
var _generation := 0
var _race_id := ""
var _ready_for_go := false
var _load_deadline := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)

func setup(room: Node, scene_parent: Node) -> void:
	_room = room
	_parent = scene_parent
	room.load_requested.connect(_load)
	room.room_changed.connect(_on_room_changed)
	room.race_started.connect(_go)
	room.left_room.connect(unload)

func _load(config: Dictionary, race_id: String) -> void:
	if not _race_id.is_empty(): return
	if not GameState.begin_online_context(config):
		load_failed.emit("LOCAL_RULES_MISMATCH")
		return
	_generation += 1
	var generation := _generation
	_race_id = race_id
	_ready_for_go = false
	_load_deadline = Time.get_ticks_msec() + 60000
	set_process(true)
	var path := "res://scenes/main.tscn"
	if ResourceLoader.load_threaded_request(path) != OK:
		_fail("SCENE_LOAD_FAILED")
		return
	while ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
		if generation != _generation: return
	if generation != _generation: return
	if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_LOADED:
		_fail("SCENE_LOAD_FAILED")
		return
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	race_scene = packed.instantiate()
	race_scene.set_meta("online_room_session", _room)
	race_scene.online_world_ready.connect(func(): _world_ready(generation, race_id))
	race_scene.online_load_failed.connect(func(reason: String):
		if generation == _generation: _fail(reason))
	_parent.add_child(race_scene)

func _world_ready(generation: int, race_id: String) -> void:
	if generation != _generation: return
	_ready_for_go = true
	if not _room.mark_loaded(race_id):
		_fail("STALE_LOAD_COMPLETION")
		return
	loaded.emit(race_id)

func _on_room_changed(snapshot: Dictionary) -> void:
	if _race_id.is_empty(): return
	if snapshot.get("phase") == "ROOM":
		unload()
	elif snapshot.get("phase") == "COUNTDOWN" and snapshot.get("race_id") == _race_id and _ready_for_go:
		race_scene.begin_online_countdown(_room.local_go_deadline_ms())

func _go(snapshot: Dictionary) -> void:
	if not _ready_for_go or snapshot.race_id != _race_id: return
	if not race_scene.begin_online_go(_race_id):
		_fail("SCENE_GO_REJECTED")
		return
	started.emit(_race_id)

func _process(_delta: float) -> void:
	if not _ready_for_go and Time.get_ticks_msec() >= _load_deadline:
		_fail("SCENE_LOAD_TIMEOUT")
	elif not _ready_for_go and not _room.connected:
		_fail("CONNECTION_LOST_DURING_LOADING")

func _fail(reason: String) -> void:
	unload()
	load_failed.emit(reason)

func unload() -> void:
	_generation += 1
	set_process(false)
	if is_instance_valid(race_scene): race_scene.queue_free()
	race_scene = null
	if not _race_id.is_empty(): GameState.end_online_context()
	_race_id = ""
	_ready_for_go = false
	GameState.hide_loading()

func _exit_tree() -> void:
	unload()
