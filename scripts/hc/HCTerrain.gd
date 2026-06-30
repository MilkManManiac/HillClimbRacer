extends Node3D
## Endless forward-corridor terrain for the Hill-Climb sandbox. A ROAD runs down the
## center (x≈0): it rolls up and down over hills (amplitude grows with distance), while
## the ground to the sides flattens out — hills are only on the road. Guardrail barriers
## line the road edges (collision) so you can't drive off; jump them and land off-road
## and you crash. Chunks stream in ahead and free behind; solid HeightMapShape3D collision.

const CHUNK := 64.0
const RES := 48           # grid cells per chunk side (higher = smoother, no facet snags)
const LAT := 3
const AHEAD := 11
const BEHIND := 3

@export var base_amp: float = 3.0
@export var max_amp: float = 48.0
@export var ramp_dist: float = 500.0
@export var road_half_width: float = 14.0   # drivable road half-width
@export var edge_falloff: float = 16.0       # how fast hills fade to flat off the road
@export var side_amp: float = 0.10           # leftover hilliness on the flat sides
@export var rail_height: float = 1.6

var _noise := FastNoiseLite.new()
var _chunks := {}
var _target: Node3D
var _barriers: Array[Node3D] = []
var _last_barrier_cz := 999999

func _ready() -> void:
	_noise.seed = 1234
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.frequency = 0.008
	_noise.fractal_octaves = 2

func set_target(t: Node3D) -> void:
	_target = t
	_update_chunks(true)

## Height: rolling hills on the road (center), flattening to the sides.
func height_at(x: float, z: float) -> float:
	var d: float = maxf(0.0, -z)
	var amp: float = lerpf(base_amp, max_amp, clamp(d / ramp_dist, 0.0, 1.0))
	var prof: float = _noise.get_noise_1d(z)
	var edge: float = smoothstep(road_half_width, road_half_width + edge_falloff, absf(x))
	var amp_here: float = lerpf(amp, amp * side_amp, edge)
	return prof * amp_here

func _physics_process(_delta: float) -> void:
	if _target:
		_update_chunks(false)

# --- streaming ---------------------------------------------------------------

func _update_chunks(initial: bool) -> void:
	var pz: int = int(floor(_target.global_position.z / CHUNK))
	var px: int = int(floor(_target.global_position.x / CHUNK))
	var wanted := {}
	for cz in range(pz - AHEAD, pz + BEHIND + 1):
		for cx in range(px - LAT, px + LAT + 1):
			wanted[Vector2i(cx, cz)] = true
	for key in _chunks.keys():
		if not wanted.has(key):
			_chunks[key].queue_free()
			_chunks.erase(key)
	var budget := 999 if initial else 3
	for key in wanted.keys():
		if budget <= 0:
			break
		if not _chunks.has(key):
			_chunks[key] = _build_chunk(key)
			budget -= 1
	if initial or pz != _last_barrier_cz:
		_last_barrier_cz = pz
		_rebuild_barriers(pz)

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
			st.set_color(_color_for(x, y))
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

func _color_for(x: float, _y: float) -> Color:
	var ax := absf(x)
	var asphalt := Color(0.16, 0.16, 0.18)
	var grass := Color(0.28, 0.44, 0.20)
	if ax < 0.45:
		return Color(0.82, 0.70, 0.20)   # center line
	var edge := smoothstep(road_half_width - 2.0, road_half_width + 2.0, ax)
	return asphalt.lerp(grass, edge)

var _mat: StandardMaterial3D
func _terrain_mat() -> StandardMaterial3D:
	if _mat:
		return _mat
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	_mat.roughness = 1.0
	_mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _mat

# --- guardrail barriers (follow the road edge height, stream with the player) -

func _rebuild_barriers(pz: int) -> void:
	for b in _barriers:
		b.queue_free()
	_barriers.clear()
	var z0 := float(pz - AHEAD) * CHUNK
	var z1 := float(pz + BEHIND + 1) * CHUNK
	_barriers.append(_build_rail(-road_half_width, z0, z1))
	_barriers.append(_build_rail(road_half_width, z0, z1))

func _build_rail(xpos: float, z0: float, z1: float) -> Node3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := 4.0
	var rings := 0
	var z := z0
	while z <= z1:
		var ey := height_at(xpos, z)
		st.set_color(Color(0.75, 0.75, 0.8))
		st.add_vertex(Vector3(xpos, ey - 0.3, z))
		st.set_color(Color(0.9, 0.3, 0.25))
		st.add_vertex(Vector3(xpos, ey + rail_height, z))
		rings += 1
		z += step
	for r in range(rings - 1):
		var a := r * 2
		var b := r * 2 + 1
		var c := (r + 1) * 2
		var dd := (r + 1) * 2 + 1
		st.add_index(a); st.add_index(c); st.add_index(b)
		st.add_index(b); st.add_index(c); st.add_index(dd)
	st.generate_normals()
	var container := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	container.add_child(mi)
	mi.create_trimesh_collision()
	add_child(container)
	return container
