shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

uniform vec4 hologram_color : source_color = vec4(0.18, 0.95, 0.82, 1.0);
uniform float surface_lightness = 0.7;
uniform sampler2D detail_texture : source_color, hint_default_white;
varying float world_height;

void vertex() {
	world_height = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	vec4 detail = texture(detail_texture, UV);
	float lightness = dot(detail.rgb, vec3(0.299, 0.587, 0.114)) * surface_lightness;
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 1.8);
	// 世界高度让车身和独立轮胎的扫描线对齐；细线只轻微调节亮度。
	float scan = 0.5 + 0.5 * sin(world_height * 150.0 - TIME * 2.5);
	float line = smoothstep(0.72, 0.95, scan);
	ALBEDO = mix(hologram_color.rgb * (0.55 + lightness * 0.35), vec3(0.72, 1.0, 0.94), rim);
	ALBEDO += hologram_color.rgb * line * 0.12;
	ALPHA = (0.18 + lightness * 0.12 + rim * 0.43 + line * 0.06) * detail.a;
}
