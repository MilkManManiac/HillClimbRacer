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

signal pickup_collected(kind: String, value: float)

const HCPickup := preload("res://scripts/hc/HCPickup.gd")
const GlbUtil := preload("res://scripts/GlbUtil.gd")

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

# --- map-readiness: seeds + palette + scatter, set by a future maps system BEFORE
# add_child (read once in _build_path / _mats / _ensure_scatter_meshes) --------
@export var path_seed := 20260630      # centre-line RNG seed (straights/turns/widen)
@export var noise_seed := 777          # hill-noise seed
@export var noise_frequency := 0.0026  # hill-noise wavelength (lower = gentler, longer rolls)
@export var grass_color := Color(0.28, 0.44, 0.20)
@export var asphalt_color := Color(0.16, 0.16, 0.18)
@export var centre_line_color := Color(0.86, 0.74, 0.22)   # dashed centre stripe
@export var edge_line_color := Color(0.92, 0.92, 0.88)     # solid verge-edge stripe
@export var rail_post_color := Color(0.5, 0.5, 0.55)       # guardrail posts + strip base
@export var rail_band_color := Color(0.9, 0.3, 0.25)       # emissive top band / cap rail
@export_range(0.0, 1.0) var scatter_density := 0.6         # 0..1 chance of a prop per verge slot
@export var scatter_kinds: Array[String] = [
	"res://assets/trees/pine_quaternius_cc0.glb",
	"res://assets/trees/pine_tall_quaternius_cc0.glb",
	"res://assets/rocks/rock_quaternius_1_cc0.glb",
	"res://assets/rocks/rock_quaternius_2_cc0.glb",
]

# --- jumps (gaps) on the winding road ---------------------------------------
@export var gap_start := 320.0         # no jumps before this distance-along-road
@export var gap_spacing := 300.0       # base distance between jumps
@export var gap_spacing_grow := 90.0   # +distance to each next jump (rarer further out)
@export var gap_base_width := 34.0     # void width (along the road) at the first jump
@export var gap_grow := 10.0           # +void width per jump
@export var gap_max_width := 130.0
@export var gap_ramp_len := 24.0       # launch ramp run-up
@export var gap_ramp_rise := 7.0       # how high the lip kicks
@export var gap_land_len := 55.0       # landing DOWNSLOPE past the void (long = smooth)
@export var gap_land_rise := 8.0       # landing lip height — you touch down and ride it down
@export var gap_pit := -45.0           # void floor
var _gaps: Array = []                  # {cs, vw, lvl, idx}
var _gsamp := PackedInt32Array()       # per sample: index into _gaps, or -1

# --- collectible pickups (coins + fuel), streamed by arc-length ahead of the car -
# Deterministic slots along the road, streamed in a window and freed behind. They are
# RESPAWNABLE: collecting one only removes it for the current run; reset_pickups()
# (called on restart) frees them all and rewinds the frontier so every run starts
# fully stocked. Fuel cans give a modest top-up — enough to matter, not a free tank.
const PK_STEP := 16.0            # slot spacing along the road centre-line (m)
const PK_LOOKAHEAD := 240.0      # spawn slots up to this far ahead (arc-length)
const PK_BEHIND := 60.0          # free pickups once this far behind the car
const PK_COIN_VALUE := 20.0      # cash per coin
const PK_FUEL_VALUE := 14.0      # fuel units per can (deliberately small — a sip, not a fill)
const PK_FUEL_SLOT := 8          # a fuel can every Nth slot (~128 m); the rest are coins
const PK_ARC_COINS := 6          # coins arced over each gap jump
const PK_ARC_PEAK := 7.0         # arc apex above the launch level
var _pk_root: Node3D
var _pk_frontier: float = 0.0    # arc-length spawned up to
var _pk_init := false
var _pk_nodes: Array = []        # [{node, s}] live pickups, for behind-culling
var _pk_arcs := {}               # gap idx -> true once its coin arc is seeded (this run)

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
var _rail_cap_mat: StandardMaterial3D
var _post_mat: StandardMaterial3D

# --- roadside scatter (trees/rocks) — meshes loaded ONCE and reused per-tile via
# MultiMesh, so streaming a tile never touches disk. Keyed by the GLB path in
# scatter_kinds so a maps system can swap in a different kind list.
var _scatter_meshes_loaded := false
var _scatter_kind_mesh := {}    # glb path -> Mesh
var _scatter_kind_scale := {}   # glb path -> base scale (normalises native mesh size)
var _post_mesh: BoxMesh         # shared guardrail-post mesh

# --- chevron turn-warning signs (outside of bends) — one shared mesh (red panel +
# emissive white arrow), built once and reused via a MeshInstance3D per placement -----
var _chevron_mesh: ArrayMesh
const CHEVRON_TURN_THRESH := 1.0     # deg per sample (~ radius < 230 m) to count as "a turn"
const CHEVRON_STRIDE := 6            # place a board every N samples (~24 m) through a turn
const CHEVRON_OFFSET := 2.5          # metres past the road edge (outside of the bend)
const CHEVRON_HEIGHT := 1.1          # board centre height above ground

func _ready() -> void:
	_build_path()
	_build_gaps()

# --- deterministic 2-D path generation with hard no-overlap -------------------
func _build_path() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = noise_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 1     # ONE octave = smooth long rolls, no small bumps
	_noise.frequency = noise_frequency   # long wavelength so hills are gentle sweeps
	_px.resize(N_MAX); _pz.resize(N_MAX); _ph.resize(N_MAX); _pw.resize(N_MAX)
	var rng := RandomNumberGenerator.new()
	rng.seed = path_seed
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
## Nearest sample to (x,z) searching outward from `hint`. If the car isn't near the
## hint (e.g. it just RESPAWNED far away), fall back to a global grid search so the
## projection snaps to wherever the car actually is instead of the stale stretch.
func _nearest_from(x: float, z: float, hint: int) -> int:
	var best := clampi(hint, 0, _n - 1)
	var bestd := INF
	var lo := maxi(0, hint - 40); var hi := mini(_n, hint + 40)
	for j in range(lo, hi):
		var dx: float = _px[j] - x; var dz: float = _pz[j] - z
		var d := dx * dx + dz * dz
		if d < bestd:
			bestd = d; best = j
	if bestd > 3600.0:   # >60 m from the local window -> teleport; search globally
		return _nearest_grid(x, z, best)
	return best
## Nearest sample anywhere (grid-based). `fallback` returned if nothing is nearby.
func _nearest_grid(x: float, z: float, fallback: int = 0) -> int:
	var c := _cell(x, z)
	var best := fallback; var bestd := INF
	for r in range(0, 4):   # widen the ring until we find road samples
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if r > 0 and absi(dx) != r and absi(dz) != r:
					continue   # only the new ring
				var key := Vector2i(c.x + dx, c.y + dz)
				if not _grid.has(key):
					continue
				for j in _grid[key]:
					var ddx: float = _px[j] - x; var ddz: float = _pz[j] - z
					var d := ddx * ddx + ddz * ddz
					if d < bestd:
						bestd = d; best = j
		if bestd != INF:
			break
	return best

## Signed lateral offset of (x,z) from sample i (along the road's right vector).
func _lateral(i: int, x: float, z: float) -> float:
	var rx := cos(_ph[i]); var rz := sin(_ph[i])   # right vector
	return (x - _px[i]) * rx + (z - _pz[i]) * rz

## CONTINUOUS projection of (x,z) onto the centre-line. The old integer-sample
## projection quantised s (and lateral) to 4 m steps, which turned every height/
## gradient query into a staircase — the root of the ramp-launch spikes and the
## per-sample "ticks" the car felt at speed. This projects onto the polyline
## SEGMENTS around the nearest sample instead, so s, lat and widen vary smoothly.
## Returns {"s": arc-length, "lat": signed lateral, "w": widen 0..1, "i": sample}.
func _project_at(i: int, x: float, z: float) -> Dictionary:
	var best_s := float(i) * STEP
	var best_lat := _lateral(i, x, z)
	var best_w := _pw[i]
	var best_h := _ph[i]                 # heading, interpolated along the winning segment
	# the per-sample values above are only the LAST-RESORT fallback (degenerate path);
	# seed the search at INF so a real segment projection always wins — seeding with the
	# sample's lateral distance TIES with the segment candidates on straights, which kept
	# the quantised fallback and reintroduced the 4 m height staircase this replaces.
	var best_d2 := INF
	for j in [i - 1, i]:                 # the two segments touching sample i
		if j < 0 or j + 1 >= _n:
			continue
		var ax := _px[j]; var az := _pz[j]
		var dx := _px[j + 1] - ax; var dz := _pz[j + 1] - az
		var len2 := dx * dx + dz * dz
		if len2 < 0.0001:
			continue
		var t := clampf(((x - ax) * dx + (z - az) * dz) / len2, 0.0, 1.0)
		var cx := ax + dx * t; var cz := az + dz * t
		var ox := x - cx; var oz := z - cz
		var d2 := ox * ox + oz * oz
		if d2 < best_d2:
			var inv := 1.0 / sqrt(len2)            # segment forward, normalised
			var fx := dx * inv; var fz := dz * inv
			best_d2 = d2
			best_s = (float(j) + t) * STEP
			best_lat = ox * -fz + oz * fx          # right = (-fz, fx): signed lateral
			best_w = lerpf(_pw[j], _pw[j + 1], t)
			best_h = lerp_angle(_ph[j], _ph[j + 1], t)
	return {"s": best_s, "lat": best_lat, "w": best_w, "h": best_h, "i": i}

## Continuous projection seeded from the stateful hint (cheap; for the car).
func _project(x: float, z: float) -> Dictionary:
	var i := _nearest_from(x, z, _proj_i)
	_proj_i = i
	return _project_at(i, x, z)

# --- public interface (matches HCTerrain so it drops in behind the toggle) ----
func set_target(t: Node3D) -> void:
	_target = t
	_proj_i = 0
	_update_tiles()

func has_gaps() -> bool:
	return true

## Where to drop the car in: a bit forward along the opening straight (so there's road
## BEHIND it and it can't roll off the start edge). Heading here is 0 -> faces forward.
func spawn_pos() -> Vector3:
	if _n == 0:
		return Vector3(0, 4, 0)
	var i := mini(28, _n - 1)   # ~110 m in, still inside the opening straight
	return Vector3(_px[i], height_at(_px[i], _pz[i]) + 4.0, _pz[i])

## Distance-along-road (arc-length) at a world position — drives distance/money.
func progress(pos: Vector3) -> float:
	return _project(pos.x, pos.z).s

## Lateral distance off the road centre-line (for off-road detection).
func lateral_off(pos: Vector3) -> float:
	return absf(_project(pos.x, pos.z).lat)

## Drivable half-width here (wider through turns).
func road_half_here(pos: Vector3) -> float:
	return lerpf(road_half, road_half_turn, _project(pos.x, pos.z).w)

## First gap ahead of `pos` within `max_dist` metres of arc-length.
## Returns {} when none. dist = metres from pos to the void lip.
func gap_ahead(pos: Vector3, max_dist: float = 100.0) -> Dictionary:
	if _gsamp.is_empty() or _gaps.is_empty():
		return {}
	var p := _project(pos.x, pos.z)
	var s: float = p.s
	var i: int = clampi(p.i, 0, _gsamp.size() - 1)
	var last := mini(_gsamp.size() - 1, i + maxi(0, int(max_dist / STEP)))
	for j in range(i, last + 1):
		var gi := _gsamp[j]
		if gi < 0:
			continue
		var g: Dictionary = _gaps[gi]
		var lip: float = g.cs - g.vw * 0.5
		if lip > s:
			return {"dist": lip - s, "vw": g.vw}
	return {}

## Ground height at an arbitrary world (x,z) — rolling hills + carved jumps.
## Continuous everywhere (segment-projected s/lat), so finite-difference
## gradients over it are smooth — safe for suspension and ramp launches.
func height_at(x: float, z: float) -> float:
	if _n == 0:
		return 0.0
	var p := _project_at(_nearest_grid(x, z), x, z)
	var rh: float = lerpf(road_half, road_half_turn, p.w)
	return _carved_height(p.s, p.lat, rh)

## World centre-line point `dist` metres further along the road from pos's
## projection (dist 0 = the projection itself). Lets the camera read bends early —
## the old road_center_x(z) look-ahead only made sense on the straight z-corridor.
func path_ahead(pos: Vector3, dist: float) -> Vector3:
	if _n == 0:
		return pos
	var p := _project(pos.x, pos.z)
	var fi: float = clampf((p.s + dist) / STEP, 0.0, float(_n - 1))
	var i := int(fi)
	var t := fi - float(i)
	var j := mini(i + 1, _n - 1)
	return Vector3(lerpf(_px[i], _px[j], t), 0.0, lerpf(_pz[i], _pz[j], t))

## Analytic ground for the car's suspension: smooth height AND surface normal in
## ONE projection. Riding this field instead of raycasting the trimesh tiles kills
## the facet/seam bumps entirely — the wheels follow the same C1 noise curve the
## road mesh was sampled from, independent of collision streaming.
func ground_info(x: float, z: float) -> Dictionary:
	if _n == 0:
		return {"h": 0.0, "n": Vector3.UP}
	var p := _project(x, z)
	var s: float = p.s
	var lat: float = p.lat
	var rh: float = lerpf(road_half, road_half_turn, p.w)
	var h := _carved_height(s, lat, rh)
	# partial derivatives in the road frame (forward = +s, right = +lat)
	var e := 0.9
	var dh_ds := (_carved_height(s + e, lat, rh) - _carved_height(s - e, lat, rh)) / (2.0 * e)
	var dh_dl := (_carved_height(s, lat + e, rh) - _carved_height(s, lat - e, rh)) / (2.0 * e)
	var hd: float = p.h                             # continuous heading (no 4 m steps)
	var fx := sin(hd); var fz := -cos(hd)           # world forward
	var rx := cos(hd); var rz := sin(hd)            # world right
	var n := Vector3(-(dh_ds * fx + dh_dl * rx), 1.0, -(dh_ds * fz + dh_dl * rz)).normalized()
	return {"h": h, "n": n}

## Base rolling-hill height (no jumps) at distance s, lateral lat.
func _base_hill(s: float, lat: float, rh: float) -> float:
	var amp := lerpf(3.0, hill_amp, clampf(s / 450.0, 0.0, 1.0))
	var prof := _noise.get_noise_1d(s)
	var edge := smoothstep(rh, rh + edge_falloff, absf(lat))
	return prof * lerpf(amp, amp * 0.1, edge)

## Hill height with any jump (ramp -> void -> landing) carved into the road at s.
func _carved_height(s: float, lat: float, rh: float) -> float:
	var base := _base_hill(s, lat, rh)
	var gi := _gap_index_at_s(s)
	if gi < 0:
		return base
	var on_road := 1.0 - smoothstep(rh, rh + edge_falloff, absf(lat))
	if on_road < 0.01:
		return base
	return lerpf(base, _gap_profile(_gaps[gi], s), on_road)

## Which gap (index into _gaps) covers distance s, or -1.
func _gap_index_at_s(s: float) -> int:
	if _gsamp.is_empty():
		return -1
	var i := clampi(int(s / STEP), 0, _gsamp.size() - 1)
	return _gsamp[i]

## Height profile of a jump at distance s: ramp kicks up, void drops, landing catches.
func _gap_profile(g: Dictionary, s: float) -> float:
	var lvl: float = g.lvl
	var lip: float = g.cs - g.vw * 0.5
	var far: float = g.cs + g.vw * 0.5
	var ramp0: float = lip - gap_ramp_len
	var ll: float = g.get("ll", gap_land_len)   # per-gap landing length (wider gap = longer catch)
	var land1: float = far + ll
	if s < lip:
		# ramp: rise from the surrounding ground up to the launch lip
		var t: float = clampf((s - ramp0) / gap_ramp_len, 0.0, 1.0)
		return lerpf(_base_hill(ramp0, 0.0, road_half), lvl + gap_ramp_rise, smoothstep(0.0, 1.0, t))
	elif s < far:
		return gap_pit    # the void
	else:
		# SKI-JUMP landing: the old smoothstep had ZERO slope right at the landing lip —
		# exactly where jumps touch down — so every landing slapped a flat pad. This
		# ease-out curve is STEEPEST at the lip (initial grade ≈ 2.6 × drop/length, in the
		# same range as the trajectory family's descent angles) and flattens toward the
		# runout, so slow jumps land early on the steep part and fast jumps land deep on
		# the still-descending part — both meet the surface moving ALONG it. Pairs with
		# HCCar measuring landing damage against the surface NORMAL, which is what makes
		# "ride the downslope" free at any speed.
		var t2: float = clampf((s - far) / ll, 0.0, 1.0)
		var land_top: float = lvl + gap_land_rise
		var f: float = 1.0 - pow(1.0 - t2, 2.6)
		return lerpf(land_top, _base_hill(land1, 0.0, road_half), f)

# --- jump scheduling ---------------------------------------------------------
## Place jumps on STRAIGHT stretches (progressive spacing), marking the samples they
## cover so height/collision/gap-state can find them fast.
func _build_gaps() -> void:
	_gsamp.resize(_n)
	for i in range(_n):
		_gsamp[i] = -1
	var idx := 0
	var s := gap_start
	var limit := float(N_MAX) * STEP - gap_land_len - 60.0
	while s < limit and idx < 400:
		var vw := minf(gap_base_width + float(idx) * gap_grow, gap_max_width)
		var ll := gap_land_len + vw * 0.5   # wider void = faster jump = longer landing catch
		var span := gap_ramp_len + vw + ll + 24.0
		if _is_straight(s - span * 0.5, s + span * 0.5):
			_gaps.append({"cs": s, "vw": vw, "ll": ll, "lvl": _base_hill(s, 0.0, road_half), "idx": idx})
			var i0 := clampi(int((s - vw * 0.5 - gap_ramp_len) / STEP), 0, _n - 1)
			var i1 := clampi(int((s + vw * 0.5 + ll) / STEP), 0, _n - 1)
			for i in range(i0, i1 + 1):
				_gsamp[i] = idx
			idx += 1
			s += gap_spacing + float(idx) * gap_spacing_grow
		else:
			s += 60.0   # turn here; nudge forward and look again

## Is the road dead-straight across [s0,s1] (no turn), so a jump is fair?
func _is_straight(s0: float, s1: float) -> bool:
	var i0 := clampi(int(s0 / STEP), 0, _n - 1)
	var i1 := clampi(int(s1 / STEP), 0, _n - 1)
	if absf(_ph[i1] - _ph[i0]) > deg_to_rad(7.0):
		return false
	for i in range(i0, i1 + 1):
		if _pw[i] > 0.12:
			return false   # inside a turn's widened zone
	return true

## Jump state at a world position, for the car's _check_gap (mirrors the z-terrain).
func gap_state(pos: Vector3) -> Dictionary:
	var p := _project(pos.x, pos.z)
	var i: int = p.i
	var gi := _gsamp[i] if i < _gsamp.size() else -1
	if gi < 0:
		return {"active": false}
	var g: Dictionary = _gaps[gi]
	var s: float = p.s
	var lat: float = absf(p.lat)
	var rh: float = lerpf(road_half, road_half_turn, p.w)
	var lip: float = g.cs - g.vw * 0.5
	var far: float = g.cs + g.vw * 0.5
	return {
		"active": true, "idx": int(g.idx), "level": float(g.lvl),
		"over_void": s > lip and s < far,
		"past_far": s >= far,
		"on_road": lat <= rh,
	}

# --- streaming: ribbon tiles along the path ----------------------------------
func _process(_delta: float) -> void:
	if _target:
		_update_tiles()
		_update_pickups()

# --- pickups (coins + fuel), main-thread streamed by arc-length ----------------

## Advance a spawn frontier ahead of the car's road progress, dropping a coin (or a
## fuel can every PK_FUEL_SLOT-th slot) at each slot, plus a coin arc over any gap.
## Frees pickups that fall well behind. Deterministic + respawnable (see reset_pickups).
func _update_pickups() -> void:
	if _target == null:
		return
	if _pk_root == null:
		_pk_root = Node3D.new()
		add_child(_pk_root)
	var cs: float = progress(_target.global_position)
	if not _pk_init:
		_pk_frontier = snappedf(maxf(cs, 0.0), PK_STEP)
		_pk_init = true
	# fill the lookahead window
	var limit: float = cs + PK_LOOKAHEAD
	while _pk_frontier < limit:
		_spawn_pickup_at_s(_pk_frontier)
		_pk_frontier += PK_STEP
	# cull pickups that have dropped behind the car
	var behind: float = cs - PK_BEHIND
	var kept: Array = []
	for e in _pk_nodes:
		if is_instance_valid(e.node):
			if e.s < behind:
				e.node.queue_free()
			else:
				kept.append(e)
	_pk_nodes = kept

## Decide + place whatever pickup sits at arc-length s (skips gap voids; seeds arcs).
func _spawn_pickup_at_s(s: float) -> void:
	var i: int = clampi(int(round(s / STEP)), 0, _n - 1)
	var gi: int = _gap_index_at_s(s)
	if gi >= 0:
		# seed this gap's coin arc once, and don't drop a ground pickup inside the void
		if not _pk_arcs.has(gi):
			_pk_arcs[gi] = true
			_spawn_gap_arc(_gaps[gi])
		var g: Dictionary = _gaps[gi]
		if s > g.cs - g.vw * 0.5 and s < g.cs + g.vw * 0.5:
			return
	var slot: int = int(round(s / PK_STEP))
	var kind := "coin"
	var value := PK_COIN_VALUE
	if slot % PK_FUEL_SLOT == 0:
		kind = "fuel"
		value = PK_FUEL_VALUE
	# lateral weave for coins so the line isn't a dead-straight rail (perp = road right)
	var off := 0.0
	if kind == "coin":
		off = float((slot % 3) - 1) * (road_half * 0.4)
	var right := Vector3(cos(_ph[i]), 0.0, sin(_ph[i]))
	var base := Vector3(_px[i], 0.0, _pz[i]) + right * off
	base.y = height_at(base.x, base.z) + 1.4
	_add_pickup(kind, value, base, s)

## A short parabola of coins arced over a gap's void, peaking so a clean jump scoops them.
func _spawn_gap_arc(g: Dictionary) -> void:
	var lvl: float = g.lvl
	var lip: float = g.cs - g.vw * 0.5
	var far: float = g.cs + g.vw * 0.5
	for k in range(PK_ARC_COINS):
		var t: float = float(k) / float(PK_ARC_COINS - 1)
		var s: float = lerpf(lip, far, t)
		var i: int = clampi(int(round(s / STEP)), 0, _n - 1)
		var pos := Vector3(_px[i], lvl + PK_ARC_PEAK * 4.0 * t * (1.0 - t) + 1.4, _pz[i])
		_add_pickup("coin", PK_COIN_VALUE, pos, s)

## Instantiate one pickup, track it (with its arc-length s), and bridge its signal up.
func _add_pickup(kind: String, value: float, pos: Vector3, s: float) -> void:
	var pu := HCPickup.make(kind, value)
	_pk_root.add_child(pu)
	pu.global_position = pos
	pu.collected.connect(_on_pickup_collected)
	_pk_nodes.append({"node": pu, "s": s})

func _on_pickup_collected(kind: String, value: float) -> void:
	pickup_collected.emit(kind, value)

## Wipe every live pickup and rewind the frontier so the next run re-stocks the whole
## track — collecting a pickup never removes it permanently, only for the current run.
func reset_pickups() -> void:
	for e in _pk_nodes:
		if is_instance_valid(e.node):
			e.node.queue_free()
	_pk_nodes.clear()
	_pk_arcs.clear()
	_pk_init = false

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
		# CRITICAL: SurfaceTool COLOR attributes are read as LINEAR by default, but our
		# palette colors are authored as sRGB — without this flag the whole ground
		# renders several stops too bright (grass/asphalt wash out to pastel white).
		_road_mat.vertex_color_is_srgb = true
		_road_mat.roughness = 0.95
		# KILL the specular sheen: at the chase camera's grazing angle the default 0.5
		# specular turns the whole ground into one white sun-glare sheet (road and grass
		# indistinguishable). Matte vertex-colored ground wants essentially none.
		_road_mat.metallic_specular = 0.03
	if _rail_mat == null:
		_rail_mat = StandardMaterial3D.new()
		_rail_mat.vertex_color_use_as_albedo = true
		_rail_mat.vertex_color_is_srgb = true   # same linear-vs-sRGB washout as the road
		_rail_mat.roughness = 0.6
		_rail_mat.metallic_specular = 0.1
		_rail_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if _rail_cap_mat == null:
		# dedicated material for the thin top cap strip + posts so only the red band
		# glows — StandardMaterial3D emission is a flat property, not vertex-driven,
		# so a separate solid-color material is the simplest way to isolate it.
		_rail_cap_mat = StandardMaterial3D.new()
		_rail_cap_mat.albedo_color = rail_band_color
		_rail_cap_mat.roughness = 0.5
		_rail_cap_mat.emission_enabled = true
		_rail_cap_mat.emission = rail_band_color
		_rail_cap_mat.emission_energy_multiplier = 0.6
	if _post_mat == null:
		_post_mat = StandardMaterial3D.new()
		_post_mat.albedo_color = rail_post_color
		_post_mat.roughness = 0.85

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
		rows.append({"p": pts, "c": cols, "rh": rh, "cx": cx, "cz": cz, "rx": rx, "rz": rz, "d": d, "void": _in_void_s(d)})
	# stitch rows into the ribbon + collision band
	for r in range(rows.size() - 1):
		var a: Dictionary = rows[r]
		var b: Dictionary = rows[r + 1]
		var over_void: bool = a.void or b.void   # no floor over a jump — the car falls in
		for k in range(LAT_FR.size() - 1):
			_quad(st, a.p[k], a.p[k + 1], b.p[k], b.p[k + 1], a.c[k], a.c[k + 1], b.c[k], b.c[k + 1])
			# collision across the drivable band (a bit past the rails so a slide still lands)
			var midlat: float = (float(LAT_FR[k]) + float(LAT_FR[k + 1])) * 0.5 * half_mesh
			if not over_void and absf(midlat) <= road_half_turn + 2.0:
				_quad(col, a.p[k], a.p[k + 1], b.p[k], b.p[k + 1], Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE)
	st.generate_normals()
	var container := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _road_mat
	container.add_child(mi)
	# rails down both edges (band + emissive cap + posts)
	_build_rail_side(container, rows, -1.0)
	_build_rail_side(container, rows, 1.0)
	# painted markings (dashed centre + solid edges) as crisp overlay strips
	container.add_child(_build_lines(rows))
	# roadside scatter (trees/rocks) — purely visual, verge band only
	_scatter_tile(t, rows, container)
	# chevron turn-warning boards — purely visual, outside edge of bends only
	_build_chevrons(t, container)
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
	return _carved_height(d, lat, rh)

## Is distance s inside a jump's void (the hole itself)?
func _in_void_s(s: float) -> bool:
	var gi := _gap_index_at_s(s)
	if gi < 0:
		return false
	var g: Dictionary = _gaps[gi]
	return s > g.cs - g.vw * 0.5 and s < g.cs + g.vw * 0.5

func _surface_color(d: float, lat: float, rh: float) -> Color:
	# cheap high-frequency detail: sample the SAME noise field but at scaled-up
	# coordinates so a flat asphalt/grass fill isn't perfectly uniform, without
	# touching _noise's persistent frequency (that field also drives the hills).
	var vh := _noise.get_noise_2d(d * 9.0, lat * 9.0)   # -1..1, deterministic per-vertex
	var grass := _varied_grass(vh)
	var al := absf(lat)
	if al > rh + 1.0:
		return grass
	# jump dressing: hazard stripes up the ramp, bright pad on the landing
	var gi := _gap_index_at_s(d)
	if gi >= 0 and al < rh:
		var g: Dictionary = _gaps[gi]
		var lip: float = g.cs - g.vw * 0.5
		var far: float = g.cs + g.vw * 0.5
		if d > lip - gap_ramp_len and d < lip:
			return Color(0.92, 0.78, 0.12) if fmod(d, 4.0) < 2.0 else Color(0.1, 0.1, 0.11)
		elif d >= far and d < far + float(g.get("ll", gap_land_len)):
			return Color(0.16, 0.5, 0.3).lerp(grass, smoothstep(rh - 1.5, rh + 1.0, al))
	# NOTE: centre/edge line markings are dedicated overlay strips (_build_lines), NOT
	# vertex paint — cross-section vertices sit ~4.5 m apart, so colouring the centre
	# vertex smeared a ~9 m wide wedge across the road.
	var road := _varied_asphalt(vh)
	var edge := smoothstep(rh - 1.5, rh + 1.0, al)   # fade to grass at the verge
	return road.lerp(grass, edge)

## Crisp painted road markings as thin overlay strips: a dashed centre line plus a
## solid edge line each side, floated 3 cm above the deck (avoids z-fighting). Real
## geometry so the lines are ~0.4 m wide regardless of the road mesh's coarse
## cross-section; reuses _road_mat (vertex-color, sRGB) for the colours.
func _build_lines(rows: Array) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lift := Vector3(0, 0.03, 0)
	for r in range(rows.size() - 1):
		var a: Dictionary = rows[r]
		var b: Dictionary = rows[r + 1]
		if a.void or b.void:
			continue
		# dashed centre line: ~3.5 m dash / 3.5 m gap, phased by arc-length so dashes
		# are stable per-location no matter which tile builds them
		if fmod(float(a.d), 7.0) < 3.5:
			_line_quad(st, a, b, -0.18, 0.18, -0.18, 0.18, centre_line_color, lift)
		# solid edge line just inside each drivable edge (tracks the widen through turns)
		for side in [-1.0, 1.0]:
			var ea: float = (float(a.rh) - 0.9) * side
			var eb: float = (float(b.rh) - 0.9) * side
			_line_quad(st, a, b, ea - 0.22, ea + 0.22, eb - 0.22, eb + 0.22, edge_line_color, lift)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _road_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

## One marking quad between two rows, given per-row lateral extents.
func _line_quad(st: SurfaceTool, a: Dictionary, b: Dictionary, la0: float, la1: float, lb0: float, lb1: float, col: Color, lift: Vector3) -> void:
	var p0 := _row_pt(a, la0) + lift
	var p1 := _row_pt(a, la1) + lift
	var p2 := _row_pt(b, lb0) + lift
	var p3 := _row_pt(b, lb1) + lift
	_quad(st, p0, p1, p2, p3, col, col, col, col)

## World point on a row's cross-section at lateral offset `lat`.
func _row_pt(r: Dictionary, lat: float) -> Vector3:
	return Vector3(float(r.cx) + float(r.rx) * lat, _height_lat(float(r.d), lat, float(r.rh)), float(r.cz) + float(r.rz) * lat)

## Grass with subtle deterministic variation (~±8% value, slight yellow-green shift
## on the bright side) so the verge doesn't read as one flat fill.
func _varied_grass(vh: float) -> Color:
	var gv := 1.0 + vh * 0.08
	var warm := maxf(vh, 0.0) * 0.10   # only warms up on the bright side
	return Color(
		clampf(grass_color.r * gv + warm * 0.5, 0.0, 1.0),
		clampf(grass_color.g * gv + warm, 0.0, 1.0),
		clampf(grass_color.b * gv - warm * 0.6, 0.0, 1.0),
	)

## Asphalt with subtle deterministic value variation (~±4%).
func _varied_asphalt(vh: float) -> Color:
	var av := 1.0 + vh * 0.04
	return Color(asphalt_color.r * av, asphalt_color.g * av, asphalt_color.b * av)

## Builds one side's guardrail into `container`: the grey->red gradient band strip
## (as before), PLUS a thin emissive cap along the very top edge (so the "rail glows"
## reads as a deliberate top band, not a uniformly-lit strip), PLUS short vertical
## posts every couple of rows so it reads as a guardrail rather than a floating ribbon.
func _build_rail_side(container: Node3D, rows: Array, side: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cap := SurfaceTool.new()
	cap.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_lo := Vector3.ZERO
	var prev_hi := Vector3.ZERO
	var prev_cap := Vector3.ZERO
	var have := false
	var post_xforms: Array[Transform3D] = []
	var row_idx := 0
	for r in rows:
		var rh: float = r.rh
		var lat := side * rh
		var lo := Vector3(r.cx + r.rx * lat, _height_lat(r.d, lat, rh) - 0.3, r.cz + r.rz * lat)
		var hi := lo + Vector3(0, 1.6, 0)
		var cap_top := hi + Vector3(0, 0.25, 0)   # thin sliver above hi = the glowing cap rail
		if have:
			st.set_color(rail_post_color); st.add_vertex(prev_lo)
			st.set_color(rail_band_color); st.add_vertex(prev_hi)
			st.set_color(rail_band_color); st.add_vertex(hi)
			st.set_color(rail_post_color); st.add_vertex(prev_lo)
			st.set_color(rail_band_color); st.add_vertex(hi)
			st.set_color(rail_post_color); st.add_vertex(lo)
			cap.set_color(rail_band_color); cap.add_vertex(prev_hi)
			cap.set_color(rail_band_color); cap.add_vertex(prev_cap)
			cap.set_color(rail_band_color); cap.add_vertex(cap_top)
			cap.set_color(rail_band_color); cap.add_vertex(prev_hi)
			cap.set_color(rail_band_color); cap.add_vertex(cap_top)
			cap.set_color(rail_band_color); cap.add_vertex(hi)
		if row_idx % 2 == 0:   # a post every other row (~8 m) — enough to read as a guardrail
			_ensure_post_mesh()
			var yaw := atan2(r.rx, r.rz)   # align the post's thin axis across the road
			var pb := Basis(Vector3.UP, yaw)
			post_xforms.append(Transform3D(pb, lo + Vector3(0, 0.5, 0)))
		prev_lo = lo; prev_hi = hi; prev_cap = cap_top; have = true
		row_idx += 1
	st.generate_normals()
	cap.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _rail_mat
	container.add_child(mi)
	var cap_mi := MeshInstance3D.new()
	cap_mi.mesh = cap.commit()
	cap_mi.material_override = _rail_cap_mat
	container.add_child(cap_mi)
	if not post_xforms.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _post_mesh
		mm.instance_count = post_xforms.size()
		for i in range(post_xforms.size()):
			mm.set_instance_transform(i, post_xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = _post_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(mmi)

## Shared post mesh, built once — a short dark box that sits at the rail base.
func _ensure_post_mesh() -> void:
	if _post_mesh != null:
		return
	_post_mesh = BoxMesh.new()
	_post_mesh.size = Vector3(0.18, 1.0, 0.18)

# --- roadside scatter (trees/rocks) -------------------------------------------

## Loads every kind in scatter_kinds ONCE (lazy) and merges each into a single Mesh
## (via GlbUtil.load_mesh) for MultiMesh instancing — never touches disk per-tile.
## Also derives a per-kind base scale from the native mesh size so trees/rocks of
## very different native scale (Quaternius rocks range from tiny to huge) all read
## as similarly-sized roadside props before the per-instance 0.8-1.6x variance.
func _ensure_scatter_meshes() -> void:
	if _scatter_meshes_loaded:
		return
	_scatter_meshes_loaded = true
	for k in scatter_kinds:
		var m := GlbUtil.load_mesh(k)
		if m == null:
			continue
		_scatter_kind_mesh[k] = m
		var aabb := m.get_aabb()
		var is_tree: bool = k.contains("/trees/")
		var native: float = aabb.size.y if is_tree else maxf(aabb.size.x, aabb.size.z)
		var target: float = 9.0 if is_tree else 2.0   # trees ~9m tall, rocks ~2m wide
		_scatter_kind_scale[k] = (target / native) if native > 0.01 else 1.0

## Scatters trees/rocks along tile `t`'s verge band, deterministically from a local
## RNG seeded off the tile index (NOT global randi — streaming must be repeatable).
## Kept lateral OUTSIDE the meshed drivable band (road_half*_here + 5) and INSIDE the
## meshed ground (road_half_turn + mesh_verge - 2) so props never float off the mesh.
func _scatter_tile(t: int, rows: Array, container: Node3D) -> void:
	if scatter_density <= 0.0 or scatter_kinds.is_empty():
		return
	_ensure_scatter_meshes()
	if _scatter_kind_mesh.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(t, int(path_seed) & 0xffff, 90210))
	var half_mesh := road_half_turn + mesh_verge
	var buckets := {}
	for k in scatter_kinds:
		buckets[k] = [] as Array[Transform3D]
	for r in rows:
		if r.void:
			continue
		var rh: float = r.rh
		var lo: float = rh + 5.0
		var hi: float = half_mesh - 2.0
		if hi <= lo:
			continue
		for side in [-1.0, 1.0]:
			if rng.randf() > scatter_density:
				continue
			var lat: float = lerpf(lo, hi, rng.randf()) * side
			var kind: String = scatter_kinds[rng.randi() % scatter_kinds.size()]
			if not _scatter_kind_mesh.has(kind):
				continue
			var wx: float = r.cx + r.rx * lat
			var wz: float = r.cz + r.rz * lat
			var wy: float = _carved_height(r.d, lat, rh)
			var s: float = rng.randf_range(0.8, 1.6) * float(_scatter_kind_scale.get(kind, 1.0))
			var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
			buckets[kind].append(Transform3D(b, Vector3(wx, wy, wz)))
	for kind in buckets.keys():
		var xforms: Array = buckets[kind]
		if xforms.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _scatter_kind_mesh[kind]
		mm.instance_count = xforms.size()
		for i in range(xforms.size()):
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		container.add_child(mmi)

# --- chevron turn-warning signs ------------------------------------------------

## Places classic red/white chevron boards on the OUTSIDE of any bend spanned by tile
## `t`, spaced deterministically (index-based, never random) so streaming a tile in
## or out always produces the same boards. Heading DELTA between consecutive samples
## is the local curvature; its sign gives the turn direction, which fixes both which
## side is "outside" (opposite the turn) and which way the arrow must point (inside).
func _build_chevrons(t: int, container: Node3D) -> void:
	_ensure_chevron_mesh()
	var i0 := t * TILE_SAMPLES
	var i1 := mini(i0 + TILE_SAMPLES, _n - 1)
	for i in range(i0, i1):
		if i % CHEVRON_STRIDE != 0:
			continue
		var dph := _ph[i + 1] - _ph[i]     # local curvature (no wrap needed: th is a
		                                    # continuous accumulator, never wrapped)
		if absf(dph) <= deg_to_rad(CHEVRON_TURN_THRESH):
			continue
		var d := float(i) * STEP
		if _in_void_s(d):                  # never plant a sign over a jump's void
			continue
		var rh: float = lerpf(road_half, road_half_turn, _pw[i])
		var side := -signf(dph)            # outside = opposite the turn direction
		var lat: float = side * (rh + CHEVRON_OFFSET)
		var ph: float = _ph[i]
		var rx := cos(ph); var rz := sin(ph)             # road right vector
		var fx := sin(ph); var fz := -cos(ph)            # road forward vector
		var wx := _px[i] + rx * lat
		var wz := _pz[i] + rz * lat
		var wy := height_at(wx, wz) + CHEVRON_HEIGHT
		# arrow must point toward the INSIDE of the turn: mirror the mesh's local
		# +X (its authored arrow direction) across the turn direction sign.
		var flip := -1.0 if dph < 0.0 else 1.0
		var right_axis := Vector3(rx, 0.0, rz) * flip
		var up_axis := Vector3.UP
		var back_axis := Vector3(-fx, 0.0, -fz)          # faces oncoming (opposite travel)
		var mi := MeshInstance3D.new()
		mi.mesh = _chevron_mesh
		mi.transform = Transform3D(Basis(right_axis, up_axis, back_axis), Vector3(wx, wy, wz))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(mi)

## Builds the shared chevron sign mesh ONCE: a red backing panel (surface 0) plus a
## single white ">" arrow made of two angled stripes (surface 1, mildly emissive so it
## reads at dusk). Authored pointing local +X; `_build_chevrons` mirrors it per-instance
## via a flipped right-axis so the same mesh serves both left- and right-hand bends.
func _ensure_chevron_mesh() -> void:
	if _chevron_mesh != null:
		return
	var panel_mat := StandardMaterial3D.new()
	panel_mat.albedo_color = Color(0.78, 0.08, 0.06)
	panel_mat.roughness = 0.75
	# the board faces oncoming traffic, i.e. usually AWAY from the sun — without a touch
	# of emission the back-lit red panel renders near-black and the sign loses its colour
	panel_mat.emission_enabled = true
	panel_mat.emission = Color(0.78, 0.08, 0.06)
	panel_mat.emission_energy_multiplier = 0.25
	panel_mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # per-instance mirroring flips winding
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = Color(0.95, 0.95, 0.92)
	stripe_mat.roughness = 0.6
	stripe_mat.emission_enabled = true
	stripe_mat.emission = Color(0.95, 0.95, 0.92)
	stripe_mat.emission_energy_multiplier = 0.4
	stripe_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var panel := SurfaceTool.new()
	panel.begin(Mesh.PRIMITIVE_TRIANGLES)
	_chevron_quad(panel, Vector2(-0.8, -0.5), Vector2(0.8, -0.5), Vector2(0.8, 0.5), Vector2(-0.8, 0.5), 0.0)
	panel.generate_normals()

	var stripe := SurfaceTool.new()
	stripe.begin(Mesh.PRIMITIVE_TRIANGLES)
	_chevron_stripe(stripe, Vector2(-0.62, 0.32), Vector2(0.08, 0.0), 0.11, 0.045)   # upper arm
	_chevron_stripe(stripe, Vector2(-0.62, -0.32), Vector2(0.08, 0.0), 0.11, 0.045)  # lower arm
	stripe.generate_normals()

	_chevron_mesh = ArrayMesh.new()
	panel.commit(_chevron_mesh)
	stripe.commit(_chevron_mesh)
	_chevron_mesh.surface_set_material(0, panel_mat)
	_chevron_mesh.surface_set_material(1, stripe_mat)

## One angled stripe (a thin parallelogram of half-width `halfw`) from pa to pb in the
## sign's local XY plane, at local depth z (slightly proud of the panel).
func _chevron_stripe(st: SurfaceTool, pa: Vector2, pb: Vector2, halfw: float, z: float) -> void:
	var dir := (pb - pa).normalized()
	var perp := Vector2(-dir.y, dir.x) * halfw
	_chevron_quad(st, pa + perp, pb + perp, pb - perp, pa - perp, z)

## A flat quad in the sign's local XY plane at depth z, wound so its normal faces +Z
## (the panel's authored "front" — oriented to face oncoming traffic at placement time).
func _chevron_quad(st: SurfaceTool, p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, z: float) -> void:
	st.add_vertex(Vector3(p0.x, p0.y, z))
	st.add_vertex(Vector3(p1.x, p1.y, z))
	st.add_vertex(Vector3(p2.x, p2.y, z))
	st.add_vertex(Vector3(p0.x, p0.y, z))
	st.add_vertex(Vector3(p2.x, p2.y, z))
	st.add_vertex(Vector3(p3.x, p3.y, z))

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, ca: Color, cb: Color, cc: Color, cd: Color) -> void:
	st.set_color(ca); st.add_vertex(a)
	st.set_color(cc); st.add_vertex(c)
	st.set_color(cb); st.add_vertex(b)
	st.set_color(cb); st.add_vertex(b)
	st.set_color(cc); st.add_vertex(c)
	st.set_color(cd); st.add_vertex(d)
