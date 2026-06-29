extends Node3D
## Owns the whole sky + lighting environment: a custom day/night sky shader, a sun and
## moon DirectionalLight, full Forward+ post (AgX tonemap, glow, SSAO, volumetric fog),
## and a time-of-day controller that drives sky colors, light, and fog together.
## Defaults to a golden-hour sunset and advances slowly so you see the cycle.

const SKY_SHADER := preload("res://shaders/sky.gdshader")

@export var time_of_day: float = 0.77      ## 0=midnight, 0.25=sunrise, 0.5=noon, 0.75=sunset
@export var auto_advance: bool = true
@export var day_length_sec: float = 480.0

# palette keyframes (midnight -> sunrise -> noon -> sunset -> midnight)
const KEYS := [
	{"t": 0.00, "top": Color(0.02, 0.03, 0.09), "hor": Color(0.05, 0.07, 0.16), "gnd": Color(0.02, 0.02, 0.05), "energy": 0.25},
	{"t": 0.23, "top": Color(0.14, 0.11, 0.32), "hor": Color(0.92, 0.46, 0.30), "gnd": Color(0.40, 0.25, 0.20), "energy": 0.65},
	{"t": 0.50, "top": Color(0.26, 0.50, 0.88), "hor": Color(0.72, 0.83, 0.96), "gnd": Color(0.50, 0.55, 0.58), "energy": 1.0},
	{"t": 0.77, "top": Color(0.22, 0.13, 0.42), "hor": Color(1.00, 0.50, 0.16), "gnd": Color(0.45, 0.28, 0.20), "energy": 0.9},
	{"t": 1.00, "top": Color(0.02, 0.03, 0.09), "hor": Color(0.05, 0.07, 0.16), "gnd": Color(0.02, 0.02, 0.05), "energy": 0.25},
]

var _env: Environment
var _sky_mat: ShaderMaterial
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D

func _ready() -> void:
	_build_environment()
	_build_lights()
	_apply(time_of_day)

func _process(delta: float) -> void:
	if auto_advance:
		time_of_day = fmod(time_of_day + delta / day_length_sec, 1.0)
		_apply(time_of_day)

# --- setup -------------------------------------------------------------------

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	_env = env

	# custom day/night sky drives ambient + reflections
	var sky := Sky.new()
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = SKY_SHADER
	sky.sky_material = _sky_mat
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 1.1
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# AgX tonemap for a filmic, non-blown-out look
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.set("tonemap_agx_white", 10.0)
	env.set("tonemap_agx_contrast", 1.35)

	# tasteful sunset bloom
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.glow_hdr_threshold = 1.0
	env.set("glow_normalized", true)

	# contact shadows / depth
	env.ssao_enabled = true
	env.ssao_radius = 1.5
	env.ssao_intensity = 2.0
	env.ssao_power = 1.5
	env.ssao_light_affect = 0.0

	# light atmospheric haze + god rays (volumetric) and aerial depth fog
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.022
	env.volumetric_fog_albedo = Color(0.9, 0.85, 0.8)
	env.set("volumetric_fog_anisotropy", 0.7)
	env.set("volumetric_fog_gi_inject", 1.0)
	env.set("volumetric_fog_length", 96.0)

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_density = 0.006
	env.fog_aerial_perspective = 0.4
	env.set("fog_sun_scatter", 0.3)
	env.fog_sky_affect = 0.5

	# gentle stylized grade
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	env.adjustment_saturation = 1.12
	env.adjustment_brightness = 1.0

	we.environment = env
	add_child(we)

func _build_lights() -> void:
	# sun FIRST so the sky shader's LIGHT0 = sun disk
	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.light_angular_distance = 1.8
	_sun.shadow_enabled = true
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun.directional_shadow_max_distance = 320.0
	_sun.set("directional_shadow_blend_splits", true)
	_sun.shadow_normal_bias = 1.5
	add_child(_sun)

	_moon = DirectionalLight3D.new()
	_moon.name = "Moon"
	_moon.light_color = Color(0.55, 0.65, 0.95)
	_moon.light_energy = 0.0
	_moon.shadow_enabled = false
	add_child(_moon)

# --- time of day -------------------------------------------------------------

func _sample(t: float) -> Dictionary:
	for i in KEYS.size() - 1:
		var a: Dictionary = KEYS[i]
		var b: Dictionary = KEYS[i + 1]
		if t >= a.t and t <= b.t:
			var f: float = inverse_lerp(a.t, b.t, t)
			return {
				"top": (a.top as Color).lerp(b.top, f),
				"hor": (a.hor as Color).lerp(b.hor, f),
				"gnd": (a.gnd as Color).lerp(b.gnd, f),
				"energy": lerp(a.energy, b.energy, f),
			}
	return KEYS[0]

func _apply(t: float) -> void:
	var p := _sample(t)
	var elev: float = -cos(TAU * t)         # -1 midnight, 0 sunrise/sunset, +1 noon
	var day: float = smoothstep(-0.05, 0.25, elev)
	var night: float = smoothstep(0.02, -0.18, elev)
	var warmth: float = 1.0 - smoothstep(0.05, 0.45, elev)

	# sky uniforms
	_sky_mat.set_shader_parameter("top_color", p.top)
	_sky_mat.set_shader_parameter("horizon_color", p.hor)
	_sky_mat.set_shader_parameter("ground_color", p.gnd)
	_sky_mat.set_shader_parameter("sky_energy", p.energy)
	_sky_mat.set_shader_parameter("sun_glow_color", Color(1.0, 0.55, 0.25))
	_sky_mat.set_shader_parameter("sun_glow", lerp(0.25, 0.8, warmth) * day)
	_sky_mat.set_shader_parameter("star_amount", night)

	# sun arc + warmth
	var e_angle: float = asin(clamp(elev, -1.0, 1.0))
	_sun.rotation = Vector3(-e_angle, deg_to_rad(-40.0), 0.0)
	_sun.visible = elev > -0.08
	_sun.light_energy = lerp(0.0, 2.6, day)
	_sun.light_color = Color(1.0, 0.97, 0.92).lerp(Color(1.0, 0.55, 0.28), warmth)

	# moon opposite the sun
	_moon.rotation = Vector3(e_angle, deg_to_rad(140.0), 0.0)
	_moon.visible = night > 0.01
	_moon.light_energy = 0.18 * night
	_sky_mat.set_shader_parameter("moon_dir", _moon.global_transform.basis.z)

	# fog tints with the horizon; warm scatter near sunset
	_env.fog_light_color = p.hor
	_env.set("fog_sun_scatter", lerp(0.2, 0.9, warmth * day))
	_env.volumetric_fog_albedo = (p.hor as Color).lerp(Color(0.9, 0.9, 0.95), 0.5)

	# never let ambient crush to pure black at night
	_env.ambient_light_energy = lerp(0.18, 1.15, day)
	_env.ambient_light_color = (p.top as Color)

func get_sun() -> DirectionalLight3D: return _sun
