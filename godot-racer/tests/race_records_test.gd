extends SceneTree
var passed := 0
var failed := 0
var folder := "res://../godot-logs/audit-records-test"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence-dir="): folder = arg.trim_prefix("--evidence-dir=")
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else: failed += 1
	print("RECORDS_ASSERT %s %s" % ["PASS" if ok else "FAIL", message])

func run() -> void:
	if not ResourceLoader.exists("res://scripts/race_records.gd"):
		check(false, "纪录模块尚未实现")
		quit(1)
		return
	var script: GDScript = load("res://scripts/race_records.gd")
	var store = script.new()
	DirAccess.make_dir_recursive_absolute(folder)
	var path := folder.path_join("records.json")
	if "--verify-only" in OS.get_cmdline_user_args():
		check(store.load_from(path), "新进程从真实文件加载")
		check(is_equal_approx(store.best_time("level_1", false), 120.123), "普通两圈跨进程保留")
		check(is_equal_approx(store.best_time("level_1", true), 45.456), "无限单圈跨进程保留")
	else:
		check(not FileAccess.file_exists(path), "测试使用全新独立路径，不覆盖既有数据")
		check(store.load_from(path), "首次无文件正常初始化")
		check(store.update_record("level_1", false, 130.0), "首次普通纪录保存")
		check(not store.update_record("level_1", false, 140.0), "较慢成绩不覆盖")
		check(store.update_record("level_1", false, 120.123), "更快普通成绩更新")
		check(store.update_record("level_1", true, 45.456), "无限单圈独立保存")
		check(is_equal_approx(store.best_time("level_1", false), 120.123), "两类纪录不互相覆盖")
		check(is_zero_approx(store.best_time("level_2", false)), "不同关卡隔离")
		check(not store.update_record("level_1", true, -1.0), "负数不进入纪录")
		check(not store.update_record("level_1", true, INF), "无穷值不进入纪录")
		check(FileAccess.file_exists(path + ".bak"), "更换主文件前保存上一个有效备份")
		var bad_path := folder.path_join("corrupt.json")
		var file := FileAccess.open(bad_path, FileAccess.WRITE)
		file.store_string("{broken")
		file.close()
		check(not store.load_from(bad_path), "损坏文件明确报错")
		check(not store.update_record("level_1", false, 10.0), "不覆盖不可读的玩家存档")
		check(FileAccess.get_file_as_string(bad_path) == "{broken", "原损坏文件字节保留")
		store.load_from(folder.path_join("missing-dir/records.json"))
		check(not store.update_record("level_1", false, 20.0) and not store.last_error.is_empty(), "写入失败可见且不伪报成功")
	print("RECORDS_COMPLETE PASS=%d FAIL=%d" % [passed, failed])
	quit(0 if failed == 0 else 1)
