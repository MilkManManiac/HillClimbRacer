// Worn / scratched painted road line (Godot 4.6 spatial). The paint breaks up and
// fades via procedural noise so lines look old, not freshly painted. Use on thin
// quads lifted slightly above the asphalt. UV.x across the line, UV.y along it.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 paint_color : source_color = vec3(0.82, 0.70, 0.20); // faded yellow
uniform float wear = 0.50;   // 0 pristine .. 1 destroyed
uniform float fade = 0.30;   // overall fade toward asphalt

vec2 hash2(vec2 p){ p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453); }
float vnoise(vec2 p){
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2(i).x,             b = hash2(i + vec2(1, 0)).x;
	float c = hash2(i + vec2(0, 1)).x, d = hash2(i + vec2(1, 1)).x;
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	float n  = vnoise(UV * vec2(7.0, 26.0));
	float n2 = vnoise(UV * vec2(40.0, 90.0));
	// edges feather so the painted band isn't a hard rectangle
	float edge = 1.0 - abs(UV.x * 2.0 - 1.0);
	float coverage = smoothstep(wear, wear + 0.25, n) * clamp(edge * 2.0, 0.0, 1.0);
	coverage *= 1.0 - smoothstep(0.7, 1.0, n2) * 0.6;  // hairline scratches
	if (coverage < 0.18) discard;
	ALBEDO = mix(paint_color * 0.4, paint_color, coverage * (1.0 - fade));
	ROUGHNESS = 0.9;
	METALLIC = 0.0;
}
