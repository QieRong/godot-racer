extends RefCounted
## 测试专用：仅保存实例ID，避免诊断引用本身延长Playback寿命。
## stop()不代表AudioServer已释放回执；回收才是退出条件。


static func capture(player: Node) -> int:
	if not bool(player.call("has_stream_playback")):
		return 0
	var receipt: AudioStreamPlayback = player.call("get_stream_playback")
	return receipt.get_instance_id()


static func capture_tree(node: Node) -> Array[int]:
	var ids: Array[int] = []
	if node is AudioStreamPlayer or node is AudioStreamPlayer3D or node is AudioStreamPlayer2D:
		var receipt_id := capture(node)
		if receipt_id != 0:
			ids.append(receipt_id)
	for child in node.get_children():
		ids.append_array(capture_tree(child))
	return ids


static func released(receipt_id: int) -> bool:
	return receipt_id != 0 and not is_instance_id_valid(receipt_id)


static func wait_all_released(tree: SceneTree, ids: Array[int]) -> bool:
	if ids.is_empty():
		return false
	for receipt_id in ids:
		if not await wait_released(tree, receipt_id):
			return false
	return true


static func wait_released(tree: SceneTree, receipt_id: int, timeout_ms := 2000) -> bool:
	var started := Time.get_ticks_msec()
	var frames := 0
	while not released(receipt_id):
		if Time.get_ticks_msec() - started >= timeout_ms:
			print("AUDIO_DRAIN_TIMEOUT id=%d frames=%d elapsed_ms=%d" % [
				receipt_id, frames, Time.get_ticks_msec() - started])
			return false
		await tree.process_frame
		frames += 1
	print("AUDIO_DRAIN_RELEASED id=%d frames=%d elapsed_ms=%d" % [
		receipt_id, frames, Time.get_ticks_msec() - started])
	return true
