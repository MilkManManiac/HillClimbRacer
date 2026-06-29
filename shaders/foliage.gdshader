// Instanced foliage shader (Godot 4.6 spatial) for MultiMesh trees/bushes.
// - per-instance albedo tint via COLOR (use_colors)
// - per-instance wind phase/amp/snow via INSTANCE_CUSTOM (x=phase, y=amp, z=snow)
// - cheap wind sway that keeps the base planted, snow on up-facing surfaces, soft backlight
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap;

uniform vec2 wind_dir = vec2(1.0, 0.4);
uniform float wind_strength = 0.10;
uniform float wind_speed = 1.2;
uniform float sway_height = 0.16;     // how strongly local height scales sway
uniform vec3 snow_color : source_color = vec3(0.95, 0.96, 1.0);
uniform float roughness_val = 0.92;

varying float v_up;
varying float v_snow;

void vertex() {
	// local height drives the sway mask (trunk base stays planted, canopy moves)
	float mask = clamp(VERTEX.y * sway_height, 0.0, 1.0);
	float phase = INSTANCE_CUSTOM.x * 6.2831;
	float amp = INSTANCE_CUSTOM.y;
	vec3 wpos = MODEL_MATRIX[3].xyz;
	float t = TIME * wind_speed + phase + dot(wpos.xz, vec2(0.04, 0.03));
	float sway = sin(t) + 0.3 * sin(t * 2.7);
	vec2 d = normalize(wind_dir) * sway * wind_strength * amp * mask;
	VERTEX.x += d.x;
	VERTEX.z += d.y;
	v_up = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz).y;
	v_snow = INSTANCE_CUSTOM.z;
}

void fragment() {
	vec3 base = COLOR.rgb;
	// snow dusting on up-facing surfaces, scaled by per-instance snow amount (z)
	float snow = smoothstep(0.25, 0.75, v_up) * clamp(v_snow, 0.0, 1.0);
	ALBEDO = mix(base, snow_color, snow);
	ROUGHNESS = mix(roughness_val, 0.8, snow);
	METALLIC = 0.0;
	BACKLIGHT = base * 0.25;
}
