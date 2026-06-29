// Windshield rain (Godot 4.6 spatial). Droplets accumulate and run down; the wiper
// sweep clears a wedge. Drive `rain_amount` (0..1) and `wiper_angle` from Cockpit.gd.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

uniform float rain_amount : hint_range(0,1) = 0.0;
uniform float wiper_angle = -10.0;

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
	vec2 uv = UV;
	float drip = vnoise(vec2(uv.x * 6.0, uv.y * 3.0 - TIME * 0.18));
	float speckle = vnoise(uv * 24.0 + TIME * 0.4);
	float wet = smoothstep(0.55, 0.92, drip) + speckle * 0.25;
	wet *= rain_amount;

	// wiper clears a wedge from the windshield base
	float frag_ang = atan(uv.x - 0.5, 1.0 - uv.y);
	float cleared = smoothstep(0.14, 0.0, abs(frag_ang - wiper_angle));
	wet *= (1.0 - cleared);

	ALBEDO = vec3(0.62, 0.66, 0.72);
	ALPHA = clamp(wet, 0.0, 0.8);
	ROUGHNESS = 0.05;
}
