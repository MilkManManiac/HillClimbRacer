extends Node3D
## Phase-1 winding-ribbon road (the 2-D path rebuild). A deterministic 2-D centre-line
## is generated once at load — mostly straight with occasional big turns (up to ~120°),
## with a HARD no-overlap guarantee so the ribbon never eats itself. The road, verges
## and rails are streamed as tiles ALONG the path (by distance-along-road s), and the
## car drives on per-tile trimesh collision. Distance/money = arc-length.
##
## Exposes the same small interface HCCar/HCMain use so it drops in behind a toggle:
##   set_target(node), height_at(x,z), progress(pos), lateral_off(pos), road_half_here(pos)
## (No gaps yet — has_gaps() is false so the car skips its jump logic. Phase 2 adds them.)

signal pickup_collected(kind: String, value: float)   # interface parity (unused for now)

const STEP := 4.0            # path sample spacing (m)
const N_MAX := 7000          # samples -> 28 km of road
const TILE_SAMPLES := 8      # samples per streamed tile (32 m)
const AHEAD_TILES := 20
const BEHIND_TILES := 4
const CELL := 24.0           # spatial-hash cell size for projection + overlap tests

@export var road_half := 18.0          # drivable half-width on a straight
@export var road_half_turn := 26.0     # widened half-width through a turn (drift room)
@export var edge_falloff := 10.0       # how fast hills fade to flat past the verge
@export var mesh_verge := 12.0         # extra ground meshed past the drivable edge
@export var hill_amp := 7.0            # rolling-hill height along the road (gentle for now)
@export var straight_bias := 0.55      # chance a new segment is straight (mostly-straight)
@export var max_turn_deg := 130.0      # biggest turn a sweeper can make
@export var turn_radius_min := 30.0    # tightest turn radius (m) — small = drift-friendly
@export var turn_radius_max := 85.0    # loosest turn radius (m)

var _px := PackedFloat32Array()   # world X per sample
var _pz := PackedFloat32Array()   # world Z per sample
var _ph := PackedFloat32Array()   # heading (rad): forward = (sin h, -cos h)
var _pw := PackedFloat32Array()   # widen factor 0..1 per sample
var _n := 0
var _noise: FastNoiseLite
var _grid := {}                   # Vector2i cell -> Array[int] sample indices
var _target: Node3D
var _proj_i := 0                  # stateful nearest-sample hint for the target
var _tiles := {}                  # tile index -> Node3D container
var _road_mat: StandardMaterial3D
var _rail_mat: StandardMaterial3D

func _ready() -> void:
	_build_path()

# --- deterministic 2-D path generation with hard no-overlap -------------------
func _build_path() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = 777
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 1     # ONE octave = smooth long rolls, no small bumps
	_noise.frequency = 0.0026      # long wavelength (~380 m) so hills are gentle sweeps
	_px.resize(N_MAX); _pz.resize(N_MAX); _ph.resize(N_MAX); _pw.resize(N_MAX)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260630
	var x := 0.0
	var z := 0.0
	var th := 0.0
	var seg_left := 40      # open with a decent straight
	var seg_kappa := 0.0
	var seg_widen := 0.0
	for i in range(N_MAX):
		_px[i] = x; _pz[i] = z; _ph[i] = th; _pw[i] = seg_widen
		_grid_add(i, x, z)
		if seg_left <= 0:
			var seg := _next_segment(rng, x, z, th, i)
			seg_left = int(seg.len); seg_kappa = seg.kappa; seg_widen = seg.widen
		th += seg_kappa
		x += sin(th) * STEP
		z += -cos(th) * STEP
		seg_left -= 1
	_n = N_MAX
	_smooth_widen()

## Pick the next segment: mostly straight, occasionally a big turn that's checked for
## overlap and steered away (or straightened) if it would touch an earlier pass.
func _next_segment(rng: RandomNumberGenerator, x: float, z: float, th: float, i: int) -> Dictionary:
	# Build a short ordered list of candidates (preferred first), then pick the FIRST
	# that doesn't run the ribbon into an earlier pass. Every segment is checked —
	# straights too — so the road can never cross itself.
	var opts: Array = []
	if rng.randf() < straight_bias:
		opts.append(_mk_straight(rng))
		opts.append(_mk_turn(rng, _dir_toward_zero(th)))
		opts.append(_mk_turn(rng, -_dir_toward_zero(th)))
	else:
		var d := _pick_dir(rng, th)
		opts.append(_mk_turn(rng, d))
		opts.append(_mk_turn(rng, -d))
		opts.append(_mk_straight(rng))
	for o in opts:
		if not _seg_overlaps(x, z, th, o.kappa, int(o.len), i):
			return o
	return {"len": 14, "kappa": 0.0, "widen": 0.0}   # boxed in — creep straight, re-decide next

func _mk_straight(rng: RandomNumberGenerator) -> Dictionary:
	return {"len": rng.randi_range(24, 70), "kappa": 0.0, "widen": 0.0}

## A turn defined by RADIUS (tight = drift-friendly). curvature per sample = STEP/R.
func _mk_turn(rng: RandomNumberGenerator, dir: float) -> Dictionary:
	var mag := deg_to_rad(rng.randf_range(45.0, max_turn_deg))
	var radius := rng.randf_range(turn_radius_min, turn_radius_max)
	var seglen := clampi(int(round(radius * mag / STEP)), 10, 300)
	return {"len": seglen, "kappa": dir * (STEP / radius), "widen": 1.0}

## Random turn direction, but bias back toward straight-ahead when heading gets large so
## the road keeps progressing and doesn't spiral onto itself.
func _pick_dir(rng: RandomNumberGenerator, th: float) -> float:
	if absf(th) > deg_to_rad(58.0):
		return -signf(th)
	return 1.0 if rng.randf() < 0.5 else -1.0
func _dir_toward_zero(th: float) -> float:
	return -signf(th) if absf(th) > 0.05 else 1.0

## Simulate a segment (turn or straight) and see if it comes within clearance of a
## NON-adjacent earlier pass. Clearance covers both meshed ribbons plus a margin.
func _seg_overlaps(x: float, z: float, th: float, kappa: float, seglen: int, i: int) -> bool:
	var clear := 2.0 * (road_half_turn + mesh_verge) + 8.0
	var sx := x; var sz := z; var sth := th
	for k in range(seglen + 12):
		sth += kappa
		sx += sin(sth) * STEP
		sz += -cos(sth) * STEP
		if _grid_near(sx, sz, i - 45, clear):   # ignore the last ~180 m (adjacent road)
			return true
	return false

func _cell(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / CELL)), int(floor(z / CELL)))
func _grid_add(i: int, x: float, z: float) -> void:
	var c := _cell(x, z)
	if not _grid.has(c):
		_grid[c] = PackedInt32Array()
	_grid[c].append(i)
## Any sample with index <= max_i within `clear` metres of (x,z)?
func _grid_near(x: float, z: float, max_i: int, clear: float) -> bool:
	var c := _cell(x, z)
	var r := int(ceil(clear / CELL)) + 1
	var c2 := clear * clear
	for dx in range(-r, r + 1):
		for dz in range(-r, r + 1):
			var key := Vector2i(c.x + dx, c.y + dz)
			if not _grid.has(key):
				continue
			for j in _grid[key]:
				if j > max_i:
					continue
				var ddx: float = _px[j] - x
				var ddz: float = _pz[j] - z
				if ddx * ddx + ddz * ddz < c2:
					return true
	return false

## Box-blur the widen flags so the road eases wider/narrower instead of snapping.
func _smooth_widen() -> void:
	var out := PackedFloat32Array(); out.resize(_n)
	var w := 6
	for i in range(_n):
		var a := 0.0
		var lo := maxi(0, i - w); var hi := mini(_n - 1, i + w)
		for j in range(lo, hi + 1):
			a += _pw[j]
		out[i] = a / float(hi - lo + 1)
	_pw = out

# --- projection (world pos -> path sample) -----------------------------------
## Nearest sample to (x,z) searching outward from `hint`.
func _nearest_from(x: float, z: float, hint: int) -> int:
	var best := clampi(hint, 0, _n - 1)
	var bestd := INF
	var lo := maxi(0, hint - 40); var hi := mini(_n, hint + 40)
	for j in range(lo, hi):
		var dx: float = _px[j] - x; var dz: float = _pz[j] - z
		var d := dx * dx + dz * dz
		if d < bestd:
			bestd = d; best = j
	return best
## Nearest sample anywhere (grid-based) — for arbitrary queries (anti-tunnel).
func _nearest_grid(x: float, z: float) -> int:
	var c := _cell(x, z)
	var best := 0; var bestd := INF
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var key := Vector2i(c.x + dx, c.y + dz)
			if not _grid.has(key):
				continue
			for j in _grid[key]:
				var ddx: float = _px[j] - x; var ddz: float = _pz[j] - z
				var d := ddx * ddx + ddz * ddz
				if d < bestd:
					bestd = d; best = j
	if bestd == INF:
		return _nearest_from(x, z, _proj_i)   # fallback if no nearby cell
	return best

## Signed lateral offset of (x,z) from sample i (along the road's right vector).
func _lateral(i: int, x: float, z: float) -> float:
	var rx := cos(_ph[i]); var rz := sin(_ph[i])   # right vector
	return (x - _px[i]) * rx + (z - _pz[i]) * rz

# --- public interface (matches HCTerrain so it drops in behind the toggle) ----
func set_target(t: Node3D) -> void:
	_target = t
	_proj_i = 0
	_update_tiles()

func has_gaps() -> bool:
	return false   # phase 1: no jumps on the winding road yet

## Where to drop the car in: a bit forward along the opening straight (so there's road
## BEHIND it and it can't roll off the start edge). Heading here is 0 -> faces forward.
func spawn_pos() -> Vector3:
	if _n == 0:
		return Vector3(0, 4, 0)
	var i := mini(28, _n - 1)   # ~110 m in, still inside the opening straight
	return Vector3(_px[i], height_at(_px[i], _pz[i]) + 4.0, _pz[i])

## Distance-along-road (arc-length) at a world position — drives distance/money.
func progress(pos: Vector3) -> float:
	var i := _nearest_from(pos.x, pos.z, _proj_i)
	_proj_i = i
	return float(i) * STEP

## Lateral distance off the road centre-line (for off-road detection).
func lateral_off(pos: Vector3) -> float:
	var i := _nearest_from(pos.x, pos.z, _proj_i)
	return absf(_lateral(i, pos.x, pos.z))

## Drivable half-width here (wider through turns).
func road_half_here(pos: Vector3) -> float:
	var i := _nearest_from(pos.x, pos.z, _proj_i)
	return lerpf(road_half, road_half_turn, _pw[i])

## Ground height at an arbitrary world (x,z) — rolling hills along the road, flat past it.
func height_at(x: float, z: float) -> float:
	if _n == 0:
		return 0.0
	var i := _nearest_grid(x, z)
	var lat := _lateral(i, x, z)
	var d := float(i) * STEP
	var amp := lerpf(3.0, hill_amp, clampf(d / 450.0, 0.0, 1.0))
	var prof := _noise.get_noise_1d(d)
	var rh := lerpf(road_half, road_half_turn, _pw[i])
	var edge := smoothstep(rh, rh + edge_falloff, absf(lat))
	return prof * lerpf(amp, amp * 0.1, edge)

# --- streaming: ribbon tiles along the path ----------------------------------
func _process(_delta: float) -> void:
	if _target:
		_update_tiles()

func _update_tiles() -> void:
	if _n == 0:
		return
	var ci := _nearest_from(_target.global_position.x, _target.global_position.z, _proj_i)
	_proj_i = ci
	var ct := ci / TILE_SAMPLES
	var want := {}
	for t in range(ct - BEHIND_TILES, ct + AHEAD_TILES + 1):
		if t >= 0 and t * TILE_SAMPLES < _n - 1:
			want[t] = true
	# free tiles out of range
	for t in _tiles.keys():
		if not want.has(t):
			_tiles[t].queue_free()
			_tiles.erase(t)
	# build up to a few missing tiles per frame (nearest first) to avoid hitches
	var built := 0
	for t in range(ct - BEHIND_TILES, ct + AHEAD_TILES + 1):
		if built >= 3:
			break
		if want.has(t) and not _tiles.has(t):
			_build_tile(t)
			built += 1

func _mats() -> void:
	if _road_mat == null:
		_road_mat = StandardMaterial3D.new()
		_road_mat.vertex_color_use_as_albedo = true
		_road_mat.roughness = 0.95
	if _rail_mat == null:
		_rail_mat = StandardMaterial3D.new()
		_rail_mat.vertex_color_use_as_albedo = true
		_rail_mat.roughness = 0.6
		_rail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

# lateral cross-section offsets (fractions of the meshed half-width) for the ribbon.
const LAT_FR := [-1.0, -0.8, -0.62, -0.5, -0.32, -0.12, 0.0, 0.12, 0.32, 0.5, 0.62, 0.8, 1.0]

func _build_tile(t: int) -> void:
	_mats()
	var i0 := t * TILE_SAMPLES
	var i1 := mini(i0 + TILE_SAMPLES, _n - 1)
	if i1 <= i0:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var col := SurfaceTool.new()   # collision surface (drivable band only)
	col.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows: Array = []       # per sample: Array of Vector3 cross-section points
	var half_mesh := road_half_turn + mesh_verge
	for i in range(i0, i1 + 1):
		var cx := _px[i]; var cz := _pz[i]
		var rx := cos(_ph[i]); var rz := sin(_ph[i])
		var d := float(i) * STEP
		var rh := lerpf(road_half, road_half_turn, _pw[i])
		var pts: Array = []
		var cols: Array = []
		for fr in LAT_FR:
			var lat: float = float(fr) * half_mesh
			var wx := cx + rx * lat
			var wz := cz + rz * lat
			var wy := _height_lat(d, lat, rh)
			pts.append(Vector3(wx, wy, wz))
			cols.append(_surface_color(d, lat, rh))
		rows.append({"p": pts, "c": cols, "rh": rh, "cx": cx, "cz": cz, "rx": rx, "rz": rz, "d": d})
	# stitch rows into the ribbon + collision band
	for r in range(rows.size() - 1):
		var a: Dictionary = rows[r]
		var b: Dictionary = rows[r + 1]
		for k in range(LAT_FR.size() - 1):
			_quad(st, a.p[k], a.p[k + 1], b.p[k], b.p[k + 1], a.c[k], a.c[k + 1], b.c[k], b.c[k + 1])
			# collision across the drivable band (a bit past the rails so a slide still lands)
			var midlat: float = (float(LAT_FR[k]) + float(LAT_FR[k + 1])) * 0.5 * half_mesh
			if absf(midlat) <= road_half_turn + 2.0:
				_quad(col, a.p[k], a.p[k + 1], b.p[k], b.p[k + 1], Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE)
	st.generate_normals()
	var container := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _road_mat
	container.add_child(mi)
	# rails down both edges
	container.add_child(_rail_strip(rows, -1.0))
	container.add_child(_rail_strip(rows, 1.0))
	# collision
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(col.commit().get_faces())
	cs.shape = shape
	body.add_child(cs)
	container.add_child(body)
	add_child(container)
	_tiles[t] = container

func _height_lat(d: float, lat: float, rh: float) -> float:
	var amp := lerpf(3.0, hill_amp, clampf(d / 450.0, 0.0, 1.0))
	var prof := _noise.get_noise_1d(d)
	var edge := smoothstep(rh, rh + edge_falloff, absf(lat))
	return prof * lerpf(amp, amp * 0.1, edge)

func _surface_color(d: float, lat: float, rh: float) -> Color:
	var grass := Color(0.28, 0.44, 0.20)
	var asphalt := Color(0.16, 0.16, 0.18)
	var al := absf(lat)
	if al > rh + 1.0:
		return grass
	var road := asphalt
	if al < 1.3 and fmod(d, 7.0) < 4.0:
		road = Color(0.86, 0.74, 0.22)   # soft dashed centre line
	var edge := smoothstep(rh - 1.5, rh + 1.0, al)   # fade to grass at the verge
	return road.lerp(grass, edge)

func _rail_strip(rows: Array, side: float) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_lo := Vector3.ZERO
	var prev_hi := Vector3.ZERO
	var have := false
	for r in rows:
		var rh: float = r.rh
		var lat := side * rh
		var lo := Vector3(r.cx + r.rx * lat, _height_lat(r.d, lat, rh) - 0.3, r.cz + r.rz * lat)
		var hi := lo + Vector3(0, 1.6, 0)
		if have:
			st.set_color(Color(0.75, 0.75, 0.8)); st.add_vertex(prev_lo)
			st.set_color(Color(0.9, 0.3, 0.25)); st.add_vertex(prev_hi)
			st.set_color(Color(0.9, 0.3, 0.25)); st.add_vertex(hi)
			st.set_color(Color(0.75, 0.75, 0.8)); st.add_vertex(prev_lo)
			st.set_color(Color(0.9, 0.3, 0.25)); st.add_vertex(hi)
			st.set_color(Color(0.75, 0.75, 0.8)); st.add_vertex(lo)
		prev_lo = lo; prev_hi = hi; have = true
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _rail_mat
	return mi

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, ca: Color, cb: Color, cc: Color, cd: Color) -> void:
	st.set_color(ca); st.add_vertex(a)
	st.set_color(cc); st.add_vertex(c)
	st.set_color(cb); st.add_vertex(b)
	st.set_color(cb); st.add_vertex(b)
	st.set_color(cc); st.add_vertex(c)
	st.set_color(cd); st.add_vertex(d)
