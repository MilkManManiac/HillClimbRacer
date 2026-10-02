extends RefCounted
## The realistic look's shared kit: photo textures, the ground shader material, baked
## prop meshes and the sky/lighting rig. Everything is loaded from raw files at runtime
## (no editor import step, same policy as GlbUtil) and cached for the life of the
## process, so a restart or a map switch never re-reads a file.
##
## Headless runs (the test battery) get null textures and skip the sky: nothing here
## affects gameplay, and decoding ~60 MB of JPEGs per probe would only slow the tests.

const GROUND_SHADER := preload("res://shaders/hc_ground.gdshader")
const PBR_DIR := "res://assets/pbr/"
const BAKED_DIR := "res://assets/desert/baked/"
const DESERT_DIR := "res://assets/desert/"

## Per-look texture sets + tints. A map opts in with MAPS[key].look = one of these keys.
const LOOKS := {
	"desert": {
		"asphalt": "asphalt_track", "asphalt_res": "2k",
		"sand": "sandy_gravel_02", "sand_res": "2k",
		"dirt": "red_laterite_soil_stones", "dirt_res": "1k",
		"cliff": "cliff_side", "cliff_res": "2k",
		"asphalt_tint": Color(0.80, 0.79, 0.78),
		"sand_tint": Color(1.0, 0.86, 0.74),
		"cliff_tint": Color(1.0, 0.90, 0.82),
		"sky": "res://assets/sky/qwantani_late_afternoon_puresky_4k.hdr",
		# where the sun sits in that photo (measured once from the brightest pixels):
		# panorama u (0..1 across) and elevation above the horizon
		"sun_u": 0.6002, "sun_elev_deg": 19.1,
		"sun_color": Color(1.0, 0.90, 0.76), "sun_energy": 3.1,
		"sky_energy": 1.0, "ambient_energy": 1.0,
		"haze": Color(0.84, 0.76, 0.66),
	},
}

static var _tex := {}
static var _meshes := {}
static var _mats := {}
static var _noise_tex: ImageTexture
static var _sky_tex := {}

static func headless() -> bool:
	return DisplayServer.get_name() == "headless"

static func has_look(key: String) -> bool:
	return LOOKS.has(key)

## A raw image file as a mip-mapped texture (cached). `normal` renormalises the mip
## chain so a normal map doesn't flatten out with distance.
static func texture(path: String, normal := false) -> Texture2D:
	if _tex.has(path):
		return _tex[path]
	var out: Texture2D = null
	if not headless() and FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null and not img.is_empty():
			img.generate_mipmaps(normal)
			out = ImageTexture.create_from_image(img)
	_tex[path] = out
	return out

static func _pbr_path(set_name: String, map: String, res: String) -> String:
	return "%s%s_%s_%s.jpg" % [PBR_DIR, set_name, map, res]

## Tileable grey noise the ground shader uses for every kind of large-scale variation
## (blotches, strata bends, worn paint). Generated once; 256 px is plenty because it is
## only ever sampled stretched over metres.
static func noise_texture() -> Texture2D:
	if _noise_tex != null or headless():
		return _noise_tex
	var n := FastNoiseLite.new()
	n.seed = 9041
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 4
	n.frequency = 0.018
	var img := n.get_seamless_image(256, 256)
	img.generate_mipmaps()
	_noise_tex = ImageTexture.create_from_image(img)
	return _noise_tex

## The ground shader material for a look. `road` = the track ribbon (asphalt + paint
## layers on); false = open land. One material per (look, road) pair, shared by every
## tile and chunk.
static func ground_material(look: String, road: bool) -> ShaderMaterial:
	var key := "%s|%s" % [look, "road" if road else "land"]
	if _mats.has(key):
		return _mats[key]
	var cfg: Dictionary = LOOKS.get(look, LOOKS["desert"])
	var m := ShaderMaterial.new()
	m.shader = GROUND_SHADER
	m.set_shader_parameter("is_road", 1.0 if road else 0.0)
	for layer in ["asphalt", "sand", "cliff"]:
		var res: String = cfg[layer + "_res"]
		m.set_shader_parameter(layer + "_albedo", texture(_pbr_path(cfg[layer], "diff", res)))
		m.set_shader_parameter(layer + "_normal", texture(_pbr_path(cfg[layer], "nor_gl", res), true))
		m.set_shader_parameter(layer + "_orm", texture(_pbr_path(cfg[layer], "arm", res)))
	m.set_shader_parameter("dirt_albedo", texture(_pbr_path(cfg.dirt, "diff", cfg.dirt_res)))
	m.set_shader_parameter("dirt_normal", texture(_pbr_path(cfg.dirt, "nor_gl", cfg.dirt_res), true))
	m.set_shader_parameter("noise_tex", noise_texture())
	m.set_shader_parameter("asphalt_tint", cfg.asphalt_tint)
	m.set_shader_parameter("sand_tint", cfg.sand_tint)
	m.set_shader_parameter("cliff_tint", cfg.cliff_tint)
	_mats[key] = m
	return m

## A second land material for the coarse far ring: same shader, but with the cut-out
## rectangle uniform live (the fine near-land covers that square).
static func far_land_material(look: String) -> ShaderMaterial:
	var key := "%s|far" % look
	if _mats.has(key):
		return _mats[key]
	var m: ShaderMaterial = ground_material(look, false).duplicate()
	_mats[key] = m
	return m

## A baked prop mesh (tools/BakeProps.gd output) with its scanned PBR material attached.
## `src` is the Poly Haven folder its textures live in. Null if the file is missing.
static func prop_mesh(baked: String, src: String, alpha_cutout := false) -> Mesh:
	var key := "prop|" + baked
	if _meshes.has(key):
		return _meshes[key]
	var path := BAKED_DIR + baked + ".res"
	var mesh: Mesh = null
	if ResourceLoader.exists(path):
		mesh = load(path) as Mesh
	if mesh != null:
		mesh.surface_set_material(0, _scan_material(src, alpha_cutout))
	_meshes[key] = mesh
	return mesh

static func _scan_material(src: String, alpha_cutout: bool) -> StandardMaterial3D:
	var key := "scan|" + src
	if _mats.has(key):
		return _mats[key]
	var base := "%s%s/textures/%s_" % [DESERT_DIR, src, src]
	var m := StandardMaterial3D.new()
	m.albedo_texture = texture(base + "diff_1k.jpg")
	m.normal_enabled = true
	m.normal_texture = texture(base + "nor_gl_1k.jpg", true)
	# Poly Haven packs occlusion / roughness / metal into one image's R / G / B
	var arm := texture(base + "arm_1k.jpg")
	m.ao_enabled = true
	m.ao_texture = arm
	m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	m.roughness_texture = arm
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	m.roughness = 1.0
	m.metallic = 0.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if src.contains("boulder") or src.contains("cliff"):
		m.albedo_color = Color(1.0, 0.80, 0.66)    # grey scan rock -> this canyon's sandstone
	elif src.contains("bush"):
		m.albedo_color = Color(1.7, 1.55, 1.25)    # the scan is near-black; sun-bleached scrub is not
	if alpha_cutout:
		# foliage cards: hard cut-out (sorts and shadows correctly, unlike blending)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.4
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mats[key] = m
	return m

## Unit vector pointing AT the sun for a look (Godot's panorama puts u = 0.5 at -Z).
static func sun_dir(look: String) -> Vector3:
	var cfg: Dictionary = LOOKS.get(look, LOOKS["desert"])
	var az: float = (float(cfg.sun_u) - 0.5) * TAU
	var el: float = deg_to_rad(float(cfg.sun_elev_deg))
	return Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))

## Swap the photographed sky in and light the scene from it. `env`/`sun` are the
## WorldEnvironment's Environment and the key DirectionalLight (owned by Sky.gd; only
## retuned here). Returns false in headless runs, where there is nothing to draw.
static func apply_sky(look: String, env: Environment, sun: DirectionalLight3D) -> bool:
	if env == null or headless():
		return false
	var cfg: Dictionary = LOOKS.get(look, LOOKS["desert"])
	var path: String = cfg.sky
	if not _sky_tex.has(path):
		var img: Image = null
		if FileAccess.file_exists(path):
			img = Image.load_from_file(path)
		_sky_tex[path] = ImageTexture.create_from_image(img) if img != null and not img.is_empty() else null
	var tex: Texture2D = _sky_tex[path]
	if tex == null:
		return false
	var pano := PanoramaSkyMaterial.new()
	pano.panorama = tex
	pano.filter = true
	pano.energy_multiplier = float(cfg.sky_energy)
	var sky := Sky.new()
	sky.sky_material = pano
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_QUALITY   # static sky: filter it once, properly
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.sky_rotation = Vector3.ZERO
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = float(cfg.ambient_energy)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# photographic response instead of the arcade maps' punchy grade
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.06
	env.adjustment_contrast = 1.04
	env.adjustment_brightness = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 2.2
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.ssao_enabled = true
	env.ssao_radius = 1.6
	env.ssao_intensity = 2.2
	env.ssao_power = 1.4
	env.ssil_enabled = false
	env.sdfgi_enabled = false
	env.ssr_enabled = false
	env.volumetric_fog_enabled = false

	# haze: thin exponential fog tinted by the photo's own horizon, thicker low down
	# where the dust hangs, so far canyon walls fade the way real distance does
	var haze: Color = cfg.haze
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = haze
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.12
	env.fog_density = 0.00042
	env.fog_aerial_perspective = 0.5
	env.fog_sky_affect = 0.0
	env.fog_height_density = 0.0

	if sun != null:
		sun.visible = true
		sun.look_at_from_position(Vector3.ZERO, -sun_dir(look), Vector3.UP)
		sun.light_color = cfg.sun_color
		sun.light_energy = float(cfg.sun_energy)
		sun.light_angular_distance = 0.6   # soft penumbra that widens with distance
		sun.shadow_enabled = true
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun.directional_shadow_max_distance = 260.0
		sun.directional_shadow_blend_splits = true
		sun.shadow_bias = 0.04
		sun.shadow_normal_bias = 1.2
		sun.shadow_blur = 1.0
		# the default filter draws a soft sun shadow as a visible dot pattern
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
		RenderingServer.directional_shadow_atlas_set_size(8192, true)
	return true
