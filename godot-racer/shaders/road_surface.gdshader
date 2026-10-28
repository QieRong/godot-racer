shader_type spatial;
render_mode cull_disabled;

uniform vec4 road_color : source_color = vec4(0.22, 0.24, 0.26, 1.0);
uniform vec4 accent_color : source_color = vec4(0.29, 0.30, 0.31, 1.0);
uniform int surface_kind = 1;
uniform float wetness = 0.0;
uniform float surface_specular = 0.0;
uniform float ripple_clock = -1.0;
varying vec3 world_position;

float hash_point(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float soft_noise(vec2 p) {
	vec2 cell = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash_point(cell), hash_point(cell + vec2(1.0, 0.0)), f.x),
		mix(hash_point(cell + vec2(0.0, 1.0)), hash_point(cell + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_position.xz;
	float patch = soft_noise(p * 0.23);
	float grain = soft_noise(p * 8.0);
	grain = mix(grain, 0.5, smoothstep(18.0, 90.0, length(VERTEX)));
	vec3 color = mix(road_color.rgb, accent_color.rgb, patch * 0.45);
	color *= 0.98 + grain * 0.04;
	ROUGHNESS = 0.96;
	SPECULAR = surface_specular;
	METALLIC = 0.0;
	if (surface_kind == 3) {
		// 压实砂砾：较路外沙土更深、更细密，不做与赛道走向无关的硬条纹。
		color *= 0.94 + soft_noise(p * 1.3) * 0.12;
	}
	if (surface_kind == 4) {
		// 蓝灰压雪/薄冰斑块，起点白线仍为另一块高出路面1cm的独立网格。
		color = mix(color, accent_color.rgb, smoothstep(0.48, 0.78, patch) * 0.55);
		ROUGHNESS = 0.83;
	}
	if (wetness > 0.0) {
		float water = smoothstep(0.35, 0.72, patch) * wetness;
		ROUGHNESS = mix(0.72, 0.25, water);
		SPECULAR = surface_specular * water;
		color = mix(color, accent_color.rgb * 0.65, water * 0.45);
		vec2 cell = floor(p / 1.8);
		float seed = hash_point(cell);
		vec2 offset = vec2(0.25 + seed * 0.5, 0.25 + hash_point(cell + 7.0) * 0.5);
		vec2 q = fract(p / 1.8) - offset;
		float distance_to_drop = length(q);
		float clock_value = ripple_clock < 0.0 ? TIME : ripple_clock;
		float age = fract(clock_value * 0.72 + seed);
		float radius = age * 0.53;
		float width = max(fwidth(distance_to_drop) * 1.5, 0.014);
		float ring = (1.0 - smoothstep(width, width * 2.0, abs(distance_to_drop - radius)));
		ring *= (1.0 - age) * smoothstep(0.03, 0.16, age) * water * step(0.4, seed);
		// 涟漪只改变受光法线，不把浅色圆环画进ALBEDO，也不写EMISSION。
		// 高光由真实灯光、湿度和视角求出；无光处不会保留自带亮纹。
		vec2 slope = q / max(distance_to_drop, 0.03) * ring * 0.10;
		NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(slope.x, 0.0, slope.y, 0.0)).xyz);
	}
	ALBEDO = color;
}
