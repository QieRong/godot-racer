extends "res://tests/five_race_test.gd"
## 正式玩家Input链沿用原比赛测试；增加玩家与AI的真实障碍接触观察。
var contacts := {"player": 0, "ai": 0}
var watched := false

func _initialize() -> void:
	level = 1
	super._initialize()

func _process(_delta: float) -> bool:
	if watched or current_scene == null: return false
	var cars: Variant = current_scene.get("_opponents")
	var player := current_scene.get_node_or_null("RaceCar") as RigidBody3D
	if not cars is Array or cars.size() != 1 or player == null: return false
	for pair in [["player", player], ["ai", cars[0]]]:
		var actor := pair[1] as RigidBody3D
		actor.contact_monitor = true
		actor.max_contacts_reported = 16
		actor.body_entered.connect(_on_contact.bind(str(pair[0])))
	watched = true
	return false

func _on_contact(body: Node, actor: String) -> void:
	if body.name == "ObstacleBody": contacts[actor] += 1

func run() -> void:
	await super.run()
	check(watched, "玩家与AI真实物理接触观察均已连接")
	check(contacts.player == 0 and contacts.ai == 0, "玩家与AI全程零障碍接触")
	FileAccess.open(output.path_join("obstacle-contacts.json"), FileAccess.WRITE).store_string(
		JSON.stringify({"watched": watched, "contacts": contacts}))
	print("VARIANT_PLAYER_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
