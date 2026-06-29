extends Node3D
## Procedural surrounding terrain: a ring of rolling snowy hills just past the forest,
## and a dramatic ridged mountain range far beyond, ringing the flat drivable play area.
## Both are static polar-ring meshes (SurfaceTool + FastNoiseLite) using the snow shader.
## The play center stays perfectly flat — terrain only exists outside `flat_radius`.

const SNOW_SHADER := preload("res://shaders/terrain_snow.gdshader")

@export var center := Vector3(0, 0, 0)       ## course is centered on origin
@export var flat_radius: float = 380.0       ## no terrain inside this radius

func _ready() -> void:
	# the road course now carries the near hills; keep only the distant mountain ring
	_build_mountains()

# --- rolling hills (near ring) -----------------------------------------------

func _build_hills() -> void:
	var n := FastNoiseLite.new()
	n.seed = 3201
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.frequency = 0.006
	n.fractal_octaves = 4
	var mesh := _build_ring(flat_radius, 1150.0, 38, 168, n, 34.0, 0.0, true)
	var mi := MeshInstance3D.new()
	mi.name = "Hills"
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = SNOW_SHADER
	mat.set_shader_parameter("snow_height", 1.5)
	mat.set_shader_parameter("snow_blend", 10.0)
	mat.set_shader_parameter("low_color", Color(0.62, 0.66, 0.70))
	mat.set_shader_parameter("rock_color", Color(0.26, 0.27, 0.28))
	mat.set_shader_parameter("snow_slope_limit", 0.45)
	mi.material_override = mat
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)

# --- mountains (far ring) ----------------------------------------------------

func _build_mountains() -> void:
	var n := FastNoiseLite.new()
	n.seed = 7788
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	n.frequency = 0.0016
	n.fractal_octaves = 5
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5
	n.domain_warp_enabled = true
	n.domain_warp_amplitude = 60.0
	n.domain_warp_frequency = 0.004
	var mesh := _build_ring(950.0, 2500.0, 46, 150, n, 460.0, -40.0, false)
	var mi := MeshInstance3D.new()
	mi.name = "Mountains"
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = SNOW_SHADER
	mat.set_shader_parameter("snow_height", 130.0)
	mat.set_shader_parameter("snow_blend", 90.0)
	mat.set_shader_parameter("low_color", Color(0.30, 0.33, 0.34))
	mat.set_shader_parameter("rock_color", Color(0.22, 0.21, 0.23))
	mat.set_shader_parameter("snow_slope_limit", 0.40)
	mat.set_shader_parameter("noise_scale", 0.01)
	mi.material_override = mat
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)

# --- generic polar ring mesh -------------------------------------------------
# Builds an annulus from inner..outer radius around center. Height = noise * height
# * radial_profile, where the profile is 0 at both edges (so it meets the flat ground
# / fades into the sky) and peaks in the band middle.

func _build_ring(inner: float, outer: float, r_steps: int, a_steps: int,
		n: FastNoiseLite, height: float, base_y: float, hills: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var row := a_steps + 1
	for ri in range(r_steps + 1):
		var rt := float(ri) / float(r_steps)               # 0 inner .. 1 outer
		var radius: float = lerp(inner, outer, rt)
		var profile: float
		if hills:
			# rise from the flat ground, stay up, gently fall toward the far edge
			profile = smoothstep(0.0, 0.18, rt) * (1.0 - smoothstep(0.7, 1.0, rt) * 0.35)
		else:
			profile = sin(rt * PI)                          # peak in the middle of the band
			profile = pow(profile, 0.7)
		for ai in range(a_steps + 1):
			var ang := float(ai) / float(a_steps) * TAU
			var px: float = center.x + cos(ang) * radius
			var pz: float = center.z + sin(ang) * radius
			var hn: float = (n.get_noise_2d(px, pz) + 1.0) * 0.5  # 0..1
			if not hills:
				hn = pow(hn, 1.5)                            # sharpen ridges
			var y := base_y + hn * height * profile
			st.set_uv(Vector2(rt, float(ai) / float(a_steps)))
			st.add_vertex(Vector3(px, y, pz))
	for ri in range(r_steps):
		for ai in range(a_steps):
			var i := ri * row + ai
			st.add_index(i)
			st.add_index(i + row)
			st.add_index(i + 1)
			st.add_index(i + 1)
			st.add_index(i + row)
			st.add_index(i + row + 1)
	st.generate_normals()
	return st.commit()
