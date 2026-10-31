extends RefCounted
## 仅替换RoadMesh材质，不改顶点、白线、碰撞或抓地力；颜色与路外地面分开。
const SHADER := preload("res://shaders/road_surface.gdshader")
const STYLES := {
	"training":[0,Color(0.18,0.205,0.22),Color(0.235,0.25,0.26),0.0],
	"sunny":[1,Color(0.22,0.24,0.26),Color(0.29,0.30,0.31),0.0],
	"rain":[2,Color(0.16,0.19,0.22),Color(0.19,0.23,0.26),0.85],
	"sand":[3,Color(0.25,0.18,0.10),Color(0.39,0.28,0.16),0.0],
	"snow":[4,Color(0.23,0.25,0.27),Color(0.26,0.28,0.30),0.0]
}

static func apply(track: Node3D, cfg: Resource) -> void:
	var road := track.find_child("RoadMesh",true,false) as MeshInstance3D
	if road==null: return
	var key: String = preload("res://scripts/scenery_dressing.gd").theme_key(cfg)
	var style: Array = STYLES[key]
	var material := ShaderMaterial.new()
	material.shader=SHADER
	material.set_shader_parameter("surface_kind",style[0])
	material.set_shader_parameter("road_color",style[1])
	material.set_shader_parameter("accent_color",style[2])
	material.set_shader_parameter("wetness",style[3])
	material.set_shader_parameter("surface_specular",0.4 if key=="rain" else 0.0)
	material.set_meta("road_theme",key)
	road.material_override=material
