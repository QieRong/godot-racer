extends Node3D
## 首页专用机械展台；几何/材质不参与车辆物理，不自行旋转。

const ICON := preload("res://icon.svg")
const BRAND_OPACITY := 0.24

var radius := 2.0
var edge_materials: Array[StandardMaterial3D] = []
var edge_strengths := Vector3.ONE
var _brand_material: StandardMaterial3D
var _pulse: MeshInstance3D
var _pulse_material: StandardMaterial3D
var _idle_time := 0.0


func _ready() -> void:
	name = "PodiumRoot3D"
	_tier("BaseTier", radius * 1.16, radius * 1.13, 0.24, -0.42, Color("252c36"))
	_tier("MiddleTier", radius * 1.10, radius * 1.08, 0.12, -0.24, Color("343b46"))
	_tier("TopTier", radius * 1.08, radius * 1.06, 0.18, -0.09, Color("303846"))
	for i in range(3):
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("7fb3e8")
		material.emission_enabled = true
		material.emission = Color("68d9e8")
		material.emission_energy_multiplier = 0.7
		material.roughness = 0.45
		edge_materials.append(material)
		var ring := MeshInstance3D.new()
		ring.name = "EdgeLight%d" % i
		var torus := TorusMesh.new()
		var ring_radius: float = radius * [1.145, 1.09, 1.065][i]
		torus.inner_radius = ring_radius - 0.012
		torus.outer_radius = ring_radius + 0.012
		torus.rings = 48
		torus.ring_segments = 6
		ring.mesh = torus
		ring.position.y = [-0.46, -0.235, -0.03][i]
		ring.material_override = material
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(ring)
	# 顶面少量径向接缝，不使用额外真实灯光。
	var seam_material := StandardMaterial3D.new()
	seam_material.albedo_color = Color("242d38")
	seam_material.roughness = 0.75
	var seams := MultiMeshInstance3D.new()
	seams.name = "TopSeams"
	var box := BoxMesh.new()
	box.size = Vector3(0.014, 0.002, radius * 0.13)
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_3D
	instances.mesh = box
	instances.instance_count = 12
	for i in range(12):
		var yaw := TAU * i / 12.0
		var position := Vector3(sin(yaw), 0, cos(yaw)) * radius * 0.96
		position.y = 0.002
		instances.set_instance_transform(i, Transform3D(Basis(Vector3.UP, yaw), position))
	seams.multimesh = instances
	seams.material_override = seam_material
	seams.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(seams)
	_build_brand()
	_build_pulse()


func _tier(node_name: String, bottom: float, top: float, height: float, y: float, color: Color) -> void:
	var tier := MeshInstance3D.new()
	tier.name = node_name
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = bottom
	mesh.top_radius = top
	mesh.height = height
	mesh.radial_segments = 24
	tier.mesh = mesh
	tier.position.y = y
	var metal := StandardMaterial3D.new()
	metal.albedo_color = color
	metal.metallic = 0.55
	metal.roughness = 0.58
	tier.material_override = metal
	add_child(tier)


func set_edge_strengths(value: Vector3) -> void:
	edge_strengths = value
	for i in range(edge_materials.size()):
		edge_materials[i].emission_energy_multiplier = value[i] * 0.7
		edge_materials[i].albedo_color = Color("7fb3e8") * maxf(0.06, value[i])


func _build_brand() -> void:
	var front := Vector3(-4.8, 0, 6.5).normalized()
	var icon := MeshInstance3D.new()
	icon.name = "TopSurfaceIcon"
	# 水平贴在赛车脚下的圆形顶面，略抬高以避免与台面闪烁。
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * radius * 1.35
	icon.mesh = plane
	icon.position = front * radius * 0.08
	icon.position.y = 0.006
	icon.rotation.y = atan2(front.x, front.z)
	_brand_material = StandardMaterial3D.new()
	_brand_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_brand_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_brand_material.albedo_texture = ICON
	icon.material_override = _brand_material
	icon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(icon)
	set_brand_strength(0.0)


func _build_pulse() -> void:
	_pulse = MeshInstance3D.new()
	_pulse.name = "PulseRing"
	var ring := TorusMesh.new()
	ring.inner_radius = radius - 0.02
	ring.outer_radius = radius + 0.02
	ring.rings = 64
	ring.ring_segments = 6
	_pulse.mesh = ring
	_pulse.position.y = 0.018
	_pulse_material = StandardMaterial3D.new()
	_pulse_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_pulse_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_pulse_material.albedo_color = Color(0.4, 0.85, 0.95, 0)
	_pulse.material_override = _pulse_material
	_pulse.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_pulse)
	_pulse.hide()


func set_brand_strength(strength: float) -> void:
	_brand_material.albedo_color = Color(1.0, 1.0, 1.0, BRAND_OPACITY * clampf(strength, 0.0, 1.0))


func set_pulse(progress: float, active: bool) -> void:
	_pulse.visible = active
	_pulse.scale = Vector3.ONE * lerpf(0.75, 1.2, progress)
	_pulse_material.albedo_color.a = 0.65 * (1.0 - progress)


func animate_idle(delta: float, simplified: bool) -> void:
	_idle_time += delta
	var strength := 1.0 if simplified else 0.95 + 0.08 * sin(_idle_time * TAU / 3.2)
	set_edge_strengths(Vector3.ONE * strength)
