// Day/night sky (Godot 4.6 sky shader): authored gradient, drifting procedural clouds
// by day, twinkling stars + moon by night, and a sun disk that follows the sun light.
shader_type sky;

uniform vec3 top_color : source_color = vec3(0.20, 0.45, 0.85);
uniform vec3 horizon_color : source_color = vec3(0.60, 0.75, 0.92);
uniform vec3 ground_color : source_color = vec3(0.35, 0.34, 0.32);
uniform float sky_energy = 1.0;
uniform float sky_curve = 0.35;

uniform vec3 sun_glow_color : source_color = vec3(1.0, 0.85, 0.6);
uniform float sun_glow = 0.4;

uniform vec3 moon_dir = vec3(0.3, 0.5, -0.8);
uniform float moon_size = 0.035;
uniform float star_amount = 0.0;     // 0 day .. 1 night
uniform float cloud_amount = 1.0;    // 0 night .. 1 day
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);

float hash(vec3 p){ p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
float hash2(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 34.345); return fract(p.x * p.y); }
float vnoise(vec2 p){
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash2(i), b = hash2(i + vec2(1, 0));
	float c = hash2(i + vec2(0, 1)), d = hash2(i + vec2(1, 1));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p){ float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++){ v += a * vnoise(p); p *= 2.02; a *= 0.5; } return v; }

void sky() {
	vec3 dir = EYEDIR;
	float h = clamp(dir.y, 0.0, 1.0);
	vec3 col = mix(horizon_color, top_color, pow(h, sky_curve));
	if (dir.y < 0.0) {
		col = mix(horizon_color, ground_color, clamp(-dir.y * 3.0, 0.0, 1.0));
	}

	// drifting clouds (day) — dome projection of the view direction
	if (dir.y > 0.02 && cloud_amount > 0.001) {
		vec2 cp = dir.xz / dir.y;
		cp = cp * 0.5 + vec2(TIME * 0.006, TIME * 0.004);
		float c = fbm(cp);
		float cover = smoothstep(0.46, 0.85, c) * cloud_amount * smoothstep(0.02, 0.22, dir.y);
		// slight shading on cloud underside
		vec3 cc = mix(cloud_color * 0.7, cloud_color, smoothstep(0.5, 0.95, c));
		col = mix(col, cc, cover);
	}

	// stars (night)
	vec3 g = floor(dir * 260.0);
	float s = hash(g);
	float star = step(0.9965, s) * star_amount;
	star *= 0.6 + 0.4 * sin(TIME * 3.0 + s * 100.0);
	col += vec3(star) * smoothstep(0.02, 0.3, dir.y);

	// moon
	float md = distance(normalize(dir), normalize(moon_dir));
	float moon = smoothstep(moon_size, moon_size * 0.55, md);
	float moon_halo = smoothstep(moon_size * 6.0, moon_size, md) * 0.15;
	col = mix(col, vec3(0.93, 0.94, 1.0), moon * star_amount);
	col += vec3(0.4, 0.45, 0.6) * moon_halo * star_amount;

	// sun disk + glow from the first directional light
	if (LIGHT0_ENABLED) {
		float sd = dot(dir, LIGHT0_DIRECTION);
		float disk = smoothstep(0.9985, 0.9995, sd);
		float glow = pow(max(sd, 0.0), 8.0) * sun_glow;
		col += LIGHT0_COLOR * disk * 8.0;
		col += sun_glow_color * glow;
	}

	col += (hash(dir * 999.0) - 0.5) / 255.0;   // dither
	COLOR = col * sky_energy;
}
