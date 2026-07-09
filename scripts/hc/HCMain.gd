extends Node3D
## Hill-Climb feel sandbox: sky + streaming terrain + arcade car + world-upright chase
## cam locked behind + HUD (fuel/health/distance/speed). Run ends on fuel-out or wreck;
## Enter restarts. Milestone 1 — prove the moment-to-moment is fun. No economy yet.

const SkyScript := preload("res://scripts/Sky.gd")
const HCTerrainScript := preload("res://scripts/hc/HCTerrain.gd")
const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")
const HCCarScript := preload("res://scripts/hc/HCCar.gd")
const HCAudioScript := preload("res://scripts/hc/HCAudio.gd")
const HCSceneryScript := preload("res://scripts/hc/HCScenery.gd")
const HCTimeTrialScript := preload("res://scripts/hc/HCTimeTrial.gd")   # static rules only, never instanced
const HCGhostScript := preload("res://scripts/hc/HCGhost.gd")
const USE_TRACK := true   # true = new 2-D winding road (HCTrack); false = classic corridor

var _car: RigidBody3D
var _audio: Node
var _terrain: Node3D
var _scenery: Node3D   # distant background ridgelines/skyline (HCScenery.gd) — see _setup_scenery
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
		"mode": "classic", "sky_time": 0.37, "accent": Color(0.55, 0.78, 0.35),
		# starter map: gap-in-generation scheduling (v7.5) surfaced the first jump
		# within a stock tank's range — soften it so a zero-upgrade van can clear it
		"overrides": {"gap_ramp_rise": 5.0, "gap_base_width": 15.0, "gap_grow": 8.0},
	},
	"canyon": {
		"name": "Sunset Canyon", "desc": "All-drifting speedrun through red sandstone — no jumps, beat the clock.",
		"mode": "sprint", "sky_time": 0.31, "accent": Color(0.92, 0.48, 0.2),
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
		"mode": "classic", "sky_time": 0.45, "accent": Color(0.4, 0.6, 0.95),
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
		"mode": "classic", "sky_time": 0.95, "night": true, "accent": Color(0.65, 0.35, 0.95),
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
	"gravity": {
		"name": "Gravity Works", "desc": "Overpasses and banked corkscrews — the road crosses OVER itself. Look up.",
		"mode": "classic", "sky_time": 0.33, "accent": Color(0.95, 0.75, 0.2),
		"overrides": {
			"stunts": "loop:2450,overpass:650,corkscrew:1500:2,overpass:2900,corkscrew:3900:1",
			"straight_bias": 0.6, "turn_radius_min": 40.0, "turn_radius_max": 80.0,
			"road_half": 18.0, "road_half_turn": 26.0,
			"hill_amp": 5.0, "noise_frequency": 0.0024,
			"gap_start": 5600.0, "gap_spacing": 420.0,
			"path_seed": 777333, "noise_seed": 424,
			"grass_color": Color(0.30, 0.42, 0.24), "asphalt_color": Color(0.15, 0.15, 0.17),
			"centre_line_color": Color(1.0, 0.8, 0.25), "edge_line_color": Color(0.95, 0.93, 0.88),
			"rail_band_color": Color(0.95, 0.45, 0.1),
			"scatter_density": 0.6,
			"scatter_kinds": [
				"res://assets/trees/pine_quaternius_cc0.glb",
				"res://assets/trees/pine_tall_quaternius_cc0.glb",
				"res://assets/rocks/rock_quaternius_1_cc0.glb",
			],
		},
	},
}
const MAP_KEYS := ["hills", "canyon", "alpine", "midnight", "gravity"]
var _map := "hills"
var _best := {}            # map_key -> best distance (m) reached on that map, persisted
var _map_btns := {}       # key -> Button (title-screen map card)
var _map_card_stat_lbl := {}   # key -> Label (title-screen card's "best distance/time" line)
var _mode_btns := {}      # "classic"/"trial" -> Button (title-screen mode toggle)
var _veh_title_btns := {} # vehicle key -> Button (title-screen vehicle strip)
var _map_row_lbl: Label   # shop/death-screen "MAP: <name>" readout

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

# --- time trial mode (title-screen "TIME TRIAL" toggle) -------------------------
# Orthogonal to sprint: sprint is a per-map property (canyon only) and always wins
# on maps that declare it; trial is a player-picked global toggle that only takes
# effect on maps WITHOUT their own mode (see HCTimeTrialScript.FINISH_M / _reset_run_mode).
# Crossing the finish line does not end the run — it banks a record/ghost and the
# drive continues classic-style, so trial composes with the existing death/shop flow
# instead of replacing it.
var _run_mode := "classic"        # "classic" | "trial" — persisted, defaults to classic
var _trial_active := false        # true this run iff sprint isn't active + trial supports _map
var _trial_time := 0.0
var _trial_finished := false
var _trial_splits_hit := {}       # split index (int) -> true, cleared every run
var _trial_result := ""           # last finish summary line, folded into the wreck screen
var _ghost: Node3D                # HCGhostScript instance (your personal best); duck-typed .call()
var _best_time := {}              # "<map>|<vehicle>" -> seconds, persisted
var _ghost_data := {}             # "<map>|<vehicle>" -> Array[float] (HCGhostScript sample dump), persisted
var _trial_lbl: Label             # HUD: big live/finish timer (top-center)
var _trial_sub_lbl: Label         # HUD: "to go / best / medal ladder" readout under the timer

# --- Stage 1 async multiplayer: shareable ghost files ("send a friend your ghost") --
# A rival ghost is keyed by MAP ONLY (not map|vehicle) — the file's own vehicle rides
# along as metadata for the label/status line, but you can race a friend's F1 lap in
# your van; only the recorded transforms matter for playback. One rival slot per map,
# imported/replaced/cleared from the title screen; persisted in the save (same
# ghost_version gate as `_ghost_data`, since it's the same sample format).
const GHOST_DIR_DEFAULT := "user://ghosts"
var ghost_dir_override := ""      # test hook (GhostShareProbe): redirect exports away from the
                                   # real folder so headless runs stay hermetic; "" = use the default
var _rival_ghost: Node3D          # HCGhostScript instance (imported rival); tinted red + name-tagged
var _rival_data := {}             # map_key -> {"vehicle":String,"time":float,"data":Array,"name":String}
var _ghost_status_lbl: Label      # title-screen GHOSTS row status line
var _ghost_file_dialog: FileDialog

# HUD
var _fuel_bar: ColorRect
var _balloon_bar: ColorRect      # slim charge bar, hidden until Party Balloons is owned
var _balloon_bar_bg: ColorRect
var _health_bar: ColorRect
var _info: Label
var _big: Label
var _score_lbl: Label
var _trick_lbl: Label
var _combo_lbl: Label            # combo pot + multiplier readout (under the score)
var _combo_bar: ColorRect        # grace-window drain bar
var _combo_bar_bg: ColorRect
var _combo_pulse_tween: Tween    # per-trick thump on the combo label
var _score_flash_tween: Tween    # gold flash on the score when a pot banks

# --- economy / upgrades ------------------------------------------------------
const UP_KEYS := ["engine", "fuel", "fueleff", "cashmult", "suspension", "durability", "wheels", "wings", "dive", "rockets", "stretch", "wide", "balloons"]
const UP_NAME := {"engine": "Engine", "fuel": "Fuel Tank", "fueleff": "Fuel Economy", "cashmult": "Sponsor Decals", "suspension": "Suspension", "durability": "Durability", "wheels": "Bigger Wheels", "wings": "Wings", "dive": "Dive Power", "rockets": "Rockets", "stretch": "Aerodynamics", "wide": "Downforce", "balloons": "Party Balloons"}
const UP_DESC := {
	"engine": "More power & higher top speed",
	"fuel": "Bigger tank — more total fuel",
	"fueleff": "Burns fuel slower (better mileage)",
	"cashmult": "Earn more cash per metre (+25%/lvl)",
	"suspension": "Coil springs — softer, safer landings (visible!)",
	"durability": "Reinforced armor — more health (HP)",
	"wheels": "Taller wheels, more clearance",
	"wings": "Lift = more air time off jumps",
	"dive": "Hold Space to dive + an air-brake flap",
	"rockets": "Hold Ctrl: a little air boost (chugs fuel)",
	"stretch": "Slippier body — higher top speed & carries momentum",
	"wide": "Presses you into the road — roll over far less",
	"balloons": "Hold F in the air: float down soft (they pop as they spend)",
}
const UP_BASECOST := {"engine": 320, "fuel": 260, "fueleff": 240, "cashmult": 400, "suspension": 300, "durability": 300, "wheels": 280, "wings": 380, "dive": 300, "rockets": 420, "stretch": 360, "wide": 320, "balloons": 340}
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
		"drift_yaw_max": 2.4, "drift_snap": 4.0, "drift_scrub": 1.4, "tippiness": 0.55, "com_height": -0.2, "slide_thresh": 0.78,
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
		"drift_yaw_max": 3.1, "drift_snap": 7.0, "drift_scrub": 0.9, "tippiness": 0.35, "com_height": -0.4, "slide_thresh": 0.85,
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
		"drift_yaw_max": 2.0, "drift_snap": 3.5, "drift_scrub": 1.8, "tippiness": 0.95, "com_height": 0.1, "slide_thresh": 0.72,
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
		"drift_yaw_max": 3.6, "drift_snap": 9.5, "drift_scrub": 0.5, "tippiness": 0.12, "com_height": -0.55, "slide_thresh": 0.95,
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
		"drift_yaw_max": 3.8, "drift_snap": 11.0, "drift_scrub": 0.45, "tippiness": 0.05, "com_height": -0.6, "slide_thresh": 0.99,
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
var _kit_lbl: Label                        # garage "BODY KIT" readout
var _owned := {"minivan": true, "hotrod": false, "monster": false, "sports": false, "f1": false}
var _was_dead := false
var _was_drifting := false   # edge-detectors for the continuous drift/boost loops
var _was_boosting := false
var _was_floating := false
var _respawning := false
var _shake := 0.0           # camera shake magnitude (decays)
var _shake_off := Vector3.ZERO
var _fov_punch := 0.0       # transient FOV kick on hard landings
var _shop: Control
var _shop_header: Label
var _shop_money: Label
var _shop_tabs: TabContainer   # Garage / Upgrades / Cosmetics
var _shop_rows := {}
var _veh_rows := {}
var _reset_btn: Button
var _restart_btn: Button
var _money_btn: Button
var _start_layer: CanvasLayer   # one-time title / how-to-play screen (pauses until dismissed)
var _start_btn: Button
var _reset_armed := false   # fresh-start needs a confirm click so it's not a mis-tap
var _first_veh_btn: Button   # focus target when the garage opens (gamepad nav)
var _scroll_repeat := 0.0    # hold-to-autoscroll timer in the shop
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
var _cosm_rows := {}     # key -> {buy: Button, swatches: HBoxContainer}

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
# v1 also carries (added without a version bump — every field is .get()-defaulted so
# older saves just don't have them yet): "run_mode" ("classic"/"trial"), "best_time"
# ("<map>|<vehicle>" -> seconds), "ghosts" ("<map>|<vehicle>" -> Array[float] sample
# dump, HCGhostScript.recorded_data() format), "ghost_version" (HCGhostScript.VERSION at save
# time — a mismatch drops ALL saved ghosts on load rather than risk feeding a stale
# sample layout into HCGhostScript.load_data(); best_time survives regardless), "rivals"
# (map_key -> {vehicle, time, data, name} — an imported .hcghost file's payload, one
# per map; gated by the SAME ghost_version check as "ghosts" since it's the same
# sample format).
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
	var best_time_out := {}
	for k in _best_time:
		best_time_out[k] = _best_time[k]
	var ghosts_out := {}
	for k in _ghost_data:
		ghosts_out[k] = _ghost_data[k]
	var rivals_out := {}
	for mk in _rival_data:
		var rd: Dictionary = _rival_data[mk]
		rivals_out[mk] = {
			"vehicle": str(rd.get("vehicle", "")),
			"time": float(rd.get("time", 0.0)),
			"data": rd.get("data", []),
			"name": str(rd.get("name", "")),
		}
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
		"run_mode": _run_mode,
		"best_time": best_time_out,
		"ghosts": ghosts_out,
		"ghost_version": HCGhostScript.VERSION,
		"rivals": rivals_out,
		"volume": master_volume,
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
	var mode_in: String = str(d.get("run_mode", _run_mode))
	if mode_in == "classic" or mode_in == "trial":
		_run_mode = mode_in
	var best_time_in: Dictionary = d.get("best_time", {})
	for k in best_time_in:
		_best_time[k] = float(best_time_in[k])
	# ghosts are versioned separately from the save schema itself: a mismatch means
	# HCGhostScript's sample layout changed since this save was written, so every stored
	# ghost is dropped (best TIMES still restore above — only the visual replay is lost)
	if int(d.get("ghost_version", HCGhostScript.VERSION)) == HCGhostScript.VERSION:
		var ghosts_in: Dictionary = d.get("ghosts", {})
		for k in ghosts_in:
			if ghosts_in[k] is Array:
				_ghost_data[k] = ghosts_in[k]
		var rivals_in: Dictionary = d.get("rivals", {})
		for mk in rivals_in:
			if MAPS.has(mk) and rivals_in[mk] is Dictionary:
				var rd: Dictionary = rivals_in[mk]
				if rd.get("data") is Array:
					_rival_data[mk] = {
						"vehicle": str(rd.get("vehicle", "")),
						"time": float(rd.get("time", 0.0)),
						"data": rd["data"],
						"name": str(rd.get("name", "")),
					}
	master_volume = clampf(float(d.get("volume", master_volume)), 0.0, 1.0)

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
	_ghost = HCGhostScript.new()
	add_child(_ghost)   # one persistent record+playback node; must exist before _setup_terrain_and_car
	_rival_ghost = HCGhostScript.new()
	_rival_ghost.call("configure", Color(1.0, 0.25, 0.22, 0.4))   # red, distinct from your blue ghost
	add_child(_rival_ghost)   # playback-only — never records; loaded from imported files
	_setup_sky()
	_setup_terrain_and_car()
	_setup_scenery()
	_setup_camera()
	_setup_hud()
	_setup_speed_lines()
	_build_shop()
	_build_pause_menu()
	_build_volume_toast()
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

## Display name for a kit path: "Stock" or a cleaned-up filename.
func _kit_name(path: String) -> String:
	if path == "":
		return "Stock"
	return path.get_file().get_basename().replace("_", " ")

## Cycle the ACTIVE vehicle's body kit and rebuild the car wearing it.
func _cycle_body_kit() -> void:
	if _audio:
		_audio.call("play_click")
	var cur: String = str(_body_kits.get(_vehicle, ""))
	var i: int = _kit_options.find(cur)
	_body_kits[_vehicle] = _kit_options[(i + 1) % _kit_options.size()]
	_swap_vehicle(_vehicle)   # full rebuild in the new shell (+ saves + refreshes shop)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_menu"):
		_toggle_pause_menu()
		return
	if event.is_action_pressed("mute_toggle"):
		_toggle_mute()
		return
	if event.is_action_pressed("volume_up"):
		_adjust_volume(0.1)
		return
	if event.is_action_pressed("volume_down"):
		_adjust_volume(-0.1)
		return
	# works for keyboard (Enter/Tab) AND gamepad (Back / Start) via the input actions
	if event.is_action_pressed("restart"):
		_restart()
	elif event.is_action_pressed("toggle_shop"):
		_toggle_shop()
	elif _shop and _shop.visible and _shop_tabs:
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
	_new_action("float", 0.5, [_key(KEY_F), _btn(JOY_BUTTON_X)])   # Party Balloons deploy
	_new_action("pitch_down", 0.2, [_key(KEY_W), _axis(JOY_AXIS_LEFT_Y, -1.0)])
	_new_action("pitch_up", 0.2, [_key(KEY_S), _axis(JOY_AXIS_LEFT_Y, 1.0)])
	_new_action("roll_left", 0.2, [_key(KEY_Q), _axis(JOY_AXIS_RIGHT_X, -1.0)])
	_new_action("roll_right", 0.2, [_key(KEY_E), _axis(JOY_AXIS_RIGHT_X, 1.0)])
	_new_action("toggle_shop", 0.5, [_key(KEY_TAB), _btn(JOY_BUTTON_START)])
	_new_action("restart", 0.5, [_key(KEY_ENTER), _btn(JOY_BUTTON_BACK)])
	_new_action("pause_menu", 0.5, [_key(KEY_ESCAPE)])
	# volume: adjustable anywhere, anytime — no need to open the pause menu. Minus/Equal
	# (the "-/+" pair) step by 10%; M toggles mute. Handled in _input below.
	_new_action("volume_down", 0.5, [_key(KEY_MINUS)])
	_new_action("volume_up", 0.5, [_key(KEY_EQUAL)])
	_new_action("mute_toggle", 0.5, [_key(KEY_M)])
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
	# per-map atmosphere seasoning, layered on TOP of the day/night base above so every
	# map keeps its own mood without a second copy of the whole tonemap/ambient setup.
	_apply_map_atmosphere(env, sun)
	# sun disc glow + star density live in Sky.gd's shader material — reached the same
	# duck-typed way as _env/_sun above (Sky.gd itself stays untouched/owned elsewhere).
	var sky_mat: ShaderMaterial = sky.get("_sky_mat")
	if sky_mat:
		_apply_map_sky_shader(sky_mat)

## Per-map fog color/density + sun-color seasoning: canyon's dusty warm haze, alpine's
## crisp cold thin air, hills' soft pastoral haze, gravity's industrial overcast-warm
## grey, midnight's deeper neon-tinged blacks. Only touches fog + sun light — tonemap/
## ambient/glow stay owned by the day/night branch above so the night-readability
## invariant is never disturbed by a per-map tweak.
func _apply_map_atmosphere(env: Environment, sun: DirectionalLight3D) -> void:
	if env == null:
		return
	match _map:
		"hills":
			# soft pastoral — a light, barely-there departure from the base warm haze
			env.fog_light_color = Color(0.93, 0.87, 0.74)
			env.fog_density = 0.009
		"canyon":
			# dusty warm haze, closer-in and thicker than the base — red-sandstone dust
			env.fog_light_color = Color(0.88, 0.56, 0.32)
			env.fog_depth_begin = 90.0
			env.fog_density = 0.017
			env.fog_aerial_perspective = 0.5
			env.adjustment_saturation = 1.22
			env.adjustment_contrast = 1.08
			if sun:
				sun.light_color = Color(1.0, 0.78, 0.52)
				sun.light_energy = 2.05
		"alpine":
			# crisp thin cold air — long clean sightlines with a slight blue distance haze
			env.fog_light_color = Color(0.80, 0.87, 0.98)
			env.fog_depth_begin = 180.0
			env.fog_depth_end = 1300.0
			env.fog_density = 0.007
			if sun:
				sun.light_color = Color(0.97, 0.97, 1.0)
				sun.light_energy = 2.05
		"midnight":
			# deeper blacks + a neon-tinged haze instead of a plain night-blue fog
			env.fog_light_color = Color(0.06, 0.05, 0.13)
			env.fog_depth_end = 900.0   # a touch further than the night base so the skyline reads
			env.fog_density = 0.017
			env.glow_intensity = 0.65
		"gravity":
			# industrial, slightly overcast-warm — hazier and flatter than the other day maps
			env.fog_light_color = Color(0.66, 0.60, 0.50)
			env.fog_depth_begin = 110.0
			env.fog_density = 0.013
			env.adjustment_saturation = 0.96
			env.adjustment_contrast = 1.02
			if sun:
				sun.light_energy = 1.65

## Sun-disc glow + star density: cheap, high-read per-map touches living in Sky.gd's
## own shader (see shaders/sky.gdshader — sun_glow/sun_glow_color/star_amount uniforms),
## reached the same way _env/_sun are rather than editing Sky.gd itself.
func _apply_map_sky_shader(sky_mat: ShaderMaterial) -> void:
	match _map:
		"canyon":
			# a big warm glare around a low sunset sun sells the "sunset canyon" name
			sky_mat.set_shader_parameter("sun_glow", 1.0)
			sky_mat.set_shader_parameter("sun_glow_color", Color(1.0, 0.5, 0.2))
		"alpine":
			# crisp thin air = a tight, cold disc rather than a hazy glow
			sky_mat.set_shader_parameter("sun_glow", 0.3)
			sky_mat.set_shader_parameter("sun_glow_color", Color(0.95, 0.97, 1.0))
		"gravity":
			# overcast industrial haze — a duller, hazier disc
			sky_mat.set_shader_parameter("sun_glow", 0.28)
		"midnight":
			# denser stars than the stock night value reads as a clearer, more dramatic sky
			sky_mat.set_shader_parameter("star_amount", 1.0)

func _setup_terrain_and_car() -> void:
	_terrain = Node3D.new()
	# TOGGLE: the new 2-D winding-ribbon road (HCTrack) vs the classic z-corridor.
	_terrain.set_script(HCTrackScript if USE_TRACK else HCTerrainScript)
	_apply_map_overrides(_terrain)   # map knobs must land BEFORE add_child (gen runs in _ready)
	add_child(_terrain)
	_car = RigidBody3D.new()
	_car.set_script(HCCarScript)
	_car.set("vehicle_type", _vehicle)   # set BEFORE add_child so _ready builds the right ride
	_car.set("body_glb", str(_body_kits.get(_vehicle, "")))   # imported shell, if one is picked
	add_child(_car)
	_car.set("road_half", _terrain.get("road_half") if USE_TRACK else _terrain.get("road_half_width"))
	_car.set("terrain", _terrain)
	# place start above the road so it drops onto it
	if _terrain.has_method("spawn_pos"):
		_start = _terrain.call("spawn_pos")   # track: a bit forward so we don't roll off the start
	else:
		_start.y = _terrain.call("height_at", 0.0, 0.0) + 4.0
	_car.global_position = _start
	_terrain.call("set_target", _car)
	_car.connect("gap_failed", _on_car_gap_failed)
	_car.connect("landed", _on_car_landed)
	_car.connect("combo_event", _on_car_combo)
	_car.connect("balloon_pop", _on_balloon_pop)
	_terrain.connect("pickup_collected", _on_pickup_collected)
	_apply_headlights()
	_reset_run_mode_state()   # NOTE: this was missing at boot before trial mode landed —
	                          # a save restoring onto canyon used to boot with sprint
	                          # inactive until the first restart/map-switch; now correct
	# procedural synth audio — every play_* call stays guarded by `if _audio:` so
	# setting _audio = null here silences the whole game if the owner rejects the mix
	_audio = HCAudioScript.new()
	add_child(_audio)
	_audio.call("setup", _car)
	_apply_volume()

## Build the distant-scenery rig once at boot. Independent of the terrain node's
## identity (unlike _terrain/_car, it's never freed/rebuilt on a map switch — see
## _apply_map, which just calls configure() again on this same node).
func _setup_scenery() -> void:
	_scenery = Node3D.new()
	_scenery.set_script(HCSceneryScript)
	add_child(_scenery)
	_scenery.call("configure", _scenery_config())

## Small config dict for HCScenery, sourced from the active map's MAPS entry: which
## silhouette style to build (style keys match MAPS keys 1:1) plus the accent color/
## night flag so the background stays visually tied to the map's own palette choices.
func _scenery_config() -> Dictionary:
	var m: Dictionary = MAPS[_map]
	return {
		"style": _map,
		"accent": m.get("accent", Color(0.7, 0.75, 0.7)),
		"night": bool(m.get("night", false)),
	}

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
	_terrain.set_script(HCTrackScript if USE_TRACK else HCTerrainScript)
	_apply_map_overrides(_terrain)
	add_child(_terrain)
	if _car:
		_car.set("road_half", _terrain.get("road_half") if USE_TRACK else _terrain.get("road_half_width"))
		_car.set("terrain", _terrain)
	if _terrain.has_method("spawn_pos"):
		_start = _terrain.call("spawn_pos")
	else:
		_start.y = _terrain.call("height_at", 0.0, 0.0) + 4.0
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
	if _scenery:
		_scenery.call("configure", _scenery_config())   # new silhouette style/palette for this map
	if _car:
		_car.call("reset_run", _start)
	_apply_headlights()
	_reset_run_mode_state()
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
	# always resync toggle state — re-clicking the ALREADY-selected card still toggles
	# its button_pressed (toggle_mode flips on every click), so without this it would
	# visually deselect a card that's still actually the active map
	_refresh_map_buttons()
	# hand focus back to START so Enter/Ⓐ always launches (a clicked map button
	# would otherwise keep focus and swallow the confirm key)
	if _start_btn:
		_start_btn.grab_focus()

## Highlight the currently-selected map card and refresh its stat line (best distance,
## and — on trial-supporting maps — best time + medal for the ACTIVE vehicle). Called
## from the title screen (map/mode/vehicle picks) and from the in-game shop's map
## switcher; is_instance_valid guards because the title screen's card nodes are freed
## by _begin_game() while this dict is never cleared (only ever repopulated on the
## next _build_start_menu — i.e. after a Main Menu reload).
func _refresh_map_buttons() -> void:
	for mk in MAP_KEYS:
		if not _map_btns.has(mk) or not is_instance_valid(_map_btns[mk]):
			continue
		var b: Button = _map_btns[mk]
		b.button_pressed = (mk == _map)
		if not _map_card_stat_lbl.has(mk) or not is_instance_valid(_map_card_stat_lbl[mk]):
			continue
		var stat: Label = _map_card_stat_lbl[mk]
		var best_m := int(float(_best.get(mk, 0.0)))
		var line := "Best: %d m" % best_m
		if HCTimeTrialScript.supports(mk):
			var bt: float = float(_best_time.get(_trial_key(mk, _vehicle), -1.0))
			if bt >= 0.0:
				var medal := HCTimeTrialScript.medal_for(mk, bt)
				line += "   ⏱ %s %s" % [HCTimeTrialScript.format_time(bt), HCTimeTrialScript.medal_glyph(medal)]
			else:
				line += "   ⏱ no trial time yet"
		elif MAPS[mk].mode == "sprint":
			line += "   (sprint mode)"
		stat.text = line
	_refresh_ghost_row()

## Update the title-screen GHOSTS status line for the CURRENTLY SELECTED map (rivals
## are keyed by map, not map|vehicle — see _rival_data). Called from every place that
## already calls _refresh_map_buttons() (map/mode/vehicle picks), plus directly after
## an export/import/clear action. No-ops before the row is built (_ghost_status_lbl
## null) and after the title screen is torn down (_begin_game frees it).
func _refresh_ghost_row() -> void:
	if _ghost_status_lbl == null or not is_instance_valid(_ghost_status_lbl):
		return
	var rd: Dictionary = _rival_data.get(_map, {})
	if rd.has("data"):
		var veh_in := str(rd.get("vehicle", ""))
		var veh_note := "" if veh_in == _vehicle or not VEHICLES.has(veh_in) else "  ·  recorded in %s" % str(VEHICLES[veh_in].name)
		_ghost_status_lbl.text = "Rival: %s  (%s)%s" % [str(rd.get("name", "?")), HCTimeTrialScript.format_time(float(rd.get("time", 0.0))), veh_note]
	else:
		_ghost_status_lbl.text = "Rival: none imported for %s yet." % str(MAPS[_map].name)

## Cycle to the next map from the shop/death-screen "MAP" row.
func _cycle_map() -> void:
	if _audio:
		_audio.call("play_click")
	var i: int = MAP_KEYS.find(_map)
	_map = MAP_KEYS[(i + 1) % MAP_KEYS.size()]
	_apply_map()
	_refresh_map_buttons()

## Refresh the "MAP: <name>" readout in the shop/death screen, if built.
func _update_map_row() -> void:
	if _map_row_lbl:
		_map_row_lbl.text = "MAP:  %s" % MAPS[_map].name

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
	_update_trial(delta)
	_update_audio(delta)
	if _scenery:
		_scenery.call("update_follow", _car.global_position, delta)
	# on death, bank money earned from how far down the track you got, open the shop
	var d: bool = _car.get("dead")
	if d and not _was_dead:
		_was_dead = true
		_last_earned = int(float(_car.get("distance")) * MONEY_PER_M * _cash_mult())
		money += _last_earned
		var dist_now: float = _car.get("distance")
		if dist_now > float(_best.get(_map, 0.0)):
			_best[_map] = dist_now   # new PB on this map
		if _ghost and _trial_active and not _trial_finished:
			_ghost.call("stop_recording")   # crashed before the line — this attempt's recording is dead weight
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
	if la_active and _terrain != null and _terrain.has_method("path_ahead"):
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
	# loop-de-loop zones: trail-behind hides the car behind the ribbon up top —
	# swing to a ring-side vantage at hub height; the position lerp below eases
	# the camera out and back in, and the occlusion ray still protects the view.
	if _terrain != null and _terrain.has_method("loop_state"):
		var lst: Dictionary = _terrain.call("loop_state", target)
		if bool(lst.get("active", false)):
			want = (lst.e as Vector3) + Vector3.UP * float(lst.R) \
					+ (lst.right as Vector3) * (float(lst.shift) * 0.5 + 26.0)
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
	if _terrain and _terrain.has_method("reset_pickups"):
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
	_reset_run_mode_state()
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

## One balloon burst (charge drained past a whole balloon / hard-landing chunk loss).
func _on_balloon_pop() -> void:
	if _audio:
		_audio.call("play_balloon_pop")

## Combo juice: every chained trick thumps the combo label with an escalating blip,
## a bank flashes the score gold, a drop stings. All audio stays _audio-guarded.
func _on_car_combo(kind: String, _amount: int, chain: int) -> void:
	if _audio:
		match kind:
			"trick":
				_audio.call("play_combo", chain)
			"bank":
				_audio.call("play_bank")
			"drop":
				_audio.call("play_combo_lost")
	if kind == "trick" and _combo_lbl:
		# scale-thump the readout so each chained trick lands visibly
		_combo_lbl.pivot_offset = _combo_lbl.size * 0.5
		_combo_lbl.scale = Vector2(1.3, 1.3)
		if _combo_pulse_tween and _combo_pulse_tween.is_valid():
			_combo_pulse_tween.kill()
		_combo_pulse_tween = create_tween()
		_combo_pulse_tween.tween_property(_combo_lbl, "scale", Vector2.ONE, 0.22)\
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	elif kind == "bank" and _score_lbl:
		_score_lbl.modulate = Color(1.6, 1.4, 0.7)
		if _score_flash_tween and _score_flash_tween.is_valid():
			_score_flash_tween.kill()
		_score_flash_tween = create_tween()
		_score_flash_tween.tween_property(_score_lbl, "modulate", Color.WHITE, 0.5)
	elif kind == "drop":
		_shake = maxf(_shake, 0.25)   # losing the pot should physically sting a little

# --- sprint mode: race the clock on "sprint"-mode maps (currently: canyon) --------

## Reseed BOTH alternate run modes for the (possibly new) active map/vehicle: sprint's
## countdown (opt-in per map via MAPS[_map].mode — classic maps stay inactive, no timer
## shown, no death-on-zero) and time-trial's timer/splits/ghost. Sprint always wins on
## maps that declare it (canyon) — the title-screen Classic/Time Trial toggle only takes
## effect on maps that don't have their own mode, so canyon always plays like canyon
## regardless of _run_mode.
func _reset_run_mode_state() -> void:
	_sprint_active = MAPS[_map].mode == "sprint"
	_sprint_time = SPRINT_TIME
	_sprint_next_checkpoint = SPRINT_CHECKPOINT_M
	_trial_active = (not _sprint_active) and _run_mode == "trial" and HCTimeTrialScript.supports(_map)
	_trial_time = 0.0
	_trial_finished = false
	_trial_splits_hit.clear()
	_trial_result = ""
	_load_ghost_for_current()
	if _ghost:
		if _trial_active and _car:
			_ghost.call("start_recording", _car)
		else:
			_ghost.call("stop_recording")
			_ghost.call("hide_ghost")

func _trial_key(map_key: String, vehicle_key: String) -> String:
	return "%s|%s" % [map_key, vehicle_key]

## Load the saved ghost (if any) for the active map+vehicle into the shared HCGhostScript
## node so it plays back this run. Cleared (no ghost shown) outside trial mode or
## when there's no saved best yet. Also (re)loads the imported RIVAL ghost for the
## active map, if any — rivals are keyed by map only (see _rival_data), so a rival
## races alongside your personal-best ghost regardless of which vehicle recorded it;
## either, both, or neither can be present and each shows independently.
func _load_ghost_for_current() -> void:
	if _ghost:
		var key := _trial_key(_map, _vehicle)
		if _trial_active and _ghost_data.has(key):
			_ghost.call("load_data", _ghost_data[key])
		else:
			_ghost.call("clear_data")
	if _rival_ghost:
		var rd: Dictionary = _rival_data.get(_map, {})
		if _trial_active and rd.has("data"):
			_rival_ghost.call("configure", Color(1.0, 0.25, 0.22, 0.4), str(rd.get("name", "RIVAL")))
			_rival_ghost.call("load_data", rd["data"])
		else:
			_rival_ghost.call("clear_data")

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
			_audio.call("play_checkpoint")
	_sprint_time -= delta
	if _sprint_time <= 0.0:
		_sprint_time = 0.0
		_car.set("health", 0.0)   # normal death/shop flow takes it from here

# --- time trial mode: race the clock to a fixed finish distance, keyed per map -----

## Tick the live trial clock, fire split call-outs, keep the ghost recording/playing,
## and detect the finish line. Unlike sprint, crossing the finish does NOT end the
## run — it banks the record/ghost and driving continues classic-style.
func _update_trial(delta: float) -> void:
	if _ghost:
		_ghost.call("tick_record", delta)   # no-op unless a recording is in progress
	if not _trial_active or _car == null or bool(_car.get("dead")):
		return
	if not _trial_finished:
		_trial_time += delta
		var dist: float = _car.get("distance")
		var splits := HCTimeTrialScript.split_distances(_map)
		for i in range(splits.size()):
			if not _trial_splits_hit.has(i) and dist >= splits[i]:
				_trial_splits_hit[i] = true
				_car.set("trick_text", "SPLIT %d — %s" % [i + 1, HCTimeTrialScript.format_time(_trial_time)])
				_car.set("_trick_timer", 1.6)
				if _audio:
					_audio.call("play_click")
		if dist >= HCTimeTrialScript.finish_distance(_map):
			_finish_trial()
	if _ghost:
		_ghost.call("show_at", _trial_time)
	if _rival_ghost:
		_rival_ghost.call("show_at", _trial_time)   # never records — just plays back the imported file

## Bank a finished trial run: compare against the saved best, persist a new record +
## ghost if this run is faster (or the first clean finish on this map+vehicle), and
## announce it through the same trick-text HUD channel sprint checkpoints use.
func _finish_trial() -> void:
	_trial_finished = true
	var key := _trial_key(_map, _vehicle)
	var prev: float = float(_best_time.get(key, -1.0))
	var is_best: bool = prev < 0.0 or _trial_time < prev
	var medal := HCTimeTrialScript.medal_for(_map, _trial_time)
	var glyph := HCTimeTrialScript.medal_glyph(medal)
	if is_best:
		_best_time[key] = _trial_time
		if _ghost:
			var data: Array = _ghost.call("recorded_data")
			if data.size() > 0:
				_ghost_data[key] = data   # this run becomes the new ghost others race against
		_trial_result = "FINISH!  %s  —  NEW BEST!  %s" % [HCTimeTrialScript.format_time(_trial_time), glyph]
		_car.set("trick_text", "🏁 NEW BEST  %s  %s" % [HCTimeTrialScript.format_time(_trial_time), glyph])
	else:
		_trial_result = "FINISH!  %s   (best %s)  %s" % [HCTimeTrialScript.format_time(_trial_time), HCTimeTrialScript.format_time(prev), glyph]
		_car.set("trick_text", "🏁 FINISH  %s  %s" % [HCTimeTrialScript.format_time(_trial_time), glyph])
	_car.set("_trick_timer", 3.0)
	if _ghost:
		_ghost.call("stop_recording")
	if _audio:
		_audio.call("play_cash")
	_save_game()   # bank the record/ghost immediately — don't wait for a death that may not come soon

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
	# Party Balloons: roof bundle + airborne float (hold F)
	if _car.has_method("apply_balloons"):
		_car.call("apply_balloons", _levels.balloons)
	# (Downforce/Aerodynamics are pure mechanical tuning now — no chassis resize.)
	_apply_cosmetics()   # cosmetics, re-applied on every rebuild/swap

## Title screen: logo, a Classic/Time-Trial mode toggle, map CARDS (accent colour +
## description + best distance/time+medal), a vehicle strip, and START. Pauses the
## whole game (process_mode ALWAYS so the panel still runs) until START, then
## unpauses and frees itself.
##
## ADAPTIVE layout throughout (CenterContainer + an internal ScrollContainer, never
## a hand-placed offset) — the old fixed-size panel once pushed START below the
## 720px window edge; every growable section here is wrapped in the scroller instead
## so it degrades to "scrolls" rather than "breaks" if it ever runs long on content.
func _build_start_menu() -> void:
	_start_layer = CanvasLayer.new()
	_start_layer.layer = 20                       # above the HUD and the shop
	_start_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_start_layer)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.03, 0.03, 0.05, 0.93)
	_start_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_start_layer.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(760, 0)
	_style_panel(panel, Color(0.07, 0.075, 0.1, 0.97), Color(0.32, 0.34, 0.42), 1, 16)
	center.add_child(panel)
	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 22)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	# --- logo -----------------------------------------------------------------
	var title_lbl := _shop_label(box, "🏎  HILL CLIMB RACER", 36, Color(1, 0.82, 0.42))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sub_lbl := _shop_label(box, "Drive as far as you can — or race the clock. Fuel is your timer.", 14, Color(0.68, 0.74, 0.86))
	sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(HSeparator.new())

	# scrollable middle: mode toggle + map cards + vehicle strip + control legend, so
	# this whole section can grow without ever pushing START off the 720px window
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(716, 434)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(sc)
	var scb := VBoxContainer.new()
	scb.add_theme_constant_override("separation", 10)
	scb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(scb)

	_build_mode_toggle(scb)

	_shop_label(scb, "SELECT MAP", 13, Color(0.6, 0.64, 0.72))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	scb.add_child(grid)
	_map_btns.clear()
	_map_card_stat_lbl.clear()
	for mk in MAP_KEYS:
		_build_map_card(grid, mk)
	_refresh_map_buttons()

	scb.add_child(HSeparator.new())
	_build_ghost_row(scb)

	scb.add_child(HSeparator.new())
	_build_title_vehicle_row(scb)

	scb.add_child(HSeparator.new())
	_shop_label(scb, "CONTROLS", 13, Color(0.6, 0.64, 0.72))
	var hints := HBoxContainer.new()
	hints.alignment = BoxContainer.ALIGNMENT_CENTER
	hints.add_theme_constant_override("separation", 14)
	scb.add_child(hints)
	_nav_hint(hints, "W/S · RT/LT", "Throttle/Brake")
	_nav_hint(hints, "A/D · ⇦⇨", "Steer")
	_nav_hint(hints, "Space · LB", "Dive")
	_nav_hint(hints, "Ctrl · RB", "Boost")
	_nav_hint(hints, "R · Y", "Recover")
	_nav_hint(hints, "Tab · ☰", "Garage")
	_nav_hint(hints, "Esc", "Pause")
	var tip := _shop_label(scb, "Drift corners by braking into the turn or flicking the wheel hard. Every upgrade changes HOW the car handles, not just the numbers — try them all in the Garage.", 12, Color(0.62, 0.66, 0.74))
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

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

## Classic (default, endless) vs Time Trial (race the clock to a finish line — see
## HCTimeTrialScript). A segmented pair of toggle buttons rather than a checkbox so both
## states are always visible at a glance. Sprint-only maps (canyon) ignore this
## entirely — see _reset_run_mode_state.
func _build_mode_toggle(parent: Node) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	_mode_btns.clear()
	for mode_key in ["classic", "trial"]:
		var b := Button.new()
		b.text = "🏁  CLASSIC" if mode_key == "classic" else "⏱  TIME TRIAL"
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(170, 38)
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(_on_title_mode_button.bind(mode_key))
		row.add_child(b)
		_mode_btns[mode_key] = b
	_refresh_mode_buttons()

func _on_title_mode_button(mode_key: String) -> void:
	if _audio:
		_audio.call("play_click")
	if mode_key == _run_mode:
		return
	_run_mode = mode_key
	_reset_run_mode_state()
	_refresh_mode_buttons()
	_refresh_map_buttons()
	_save_game()

func _refresh_mode_buttons() -> void:
	for k in _mode_btns:
		if is_instance_valid(_mode_btns[k]):
			(_mode_btns[k] as Button).button_pressed = (k == _run_mode)

## One map "card": a toggle Button styled as a panel (accent-tinted border, brighter
## when selected/hovered) with its real content — name/description/stat line — laid
## on top as IGNORE-mouse-filter children so clicks fall through to the Button
## underneath. custom_minimum_size keeps every card the same footprint regardless of
## how long its description runs.
func _build_map_card(parent: Node, mk: String) -> void:
	var m: Dictionary = MAPS[mk]
	var accent: Color = m.get("accent", Color(0.6, 0.62, 0.68))
	var card := Button.new()
	card.text = ""
	card.toggle_mode = true
	card.focus_mode = Control.FOCUS_ALL
	card.custom_minimum_size = Vector2(330, 108)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.tooltip_text = str(m.desc)
	var normal_sb := _panel_style(Color(0.09, 0.095, 0.12, 0.9), Color(accent.r, accent.g, accent.b, 0.35), 1, 10)
	var hover_sb := _panel_style(Color(0.12, 0.125, 0.16, 0.94), accent, 2, 10)
	var pressed_sb := _panel_style(Color(0.1, 0.11, 0.15, 0.97), accent, 3, 10)
	card.add_theme_stylebox_override("normal", normal_sb)
	card.add_theme_stylebox_override("hover", hover_sb)
	card.add_theme_stylebox_override("pressed", pressed_sb)
	card.add_theme_stylebox_override("focus", hover_sb)
	card.pressed.connect(_on_title_map_button.bind(mk))
	parent.add_child(card)

	var cpad := MarginContainer.new()
	cpad.set_anchors_preset(Control.PRESET_FULL_RECT)
	cpad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for cm in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		cpad.add_theme_constant_override(cm, 10)
	card.add_child(cpad)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 3)
	cpad.add_child(vb)

	var name_lbl := Label.new()
	name_lbl.text = str(m.name)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.add_theme_color_override("font_color", accent)
	vb.add_child(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.text = str(m.desc)
	desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.clip_text = true
	desc_lbl.custom_minimum_size = Vector2(300, 38)
	desc_lbl.add_theme_font_size_override("font_size", 12)
	desc_lbl.add_theme_color_override("font_color", Color(0.68, 0.7, 0.76))
	vb.add_child(desc_lbl)

	var hs := HSeparator.new()
	hs.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(hs)
	var stat_lbl := Label.new()
	stat_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stat_lbl.add_theme_font_size_override("font_size", 12)
	stat_lbl.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	vb.add_child(stat_lbl)
	_map_btns[mk] = card
	_map_card_stat_lbl[mk] = stat_lbl

## Compact title-screen row for Stage 1 async multiplayer ("send a friend your
## ghost"): export the personal-best ghost for the currently-selected map+vehicle to
## a standalone file, reveal the folder it landed in (so it can be attached/AirDropped/
## etc. to a friend), import a friend's file as this map's RIVAL ghost, or clear it.
## Deliberately terse — one row + one status line — so it never threatens the 720px
## window budget (CLAUDE.md invariant 4); all four actions no-op gracefully with a
## message in the status line rather than erroring.
func _build_ghost_row(parent: Node) -> void:
	_shop_label(parent, "GHOSTS — share your best run", 13, Color(0.6, 0.64, 0.72))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	var export_btn := Button.new()
	export_btn.text = "⬆ Export Best"
	export_btn.custom_minimum_size = Vector2(132, 32)
	export_btn.add_theme_font_size_override("font_size", 12)
	export_btn.pressed.connect(_export_best_ghost)
	row.add_child(export_btn)
	var folder_btn := Button.new()
	folder_btn.text = "📂 Folder"
	folder_btn.custom_minimum_size = Vector2(84, 32)
	folder_btn.add_theme_font_size_override("font_size", 12)
	folder_btn.pressed.connect(_reveal_ghosts_folder)
	row.add_child(folder_btn)
	var import_btn := Button.new()
	import_btn.text = "⬇ Import Rival"
	import_btn.custom_minimum_size = Vector2(132, 32)
	import_btn.add_theme_font_size_override("font_size", 12)
	import_btn.pressed.connect(_open_import_dialog)
	row.add_child(import_btn)
	var clear_btn := Button.new()
	clear_btn.text = "✕ Clear Rival"
	clear_btn.custom_minimum_size = Vector2(112, 32)
	clear_btn.add_theme_font_size_override("font_size", 12)
	clear_btn.pressed.connect(_clear_rival_ghost)
	row.add_child(clear_btn)
	_ghost_status_lbl = _shop_label(parent, "", 12, Color(0.72, 0.76, 0.84))
	_ghost_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ghost_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_refresh_ghost_row()

## Write the personal-best ghost for the CURRENTLY SELECTED map+vehicle to a standalone
## .hcghost file under GHOST_DIR. No-ops (with a status message, not an error) if
## there's no best ghost yet for this exact map+vehicle pairing.
func _export_best_ghost() -> void:
	if _audio:
		_audio.call("play_click")
	var key := _trial_key(_map, _vehicle)
	if not _ghost_data.has(key):
		_show_ghost_status("No best ghost yet for %s / %s — finish a time trial there first." % [str(MAPS[_map].name), str(VEHICLES[_vehicle].name)])
		return
	var data: Array = _ghost_data[key]
	var time: float = float(_best_time.get(key, 0.0))
	var dir := _ghost_dir()
	if DirAccess.make_dir_recursive_absolute(dir) not in [OK, ERR_ALREADY_EXISTS]:
		_show_ghost_status("Export failed — couldn't create the ghosts folder.")
		return
	var fname := "%s_%s_%ss.hcghost" % [_map, _vehicle, "%.2f" % time]
	var payload := {
		"hcghost_version": HCGhostScript.VERSION,
		"map": _map,
		"vehicle": _vehicle,
		"time": time,
		"sample_hz": HCGhostScript.SAMPLE_HZ,
		"samples": data,
		"checksum": HCGhostScript.checksum(data, time),
	}
	var f := FileAccess.open(dir + "/" + fname, FileAccess.WRITE)
	if f == null:
		_show_ghost_status("Export failed — couldn't write the file.")
		return
	f.store_string(JSON.stringify(payload))
	f.close()
	_show_ghost_status("Exported %s — hit 📂 Folder to grab it." % fname)

## Open the (globalized) ghosts folder in the OS file browser so the owner can attach
## an exported .hcghost to an email/chat. Never called automatically from export —
## kept as its own explicit action so headless probes never trigger a real OS window.
func _reveal_ghosts_folder() -> void:
	if _audio:
		_audio.call("play_click")
	var dir := _ghost_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	OS.shell_open(ProjectSettings.globalize_path(dir))

## Native "open file" dialog scoped to *.hcghost, filesystem-rooted at the ghosts
## folder. Built lazily (once) and reused; Godot's FileDialog is a Window, so it can
## be added directly under the root and popped up on demand.
func _open_import_dialog() -> void:
	if _audio:
		_audio.call("play_click")
	if _ghost_file_dialog == null and _start_layer:
		_ghost_file_dialog = FileDialog.new()
		_ghost_file_dialog.title = "Import a friend's ghost"
		_ghost_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_ghost_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_ghost_file_dialog.add_filter("*.hcghost", "Hill Climb ghost file")
		_ghost_file_dialog.size = Vector2i(640, 460)
		_ghost_file_dialog.file_selected.connect(_on_ghost_file_selected)
		# parented under the title screen's ALWAYS-processing layer (see _build_start_menu)
		# so it works while get_tree().paused is true, and is cleaned up automatically
		# when _begin_game() frees _start_layer
		_start_layer.add_child(_ghost_file_dialog)
	if _ghost_file_dialog == null:
		return
	DirAccess.make_dir_recursive_absolute(_ghost_dir())
	_ghost_file_dialog.current_dir = ProjectSettings.globalize_path(_ghost_dir())
	_ghost_file_dialog.popup_centered()

func _on_ghost_file_selected(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_show_ghost_status("Couldn't open that file.")
		return
	var txt := f.get_as_text()
	f.close()
	var res := import_rival_ghost_text(txt, path.get_file().get_basename())
	_show_ghost_status(str(res.get("msg", "")))

## Core import validator + applier — deliberately takes raw JSON TEXT (not a path) so
## it works identically from the real FileDialog and from a headless probe that never
## touches a native dialog. Validates version, map key, sample shape, and the
## checksum (in that order, cheapest/most-decisive checks first) before storing the
## rival under its OWN map key (see _rival_data doc comment — NOT the currently
## selected title-screen map, so importing a canyon ghost while alpine is selected
## still lands correctly). Returns {"ok": bool, "msg": String}.
func import_rival_ghost_text(json_text: String, source_name: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(json_text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {"ok": false, "msg": "Not a valid ghost file."}
	var d: Dictionary = json.data
	if int(d.get("hcghost_version", -1)) != HCGhostScript.VERSION:
		return {"ok": false, "msg": "Ghost file is from an incompatible version."}
	var map_in := str(d.get("map", ""))
	if not MAPS.has(map_in):
		return {"ok": false, "msg": "Ghost file is for an unknown map (\"%s\")." % map_in}
	var samples: Array = d.get("samples", [])
	var time_in := float(d.get("time", -1.0))
	if samples.is_empty() or samples.size() % int(HCGhostScript.FLOATS_PER_SAMPLE) != 0 or time_in <= 0.0:
		return {"ok": false, "msg": "Ghost file is malformed."}
	var expect_cs := int(d.get("checksum", 0))
	if expect_cs != HCGhostScript.checksum(samples, time_in):
		return {"ok": false, "msg": "Ghost file failed its integrity check (corrupted?)."}
	var vehicle_in := str(d.get("vehicle", ""))
	_rival_data[map_in] = {
		"vehicle": vehicle_in,
		"time": time_in,
		"data": samples,
		"name": source_name,
	}
	if map_in == _map:
		_load_ghost_for_current()   # already on this map — swap the live rival in immediately
	_refresh_ghost_row()
	_refresh_map_buttons()
	_save_game()
	var veh_note := "" if not VEHICLES.has(vehicle_in) or vehicle_in == "" else "  (recorded in %s)" % str(VEHICLES[vehicle_in].name)
	return {"ok": true, "msg": "Rival loaded for %s: %s — %s%s" % [str(MAPS[map_in].name), source_name, HCTimeTrialScript.format_time(time_in), veh_note]}

## Drop the rival ghost for the CURRENTLY SELECTED map only (rivals are per-map — see
## _rival_data). No-ops with a status message if there isn't one.
func _clear_rival_ghost() -> void:
	if _audio:
		_audio.call("play_click")
	if not _rival_data.has(_map):
		_show_ghost_status("No rival set for %s." % str(MAPS[_map].name))
		return
	_rival_data.erase(_map)
	if _rival_ghost:
		_rival_ghost.call("clear_data")
	_save_game()
	_show_ghost_status("Rival cleared for %s." % str(MAPS[_map].name))
	_refresh_ghost_row()

func _show_ghost_status(msg: String) -> void:
	if _ghost_status_lbl and is_instance_valid(_ghost_status_lbl):
		_ghost_status_lbl.text = msg

## GHOST_DIR_DEFAULT, unless a probe has redirected exports via ghost_dir_override
## (see its doc comment) — keeps headless tests from ever touching the real folder.
func _ghost_dir() -> String:
	return ghost_dir_override if ghost_dir_override != "" else GHOST_DIR_DEFAULT

## Title-screen vehicle strip: pick the STARTING ride without opening the Garage.
## Owned rides are selectable; locked ones show a price/lock and just tooltip-hint
## "unlock in the Garage" rather than letting you buy from the title screen (buying
## needs the shop's money readout/context, which doesn't exist here).
func _build_title_vehicle_row(parent: Node) -> void:
	_shop_label(parent, "VEHICLE", 13, Color(0.6, 0.64, 0.72))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	_veh_title_btns.clear()
	for vk in VEH_KEYS:
		var b := Button.new()
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 38)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_on_title_vehicle_button.bind(vk))
		row.add_child(b)
		_veh_title_btns[vk] = b
	_refresh_title_vehicle_buttons()

func _on_title_vehicle_button(vk: String) -> void:
	if _audio:
		_audio.call("play_click")
	if _vehicle == vk or not bool(_owned.get(vk, false)):
		return   # locked rides are unlocked from the Garage (Tab), not here
	_swap_vehicle(vk)
	_refresh_title_vehicle_buttons()
	_refresh_map_buttons()   # best-TIME column is per-vehicle; the active ride just changed

func _refresh_title_vehicle_buttons() -> void:
	for vk in VEH_KEYS:
		if not _veh_title_btns.has(vk) or not is_instance_valid(_veh_title_btns[vk]):
			continue
		var b: Button = _veh_title_btns[vk]
		var owned: bool = bool(_owned.get(vk, false))
		b.button_pressed = (_vehicle == vk)
		b.disabled = not owned
		if _vehicle == vk:
			b.text = "✓ " + str(VEHICLES[vk].name)
		elif owned:
			b.text = str(VEHICLES[vk].name)
		else:
			b.text = "🔒 " + str(VEHICLES[vk].name)
		b.tooltip_text = str(VEHICLES[vk].desc) if owned else "%s — $%d (unlock in the Garage)" % [str(VEHICLES[vk].name), int(VEHICLES[vk].price)]

## Leave the title screen: unpause and drop the overlay.
func _begin_game() -> void:
	if _audio:
		_audio.call("play_click")
	get_tree().paused = false
	if _start_layer:
		_start_layer.queue_free()
		_start_layer = null
	_ghost_file_dialog = null   # was a child of _start_layer — freed with it above
	_ghost_status_lbl = null

# --- pause menu: ESC during a live run (not the title, not the garage) -------------

var _pause_layer: CanvasLayer
var _pause_resume_btn: Button
var _fullscreen_btn: Button
var master_volume := 1.0   # linear 0-1, persisted; pushed onto _audio (see _apply_volume)
var _pre_mute_volume := 1.0   # level to restore when un-muting (M brings sound back to here)
var _vol_slider: HSlider   # the pause-menu slider, kept in sync when hotkeys change volume

## Build the pause overlay once (hidden) — same "build hidden, toggle .visible" shape
## as the shop, and the same PROCESS_MODE_ALWAYS + get_tree().paused pattern the title
## screen uses (CLAUDE.md invariant: anything that pauses the tree must opt itself out
## of that pause to keep receiving input).
func _build_pause_menu() -> void:
	_pause_layer = CanvasLayer.new()
	_pause_layer.layer = 15   # above the shop (10) and HUD, below the title (20)
	_pause_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause_layer.visible = false
	add_child(_pause_layer)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.02, 0.05, 0.82)
	_pause_layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_layer.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	_style_panel(panel, Color(0.08, 0.09, 0.12, 0.97), Color(0.4, 0.44, 0.55), 1, 14)
	center.add_child(panel)
	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 22)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	_shop_label(box, "PAUSED", 26, Color(1, 0.82, 0.42))
	box.add_child(HSeparator.new())

	_pause_resume_btn = _menu_button(box, "▶  Resume", _toggle_pause_menu)
	# HCMain._input is gated by the SceneTree pause (Node process_mode PAUSABLE, the
	# default) so it can't hear ESC while paused — only this ALWAYS-mode subtree can.
	# A Shortcut on the Resume button routes ESC through Control's own (pause-exempt)
	# shortcut-input path instead, so ESC both opens AND closes the pause menu.
	var esc_shortcut := Shortcut.new()
	esc_shortcut.events = [_key(KEY_ESCAPE)]
	_pause_resume_btn.shortcut = esc_shortcut
	_menu_button(box, "⟲  Restart Run", _pause_restart)
	_menu_button(box, "🏠  Main Menu", _go_to_main_menu)
	_fullscreen_btn = _menu_button(box, "⛶  Fullscreen", _toggle_fullscreen)

	box.add_child(HSeparator.new())
	var vol_row := HBoxContainer.new()
	vol_row.add_theme_constant_override("separation", 10)
	box.add_child(vol_row)
	var vol_lbl := Label.new()
	vol_lbl.text = "Volume"
	vol_lbl.add_theme_font_size_override("font_size", 14)
	vol_lbl.add_theme_color_override("font_color", Color(0.5, 0.52, 0.58))
	vol_lbl.custom_minimum_size = Vector2(70, 0)
	vol_row.add_child(vol_lbl)
	_vol_slider = HSlider.new()
	_vol_slider.min_value = 0; _vol_slider.max_value = 100
	_vol_slider.value = master_volume * 100.0
	_vol_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vol_slider.value_changed.connect(_on_volume_changed)
	vol_row.add_child(_vol_slider)
	var vol_note := _shop_label(box, "or press  −  /  =  to adjust,  M  to mute — anytime, no menu needed", 11, Color(0.45, 0.47, 0.52))
	vol_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

## Volume slider → persisted setting, pushed onto _audio when audio finally lands.
## The parallel audio pass exposes master_volume (linear 0-1) on HCAudio; this is the
## exact hook: whoever instances HCAudio should also call _apply_volume() once.
func _on_volume_changed(v: float) -> void:
	master_volume = clampf(v / 100.0, 0.0, 1.0)
	_apply_volume()
	_save_game()

func _apply_volume() -> void:
	if _audio:
		_audio.set("master_volume", master_volume)

## Hotkey volume step (±0.1). Clamps, applies to the live synth, persists, syncs the
## pause-menu slider (no_signal so we don't loop back through _on_volume_changed), and
## flashes the on-screen readout. Any positive level also arms un-mute restore.
func _adjust_volume(delta: float) -> void:
	master_volume = clampf(master_volume + delta, 0.0, 1.0)
	if master_volume > 0.0:
		_pre_mute_volume = master_volume
	_apply_volume()
	_save_game()
	if _vol_slider:
		_vol_slider.set_value_no_signal(master_volume * 100.0)
	_flash_volume_toast()

## M toggles between silent and the last audible level (defaults to full if muted from 0).
func _toggle_mute() -> void:
	if master_volume > 0.0:
		_pre_mute_volume = master_volume
		master_volume = 0.0
	else:
		master_volume = _pre_mute_volume if _pre_mute_volume > 0.0 else 1.0
	_apply_volume()
	_save_game()
	if _vol_slider:
		_vol_slider.set_value_no_signal(master_volume * 100.0)
	_flash_volume_toast()

## Small top-center "🔊 70%" readout that fades after any volume/mute change. Lives on its
## own ALWAYS-mode layer + tween so it still animates while the tree is paused.
func _build_volume_toast() -> void:
	_vol_toast_layer = CanvasLayer.new()
	_vol_toast_layer.layer = 16   # above the pause menu (15), below the title (20)
	_vol_toast_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_vol_toast_layer)
	_vol_toast = Label.new()
	_vol_toast.anchor_left = 0.5; _vol_toast.anchor_right = 0.5
	_vol_toast.anchor_top = 0.0; _vol_toast.anchor_bottom = 0.0
	_vol_toast.offset_left = -110; _vol_toast.offset_right = 110
	_vol_toast.offset_top = 24; _vol_toast.offset_bottom = 64
	_vol_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vol_toast.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_vol_toast.add_theme_font_size_override("font_size", 22)
	_vol_toast.add_theme_color_override("font_color", Color(1, 0.9, 0.55))
	_vol_toast.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_vol_toast.add_theme_constant_override("outline_size", 6)
	_vol_toast.modulate.a = 0.0
	_vol_toast_layer.add_child(_vol_toast)

var _vol_toast_layer: CanvasLayer
var _vol_toast: Label
var _vol_toast_tween: Tween

func _flash_volume_toast() -> void:
	if _vol_toast == null:
		return
	var pct: int = int(round(master_volume * 100.0))
	_vol_toast.text = ("🔇  Muted" if master_volume <= 0.0 else "🔊  %d%%" % pct)
	_vol_toast.modulate.a = 1.0
	if _vol_toast_tween and _vol_toast_tween.is_valid():
		_vol_toast_tween.kill()
	# bind the tween to the ALWAYS-mode layer so the fade runs even while paused
	_vol_toast_tween = _vol_toast_layer.create_tween()
	_vol_toast_tween.tween_interval(0.9)
	_vol_toast_tween.tween_property(_vol_toast, "modulate:a", 0.0, 0.5)

## Continuous audio: engine follows speed/throttle every frame; drift/boost loops
## start/stop on state EDGES (the synth manages its own envelopes, so re-calling
## start every frame would retrigger the attack).
func _update_audio(_delta: float) -> void:
	if not _audio or _car == null:
		return
	var car_dead: bool = _car.get("dead")
	var spd: float = _car.linear_velocity.length()
	var max_spd: float = maxf(float(_car.get("max_speed")), 1.0)
	var throttle: float = 0.0 if car_dead else float(_car.get("_prev_drive"))
	_audio.call("set_engine", clampf(spd / max_spd, 0.0, 1.0), throttle)
	var is_drifting: bool = not car_dead and bool(_car.get("drifting"))
	if is_drifting != _was_drifting:
		_audio.call("start_drift" if is_drifting else "stop_drift")
		_was_drifting = is_drifting
	var is_boosting: bool = not car_dead and bool(_car.get("boosting"))
	if is_boosting != _was_boosting:
		_audio.call("start_boost" if is_boosting else "stop_boost")
		_was_boosting = is_boosting
	# balloon deploy: squeaky inflate on the rising edge only (pops arrive via signal)
	var is_floating: bool = not car_dead and bool(_car.get("floating"))
	if is_floating and not _was_floating:
		_audio.call("play_balloon_inflate")
	_was_floating = is_floating

## One consistently-styled full-width menu button; returns it so callers can keep a ref.
func _menu_button(parent: Node, text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 16)
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b

## ESC toggles the pause overlay during a live run only — a no-op over the title
## screen or the garage/wreck shop so the three full-screen states never fight.
func _toggle_pause_menu() -> void:
	if _pause_layer == null or _start_layer != null:
		return
	if _shop and _shop.visible:
		return
	if _pause_layer.visible:
		_pause_layer.visible = false
		get_tree().paused = false
	else:
		if _audio:
			_audio.call("play_click")
		_refresh_fullscreen_btn()
		_pause_layer.visible = true
		get_tree().paused = true
		if _pause_resume_btn:
			_pause_resume_btn.call_deferred("grab_focus")

## "Restart Run" from the pause menu: run the normal restart flow, then close the overlay.
func _pause_restart() -> void:
	_restart()
	_toggle_pause_menu()

func _toggle_fullscreen() -> void:
	var win := get_window()
	win.mode = Window.MODE_WINDOWED if win.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
	_refresh_fullscreen_btn()

func _refresh_fullscreen_btn() -> void:
	if _fullscreen_btn:
		var is_full := get_window().mode == Window.MODE_FULLSCREEN
		_fullscreen_btn.text = "⛶  Windowed Mode" if is_full else "⛶  Fullscreen"

## Save + reload the whole scene fresh, landing back on the (paused) title screen —
## the simplest correct way to "return to main menu" given how much live state a run
## touches (terrain, car, camera, HUD); reusing boot's own setup path beats hand-
## unwinding all of it here.
func _go_to_main_menu() -> void:
	if _audio:
		_audio.call("play_click")
	_save_game()
	get_tree().paused = false
	get_tree().reload_current_scene()

func _build_shop() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_shop = Control.new()
	_shop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop.visible = false
	layer.add_child(_shop)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.72)
	_shop.add_child(dim)

	# a fixed-size centered panel; the upgrade list inside scrolls so nothing
	# can ever run off the bottom of the screen no matter how many upgrades.
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(672, 700)
	panel.position = Vector2(-336, -350)
	_style_panel(panel, Color(0.07, 0.075, 0.1, 0.97), Color(0.32, 0.34, 0.42), 1, 16)   # same look as the title/pause overlays
	_shop.add_child(panel)
	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 18)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	pad.add_child(box)

	_shop_header = _shop_label(box, "", 26, Color(1, 0.82, 0.42))
	_shop_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shop_money = _shop_label(box, "", 19, Color(0.65, 1.0, 0.7))
	_shop_money.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sep := HSeparator.new()
	box.add_child(sep)

	# MAP switcher: change tracks between runs (cycles through MAPS + rebuilds).
	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 10)
	box.add_child(map_row)
	_map_row_lbl = Label.new()
	_map_row_lbl.add_theme_font_size_override("font_size", 15)
	_map_row_lbl.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0))
	_map_row_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_row.add_child(_map_row_lbl)
	var map_switch := Button.new()
	map_switch.text = "switch"
	map_switch.custom_minimum_size = Vector2(90, 32)
	map_switch.pressed.connect(_cycle_map)
	map_row.add_child(map_switch)
	_update_map_row()
	box.add_child(HSeparator.new())

	# Three tabs — Garage, Upgrades, Cosmetics — so no section crowds another and every
	# option stays on screen (LB/RB or Q/E switch tabs). Each tab scrolls on its own;
	# the RETRY / NEW GAME footer stays pinned below the tabs.
	_shop_tabs = TabContainer.new()
	_shop_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_shop_tabs.custom_minimum_size = Vector2(624, 430)
	_shop_tabs.tab_alignment = TabBar.ALIGNMENT_CENTER
	box.add_child(_shop_tabs)
	var garage_list := _make_tab("🚗  Garage")
	var upgrade_list := _make_tab("🔧  Upgrades")
	var cosmetic_list := _make_tab("✨  Cosmetics")

	# --- GARAGE tab: unlock / select a ride ------------------------------------
	var list := garage_list
	for vk in VEH_KEYS:
		var vrow := HBoxContainer.new()
		vrow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vrow.add_theme_constant_override("separation", 10)
		list.add_child(vrow)
		var vinfo := VBoxContainer.new()
		vinfo.custom_minimum_size = Vector2(360, 0)
		vinfo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vinfo.add_theme_constant_override("separation", 0)
		vrow.add_child(vinfo)
		var vlbl := Label.new()
		vlbl.add_theme_font_size_override("font_size", 17)
		vinfo.add_child(vlbl)
		var vdesc := Label.new()
		vdesc.text = VEHICLES[vk].desc
		vdesc.add_theme_font_size_override("font_size", 12)
		vdesc.add_theme_color_override("font_color", Color(0.62, 0.64, 0.7))
		vdesc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vdesc.custom_minimum_size = Vector2(360, 0)
		vinfo.add_child(vdesc)
		var vbuy := Button.new()
		vbuy.custom_minimum_size = Vector2(110, 40)
		vbuy.pressed.connect(_on_vehicle_button.bind(vk))
		vrow.add_child(vbuy)
		if _first_veh_btn == null:
			_first_veh_btn = vbuy
		_veh_rows[vk] = {"label": vlbl, "buy": vbuy}
	# --- BODY KIT: dress the active ride in an imported .glb shell -------------
	list.add_child(HSeparator.new())
	var khint := _shop_label(list, "BODY KIT — a 3-D model shell for the ACTIVE ride (free; drop .glb files into assets/car/). Wheels auto-fit to the model.", 13, Color(0.62, 0.64, 0.7))
	khint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var krow := HBoxContainer.new()
	krow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	krow.add_theme_constant_override("separation", 10)
	list.add_child(krow)
	_kit_lbl = Label.new()
	_kit_lbl.add_theme_font_size_override("font_size", 16)
	_kit_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	krow.add_child(_kit_lbl)
	var kbtn := Button.new()
	kbtn.text = "next kit ▸"
	kbtn.custom_minimum_size = Vector2(110, 40)
	kbtn.pressed.connect(_cycle_body_kit)
	krow.add_child(kbtn)
	# --- UPGRADES tab ----------------------------------------------------------
	list = upgrade_list
	for key in UP_KEYS:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 10)
		list.add_child(row)
		var info := VBoxContainer.new()
		info.custom_minimum_size = Vector2(300, 0)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_constant_override("separation", 0)
		row.add_child(info)
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 18)
		info.add_child(lbl)
		var desc := Label.new()
		desc.text = UP_DESC.get(key, "")
		desc.add_theme_font_size_override("font_size", 12)
		desc.add_theme_color_override("font_color", Color(0.62, 0.64, 0.7))
		info.add_child(desc)
		var sell := Button.new()
		sell.custom_minimum_size = Vector2(62, 40)
		sell.add_theme_color_override("font_color", Color(1.0, 0.7, 0.6))
		sell.pressed.connect(_sell.bind(key))
		row.add_child(sell)
		var buy := Button.new()
		buy.custom_minimum_size = Vector2(96, 40)
		buy.pressed.connect(_buy.bind(key))
		row.add_child(buy)
		_shop_rows[key] = {"label": lbl, "desc": desc, "buy": buy, "sell": sell}

	# --- COSMETICS tab: purely visual; buy cheap once, then pick a colour ------
	list = cosmetic_list
	var coshint := _shop_label(list, "Purely visual — buy once, then hover a swatch to preview it and click to apply.", 13, Color(0.62, 0.64, 0.7))
	coshint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for ck in COSM_KEYS:
		var c: Dictionary = COSMETICS[ck]
		var crow := HBoxContainer.new()
		crow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		crow.add_theme_constant_override("separation", 10)
		list.add_child(crow)
		var cinfo := Label.new()
		cinfo.text = str(c.name)
		cinfo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cinfo.add_theme_font_size_override("font_size", 18)
		crow.add_child(cinfo)
		# live preview: shows the colour you are hovering / have selected before you commit
		var cprev := Panel.new()
		cprev.custom_minimum_size = Vector2(72, 34)
		var pv_sb := StyleBoxFlat.new()
		pv_sb.bg_color = _cosm_color[ck]
		pv_sb.set_corner_radius_all(5)
		pv_sb.set_border_width_all(2)
		pv_sb.border_color = Color(1, 1, 1, 0.55)
		cprev.add_theme_stylebox_override("panel", pv_sb)
		crow.add_child(cprev)
		var cbuy := Button.new()
		cbuy.custom_minimum_size = Vector2(110, 40)
		cbuy.pressed.connect(_buy_cosmetic.bind(ck))
		crow.add_child(cbuy)
		var sw_row := HBoxContainer.new()
		sw_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sw_row.add_theme_constant_override("separation", 6)
		list.add_child(sw_row)
		var swatch_btns := []
		for col in c.colors:
			var sw := Button.new()
			sw.custom_minimum_size = Vector2(46, 32)
			var sb := StyleBoxFlat.new(); sb.bg_color = col; sb.set_corner_radius_all(4)
			# the SAME stylebox drives every state so the hover/selected ring shows in any state.
			for st in ["normal", "hover", "pressed", "focus"]:
				sw.add_theme_stylebox_override(st, sb)
			sw.pressed.connect(_pick_cosmetic.bind(ck, col))
			# hovering (mouse) or focusing (pad/keys) live-previews the colour + rings the swatch
			sw.mouse_entered.connect(_preview_cosmetic.bind(ck, col))
			sw.focus_entered.connect(_preview_cosmetic.bind(ck, col))
			sw_row.add_child(sw)
			swatch_btns.append({"btn": sw, "sb": sb, "color": col})
		_cosm_rows[ck] = {"buy": cbuy, "swatches": sw_row, "swatch_btns": swatch_btns, "preview": pv_sb}

	_restart_btn = Button.new()
	_restart_btn.text = "RETRY  (Enter / ⓑ)  —  keeps your garage"
	_restart_btn.custom_minimum_size = Vector2(0, 46)
	_restart_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_restart_btn.pressed.connect(_restart)
	box.add_child(_restart_btn)

	# Fresh start: wipe ALL progress (money, every vehicle's upgrades, unlocks) and
	# return to the starter Hot Rod. Two-click confirm so it can't be a mis-tap.
	_reset_btn = Button.new()
	_reset_btn.text = "🔄 NEW GAME  —  wipe ALL upgrades & money"
	_reset_btn.custom_minimum_size = Vector2(0, 40)
	_reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reset_btn.add_theme_color_override("font_color", Color(1.0, 0.62, 0.55))
	_reset_btn.pressed.connect(_on_reset_pressed)
	box.add_child(_reset_btn)

	# TEST-ONLY: instant cash so you can buy anything while iterating
	_money_btn = Button.new()
	_money_btn.text = "🧪 +$1,000,000  (test money)"
	_money_btn.custom_minimum_size = Vector2(0, 34)
	_money_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_money_btn.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	_money_btn.pressed.connect(_on_test_money)
	box.add_child(_money_btn)

	# navigation legend — keycap "icons" so it's obvious how to move through the menu
	box.add_child(HSeparator.new())
	var hints := HBoxContainer.new()
	hints.alignment = BoxContainer.ALIGNMENT_CENTER
	hints.add_theme_constant_override("separation", 16)
	box.add_child(hints)
	_nav_hint(hints, "Q / E  ·  ⇦⇨", "Tabs")
	_nav_hint(hints, "↑ / ↓", "Move")
	_nav_hint(hints, "← / →", "Sell / Buy")
	_nav_hint(hints, "⏎ · Ⓐ", "Select")
	_nav_hint(hints, "Tab · ☰", "Close")

	_wire_focus_chain()
	# connect AFTER the rows exist (adding tabs above fires tab_changed early, when the
	# row dicts are still empty). Now mouse tab clicks relink the focus ring too.
	_shop_tabs.tab_changed.connect(func(_i): _relink_active_chain())

## TEST-ONLY: dump a million dollars in the bank and refresh the shop.
func _on_test_money() -> void:
	money += 1000000
	_save_game()
	_refresh_shop()

## HOLD up/down (d-pad or arrow keys) to keep moving the shop focus, instead of tapping
## once per item. The first press is handled by the built-in nav; after a short delay
## this repeats while held.
func _shop_autoscroll(delta: float) -> void:
	if _shop == null or not _shop.visible:
		_scroll_repeat = 0.0
		return
	var dir := 0
	if Input.is_action_pressed("ui_down"):
		dir = 1
	elif Input.is_action_pressed("ui_up"):
		dir = -1
	if dir == 0:
		_scroll_repeat = 0.0
		return
	if Input.is_action_just_pressed("ui_down") or Input.is_action_just_pressed("ui_up"):
		_scroll_repeat = 0.4   # let the first tap move once, then wait before auto-repeating
		return
	_scroll_repeat -= delta
	if _scroll_repeat <= 0.0:
		_move_shop_focus(dir)
		_scroll_repeat = 0.08   # repeat cadence while held

func _move_shop_focus(dir: int) -> void:
	var f := get_viewport().gui_get_focus_owner()
	if f == null:
		return
	var np: NodePath = f.focus_neighbor_bottom if dir > 0 else f.focus_neighbor_top
	if np.is_empty():
		return
	var target := f.get_node_or_null(np)
	if target and target is Control:
		(target as Control).grab_focus()

## Build one scrolling tab (named `title`) in the TabContainer and return its content
## VBox to fill. follow_focus keeps the gamepad-focused row on screen as you walk it.
func _make_tab(title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.follow_focus = true
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 8)
	sc.add_child(vb)
	_shop_tabs.add_child(sc)
	_shop_tabs.set_tab_title(_shop_tabs.get_tab_count() - 1, title)
	return vb

## Cycle the visible tab (LB/RB or Q/E) and focus its first row.
func _switch_tab(dir: int) -> void:
	if _shop_tabs == null:
		return
	var n := _shop_tabs.get_tab_count()
	_shop_tabs.current_tab = (_shop_tabs.current_tab + dir + n) % n
	if _audio:
		_audio.call("play_click")
	_relink_active_chain()
	_focus_tab_first()

## Grab focus on the first button of the currently-visible tab.
func _focus_tab_first() -> void:
	var firsts := [
		_veh_rows[VEH_KEYS[0]].buy if _veh_rows.has(VEH_KEYS[0]) else null,
		_shop_rows[UP_KEYS[0]].buy if _shop_rows.has(UP_KEYS[0]) else null,
		_cosm_rows[COSM_KEYS[0]].buy if _cosm_rows.has(COSM_KEYS[0]) else null,
	]
	var t: int = clampi(_shop_tabs.current_tab, 0, firsts.size() - 1)
	if firsts[t]:
		(firsts[t] as Control).call_deferred("grab_focus")

## Wire the static bits (Buy<->Sell on upgrade rows) then link the ACTIVE tab. The
## per-tab ring is rebuilt on open / tab-switch so focus never escapes into a hidden
## tab's clipped rows (which would make the cursor vanish past the last visible item).
func _wire_focus_chain() -> void:
	for key in UP_KEYS:
		var b: Button = _shop_rows[key].buy
		var s: Button = _shop_rows[key].sell
		s.focus_mode = Control.FOCUS_ALL
		b.focus_neighbor_left = b.get_path_to(s)
		s.focus_neighbor_right = s.get_path_to(b)
	_relink_active_chain()

## Build ONE wrapping focus ring from the visible tab's Buy buttons + the shared footer,
## so d-pad up/down cycles only currently-visible controls. Every entry is on screen, so
## walking past the last item wraps back to the top instead of dropping focus.
func _relink_active_chain() -> void:
	if _shop_tabs == null or _veh_rows.is_empty() or _shop_rows.is_empty() or _cosm_rows.is_empty():
		return   # rows not built yet (tab_changed can fire mid-construction)
	var chain: Array[Control] = []
	match _shop_tabs.current_tab:
		1:
			for key in UP_KEYS:
				chain.append(_shop_rows[key].buy)
		2:
			for ck in COSM_KEYS:
				chain.append(_cosm_rows[ck].buy)
		_:
			for vk in VEH_KEYS:
				chain.append(_veh_rows[vk].buy)
	chain.append(_restart_btn)
	chain.append(_reset_btn)
	chain.append(_money_btn)
	_chain_focus(chain)

## Wire an ordered list of controls into a wrapping top/bottom focus ring.
func _chain_focus(chain: Array[Control]) -> void:
	var n := chain.size()
	for i in range(n):
		var cur: Control = chain[i]
		var nxt: Control = chain[(i + 1) % n]
		var prv: Control = chain[(i - 1 + n) % n]
		cur.focus_mode = Control.FOCUS_ALL
		cur.focus_neighbor_bottom = cur.get_path_to(nxt)
		cur.focus_neighbor_top = cur.get_path_to(prv)
		cur.focus_next = cur.get_path_to(nxt)
		cur.focus_previous = cur.get_path_to(prv)

## A rounded "keycap" chip (the boxed key/button icon) used by the nav legend.
func _key_chip(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.95, 0.96, 1.0))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.19, 0.21, 0.27)
	sb.set_corner_radius_all(5)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.42, 0.46, 0.55)
	sb.content_margin_left = 8; sb.content_margin_right = 8
	sb.content_margin_top = 3; sb.content_margin_bottom = 3
	l.add_theme_stylebox_override("normal", sb)
	return l

## One legend entry: a keycap chip + a short caption of what it does.
func _nav_hint(parent: Node, keys: String, caption: String) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.add_child(_key_chip(keys))
	var cap := Label.new()
	cap.text = caption
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", Color(0.66, 0.7, 0.78))
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(cap)
	parent.add_child(h)

func _shop_label(parent: Node, text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	parent.add_child(l)
	return l

## Shared "dark card" look for the title screen / pause menu / map cards — one place
## to keep every overlay panel visually consistent instead of each screen inventing
## its own StyleBoxFlat.
func _panel_style(bg: Color, border: Color, border_w: int = 1, radius: int = 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 14; sb.content_margin_right = 14
	sb.content_margin_top = 10; sb.content_margin_bottom = 10
	return sb

## Apply the shared panel look to an existing PanelContainer.
func _style_panel(p: PanelContainer, bg: Color, border: Color, border_w: int = 1, radius: int = 12) -> void:
	p.add_theme_stylebox_override("panel", _panel_style(bg, border, border_w, radius))

var _shop_summary := ""

func _show_shop() -> void:
	_shop_header.text = "WRECKED!"
	var best_m := int(float(_best.get(_map, 0.0)))
	_shop_summary = "You reached %d m  —  earned +$%d this run\nBEST: %d m" % [int(_car.get("distance")), _last_earned, best_m]
	if _trial_result != "":
		_shop_summary += "\n" + _trial_result   # trial finish recap, if this run crossed the line
	_shop.visible = true
	_refresh_shop()
	# focus RETRY so a gamepad can just press A to go again (d-pad to browse upgrades)
	if _restart_btn:
		_restart_btn.call_deferred("grab_focus")

func _toggle_shop() -> void:
	if _shop == null:
		return
	_shop.visible = not _shop.visible
	if _shop.visible:
		_shop_header.text = "GARAGE"
		_shop_summary = ""
		if _shop_tabs:
			_shop_tabs.current_tab = 0
		_refresh_shop()
		_relink_active_chain()
		if _first_veh_btn:
			_first_veh_btn.call_deferred("grab_focus")

## Vehicle row button: select if owned, otherwise buy if affordable.
func _on_vehicle_button(vk: String) -> void:
	if _audio:
		_audio.call("play_click")
	if _vehicle == vk:
		return
	if bool(_owned.get(vk, false)):
		_swap_vehicle(vk)
		return
	var price: int = int(VEHICLES[vk].price)
	if money < price:
		return
	money -= price
	_owned[vk] = true
	if _audio:
		_audio.call("play_cash")
	_swap_vehicle(vk)

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
	_car.set("road_half", _terrain.get("road_half") if USE_TRACK else _terrain.get("road_half_width"))
	_car.set("terrain", _terrain)
	if _terrain.has_method("spawn_pos"):
		_start = _terrain.call("spawn_pos")
	else:
		_start.y = _terrain.call("height_at", 0.0, 0.0) + 4.0
	_car.global_position = _start
	_terrain.call("set_target", _car)
	_car.connect("gap_failed", _on_car_gap_failed)
	_car.connect("landed", _on_car_landed)
	_car.connect("combo_event", _on_car_combo)
	_car.connect("balloon_pop", _on_balloon_pop)
	_terrain.connect("pickup_collected", _on_pickup_collected)
	if _audio:
		_audio.call("setup", _car)   # re-point the engine synth at the new body
	_apply_headlights()
	_apply_upgrades()
	_cam_heading = Vector3(0, 0, -1)
	_was_dead = false
	_reset_run_mode_state()
	_save_game()   # persists both the purchase (if any) and the new active vehicle
	if was_visible:
		_refresh_shop()

## Fresh-start button: first press arms (asks to confirm), second press wipes.
func _on_reset_pressed() -> void:
	if not _reset_armed:
		_reset_armed = true
		_reset_btn.text = "⚠ CONFIRM — wipe EVERYTHING?"
		return
	_fresh_start()

## Wipe all persistent progress and rebuild as the starter Hot Rod.
func _fresh_start() -> void:
	_reset_armed = false
	money = 0
	_last_earned = 0
	_shop_summary = ""
	_best = {}
	_init_levels()                                    # zero every vehicle's tree
	_owned = {"minivan": true, "hotrod": false, "monster": false, "sports": false, "f1": false}
	for ck in COSM_KEYS:
		_cosm_owned[ck] = false
		_cosm_color[ck] = COSMETICS[ck].default
	_body_kits = {}   # back to stock shells on every ride
	_run_mode = "classic"
	_best_time = {}
	_ghost_data = {}
	_rival_data = {}
	if save_enabled and FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)   # wipe the on-disk save, not just memory
	_swap_vehicle("minivan")                          # rebuild the car clean + re-apply zeros
	                                                   # (this also re-saves the blank state)
	if _reset_btn:
		_reset_btn.text = "🔄 NEW GAME  —  wipe ALL upgrades & money"
	_refresh_shop()

func _refresh_shop() -> void:
	# any other shop action cancels a pending fresh-start confirmation
	if _reset_armed and _reset_btn:
		_reset_armed = false
		_reset_btn.text = "🔄 NEW GAME  —  wipe ALL upgrades & money"
	var bank := "TOTAL MONEY:  $%d   (kept between tries)" % money
	_shop_money.text = (_shop_summary + "\n" + bank) if _shop_summary != "" else bank
	if _kit_lbl:
		_kit_lbl.text = "BODY KIT:  %s" % _kit_name(str(_body_kits.get(_vehicle, "")))
	_refresh_cosmetics()
	for vk in VEH_KEYS:
		var vrow: Dictionary = _veh_rows[vk]
		vrow.label.text = VEHICLES[vk].name
		var vbuy: Button = vrow.buy
		if _vehicle == vk:
			vbuy.text = "DRIVING"
			vbuy.disabled = true
			vrow.label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
		elif bool(_owned.get(vk, false)):
			vbuy.text = "SELECT"
			vbuy.disabled = false
			vrow.label.add_theme_color_override("font_color", Color(1, 1, 1))
		else:
			var price: int = int(VEHICLES[vk].price)
			vbuy.text = "$%d" % price
			vbuy.disabled = money < price
			vrow.label.add_theme_color_override("font_color", Color(0.8, 0.82, 0.86))
	for key in UP_KEYS:
		var lvl: int = _levels[key]
		var row: Dictionary = _shop_rows[key]
		var pips := "●".repeat(lvl) + "○".repeat(UP_MAX - lvl)
		row.label.text = "%s   %s" % [UP_NAME[key], pips]
		row.label.add_theme_color_override("font_color", Color(1, 1, 1))
		row.desc.text = UP_DESC.get(key, "")
		var buy: Button = row.buy
		if lvl >= UP_MAX:
			buy.text = "MAX"
			buy.disabled = true
			buy.add_theme_color_override("font_color", Color(1.0, 0.84, 0.4))
		else:
			var c: int = _cost(key)
			var can_afford: bool = money >= c
			buy.text = "$%d" % c
			buy.disabled = not can_afford
			# affordance: a buyable upgrade reads GREEN, one you can't afford yet reads
			# muted grey — same "can I press this" read the map/mode toggles use
			buy.add_theme_color_override("font_color", Color(0.55, 1.0, 0.6) if can_afford else Color(0.55, 0.56, 0.6))
		var sell: Button = row.sell
		if lvl > 0:
			sell.text = "+$%d" % int(UP_BASECOST[key] * pow(UP_COSTMULT, lvl - 1) * SELL_REFUND)
			sell.disabled = false
		else:
			sell.text = "sell"
			sell.disabled = true

func _buy(key: String) -> void:
	if _audio:
		_audio.call("play_click")
	if _levels[key] >= UP_MAX:
		return
	var c: int = _cost(key)
	if money < c:
		return
	money -= c
	_levels[key] += 1
	if _audio:
		_audio.call("play_cash")
	_apply_upgrades()
	_save_game()
	_refresh_shop()

const SELL_REFUND := 0.7   # sell a level back for 70% of what that level cost

## Refund one level of an upgrade (70% of what the last level cost) if you regret it.
func _sell(key: String) -> void:
	if _audio:
		_audio.call("play_click")
	if _levels[key] <= 0:
		return
	var paid: int = int(UP_BASECOST[key] * pow(UP_COSTMULT, _levels[key] - 1))
	money += int(paid * SELL_REFUND)
	_levels[key] -= 1
	_apply_upgrades()
	_save_game()
	_refresh_shop()

func _buy_cosmetic(key: String) -> void:
	if _audio:
		_audio.call("play_click")
	var c: Dictionary = COSMETICS[key]
	if _cosm_owned[key] or money < int(c.cost):
		return
	money -= int(c.cost)
	_cosm_owned[key] = true
	if _audio:
		_audio.call("play_cash")
	_apply_cosmetics()
	_save_game()
	_refresh_shop()

func _pick_cosmetic(key: String, col: Color) -> void:
	if not _cosm_owned[key]:
		return
	_cosm_color[key] = col
	if _audio:
		_audio.call("play_click")
	_apply_cosmetics()
	_save_game()   # persist the chosen colour, not just the unlock
	_refresh_swatch_selection(key)

## Ring the currently-selected swatch (and clear the others) so the chosen colour reads.
func _refresh_swatch_selection(key: String) -> void:
	var r: Dictionary = _cosm_rows.get(key, {})
	if r.is_empty():
		return
	var sel: Color = _cosm_color[key]
	if r.has("preview"):
		(r.preview as StyleBoxFlat).bg_color = sel
	for e in r.swatch_btns:
		var sb: StyleBoxFlat = e.sb
		if (e.color as Color).is_equal_approx(sel):
			sb.set_border_width_all(3)
			sb.border_color = Color(1, 1, 1)
		else:
			sb.set_border_width_all(0)

## Live-preview the colour under the cursor/focus (before committing): fill the preview box
## with it and ring that swatch yellow, while the currently-SELECTED swatch keeps a white ring.
func _preview_cosmetic(key: String, col: Color) -> void:
	var r: Dictionary = _cosm_rows.get(key, {})
	if r.is_empty():
		return
	if r.has("preview"):
		(r.preview as StyleBoxFlat).bg_color = col
	var sel: Color = _cosm_color[key]
	for e in r.swatch_btns:
		var sb: StyleBoxFlat = e.sb
		var is_hover: bool = (e.color as Color).is_equal_approx(col)
		var is_sel: bool = (e.color as Color).is_equal_approx(sel)
		sb.set_border_width_all(3 if (is_hover or is_sel) else 0)
		sb.border_color = Color(1.0, 0.9, 0.3) if is_hover else Color(1, 1, 1)

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

func _refresh_cosmetics() -> void:
	for ck in COSM_KEYS:
		var r: Dictionary = _cosm_rows.get(ck, {})
		if r.is_empty():
			continue
		var c: Dictionary = COSMETICS[ck]
		if _cosm_owned[ck]:
			r.buy.text = "OWNED"
			r.buy.disabled = true
			r.swatches.visible = true
			_refresh_swatch_selection(ck)
		else:
			r.buy.text = "$%d" % int(c.cost)
			r.buy.disabled = money < int(c.cost)
			r.swatches.visible = false

# --- HUD ---------------------------------------------------------------------

func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_bar_bg(layer, Vector2(28, 28), Color(0, 0, 0, 0.5))
	_fuel_bar = _bar(layer, Vector2(30, 30), Color(0.95, 0.8, 0.2))
	_bar_bg(layer, Vector2(28, 56), Color(0, 0, 0, 0.5))
	_health_bar = _bar(layer, Vector2(30, 58), Color(0.9, 0.3, 0.3))
	# balloon float charge: a slim strip tucked under health, shown only once the
	# Party Balloons upgrade is owned (the roof bundle itself is the primary meter)
	_balloon_bar_bg = ColorRect.new()
	_balloon_bar_bg.position = Vector2(28, 76)
	_balloon_bar_bg.size = Vector2(224, 8)
	_balloon_bar_bg.color = Color(0, 0, 0, 0.5)
	_balloon_bar_bg.visible = false
	layer.add_child(_balloon_bar_bg)
	_balloon_bar = ColorRect.new()
	_balloon_bar.position = Vector2(30, 77.5)
	_balloon_bar.size = Vector2(220, 5)
	_balloon_bar.color = Color(1.0, 0.45, 0.62)
	_balloon_bar.visible = false
	layer.add_child(_balloon_bar)
	_info = Label.new()
	_info.position = Vector2(28, 90)   # below the (optional) balloon strip
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
	# combo readout under the score: unbanked pot + multiplier, with a thin drain
	# bar showing the grace window. Hidden whenever no combo is open.
	_combo_lbl = Label.new()
	_combo_lbl.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_combo_lbl.position = Vector2(-200, 58)
	_combo_lbl.add_theme_font_size_override("font_size", 17)
	_combo_lbl.add_theme_color_override("font_color", Color(1.0, 0.62, 0.25))
	_combo_lbl.visible = false
	layer.add_child(_combo_lbl)
	_combo_bar_bg = ColorRect.new()
	_combo_bar_bg.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_combo_bar_bg.position = Vector2(-200, 82)
	_combo_bar_bg.size = Vector2(172, 5)
	_combo_bar_bg.color = Color(0.16, 0.12, 0.08, 0.85)
	_combo_bar_bg.visible = false
	layer.add_child(_combo_bar_bg)
	_combo_bar = ColorRect.new()
	_combo_bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_combo_bar.position = Vector2(-200, 82)
	_combo_bar.size = Vector2(172, 5)
	_combo_bar.color = Color(1.0, 0.62, 0.25)
	_combo_bar.visible = false
	layer.add_child(_combo_bar)
	_sprint_lbl = Label.new()
	_sprint_lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_sprint_lbl.position = Vector2(-120, 60)
	_sprint_lbl.custom_minimum_size = Vector2(240, 0)
	_sprint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sprint_lbl.add_theme_font_size_override("font_size", 44)
	_sprint_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	layer.add_child(_sprint_lbl)
	# time-trial timer shares the sprint countdown's screen slot — the two modes are
	# mutually exclusive per run (see _reset_run_mode_state), so they never overlap.
	_trial_lbl = Label.new()
	_trial_lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_trial_lbl.position = Vector2(-120, 54)
	_trial_lbl.custom_minimum_size = Vector2(240, 0)
	_trial_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_trial_lbl.add_theme_font_size_override("font_size", 40)
	_trial_lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	layer.add_child(_trial_lbl)
	_trial_sub_lbl = Label.new()
	_trial_sub_lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_trial_sub_lbl.position = Vector2(-200, 100)
	_trial_sub_lbl.custom_minimum_size = Vector2(400, 0)
	_trial_sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_trial_sub_lbl.add_theme_font_size_override("font_size", 14)
	_trial_sub_lbl.add_theme_color_override("font_color", Color(0.75, 0.8, 0.88))
	layer.add_child(_trial_sub_lbl)
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
	hint.text = "KB: Shift/W drive • S brake • A/D steer • Ctrl boost • Space dive • F balloons • R recover • air W/S pitch, Q/E roll • Tab garage • Enter retry\nPad: RT throttle • LT brake • L-stick steer/pitch • R-stick roll • RB boost • LB dive • Ⓧ balloons • Y recover • Start garage • Ⓑ retry"
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
	# balloon charge strip: only exists on screen once the upgrade is owned
	var blv := int(_car.get("balloon_level"))
	_balloon_bar_bg.visible = blv > 0
	_balloon_bar.visible = blv > 0
	if blv > 0:
		var bcap := maxf(float(_car.get("balloon_cap")), 0.001)
		_balloon_bar.size.x = 220.0 * clampf(float(_car.get("balloon_time")) / bcap, 0.0, 1.0)
	var air: String = "  ✈ AIR" if _car.get("airborne") else ""
	_info.text = "%d m    %d km/h%s" % [int(dist), int(_car.call("get_speed_kmh")), air]
	_score_lbl.text = "SCORE %d" % int(_car.get("score"))
	_trick_lbl.text = _car.get("trick_text")
	# combo readout: pot + multiplier, thin drain bar for the grace window
	var pot := float(_car.get("combo_pot"))
	var combo_open := pot > 0.5
	_combo_lbl.visible = combo_open
	_combo_bar.visible = combo_open
	_combo_bar_bg.visible = combo_open
	if combo_open:
		_combo_lbl.text = "COMBO +%d   x%.1f" % [int(pot), float(_car.call("combo_mult"))]
		_combo_bar.size.x = 172.0 * float(_car.call("combo_grace_frac"))
	_update_sprint_hud()
	_update_trial_hud()
	_update_gap_telegraph()

## Sprint-mode countdown: hidden on classic maps, big + red under 10s on sprint maps.
func _update_sprint_hud() -> void:
	if not _sprint_active or _car == null or bool(_car.get("dead")):
		_sprint_lbl.text = ""
		return
	_sprint_lbl.text = "%d" % ceili(_sprint_time)
	_sprint_lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3) if _sprint_time < 10.0 else Color(0.6, 1.0, 0.7))

## Time-trial countdown-up: live timer + a small "to go / best / medals" readout.
## Shares the sprint label's screen real estate (never both active on the same map)
## so the top-center HUD zone never crowds two big timers at once.
func _update_trial_hud() -> void:
	if not _trial_active or _car == null:
		_trial_lbl.text = ""
		_trial_sub_lbl.text = ""
		return
	if bool(_car.get("dead")) and not _trial_finished:
		return   # freeze the last live reading through the death/shop transition
	_trial_lbl.text = HCTimeTrialScript.format_time(_trial_time)
	var key := _trial_key(_map, _vehicle)
	var best: float = float(_best_time.get(key, -1.0))
	var best_txt: String = ("best " + HCTimeTrialScript.format_time(best)) if best >= 0.0 else "no record yet"
	if _trial_finished:
		var medal := HCTimeTrialScript.medal_for(_map, _trial_time)
		_trial_lbl.add_theme_color_override("font_color", HCTimeTrialScript.medal_color(medal) if medal != "" else Color(0.6, 1.0, 0.7))
		_trial_sub_lbl.text = "FINISHED  %s   %s" % [HCTimeTrialScript.medal_glyph(medal), best_txt]
	else:
		_trial_lbl.add_theme_color_override("font_color", Color(1, 1, 1))
		var remain: float = maxf(HCTimeTrialScript.finish_distance(_map) - float(_car.get("distance")), 0.0)
		_trial_sub_lbl.text = "%dm to go   %s   %s" % [int(remain), best_txt, HCTimeTrialScript.ladder_text(_map)]

## Warn the player to build speed on a gap run-up (green = you'll make it).
func _update_gap_telegraph() -> void:
	if _respawning or bool(_car.get("dead")):
		return   # _big is owned by the wipeout / death screen
	if not _terrain.has_method("_gap_for_z"):
		_big.text = ""   # no gaps on the winding-road track yet
		return
	var gz: float = _car.global_position.z
	var g: Dictionary = _terrain.call("_gap_for_z", gz)
	if g.is_empty() or gz <= g.lip_z or (gz - g.lip_z) > 75.0:
		_big.text = ""   # not approaching a gap
		return
	var v_req: float = 6.0 + float(g.void_w) * 0.9        # m/s needed to clear it
	var spd: float = _car.linear_velocity.length()
	if spd >= v_req:
		_big.text = "SEND IT!  ▶▶"
		_big.add_theme_color_override("font_color", Color(0.5, 1.0, 0.55))
	else:
		_big.text = "⚠ GO FASTER   %d / %d km/h" % [int(spd * 3.6), int(v_req * 3.6)]
		_big.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
