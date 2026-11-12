extends Node3D
## 仅复制网格，不实例化车辆、脚本、碰撞或声音。摄影也复用此视觉代理。
var samples := PackedFloat32Array()
var cursor := 0
const STRIDE := 9
const HOLOGRAM := preload("res://shaders/ghost_hologram.gdshader")

func add_ghost_label(seconds: float) -> void:
	var label := Label3D.new()
	label.name = "GhostName"
	label.font = preload("res://scripts/ui_theme.gd").ui_font
	label.text = tr("幽灵车\n%s") % preload("res://scripts/race_records.gd").time_text(seconds)
	label.position = Vector3(0, 2.0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 56
	label.pixel_size = 0.008
	label.modulate = Color(0.45, 1.0, 0.87)
	label.outline_modulate = Color(0.02, 0.08, 0.12, 0.9)
	label.outline_size = 10
	label.no_depth_test = false
	add_child(label)

func build(source: Node3D, as_ghost := true) -> void:
	for node in source.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if not mesh.is_visible_in_tree(): continue
		var visual := MeshInstance3D.new()
		visual.mesh = mesh.mesh
		visual.transform = source.global_transform.affine_inverse() * mesh.global_transform
		for surface in range(mesh.mesh.get_surface_count()):
			var original := mesh.get_active_material(surface)
			if not as_ghost:
				visual.set_surface_override_material(surface, original)
				continue
			var material := ShaderMaterial.new()
			material.shader = HOLOGRAM
			if original is StandardMaterial3D:
				var color: Color = original.albedo_color
				material.set_shader_parameter("surface_lightness", color.r * 0.299 + color.g * 0.587 + color.b * 0.114)
				if original.albedo_texture != null:
					material.set_shader_parameter("detail_texture", original.albedo_texture)
			visual.set_surface_override_material(surface, material)
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(visual)

func play_at(seconds: float) -> void:
	if samples.size() < STRIDE * 2 or seconds > samples[samples.size() - STRIDE]:
		visible = false
		return
	visible = true
	if seconds < samples[cursor]: cursor = 0
	while cursor + STRIDE * 2 < samples.size() and samples[cursor + STRIDE] <= seconds:
		cursor += STRIDE
	var next := mini(cursor + STRIDE, samples.size() - STRIDE)
	var alpha := clampf((seconds - samples[cursor]) / maxf(0.0001, samples[next] - samples[cursor]), 0.0, 1.0)
	var a := Vector3(samples[cursor+1], samples[cursor+2], samples[cursor+3])
	var b := Vector3(samples[next+1], samples[next+2], samples[next+3])
	var qa := Quaternion(samples[cursor+4], samples[cursor+5], samples[cursor+6], samples[cursor+7]).normalized()
	var qb := Quaternion(samples[next+4], samples[next+5], samples[next+6], samples[next+7]).normalized()
	global_transform = Transform3D(Basis(qa.slerp(qb, alpha)), a.lerp(b, alpha))

static func append_sample(data: PackedFloat32Array, seconds: float, pose: Transform3D, progress: float) -> PackedFloat32Array:
	var q := pose.basis.orthonormalized().get_rotation_quaternion()
	data.append_array(PackedFloat32Array([seconds, pose.origin.x, pose.origin.y, pose.origin.z, q.x, q.y, q.z, q.w, progress]))
	return data
