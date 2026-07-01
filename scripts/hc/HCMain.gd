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
const UP_KEYS := ["engine", "fuel", "fueleff", "cashmult", "suspension", "durability", "wheels", "wings", "ailerons", "dive", "rockets", "stretch", "wide"]
const UP_NAME := {"engine": "Engine", "fuel": "Fuel Tank", "fueleff": "Fuel Economy", "cashmult": "Sponsor Decals", "suspension": "Suspension", "durability": "Durability", "wheels": "Bigger Wheels", "wings": "Wings", "ailerons": "Ailerons", "dive": "Dive Power", "rockets": "Rockets", "stretch": "Stretch (Limo)", "wide": "Wide Stance"}
const UP_DESC := {
	"engine": "More power & higher top speed",
	"fuel": "Bigger tank — more total fuel",
	"fueleff": "Burns fuel slower (better mileage)",
	"cashmult": "Earn more cash per metre (+25%/lvl)",
	"suspension": "Coil springs — softer, safer landings (visible!)",
	"durability": "Roll cage + armor — more health (HP)",
	"wheels": "Taller & wider wheels, more clearance",
	"wings": "Lift = more air time off jumps",
	"ailerons": "Air control + auto-centering (needs Wings)",
	"dive": "Hold Space to dive + an air-brake flap",
	"rockets": "Hold Ctrl: a little air boost (chugs fuel)",
	"stretch": "Limo: longer wheelbase, lazier turns",
	"wide": "Wider stance, harder to roll over",
}
const UP_BASECOST := {"engine": 320, "fuel": 260, "fueleff": 240, "cashmult": 400, "suspension": 300, "durability": 300, "wheels": 280, "wings": 380, "ailerons": 340, "dive": 300, "rockets": 420, "stretch": 360, "wide": 320}
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
	"hotrod": {
		"name": "Hot Rod", "price": 0,
		"desc": "Balanced convertible — light, quick, gets big air.",
		"engine_base": 8000.0, "engine_per": 3600.0,
		"speed_base": 30.0, "speed_per": 15.0,
		"fuel_base": 70.0, "fuel_per": 95.0, "fuel_burn": 1.0,
		"land_base": 9.0, "susp_rest": 0.55, "susp_per": 0.18, "wheel_rad": 0.5, "wheel_per": 0.12,
		"health_base": 100.0, "grip": 8.5, "gravity": 17.0, "steer": 0.4,
	},
	"monster": {
		"name": "Monster Truck", "price": 2800,
		"desc": "Giant heavy 4x4 — climbs anything & hard to flip, but slow, thirsty, bad in the air. Starts on dinky wheels; the Bigger Wheels upgrade makes them RIDICULOUSLY huge.",
		"engine_base": 15000.0, "engine_per": 5400.0,
		"speed_base": 26.0, "speed_per": 11.0,
		"fuel_base": 100.0, "fuel_per": 110.0, "fuel_burn": 1.5,
		# small starting wheels (wheel_rad) that grow a LOT per level (wheel_per),
		# with ride height (susp) lifting to match so the truck towers when maxed.
		"land_base": 11.0, "susp_rest": 0.85, "susp_per": 0.34, "wheel_rad": 0.5, "wheel_per": 0.38,
		"health_base": 165.0, "grip": 12.0, "gravity": 20.0, "steer": 0.34,
	},
}
const VEH_KEYS := ["hotrod", "monster"]
var _vehicle := "hotrod"
var _owned := {"hotrod": true, "monster": false}
var _was_dead := false
var _respawning := false
var _shake := 0.0           # camera shake magnitude (decays)
var _shake_off := Vector3.ZERO
var _fov_punch := 0.0       # transient FOV kick on hard landings
var _shop: Control
var _shop_header: Label
var _shop_money: Label
var _shop_rows := {}
var _veh_rows := {}
var _reset_btn: Button
var _restart_btn: Button
var _money_btn: Button
var _reset_armed := false   # fresh-start needs a confirm click so it's not a mis-tap
var _first_veh_btn: Button   # focus target when the garage opens (gamepad nav)

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

func _input(event: InputEvent) -> void:
	# works for keyboard (Enter/Tab) AND gamepad (Back / Start) via the input actions
	if event.is_action_pressed("restart"):
		_restart()
	elif event.is_action_pressed("toggle_shop"):
		_toggle_shop()

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
	_car.set("max_speed", float(v.speed_base) + _levels.engine * float(v.speed_per))
	if _car.has_method("apply_engine"):
		_car.call("apply_engine", _levels.engine)
	# fuel is the run timer — VERY low stock so you can barely move; two upgrades fix it:
	#   Fuel Tank = capacity, Fuel Economy = slower burn. Heavy rides drink more (fuel_burn).
	_car.set("max_fuel", float(v.fuel_base) + _levels.fuel * float(v.fuel_per))
	_car.set("fuel_eff", float(v.fuel_burn) * maxf(1.0 - _levels.fueleff * 0.12, 0.28))
	# intrinsic handling per ride (grip/gravity/steer); not touched by upgrades
	_car.set("grip", float(v.grip))
	_car.set("gravity_force", float(v.gravity))
	_car.set("max_steer_angle", float(v.steer))
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
	# Wings = lift/air time; Ailerons (gated behind Wings) = control surfaces + guidance + sharper air
	if _car.has_method("apply_wings"):
		_car.call("apply_wings", _levels.wings)
	if _car.has_method("apply_ailerons"):
		_car.call("apply_ailerons", _levels.ailerons)
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
	# Chassis conversions: Stretch (longer) + Wide (wider track)
	if _car.has_method("apply_chassis"):
		_car.call("apply_chassis", _levels.stretch, _levels.wide)

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
	panel.custom_minimum_size = Vector2(540, 620)
	panel.position = Vector2(-270, -310)
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

	# everything scrollable lives in ONE list (vehicles + upgrades) so it can never
	# run off the panel; the scroll flexes to fill, keeping Restart pinned below.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(504, 360)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true   # gamepad: scroll to keep the focused row on screen
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)

	# --- vehicle selector (unlock/select a ride) -------------------------------
	_shop_label(list, "GARAGE — pick your ride", 15, Color(0.8, 0.85, 1.0))
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
	var sep2 := HSeparator.new()
	list.add_child(sep2)
	_shop_label(list, "UPGRADES", 15, Color(0.8, 0.85, 1.0))

	for key in UP_KEYS:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 10)
		list.add_child(row)
		var info := VBoxContainer.new()
		info.custom_minimum_size = Vector2(360, 0)
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
		var buy := Button.new()
		buy.custom_minimum_size = Vector2(96, 40)
		buy.pressed.connect(_buy.bind(key))
		row.add_child(buy)
		_shop_rows[key] = {"label": lbl, "desc": desc, "buy": buy}

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

	_wire_focus_chain()

## TEST-ONLY: dump a million dollars in the bank and refresh the shop.
func _on_test_money() -> void:
	money += 1000000
	_refresh_shop()

## Chain every shop button top-to-bottom (vehicles -> upgrades -> retry -> new game,
## wrapping) so a gamepad d-pad walks the WHOLE list. Without this, the default
## focus solver jumps straight from an upgrade row to the Retry button because the
## next rows are clipped by the scroll. (Disabled buttons stay focusable so you can
## still read every upgrade; they just can't be pressed.)
func _wire_focus_chain() -> void:
	var chain: Array[Control] = []
	for vk in VEH_KEYS:
		chain.append(_veh_rows[vk].buy)
	for key in UP_KEYS:
		chain.append(_shop_rows[key].buy)
	chain.append(_restart_btn)
	chain.append(_reset_btn)
	chain.append(_money_btn)
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
		_shop_header.text = "GARAGE   (Tab / Start to close)"
		_shop_summary = ""
		_refresh_shop()
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
	_owned = {"hotrod": true, "monster": false}       # relock everything but the starter
	_swap_vehicle("hotrod")                           # rebuild the car clean + re-apply zeros
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
		var locked: bool = key == "ailerons" and _levels.wings == 0
		var pips := "●".repeat(lvl) + "○".repeat(UP_MAX - lvl)
		row.label.text = "%s   %s" % [UP_NAME[key], pips]
		row.label.add_theme_color_override("font_color", Color(0.55, 0.58, 0.62) if locked else Color(1, 1, 1))
		row.desc.text = UP_DESC.get(key, "")
		var buy: Button = row.buy
		if locked:
			buy.text = "🔒 Wings"
			buy.disabled = true
		elif lvl >= UP_MAX:
			buy.text = "MAX"
			buy.disabled = true
		else:
			var c: int = _cost(key)
			buy.text = "$%d" % c
			buy.disabled = money < c

func _buy(key: String) -> void:
	if _audio:
		_audio.call("play_click")
	if _levels[key] >= UP_MAX:
		return
	if key == "ailerons" and _levels.wings == 0:
		return   # gated behind Wings
	var c: int = _cost(key)
	if money < c:
		return
	money -= c
	_levels[key] += 1
	if _audio:
		_audio.call("play_cash")
	_apply_upgrades()
	_refresh_shop()

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
