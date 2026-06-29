// Full-screen VHS / PSX post-process.
// Apply to a ColorRect (full-rect anchors) on a CanvasLayer above the 3D scene.
// Drive `dread` (0..1) from gameplay to intensify grain, aberration, and desaturation.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

uniform float dread : hint_range(0.0, 1.0) = 0.0;
uniform float grain_amount : hint_range(0.0, 1.0) = 0.06;
uniform float aberration : hint_range(0.0, 0.01) = 0.0015;
uniform float scanline_amount : hint_range(0.0, 1.0) = 0.12;
uniform float vignette_amount : hint_range(0.0, 2.0) = 1.1;
uniform float color_levels : hint_range(2.0, 64.0) = 24.0; // PSX-ish color banding
uniform float time_seed = 0.0;

// cheap hash noise
float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float d = clamp(dread, 0.0, 1.0);

	// chromatic aberration grows with dread
	float ab = aberration * (1.0 + d * 4.0);
	vec2 dir = uv - vec2(0.5);
	float r = texture(screen_tex, uv - dir * ab).r;
	float g = texture(screen_tex, uv).g;
	float b = texture(screen_tex, uv + dir * ab).b;
	vec3 col = vec3(r, g, b);

	// PSX color banding / quantization
	float levels = max(2.0, color_levels - d * 8.0);
	col = floor(col * levels) / levels;

	// desaturate as dread rises (cosmic indifference)
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(luma), d * 0.5);

	// animated film grain
	float n = hash(uv * vec2(640.0, 480.0) + time_seed);
	col += (n - 0.5) * (grain_amount + d * 0.10);

	// scanlines
	float scan = sin(uv.y * 720.0) * 0.5 + 0.5;
	col *= 1.0 - scanline_amount * scan * 0.5;

	// vignette
	float vig = smoothstep(0.9, 0.2, length(dir) * vignette_amount);
	col *= mix(1.0, vig, 0.85);

	COLOR = vec4(col, 1.0);
}
