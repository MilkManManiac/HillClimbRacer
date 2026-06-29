// Day/night sky (Godot 4.6 sky shader). Authored gradient (day -> sunset -> night),
// a sun disk + glow that follows the scene's first DirectionalLight, a moon disk, and
// procedural twinkling stars that fade in at night. Drive the uniforms from Sky.gd.
shader_type sky;

uniform vec3 top_color : source_color = vec3(0.25, 0.12, 0.40);
uniform vec3 horizon_color : source_color = vec3(1.0, 0.50, 0.15);
uniform vec3 ground_color : source_color = vec3(0.35, 0.22, 0.18);
uniform float sky_energy = 1.0;
uniform float sky_curve = 0.28;

uniform vec3 sun_glow_color : source_color = vec3(1.0, 0.55, 0.25);
uniform float sun_glow = 0.6;

uniform vec3 moon_dir = vec3(0.3, 0.5, -0.8);
uniform float moon_size = 0.035;
uniform float star_amount = 0.0;     // 0 day .. 1 night

float hash(vec3 p){ p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }

void sky() {
	vec3 dir = EYEDIR;
	float h = clamp(dir.y, 0.0, 1.0);
	vec3 col = mix(horizon_color, top_color, pow(h, sky_curve));

	// below the horizon -> ground haze color
	if (dir.y < 0.0) {
		col = mix(horizon_color, ground_color, clamp(-dir.y * 3.0, 0.0, 1.0));
	}

	// stars (above horizon, night only)
	vec3 g = floor(dir * 260.0);
	float s = hash(g);
	float star = step(0.9965, s) * star_amount;
	star *= 0.6 + 0.4 * sin(TIME * 3.0 + s * 100.0);
	col += vec3(star) * smoothstep(0.02, 0.3, dir.y);

	// moon disk + soft halo
	float md = distance(normalize(dir), normalize(moon_dir));
	float moon = smoothstep(moon_size, moon_size * 0.55, md);
	float moon_halo = smoothstep(moon_size * 6.0, moon_size, md) * 0.15;
	col = mix(col, vec3(0.93, 0.94, 1.0), moon * star_amount);
	col += vec3(0.4, 0.45, 0.6) * moon_halo * star_amount;

	// sun disk + glow following the first directional light
	if (LIGHT0_ENABLED) {
		float sd = dot(dir, LIGHT0_DIRECTION);
		float disk = smoothstep(0.9985, 0.9995, sd);
		float glow = pow(max(sd, 0.0), 8.0) * sun_glow;
		col += LIGHT0_COLOR * disk * 8.0;
		col += sun_glow_color * glow;
	}

	// dither to kill gradient banding
	col += (hash(dir * 999.0) - 0.5) / 255.0;
	COLOR = col * sky_energy;
}
