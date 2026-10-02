shader_type canvas_item;

// Sense of speed for the realistic maps: the frame smears outward from the point the
// car is heading for, a little at the centre of the picture and more toward the edges —
// what a camera does at speed — instead of the arcade maps' drawn streaks. A faint
// vignette rides along at all times.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform float strength = 0.0;      // 0 = off, ~0.06 = flat out
uniform float vignette = 0.22;

void fragment() {
	vec2 centre = vec2(0.5, 0.46);
	vec2 d = SCREEN_UV - centre;
	float r = length(d * vec2(1.0, 1.25));
	float amt = strength * smoothstep(0.16, 0.8, r);
	vec3 acc = vec3(0.0);
	const int N = 9;
	for (int i = 0; i < N; i++) {
		float t = float(i) / float(N - 1);
		acc += texture(screen_tex, SCREEN_UV - d * amt * t).rgb;
	}
	acc /= float(N);
	acc *= 1.0 - vignette * smoothstep(0.45, 1.0, r);
	COLOR = vec4(acc, 1.0);
}
