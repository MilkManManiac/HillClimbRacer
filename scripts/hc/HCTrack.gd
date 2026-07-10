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
# Gaps are scheduled DURING path generation now (_try_gap, called from _build_path
# alongside _try_stunt), not found afterward in whatever straights happened to land —
# placing a gap RESERVES its own footprint (ramp + void + landing catch + a worst-
# case-overshoot safety straight) as one dead-straight segment that no later turn
# decision can ever bend. That's the fix for "you fly over the bend past the
# landing": the bend can no longer exist inside the window a max-speed launch needs.
# See _try_gap / _landing_catch_len / _max_jump_flight for the mechanics.
@export var gap_start := 320.0         # no jumps before this distance-along-road
@export var gap_spacing := 300.0       # base distance between jumps
@export var gap_spacing_grow := 90.0   # +distance to each next jump (rarer further out)
@export var gap_base_width := 34.0     # void width (along the road) at the first jump
@export var gap_grow := 10.0           # +void width per jump
@export var gap_max_width := 130.0
@export var gap_ramp_len := 24.0       # launch ramp run-up
@export var gap_ramp_rise := 7.0       # how high the lip kicks
@export var gap_land_len := 55.0       # landing DOWNSLOPE past the void (long = smooth);
                                        # floored per-gap by _landing_catch_len (speed-aware)
@export var gap_land_rise := 8.0       # landing lip height — you touch down and ride it down
@export var gap_pad_color := Color(0.16, 0.5, 0.3)  # landing-pad paint — game language is
                                        # "green = safe"; warm-palette maps override it so
                                        # the pad doesn't read as an alien lime patch
@export var gap_pit := -45.0           # void floor
var _gaps: Array = []                  # {cs, vw, lvl, idx}
var _gsamp := PackedInt32Array()       # per sample: index into _gaps, or -1

# --- speed-aware jump safety (fair landings at any legal speed) ---------------
# A maxed engine can hit a gap at its vehicle's speed_cap (95 m/s for the F1 — see
# HCMain.VEHICLES) plus a little downhill headroom before HCCar's SOFT speed cap
# (max_speed * 1.3) reels it back in, while HCCar's ramp-launch code hard-clamps the
# vertical kick to 24 m/s (`minf(ramp_vy, 24.0)`) for every vehicle. Treat that pair as
# the worst case, with a floaty vehicle's gravity (17, the slowest fall on the roster)
# for a generous (over-, not under-, estimate) hang time: the result is the horizontal
# distance a maxed car can cover between a ramp's lip and touching back down near
# launch height (_max_jump_flight). Every gap reserves at least that much fair, flat
# road past its lip — see _try_gap.
const JUMP_VMAX_H := 100.0        # generous global worst-case horizontal launch speed (m/s)
const JUMP_VMAX_V := 24.0         # HCCar's hard cap on ramp-launch vertical speed (m/s)
const JUMP_GRAVITY_MIN := 17.0    # floatiest vehicle's gravity_force (m/s^2)
const JUMP_RESERVE_MARGIN := 20.0 # extra safety past the ballistic estimate (m)
# The landing PLATFORM's leading edge (gap_land_rise above table level) is a real
# discontinuity in the height field — the void returns a flat gap_pit right up to
# `far`, where the landing curve starts at land_top. A car is only safe there if it's
# already AT OR ABOVE land_top by the time it arrives — and counter-intuitively, MORE
# speed means LESS climb: crossing a fixed-width void faster leaves less TIME for the
# capped 24 m/s vertical launch to lift the car, so a narrow gap taken at speed_cap
# can slam into the platform's face instead of flying over it. JUMP_LAND_CLEARANCE is
# the safety margin (chassis-to-wheel offset + suspension travel + buffer) below the
# worst-case climb estimate that _safe_land_rise clamps land_top's rise to.
const JUMP_LAND_CLEARANCE := 6.0
var _gap_next_s := 0.0    # arc-length the NEXT scheduled gap is due at (see _try_gap)
var _gap_idx := 0         # gaps placed so far this generation

# --- stunts: the road crossing OVER itself (overpasses + banked corkscrews) ----
# A plan string (set per-map BEFORE add_child, like every other export) of comma-
# separated tokens:
#   overpass:S[:RADIUS]           teardrop loop-back that bridges OVER its own
#                                 approach straight at arc-length ~S
#   corkscrew:S[:COILS[:RADIUS]]  climb a ramp, then spiral DOWN a banked helix
#                                 whose coils stack vertically over each other
#   loop:S[:RADIUS]               full VERTICAL loop-de-loop: a straight ground
#                                 stretch carrying a vertical-circle ribbon
#                                 tangent to the road, exiting laterally shifted
#                                 (corkscrew-style) so the wrap clears its own
#                                 entry ramp. The ribbon is NOT a heightfield
#                                 surface — HCCar rides it via loop_state() (an
#                                 opt-in frame-adherence zone); too slow = detach
#                                 and fall back to the flat road below.
# Features are emitted as SCRIPTED path segments (bypassing the random generator,
# with a fit check against earlier road) and carry ANALYTIC elevation + bank
# profiles in s — pure C1 smoothstep compositions, never per-sample interpolation,
# so the no-staircase invariant holds. Where two stretches of road overlap in
# (x,z), ground queries blend the candidate surfaces continuously (_surface_blend)
# instead of snapping between them.
@export var stunts := ""
@export var stunt_clearance := 9.5     # vertical deck-to-road gap at crossings (m)
@export var stunt_bank_deg := 13.0     # corkscrew banking (outer edge raised)
const LOOP_HALF := 4.5                 # loop ribbon half-width (m) — a narrow stunt deck
const LOOP_GAP := 4.0                  # lateral daylight between the wrap's entry & exit ramps
var _has_loop := false                 # fast-path gate for loop_state()
var _creep_total := 0                  # all boxed-in creep fallbacks (diagnostic only)
var _creep_xing := 0                   # boxed-in creeps that stayed on the unchecked
                                       # straight because `_escape_turn` found no clear
                                       # candidate — should be 0 for every shipped map;
                                       # feeds stunt_report so probes/sweeps can reject
                                       # a layout instead of shipping a broken road
var _plan: Array = []                  # parsed plan tokens, sorted by s
var _plan_idx := 0
var _plan_placed := 0
var _script: Array = []                # queued scripted pieces mid-feature
var _scripted := false                 # emitting a feature (unwind heading after)
var _features: Array = []              # placed features (analytic elev/bank profiles)
var _ovl: Array = []                   # overlap height-reconcile patches {sc,w,a,b}
var _ovl_resid := 0.0                  # worst height mismatch left after patching
var _tile_partners := {}               # tile -> {tile: true} spatially-linked tiles

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
var _tile_props := {}             # tile index -> PackedFloat32Array [x,y,z,r × N] solid verge props
var _tile_prop_bounds := {}       # tile index -> Vector3 (cx, cz, bound radius) cheap query reject
var _props_scratch := PackedFloat32Array()   # reused by props_near — callers must not hold it
var _road_mat: StandardMaterial3D
var _rail_mat: StandardMaterial3D
var _rail_cap_mat: StandardMaterial3D
var _post_mat: StandardMaterial3D
var _reflector_mat: StandardMaterial3D
## Auto-detected "is this a night map" flag, derived from grass_color luminance rather
## than a dedicated export — maps push overrides onto HCTrack via terrain.set(k,v) from
## a dict HCTrack doesn't own, so we key off a palette value every map already sets
## instead of requiring a plumbing change elsewhere. Midnight's dark grass reads well
## below any daytime map's (incl. alpine's bright snow); see _mats().
var _night := false

# --- roadside scatter (trees/rocks) — meshes loaded ONCE and reused per-tile via
# MultiMesh, so streaming a tile never touches disk. Keyed by the GLB path in
# scatter_kinds so a maps system can swap in a different kind list.
var _scatter_meshes_loaded := false
var _scatter_kind_mesh := {}    # glb path -> Mesh
var _scatter_kind_scale := {}   # glb path -> base scale (normalises native mesh size)
var _post_mesh: Mesh            # shared guardrail-post mesh (slightly tapered)
var _reflector_mesh: Mesh       # shared tiny reflector-dot mesh sat on each post

# --- chevron turn-warning signs (outside of bends) — one shared mesh (red panel +
# emissive white arrow), built once and reused via a MeshInstance3D per placement -----
var _chevron_mesh: ArrayMesh
const CHEVRON_TURN_THRESH := 1.0     # deg per sample (~ radius < 230 m) to count as "a turn"
const CHEVRON_STRIDE := 6            # place a board every N samples (~24 m) through a turn
const CHEVRON_OFFSET := 2.5          # metres past the road edge (outside of the bend)
const CHEVRON_HEIGHT := 1.1          # board centre height above ground

func _ready() -> void:
	_parse_stunts()
	_build_path()   # gaps are now scheduled INSIDE _build_path (see _try_gap)
	_reconcile_overlaps()

# --- deterministic 2-D path generation with hard no-overlap -------------------
func _build_path() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = noise_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 1     # ONE octave = smooth long rolls, no small bumps
	_noise.frequency = noise_frequency   # long wavelength so hills are gentle sweeps
	_px.resize(N_MAX); _pz.resize(N_MAX); _ph.resize(N_MAX); _pw.resize(N_MAX)
	_gsamp.resize(N_MAX)
	for k in range(N_MAX):
		_gsamp[k] = -1
	_gap_next_s = gap_start
	_gap_idx = 0
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
			var seg: Dictionary
			if not _script.is_empty():
				seg = _script.pop_front()   # mid-stunt: play the scripted pieces verbatim
			else:
				if _scripted:
					# stunt finished: unwind the accumulated coil angle by an exact
					# number of full turns (trig-identical) so _pick_dir's keep-
					# progressing bias doesn't see a huge heading and force every
					# following turn one way (a 720° corkscrew would otherwise drag
					# the road into a compensating spiral).
					th -= TAU * round(th / TAU)
					_scripted = false
				seg = _try_stunt(rng, x, z, th, i)
				if not seg.is_empty():
					_scripted = true
				else:
					seg = _try_gap(x, z, th, seg_kappa, seg_widen, i)
					if seg.is_empty():
						seg = _next_segment(rng, x, z, th, i)
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
	# Boxed in — normally creep straight and re-decide next boundary (CLASSIC
	# behavior, kept bit-identical: every legacy map's layout depends on these
	# unchecked creeps, and the vast majority of boxed-in moments are benign —
	# the next boundary finds daylight again within a sample or two).
	#
	# A rare chain of these creeps is NOT benign: a creep whose samples run inside
	# branch-gather range (55 m) of DISTANT road (index gap > 120) is chain-
	# tunnelling toward an at-grade crossing that no reconcile/blend can
	# disambiguate (canyon's own generator produced exactly this ~s=27.4-27.8 km,
	# closing to 18.9 m centre-to-centre against road half-width 20 m — a literal
	# self-eating road). Gate the escape search on that same 55 m danger radius so
	# every OTHER boxed-in creep (including all of canyon's first 6 km, where the
	# owner's tuning is the feel reference) takes the identical unchecked straight
	# it always has — only genuinely converging creeps get steered.
	_creep_total += 1
	var mc := _seg_min_clear(x, z, th, 0.0, 14, i - 75, 0)
	if mc <= 55.0:
		var esc := _escape_turn(x, z, th, i)
		if not esc.is_empty():
			return esc
		_creep_xing += 1   # no candidate improved on the straight — still flagged
	return {"len": 14, "kappa": 0.0, "widen": 0.0}

## Steer away from a converging branch instead of creeping straight into it. Sweeps
## a small deterministic set of sharper turns (radii/angles/directions the random
## draw never reaches) and greedily keeps whichever candidate raises minimum
## clearance the most — even a partial gain beats holding a heading that's actively
## closing the distance, and the next segment boundary (14 samples later) re-scores
## from the new, now-diverging heading, so a single-instant escape compounds across
## the danger zone instead of needing to solve it in one shot. Consumes no RNG (so
## it never perturbs a seed's later draws unless it actually improves on straight)
## and only runs from the danger gate above, so it is silent on every map that
## never chain-tunnels. Returns {} if nothing beats the straight clearance.
func _escape_turn(x: float, z: float, th: float, i: int) -> Dictionary:
	var d0 := _dir_toward_zero(th)
	var best := {}
	var bestmc := _seg_min_clear(x, z, th, 0.0, 14, i, 12)
	for radius in [turn_radius_min * 0.6, turn_radius_min, lerpf(turn_radius_min, turn_radius_max, 0.5), turn_radius_max]:
		for mag_deg in [70.0, 100.0, 140.0, max_turn_deg]:
			for dir in [d0, -d0]:
				var seg := _mk_turn_fixed(dir, radius, mag_deg)
				var candmc := _seg_min_clear(x, z, th, seg.kappa, int(seg.len), i, 12)
				if candmc > bestmc:
					bestmc = candmc
					best = seg
	return best

## Same shape as `_mk_turn` but with explicit radius/angle instead of an rng draw
## (the escape sweep needs to try several fixed candidates in a known order).
func _mk_turn_fixed(dir: float, radius: float, mag_deg: float) -> Dictionary:
	var mag := deg_to_rad(mag_deg)
	var seglen := clampi(int(round(radius * mag / STEP)), 10, 300)
	return {"len": seglen, "kappa": dir * (STEP / radius), "widen": 1.0}

## Minimum distance from a simulated segment (+pad lookahead samples) to any
## earlier sample with index <= i - 45, capped at the overlap clearance (cap
## returned when nothing is near). Pass a reduced i to widen the exempt gap
## (the creep gate ignores everything within ~one hairpin of itself). Escape
## scoring only — never on the generation hot path.
func _seg_min_clear(x: float, z: float, th: float, kappa: float, seglen: int, i: int, pad := 12) -> float:
	var cap := 2.0 * (road_half_turn + mesh_verge) + 8.0
	var best := cap
	var sx := x; var sz := z; var sth := th
	for k in range(seglen + pad):
		sth += kappa
		sx += sin(sth) * STEP
		sz += -cos(sth) * STEP
		best = minf(best, _grid_min_dist(sx, sz, i - 45, cap))
	return best

## Distance from (x,z) to the nearest sample with index <= max_i, capped at cap.
func _grid_min_dist(x: float, z: float, max_i: int, cap: float) -> float:
	var c := _cell(x, z)
	var r := int(ceil(cap / CELL)) + 1
	var best2 := cap * cap
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
				best2 = minf(best2, ddx * ddx + ddz * ddz)
	return sqrt(best2)

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

# --- stunts: scheduling + scripted geometry ------------------------------------

func _parse_stunts() -> void:
	_plan.clear()
	for tok in stunts.split(",", false):
		var p := tok.strip_edges().split(":")
		if p.size() < 2:
			continue
		var d := {"kind": p[0], "s": maxf(float(p[1]), 400.0), "defer": 0}
		if p.size() > 2:
			d["p1"] = float(p[2])
		if p.size() > 3:
			d["p2"] = float(p[3])
		_plan.append(d)
	_plan.sort_custom(func(a, b): return float(a.s) < float(b.s))

## At a segment boundary: if the next planned stunt is due here and its scripted
## footprint doesn't hit earlier road, register it and start emitting its pieces.
## Returns the first piece, or {} to fall through to the random generator. Consumes
## NO RNG unless a stunt is actually due, so plan-less maps generate bit-identical
## paths to before this feature existed.
func _try_stunt(rng: RandomNumberGenerator, x: float, z: float, th: float, i: int) -> Dictionary:
	if _plan_idx >= _plan.size():
		return {}
	var st: Dictionary = _plan[_plan_idx]
	if float(i) * STEP < float(st.s):
		return {}
	var pieces := _stunt_pieces(st, rng)
	var total := 0
	for p in pieces:
		total += int(p.len)
	if i + total > N_MAX - 150:
		push_warning("HCTrack: stunt '%s' past track end — dropped" % str(st.kind))
		_plan_idx += 1
		return {}
	var sim := _sim_pieces(x, z, th, pieces)
	if not _stunt_fits(sim, i):
		st.s = float(st.s) + 60.0   # boxed in by earlier road — slide the plan forward
		st.defer = int(st.defer) + 1
		if st.defer > 80:
			push_warning("HCTrack: stunt '%s' never found room — dropped" % str(st.kind))
			_plan_idx += 1
		return {}
	_register_feature(st, pieces, sim, float(i) * STEP)
	_plan_idx += 1
	_plan_placed += 1
	_script = pieces.duplicate()
	return _script.pop_front()

## The scripted piece list ({len (samples), kappa, widen}) for one stunt.
func _stunt_pieces(st: Dictionary, rng: RandomNumberGenerator) -> Array:
	var dir: float = 1.0 if rng.randf() < 0.5 else -1.0
	match str(st.kind):
		"overpass":
			# straight approach -> 252° constant-radius teardrop -> straight exit.
			# The exit leg crosses back over the approach at ~1.38 R before the turn
			# entry, at ~108° incidence (computed; verified numerically on placement).
			var r: float = clampf(float(st.get("p1", 46.0)), 30.0, 70.0)
			var turn_n := int(round(r * deg_to_rad(252.0) / STEP))
			return [
				{"len": 35, "kappa": 0.0, "widen": 0.0},
				{"len": turn_n, "kappa": dir * (STEP / r), "widen": 1.0},
				{"len": 75, "kappa": 0.0, "widen": 0.0},
			]
		"corkscrew":
			# straight climb ramp -> descending helix of COILS×360°+90° -> level exit.
			# The +90° puts the exit tangent perpendicular to the entry ramp so the
			# level exit road diverges instead of running underneath the climb. The
			# ramp is longer than the climb needs: its top HOLDS flat, because the
			# first coil pass curls back alongside the ramp corridor and the ramp
			# must already be at full height there to keep vertical clearance.
			var coils := clampi(int(float(st.get("p1", 2.0))), 1, 3)
			# default radius comfortably above the widened half-width so the spiral
			# keeps an open centre (a hole, not a stacked disc) and reads as a road
			var r2: float = clampf(float(st.get("p2", 52.0)), 34.0, 70.0)
			var h: float = _cork_h(coils)
			var ramp_n := int(round((h * 12.0 + 110.0) / STEP))
			var coil_n := int(round(r2 * deg_to_rad(float(coils) * 360.0 + 90.0) / STEP))
			return [
				{"len": ramp_n, "kappa": 0.0, "widen": 0.35},
				{"len": coil_n, "kappa": dir * (STEP / r2), "widen": 0.55},
				{"len": 60, "kappa": 0.0, "widen": 0.0},
			]
		"loop":
			# straight ground all the way through: a flat approach, a widened stretch
			# under the vertical-circle ribbon's footprint (±R around the tangent
			# point — the failed-detach car lands here), and a flat exit runout. The
			# ribbon itself is registered analytically (_register_feature) and meshed
			# by its anchor tile; the path/heightfield never leaves the ground.
			var rl: float = clampf(float(st.get("p1", 11.0)), 8.0, 16.0)
			return [
				{"len": 26, "kappa": 0.0, "widen": 0.5},
				{"len": int(ceil((2.0 * rl + 28.0) / STEP)), "kappa": 0.0, "widen": 1.0},
				{"len": 40, "kappa": 0.0, "widen": 0.5},
			]
	return [{"len": 20, "kappa": 0.0, "widen": 0.0}]   # unknown token: harmless straight

## Simulate the pieces exactly as the emission loop will step them. Sim sample k
## (0-based) becomes path sample i+k+1, i.e. arc-length s0 + (k+1)·STEP.
func _sim_pieces(x: float, z: float, th: float, pieces: Array) -> Dictionary:
	var pxs := PackedFloat32Array()
	var pzs := PackedFloat32Array()
	var sx := x; var sz := z; var sth := th
	for p in pieces:
		for k in range(int(p.len)):
			sth += float(p.kappa)
			sx += sin(sth) * STEP
			sz += -cos(sth) * STEP
			pxs.append(sx)
			pzs.append(sz)
	return {"px": pxs, "pz": pzs}

## Would the scripted footprint hit NON-adjacent earlier road? (Its own intended
## self-crossing is fine — sim samples aren't in the grid yet, so only pre-stunt
## road is tested, with the same clearance the random generator enforces.)
func _stunt_fits(sim: Dictionary, i: int) -> bool:
	var clear := 2.0 * (road_half_turn + mesh_verge) + 8.0
	var pxs: PackedFloat32Array = sim.px
	var pzs: PackedFloat32Array = sim.pz
	for k in range(pxs.size()):
		if _grid_near(pxs[k], pzs[k], i - 45, clear):
			return false
	return true

## Anchor the feature's analytic elevation/bank profile at s0 and record it.
## Elevation is H·(smoothstep(u0,u1,s) − smoothstep(d0,d1,s)) — C1 everywhere,
## zero (with zero slope) at both feature ends. The whole feature also flattens
## the base hills toward a fixed level (lvl) via _stunt_w, so crossing clearances
## are exact by construction instead of at the mercy of the noise field.
func _register_feature(st: Dictionary, pieces: Array, sim: Dictionary, s0: float) -> void:
	var total := 0
	for p in pieces:
		total += int(p.len)
	var s1 := s0 + float(total) * STEP
	var f := {
		"kind": str(st.kind), "s0": s0, "s1": s1,
		"lvl": _base_hill(s0 + 60.0, 0.0, road_half),
		"h": 0.0, "u0": s0, "u1": s0, "d0": s1, "d1": s1,
		"b0": 0.0, "b1": 0.0, "bin": 100.0, "bslope": 0.0,
		"minclear": INF, "crossings": 0,
	}
	var len0 := int(pieces[0].len)
	match str(st.kind):
		"overpass":
			# find where the turn/exit passes back over the approach piece
			var pxs: PackedFloat32Array = sim.px
			var pzs: PackedFloat32Array = sim.pz
			var lim := road_half_turn + road_half + 6.0
			var lim2 := lim * lim
			var c0 := INF
			var c1 := -INF
			for m in range(len0 + 20, pxs.size()):
				for a in range(len0):
					var dx := pxs[m] - pxs[a]
					var dz := pzs[m] - pzs[a]
					if dx * dx + dz * dz < lim2:
						var sm := s0 + float(m + 1) * STEP
						c0 = minf(c0, sm)
						c1 = maxf(c1, sm)
						break
			if c0 == INF:
				push_warning("HCTrack: overpass found no self-crossing — flat feature")
			else:
				f.h = stunt_clearance
				f.u0 = s0 + float(len0) * STEP   # climb through the turn...
				f.u1 = maxf(c0 - 8.0, f.u0 + 80.0)   # ...topping out before the bridge
				f.d0 = c1 + 8.0
				f.d1 = f.d0 + 120.0
		"corkscrew":
			var coil_n := int(pieces[1].len)
			f.h = _cork_h(clampi(int(float(st.get("p1", 2.0))), 1, 3))
			f.u0 = s0 + 4.0
			f.u1 = s0 + float(len0) * STEP - 110.0   # top out early: flat hold to the coil
			f.d0 = s0 + float(len0) * STEP
			f.d1 = f.d0 + float(coil_n) * STEP   # descend across the whole helix...
			f.lin = true                          # ...at CONSTANT pitch (see _lin_ease)
			f.b0 = f.d0 + 100.0
			f.b1 = f.d1 - 60.0
			f.bslope = -signf(float(pieces[1].kappa)) * tan(deg_to_rad(stunt_bank_deg))
		"loop":
			# GROUND elevation profile stays zero (h=0 defaults): the loop only
			# flattens the hills to lvl via _stunt_w. The vertical circle itself is
			# an analytic frame anchored at the tangent point: entry at ent (lat 0),
			# circle in the road's vertical plane, ribbon centre-line drifting
			# lp_shift metres sideways across the wrap so the exit ramp lands next
			# to (never inside) the entry ramp. All of it lives in lp_* keys read by
			# loop_state()/_loop_point(); the heightfield never sees the ribbon.
			var rl: float = clampf(float(st.get("p1", 11.0)), 8.0, 16.0)
			var len0m: float = float(len0) * STEP
			var m := int(round((len0m + rl + 8.0) / STEP)) - 1   # sim index of the tangent point
			var pxs2: PackedFloat32Array = sim.px
			var pzs2: PackedFloat32Array = sim.pz
			m = clampi(m, 1, pxs2.size() - 2)
			var fv := Vector3(pxs2[m + 1] - pxs2[m], 0.0, pzs2[m + 1] - pzs2[m]).normalized()
			f.loop = true
			f.lp_R = rl
			f.lp_half = LOOP_HALF
			f.lp_shift = 2.0 * LOOP_HALF + LOOP_GAP   # exit ramp daylight past the entry ramp
			f.lp_ent = s0 + float(m + 1) * STEP        # arc-length of the tangent point
			f.lp_e = Vector3(pxs2[m], float(f.lvl), pzs2[m])   # ground there is exactly lvl (w=1)
			f.lp_f = fv
			f.lp_r = Vector3(-fv.z, 0.0, fv.x)         # road right (heading frame convention)
			f.lp_i = int(round(s0 / STEP)) + m + 1     # global path sample at the tangent point
			f.lp_tile = int(f.lp_i) / TILE_SAMPLES     # tile that builds the ribbon mesh
			_has_loop = true
	_features.append(f)
	_verify_feature(f, sim, s0)

## Numerically verify the crossing clearances the profile promises, and link the
## tile pairs that overlap in (x,z) so streaming keeps a bridge deck alive while
## the car drives the road underneath it (and vice versa).
func _verify_feature(f: Dictionary, sim: Dictionary, s0: float) -> void:
	if bool(f.get("loop", false)):
		_verify_loop(f)
		return
	var pxs: PackedFloat32Array = sim.px
	var pzs: PackedFloat32Array = sim.pz
	var i0 := int(round(s0 / STEP))
	var lim := 2.0 * road_half_turn
	var lim2 := lim * lim
	var minclear := INF
	var crossings := 0
	for m in range(pxs.size()):
		for a in range(m - 45):
			var dx := pxs[m] - pxs[a]
			var dz := pzs[m] - pzs[a]
			if dx * dx + dz * dz < lim2:
				var sm := s0 + float(m + 1) * STEP
				var sa := s0 + float(a + 1) * STEP
				var dh := absf(_f_elev(f, sm) - _f_elev(f, sa))
				minclear = minf(minclear, dh)
				crossings += 1
				_link_tiles(i0 + m + 1, i0 + a + 1)
	f.minclear = minclear
	f.crossings = crossings
	if crossings > 0 and minclear < 6.0:
		push_warning("HCTrack: stunt '%s' clearance %.1fm < 6m" % [str(f.kind), minclear])

func _link_tiles(ia: int, ib: int) -> void:
	var ta := ia / TILE_SAMPLES
	var tb := ib / TILE_SAMPLES
	if ta == tb:
		return
	if not _tile_partners.has(ta):
		_tile_partners[ta] = {}
	if not _tile_partners.has(tb):
		_tile_partners[tb] = {}
	_tile_partners[ta][tb] = true
	_tile_partners[tb][ta] = true

# --- loop-de-loop analytic frame -------------------------------------------------

## Ribbon centre-line point of loop feature f at wrap angle th (0 = ground tangent,
## PI = inverted apex, TAU = shifted exit tangent), lateral offset lat off-centre.
## The lateral drift is smoothstep(th/TAU) — zero SLOPE at both tangents, so the
## ribbon leaves and rejoins the road pointing dead ahead (C1 in every component).
func _loop_point(f: Dictionary, th: float, lat: float) -> Vector3:
	var e: Vector3 = f.lp_e
	var fv: Vector3 = f.lp_f
	var rv: Vector3 = f.lp_r
	var rl: float = f.lp_R
	var sh: float = float(f.lp_shift) * smoothstep(0.0, 1.0, clampf(th / TAU, 0.0, 1.0))
	return e + fv * (rl * sin(th)) + Vector3.UP * (rl * (1.0 - cos(th))) + rv * (sh + lat)

## Build-time numeric verification of the loop ribbon (the corkscrew's discipline):
##  · wrap clearance — the entry and exit ramps share the same forward positions
##    near the ground, so centre-line points far apart ALONG the ribbon must stay
##    at least a full deck width apart in 3-D (the lateral shift is what buys it);
##  · over-road clearance — everywhere the ribbon hangs over the flat road below
##    (past its own merge ramps), record the drive-under headroom;
##  · partner-link the anchor tile with every tile under the footprint so the
##    ribbon streams with the ground it shadows.
func _verify_loop(f: Dictionary) -> void:
	var steps := 128
	var rl: float = f.lp_R
	var pts: Array[Vector3] = []
	for k in range(steps + 1):
		pts.append(_loop_point(f, TAU * float(k) / float(steps), 0.0))
	var wrap := INF
	for a in range(steps + 1):
		for b in range(a + 1, steps + 1):
			if b - a < steps / 4:
				continue   # under a quarter-wrap apart the circle's own chord governs
				           # (2R·sin(sep/2) >= R√2 — never a clash); the risk pairs are
				           # entry vs exit ramp, nearly a full wrap apart
			wrap = minf(wrap, pts[a].distance_to(pts[b]))
	var need := 2.0 * float(f.lp_half) + 1.0
	f.wrapclear = wrap
	if wrap < need:
		push_warning("HCTrack: loop wrap clearance %.1fm < %.1fm" % [wrap, need])
	var mc := INF
	var cross := 0
	for k in range(steps + 1):
		var hh: float = pts[k].y - float(f.lvl)
		if hh >= 6.0:   # past the merge ramps: this is deck hanging over drivable road
			cross += 1
			mc = minf(mc, hh)
	f.crossings = cross
	f.minclear = mc
	var span := int(ceil(rl / STEP)) + 3
	for j in range(int(f.lp_i) - span, int(f.lp_i) + span + 1):
		_link_tiles(int(f.lp_i), j)

## Loop-ride query for HCCar (duck-typed): is pos inside a loop stunt's zone, and
## where on the wrap is it? th is the RAW angle (-PI..PI] — the car unwraps it
## against its own running angle, so entry (th~0) vs exit (th~TAU) is the CAR's
## state, not a property of space. "mouth" flags the mount window: just past the
## ground tangency, at the ribbon's radius, where ribbon and road agree to a few
## centimetres — mounting there is seamless by construction.
func loop_state(pos: Vector3) -> Dictionary:
	if not _has_loop:
		return {"active": false}
	for f in _features:
		if not bool(f.get("loop", false)):
			continue
		var rl: float = f.lp_R
		var e: Vector3 = f.lp_e
		var q: Vector3 = pos - e - Vector3.UP * rl   # relative to the circle centre
		var qf: float = q.dot(f.lp_f)
		var ql: float = q.dot(f.lp_r)
		var shf: float = float(f.lp_shift)
		if absf(qf) > rl + 9.0 or q.y > rl + 7.0 or q.y < -rl - 9.0:
			continue
		if ql < minf(0.0, shf) - float(f.lp_half) - 9.0 or ql > maxf(0.0, shf) + float(f.lp_half) + 9.0:
			continue
		var th := atan2(qf, -q.y)
		var r := sqrt(qf * qf + q.y * q.y)
		var sh: float = shf * smoothstep(0.0, 1.0, clampf(th / TAU, 0.0, 1.0))
		return {
			"active": true, "th": th, "r": r, "lat": ql - sh,
			"R": rl, "half": float(f.lp_half), "shift": shf,
			"e": e, "fwd": f.lp_f, "right": f.lp_r,
			"mouth": th > -0.02 and th < 0.5 and absf(r - rl) < 0.9,
		}
	return {"active": false}

# --- stunt analytic profiles (pure functions of s — nothing sampled/interpolated) --

## Corkscrew total height: one coil needs extra pitch (the single 360° wrap and the
## ramp pinch both eat into it), taller stacks scale by 10 m per coil.
func _cork_h(coils: int) -> float:
	return maxf(12.0, 10.0 * float(coils))

## C1 "linear with eased ends" 0..1 ramp (ease = first/last 10% of the span). The
## corkscrew DESCENT uses this instead of smoothstep: smoothstep's zero-slope ends
## would pinch the vertical gap between stacked coils (and against the entry ramp
## alongside the first coil) well below the clearance floor — constant mid-pitch
## keeps every wrap-to-wrap gap ~equal.
func _lin_ease(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	var a := 0.1
	var norm := 1.0 - a          # integral of the trapezoid velocity profile
	if t < a:
		return t * t / (2.0 * a * norm)
	if t > 1.0 - a:
		var u := 1.0 - t
		return 1.0 - u * u / (2.0 * a * norm)
	return (t - a * 0.5) / norm

## Elevation of feature f at arc-length s (0 at both feature ends, C1 everywhere).
func _f_elev(f: Dictionary, s: float) -> float:
	var up := smoothstep(float(f.u0), float(f.u1), s)
	var down: float
	if bool(f.get("lin", false)):
		down = _lin_ease((s - float(f.d0)) / maxf(float(f.d1) - float(f.d0), 1.0))
	else:
		down = smoothstep(float(f.d0), float(f.d1), s)
	return float(f.h) * (up - down)

## Signed bank cross-slope (dh per +lat metre) of feature f at s.
func _f_bank(f: Dictionary, s: float) -> float:
	var bs: float = float(f.bslope)
	if bs == 0.0:
		return 0.0
	return bs * (smoothstep(float(f.b0), float(f.b0) + float(f.bin), s) - smoothstep(float(f.b1) - float(f.bin), float(f.b1), s))

## How much the feature owns the ground at s (blends base hills -> flat lvl+profile).
func _stunt_w(f: Dictionary, s: float) -> float:
	return smoothstep(float(f.s0), float(f.s0) + 60.0, s) * (1.0 - smoothstep(float(f.s1) - 110.0, float(f.s1), s))

## 0..1 "this is an elevated bridge deck, not ground" factor at s — drives the
## deck meshing (narrow ribbon, underside slab, no grass/scatter).
func _deck_at(s: float) -> float:
	var dk := 0.0
	for f in _features:
		if s > float(f.s0) and s < float(f.s1):
			dk = maxf(dk, smoothstep(2.5, 6.0, _f_elev(f, s)))
	return dk

## Is s inside any stunt feature's span (+margin)? Gaps must never share ground
## with a stunt (their carve + the stunt flatten would fight).
func _in_stunt_span(s: float, margin := 0.0) -> bool:
	for f in _features:
		if s > float(f.s0) - margin and s < float(f.s1) + margin:
			return true
	return false

# --- overlap height reconciliation ---------------------------------------------
# THE random-pop fix. The generator's hard no-overlap clearance only applies to
# NON-adjacent road (index gap > 45); a tight hairpin (radius < the widened
# half-width, e.g. canyon's R26 vs half 32) legitimately pinches its own two legs
# — and its apex — into overlapping ribbons at DIFFERENT noise heights. A wheel
# query drifting wide there used to snap between the legs' surfaces: a
# discontinuous ground step under one wheel = spring spike = the random hop.
# Fix in two halves: (1) here, cancel ~most of the height DISAGREEMENT with
# smooth cosine-windowed patches so overlapping decks nearly agree; (2) at query
# time, _surface_blend rides overlaps continuously instead of snapping.
func _reconcile_overlaps() -> void:
	for _pass in range(2):   # second pass mops up what the windowing under-corrects
		var mism := PackedFloat32Array(); mism.resize(_n)
		var cnt := PackedInt32Array(); cnt.resize(_n)
		var found := false
		for i in range(_n - 11):
			# overlaps need real curvature inside the window — skip pure straights
			if _pw[i] < 0.03 and _pw[mini(i + 24, _n - 1)] < 0.03 and _pw[mini(i + 45, _n - 1)] < 0.03:
				continue
			var si := float(i) * STEP
			if _in_stunt_span(si, 40.0):
				continue   # stunts manage their own crossings (big, verified clearances)
			var rh_i := lerpf(road_half, road_half_turn, _pw[i])
			for j in range(i + 11, mini(i + 46, _n)):
				var dx := _px[j] - _px[i]
				var dz := _pz[j] - _pz[i]
				var lim := rh_i + lerpf(road_half, road_half_turn, _pw[j]) + 10.0
				if dx * dx + dz * dz >= lim * lim:
					continue
				var sj := float(j) * STEP
				if _in_stunt_span(sj, 40.0):
					continue
				var hi := _center_h(i)
				var hj := _center_h(j)
				if absf(hi - hj) > 5.5:
					continue   # a deliberate deck-over-road — leave it alone
				mism[i] += hj - hi; cnt[i] += 1
				mism[j] += hi - hj; cnt[j] += 1
				found = true
		if not found:
			break
		_emit_ovl_patches(mism, cnt)
	_measure_ovl_residual()   # record the worst remaining disagreement for probes

## Centre-line height at sample i including any patches placed so far.
func _center_h(i: int) -> float:
	var s := float(i) * STEP
	var rh := lerpf(road_half, road_half_turn, _pw[i])
	return _base_hill(s, 0.0, rh) + _ovl_off(s)

## Cluster the flagged samples and fit one smooth linear-trend cosine patch per
## cluster (gain 0.7 of the half-gap — intentionally imperfect so overlapping
## decks land CLOSE but not coplanar, which would z-fight).
func _emit_ovl_patches(mism: PackedFloat32Array, cnt: PackedInt32Array) -> void:
	var i := 0
	while i < _n:
		if cnt[i] == 0:
			i += 1
			continue
		var a := i
		var b := i
		var gap := 0
		var j := i + 1
		while j < _n and gap <= 8:
			if cnt[j] > 0:
				b = j
				gap = 0
			else:
				gap += 1
			j += 1
		# least-squares linear fit of the desired offsets across the cluster
		var sc := (float(a) + float(b)) * 0.5 * STEP
		var sum_o := 0.0; var sum_od := 0.0; var sum_dd := 0.0; var m := 0
		for k in range(a, b + 1):
			if cnt[k] == 0:
				continue
			var o: float = 0.7 * 0.5 * mism[k] / float(cnt[k])   # half each leg, 0.7 gain
			var dd := float(k) * STEP - sc
			sum_o += o; sum_od += o * dd; sum_dd += dd * dd; m += 1
		if m > 0:
			var pa: float = clampf(sum_o / float(m), -3.0, 3.0)
			var pb: float = clampf(sum_od / sum_dd, -0.08, 0.08) if sum_dd > 1.0 else 0.0
			_ovl.append({"sc": sc, "w": (float(b - a) * 0.5) * STEP + 30.0, "a": pa, "b": pb})
		i = b + 1

## Worst remaining centre-height disagreement across all detected overlaps.
func _measure_ovl_residual() -> void:
	_ovl_resid = 0.0
	if _ovl.is_empty():
		return
	for i in range(_n - 11):
		if _pw[i] < 0.03 and _pw[mini(i + 24, _n - 1)] < 0.03 and _pw[mini(i + 45, _n - 1)] < 0.03:
			continue
		if _in_stunt_span(float(i) * STEP, 40.0):
			continue
		var rh_i := lerpf(road_half, road_half_turn, _pw[i])
		for j in range(i + 11, mini(i + 46, _n)):
			var dx := _px[j] - _px[i]
			var dz := _pz[j] - _pz[i]
			var lim := rh_i + lerpf(road_half, road_half_turn, _pw[j]) + 10.0
			if dx * dx + dz * dz >= lim * lim:
				continue
			if _in_stunt_span(float(j) * STEP, 40.0):
				continue
			var d := absf(_center_h(i) - _center_h(j))
			if d <= 5.5:
				_ovl_resid = maxf(_ovl_resid, d)

## Summed smooth patch offset at arc-length s (analytic: cosine windows, C1).
func _ovl_off(s: float) -> float:
	var off := 0.0
	for p in _ovl:
		var d: float = s - float(p.sc)
		var w: float = float(p.w)
		if absf(d) < w:
			off += (float(p.a) + float(p.b) * d) * (0.5 + 0.5 * cos(PI * d / w))
	return off

## Debug/probe: what the stunts plan + overlap pass actually produced.
func stunt_report() -> Dictionary:
	return {
		"features": _features,
		"placed": _plan_placed,
		"planned": _plan.size(),
		"patches": _ovl.size(),
		"overlap_residual": _ovl_resid,
		"partner_tiles": _tile_partners.size(),
		"creep_xing": _creep_xing,
		"creep_total": _creep_total,
	}

## Debug/probe: world centre-line point at arc-length s (top of the drivable deck).
func point_at_s(s: float) -> Vector3:
	if _n == 0:
		return Vector3.ZERO
	var fi := clampf(s / STEP, 0.0, float(_n - 1))
	var i := int(fi)
	var t := fi - float(i)
	var j := mini(i + 1, _n - 1)
	var rh := lerpf(road_half, road_half_turn, lerpf(_pw[i], _pw[j], t))
	return Vector3(lerpf(_px[i], _px[j], t), _carved_height(s, 0.0, rh), lerpf(_pz[i], _pz[j], t))

# --- projection (world pos -> path sample) -----------------------------------
## Nearest sample to (x,z) searching OUTWARD from `hint` — iteration order matters:
## where the road passes over/near itself, two samples on different passes can be
## exactly equidistant (a crossing point), and outward iteration with a strict
## comparison resolves the tie to the index-closest one (the pass the target is
## already on) instead of arbitrarily. Unique minima are unaffected. If the target
## isn't near the hint (e.g. it just RESPAWNED far away), fall back to a global
## grid search so the projection snaps to wherever it actually is.
func _nearest_from(x: float, z: float, hint: int) -> int:
	var h0 := clampi(hint, 0, _n - 1)
	var best := h0
	var bestd := INF
	for off in range(0, 41):
		var j := h0 + off
		if j < _n:
			var dx: float = _px[j] - x; var dz: float = _pz[j] - z
			var d := dx * dx + dz * dz
			if d < bestd:
				bestd = d; best = j
		if off > 0:
			j = h0 - off
			if j >= 0:
				var dx2: float = _px[j] - x; var dz2: float = _pz[j] - z
				var d2 := dx2 * dx2 + dz2 * dz2
				if d2 < bestd:
					bestd = d2; best = j
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

## Signed lateral offset PLUS the road's own right-vector at pos — for callers that
## need a DIRECTION to correct toward (not just the absolute distance lateral_off
## gives), e.g. HCCar's airborne landing-zone guidance nudge.
func lateral_vec(pos: Vector3) -> Dictionary:
	var p := _project(pos.x, pos.z)
	return {"lat": p.lat, "right": Vector3(cos(p.h), 0.0, sin(p.h))}

## Ground height at an arbitrary world (x,z) — rolling hills + carved jumps.
## Continuous everywhere (segment-projected s/lat), so finite-difference
## gradients over it are smooth — safe for suspension and ramp launches.
## Where several surfaces stack (bridge over road), this hint-less form returns
## the LOWEST claiming surface — the conservative answer for its callers (the
## camera floor clamp must never teleport the camera on top of an overpass the
## car is driving under).
func height_at(x: float, z: float) -> float:
	if _n == 0:
		return 0.0
	var cands := _branch_samples(x, z)
	if cands.size() > 1:
		var best := INF
		for ci in cands:
			var pc := _project_at(ci, x, z)
			var rhc: float = lerpf(road_half, road_half_turn, pc.w)
			if absf(pc.lat) > rhc + 8.0:
				continue
			best = minf(best, _carved_height(pc.s, pc.lat, rhc))
		if best < INF:
			return best
	var p := _project_at(_nearest_grid(x, z), x, z)
	var rh: float = lerpf(road_half, road_half_turn, p.w)
	return _carved_height(p.s, p.lat, rh)

## Height of the surface a body AT height y_hint would ride at (x,z) — the same
## blended field the wheels use, so HCCar's anti-tunnel floor and the springs
## always agree about where "the ground" is.
func height_at_y(x: float, z: float, y_hint: float) -> float:
	if _n == 0:
		return 0.0
	var cands := _branch_samples(x, z)
	if cands.size() <= 1:
		var i := cands[0] if cands.size() == 1 else _nearest_grid(x, z)
		var p := _project_at(i, x, z)
		return _carved_height(p.s, p.lat, lerpf(road_half, road_half_turn, p.w))
	var b := _surface_blend(cands, x, z, y_hint)
	if float(b.wsum) <= 0.0:
		return -1e6   # under every deck with no ground below: free air
	return b.h

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
	return _ground_from(_project(x, z))

## ground_info with the querier's height: where several road surfaces stack at one
## (x,z) (overpass decks, corkscrew coils, hairpin legs pinching together), the
## candidates are blended CONTINUOUSLY with y_hint disambiguating which deck is
## "the ground" (a surface far above the querier is a roof, not a floor). With a
## single candidate this is exactly ground_info — bit-identical on plain road.
func ground_info_y(x: float, z: float, y_hint: float) -> Dictionary:
	if _n == 0:
		return {"h": 0.0, "n": Vector3.UP}
	var cands := _branch_samples(x, z)
	if cands.size() == 1:
		_proj_i = cands[0]   # keep the stateful hint glued to the ridden branch
		return _ground_from(_project_at(cands[0], x, z))
	if cands.is_empty():
		return _ground_from(_project(x, z))   # off-mesh: classic stateful fallback
	var b := _surface_blend(cands, x, z, y_hint)
	if float(b.wsum) <= 0.0:
		return {"h": -1e6, "n": Vector3.UP}   # under everything: free air
	var bp: Dictionary = b.p
	if not bp.is_empty():
		_proj_i = int(bp.i)
	# world-frame gradient of the blended field (same candidate set, offset points)
	var e := 0.9
	var hx1: float = _surface_blend(cands, x + e, z, y_hint).h
	var hx0: float = _surface_blend(cands, x - e, z, y_hint).h
	var hz1: float = _surface_blend(cands, x, z + e, y_hint).h
	var hz0: float = _surface_blend(cands, x, z - e, y_hint).h
	var gx := clampf((hx1 - hx0) / (2.0 * e), -4.0, 4.0)
	var gz := clampf((hz1 - hz0) / (2.0 * e), -4.0, 4.0)
	return {"h": b.h, "n": Vector3(-gx, 1.0, -gz).normalized()}

## The classic single-surface ground answer from a finished projection: height plus
## a normal from partial derivatives in the road frame (forward = +s, right = +lat).
func _ground_from(p: Dictionary) -> Dictionary:
	var s: float = p.s
	var lat: float = p.lat
	var rh: float = lerpf(road_half, road_half_turn, p.w)
	var h := _carved_height(s, lat, rh)
	var e := 0.9
	# Clamped the same way ground_info_y's multi-surface blend already does (that path
	# never had this bug — only the single-surface path was missing the clamp). A gap's
	# void/landing edges are DELIBERATE near-vertical cliffs in the height field (a car
	# is meant to be flying well clear of them, never actually touching down there); an
	# unclamped finite-difference straddling one spikes to a huge slope, which collapses
	# the normal's n.y toward zero. HCCar._suspend_analytic's compression distance
	# divides by (roughly) n.y, so a tiny n.y makes a car several METRES clear of the
	# ground read as merely grazing it — a maxed-speed launch over a narrow void (fast
	# = LESS time to climb, see HCTrack._safe_land_rise) lands squarely in that few-
	# metre band and takes catastrophic "landing" damage while still plainly airborne.
	var dh_ds := clampf((_carved_height(s + e, lat, rh) - _carved_height(s - e, lat, rh)) / (2.0 * e), -4.0, 4.0)
	var dh_dl := clampf((_carved_height(s, lat + e, rh) - _carved_height(s, lat - e, rh)) / (2.0 * e), -4.0, 4.0)
	var hd: float = p.h                             # continuous heading (no 4 m steps)
	var fx := sin(hd); var fz := -cos(hd)           # world forward
	var rx := cos(hd); var rz := sin(hd)            # world right
	var n := Vector3(-(dh_ds * fx + dh_dl * rx), 1.0, -(dh_ds * fz + dh_dl * rz)).normalized()
	return {"h": h, "n": n}

## Candidate road branches near (x,z): every LOCAL MINIMUM of centre-line distance
## along the sample-index sequence (runs split at index gaps). One winning sample
## per branch. A straight has one minimum; a hairpin whose legs pinch together has
## two; a corkscrew column has one per coil. Plain road far from any self-approach
## always yields exactly one — the same sample the classic projection picks.
func _branch_samples(x: float, z: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var c := _cell(x, z)
	var idxs: Array = []
	for dx in range(-2, 3):
		for dz in range(-2, 3):
			var key := Vector2i(c.x + dx, c.y + dz)
			if not _grid.has(key):
				continue
			for j in _grid[key]:
				var ddx: float = _px[j] - x
				var ddz: float = _pz[j] - z
				if ddx * ddx + ddz * ddz < 2025.0:   # 45 m gather radius
					idxs.append(j)
	if idxs.is_empty():
		return out
	idxs.sort()
	# walk runs (split at index gaps > 8) and keep each run's local d2 minima
	var run: Array = []
	var prev := -100
	for j in idxs:
		if j - prev > 8 and not run.is_empty():
			out.append_array(_run_minima(run, x, z))
			run.clear()
		run.append(j)
		prev = j
	if not run.is_empty():
		out.append_array(_run_minima(run, x, z))
	return out

## Local minima of centre-distance² along one contiguous index run, merging
## minima within 8 samples (plateau ties) keeping the closest.
func _run_minima(run: Array, x: float, z: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var n := run.size()
	var ds := PackedFloat32Array(); ds.resize(n)
	for k in range(n):
		var j: int = run[k]
		var ddx: float = _px[j] - x
		var ddz: float = _pz[j] - z
		ds[k] = ddx * ddx + ddz * ddz
	var last_j := -1000
	var last_d := INF
	for k in range(n):
		var lo_ok: bool = k == 0 or ds[k] <= ds[k - 1]
		var hi_ok: bool = k == n - 1 or ds[k] <= ds[k + 1]
		if lo_ok and hi_ok:
			var j: int = run[k]
			if j - last_j <= 8:
				if ds[k] < last_d:   # plateau/near-tie: keep the closer sample
					out[out.size() - 1] = j
					last_j = j
					last_d = ds[k]
				continue
			out.append(j)
			last_j = j
			last_d = ds[k]
	return out

## Blend the candidate surfaces at (x,z) into ONE continuous ground height.
## Weights per candidate (all continuous in x, z and y_hint, so the blended field
## can never step under a wheel):
##  · a lateral claim fade past the branch's drivable edge (+2..+8 m) — driving
##    off a bridge deck's side becomes "no support", i.e. a real fall;
##  · a distance taper (35..45 m) so branches entering the gather radius arrive
##    with zero weight;
##  · a normalised ASYMMETRIC exponential around y_hint: surfaces below the
##    querier decay gently (1/1.2 per m — the highest below wins, so overlapping
##    near-equal decks blend and you ride the one that renders on top), while
##    surfaces above a 1.5 m dead-band decay HARD (1/0.35 per m — an overpass
##    roof is not a floor). The above-rate strictly exceeding the below-rate is
##    what makes runaway impossible: no ceiling can out-score a floor by being
##    higher, which an absolute softmax-over-height allowed (h_eff crept up,
##    opening the ceiling's gate further — positive feedback).
## Returns {"h": blended height, "p": dominant projection, "wsum": total weight}.
func _surface_blend(cands: PackedInt32Array, x: float, z: float, y_hint: float) -> Dictionary:
	var hs := PackedFloat32Array()
	var gs := PackedFloat32Array()   # lat/distance gates
	var es := PackedFloat32Array()   # log-space y-affinity (normalised before exp)
	var ps: Array = []
	var emax := -INF
	for ci in cands:
		var p := _project_at(ci, x, z)
		var rh: float = lerpf(road_half, road_half_turn, p.w)
		var h := _carved_height(p.s, p.lat, rh)
		var g := 1.0 - smoothstep(rh + 2.0, rh + 8.0, absf(p.lat))
		var ddx: float = _px[ci] - x
		var ddz: float = _pz[ci] - z
		g *= 1.0 - smoothstep(1225.0, 2025.0, ddx * ddx + ddz * ddz)
		var e: float
		if is_nan(y_hint):
			e = h / 1.2   # no querier height: plain prefer-the-upper-deck softmax
		else:
			e = -maxf(0.0, y_hint - h) / 1.2 - maxf(0.0, h - y_hint - 1.5) / 0.35
		hs.append(h)
		gs.append(g)
		es.append(e)
		ps.append(p)
		if g > 0.0001:
			emax = maxf(emax, e)
	if emax == -INF:
		return {"h": -1e6, "p": {}, "wsum": 0.0}
	var num := 0.0
	var den := 0.0
	var best_w := -1.0
	var best_p: Dictionary = {}
	for k in range(hs.size()):
		var w: float = gs[k] * exp(clampf(es[k] - emax, -60.0, 0.0))
		num += w * hs[k]
		den += w
		if w > best_w:
			best_w = w
			best_p = ps[k]
	if den <= 0.0:
		return {"h": -1e6, "p": {}, "wsum": 0.0}
	return {"h": num / den, "p": best_p, "wsum": den}

## Base rolling-hill height (no jumps) at distance s, lateral lat.
func _base_hill(s: float, lat: float, rh: float) -> float:
	var amp := lerpf(3.0, hill_amp, clampf(s / 450.0, 0.0, 1.0))
	var prof := _noise.get_noise_1d(s)
	var edge := smoothstep(rh, rh + edge_falloff, absf(lat))
	return prof * lerpf(amp, amp * 0.1, edge)

## Hill height with any jump (ramp -> void -> landing) carved into the road at s,
## plus overlap-reconcile patches and any stunt feature's elevation/bank profile.
## Every added term is an analytic C1 function of s (and linear in lat for bank),
## so the field stays as smooth as the base noise — no staircases, ever.
func _carved_height(s: float, lat: float, rh: float) -> float:
	var base := _base_hill(s, lat, rh)
	if not _ovl.is_empty():
		base += _ovl_off(s)
	var gi := _gap_index_at_s(s)
	if gi >= 0:
		var on_road := 1.0 - smoothstep(rh, rh + edge_falloff, absf(lat))
		if on_road >= 0.01:
			base = lerpf(base, _gap_profile(_gaps[gi], s), on_road)
	for f in _features:
		if s <= float(f.s0) or s >= float(f.s1):
			continue
		var w := _stunt_w(f, s)
		if w <= 0.0001:
			continue
		# inside a stunt the ground is a FLAT reference level + the feature's own
		# elevation/bank — hills are blended out so crossing clearances are exact
		base = lerpf(base, float(f.lvl) + _f_elev(f, s) + _f_bank(f, s) * lat, w)
	return base

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
		var land_top: float = lvl + float(g.get("lr", gap_land_rise))   # speed-safe rise (_safe_land_rise)
		var f: float = 1.0 - pow(1.0 - t2, 2.6)
		return lerpf(land_top, _base_hill(land1, 0.0, road_half), f)

# --- jump scheduling ---------------------------------------------------------
## Worst-case horizontal distance a maxed vehicle can cover between a ramp's launch
## lip and touching back down near launch height (see the const block above the gap
## exports) — a generous ballistic estimate (2*Vy/g hang time × Vx), not exact
## per-vehicle physics; that's the point, it has to cover EVERY vehicle.
func _max_jump_flight() -> float:
	return JUMP_VMAX_H * (2.0 * JUMP_VMAX_V / JUMP_GRAVITY_MIN)

## Landing-catch length for a void of width `vw`. The old wider-gap-grows-the-landing
## rule is kept (a wider void implies a faster, later-game jump) — NEW is the floor at
## a healthy fraction of the worst-case ballistic flight, so even the very first,
## narrowest gap gives a maxed-out car's worst-case launch a real downslope to settle
## onto, instead of skipping clean past a short landing onto the plain reserved
## straight beyond it.
func _landing_catch_len(vw: float) -> float:
	return maxf(gap_land_len + vw * 0.5, _max_jump_flight() * 0.4)

## Safe per-gap landing-PLATFORM rise for a void of width `vw`: land_top (lvl + this)
## must sit no higher than a worst-case-speed car is guaranteed to have climbed to by
## the time it reaches the void's far edge, or it slams into the platform's leading
## face (see the const block above). Ballistic estimate: time to cross the void at
## the worst-case horizontal speed, times the capped vertical launch speed, minus the
## usual quadratic sag and a flat safety clearance. Only ever REDUCES gap_land_rise
## (clampf's upper bound), never raises it — narrow early gaps get capped, wide late
## gaps (which give the climb far more time) keep the full tuned rise unchanged.
func _safe_land_rise(vw: float) -> float:
	var t_cross: float = vw / JUMP_VMAX_H
	var climb: float = JUMP_VMAX_V * t_cross - 0.5 * JUMP_GRAVITY_MIN * t_cross * t_cross
	return clampf(gap_ramp_rise + climb - JUMP_LAND_CLEARANCE, 0.0, gap_land_rise)

## At a segment boundary: if the next scheduled gap is due AND the segment that just
## finished was a plain straight (a fair, aligned run-up), reserve the gap's ENTIRE
## footprint — ramp, void, the speed-aware landing catch, and a worst-case-overshoot
## safety straight beyond it — as ONE dead-straight segment emitted right now.
## Claiming the frontier here (exactly like _try_stunt) is what makes the reservation
## real: no LATER turn decision can ever bend the road inside a window a max-speed
## launch needs — the actual fix for "you fly over the bend past the landing." Falls
## through (returns {}, no state change, no RNG use) whenever a gap isn't due yet —
## canyon (gap_start far past the whole track) takes this branch on every boundary and
## stays bit-identical to before this feature existed.
func _try_gap(x: float, z: float, th: float, prev_kappa: float, prev_widen: float, i: int) -> Dictionary:
	if _gap_idx >= 400:
		return {}
	var s0 := float(i) * STEP
	if s0 < _gap_next_s:
		return {}
	if prev_kappa != 0.0 or prev_widen > 0.12:
		return {}   # mid-turn (or its widen hasn't eased out yet) — wait for a real straight
	var vw: float = minf(gap_base_width + float(_gap_idx) * gap_grow, gap_max_width)
	var ll: float = _landing_catch_len(vw)
	var lr: float = _safe_land_rise(vw)
	var lip := s0 + gap_ramp_len
	var cs := lip + vw * 0.5
	var far := lip + vw
	var land1 := far + ll
	var reserve_end := maxf(land1, s0 + _max_jump_flight() + JUMP_RESERVE_MARGIN)
	var total_samp := maxi(int(round((reserve_end - s0) / STEP)), 1)
	if i + total_samp > N_MAX - 150:
		return {}   # too close to the track end — stop scheduling jumps
	if _seg_overlaps(x, z, th, 0.0, total_samp, i):
		_gap_next_s = s0 + 60.0   # boxed in by earlier road — try again a bit further on
		return {}
	_gaps.append({"cs": cs, "vw": vw, "ll": ll, "lr": lr, "lvl": _base_hill(cs, 0.0, road_half), "idx": _gap_idx})
	var i1 := clampi(int(round(land1 / STEP)), 0, N_MAX - 1)
	for k in range(i, i1 + 1):
		_gsamp[k] = _gap_idx
	_gap_idx += 1
	_gap_next_s = cs + gap_spacing + float(_gap_idx) * gap_spacing_grow
	return {"len": total_samp, "kappa": 0.0, "widen": 0.0}

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
	# height for THIS slot's stretch of road: seed with the row's own surface, then
	# resolve the blended field a car there would ride (a bare height_at could pick
	# a different deck where the track stacks over itself, burying the pickup)
	var rh := lerpf(road_half, road_half_turn, _pw[i])
	var own_h := _carved_height(s, off, rh)
	base.y = height_at_y(base.x, base.z, own_h + 1.5) + 1.4
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
	# read-only use of the hint: the physics-side ground queries own _proj_i (they
	# know which BRANCH the car rides where the road stacks over itself; a raw
	# 2-D-nearest write from here could flip it to the other deck at a crossing)
	var ci := _nearest_from(_target.global_position.x, _target.global_position.z, _proj_i)
	var ct := ci / TILE_SAMPLES
	var want := {}
	for t in range(ct - BEHIND_TILES, ct + AHEAD_TILES + 1):
		if t >= 0 and t * TILE_SAMPLES < _n - 1:
			want[t] = true
	# keep spatially-linked tiles alive too: a bridge deck must stay streamed while
	# the car drives the road underneath it, even when the deck's own arc-length
	# window has long moved on (and vice versa)
	if not _tile_partners.is_empty():
		var extra := {}
		for t in want:
			if _tile_partners.has(t):
				for u in _tile_partners[t]:
					if u >= 0 and u * TILE_SAMPLES < _n - 1:
						extra[u] = true
		for u in extra:
			want[u] = true
	# free tiles out of range
	for t in _tiles.keys():
		if not want.has(t):
			_tiles[t].queue_free()
			_tiles.erase(t)
			_tile_props.erase(t)
			_tile_prop_bounds.erase(t)
	# build up to a few missing tiles per frame (nearest first) to avoid hitches
	var keys := want.keys()
	keys.sort_custom(func(a, b): return absi(int(a) - ct) < absi(int(b) - ct))
	var built := 0
	for t in keys:
		if built >= 3:
			break
		if not _tiles.has(t):
			_build_tile(t)
			built += 1

func _mats() -> void:
	# cheap (3 adds) so recomputing every call is fine; catches a map override that
	# lands after the first tile build.
	_night = (grass_color.r + grass_color.g + grass_color.b) / 3.0 < 0.18
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
		# darker than the rail band's post-color stop — reads as dull steel, not paint
		_post_mat.albedo_color = rail_post_color.darkened(0.35)
		_post_mat.roughness = 0.75
		_post_mat.metallic = 0.25
	if _reflector_mat == null:
		_reflector_mat = StandardMaterial3D.new()
		_reflector_mat.albedo_color = rail_band_color
		_reflector_mat.emission_enabled = true
		_reflector_mat.emission = rail_band_color
		# subtle catch-the-light dot by day, a real glow once night auto-detects
		_reflector_mat.emission_energy_multiplier = 1.8 if _night else 0.2

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
	var und := SurfaceTool.new()   # bridge-deck underside + skirts (decks only)
	und.begin(Mesh.PRIMITIVE_TRIANGLES)
	var have_und := false
	var rows: Array = []       # per sample: Array of Vector3 cross-section points
	var half_mesh := road_half_turn + mesh_verge
	for i in range(i0, i1 + 1):
		var cx := _px[i]; var cz := _pz[i]
		var rx := cos(_ph[i]); var rz := sin(_ph[i])
		var d := float(i) * STEP
		var rh := lerpf(road_half, road_half_turn, _pw[i])
		# on an elevated deck the ground ribbon narrows to the road + a shoulder —
		# a bridge, not a floating slice of hillside (dk eases 0..1 so the taper
		# is smooth where a deck rises out of the ground)
		var dk := _deck_at(d)
		var hm := lerpf(half_mesh, rh + 3.0, dk)
		var pts: Array = []
		var cols: Array = []
		for fr in LAT_FR:
			var lat: float = float(fr) * hm
			var wx := cx + rx * lat
			var wz := cz + rz * lat
			var wy := _height_lat(d, lat, rh)
			pts.append(Vector3(wx, wy, wz))
			cols.append(_surface_color(d, lat, rh))
		rows.append({"p": pts, "c": cols, "rh": rh, "cx": cx, "cz": cz, "rx": rx, "rz": rz, "d": d, "void": _in_void_s(d), "dk": dk, "hm": hm, "i": i})
	# stitch rows into the ribbon + collision band
	for r in range(rows.size() - 1):
		var a: Dictionary = rows[r]
		var b: Dictionary = rows[r + 1]
		var over_void: bool = a.void or b.void   # no floor over a jump — the car falls in
		for k in range(LAT_FR.size() - 1):
			_quad(st, a.p[k], a.p[k + 1], b.p[k], b.p[k + 1], a.c[k], a.c[k + 1], b.c[k], b.c[k + 1])
			# collision across the drivable band (a bit past the rails so a slide still lands)
			var midlat: float = (float(LAT_FR[k]) + float(LAT_FR[k + 1])) * 0.5 * minf(float(a.hm), float(b.hm))
			if not over_void and absf(midlat) <= road_half_turn + 2.0:
				_quad(col, a.p[k], a.p[k + 1], b.p[k], b.p[k + 1], Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE)
		# bridge-deck slab: underside + side skirts so an overpass reads as a solid
		# deck from below (thickness scales with dk so it tapers out at the ends)
		if float(a.dk) > 0.02 or float(b.dk) > 0.02:
			have_und = true
			var ta := Vector3(0, 0.9 * float(a.dk) + 0.05, 0)
			var tb := Vector3(0, 0.9 * float(b.dk) + 0.05, 0)
			var cu := Color(0.30, 0.29, 0.28)
			var last := LAT_FR.size() - 1
			for k in range(last):
				_quad(und, a.p[k] - ta, a.p[k + 1] - ta, b.p[k] - tb, b.p[k + 1] - tb, cu, cu, cu, cu)
			var ce := Color(0.38, 0.37, 0.35)
			_quad(und, a.p[0], a.p[0] - ta, b.p[0], b.p[0] - tb, ce, cu, ce, cu)
			_quad(und, a.p[last], a.p[last] - ta, b.p[last], b.p[last] - tb, ce, cu, ce, cu)
	st.generate_normals()
	var container := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _road_mat
	container.add_child(mi)
	if have_und:
		und.generate_normals()
		var umi := MeshInstance3D.new()
		umi.mesh = und.commit()
		umi.material_override = _rail_mat   # vertex-coloured + double-sided
		container.add_child(umi)
	# rails down both edges (band + emissive cap + posts)
	_build_rail_side(container, rows, -1.0)
	_build_rail_side(container, rows, 1.0)
	# painted markings (dashed centre + solid edges) as crisp overlay strips
	container.add_child(_build_lines(rows))
	# roadside scatter (trees/rocks) — purely visual, verge band only
	_scatter_tile(t, rows, container)
	# chevron turn-warning boards — purely visual, outside edge of bends only
	_build_chevrons(t, container)
	# loop-de-loop ribbon: the anchor tile owns the whole circle (deck + underside +
	# curbs + camera-ray collision quads appended into this tile's trimesh)
	for f in _features:
		if bool(f.get("loop", false)) and int(f.lp_tile) == t:
			container.add_child(_build_loop_ribbon(f, col))
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

# lateral cross-section fractions for the loop ribbon (narrower than the road)
const LOOP_FR := [-1.0, -0.86, -0.45, 0.0, 0.45, 0.86, 1.0]

## The loop-de-loop's visible ribbon: a vertical-circle deck (asphalt top with
## painted edges and hazard-striped mouths), an underside slab 0.55 m outward, side
## skirts, and glowing curb lips along both edges so the ribbon reads at speed.
## Top-surface quads also go into `col` — the tile's camera-occlusion trimesh (the
## car never collides with tiles; it rides the analytic frame via loop_state).
## Double-sided rail material so winding/normals never matter on a surface that is
## seen from every direction including upside-down.
func _build_loop_ribbon(f: Dictionary, col: SurfaceTool) -> MeshInstance3D:
	_mats()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows := 110
	var half: float = f.lp_half
	var fv: Vector3 = f.lp_f
	var curb := Color(rail_band_color.r, rail_band_color.g, rail_band_color.b)
	var under := Color(0.30, 0.29, 0.28)
	var prev: Array = []
	var prev_out := Vector3.ZERO
	var prev_haz := Color.WHITE
	for k in range(rows + 1):
		var th := TAU * float(k) / float(rows)
		var n_out := fv * sin(th) - Vector3.UP * cos(th)   # away from the circle centre
		var lift := -n_out * 0.04   # float the ribbon a hair off the road at the tangents
		var pts: Array = []
		for fr in LOOP_FR:
			pts.append(_loop_point(f, th, float(fr) * half) + lift)
		# mouth zones get hazard stripes; the rest is asphalt with painted edges
		var mouth: bool = th < 0.55 or th > TAU - 0.55
		var vh := _noise.get_noise_1d(th * 40.0)
		var haz: Color = (Color(0.92, 0.78, 0.12) if (k / 3) % 2 == 0 else Color(0.1, 0.1, 0.11)) if mouth else _varied_asphalt(vh)
		if not prev.is_empty():
			for c2 in range(LOOP_FR.size() - 1):
				var edge_a: bool = absf(float(LOOP_FR[c2])) >= 0.86 and absf(float(LOOP_FR[c2 + 1])) >= 0.86
				var top_col: Color = edge_line_color if (edge_a and not mouth) else haz
				var top_col_p: Color = edge_line_color if (edge_a and not mouth) else prev_haz
				# deck top
				_quad(st, prev[c2], prev[c2 + 1], pts[c2], pts[c2 + 1], top_col_p, top_col_p, top_col, top_col)
				# camera-ray collision follows the top surface
				_quad(col, prev[c2], prev[c2 + 1], pts[c2], pts[c2 + 1], Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE)
				# underside slab
				var oa: Vector3 = prev_out * 0.55
				var ob: Vector3 = n_out * 0.55
				_quad(st, prev[c2] + oa, prev[c2 + 1] + oa, pts[c2] + ob, pts[c2 + 1] + ob, under, under, under, under)
			var last := LOOP_FR.size() - 1
			# side skirts closing top -> underside
			_quad(st, prev[0], prev[0] + prev_out * 0.55, pts[0], pts[0] + n_out * 0.55, under, under, under, under)
			_quad(st, prev[last], prev[last] + prev_out * 0.55, pts[last], pts[last] + n_out * 0.55, under, under, under, under)
			# curb lips: a bright rail rising toward the centre along both edges
			_quad(st, prev[0], prev[0] - prev_out * 0.45, pts[0], pts[0] - n_out * 0.45, curb, curb, curb, curb)
			_quad(st, prev[last], prev[last] - prev_out * 0.45, pts[last], pts[last] - n_out * 0.45, curb, curb, curb, curb)
		prev = pts
		prev_out = n_out
		prev_haz = haz
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _rail_mat   # vertex-coloured, sRGB, double-sided
	return mi

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
	var dk := _deck_at(d)
	if dk > 0.01:
		# elevated deck: the shoulder is concrete, not floating grass
		grass = grass.lerp(Color(0.46, 0.45, 0.43) * (1.0 + vh * 0.05), dk)
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
			return gap_pad_color.lerp(grass, smoothstep(rh - 1.5, rh + 1.0, al))
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

## W-beam cross-section profile: (height above the ground-contact point, lateral
## "bulge" toward the road) pairs tracing the classic corrugated guardrail silhouette
## bottom-to-top — a ridge, a valley, and a second ridge instead of one flat band.
## Cheap: 3 quads per row-pair instead of 1, still O(rows), no per-tile cost blowup.
const RAIL_PROFILE: Array[Vector2] = [
	Vector2(0.0, 0.0),
	Vector2(0.55, 0.22),
	Vector2(1.05, -0.16),
	Vector2(1.6, 0.12),
]
const RAIL_TOP_H := 1.6
const RAIL_FLARE_ROWS := 3   # rows of taper approaching a gap void's edge

## Per-profile-point vertex color: baked highlight on the ridge (index 1), baked
## shadow in the valley (index 2), dark steel base (0) rising to the bright accent
## band at the top (3, matching the emissive cap).
func _rail_band_color(profile_index: int) -> Color:
	match profile_index:
		0:
			return rail_post_color.darkened(0.15)
		1:
			return rail_post_color.lerp(rail_band_color, 0.6).lightened(0.4)
		2:
			return rail_post_color.darkened(0.55)
		_:
			return rail_band_color

## Builds one side's guardrail into `container`: a W-beam profile band (bottom-to-top
## gradient, grey posts to the glowing red/accent band), a thin emissive cap along the
## very top edge, tapered steel posts every couple of rows with small reflector dots
## (emissive at night), and a flare-to-ground taper approaching any gap void so the
## rail doesn't just stop mid-air at a jump's edge.
func _build_rail_side(container: Node3D, rows: Array, side: float) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cap := SurfaceTool.new()
	cap.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_pts: Array[Vector3] = []
	var prev_cols: Array[Color] = []
	var prev_cap_top := Vector3.ZERO
	var have := false
	var post_xforms: Array[Transform3D] = []
	var reflector_xforms: Array[Transform3D] = []
	var row_idx := 0
	var n_rows: int = rows.size()
	for ri in range(n_rows):
		var r: Dictionary = rows[ri]
		var rh: float = r.rh
		var lat0 := side * rh
		var flare := _rail_flare(rows, ri)
		var base_y := _height_lat(r.d, lat0, rh) - 0.3
		var pts: Array[Vector3] = []
		var cols: Array[Color] = []
		for pi in range(RAIL_PROFILE.size()):
			var pe: Vector2 = RAIL_PROFILE[pi]
			var h: float = pe.x * flare
			var lat: float = lat0 - side * pe.y * flare
			pts.append(Vector3(r.cx + r.rx * lat, base_y + h, r.cz + r.rz * lat))
			# Baked highlight/shadow banding (not a smooth height gradient): the ridge
			# facet is lightened as if catching light, the valley darkened as if in its
			# own shadow — this reads as corrugated metal even under flat/overcast
			# lighting, where the real geometry's shading alone would be too subtle.
			cols.append(_rail_band_color(pi))
		var cap_top := pts[pts.size() - 1] + Vector3(0, 0.25 * flare, 0)
		if have:
			for k in range(pts.size() - 1):
				_quad(st, prev_pts[k], prev_pts[k + 1], pts[k], pts[k + 1], prev_cols[k], prev_cols[k + 1], cols[k], cols[k + 1])
			var prev_top := prev_pts[prev_pts.size() - 1]
			var top := pts[pts.size() - 1]
			cap.set_color(rail_band_color); cap.add_vertex(prev_top)
			cap.set_color(rail_band_color); cap.add_vertex(prev_cap_top)
			cap.set_color(rail_band_color); cap.add_vertex(cap_top)
			cap.set_color(rail_band_color); cap.add_vertex(prev_top)
			cap.set_color(rail_band_color); cap.add_vertex(cap_top)
			cap.set_color(rail_band_color); cap.add_vertex(top)
		if row_idx % 2 == 0 and flare > 0.5:   # a post every other row (~8 m); skip near a flare-out
			_ensure_post_mesh()
			var yaw := atan2(r.rx, r.rz)   # align the post's thin axis across the road
			var pb := Basis(Vector3.UP, yaw)
			var post_base := Vector3(r.cx + r.rx * lat0, base_y, r.cz + r.rz * lat0)
			post_xforms.append(Transform3D(pb, post_base + Vector3(0, 0.5, 0)))
			# reflector dot nudged slightly toward the road so it isn't swallowed by the post
			var inward := Vector3(r.rx, 0, r.rz) * (-side) * 0.1
			reflector_xforms.append(Transform3D(Basis.IDENTITY, post_base + Vector3(0, 0.55, 0) + inward))
		prev_pts = pts; prev_cols = cols; prev_cap_top = cap_top; have = true
		row_idx += 1
	# FLAT (unsmoothed) normals: smooth normals would average away the exact crease
	# between profile segments (they share exact vertex positions at each seam),
	# erasing the W-beam's ridge/valley read — flat facets are also consistent with
	# this game's low-poly look elsewhere (road ribbon aside).
	st.generate_normals(false)
	cap.generate_normals(false)
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
		var rm := MultiMesh.new()
		rm.transform_format = MultiMesh.TRANSFORM_3D
		rm.mesh = _reflector_mesh
		rm.instance_count = reflector_xforms.size()
		for i in range(reflector_xforms.size()):
			rm.set_instance_transform(i, reflector_xforms[i])
		var rmi := MultiMeshInstance3D.new()
		rmi.multimesh = rm
		rmi.material_override = _reflector_mat
		rmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(rmi)

## Tapers a rail cross-section toward 0 (flat, at ground level) as it approaches a gap
## void's edge within RAIL_FLARE_ROWS rows, and pins it to exactly 0 inside the void —
## so the guardrail visually flares down into the ground at a jump instead of floating
## over open air. 1.0 = full-height rail, unaffected almost everywhere on the track.
func _rail_flare(rows: Array, ri: int) -> float:
	var r: Dictionary = rows[ri]
	if bool(r.void):
		return 0.0
	var dist := RAIL_FLARE_ROWS + 1
	for k in range(1, RAIL_FLARE_ROWS + 1):
		var lo_i := ri - k
		var hi_i := ri + k
		if (lo_i >= 0 and bool(rows[lo_i].void)) or (hi_i < rows.size() and bool(rows[hi_i].void)):
			dist = k
			break
	if dist > RAIL_FLARE_ROWS:
		return 1.0
	return float(dist) / float(RAIL_FLARE_ROWS + 1)

## Shared post + reflector meshes, built once. The post is a 4-sided CylinderMesh
## (a square prism from 4 radial segments) with a smaller top radius than bottom —
## a cheap taper that reads as a rolled-steel guardrail post instead of a fencepost.
func _ensure_post_mesh() -> void:
	if _post_mesh != null:
		return
	var post := CylinderMesh.new()
	post.top_radius = 0.075
	post.bottom_radius = 0.11
	post.height = 1.1
	post.radial_segments = 4
	_post_mesh = post
	var refl := SphereMesh.new()
	refl.radius = 0.055
	refl.height = 0.11
	refl.radial_segments = 6
	refl.rings = 3
	_reflector_mesh = refl

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
	var props := PackedFloat32Array()   # [x,y,z,coarse radius] per accepted prop (near-miss feed)
	for r in rows:
		if r.void or float(r.dk) > 0.05:
			continue   # no trees growing out of a bridge deck
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
			# THE trees-on-the-road fix: this point is verge relative to ITS row, but
			# where the track self-approaches (hairpin legs, an overpass above) the
			# same (x,z) can be DRIVABLE road of another stretch — reject those.
			if _claimed_by_other(wx, wz, int(r.i), 5.0):
				continue
			var wy: float = _carved_height(r.d, lat, rh)
			var s: float = rng.randf_range(0.8, 1.6) * float(_scatter_kind_scale.get(kind, 1.0))
			var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
			buckets[kind].append(Transform3D(b, Vector3(wx, wy, wz)))
			# coarse footprint for the near-miss check — trunk/boulder scale, not canopy
			props.push_back(wx)
			props.push_back(wy)
			props.push_back(wz)
			props.push_back(clampf(0.45 * s, 0.3, 1.4))
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
	# index this tile's props for props_near: centroid + bound radius lets a query
	# reject the whole tile with one distance check
	if props.size() > 0:
		var cx := 0.0
		var cz := 0.0
		var n := props.size() / 4
		for i in range(0, props.size(), 4):
			cx += props[i]
			cz += props[i + 2]
		cx /= float(n)
		cz /= float(n)
		var bound := 0.0
		for i in range(0, props.size(), 4):
			var dx: float = props[i] - cx
			var dz: float = props[i + 2] - cz
			bound = maxf(bound, dx * dx + dz * dz)
		_tile_props[t] = props
		_tile_prop_bounds[t] = Vector3(cx, cz, sqrt(bound) + 1.5)

## Solid verge props (trees/rocks) within `radius` of (x,z) as flat [x,y,z,r] quads
## (r = coarse trunk/boulder footprint). Feeds the car's prop near-miss. Returns a
## REUSED scratch buffer — consume immediately, never hold across frames. Purely a
## read of the scatter index; the ground-query path is untouched.
func props_near(x: float, z: float, radius: float) -> PackedFloat32Array:
	_props_scratch.resize(0)
	for t in _tile_props:
		var b: Vector3 = _tile_prop_bounds[t]
		var bdx := x - b.x
		var bdz := z - b.y
		var reach: float = b.z + radius
		if bdx * bdx + bdz * bdz > reach * reach:
			continue
		var arr: PackedFloat32Array = _tile_props[t]
		for i in range(0, arr.size(), 4):
			var dx := x - arr[i]
			var dz := z - arr[i + 2]
			var rr: float = radius + arr[i + 3]
			if dx * dx + dz * dz <= rr * rr:
				_props_scratch.push_back(arr[i])
				_props_scratch.push_back(arr[i + 1])
				_props_scratch.push_back(arr[i + 2])
				_props_scratch.push_back(arr[i + 3])
	return _props_scratch

## True if a DIFFERENT stretch of road (index gap > 10 from `own_i`) claims (x,z)
## as drivable-or-nearly (within its half-width + margin). Keeps verge props and
## signs off road that belongs to another pass of the track.
func _claimed_by_other(x: float, z: float, own_i: int, margin: float) -> bool:
	for ci in _branch_samples(x, z):
		if absi(ci - own_i) <= 10:
			continue
		var p := _project_at(ci, x, z)
		var rh: float = lerpf(road_half, road_half_turn, p.w)
		if absf(p.lat) < rh + margin:
			return true
	return false

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
		var dph := _ph[i + 1] - _ph[i]     # local curvature (th is a continuous
		                                    # accumulator; the ONE exception is the
		                                    # exact-TAU unwind after a stunt — the
		                                    # >20°/sample guard below skips it, since
		                                    # no real turn is that tight)
		if absf(dph) <= deg_to_rad(CHEVRON_TURN_THRESH) or absf(dph) > deg_to_rad(20.0):
			continue
		var d := float(i) * STEP
		if _in_void_s(d):                  # never plant a sign over a jump's void
			continue
		if _deck_at(d) > 0.2:
			continue                        # no boards floating beside a bridge deck
		var rh: float = lerpf(road_half, road_half_turn, _pw[i])
		var side := -signf(dph)            # outside = opposite the turn direction
		var lat: float = side * (rh + CHEVRON_OFFSET)
		var ph: float = _ph[i]
		var rx := cos(ph); var rz := sin(ph)             # road right vector
		var fx := sin(ph); var fz := -cos(ph)            # road forward vector
		var wx := _px[i] + rx * lat
		var wz := _pz[i] + rz * lat
		if _claimed_by_other(wx, wz, i, 3.0):
			continue                        # that spot is another pass's road
		# height from THIS row's s (not a bare height_at, which could resolve to a
		# different surface where the track stacks over itself)
		var wy := _carved_height(d, lat, rh) + CHEVRON_HEIGHT
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
