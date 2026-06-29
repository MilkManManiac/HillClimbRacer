// Procedural asphalt (Godot 4.6 spatial). World-space value noise for aggregate
// grain, tar patches, and thin cracks so the road isn't a flat gray slab.
shader_type spatial;
render_mode cull_back, diffuse_burley;

uniform vec3 base_color  : source_color = vec3(0.065, 0.065, 0.075);
uniform vec3 light_color : source_color = vec3(0.16, 0.16, 0.17);
uniform float world_scale = 0.22;
uniform float crack_amount = 0.30;

varying vec3 v_wpos;

vec2 hash2(vec2 p){ p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453); }
float vnoise(vec2 p){
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2(i).x,             b = hash2(i + vec2(1, 0)).x;
	float c = hash2(i + vec2(0, 1)).x, d = hash2(i + vec2(1, 1)).x;
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
float fbm(vec2 p){ float v = 0.0, a = 0.5; for(int i = 0; i < 5; i++){ v += a * vnoise(p); p *= 2.03; a *= 0.5; } return v; }

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = v_wpos.xz * world_scale;
	float grain  = fbm(uv * 8.0);
	float patch  = fbm(uv * 0.6);
	float mottle = fbm(uv * 2.0);

	vec3 col = mix(base_color, light_color, patch * 0.6 + grain * 0.4);
	col *= 0.85 + 0.3 * mottle;

	// cracks: thin dark ridged lines
	float cr = abs(fbm(uv * 1.3) - 0.5) * 2.0;
	float cracks = smoothstep(0.06, 0.0, cr) * crack_amount;
	col *= (1.0 - cracks * 0.8);

	ALBEDO = col;
	ROUGHNESS = clamp(0.72 + grain * 0.25 - patch * 0.15, 0.5, 0.98);
	METALLIC = 0.0;
	SPECULAR = 0.3;

	// cheap normal perturbation
	float e = 0.6;
	float nx = fbm(uv * 8.0 + vec2(e, 0)) - fbm(uv * 8.0 - vec2(e, 0));
	float nz = fbm(uv * 8.0 + vec2(0, e)) - fbm(uv * 8.0 - vec2(0, e));
	NORMAL_MAP = normalize(vec3(-nx, -nz, 1.0)) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.35;
}
