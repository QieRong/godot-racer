extends SceneTree
## 不增加灯数：真实灯池提前选择前方道路灯位；不判定人眼观感。
const Lighting := preload("res://scripts/street_lighting.gd")
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool,label: String) -> void:
	if ok: passed+=1
	else: failed+=1
	print("LIGHT_PREVIEW_ASSERT %s %s" % ["PASS" if ok else "FAIL",label])

func active_rows(pool: Node) -> Array[float]:
	var rows: Array[float]=[]
	for light in pool.get_children():
		if light is SpotLight3D and light.visible: rows.append(-light.global_position.z)
	return rows

func run() -> void:
	var focus := Node3D.new()
	root.add_child(focus)
	focus.position=Vector3(0,0,-16)
	var mounts: Array[Transform3D]=[]
	var targets: Array[Vector3]=[]
	for arc in [-48.0,0.0,48.0,96.0,144.0]:
		for side in [-1.0,1.0]:
			mounts.append(Transform3D(Basis.IDENTITY,Vector3(18*side,0,-arc)))
			targets.append(Vector3(0,0,-arc))
	var pool := Lighting.new()
	root.add_child(pool)
	pool.setup(mounts,targets,focus)
	pool.set_process(false)
	var rows := active_rows(pool)
	check(rows.size()==4 and pool.get_child_count()==4,"活动与分配的道路灯都保持4盏")
	check(rows.count(96.0)==2,"车在16m时，80m前方成对灯已启用")
	check(rows.count(48.0)==2,"保留32m前方当前路段成对灯")
	var unchanged := true
	for light in pool.get_children():
		unchanged=unchanged and is_equal_approx(light.light_energy,3.6)
		unchanged=unchanged and is_equal_approx(light.spot_range,42.0) and not light.shadow_enabled
	check(unchanged,"原灯亮度/射程/无阴影预算不改")
	focus.position=Vector3(0,0,2)
	pool.call("_refresh")
	check(active_rows(pool).count(0.0)==2,"预备远灯时保留脚下16m内最近一对灯")
	focus.position=Vector3(0,0,-16)
	focus.rotation.y=PI
	pool.call("_refresh")
	rows=active_rows(pool)
	check(rows.count(-48.0)==2 and rows.count(0.0)==2,"反向观察提前准备后方灯位")
	focus.position=Vector3(0,0,-600)
	pool.call("_refresh")
	check(active_rows(pool).is_empty(),"保留110m车身距离硬边界")
	pool.free()
	var empty := Lighting.new()
	root.add_child(empty)
	empty.setup([],[],focus)
	check(active_rows(empty).is_empty(),"空灯位数据保持安全无灯")
	empty.free()
	focus.free()
	print("LIGHT_PREVIEW_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
