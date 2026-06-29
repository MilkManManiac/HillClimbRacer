// Slope + height snow/rock terrain shader (Godot 4.6 spatial).
// Snow accumulates on high, flat ground; steep faces show rock. A little procedural
// noise breaks up the albedo so big meshes don't read as flat plastic.
shader_type spatial;
render_mode cull_back;

uniform vec3 rock_color  : source_color = vec3(0.30, 0.28, 0.27);
uniform vec3 low_color   : source_color = vec3(0.40, 0.42, 0.40);
uniform vec3 snow_color  : source_color = vec3(0.93, 0.95, 1.0);
uniform float snow_height      = 8.0;    // world Y where snow begins
uniform float snow_blend       = 14.0;   // fade band
uniform float snow_slope_limit = 0.52;   // min up-ness (normal.y) to hold snow
uniform float rock_slope       = 0.80;   // below this up-ness -> rock shows through
uniform float noise_scale      = 0.04;
uniform float noise_amount     = 0.10;

varying vec3 world_pos;
varying vec3 world_normal;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	world_pos    = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float up = world_normal.y;                       // 1 flat, 0 vertical

	// macro noise variation
	float n = vnoise(world_pos.xz * noise_scale) - 0.5;

	// base: low ground tint on shallow, rock on steep
	float rockness = 1.0 - smoothstep(rock_slope, 1.0, up);
	vec3 albedo = mix(low_color, rock_color, rockness);
	albedo += n * noise_amount;

	// snow where high enough AND flat enough
	float h_mask = smoothstep(snow_height, snow_height + snow_blend, world_pos.y);
	float s_mask = smoothstep(snow_slope_limit, snow_slope_limit + 0.15, up);
	float snow = clamp(h_mask * s_mask + n * 0.15, 0.0, 1.0);

	ALBEDO = mix(albedo, snow_color, snow);
	ROUGHNESS = mix(0.95, 0.7, snow);
	METALLIC = 0.0;
}
