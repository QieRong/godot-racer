extends Node
## 测试控制器：只调用正式共享Input控制链；不改姿态/速度/物理。
var pilot: RefCounted
var car: VehicleBody3D
var track: Node3D
var state: Node
var last_pos := Vector3.ZERO
var stuck := 0.0
var recover := 0.0
var recovery_frames := 0

func _physics_process(_delta: float) -> void:
	if state == null or state.call("phase_name") != "RACING": return
	var result: Dictionary = pilot.drive_recover(track, last_pos, stuck, recover,
		float(Engine.physics_ticks_per_second))
	last_pos = result.last_pos
	stuck = result.stuck_sec
	recover = result.recover_sec
	if result.handled:
		recovery_frames += 1
		return
	pilot.drive_track(track, 28.0)
