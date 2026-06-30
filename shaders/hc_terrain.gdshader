shader_type spatial;
// Cheap terrain finish for the hill-climb corridor. Uses the mesh's vertex colors
// as the base albedo (the road markings / biome tint baked in _color_for) and adds:
//  * subtle large-scale value variation from world XZ (breaks up the flat fill)
//  * slope-based darkening (steeper ground reads darker, like packed dirt/shadow)
//  * a faint, tight specular highlight so hills catch the light instead of looking matte
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform float macro_scale = 0.012;   // frequency of the big value blotches
uniform float macro_strength = 0.10; // how much they lighten/darken
uniform float micro_scale = 0.35;    // fine grain frequency
uniform float micro_strength = 0.04;
uniform float slope_darken = 0.35;   // max darkening on vertical faces
uniform float spec_amount = 0.12;

// hash / value noise (cheap, no textures)
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 base = COLOR.rgb;

	// large-scale value variation tied to world position (deterministic, no swimming)
	float macro = vnoise(v_world.xz * macro_scale) - 0.5;
	float micro = vnoise(v_world.xz * micro_scale) - 0.5;
	float tint = 1.0 + macro * (macro_strength * 2.0) + micro * (micro_strength * 2.0);
	base *= clamp(tint, 0.7, 1.3);

	// slope darkening: NORMAL.y in view space isn't world-up, so use the world normal
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float flatness = clamp(wn.y, 0.0, 1.0);
	base *= mix(1.0 - slope_darken, 1.0, flatness);

	ALBEDO = base;
	ROUGHNESS = mix(0.95, 0.6, flatness);   // flatter ground a touch glossier
	SPECULAR = spec_amount;
	METALLIC = 0.0;
}
