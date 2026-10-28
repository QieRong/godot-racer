extends SceneTree
## 在不含私有GLB的公开工程上运行，验证缺美术时仍可实际装配/发车。
var passed := 0
var failed := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed+=1
	else: failed+=1
	print("FALLBACK_ASSERT %s %s" % ["PASS" if ok else "FAIL",message])

func run() -> void:
	var state := root.get_node("GameState")
	check(not ResourceLoader.exists("res://models/environment/konbini_aoi_01.glb"),"公开夹具确实不含私有便利店GLB")
	for level in [2,4]:
		state.chosen_level=level
		change_scene_to_file("res://scenes/main.tscn")
		var deadline := Time.get_ticks_msec()+40000
		while Time.get_ticks_msec()<deadline:
			await process_frame
			if current_scene!=null and state.phase_name()=="RACING": break
		check(current_scene!=null and state.phase_name()=="RACING","L%d 缺私有美术仍可装配发车" % (level+1))
		if current_scene==null: quit(1);return
		var scene := current_scene
		check(scene.get_node("Track").find_child("RoadMesh",true,false)!=null
			and scene.get_node_or_null("RaceCar")!=null,"L%d 路面/车辆正常存在" % (level+1))
		check(scene.get_node("TrackScenery/SceneryDressing").get_child_count()==0,
			"L%d 缺私有GLB时跳过对应装饰组" % (level+1))
		state.enter_menu();current_scene=null;scene.free();await process_frame
	var music := state.find_child("MenuMusic",false,false)
	if music!=null: await music.shutdown_and_wait()
	preload("res://scripts/theme_sky.gd").clear_cached_textures()
	await process_frame
	print("FALLBACK_COMPLETE PASS=%d FAIL=%d" % [passed,failed])
	quit(0 if failed==0 else 1)
