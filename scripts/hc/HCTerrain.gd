extends Node3D
## Endless forward-corridor terrain for the Hill-Climb sandbox. A ROAD runs down the
## center (x≈0): it rolls up and down over hills (amplitude grows with distance), while
## the ground to the sides flattens out — hills are only on the road. Guardrail barriers
## line the road edges (collision) so you can't drive off; jump them and land off-road
## and you crash. Chunks stream in ahead and free behind; solid HeightMapShape3D collision.

const CHUNK := 64.0
const RES := 40           # grid cells per chunk side (higher = smoother, no facet snags)
const LAT := 2            # lateral chunks each side (road is narrow, don't need many)
const AHEAD := 8          # chunks streamed ahead (fog hides further; fewer = lighter)
const BEHIND := 2

@export var base_amp: float = 3.0
@export var max_amp: float = 20.0            # gentler peaks so slopes stay shallow (long jumps)
@export var ramp_dist: float = 450.0
@export var road_half_width: float = 28.0    # road twice as wide
@export var edge_falloff: float = 18.0       # how fast hills fade to flat off the road
@export var side_amp: float = 0.10           # leftover hilliness on the flat sides
@export var rail_height: float = 1.6

# --- gap / checkpoint schedule (jump the hole or fall in) --------------------
@export var gap_start_dist: float = 360.0    # pure hills before this; first gap here
@export var gap_spacing: float = 340.0       # distance to the SECOND gap (base spacing)
@export var gap_spacing_grow: float = 110.0  # +distance to each next gap (pits get rarer the further you go)
@export var gap_base_width: float = 34.0     # void width at the first gap
@export var gap_grow: float = 8.0            # +void width per gap index (harder to clear over distance)
@export var gap_max_width: float = 120.0
@export var ramp_len: float = 26.0           # launch-ramp run-up length (telegraph)
@export var ramp_rise: float = 8.0           # how high the lip kicks the nose
@export var land_len: float = 36.0           # flat landing platform past the void
@export var pit_floor: float = -45.0         # void floor (deep = unrecoverable)

var _noise := FastNoiseLite.new()
var _chunks := {}
var _target: Node3D
var _barriers: Array[Node3D] = []
var _last_barrier_cz := 999999
# threaded streaming: heavy mesh build runs on worker threads; finished chunks are
# inserted on the main thread a few per frame so high-speed travel never hitches.
var _pending := {}            # keys with a build task in flight
var _done: Array = []         # built chunk data awaiting main-thread insertion
var _done_mutex := Mutex.new()

func _ready() -> void:
	_noise = _new_noise()   # single source of truth (workers use the same config)

func set_target(t: Node3D) -> void:
	_target = t
	_update_chunks(true)

# A worker thread must NOT share the main thread's _noise (FastNoiseLite isn't
# safe for concurrent reads -> "Bad address index"). Each build task makes its own.
func _new_noise() -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = 1234
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.frequency = 0.0026   # long-wavelength = gradual slopes for long flowing jumps
	n.fractal_octaves = 2
	n.fractal_gain = 0.4   # less high-frequency detail = smoother crests
	return n

## Rolling-hills base height (road center high, sides flat). No gaps.
## `noise` lets worker threads pass their own instance; main-thread callers omit it.
func _terrain_height(x: float, z: float, noise: FastNoiseLite = null) -> float:
	if noise == null:
		noise = _noise
	var d: float = maxf(0.0, -z)
	var amp: float = lerpf(base_amp, max_amp, clamp(d / ramp_dist, 0.0, 1.0))
	var prof: float = noise.get_noise_1d(z)
	var edge: float = smoothstep(road_half_width, road_half_width + edge_falloff, absf(x))
	var amp_here: float = lerpf(amp, amp * side_amp, edge)
	return prof * amp_here

## The gap nearest z (or {} if none yet). Deterministic from z, so every chunk
## and the collision shape carve identically with no streaming state. center_z is
## NEGATIVE (forward). Approaching from large z you hit: ramp_z0 -> lip_z -> void
## -> far_z -> land_z1.
func _gap_for_z(z: float, noise: FastNoiseLite = null) -> Dictionary:
	var d: float = -z
	if d < gap_start_dist - gap_spacing * 0.5:
		return {}
	# Progressive schedule: the gap-to-gap spacing widens by gap_spacing_grow each
	# index, so pits get RARER the further you travel. That makes
	#   center_d(i) = start + base*i + grow*i*(i-1)/2   (quadratic in i).
	# Invert that quadratic to find the nearest gap index for this z, then round so
	# a gap's ramp (nearer) and landing (farther) resolve to the SAME index.
	var rel: float = d - gap_start_dist
	var idx: int
	var a: float = gap_spacing_grow * 0.5
	if a > 0.0001:
		var b: float = gap_spacing - a
		var disc: float = b * b + 4.0 * a * rel
		idx = int(round((-b + sqrt(maxf(disc, 0.0))) / (2.0 * a)))
	else:
		idx = int(round(rel / gap_spacing))
	if idx < 0:
		return {}
	var center_d: float = gap_start_dist + gap_spacing * float(idx) + gap_spacing_grow * float(idx) * float(idx - 1) * 0.5
	var void_w: float = minf(gap_base_width + float(idx) * gap_grow, gap_max_width)
	var center_z: float = -center_d
	var lip_z: float = center_z + void_w * 0.5
	var far_z: float = center_z - void_w * 0.5
	var ramp0: float = lip_z + ramp_len
	# one shared "table" height for the whole gap so takeoff and landing match
	# (no impossible taller-on-one-side peak). Sampled from the natural hills at
	# the approach so it blends in smoothly.
	var level: float = _terrain_height(0.0, ramp0, noise)
	return {
		"idx": idx,
		"void_w": void_w,
		"center_z": center_z,
		"lip_z": lip_z,
		"far_z": far_z,
		"ramp_z0": ramp0,
		"land_z1": far_z - land_len,
		"level": level,
	}

## Final height: rolling hills, with gaps carved over the road (ramp -> void ->
## flat landing platform). Sides stay as normal ground so it reads as a bridge-out.
func height_at(x: float, z: float, noise: FastNoiseLite = null) -> float:
	var base: float = _terrain_height(x, z, noise)
	var g := _gap_for_z(z, noise)
	if g.is_empty():
		return base
	var on_road: float = 1.0 - smoothstep(road_half_width, road_half_width + edge_falloff, absf(x))
	if on_road < 0.01:
		return base
	var gy: float = base
	var lip_z: float = g.lip_z
	var far_z: float = g.far_z
	var ramp0: float = g.ramp_z0
	var land1: float = g.land_z1
	var lvl: float = g.level
	var blend := 16.0
	if z > ramp0 and z <= ramp0 + blend:
		# ease the natural hills up to the flat table level on approach
		var f: float = (ramp0 + blend - z) / blend          # 0 -> 1 toward the ramp
		gy = lerpf(base, lvl, smoothstep(0.0, 1.0, f))
	elif z <= ramp0 and z > lip_z:
		# launch ramp: rises ramp_rise ABOVE the table level (kick), then a clean lip
		var t: float = (ramp0 - z) / ramp_len               # 0 at ramp start, 1 at lip
		gy = lvl + smoothstep(0.0, 1.0, t) * ramp_rise
	elif z <= lip_z and z >= far_z:
		gy = pit_floor                                      # the void
	elif z < far_z and z >= land1:
		gy = lvl                                            # landing == takeoff height
	elif z < land1 and z >= land1 - blend:
		# ease the landing platform back down to the natural hills
		var f2: float = (z - (land1 - blend)) / blend       # 1 at platform -> 0 below
		gy = lerpf(base, lvl, smoothstep(0.0, 1.0, f2))
	return lerpf(base, gy, on_road)

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
	for key in wanted.keys():
		if _chunks.has(key) or _pending.has(key):
			continue
		_pending[key] = true
		if initial:
			_insert_chunk(_gen_chunk_data(key))   # block on first load so the world is there
		else:
			WorkerThreadPool.add_task(_gen_task.bind(key))
	_drain_done(initial)
	if initial or pz != _last_barrier_cz:
		_last_barrier_cz = pz
		_rebuild_barriers(pz)

## Runs on a worker thread: builds the mesh + heights (the expensive part) off the
## main thread, then queues the result for insertion.
func _gen_task(key: Vector2i) -> void:
	var data := _gen_chunk_data(key)
	_done_mutex.lock()
	_done.append(data)
	_done_mutex.unlock()

## Insert a few finished chunks per frame on the main thread (node creation only).
func _drain_done(initial: bool) -> void:
	var batch: Array = []
	_done_mutex.lock()
	var lim: int = _done.size() if initial else 3
	while _done.size() > 0 and batch.size() < lim:
		batch.append(_done.pop_front())
	_done_mutex.unlock()
	for d in batch:
		_insert_chunk(d)

## Thread-safe heavy build: SurfaceTool mesh + collision heightmap. No scene-tree access.
func _gen_chunk_data(key: Vector2i) -> Dictionary:
	var noise := _new_noise()   # thread-local noise so concurrent tasks never share _noise
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
			var y := height_at(x, z, noise)
			heights.append(y)
			st.set_color(_color_for(x, y, z, noise))
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
	var hm := HeightMapShape3D.new()
	hm.map_width = RES + 1
	hm.map_depth = RES + 1
	hm.map_data = heights
	var props := _gen_props(ox, oz, noise)
	return {"key": key, "mesh": st.commit(), "shape": hm, "ox": ox, "oz": oz, "step": step, "props": props}

# --- roadside props (placement only; pure math, runs on worker thread) ---------
# Prop types: 0 = conifer tree, 1 = rock, 2 = sign/post.
const PROP_TREE := 0
const PROP_ROCK := 1
const PROP_SIGN := 2
const PROP_MARGIN := 8.0     # clearance off the asphalt before anything spawns
const PROP_SPREAD := 24.0    # how far out from the margin props may sit
const PROP_ZSTEP := 7.0      # candidate slot spacing down the corridor

# Per-biome [fill density 0..1, tree weight, rock weight, sign weight].
const PROP_BIOME := [
	[0.80, 0.78, 0.16, 0.06],   # meadow: lush, mostly trees
	[0.45, 0.18, 0.74, 0.08],   # desert: sparse, rocks
	[0.40, 0.40, 0.52, 0.08],   # snow: sparse evergreens + rocks
	[0.55, 0.10, 0.84, 0.06],   # volcanic: jagged rocks
]

func _biome_index(z: float) -> int:
	var d: float = maxf(0.0, -z)
	return int(floor(d / BIOME_LEN)) % BIOMES.size()

## Deterministic scatter for one chunk. Returns Array of {pos, type, scale, rot}.
func _gen_props(ox: float, oz: float, noise: FastNoiseLite) -> Array:
	var out: Array = []
	var slots: int = int(CHUNK / PROP_ZSTEP)
	for s in range(slots):
		var z: float = oz + (float(s) + 0.5) * PROP_ZSTEP
		var bi: int = _biome_index(z)
		var cfg: Array = PROP_BIOME[bi]
		var density: float = cfg[0]
		for side in [-1.0, 1.0]:
			# one decision sample per (slot, side); >0.5-ish space stays empty
			var pick: float = noise.get_noise_2d((ox + side * 500.0) * 3.1 + float(s) * 13.0, z * 3.1)
			pick = pick * 0.5 + 0.5   # -> 0..1
			if pick > density:
				continue
			# lateral distance out from the verge, jittered by a second sample
			var jx: float = noise.get_noise_2d(z * 7.0, side * 91.0) * 0.5 + 0.5
			var x: float = side * (road_half_width + PROP_MARGIN + jx * PROP_SPREAD)
			# only emit props whose x lands in THIS chunk's lateral span, so the
			# several lateral chunks streamed each frame don't all spawn duplicates.
			if x < ox or x >= ox + CHUNK:
				continue
			# don't let anything sit on the leftover side-hills right at the verge dip
			var y: float = height_at(x, z, noise)
			if y < pit_floor + 5.0:
				continue   # over a void, skip
			# type from a third sample weighted by biome
			var ts: float = noise.get_noise_2d(x * 5.0, z * 5.0 + 37.0) * 0.5 + 0.5
			var tw: float = cfg[1] + cfg[2] + cfg[3]
			var typ: int = PROP_TREE
			if ts < cfg[1] / tw:
				typ = PROP_TREE
			elif ts < (cfg[1] + cfg[2]) / tw:
				typ = PROP_ROCK
			else:
				typ = PROP_SIGN
			var sc: float = 0.7 + (noise.get_noise_2d(x * 2.3, z * 2.3) * 0.5 + 0.5) * 0.8
			var rot: float = (noise.get_noise_2d(x * 1.7 + 5.0, z * 1.7) * 0.5 + 0.5) * TAU
			out.append({"pos": Vector3(x, y, z), "type": typ, "scale": sc, "rot": rot})
	return out

## Main-thread: turn built data into nodes and add to the tree.
func _insert_chunk(d: Dictionary) -> void:
	var key: Vector2i = d.key
	_pending.erase(key)
	if _chunks.has(key):
		return
	var ox: float = d.ox
	var oz: float = d.oz
	var step: float = d.step
	var container := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = d.mesh
	mi.material_override = _terrain_mat()
	container.add_child(mi)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = d.shape
	cs.position = Vector3(ox + CHUNK * 0.5, 0.0, oz + CHUNK * 0.5)
	cs.scale = Vector3(step, 1.0, step)
	body.add_child(cs)
	container.add_child(body)
	_insert_props(container, d.get("props", []))
	add_child(container)
	_chunks[key] = container

# --- prop meshes + insertion (main thread only) ------------------------------
# Each prop is a single Mesh with one SURFACE per primitive part, every surface
# carrying its own flat StandardMaterial3D (trunk brown, canopy green, ...). The
# MultiMeshInstance3D leaves material_override unset so those per-surface colors show.

var _prop_meshes := {}   # type -> Mesh, built once and shared by every chunk's MultiMesh
func _prop_mesh(typ: int) -> Mesh:
	if _prop_meshes.has(typ):
		return _prop_meshes[typ]
	var m: Mesh
	match typ:
		PROP_ROCK:
			m = _make_rock_mesh()
		PROP_SIGN:
			m = _make_sign_mesh()
		_:
			m = _make_tree_mesh()
	_prop_meshes[typ] = m
	return m

func _flat_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.9
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return m

# Append `prim` (transformed) as a fresh surface on `mesh` with its own color.
func _add_part(mesh: ArrayMesh, prim: Mesh, xform: Transform3D, col: Color) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(prim, 0, xform)   # copies the primitive's verts/normals/uvs
	st.set_material(_flat_mat(col))
	st.commit(mesh)                  # adds one surface to the shared mesh

func _make_tree_mesh() -> Mesh:
	var mesh := ArrayMesh.new()
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.18
	trunk.bottom_radius = 0.26
	trunk.height = 1.4
	trunk.radial_segments = 6
	trunk.rings = 1
	_add_part(mesh, trunk, Transform3D(Basis(), Vector3(0, 0.7, 0)), Color(0.34, 0.22, 0.12))
	# canopies: CylinderMesh with top_radius 0 == a cone (works on every 4.x build)
	var lower := CylinderMesh.new()
	lower.top_radius = 0.0
	lower.bottom_radius = 1.5
	lower.height = 2.4
	lower.radial_segments = 7
	lower.rings = 1
	_add_part(mesh, lower, Transform3D(Basis(), Vector3(0, 2.0, 0)), Color(0.13, 0.34, 0.17))
	var upper := CylinderMesh.new()
	upper.top_radius = 0.0
	upper.bottom_radius = 1.0
	upper.height = 1.9
	upper.radial_segments = 7
	upper.rings = 1
	_add_part(mesh, upper, Transform3D(Basis(), Vector3(0, 3.4, 0)), Color(0.16, 0.40, 0.20))
	return mesh

func _make_rock_mesh() -> Mesh:
	var mesh := ArrayMesh.new()
	var b1 := BoxMesh.new()
	b1.size = Vector3(1.6, 1.1, 1.4)
	var t1 := Transform3D(Basis(Vector3(0, 1, 0), 0.5) * Basis(Vector3(1, 0, 0), 0.25), Vector3(0, 0.45, 0))
	_add_part(mesh, b1, t1, Color(0.42, 0.40, 0.38))
	var b2 := BoxMesh.new()
	b2.size = Vector3(0.9, 0.8, 1.0)
	var t2 := Transform3D(Basis(Vector3(0, 1, 0), 1.2), Vector3(0.6, 0.35, -0.4))
	_add_part(mesh, b2, t2, Color(0.34, 0.33, 0.32))
	return mesh

func _make_sign_mesh() -> Mesh:
	var mesh := ArrayMesh.new()
	var post := CylinderMesh.new()
	post.top_radius = 0.07
	post.bottom_radius = 0.07
	post.height = 2.2
	post.radial_segments = 5
	post.rings = 1
	_add_part(mesh, post, Transform3D(Basis(), Vector3(0, 1.1, 0)), Color(0.55, 0.55, 0.58))
	var panel := BoxMesh.new()
	panel.size = Vector3(1.1, 0.7, 0.08)
	_add_part(mesh, panel, Transform3D(Basis(), Vector3(0, 2.1, 0)), Color(0.90, 0.78, 0.16))
	return mesh

## Build one MultiMeshInstance3D per prop type present in this chunk.
func _insert_props(container: Node3D, props: Array) -> void:
	if props.is_empty():
		return
	var by_type := {}
	for p in props:
		var t: int = p.type
		if not by_type.has(t):
			by_type[t] = []
		by_type[t].append(p)
	for t in by_type.keys():
		var list: Array = by_type[t]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _prop_mesh(t)
		mm.instance_count = list.size()
		for i in range(list.size()):
			var p: Dictionary = list[i]
			var basis := Basis(Vector3(0, 1, 0), p.rot).scaled(Vector3(p.scale, p.scale, p.scale))
			mm.set_instance_transform(i, Transform3D(basis, p.pos))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		# per-surface materials on the prop mesh carry the colors; no override.
		container.add_child(mmi)

# Biome palette [ground, road] cycling with distance so progress is visible.
const BIOMES := [
	[Color(0.28, 0.44, 0.20), Color(0.16, 0.16, 0.18)],   # meadow
	[Color(0.76, 0.66, 0.42), Color(0.30, 0.25, 0.20)],   # desert
	[Color(0.86, 0.88, 0.92), Color(0.30, 0.30, 0.34)],   # snow
	[Color(0.27, 0.12, 0.10), Color(0.12, 0.10, 0.11)],   # volcanic
]
const BIOME_LEN := 280.0   # meters per biome before it crossfades to the next

func _biome(z: float) -> Array:
	var d: float = maxf(0.0, -z)
	var phase: float = d / BIOME_LEN
	var i: int = int(floor(phase)) % BIOMES.size()
	var j: int = (i + 1) % BIOMES.size()
	var f: float = smoothstep(0.7, 1.0, phase - floor(phase))   # hold, then quick crossfade
	var a: Array = BIOMES[i]
	var b: Array = BIOMES[j]
	return [(a[0] as Color).lerp(b[0], f), (a[1] as Color).lerp(b[1], f)]

func _color_for(x: float, _y: float, z: float, noise: FastNoiseLite = null) -> Color:
	var ax := absf(x)
	var pal := _biome(z)
	var grass: Color = pal[0]
	var asphalt: Color = pal[1]
	var edge := smoothstep(road_half_width - 2.0, road_half_width + 2.0, ax)
	# gap dressing: hazard stripes up the launch ramp, bright pad on the landing
	var g := _gap_for_z(z, noise)
	if not g.is_empty() and ax < road_half_width:
		if z <= g.ramp_z0 and z > g.lip_z:
			var stripe: bool = fmod(absf(z), 4.0) < 2.0   # yellow/black chevron feel
			return Color(0.92, 0.78, 0.12) if stripe else Color(0.1, 0.1, 0.11)
		elif z < g.far_z and z >= g.land_z1:
			return Color(0.16, 0.5, 0.3).lerp(grass, edge)   # green "safe" landing pad
	# --- off the asphalt: ground with a little grain so the verges aren't a flat fill
	if ax > road_half_width + 2.0:
		var gv: float = 0.0
		if noise != null:
			gv = noise.get_noise_2d(x * 1.3, z * 1.3) * 0.06
		return grass.lightened(maxf(gv, 0.0)).darkened(maxf(-gv, 0.0))

	# --- road surface detail (only inside the asphalt band) ----------------------
	# subtle asphalt tone variation so the tarmac isn't a single dead grey
	var av: float = 0.0
	if noise != null:
		av = noise.get_noise_2d(x * 2.0, z * 2.0)
	var road := asphalt.lightened(maxf(av, 0.0) * 0.10).darkened(maxf(-av, 0.0) * 0.10)

	# dashed center line (broken white-yellow)
	if ax < 0.45:
		if fmod(absf(z), 6.0) < 3.5:
			return Color(0.86, 0.74, 0.22)
		return road   # gap in the dash

	# solid edge / shoulder lines just inside the verge
	var line_in := road_half_width - 1.6
	var line_out := road_half_width - 0.6
	if ax > line_in and ax < line_out:
		return Color(0.88, 0.88, 0.90)   # solid white edge line

	# rumble strips: short alternating light/dark blocks on the shoulder strip
	if ax >= line_out and ax < road_half_width:
		var rumble: bool = fmod(absf(z), 2.4) < 1.2
		var rc := Color(0.82, 0.20, 0.18) if rumble else Color(0.90, 0.90, 0.92)
		return rc.lerp(grass, edge)

	return road.lerp(grass, edge)

var _mat: Material
func _terrain_mat() -> Material:
	if _mat:
		return _mat
	# Custom spatial shader: vertex-color albedo + world-position value variation,
	# slope darkening and a faint specular so the hills aren't dead flat. Falls back
	# to a StandardMaterial3D if the shader file is missing.
	var sh := load("res://shaders/hc_terrain.gdshader")
	if sh is Shader:
		var sm := ShaderMaterial.new()
		sm.shader = sh
		_mat = sm
	else:
		var bm := StandardMaterial3D.new()
		bm.vertex_color_use_as_albedo = true
		bm.roughness = 1.0
		bm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		bm.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mat = bm
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

## Skip rail over a void so it doesn't magically bridge the gap.
func _in_void(z: float) -> bool:
	var g := _gap_for_z(z)
	if g.is_empty():
		return false
	return z <= g.lip_z and z >= g.far_z

func _build_rail(xpos: float, z0: float, z1: float) -> Node3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := 4.0
	# build the rail in contiguous segments, breaking the strip across each void
	var seg_start := 0   # vertex index where the current segment began
	var rings := 0       # rings in the current segment
	var vbase := 0       # total vertices emitted
	var z := z0
	while z <= z1:
		if _in_void(z):
			seg_start = vbase   # break: next ring starts a fresh, disconnected strip
			rings = 0
			z += step
			continue
		var ey := height_at(xpos, z)
		st.set_color(Color(0.75, 0.75, 0.8))
		st.add_vertex(Vector3(xpos, ey - 0.3, z))
		st.set_color(Color(0.9, 0.3, 0.25))
		st.add_vertex(Vector3(xpos, ey + rail_height, z))
		vbase += 2
		if rings >= 1:
			var a := seg_start + (rings - 1) * 2
			var b := a + 1
			var c := a + 2
			var dd := a + 3
			st.add_index(a); st.add_index(c); st.add_index(b)
			st.add_index(b); st.add_index(c); st.add_index(dd)
		rings += 1
		z += step
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
	# NOTE: no collision on the rails anymore. Building a trimesh shape over the
	# full 900m+ rail every chunk crossing was a big frame hitch. The car already
	# crashes when it leaves the road (the |x| > road_half check in HCCar), so the
	# rail is now a visual edge marker only.
	add_child(container)
	return container
