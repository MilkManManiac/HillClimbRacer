extends Node3D
## Endless forward-corridor heightfield for the Hill-Climb sandbox. Chunks stream in
## ahead of the car (forward = -Z) and free behind. Terrain amplitude/roughness grows
## with distance so the run escalates from gentle hills to mountainous big-air terrain.
## Each chunk has trimesh collision the raycast-wheel car drives on. Invisible side
## walls keep the car in the lateral band.

const CHUNK := 64.0       # chunk size (m)
const RES := 22           # grid cells per chunk side
const LAT := 3            # chunks each side of centerline -> band width = (2*LAT+1)*CHUNK
const AHEAD := 11         # chunks generated ahead (in -Z)
const BEHIND := 3         # chunks kept behind

@export var base_amp: float = 2.5     # gentle near the start
@export var max_amp: float = 34.0     # mountainous far out
@export var ramp_dist: float = 1600.0 # distance over which amplitude ramps up

var _noise := FastNoiseLite.new()
var _rough := FastNoiseLite.new()
var _chunks := {}          # Vector2i(cx,cz) -> MeshInstance3D
var _target: Node3D
var _wall_l: StaticBody3D
var _wall_r: StaticBody3D

func _ready() -> void:
	_noise.seed = 1234
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.frequency = 0.010
	_noise.fractal_octaves = 4
	_rough.seed = 99
	_rough.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_rough.frequency = 0.05
	_build_walls()

func set_target(t: Node3D) -> void:
	_target = t
	_update_chunks(true)

## World height at (x,z). Amplitude grows the further forward (-Z) you are.
func height_at(x: float, z: float) -> float:
	var d: float = maxf(0.0, -z)
	var amp: float = lerpf(base_amp, max_amp, clamp(d / ramp_dist, 0.0, 1.0))
	var n: float = _noise.get_noise_2d(x, z)            # -1..1, broad rolling hills
	var r: float = _rough.get_noise_2d(x, z) * 0.25     # finer chop, scaled in far out
	var rough_mix: float = clamp(d / ramp_dist, 0.0, 1.0)
	return (n + r * rough_mix) * amp

func _physics_process(_delta: float) -> void:
	if _target:
		_update_chunks(false)
		_follow_walls()

# --- streaming ---------------------------------------------------------------

func _update_chunks(initial: bool) -> void:
	var pz: int = int(floor(_target.global_position.z / CHUNK))
	var px: int = int(floor(_target.global_position.x / CHUNK))
	# desired chunk set: lateral band, from BEHIND (+Z) to AHEAD (-Z)
	var wanted := {}
	for cz in range(pz - AHEAD, pz + BEHIND + 1):
		for cx in range(px - LAT, px + LAT + 1):
			wanted[Vector2i(cx, cz)] = true
	# free chunks no longer wanted
	for key in _chunks.keys():
		if not wanted.has(key):
			_chunks[key].queue_free()
			_chunks.erase(key)
	# build a few new chunks per frame (all of them on the initial pass)
	var budget := 999 if initial else 3
	for key in wanted.keys():
		if budget <= 0:
			break
		if not _chunks.has(key):
			_chunks[key] = _build_chunk(key)
			budget -= 1

func _build_chunk(key: Vector2i) -> Node3D:
	var ox := float(key.x) * CHUNK
	var oz := float(key.y) * CHUNK
	var step := CHUNK / float(RES)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var heights := PackedFloat32Array()
	for iz in range(RES + 1):
		for ix in range(RES + 1):
			var x := ox + float(ix) * step
			var z := oz + float(iz) * step
			var y := height_at(x, z)
			heights.append(y)
			st.set_color(_color_for(y, z))
			st.set_uv(Vector2(float(ix) / RES, float(iz) / RES))
			st.add_vertex(Vector3(x, y, z))
	var row := RES + 1
	for iz in range(RES):
		for ix in range(RES):
			var i := iz * row + ix
			st.add_index(i)
			st.add_index(i + row)
			st.add_index(i + 1)
			st.add_index(i + 1)
			st.add_index(i + row)
			st.add_index(i + row + 1)
	st.generate_normals()
	var container := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _terrain_mat()
	container.add_child(mi)
	# solid heightmap collision (robust vs fast landings; trimesh tunnels)
	var hm := HeightMapShape3D.new()
	hm.map_width = RES + 1
	hm.map_depth = RES + 1
	hm.map_data = heights
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = hm
	cs.position = Vector3(ox + CHUNK * 0.5, 0.0, oz + CHUNK * 0.5)
	cs.scale = Vector3(step, 1.0, step)
	body.add_child(cs)
	container.add_child(body)
	add_child(container)
	return container

func _color_for(y: float, z: float) -> Color:
	# low-poly tint by height: green -> brown -> rock -> snow on the big stuff
	var d: float = maxf(0.0, -z)
	var amp: float = lerpf(base_amp, max_amp, clamp(d / ramp_dist, 0.0, 1.0))
	var t: float = clamp((y + amp * 0.3) / maxf(amp, 1.0), -1.0, 1.0)
	var grass := Color(0.30, 0.45, 0.22)
	var dirt := Color(0.40, 0.33, 0.22)
	var rock := Color(0.38, 0.37, 0.40)
	var snow := Color(0.92, 0.94, 0.98)
	var c: Color
	if t < 0.2:
		c = grass.lerp(dirt, clamp(t / 0.2, 0.0, 1.0))
	elif t < 0.55:
		c = dirt.lerp(rock, (t - 0.2) / 0.35)
	else:
		c = rock.lerp(snow, clamp((t - 0.55) / 0.35, 0.0, 1.0))
	return c

var _mat: StandardMaterial3D
func _terrain_mat() -> StandardMaterial3D:
	if _mat:
		return _mat
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 1.0
	_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return _mat

# --- lateral containment walls ----------------------------------------------

func _build_walls() -> void:
	var band := float(LAT) * CHUNK + CHUNK * 0.5
	_wall_l = _make_wall()
	_wall_r = _make_wall()
	_wall_l.position.x = -band
	_wall_r.position.x = band

func _make_wall() -> StaticBody3D:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 120.0, 6000.0)
	cs.shape = box
	body.add_child(cs)
	add_child(body)
	return body

func _follow_walls() -> void:
	var z := _target.global_position.z
	_wall_l.position.z = z
	_wall_r.position.z = z
	_wall_l.position.y = 40.0
	_wall_r.position.y = 40.0
