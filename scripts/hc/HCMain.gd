extends Node3D
## Hill-Climb feel sandbox: sky + streaming terrain + arcade car + world-upright chase
## cam locked behind + HUD (fuel/health/distance/speed). Run ends on fuel-out or wreck;
## Enter restarts. Milestone 1 — prove the moment-to-moment is fun. No economy yet.

const SkyScript := preload("res://scripts/Sky.gd")
const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")
const HCCarScript := preload("res://scripts/hc/HCCar.gd")
const HCAudioScript := preload("res://scripts/hc/HCAudio.gd")
const HCShopScript := preload("res://scripts/hc/HCShop.gd")

var _car: RigidBody3D
var _audio: Node
var _terrain: Node3D
var _cam: Camera3D
var _cam_heading := Vector3(0, 0, -1)
var _start := Vector3(0, 6, 0)

# --- maps ----------------------------------------------------------------
# Each map is a HCTrack export override set applied via `_terrain.set(k, v)` BEFORE
# add_child (generation happens in _ready on add_child, so this is the only window).
# "mode" picks the run variant: "classic" = today's game, "sprint" = race-the-clock
# (see SPRINT_* below). Selected map persists across restarts/deaths in the session.
const MAPS := {
	"hills": {
		"name": "Rolling Hills", "desc": "The classic ride — gentle sweepers, occasional jumps.",
		"mode": "classic", "sky_time": 0.37, "overrides": {},
	},
	"canyon": {
		"name": "Sunset Canyon", "desc": "All-drifting speedrun through red sandstone — no jumps, beat the clock.",
		"mode": "sprint", "sky_time": 0.31,
		"overrides": {
			"straight_bias": 0.22, "max_turn_deg": 150.0, "turn_radius_min": 26.0, "turn_radius_max": 60.0,
			"road_half": 20.0, "road_half_turn": 32.0, "hill_amp": 2.5, "noise_frequency": 0.004,
			"gap_start": 9.9e8, "path_seed": 424242, "noise_seed": 99,
			"grass_color": Color(0.55, 0.33, 0.18), "asphalt_color": Color(0.12, 0.11, 0.12),
			"edge_line_color": Color(0.95, 0.88, 0.72), "rail_band_color": Color(0.95, 0.5, 0.15),
			"scatter_density": 0.85,
			"scatter_kinds": ["res://assets/rocks/rock_quaternius_1_cc0.glb", "res://assets/rocks/rock_quaternius_2_cc0.glb"],
		},
	},
	"alpine": {
		"name": "Alpine Ridge", "desc": "Big snowy hills, big-air jumps — a stock ride can't clear them; bring engine + suspension upgrades.",
		"mode": "classic", "sky_time": 0.45,
		"overrides": {
			# bot-tuned (tests/AutoDrive.gd): the old 240 m / rise-8.5 first jump zeroed a
			# stock car's health on its first landing — later start, lower kick, longer
			# landing downslope keep it BIG but survivable
			"hill_amp": 14.0, "straight_bias": 0.7, "turn_radius_min": 50.0, "turn_radius_max": 95.0,
			"gap_start": 340.0, "gap_spacing": 280.0, "gap_ramp_rise": 6.0, "gap_land_len": 75.0,
			"gap_base_width": 24.0, "gap_grow": 12.0, "noise_frequency": 0.0034,
			"path_seed": 1337, "noise_seed": 2026,
			"grass_color": Color(0.88, 0.90, 0.94), "asphalt_color": Color(0.10, 0.10, 0.12),
			"centre_line_color": Color(0.85, 0.4, 0.2), "edge_line_color": Color(0.25, 0.3, 0.4),
			"rail_band_color": Color(0.2, 0.5, 0.95), "scatter_density": 0.85,
			"scatter_kinds": [
				"res://assets/trees/pine_quaternius_cc0.glb",
				"res://assets/trees/pine_tall_quaternius_cc0.glb",
				"res://assets/trees/pine_tree_quaternius_cc0.glb",
				"res://assets/trees/pine_trees_quaternius_cc0.glb",
			],
		},
	},
	"midnight": {
		"name": "Midnight Run", "desc": "Neon night cruise — headlights on, follow the glow.",
		"mode": "classic", "sky_time": 0.95, "night": true,
		"overrides": {
			"straight_bias": 0.45, "turn_radius_min": 34.0, "turn_radius_max": 70.0,
			"road_half": 19.0, "hill_amp": 5.0, "noise_frequency": 0.003,
			"gap_start": 500.0, "gap_spacing": 380.0,
			"path_seed": 20261111, "noise_seed": 611,
			# lightened slightly from a first pass (0.06/0.07-ish) that crushed to pure
			# black even under the tuned night lighting — still reads as dark night
			# grass/asphalt, just not literally unlit black
			"grass_color": Color(0.09, 0.13, 0.11), "asphalt_color": Color(0.11, 0.11, 0.14),
			"centre_line_color": Color(1.0, 0.85, 0.3), "edge_line_color": Color(0.85, 0.9, 1.0),
			"rail_band_color": Color(0.1, 0.9, 0.85), "rail_post_color": Color(0.25, 0.28, 0.35),
			"scatter_density": 0.5,
			"scatter_kinds": [
				"res://assets/rocks/rock_quaternius_1_cc0.glb",
				"res://assets/rocks/rock_quaternius_2_cc0.glb",
				"res://assets/trees/pine_tall_quaternius_cc0.glb",
			],
		},
	},
}
const MAP_KEYS := ["hills", "canyon", "alpine", "midnight"]
var _map := "hills"
var _best := {}            # map_key -> best distance (m) reached on that map, persisted
var _map_btns := {}       # key -> Button (title-screen row)

# --- sprint mode (mode "sprint" — race the clock) -------------------------
# Bot-tuned (tests/AutoDrive.gd data): a stock car burns its tank mid-run and coasts
# to a clock death — so checkpoints REFUEL as well as add time, making the sprint a
# self-sustaining chain you keep alive by pace, and they PAY so the mode earns money.
const SPRINT_TIME := 45.0        # starting countdown (s)
const SPRINT_CHECKPOINT_M := 350.0
const SPRINT_BONUS_S := 18.0
const SPRINT_FUEL_FRAC := 0.4    # tank fraction refilled per checkpoint
const SPRINT_CASH_BASE := 100    # checkpoint payout: base + step per checkpoint index
const SPRINT_CASH_STEP := 50
var _sprint_active := false
var _sprint_time := 0.0
var _sprint_next_checkpoint := 0.0
var _sprint_lbl: Label

# HUD
var _fuel_bar: ColorRect
var _health_bar: ColorRect
var _info: Label
var _big: Label
var _score_lbl: Label
var _trick_lbl: Label

# --- economy / upgrades ------------------------------------------------------
const UP_KEYS := ["engine", "fuel", "fueleff", "cashmult", "suspension", "durability", "wheels", "wings", "dive", "rockets", "stretch", "wide"]
const UP_NAME := {"engine": "Engine", "fuel": "Fuel Tank", "fueleff": "Fuel Economy", "cashmult": "Sponsor Decals", "suspension": "Suspension", "durability": "Durability", "wheels": "Bigger Wheels", "wings": "Wings", "dive": "Dive Power", "rockets": "Rockets", "stretch": "Aerodynamics", "wide": "Downforce"}
const UP_DESC := {
	"engine": "More power & higher top speed",
	"fuel": "Bigger tank — more total fuel",
	"fueleff": "Burns fuel slower (better mileage)",
	"cashmult": "Earn more cash per metre (+25%/lvl)",
	"suspension": "Coil springs — softer, safer landings (visible!)",
	"durability": "Roll cage + armor — more health (HP)",
	"wheels": "Taller & wider wheels, more clearance",
	"wings": "Lift = more air time off jumps",
	"dive": "Hold Space to dive + an air-brake flap",
	"rockets": "Hold Ctrl: a little air boost (chugs fuel)",
	"stretch": "Slippier body — higher top speed & carries momentum",
	"wide": "Presses you into the road — roll over far less",
}
const UP_BASECOST := {"engine": 320, "fuel": 260, "fueleff": 240, "cashmult": 400, "suspension": 300, "durability": 300, "wheels": 280, "wings": 380, "dive": 300, "rockets": 420, "stretch": 360, "wide": 320}
const UP_COSTMULT := 1.9   # each level costs 1.9x the last — costs ramp hard
const UP_MAX := 6
const MONEY_PER_M := 1.0    # money earned = metres travelled down the track
var money: int = 0
var _last_earned: int = 0
# upgrade levels are PER-VEHICLE — each ride has its own upgrade tree, so buying a
# new vehicle starts it fresh. _levels always points at the active ride's dict.
var _all_levels := {}
var _levels := {}

# --- vehicles ----------------------------------------------------------------
# Per-ride tuning. HCCar.VSPEC holds the matching geometry (mass, wheel track,
# body). Upgrade levels are SHARED across vehicles; these bases make the same
# level feel different per ride. _vehicle = the active one; _owned tracks unlocks.
const VEHICLES := {
	"minivan": {
		"name": "Rust-Bucket Van", "price": 0,
		"desc": "The free starter. Slow, soft and boxy with wide floaty turns — you'll want out of it fast. Every upgrade (and the next ride) feels like a huge step up.",
		"engine_base": 6000.0, "engine_per": 3000.0,
		"speed_base": 16.0, "speed_per": 8.0, "speed_cap": 40.0,
		"fuel_base": 90.0, "fuel_per": 48.0, "fuel_burn": 1.1,
		"land_base": 8.0, "susp_rest": 0.6, "susp_per": 0.16, "wheel_rad": 0.46, "wheel_per": 0.1,
		"health_base": 95.0, "grip": 7.5, "gravity": 17.0, "steer": 0.36, "corner_grip": 15.0,
		# lazy boxy tail, scrubs a lot, tall & tippy — wallows through bends
		"drift_yaw_max": 2.4, "drift_snap": 4.0, "drift_scrub": 1.4, "com_height": -0.2, "slide_thresh": 0.78,
	},
	"hotrod": {
		"name": "Hot Rod", "price": 1200,
		"desc": "Balanced convertible — light, quick, corners well, gets big air. The first real upgrade over the van.",
		"engine_base": 8000.0, "engine_per": 3600.0,
		"speed_base": 24.0, "speed_per": 12.0, "speed_cap": 55.0,
		"fuel_base": 70.0, "fuel_per": 44.0, "fuel_burn": 1.0,
		"land_base": 9.0, "susp_rest": 0.55, "susp_per": 0.18, "wheel_rad": 0.5, "wheel_per": 0.12,
		"health_base": 100.0, "grip": 8.5, "gravity": 17.0, "steer": 0.4, "corner_grip": 24.0,
		# the balanced baseline — an eager, catchable slide
		"drift_yaw_max": 3.1, "drift_snap": 7.0, "drift_scrub": 0.9, "com_height": -0.4, "slide_thresh": 0.85,
	},
	"monster": {
		"name": "Monster Truck", "price": 3200,
		"desc": "Giant heavy 4x4 — climbs anything, tanky, huge air with rockets, but slow, thirsty and TERRIBLE in corners (wide + tippy). Dinky wheels that the Bigger Wheels upgrade makes RIDICULOUS.",
		"engine_base": 15000.0, "engine_per": 5400.0,
		"speed_base": 22.0, "speed_per": 10.0, "speed_cap": 45.0,
		"fuel_base": 100.0, "fuel_per": 52.0, "fuel_burn": 1.5,
		"land_base": 11.0, "susp_rest": 0.85, "susp_per": 0.34, "wheel_rad": 0.5, "wheel_per": 0.38,
		"health_base": 165.0, "grip": 12.0, "gravity": 20.0, "steer": 0.34, "corner_grip": 14.0,
		# heavy lazy tail, scrubs HARD, wildly top-heavy — flops out of hard corners
		"drift_yaw_max": 2.0, "drift_snap": 3.5, "drift_scrub": 1.8, "com_height": 0.1, "slide_thresh": 0.72,
	},
	"sports": {
		"name": "Sports Car", "price": 5500,
		"desc": "Low, wide and grippy — the corner carver. Fast, sharp turns, made for the winding road. Not much air.",
		"engine_base": 12000.0, "engine_per": 4200.0,
		"speed_base": 40.0, "speed_per": 16.0, "speed_cap": 75.0,
		"fuel_base": 75.0, "fuel_per": 42.0, "fuel_burn": 1.15,
		"land_base": 10.0, "susp_rest": 0.45, "susp_per": 0.14, "wheel_rad": 0.5, "wheel_per": 0.11,
		"health_base": 95.0, "grip": 10.0, "gravity": 17.0, "steer": 0.42, "corner_grip": 32.0,
		# sharp responsive rotation, keeps its momentum, low & glued — barely leans
		"drift_yaw_max": 3.6, "drift_snap": 9.5, "drift_scrub": 0.5, "com_height": -0.55, "slide_thresh": 0.95,
	},
	"f1": {
		"name": "F1 Car", "price": 13000,
		"desc": "Open-wheel track weapon — razor-sharp cornering and blistering top speed, but fragile and slammed to the ground. Master of the road, awful everywhere else.",
		"engine_base": 21000.0, "engine_per": 6000.0,
		"speed_base": 64.0, "speed_per": 20.0, "speed_cap": 95.0,
		"fuel_base": 65.0, "fuel_per": 38.0, "fuel_burn": 1.3,
		"land_base": 9.0, "susp_rest": 0.35, "susp_per": 0.1, "wheel_rad": 0.55, "wheel_per": 0.1,
		"health_base": 75.0, "grip": 15.0, "gravity": 17.0, "steer": 0.46, "corner_grip": 74.0,
		# razor rotation, twitchy, glued to the deck — a track weapon that never leans.
		# HIGH corner_grip = it holds tight lines on pure grip without breaking into a drift.
		"drift_yaw_max": 3.8, "drift_snap": 11.0, "drift_scrub": 0.45, "com_height": -0.6, "slide_thresh": 0.99,
	},
}
const VEH_KEYS := ["minivan", "hotrod", "monster", "sports", "f1"]
var _vehicle := "minivan"

# --- body kits: optional imported GLB shell per vehicle ("" = procedural body) ----
# Options are scanned from assets/car/*.glb at boot, picked in the Garage tab, and
# persisted. Physics is untouched — HCCar auto-fits its wheel stance to the model
# (see HCCar.body_glb / _build_glb_body). Drop new .glb files in assets/car/ (specs
# in assets/car/README.md) and they appear in the picker on next boot.
var _body_kits := {}                       # vehicle key -> glb path ("" = stock)
var _kit_options: Array[String] = [""]     # "" (stock) + every assets/car/*.glb
var _owned := {"minivan": true, "hotrod": false, "monster": false, "sports": false, "f1": false}
var _was_dead := false
var _shake := 0.0           # camera shake magnitude (decays)
var _shake_off := Vector3.ZERO
var _fov_punch := 0.0       # transient FOV kick on hard landings
var _shop: Control
var _shop_ui: HCShopScript
var _start_layer: CanvasLayer   # one-time title / how-to-play screen (pauses until dismissed)
var _start_btn: Button
# --- cosmetics: cheap one-time unlocks, then a colour is selectable ----------
# Purely visual. Each is bought once (cheap), then you pick a colour from swatches.
# The car exposes an apply_*(color) per cosmetic; unowned ones keep the car's stock
# look. Ownership + chosen colour persist across retries (wiped by New Game).
const COSMETICS := {
	"underglow": {"name": "Underglow Lights", "cost": 150,
		"colors": [Color(0.1, 0.7, 1.0), Color(0.2, 0.3, 1.0), Color(0.7, 0.2, 1.0), Color(1.0, 0.2, 0.7), Color(1.0, 0.2, 0.15), Color(1.0, 0.55, 0.1), Color(0.2, 1.0, 0.4), Color(1.0, 1.0, 1.0)],
		"default": Color(0.1, 0.7, 1.0)},
	"smoke": {"name": "Tire Smoke Tint", "cost": 100,
		"colors": [Color(0.86, 0.86, 0.9), Color(0.14, 0.14, 0.17), Color(1.0, 0.3, 0.3), Color(0.3, 0.6, 1.0), Color(0.35, 1.0, 0.5), Color(1.0, 0.4, 1.0), Color(1.0, 0.85, 0.3), Color(0.6, 0.25, 1.0)],
		"default": Color(0.86, 0.86, 0.9)},
	"streaks": {"name": "Drift Streaks", "cost": 100,
		"colors": [Color(0.05, 0.05, 0.06), Color(1.0, 0.2, 0.2), Color(0.2, 0.5, 1.0), Color(0.2, 1.0, 0.4), Color(1.0, 0.6, 0.1), Color(1.0, 0.2, 0.8), Color(0.7, 0.3, 1.0), Color(1.0, 1.0, 1.0)],
		"default": Color(0.05, 0.05, 0.06)},
	"flames": {"name": "Boost Flames", "cost": 120,
		"colors": [Color(1.0, 0.55, 0.15), Color(0.3, 0.6, 1.0), Color(0.4, 1.0, 0.45), Color(1.0, 0.2, 0.8), Color(0.7, 0.3, 1.0), Color(1.0, 0.9, 0.3), Color(1.0, 0.2, 0.1), Color(0.9, 0.95, 1.0)],
		"default": Color(1.0, 0.55, 0.15)},
}
const COSM_KEYS := ["underglow", "smoke", "streaks", "flames"]
var _cosm_owned := {"underglow": false, "smoke": false, "streaks": false, "flames": false}
var _cosm_color := {}    # key -> chosen Color (seeded from defaults in _ready)

# --- feel juice: camera bank into drifts + high-speed speed-lines -------------
const CAM_ROLL_MAX_DEG := 5.0          # max camera bank while drifting (degrees)
const SPEED_REF := 53.0                # reference top speed (m/s)
const SPEED_FX_ON := 0.55              # speed-lines begin at this fraction of ref
const SPEED_FX_MAX := 0.98             # speed-lines reach full at this fraction of ref
const SPEED_LINE_COUNT := 32           # number of radial streaks
# corner look-ahead: sample the road centre-line a bit ahead and lean the aim into
# the upcoming bend so curves read early. Subtle + heavily damped (see _update_camera).
const CAM_LOOKAHEAD_DIST := 45.0       # metres ahead of the car to sample the road
const CAM_LOOKAHEAD_GAIN := 0.6        # how strongly lateral road bend maps to aim bias
const CAM_LOOKAHEAD_MAX := 7.0         # max aim bias (metres)
var _cam_lead := Vector3.ZERO          # smoothed look-ahead aim bias (horizontal vector)
var _cam_roll := 0.0                   # smoothed camera bank angle (degrees)
var _cam_look_basis := Basis.IDENTITY  # roll-free smoothing accumulator (see _update_camera)
var _cam_look_ready := false           # false until _cam_look_basis is seeded
var _speed_fx := 0.0                   # smoothed speed-lines intensity 0..1
var _speed_lines: Control              # full-screen streak overlay (mouse-ignored)
var _speed_line_nodes: Array[Line2D] = []
var _speed_lines_size := Vector2.ZERO  # viewport size the streaks were laid out for

# --- persistence ---------------------------------------------------------------
# Schema v1: {"version", "money", "levels" (vehicle_key -> {upgrade_key: int}),
# "owned" ([vehicle_key,...]), "vehicle", "cosm_owned" ([cosm_key,...]),
# "cosm_color" (cosm_key -> "#rrggbb"), "map", "best" (map_key -> float metres)}.
# _collect_save() / _apply_save() are the single choke point for the schema — adding
# a field later is "write it in one, read it with .get(key, fallback) in the other."
const SAVE_PATH := "user://hc_save.json"
## Persistence is OFF under the headless driver so the verification battery stays
## hermetic — otherwise MapProbe ending on Alpine writes map=alpine and the next
## SmoothProbe boots onto the jump map and blows its rms gates (and headless probes
## would trash the developer's real save). Real play is never headless; SaveProbe
## opts back in with `root.set("save_enabled", true)` BEFORE add_child — the same
## pre-_ready override window the map system uses.
var save_enabled := DisplayServer.get_name() != "headless"

## Snapshot everything that should survive a restart into a plain Dictionary (mirrors
## _apply_save). Colors serialize as "#rrggbb" html strings, not Godot Color objects —
## JSON has no native Color type.
func _collect_save() -> Dictionary:
	var levels_out := {}
	for vk in VEH_KEYS:
		levels_out[vk] = _all_levels[vk].duplicate()
	var owned_out := []
	for vk in VEH_KEYS:
		if bool(_owned.get(vk, false)):
			owned_out.append(vk)
	var cosm_owned_out := []
	for ck in COSM_KEYS:
		if bool(_cosm_owned.get(ck, false)):
			cosm_owned_out.append(ck)
	var cosm_color_out := {}
	for ck in COSM_KEYS:
		cosm_color_out[ck] = (_cosm_color[ck] as Color).to_html(false)   # no alpha channel
	var best_out := {}
	for mk in _best:
		best_out[mk] = _best[mk]
	return {
		"version": 1,
		"money": money,
		"levels": levels_out,
		"owned": owned_out,
		"vehicle": _vehicle,
		"cosm_owned": cosm_owned_out,
		"cosm_color": cosm_color_out,
		"map": _map,
		"best": best_out,
		"body_kits": _body_kits.duplicate(),
	}

## Merge a loaded save dict onto the in-memory defaults. EVERY read goes through
## `.get(key, fallback)` so a save missing newer fields (an older version) still loads
## cleanly instead of erroring — this is what makes adding fields later a one-line change.
func _apply_save(d: Dictionary) -> void:
	money = int(d.get("money", money))
	var levels_in: Dictionary = d.get("levels", {})
	for vk in VEH_KEYS:
		if levels_in.has(vk):
			var lv: Dictionary = levels_in[vk]
			for k in UP_KEYS:
				_all_levels[vk][k] = int(lv.get(k, _all_levels[vk][k]))
	var owned_in: Array = d.get("owned", [])
	for vk in owned_in:
		if _owned.has(vk):
			_owned[vk] = true
	var veh_in: String = str(d.get("vehicle", _vehicle))
	if VEHICLES.has(veh_in):
		_vehicle = veh_in
	_levels = _all_levels[_vehicle]   # re-point at the (possibly restored) active ride's tree
	var cosm_owned_in: Array = d.get("cosm_owned", [])
	for ck in cosm_owned_in:
		if _cosm_owned.has(ck):
			_cosm_owned[ck] = true
	var cosm_color_in: Dictionary = d.get("cosm_color", {})
	for ck in COSM_KEYS:
		if cosm_color_in.has(ck):
			_cosm_color[ck] = Color.html(str(cosm_color_in[ck]))
	var map_in: String = str(d.get("map", _map))
	if MAPS.has(map_in):
		_map = map_in
	var best_in: Dictionary = d.get("best", {})
	for mk in best_in:
		_best[mk] = float(best_in[mk])
	# body kits: only accept paths that still exist in assets/car/ (scanned into
	# _kit_options before load) so a deleted .glb falls back to the stock body
	var kits_in: Dictionary = d.get("body_kits", {})
	for vk in kits_in:
		if VEHICLES.has(vk) and _kit_options.has(str(kits_in[vk])):
			_body_kits[vk] = str(kits_in[vk])

## Write the full save snapshot to disk. Cheap enough to call on every purchase/switch/
## death — it's a few hundred bytes of JSON, not a hot-path concern.
func _save_game() -> void:
	if not save_enabled:
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return   # e.g. read-only user dir — fail silent, in-memory play carries on
	f.store_string(JSON.stringify(_collect_save()))
	f.close()

## Load persisted progress, if any. No file = fresh start (normal on first launch).
## Corrupt/unparseable file = ALSO a silent fresh start — never crash or spam errors
## over a bad save; the player just starts over as if it were new.
func _load_game() -> void:
	if not save_enabled:
		return
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	# a JSON instance (not JSON.parse_string) — parse_string ERR-prints on bad input,
	# and a corrupt save must be a SILENT fresh start, not console spam
	var json := JSON.new()
	if json.parse(txt) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return
	_apply_save(json.data)

func _ready() -> void:
	for ck in COSM_KEYS:
		_cosm_color[ck] = COSMETICS[ck].default   # seed chosen colours from defaults
	_setup_input()
	_init_levels()
	_scan_body_kits()   # before _load_game so a saved kit path can be validated
	_load_game()   # restore money/levels/owned/vehicle/cosmetics/map/best BEFORE anything
	               # below reads them — terrain (_map) and car (_vehicle) are built next
	_setup_sky()
	_setup_terrain_and_car()
	_setup_camera()
	_setup_hud()
	_setup_speed_lines()
	_shop_ui = HCShopScript.new(self)
	_build_shop()
	_apply_upgrades()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_start_menu()   # title + how-to-play; pauses the game until you hit START

## Find every .glb in assets/car/ for the Garage's body-kit picker. Runtime-loaded
## (GlbUtil), so files just dropped in the folder work without an editor import pass.
func _scan_body_kits() -> void:
	_kit_options = [""]
	var dir := DirAccess.open("res://assets/car")
	if dir == null:
		return
	for f in dir.get_files():
		if f.get_extension().to_lower() == "glb":
			_kit_options.append("res://assets/car/" + f)

func _input(event: InputEvent) -> void:
	# works for keyboard (Enter/Tab) AND gamepad (Back / Start) via the input actions
	if event.is_action_pressed("restart"):
		_restart()
	elif event.is_action_pressed("toggle_shop"):
		_toggle_shop()
	elif _shop and _shop.visible and _shop_ui:
		if event.is_action_pressed("shop_tab_left"):
			_switch_tab(-1)
		elif event.is_action_pressed("shop_tab_right"):
			_switch_tab(1)

# --- input map: keyboard + gamepad, built at runtime so we don't hand-edit the
# serialized project.godot. Gamepad layout (Xbox): RT throttle, LT brake, left
# stick steer (and air yaw + pitch), right stick X roll, RB boost, LB dive,
# Y recover, Start garage, Back retry; shop navigates with d-pad + A.
func _setup_input() -> void:
	for a in ["accelerate", "brake", "turn_left", "turn_right"]:
		if InputMap.has_action(a):
			InputMap.action_set_deadzone(a, 0.2)   # smooth analog triggers/stick
	_joy_axis("accelerate", JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_joy_axis("brake", JOY_AXIS_TRIGGER_LEFT, 1.0)
	_joy_axis("turn_left", JOY_AXIS_LEFT_X, -1.0)
	_joy_axis("turn_right", JOY_AXIS_LEFT_X, 1.0)
	_new_action("boost", 0.5, [_key(KEY_CTRL), _btn(JOY_BUTTON_RIGHT_SHOULDER)])
	_new_action("dive", 0.5, [_key(KEY_SPACE), _btn(JOY_BUTTON_LEFT_SHOULDER)])
	_new_action("recover", 0.5, [_key(KEY_R), _btn(JOY_BUTTON_Y)])
	_new_action("pitch_down", 0.2, [_key(KEY_W), _axis(JOY_AXIS_LEFT_Y, -1.0)])
	_new_action("pitch_up", 0.2, [_key(KEY_S), _axis(JOY_AXIS_LEFT_Y, 1.0)])
	_new_action("roll_left", 0.2, [_key(KEY_Q), _axis(JOY_AXIS_RIGHT_X, -1.0)])
	_new_action("roll_right", 0.2, [_key(KEY_E), _axis(JOY_AXIS_RIGHT_X, 1.0)])
	_new_action("toggle_shop", 0.5, [_key(KEY_TAB), _btn(JOY_BUTTON_START)])
	_new_action("restart", 0.5, [_key(KEY_ENTER), _btn(JOY_BUTTON_BACK)])
	# shop tab switching (bumpers on a pad, Q/E on the keyboard — only read while the
	# shop is open, so they can safely double as the in-game roll/dive/boost keys)
	_new_action("shop_tab_left", 0.5, [_key(KEY_Q), _btn(JOY_BUTTON_LEFT_SHOULDER)])
	_new_action("shop_tab_right", 0.5, [_key(KEY_E), _btn(JOY_BUTTON_RIGHT_SHOULDER)])
	# shop navigation on a gamepad (insurance in case the ui_* defaults were stripped)
	_joy_btn("ui_accept", JOY_BUTTON_A)
	_joy_btn("ui_cancel", JOY_BUTTON_B)
	_joy_btn("ui_up", JOY_BUTTON_DPAD_UP)
	_joy_btn("ui_down", JOY_BUTTON_DPAD_DOWN)
	_joy_btn("ui_left", JOY_BUTTON_DPAD_LEFT)
	_joy_btn("ui_right", JOY_BUTTON_DPAD_RIGHT)

func _key(kc: int) -> InputEventKey:
	var e := InputEventKey.new(); e.physical_keycode = kc; return e
func _btn(b: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new(); e.button_index = b; return e
func _axis(a: int, v: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new(); e.axis = a; e.axis_value = v; return e
func _joy_axis(action: String, a: int, v: float) -> void:
	if InputMap.has_action(action):
		InputMap.action_add_event(action, _axis(a, v))
func _joy_btn(action: String, b: int) -> void:
	if InputMap.has_action(action):
		InputMap.action_add_event(action, _btn(b))
func _new_action(nm: String, dz: float, events: Array) -> void:
	if not InputMap.has_action(nm):
		InputMap.add_action(nm, dz)
	for e in events:
		InputMap.action_add_event(nm, e)

var _sky: Node3D   # kept so maps can retune time-of-day on switch (_apply_map)

func _setup_sky() -> void:
	var sky := Node3D.new()
	sky.set_script(SkyScript)
	# ARCADE MODE: freeze on a warm, bright afternoon rather than letting Sky.gd's
	# day/night cycle run (that cycle is built for a different, darker mode elsewhere).
	# t=0.37 -> ~43deg sun elevation: a pleasant, readable afternoon angle.
	sky.set("time_of_day", MAPS[_map].sky_time)
	sky.set("auto_advance", false)   # lock the time of day; this mode is never dark
	add_child(sky)
	_sky = sky
	_tune_arcade_environment(sky)

## Sky.gd builds a full WorldEnvironment + sun/moon rig tuned for its slow day/night
## cycle (long shadow draw distance, volumetric fog, etc). We stay inside HCMain.gd's
## scope by reaching into the nodes it already created and retuning them for a cheap,
## bright, always-readable arcade look — Sky.gd itself belongs to another mode/owner.
## Branches on MAPS[_map].night: day maps keep the exact original tuning; the night
## map (midnight) gets a dim, cool retune so it reads as genuine night instead of the
## same bright-afternoon settings just painted a dark colour.
func _tune_arcade_environment(sky: Node3D) -> void:
	var env: Environment = sky.get("_env")
	var sun: DirectionalLight3D = sky.get("_sun")
	var night: bool = bool(MAPS[_map].get("night", false))
	if env:
		if night:
			# filmic tonemap with a moderate exposure lift — a real night still needs the
			# road readable; a first pass at 1.1 with low ambient read as pure black
			env.tonemap_mode = Environment.TONE_MAPPER_ACES
			env.tonemap_exposure = 1.35
			# AMBIENT_SOURCE_SKY samples the sky's actual radiance texture — at deep night
			# that texture is itself near-black (see Sky.gd's KEYS table), so no energy
			# multiplier on it can lift the ground above near-invisible; a first pass at
			# energy 0.8 on AMBIENT_SOURCE_SKY proved this (still pure black). Decouple
			# ambient from the (correctly dim) sky texture with a flat COLOR source
			# instead — an arcade liberty, same spirit as the day tuning's own departures
			# from physically-accurate lighting in favour of readability.
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = Color(0.12, 0.16, 0.24)   # cool dim night fill
			env.ambient_light_energy = 2.0
			# lower glow threshold so the neon rail band / centre line / coins bloom —
			# that bloom IS the "neon at night" read
			env.glow_enabled = true
			env.glow_intensity = 0.55
			env.glow_bloom = 0.14
			env.glow_hdr_threshold = 1.0
			env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
			env.volumetric_fog_enabled = false
			env.ssr_enabled = false
			env.sdfgi_enabled = false
			# near-black-blue fog, closer-in than the day haze so distant road fades to
			# night rather than hazing out to a bright horizon
			env.fog_enabled = true
			env.fog_mode = Environment.FOG_MODE_DEPTH
			env.fog_depth_begin = 60.0
			env.fog_depth_end = 650.0
			env.fog_density = 0.015
			env.fog_aerial_perspective = 0.3
			env.fog_sky_affect = 0.6
			env.fog_light_color = Color(0.03, 0.05, 0.10)   # near-black blue-night haze
			env.adjustment_enabled = true
			env.adjustment_saturation = 1.1
			env.adjustment_contrast = 1.05
			env.adjustment_brightness = 1.15
		else:
			# filmic tonemap with a light exposure lift so the bright, colorful palette pops
			env.tonemap_mode = Environment.TONE_MAPPER_ACES
			env.tonemap_exposure = 1.3
			# ambient bounce from the sky itself, lifted a touch so shadows never read as dead
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_energy = 1.2
			# glow: only strong emissive (coin pickups, brake lights, nitro) should bloom —
			# a high threshold keeps the sky/road from washing out into a soft haze
			env.glow_enabled = true
			env.glow_intensity = 0.35
			env.glow_bloom = 0.06
			env.glow_hdr_threshold = 1.3
			env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
			# perf: cut anything heavy — no volumetric fog / SSR / SDFGI in this mode
			env.volumetric_fog_enabled = false
			env.ssr_enabled = false
			env.sdfgi_enabled = false
			# cheap depth fog for an aerial-perspective feel: starts well past normal
			# reaction range so it beautifies the horizon without hiding the road ahead
			env.fog_enabled = true
			env.fog_mode = Environment.FOG_MODE_DEPTH
			env.fog_depth_begin = 130.0
			env.fog_depth_end = 950.0
			env.fog_density = 0.01
			env.fog_aerial_perspective = 0.4
			env.fog_sky_affect = 0.55
			env.fog_light_color = Color(0.95, 0.85, 0.72)   # warm horizon haze
			# a small saturation/contrast lift so the arcade colors read punchy, not flat
			env.adjustment_enabled = true
			env.adjustment_saturation = 1.15
			env.adjustment_contrast = 1.06
			env.adjustment_brightness = 1.02
	if sun:
		if night:
			# Sky.gd's own _apply() both (a) sets sun.visible = false once the real sun is
			# below the horizon (true at our deep-night time_of_day) and (b) leaves its
			# rotation aimed for that below-horizon sun — pointing the light rays UP, not
			# down at the road. Either alone made every color/energy tweak here a no-op.
			# Force it back on AND re-aim it at a fixed, plausible moonlight elevation
			# (~50deg, same heading Sky.gd uses) so it's a real downward key light —
			# Sky.gd's own moon light still runs too, this is just insurance that
			# something directional actually reaches the ground near the camera.
			sun.visible = true
			sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(-40.0), 0.0)
			sun.light_color = Color(0.55, 0.62, 0.9)
			sun.light_energy = 0.7
			sun.shadow_enabled = true
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			sun.directional_shadow_max_distance = 150.0
			sun.shadow_bias = 0.05
			sun.shadow_blur = 1.5
		else:
			sun.light_color = Color(1.0, 0.92, 0.78)   # warm afternoon sun
			sun.light_energy = 1.9
			sun.shadow_enabled = true
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			sun.directional_shadow_max_distance = 150.0   # cheaper than Sky.gd's default 320m
			sun.shadow_bias = 0.05
			sun.shadow_blur = 1.5   # soft-edged shadows, not razor-hard arcade shadows

func _setup_terrain_and_car() -> void:
	_terrain = Node3D.new()
	_terrain.set_script(HCTrackScript)
	_apply_map_overrides(_terrain)   # map knobs must land BEFORE add_child (gen runs in _ready)
	add_child(_terrain)
	_car = RigidBody3D.new()
	_car.set_script(HCCarScript)
	_car.set("vehicle_type", _vehicle)   # set BEFORE add_child so _ready builds the right ride
	_car.set("body_glb", str(_body_kits.get(_vehicle, "")))   # imported shell, if one is picked
	add_child(_car)
	_car.set("road_half", _terrain.get("road_half"))
	_car.set("terrain", _terrain)
	# place start above the road so it drops onto it
	_start = _terrain.call("spawn_pos")   # a bit forward so we don't roll off the start
	_car.global_position = _start
	_terrain.call("set_target", _car)
	_car.connect("gap_failed", _on_car_gap_failed)
	_car.connect("landed", _on_car_landed)
	_terrain.connect("pickup_collected", _on_pickup_collected)
	_apply_headlights()
	# audio intentionally OFF for now (user will source better sounds later). The
	# HCAudio synth + all play_* calls stay guarded by `if _audio:` so leaving
	# _audio null = fully silent; flip this back on by instancing HCAudioScript here.

## Switch the car's headlights on for the active map's "night" flag, if the car
## supports it. Guarded by has_method so this works whether or not the concurrent
## HCCar change (adding set_headlights) has landed yet — a per-map flag rather than
## hardcoding the "midnight" key so any future night map picks this up for free.
func _apply_headlights() -> void:
	if _car and _car.has_method("set_headlights"):
		_car.call("set_headlights", bool(MAPS[_map].get("night", false)))

## Push the active map's HCTrack export overrides onto a not-yet-added terrain node.
## Must run set_script -> this -> add_child, since HCTrack builds its road in _ready.
func _apply_map_overrides(terrain: Node3D) -> void:
	var overrides: Dictionary = MAPS[_map].overrides
	for k in overrides:
		if k == "scatter_kinds":
			# the export is a TYPED Array[String]; set() silently rejects a plain Array
			# (the canyon kept its pine trees this way) — rebuild it typed first
			var arr: Array[String] = []
			for p in overrides[k]:
				arr.append(str(p))
			terrain.set(k, arr)
		else:
			terrain.set(k, overrides[k])

## Called by the title-screen map row / shop "MAP" switcher (and MapProbe). Rebuilds
## the terrain fresh with the new map's overrides, respawns the car on it, and resets
## run + sprint state. Safe to call before or after _begin_game.
func select_map(key: String) -> void:
	if not MAPS.has(key) or key == _map:
		return
	_map = key
	_apply_map()

## Rebuild path for a map switch: free the old terrain, build a new one with this
## map's overrides, respawn the car, reconnect signals, reset run + sprint state.
func _apply_map() -> void:
	if _terrain and _terrain.is_connected("pickup_collected", _on_pickup_collected):
		_terrain.disconnect("pickup_collected", _on_pickup_collected)
	if _terrain:
		var old: Node = _terrain
		remove_child(old)
		old.queue_free()
	_terrain = Node3D.new()
	_terrain.set_script(HCTrackScript)
	_apply_map_overrides(_terrain)
	add_child(_terrain)
	if _car:
		_car.set("road_half", _terrain.get("road_half"))
		_car.set("terrain", _terrain)
	_start = _terrain.call("spawn_pos")
	_terrain.call("set_target", _car)
	_terrain.connect("pickup_collected", _on_pickup_collected)
	if _sky:
		_sky.set("time_of_day", MAPS[_map].sky_time)
		# time_of_day is a plain @export with no setter — Sky.gd only computes the actual
		# sky/sun/moon colors once, in its own _apply() (called from _ready, and again
		# every frame IF auto_advance were on — it's off here). Setting the property alone
		# leaves the boot-time palette on screen after a map switch, so nudge it to
		# recompute directly (duck-typed, like the terrain/car calls elsewhere in this file).
		if _sky.has_method("_apply"):
			_sky.call("_apply", MAPS[_map].sky_time)
		_tune_arcade_environment(_sky)   # night/day env retune — must re-run on every map switch
	if _car:
		_car.call("reset_run", _start)
	_apply_headlights()
	_reset_sprint_state()
	if _cam:
		_cam.global_position = _start + Vector3(0, 6, 12)
	_cam_heading = Vector3(0, 0, -1)
	_cam_look_ready = false
	_was_dead = false
	_update_map_row()
	_save_game()   # persist the map selection
	if _shop and _shop.visible:
		_refresh_shop()

## Title-screen map button: select it and re-run the initial terrain/car build (the
## title screen is still paused/showing, so this just swaps which map we'll play).
func _on_title_map_button(key: String) -> void:
	if _audio:
		_audio.call("play_click")
	if key != _map:
		_map = key
		_apply_map()
		_refresh_map_buttons()
	# hand focus back to START so Enter/Ⓐ always launches (a clicked map button
	# would otherwise keep focus and swallow the confirm key)
	if _start_btn:
		_start_btn.grab_focus()

## Highlight the currently-selected map button on the title screen.
func _refresh_map_buttons() -> void:
	for mk in MAP_KEYS:
		if not _map_btns.has(mk):
			continue
		var b: Button = _map_btns[mk]
		b.button_pressed = (mk == _map)

## Cycle to the next map from the shop/death-screen "MAP" row.
func _cycle_map() -> void:
	if _shop_ui: _shop_ui._cycle_map()

## Refresh the "MAP: <name>" readout in the shop/death screen, if built.
func _update_map_row() -> void:
	if _shop_ui: _shop_ui._update_map_row()

func _setup_camera() -> void:
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.far = 2000.0
	_cam.current = true
	# we drive the camera by hand every frame in _process; with the project's
	# physics_interpolation on, Godot spams "Interpolated Camera3D triggered from
	# outside physics process". Opt this node out of interpolation to silence it.
	_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_cam)
	_cam.global_position = _start + Vector3(0, 6, 12)
	_cam.look_at(_start, Vector3.UP)

func _process(delta: float) -> void:
	_shop_autoscroll(delta)
	if _car == null:
		return
	_update_camera(delta)
	_update_hud()
	_update_feel(delta)
	_update_sprint(delta)
	# on death, bank money earned from how far down the track you got, open the shop
	var d: bool = _car.get("dead")
	if d and not _was_dead:
		_was_dead = true
		_last_earned = int(float(_car.get("distance")) * MONEY_PER_M * _cash_mult())
		money += _last_earned
		var dist_now: float = _car.get("distance")
		if dist_now > float(_best.get(_map, 0.0)):
			_best[_map] = dist_now   # new PB on this map
		_save_game()   # persist the bank + best BEFORE the shop even opens
		if _audio:
			_audio.call("play_wreck")
		_show_shop()

func _update_camera(delta: float) -> void:
	# remove last frame's shake offset so it doesn't accumulate into the smoothing
	_cam.global_position -= _shake_off
	# heading from horizontal velocity (stable during flips); fall back to last heading
	var vel: Vector3 = _car.linear_velocity
	var vh := Vector3(vel.x, 0, vel.z)
	if vh.length() > 2.0:
		_cam_heading = _cam_heading.lerp(vh.normalized(), 1.0 - exp(-3.0 * delta))
	# feature 1: bank the camera toward the slide while drifting. Sign comes from
	# the car's lateral velocity (horizontal vel dotted onto the car's right axis);
	# smoothed so it eases in/out and can't snap. Applied to the view basis below.
	var roll_target := 0.0
	if not bool(_car.get("dead")) and bool(_car.get("drifting")):
		var cr := _car.global_transform.basis.x   # car's right vector (world)
		cr.y = 0.0
		if cr.length() > 0.001 and vh.length() > 1.0:
			var lat: float = vh.dot(cr.normalized())   # + = sliding to car's right
			if is_finite(lat):
				roll_target = clampf(lat / 12.0, -1.0, 1.0) * CAM_ROLL_MAX_DEG
	_cam_roll = lerpf(_cam_roll, roll_target, 1.0 - exp(-6.0 * delta))
	# corner look-ahead: sample the road centre-line ~LOOKAHEAD metres further along the
	# path and bias the aim toward where the road is heading. Only the SIDEWAYS part of
	# the lead (perpendicular to travel) is kept, so straights add no bias. Eased to 0
	# when there's nothing to drive (dead / no car / shop open) so it never lingers.
	var lead_target := Vector3.ZERO
	var la_active: bool = not (_car == null or bool(_car.get("dead")) or (_shop != null and _shop.visible))
	if la_active and _terrain != null:
		var here: Vector3 = _terrain.call("path_ahead", _car.global_position, 0.0)
		var ahead: Vector3 = _terrain.call("path_ahead", _car.global_position, CAM_LOOKAHEAD_DIST)
		var lead := ahead - here
		lead.y = 0.0
		lead -= _cam_heading * lead.dot(_cam_heading)   # sideways component only
		lead *= CAM_LOOKAHEAD_GAIN
		if lead.length() > CAM_LOOKAHEAD_MAX:
			lead = lead.normalized() * CAM_LOOKAHEAD_MAX
		if lead.is_finite():
			lead_target = lead
	_cam_lead = _cam_lead.lerp(lead_target, 1.0 - exp(-4.0 * delta))
	var target := _car.global_position
	var want := target - _cam_heading * 12.0 + Vector3(0, 6.0, 0)
	# gentle "cut the corner": nudge the chase position a small fraction of the aim bias
	want += _cam_lead * 0.3
	# don't let terrain block the view of the car: raycast from the car toward the camera
	# and pull the camera in front of any hill in the way
	var ss := _car.get_world_3d().direct_space_state
	var from := target + Vector3(0, 2.0, 0)
	var q := PhysicsRayQueryParameters3D.create(from, want, 1, [_car.get_rid()])
	var hit := ss.intersect_ray(q)
	var blocked := not hit.is_empty()
	if blocked:
		want = from.lerp(hit.position, 0.82)
	# never let the camera dip below the terrain surface
	var floor_y: float = _terrain.call("height_at", want.x, want.z) + 3.0
	if want.y < floor_y:
		want.y = floor_y
	# snap in faster when blocked so the car never disappears
	var snap: float = 16.0 if blocked else 6.0
	_cam.global_position = _cam.global_position.lerp(want, 1.0 - exp(-snap * delta))
	var look := target + Vector3(0, 1.0, 0)
	# lean the AIM toward the upcoming bend (composes with the roll-free basis below;
	# it only shifts the look target, so it never feeds the drift-roll accumulator)
	look += _cam_lead
	var dir := look - _cam.global_position
	# looking_at() errors if the look direction is parallel to the up vector
	# (camera ends up directly above/below the car). Skip the degenerate frame,
	# and fall back to a horizontal up reference when we're near-vertical.
	if dir.length() > 0.05:
		var up_ref := Vector3.UP
		if absf(dir.normalized().dot(Vector3.UP)) > 0.985:
			up_ref = _cam_heading if _cam_heading.length() > 0.1 else Vector3.FORWARD
		var t := _cam.global_transform.looking_at(look, up_ref)
		# smooth the roll-FREE look basis in its own accumulator so the drift bank
		# (applied below) never feeds back into next frame's slerp and accumulates.
		if not _cam_look_ready:
			_cam_look_basis = t.basis
			_cam_look_ready = true
		_cam_look_basis = _cam_look_basis.slerp(t.basis, 1.0 - exp(-8.0 * delta))
		# feature 1: roll the final view about its forward axis by the smoothed bank,
		# rebuilt from the un-rolled basis each frame (no drift over time).
		var fwd: Vector3 = (-_cam_look_basis.z).normalized()
		_cam.global_transform.basis = _cam_look_basis.rotated(fwd, deg_to_rad(_cam_roll))
	# FOV widens with speed (and harder while boosting) for a sense of pace
	var spd: float = _car.linear_velocity.length()
	var boosting: bool = bool(_car.get("boosting"))
	var target_fov: float = lerpf(70.0, 92.0, clamp(spd / 42.0, 0.0, 1.0))
	target_fov += (9.0 if boosting else 0.0) + _fov_punch
	_cam.fov = lerpf(_cam.fov, target_fov, 1.0 - exp(-4.0 * delta))
	_fov_punch *= exp(-7.0 * delta)
	# rockets rumble the camera; landings (above) add a one-shot jolt. Apply + decay.
	if boosting:
		_shake = maxf(_shake, 0.11)
	_shake_off = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake
	_cam.global_position += _shake_off
	_shake *= exp(-7.0 * delta)

func _restart() -> void:
	_apply_upgrades()
	_car.call("reset_run", _start)
	if _terrain:
		_terrain.call("reset_pickups")   # re-stock the whole track each run
	_cam.global_position = _start + Vector3(0, 6, 12)
	_cam_heading = Vector3(0, 0, -1)
	_shake = 0.0
	_shake_off = Vector3.ZERO
	_fov_punch = 0.0
	_cam_roll = 0.0
	_cam_lead = Vector3.ZERO
	_cam_look_ready = false   # reseed the look basis at the new spawn orientation
	_speed_fx = 0.0
	_was_dead = false
	_reset_sprint_state()
	if _shop:
		_shop.visible = false

# --- camera juice ------------------------------------------------------------

## A landing kicks the camera: shake + a quick FOV punch, both scaled by impact.
func _on_car_landed(impact: float, _air_time: float) -> void:
	_shake = maxf(_shake, clampf(impact * 0.018, 0.0, 0.6))
	_fov_punch = maxf(_fov_punch, clampf(impact * 0.5, 0.0, 12.0))

## Falling into a pit is a wreck like any other — the car sets dead and _process
## shows the end screen. Just add a jolt here for feel.
func _on_car_gap_failed(_can_respawn: bool) -> void:
	_shake = maxf(_shake, 0.5)

# --- sprint mode: race the clock on "sprint"-mode maps (currently: canyon) --------

## Reseed the countdown for the active map's mode. Classic maps stay inactive
## (no timer shown, no death-on-zero) — this is purely opt-in per map.
func _reset_sprint_state() -> void:
	_sprint_active = MAPS[_map].mode == "sprint"
	_sprint_time = SPRINT_TIME
	_sprint_next_checkpoint = SPRINT_CHECKPOINT_M

## Tick the countdown while a sprint run is live; award +time every checkpoint
## distance and end the run (via the car's normal death flow) at zero.
func _update_sprint(delta: float) -> void:
	if not _sprint_active or _car == null or bool(_car.get("dead")):
		return
	var dist: float = _car.get("distance")
	if dist >= _sprint_next_checkpoint:
		var cp_idx: int = int(_sprint_next_checkpoint / SPRINT_CHECKPOINT_M)   # 1-based
		_sprint_next_checkpoint += SPRINT_CHECKPOINT_M
		_sprint_time += SPRINT_BONUS_S
		# refuel + pay: keeps the chain alive (fuel starved out mid-run otherwise) and
		# makes sprint runs worth money beyond the distance payout
		var mf: float = float(_car.get("max_fuel"))
		_car.set("fuel", minf(float(_car.get("fuel")) + mf * SPRINT_FUEL_FRAC, mf))
		var cash: int = int((SPRINT_CASH_BASE + SPRINT_CASH_STEP * (cp_idx - 1)) * _cash_mult())
		money += cash
		_car.set("trick_text", "CHECKPOINT  +%ds  ⛽  +$%d" % [int(SPRINT_BONUS_S), cash])
		_car.set("_trick_timer", 2.0)
		if _audio:
			_audio.call("play_coin")
	_sprint_time -= delta
	if _sprint_time <= 0.0:
		_sprint_time = 0.0
		_car.set("health", 0.0)   # normal death/shop flow takes it from here

# --- feel: speed-lines overlay ----------------------------------------------

## Build a full-screen overlay of thin radial streaks (anime-style speed lines),
## drawn procedurally with Line2Ds (no texture assets). Alpha is driven per-frame
## in _update_feel by a smoothed speed factor. Its own CanvasLayer sits UNDER the
## HUD (layer 1) and shop (layer 10) so it never obscures readouts, and it ignores
## the mouse so it can't eat clicks in the shop.
func _setup_speed_lines() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)
	_speed_lines = Control.new()
	_speed_lines.set_anchors_preset(Control.PRESET_FULL_RECT)
	_speed_lines.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_speed_lines.modulate = Color(1, 1, 1, 0)   # start invisible; ramps with speed
	layer.add_child(_speed_lines)
	for i in range(SPEED_LINE_COUNT):
		var ln := Line2D.new()
		ln.width = randf_range(1.5, 3.5)
		ln.default_color = Color(1, 1, 1, randf_range(0.3, 0.55))
		ln.begin_cap_mode = Line2D.LINE_CAP_ROUND
		ln.end_cap_mode = Line2D.LINE_CAP_ROUND
		_speed_lines.add_child(ln)
		_speed_line_nodes.append(ln)
	_layout_speed_lines(get_viewport().get_visible_rect().size)

## Position the streaks radially around screen center, from just outside a central
## "safe" radius out toward the edges. Recomputed whenever the viewport resizes.
## Safe on a zero-size viewport (frame 0): bails until a real size arrives.
func _layout_speed_lines(vp: Vector2) -> void:
	if vp.x < 1.0 or vp.y < 1.0:
		return
	_speed_lines_size = vp
	var center := vp * 0.5
	var span := vp.length()
	var safe := span * 0.18          # inner radius kept clear of streaks
	var reach := span * 0.72
	var n := _speed_line_nodes.size()
	if n <= 0:
		return
	for i in range(n):
		var ln := _speed_line_nodes[i]
		var ang := TAU * float(i) / float(n) + randf_range(-0.06, 0.06)
		var dir := Vector2(cos(ang), sin(ang))
		var r0 := safe + randf_range(0.0, safe * 0.4)
		var r1 := r0 + reach * randf_range(0.5, 1.0)
		ln.clear_points()
		ln.add_point(center + dir * r0)
		ln.add_point(center + dir * r1)

## Per-frame feel update: ramp the speed-lines alpha with a smoothed speed factor,
## hidden while dead or the shop is open. (Camera bank is handled in _update_camera.)
func _update_feel(delta: float) -> void:
	if _speed_lines == null:
		return
	# relayout on first valid frame or after a viewport resize
	var vp := get_viewport().get_visible_rect().size
	if vp.x >= 1.0 and vp.y >= 1.0 and vp.distance_to(_speed_lines_size) > 1.0:
		_layout_speed_lines(vp)
	var hidden: bool = _car == null or bool(_car.get("dead")) or (_shop != null and _shop.visible)
	var target := 0.0
	if not hidden:
		var spd: float = _car.linear_velocity.length()
		if is_finite(spd):
			var f := (spd / SPEED_REF - SPEED_FX_ON) / maxf(SPEED_FX_MAX - SPEED_FX_ON, 0.01)
			target = clampf(f, 0.0, 1.0)
	_speed_fx = lerpf(_speed_fx, target, 1.0 - exp(-4.0 * delta))
	_speed_lines.modulate.a = _speed_fx * 0.7   # peak ~0.35 alpha per streak

## Sponsor Decals upgrade: scales all cash earned (distance payout + coins).
func _cash_mult() -> float:
	return 1.0 + float(_levels.cashmult) * 0.25

## A world pickup (HCPickup, re-emitted by the terrain) was driven through.
func _on_pickup_collected(kind: String, value: float) -> void:
	match kind:
		"coin":
			money += int(value * _cash_mult())
			if _audio:
				_audio.call("play_coin")
		"fuel":
			var mf: float = _car.get("max_fuel")
			_car.set("fuel", minf(float(_car.get("fuel")) + value, mf))
			if _audio:
				_audio.call("play_coin")
		"nitro":
			# concentrated boost juice + a quick forward kick
			var mf2: float = _car.get("max_fuel")
			_car.set("fuel", minf(float(_car.get("fuel")) + value, mf2))
			if is_instance_valid(_car) and not bool(_car.get("dead")):
				_car.apply_central_impulse(-_car.global_transform.basis.z * value * 120.0)
			if _audio:
				_audio.call("play_coin")
		"milk":
			# the rare carton: value is a FRACTION of the tank (see HCTrack.PK_MILK_VALUE)
			var mfm: float = _car.get("max_fuel")
			_car.set("fuel", minf(float(_car.get("fuel")) + mfm * value, mfm))
			_car.set("trick_text", "GOT MILK?   +%d%% TANK" % int(round(value * 100.0)))
			_car.set("_trick_timer", 1.8)
			if _audio:
				_audio.call("play_coin")

# --- upgrade shop ------------------------------------------------------------

func _cost(key: String) -> int:
	return int(UP_BASECOST[key] * pow(UP_COSTMULT, _levels[key]))

## One zeroed upgrade dict per vehicle; _levels points at the active ride's.
func _init_levels() -> void:
	for vk in VEH_KEYS:
		var d := {}
		for k in UP_KEYS:
			d[k] = 0
		_all_levels[vk] = d
	_levels = _all_levels[_vehicle]

func _apply_upgrades() -> void:
	if _car == null:
		return
	var v: Dictionary = VEHICLES[_vehicle]   # per-ride bases; upgrades ramp on top
	# starter is intentionally weak/slow; upgrades ramp it up hard
	_car.set("engine_force", float(v.engine_base) + _levels.engine * float(v.engine_per))
	# AERODYNAMICS (was Stretch): slippier body — raises top speed (soft cap tracks it).
	# speed_cap = per-vehicle CEILING so maxed engines can't run away to absurd speeds
	# (an engine-maxed F1 used to reach ~184 m/s); the ladder stays intact because each
	# faster ride's cap sits above the previous one's.
	_car.set("max_speed", minf(float(v.speed_base) + _levels.engine * float(v.speed_per) + _levels.stretch * 5.0, float(v.get("speed_cap", 60.0))))
	if _car.has_method("apply_engine"):
		_car.call("apply_engine", _levels.engine)
	# fuel is the run timer — VERY low stock so you can barely move; two upgrades fix it:
	#   Fuel Tank = capacity, Fuel Economy = slower burn. Heavy rides drink more (fuel_burn).
	_car.set("max_fuel", float(v.fuel_base) + _levels.fuel * float(v.fuel_per))
	_car.set("fuel_eff", float(v.fuel_burn) * maxf(1.0 - _levels.fueleff * 0.08, 0.45))
	# intrinsic handling per ride (grip/gravity/steer); not touched by upgrades
	_car.set("grip", float(v.grip))
	_car.set("gravity_force", float(v.gravity))
	_car.set("max_steer_angle", float(v.steer))
	_car.set("corner_grip", float(v.get("corner_grip", 22.0)))   # low = wide turns at speed
	# per-vehicle drift + tipping personality (each ride slides & leans differently)
	_car.set("drift_yaw_max", float(v.get("drift_yaw_max", 3.1)))
	_car.set("drift_snap", float(v.get("drift_snap", 7.0)))
	# Aerodynamics also carries momentum better — less speed scrubbed mid-drift.
	_car.set("drift_scrub", float(v.get("drift_scrub", 0.9)) * maxf(1.0 - _levels.stretch * 0.1, 0.4))
	_car.set("slide_thresh", float(v.get("slide_thresh", 0.85)))
	_car.set("com_height", float(v.get("com_height", -0.4)))
	# DOWNFORCE (was Wide Body): a speed-scaled push into the road so the car plants and
	# corners flatter at speed. Purely mechanical — does not change the car's size.
	_car.set("downforce", float(_levels.wide) * 0.9)
	if _car.has_method("apply_com"):
		_car.call("apply_com")   # push the new CoM height into the rigid body
	# Suspension softens landings (higher free-impact threshold) + shows the springs
	_car.set("land_damage_speed", float(v.land_base) + _levels.suspension * 5.0 + _levels.wheels * 2.0)
	if _car.has_method("apply_suspension"):
		_car.call("apply_suspension", _levels.suspension)
	# Bigger Wheels: more ride height + larger wheels (clearance over bumps).
	# Per-ride growth — the monster's wheels balloon dramatically.
	_car.set("suspension_rest", float(v.susp_rest) + _levels.wheels * float(v.susp_per))
	_car.set("wheel_radius", float(v.wheel_rad) + _levels.wheels * float(v.wheel_per))
	if _car.has_method("apply_wheel_size"):
		_car.call("apply_wheel_size")
	# Wings = lift / air time
	if _car.has_method("apply_wings"):
		_car.call("apply_wings", _levels.wings)
	_car.set("dive_force", 30.0 + _levels.dive * 16.0)     # heavier dive to time ramps
	# Durability = roll cage + armor (more health / frame)
	_car.set("max_health", float(v.health_base) + _levels.durability * 18.0)
	if _car.has_method("apply_cage"):
		_car.call("apply_cage", _levels.durability)
	if _car.has_method("apply_cans"):
		_car.call("apply_cans", _levels.fuel)
	if _car.has_method("apply_airbrake"):
		_car.call("apply_airbrake", _levels.dive)
	# Rockets: rear nozzles + boost thrust (hold Ctrl)
	if _car.has_method("apply_rockets"):
		_car.call("apply_rockets", _levels.rockets)
	# (Downforce/Aerodynamics are pure mechanical tuning now — no chassis resize.)
	_apply_cosmetics()   # cosmetics, re-applied on every rebuild/swap

## One-time title + how-to-play screen. Pauses the whole game (process_mode ALWAYS so
## the panel still runs) until START, then unpauses and frees itself.
func _build_start_menu() -> void:
	_start_layer = CanvasLayer.new()
	_start_layer.layer = 20                       # above the HUD and the shop
	_start_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_start_layer)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.03, 0.04, 0.06, 0.9)
	_start_layer.add_child(dim)

	# ADAPTIVE layout: the old fixed 720x640 panel at a hand-placed offset overflowed
	# the 720 px window once the MAP row landed — START rendered BELOW the screen edge
	# and the game looked "stuck" (nothing clickable could unpause it). Now the panel
	# centres itself at any size, the how-to text scrolls, and MAP + START stay pinned.
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_start_layer.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(720, 0)
	center.add_child(panel)
	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 20)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	pad.add_child(box)

	_shop_label(box, "🏎  HILL CLIMB RACER", 34, Color(1, 0.82, 0.42))
	_shop_label(box, "Drive as far as you can. Fuel is your timer — don't run dry.", 16, Color(0.72, 0.78, 0.9))
	box.add_child(HSeparator.new())

	# scrollable middle (controls + tips) so the pinned MAP/START rows below always
	# fit on screen no matter how much how-to text accumulates
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(672, 290)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(sc)
	var scb := VBoxContainer.new()
	scb.add_theme_constant_override("separation", 8)
	scb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(scb)

	_shop_label(scb, "CONTROLS", 16, Color(0.8, 0.85, 1.0))
	var ctrls := [
		"Throttle / Brake:   W / S   ·   RT / LT",
		"Steer:   A / D   ·   left stick",
		"In the air:   W/S pitch  ·  A/D yaw  ·  Q/E roll",
		"Dive:   Space / LB      Boost (Rockets):   Ctrl / RB",
		"Recover if flipped:   R / Y      Garage:   Tab / Start",
	]
	for c in ctrls:
		_shop_label(scb, "•  " + c, 15, Color(0.86, 0.88, 0.92))
	scb.add_child(HSeparator.new())

	_shop_label(scb, "TIPS", 16, Color(0.8, 0.85, 1.0))
	var tips := [
		"Drift around most corners — brake while turning, or flick the wheel hard, to break the rear loose. Take a fast corner on pure grip and a top-heavy ride will TIP and roll out of control.",
		"Read EVERY upgrade — each changes how the car handles, not just its numbers. (Downforce = tips far less · Aerodynamics = higher top speed · Bigger Wheels = clearance.)",
		"Grab coins for cash and fuel cans to stretch your run — pickups respawn every run.",
		"Clear the gaps by carrying speed. Fall in and the run ends.",
		"Every vehicle feels different — try them all in the Garage (van → hot rod → monster → sports → F1).",
	]
	for t in tips:
		var l := _shop_label(scb, "•  " + t, 14, Color(0.7, 0.74, 0.8))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(640, 0)
	box.add_child(HSeparator.new())

	_shop_label(box, "MAP", 16, Color(0.8, 0.85, 1.0))
	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 8)
	box.add_child(map_row)
	_map_btns.clear()
	for mk in MAP_KEYS:
		var mbtn := Button.new()
		mbtn.text = MAPS[mk].name
		mbtn.tooltip_text = MAPS[mk].desc
		mbtn.custom_minimum_size = Vector2(0, 40)
		mbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mbtn.toggle_mode = true
		mbtn.pressed.connect(_on_title_map_button.bind(mk))
		map_row.add_child(mbtn)
		_map_btns[mk] = mbtn
	_refresh_map_buttons()
	box.add_child(HSeparator.new())

	_start_btn = Button.new()
	_start_btn.text = "START  ▶   (Enter / Ⓐ)"
	_start_btn.custom_minimum_size = Vector2(0, 54)
	_start_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_btn.add_theme_font_size_override("font_size", 22)
	_start_btn.pressed.connect(_begin_game)
	box.add_child(_start_btn)

	get_tree().paused = true
	_start_btn.call_deferred("grab_focus")

## Leave the title screen: unpause and drop the overlay.
func _begin_game() -> void:
	if _audio:
		_audio.call("play_click")
	get_tree().paused = false
	if _start_layer:
		_start_layer.queue_free()
		_start_layer = null

func _build_shop() -> void:
	_shop_ui._build_shop()

func _shop_autoscroll(delta: float) -> void:
	if _shop_ui: _shop_ui._shop_autoscroll(delta)

func _switch_tab(dir: int) -> void:
	if _shop_ui: _shop_ui._switch_tab(dir)

func _show_shop() -> void:
	if _shop_ui: _shop_ui._show_shop()

func _toggle_shop() -> void:
	if _shop_ui: _shop_ui._toggle_shop()

func _refresh_shop() -> void:
	if _shop_ui: _shop_ui._refresh_shop()

func _shop_label(parent: Node, text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	parent.add_child(l)
	return l

## Rebuild the car node as a different ride (vehicles aren't hot-swappable in
## place — geometry differs — so we free & recreate, then re-wire and re-apply).
func _swap_vehicle(vk: String) -> void:
	_vehicle = vk
	_levels = _all_levels[vk]   # switch to this ride's own upgrade tree
	var was_visible := _shop and _shop.visible
	if _terrain.is_connected("pickup_collected", _on_pickup_collected):
		_terrain.disconnect("pickup_collected", _on_pickup_collected)
	if _car:
		# detach IMMEDIATELY (not just queue_free) so the old ride — and its
		# visible upgrade parts like wings — vanish this frame instead of lingering
		# in the scene behind the shop until the deferred free finally runs.
		var old: Node = _car
		old.remove_from_group("car")
		remove_child(old)
		old.queue_free()
	_car = RigidBody3D.new()
	_car.set_script(HCCarScript)
	_car.set("vehicle_type", _vehicle)
	_car.set("body_glb", str(_body_kits.get(_vehicle, "")))   # imported shell, if one is picked
	add_child(_car)
	_car.set("road_half", _terrain.get("road_half"))
	_car.set("terrain", _terrain)
	_start = _terrain.call("spawn_pos")
	_car.global_position = _start
	_terrain.call("set_target", _car)
	_car.connect("gap_failed", _on_car_gap_failed)
	_car.connect("landed", _on_car_landed)
	_terrain.connect("pickup_collected", _on_pickup_collected)
	if _audio:
		_audio.call("setup", _car)   # re-point the engine synth at the new body
	_apply_headlights()
	_apply_upgrades()
	_cam_heading = Vector3(0, 0, -1)
	_was_dead = false
	_reset_sprint_state()
	_save_game()   # persists both the purchase (if any) and the new active vehicle
	if was_visible:
		_refresh_shop()

## Push every owned cosmetic's colour onto the car (re-called on rebuild/swap).
## Unowned cosmetics are left at the car's stock look (underglow just stays off).
func _apply_cosmetics() -> void:
	if _car == null:
		return
	if _car.has_method("apply_underglow"):
		_car.call("apply_underglow", _cosm_owned["underglow"], _cosm_color["underglow"])
	if _cosm_owned["smoke"] and _car.has_method("apply_smoke_color"):
		_car.call("apply_smoke_color", _cosm_color["smoke"])
	if _cosm_owned["streaks"] and _car.has_method("apply_streak_color"):
		_car.call("apply_streak_color", _cosm_color["streaks"])
	if _cosm_owned["flames"] and _car.has_method("apply_flame_color"):
		_car.call("apply_flame_color", _cosm_color["flames"])

# --- HUD ---------------------------------------------------------------------

func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_bar_bg(layer, Vector2(28, 28), Color(0, 0, 0, 0.5))
	_fuel_bar = _bar(layer, Vector2(30, 30), Color(0.95, 0.8, 0.2))
	_bar_bg(layer, Vector2(28, 56), Color(0, 0, 0, 0.5))
	_health_bar = _bar(layer, Vector2(30, 58), Color(0.9, 0.3, 0.3))
	_info = Label.new()
	_info.position = Vector2(28, 84)
	_info.add_theme_font_size_override("font_size", 18)
	layer.add_child(_info)
	_big = Label.new()
	_big.set_anchors_preset(Control.PRESET_CENTER)
	_big.position = Vector2(-220, -40)
	_big.custom_minimum_size = Vector2(440, 0)
	_big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_big.add_theme_font_size_override("font_size", 26)
	_big.add_theme_color_override("font_color", Color(1, 1, 0.7))
	layer.add_child(_big)
	_score_lbl = Label.new()
	_score_lbl.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_score_lbl.position = Vector2(-200, 28)
	_score_lbl.add_theme_font_size_override("font_size", 24)
	_score_lbl.add_theme_color_override("font_color", Color(1, 0.95, 0.5))
	layer.add_child(_score_lbl)
	_sprint_lbl = Label.new()
	_sprint_lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_sprint_lbl.position = Vector2(-120, 60)
	_sprint_lbl.custom_minimum_size = Vector2(240, 0)
	_sprint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sprint_lbl.add_theme_font_size_override("font_size", 44)
	_sprint_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	layer.add_child(_sprint_lbl)
	_trick_lbl = Label.new()
	_trick_lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_trick_lbl.position = Vector2(-240, 120)
	_trick_lbl.custom_minimum_size = Vector2(480, 0)
	_trick_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_trick_lbl.add_theme_font_size_override("font_size", 32)
	_trick_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	layer.add_child(_trick_lbl)
	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(28, -34)
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	hint.text = "KB: Shift/W drive • S brake • A/D steer • Ctrl boost • Space dive • R recover • air W/S pitch, Q/E roll • Tab garage • Enter retry\nPad: RT throttle • LT brake • L-stick steer/pitch • R-stick roll • RB boost • LB dive • Y recover • Start garage • Ⓑ retry"
	layer.add_child(hint)

func _bar_bg(layer: CanvasLayer, pos: Vector2, col: Color) -> void:
	var r := ColorRect.new()
	r.position = pos
	r.size = Vector2(224, 18)
	r.color = col
	layer.add_child(r)

func _bar(layer: CanvasLayer, pos: Vector2, col: Color) -> ColorRect:
	var r := ColorRect.new()
	r.position = pos
	r.size = Vector2(220, 14)
	r.color = col
	layer.add_child(r)
	return r

func _update_hud() -> void:
	var fuel: float = _car.get("fuel")
	var health: float = _car.get("health")
	var dist: float = _car.get("distance")
	var maxfuel: float = _car.get("max_fuel")
	var maxhp: float = _car.get("max_health")
	_fuel_bar.size.x = 220.0 * clamp(fuel / maxf(maxfuel, 1.0), 0.0, 1.0)
	_health_bar.size.x = 220.0 * clamp(health / maxf(maxhp, 1.0), 0.0, 1.0)
	var air: String = "  ✈ AIR" if _car.get("airborne") else ""
	_info.text = "%d m    %d km/h%s" % [int(dist), int(_car.call("get_speed_kmh")), air]
	_score_lbl.text = "SCORE %d" % int(_car.get("score"))
	_trick_lbl.text = _car.get("trick_text")
	_update_sprint_hud()
	_update_gap_telegraph()

## Sprint-mode countdown: hidden on classic maps, big + red under 10s on sprint maps.
func _update_sprint_hud() -> void:
	if not _sprint_active or _car == null or bool(_car.get("dead")):
		_sprint_lbl.text = ""
		return
	_sprint_lbl.text = "%d" % ceili(_sprint_time)
	_sprint_lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3) if _sprint_time < 10.0 else Color(0.6, 1.0, 0.7))

## Warn the player to build speed on a gap run-up (green = you'll make it).
func _update_gap_telegraph() -> void:
	if bool(_car.get("dead")):
		return   # _big is owned by the wipeout / death screen
	if _terrain == null:
		_big.text = ""
		return
	var g: Dictionary = _terrain.call("gap_ahead", _car.global_position)
	if g.is_empty() or float(g.dist) > 75.0:
		_big.text = ""   # not approaching a gap
		return
	var v_req: float = 6.0 + float(g.vw) * 0.9        # m/s needed to clear it
	var spd: float = _car.linear_velocity.length()
	if spd >= v_req:
		_big.text = "SEND IT!  ▶▶"
		_big.add_theme_color_override("font_color", Color(0.5, 1.0, 0.55))
	else:
		_big.text = "⚠ GO FASTER   %d / %d km/h" % [int(spd * 3.6), int(v_req * 3.6)]
		_big.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
