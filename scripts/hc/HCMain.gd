extends Node3D
## Hill-Climb feel sandbox: sky + streaming terrain + arcade car + world-upright chase
## cam locked behind + HUD (fuel/health/distance/speed). Run ends on fuel-out or wreck;
## Enter restarts. Milestone 1 — prove the moment-to-moment is fun. No economy yet.

const SkyScript := preload("res://scripts/Sky.gd")
const HCTerrainScript := preload("res://scripts/hc/HCTerrain.gd")
const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")
const HCCarScript := preload("res://scripts/hc/HCCar.gd")
const HCAudioScript := preload("res://scripts/hc/HCAudio.gd")
const USE_TRACK := true   # true = new 2-D winding road (HCTrack); false = classic corridor

var _car: RigidBody3D
var _audio: Node
var _terrain: Node3D
var _cam: Camera3D
var _cam_heading := Vector3(0, 0, -1)
var _start := Vector3(0, 6, 0)

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
		"speed_base": 16.0, "speed_per": 8.0,
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
		"speed_base": 24.0, "speed_per": 12.0,
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
		"speed_base": 22.0, "speed_per": 10.0,
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
		"speed_base": 40.0, "speed_per": 16.0,
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
		"speed_base": 64.0, "speed_per": 20.0,
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
var _owned := {"minivan": true, "hotrod": false, "monster": false, "sports": false, "f1": false}
var _was_dead := false
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
const CAM_LOOKAHEAD_MAX := 7.0         # max world-X aim bias (metres)
var _cam_lookahead := 0.0              # smoothed look-ahead aim bias (world X, metres)
var _cam_roll := 0.0                   # smoothed camera bank angle (degrees)
var _cam_look_basis := Basis.IDENTITY  # roll-free smoothing accumulator (see _update_camera)
var _cam_look_ready := false           # false until _cam_look_basis is seeded
var _speed_fx := 0.0                   # smoothed speed-lines intensity 0..1
var _speed_lines: Control              # full-screen streak overlay (mouse-ignored)
var _speed_line_nodes: Array[Line2D] = []
var _speed_lines_size := Vector2.ZERO  # viewport size the streaks were laid out for

func _ready() -> void:
	for ck in COSM_KEYS:
		_cosm_color[ck] = COSMETICS[ck].default   # seed chosen colours from defaults
	_setup_input()
	_init_levels()
	_setup_sky()
	_setup_terrain_and_car()
	_setup_camera()
	_setup_hud()
	_setup_speed_lines()
	_build_shop()
	_apply_upgrades()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_start_menu()   # title + how-to-play; pauses the game until you hit START

func _input(event: InputEvent) -> void:
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

func _setup_sky() -> void:
	var sky := Node3D.new()
	sky.set_script(SkyScript)
	sky.set("time_of_day", 0.42)
	add_child(sky)

func _setup_terrain_and_car() -> void:
	_terrain = Node3D.new()
	# TOGGLE: the new 2-D winding-ribbon road (HCTrack) vs the classic z-corridor.
	_terrain.set_script(HCTrackScript if USE_TRACK else HCTerrainScript)
	add_child(_terrain)
	_car = RigidBody3D.new()
	_car.set_script(HCCarScript)
	_car.set("vehicle_type", _vehicle)   # set BEFORE add_child so _ready builds the right ride
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
	_terrain.connect("pickup_collected", _on_pickup_collected)
	# audio intentionally OFF for now (user will source better sounds later). The
	# HCAudio synth + all play_* calls stay guarded by `if _audio:` so leaving
	# _audio null = fully silent; flip this back on by instancing HCAudioScript here.

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
	# on death, bank money earned from how far down the track you got, open the shop
	var d: bool = _car.get("dead")
	if d and not _was_dead:
		_was_dead = true
		_last_earned = int(float(_car.get("distance")) * MONEY_PER_M * _cash_mult())
		money += _last_earned
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
	# corner look-ahead: sample the road centre-line ~LOOKAHEAD metres ahead (forward
	# is -Z, so subtract) and bias the aim toward where the road is heading. Eased to 0
	# when there's nothing to drive (dead / no car / shop open) so it never lingers.
	var lead_target := 0.0
	var la_active: bool = not (_car == null or bool(_car.get("dead")) or (_shop != null and _shop.visible))
	if la_active and _terrain != null and _terrain.has_method("road_center_x"):
		var cz: float = _car.global_position.z
		var here_cx: float = _terrain.call("road_center_x", cz)
		var ahead_cx: float = _terrain.call("road_center_x", cz - CAM_LOOKAHEAD_DIST)
		var lateral_lead := ahead_cx - here_cx
		if is_finite(lateral_lead):
			lead_target = clampf(lateral_lead * CAM_LOOKAHEAD_GAIN, -CAM_LOOKAHEAD_MAX, CAM_LOOKAHEAD_MAX)
	_cam_lookahead = lerpf(_cam_lookahead, lead_target, 1.0 - exp(-4.0 * delta))
	var target := _car.global_position
	var want := target - _cam_heading * 12.0 + Vector3(0, 6.0, 0)
	# gentle "cut the corner": nudge the chase position a small fraction of the aim bias
	want.x += _cam_lookahead * 0.3
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
	look.x += _cam_lookahead
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
	_cam_lookahead = 0.0
	_cam_look_ready = false   # reseed the look basis at the new spawn orientation
	_speed_fx = 0.0
	_was_dead = false
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
	_car.set("max_speed", float(v.speed_base) + _levels.engine * float(v.speed_per) + _levels.stretch * 5.0)
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

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(720, 640)
	panel.position = Vector2(-360, -320)
	_start_layer.add_child(panel)
	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 26)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	pad.add_child(box)

	_shop_label(box, "🏎  HILL CLIMB RACER", 34, Color(1, 0.82, 0.42))
	_shop_label(box, "Drive as far as you can. Fuel is your timer — don't run dry.", 16, Color(0.72, 0.78, 0.9))
	box.add_child(HSeparator.new())

	_shop_label(box, "CONTROLS", 16, Color(0.8, 0.85, 1.0))
	var ctrls := [
		"Throttle / Brake:   W / S   ·   RT / LT",
		"Steer:   A / D   ·   left stick",
		"In the air:   W/S pitch  ·  A/D yaw  ·  Q/E roll",
		"Dive:   Space / LB      Boost (Rockets):   Ctrl / RB",
		"Recover if flipped:   R / Y      Garage:   Tab / Start",
	]
	for c in ctrls:
		_shop_label(box, "•  " + c, 15, Color(0.86, 0.88, 0.92))
	box.add_child(HSeparator.new())

	_shop_label(box, "TIPS", 16, Color(0.8, 0.85, 1.0))
	var tips := [
		"Drift around most corners — brake while turning, or flick the wheel hard, to break the rear loose. Take a fast corner on pure grip and a top-heavy ride will TIP and roll out of control.",
		"Read EVERY upgrade — each changes how the car handles, not just its numbers. (Downforce = tips far less · Aerodynamics = higher top speed · Bigger Wheels = clearance.)",
		"Grab coins for cash and fuel cans to stretch your run — pickups respawn every run.",
		"Clear the gaps by carrying speed. Fall in and the run ends.",
		"Every vehicle feels different — try them all in the Garage (van → hot rod → monster → sports → F1).",
	]
	for t in tips:
		var l := _shop_label(box, "•  " + t, 14, Color(0.7, 0.74, 0.8))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(668, 0)
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
	_shop.add_child(panel)
	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 18)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	pad.add_child(box)

	_shop_header = _shop_label(box, "", 26, Color(1, 0.82, 0.42))
	_shop_money = _shop_label(box, "", 19, Color(0.65, 1.0, 0.7))
	var sep := HSeparator.new()
	box.add_child(sep)

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

var _shop_summary := ""

func _show_shop() -> void:
	_shop_header.text = "WRECKED!"
	_shop_summary = "You reached %d m  —  earned +$%d this run" % [int(_car.get("distance")), _last_earned]
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
	_terrain.connect("pickup_collected", _on_pickup_collected)
	if _audio:
		_audio.call("setup", _car)   # re-point the engine synth at the new body
	_apply_upgrades()
	_cam_heading = Vector3(0, 0, -1)
	_was_dead = false
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
	_init_levels()                                    # zero every vehicle's tree
	_owned = {"minivan": true, "hotrod": false, "monster": false, "sports": false, "f1": false}
	for ck in COSM_KEYS:
		_cosm_owned[ck] = false
		_cosm_color[ck] = COSMETICS[ck].default
	_swap_vehicle("minivan")                          # rebuild the car clean + re-apply zeros
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
		else:
			var c: int = _cost(key)
			buy.text = "$%d" % c
			buy.disabled = money < c
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
	_refresh_shop()

func _pick_cosmetic(key: String, col: Color) -> void:
	if not _cosm_owned[key]:
		return
	_cosm_color[key] = col
	if _audio:
		_audio.call("play_click")
	_apply_cosmetics()
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
	_update_gap_telegraph()

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
