extends RigidBody3D
## Hill-Climb sandbox car (3rd person). Raycast-wheel arcade physics on the ground; full
## manual 3-axis control in the air (no assist — land flat or take damage). Tiny-Wings
## DIVE (hold) noses down + adds weight to hug downslopes for speed and double as air
## pitch. Fuel drains under power; Health drops on hard/bad landings. R = self-right.
##
## Inputs: W/S throttle+brake (and air pitch), A/D steer (and air roll), Q/E air yaw,
##         Shift = dive, R = recover.

# --- tunables ---
@export var engine_force: float = 19000.0
@export var max_speed: float = 125.0
@export var brake_force: float = 5500.0
@export var grip: float = 8.5
@export var slide_factor: float = 0.7      # how much grip you lose turning hard at speed (slides)
@export var wheelbase: float = 2.8
@export var max_steer_angle: float = 0.4   # smaller = gentler turns
@export var corner_grip: float = 22.0      # max lateral accel (m/s^2) — low = wide turns at speed
# --- per-vehicle drift personality (set from HCMain.VEHICLES) ---
@export var drift_yaw_max: float = 3.1     # nose swing at full lock while drifting (tight vs shallow)
@export var drift_snap: float = 7.0        # how fast drift-yaw chases the stick (HIGH = twitchy/loose)
@export var drift_scrub: float = 0.9       # speed bled off mid-drift (HIGH = tight-but-slow corners)
@export var slide_thresh: float = 0.85     # steer×speed a hard flick needs to break into a drift (HIGH = grips through corners)
# --- per-vehicle roll instability / tipping ---
@export var com_height: float = -0.4       # center-of-mass Y offset (higher = more top-heavy)
@export var steer_rate: float = 3.0        # lower = slower steering response
@export var gravity_force: float = 17.0    # lower = floatier, more hang time
@export var suspension_rest: float = 0.55   # ride height (raised by Bigger Wheels)
@export var wheel_radius: float = 0.5        # visual wheel size + bump reach
@export var suspension_stiff: float = 105.0
@export var suspension_damp: float = 3.2    # some bounce, but damped enough not to fling
@export var suspension_max_force: float = 8500.0   # per-wheel cap so hard landings don't launch
@export var dive_force: float = 30.0       # downward push when diving (upgradable)
@export var boost_force: float = 0.0       # rocket thrust along the nose (Rockets upgrade; 0 = none)
@export var downforce: float = 0.0         # Downforce upgrade: speed-scaled push into the road (grounded only)
@export var center_assist: float = 0.0     # air-guidance upgrade: pulls toward road center
@export var air_pitch_torque: float = 11.0
@export var air_roll_torque: float = 9.0
@export var air_yaw_torque: float = 6.0
@export var max_fuel: float = 600.0   # generous for the feel/air sandbox (tune later)
@export var fuel_eff: float = 1.0     # burn multiplier (1.0 = stock; Efficiency upgrade lowers it)
@export var max_health: float = 100.0
@export var road_half: float = 14.0   # land outside this (jumped the rail) -> crash
@export var land_damage_speed: float = 12.0  # vertical impact speed before damage starts

var fuel: float = 100.0
var health: float = 100.0
var distance: float = 0.0
var airborne: bool = false
var dead: bool = false
var score: float = 0.0
var trick_text: String = ""
var _trick_timer: float = 0.0
var terrain: Node3D   # set by HCMain; used to catch ground tunneling

var _rays: Array[RayCast3D] = []
var _wheel_meshes: Array[MeshInstance3D] = []
var _wheel_positions: Array[Vector3] = []
var _springs: Array[MeshInstance3D] = []   # visible coil-over per wheel (Suspension upgrade)
var _spring_beef: float = 0.7              # coil thickness, grows with Suspension level
var _wings: Array[Node3D] = []
var _ailerons: Array[Node3D] = []
var _rudder: Node3D
var _engine: Node3D
var _cage: Node3D
var _cage_tiers: Array[Node3D] = []
var _airbrake: Node3D
var _cans: Array[MeshInstance3D] = []
var _dust: GPUParticles3D        # small landing dust (soft touchdowns)
var _dust_big: GPUParticles3D    # bigger landing dust (hard impacts)
var _ring_puff: GPUParticles3D   # ground-hugging ring puff (really hard landings)
var _rockets: Array[Node3D] = []
var _rocket_flames: Array[GPUParticles3D] = []
var _rocket_cores: Array[GPUParticles3D] = []   # bright inner core of the boost jets
var _boost_light: OmniLight3D                   # flickering orange point light while boosting
var _boost_flicker_t: float = 0.0
var boosting: bool = false
var drifting: bool = false          # rear traction broken (hard turn / handbrake) -> tire smoke
var _grip_break: float = 0.0        # 0 = full grip, 1 = fully sliding; ramps in fast, out slow
var _drift_yaw_cur: float = 0.0     # smoothed drift yaw (drift_snap controls how fast it chases target)
const DRIFT_YAW_EXP := 1.9          # >1 = gentle at small steer, ramps up the harder you turn
var wing_lift: float = 0.0          # lift from Wings upgrade (air time)
var _tire_smoke: Array[GPUParticles3D] = []
var _wind_streaks: GPUParticles3D   # thin speed-line streaks once you're moving fast
var _exhaust_smoke: Array[GPUParticles3D] = []
var _damage_smoke: GPUParticles3D          # engine smoke when HP is low
var _backfire: Array[GPUParticles3D] = []  # flame pops on throttle lift
var _prev_drive: float = 0.0
var _backfire_cd: float = 0.0
# skid marks: a world-space pool of dark quads laid under the rear wheels while drifting
const SKID_POOL := 120
const SKID_LIFE := 2.8
var _skid_marks: Array[MeshInstance3D] = []
var _skid_life: Array[float] = []
var _skid_idx: int = 0
var _skid_last: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _skid_root: Node3D
var _underglow: Node3D
var _ug_strips: Array[MeshInstance3D] = []
var _ug_light: OmniLight3D
var _grounded: bool = false
var _steer: float = 0.0
var _air_time: float = 0.0
var _flip_accum: float = 0.0
var _last_up: Vector3 = Vector3.UP

# --- gap / checkpoint state --------------------------------------------------
signal gap_cleared(idx: int)
signal gap_failed(can_respawn: bool)
signal landed(impact: float, air_time: float)   # for camera juice (shake/punch)

# convertible body + parametric chassis (Stretch/Wide upgrades) + Sidecar
var _body: Node3D
var _headlights: Array[SpotLight3D] = []   # forward spotlights, built per-body; OFF by default
                                            # (night map toggles via set_headlights)
var _col_shape: CollisionShape3D
var _col_box: BoxShape3D
var _sidecar: Node3D
var _sidecar_ray: RayCast3D
var _sidecar_wheel: MeshInstance3D
var _sidecar_on: bool = false
var checkpoint_z: float = 0.0   # last cleared gap's far platform (respawn point)
var gaps_cleared: int = 0
var _gap_armed: bool = false    # airborne over a void, outcome pending
var _falling_out: bool = false  # fell in; awaiting respawn (suspends anti-tunnel)

# --- damage panel-shedding (procedural bodies only; see _check_panel_shed) ---
var _prev_health: float = 100.0             # last frame's health, to detect threshold crossings
var _shed_panels: Array[MeshInstance3D] = []  # originals hidden by shedding (un-hidden on reset_run)
var _shed_flying: Array[MeshInstance3D] = []  # free-flying clones currently animating (tracked so a
                                               # run reset can force-clear them early)
var _panel_pop: GPUParticles3D                # small dust/spark puff at the detach point
var _shed_clone_script: GDScript              # lazily-built self-contained tumble/fade script (see
                                               # _get_shed_clone_script) so clones keep animating and
                                               # free themselves even if the car node itself is freed
                                               # (vehicle swap)

# --- vehicle identity --------------------------------------------------------
# Which ride this body is. Set by HCMain BEFORE add_child (so _ready builds the
# right geometry). HCMain.VEHICLES holds the handling/economy tuning; VSPEC here
# holds just the structural geometry (mass, collision box, wheel track) so the
# two stay decoupled. Switch vehicles = HCMain frees & recreates the car node.
@export var vehicle_type: String = "hotrod"
# Optional imported shell: path to a .glb in assets/car/ (set by HCMain BEFORE
# add_child, like vehicle_type; "" = the procedural panel body). Physics model is
# untouched — but if the asset names its wheel nodes, the ray/wheel stance
# auto-fits to the model's real wheel positions so the body never hovers over
# misplaced wheels. Falls back to the procedural body if the file fails to load.
@export var body_glb: String = ""
const HCCarBody := preload("res://scripts/hc/HCCarBody.gd")
const HCCarBodyBuilderScript := preload("res://scripts/hc/HCCarBodyBuilder.gd")
const HCCarFXScript := preload("res://scripts/hc/HCCarFX.gd")
var _body_builder: RefCounted
var _fx: RefCounted
var _glb_top: float = 0.0   # imported shell's roof height (car-local); 0 = procedural body
# INVARIANT: the box bottom (col_y - col.y/2) MUST sit BELOW the wheel-ray origin
# (local y=0.5). If the box catches the car deeper than that, the ray origins drop
# under the ground when the car bottoms out, the rays stop seeing ground, the
# suspension switches off, and the car deadlocks sunk-and-undriveable. Box LENGTH
# (col.z) is free to trim for facet-snag relief — only the height/col_y matter here.
const VSPEC := {
	"minivan": {"mass": 1200.0, "col": Vector3(2.0, 1.4, 4.0), "col_y": 0.95, "fx": 0.95, "fz": 1.5,  "wheelbase": 3.0},
	"hotrod":  {"mass": 850.0,  "col": Vector3(1.9, 0.9, 3.6), "col_y": 0.7,  "fx": 0.9,  "fz": 1.4,  "wheelbase": 2.8},
	"monster": {"mass": 2400.0, "col": Vector3(3.0, 1.8, 4.8), "col_y": 1.3,  "fx": 1.7,  "fz": 2.05, "wheelbase": 4.1},
	"sports":  {"mass": 950.0,  "col": Vector3(2.1, 0.7, 4.0), "col_y": 0.5,  "fx": 1.05, "fz": 1.55, "wheelbase": 3.0},
	"f1":      {"mass": 780.0,  "col": Vector3(1.5, 0.6, 4.4), "col_y": 0.45, "fx": 1.15, "fz": 1.9,  "wheelbase": 3.7},
}
var _vs: Dictionary = VSPEC["hotrod"]
var _part_scale: float = 1.0   # bolt-on upgrade parts are scaled up to fit a bigger ride

func _ready() -> void:
	add_to_group("car")   # so world pickups (HCPickup Area3D) can identify the player body
	_vs = VSPEC.get(vehicle_type, VSPEC["hotrod"])
	mass = float(_vs.mass)
	wheelbase = float(_vs.wheelbase)   # per-vehicle turn feel (was set via apply_chassis, now removed)
	# per-wheel suspension cap MUST scale with weight, else a heavy ride (monster
	# truck) can't generate enough force to hold itself up — it bottoms out, the
	# chassis drags, suspension feels dead, and landings never compress. ~13x mass
	# over 4 wheels gives comfortable headroom above gravity (mass * gravity_force).
	suspension_max_force = mass * 13.0
	_part_scale = 1.5 if vehicle_type == "monster" else 1.0   # fit parts to the big truck
	can_sleep = false
	continuous_cd = true
	gravity_scale = 0.0          # we apply gravity manually; avoid double gravity
	angular_damp = 0.2
	linear_damp = 0.01           # very low so momentum carries (fast arcade feel)
	# The body box does NOT collide with the terrain (layer 1). This is a raycast-suspension
	# vehicle: the wheel rays hold it up and the anti-tunnel safety net catches deep punches.
	# Letting the long box ride the per-tile trimesh caused "ghost collisions" — at speed the
	# box catches internal facet/seam edges and (being frictionless) redirects forward momentum
	# straight up, i.e. the random collide-lose-speed-launch bug. Mask 2 keeps it free to hit
	# future solid obstacles (walls/props) without ever touching the drivable ground.
	collision_mask = 2
	var pm := PhysicsMaterial.new()
	pm.friction = 0.0
	pm.bounce = 0.0
	physics_material_override = pm
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	apply_com()   # per-vehicle CoM height (tippy rides ride higher/heavier up top)
	fuel = max_fuel
	health = max_health
	_prev_health = max_health
	_body_builder = HCCarBodyBuilderScript.new(self)
	_fx = HCCarFXScript.new(self)
	_build_collision()
	_build_rays()
	_build_springs()
	_build_body()
	_build_wings()
	_build_engine()
	_build_cage()
	_build_airbrake()
	_build_cans()
	_fx.build()
	_build_rockets()
	_build_skids()
	_fit_parts()   # raise/scale the bolt-on upgrade parts to fit this vehicle
	# sidecar removed for now (functions kept dormant; not built/applied)

## Push the current com_height into the rigid body. Called on spawn and whenever
## HCMain re-applies vehicle tuning, so a top-heavy ride actually sits top-heavy.
func apply_com() -> void:
	center_of_mass = Vector3(0, com_height, 0)

func _physics_process(delta: float) -> void:
	if dead:
		# park the wreck so it can't keep falling/bouncing behind the shop
		if not freeze:
			linear_velocity = Vector3.ZERO
			angular_velocity = Vector3.ZERO
			freeze = true
		return
	var up := global_transform.basis.y
	var fwd := -global_transform.basis.z
	var right := global_transform.basis.x
	var vel := linear_velocity
	var fwd_speed := vel.dot(fwd)
	var speed := vel.length()

	# --- suspension + ground detection -------------------------------------
	# ANALYTIC wheels when the terrain offers ground_info (smooth height + normal):
	# the springs ride the same continuous curve the road mesh was sampled from, so
	# trimesh facet edges / tile seams / streaming order can never kick the chassis.
	# Raycast wheels remain as the fallback for terrains without the interface.
	var was_grounded := _grounded
	_grounded = false
	var gnormal := Vector3.ZERO   # averaged ground normal under the wheels (for pitch stability)
	var analytic: bool = terrain != null
	for i in range(_rays.size()):
		var d := -1.0   # contact distance from the wheel-ray origin (-1 = in the air)
		if analytic:
			var c := _suspend_analytic(i, up, vel)
			if not c.is_empty():
				_grounded = true
				gnormal += c.n
				d = c.d
		else:
			var ray := _rays[i]
			if _suspend(ray, up, vel):
				_grounded = true
				gnormal += ray.get_collision_normal()
				d = ray.global_position.distance_to(ray.get_collision_point())
		_update_wheel_visual(i, d)   # keep the visible wheel on the ground (no sinking)
	if _sidecar_on and _sidecar_ray and _suspend(_sidecar_ray, up, vel):
		_grounded = true
	airborne = not _grounded

	# --- grounded attitude: glue pitch & roll to the ground slope -----------
	# The 4 springs alone let the chassis wind up a pitch OSCILLATION at speed (worst on the long
	# F1) that a landing kicks into a full nose-dive/flip. Instead, while grounded we strongly and
	# critically-damp the chassis ATTITUDE toward the averaged ground normal — pitch AND roll,
	# never yaw (steering owns that) — then hard-cap the grounded pitch/roll rate. The car stays
	# planted and glued to the slope, so it can't knife its nose in or flip on a hard landing.
	if _grounded and gnormal.length() > 0.01:
		var gn := gnormal.normalized()
		var lvl_axis := up.cross(gn)                        # rotate body-up toward ground normal (pitch+roll, no yaw)
		var yaw_rate: float = angular_velocity.dot(up)
		var tilt_rate := angular_velocity - up * yaw_rate   # pitch+roll part of the spin
		apply_torque((lvl_axis * 32.0 - tilt_rate * 9.0) * mass)
		# hard cap the grounded pitch/roll rate so a hard landing can't spike a tumble
		var pr: float = clampf(angular_velocity.dot(right), -3.5, 3.5)
		var rr: float = clampf(angular_velocity.dot(fwd), -3.5, 3.5)
		angular_velocity = up * yaw_rate + right * pr + fwd * rr

	# --- gravity ------------------------------------------------------------
	apply_central_force(Vector3.DOWN * gravity_force * mass)

	# --- downforce upgrade: press the car into the road at speed so it plants and
	# corners flatter. Grounded-only so it never kills your jumps.
	if downforce > 0.0 and _grounded:
		apply_central_force(Vector3.DOWN * downforce * speed * mass * 0.12)

	# --- dive (hold Space / LB): drop faster, burns fuel --------------------
	var diving := Input.is_action_pressed("dive") and fuel > 0.0
	if diving:
		apply_central_force(Vector3.DOWN * dive_force * mass)
		fuel -= delta * 9.0 * fuel_eff   # the drop costs fuel

	# --- rocket BOOST (hold Ctrl / RB): thrust along the nose, burns fuel fast ---
	# works on the ground (launch speed) AND in the air (push the nose forward
	# to clear gaps / steer flips). 0 boost_force = no Rockets upgrade yet.
	boosting = Input.is_action_pressed("boost") and boost_force > 0.0 and fuel > 0.0
	if boosting:
		apply_central_force(fwd * boost_force)
		fuel -= delta * 45.0 * fuel_eff   # rockets CHUG fuel — short bursts only
	_fx.update_flames(boosting, delta)

	# throttle = RT / W / Shift; brake = LT / S; left stick (A/D) steer & air yaw;
	# left stick Y (W/S) = air pitch; right stick X (Q/E) = air roll
	var drive := maxf(Input.get_action_strength("accelerate"), (1.0 if Input.is_key_pressed(KEY_SHIFT) else 0.0))
	var braking := Input.get_action_strength("brake")
	var steer_in := Input.get_axis("turn_right", "turn_left")
	var pitch_in := Input.get_action_strength("pitch_up") - Input.get_action_strength("pitch_down")

	if _grounded:
		# drive / brake (fuel-gated)
		if fuel > 0.0 and drive > 0.01 and fwd_speed < max_speed:
			apply_central_force(fwd * drive * engine_force)
			fuel -= delta * (2.6 + drive * 7.0) * fuel_eff   # thirsty — fuel pressure forces upgrades
		elif braking > 0.01:
			if fwd_speed > 0.5:
				apply_central_force(-fwd * brake_force * braking)
			else:
				apply_central_force(fwd * -braking * engine_force * 0.4)
		else:
			apply_central_force(-fwd * fwd_speed * 0.04 * mass * 0.02)   # tiny coast drag, keeps momentum
		fuel -= delta * 0.9 * fuel_eff   # idle burn
		# smoothed steering (slower response than raw input)
		_steer = lerpf(_steer, steer_in, 1.0 - exp(-steer_rate * delta))
		var k: float = clamp(speed / max_speed, 0.0, 1.0)
		# grip = re-aim horizontal velocity toward the car's heading WITHOUT losing speed
		# (so a slightly-sideways landing keeps its momentum instead of scrubbing it).
		var hv := Vector3(vel.x, 0.0, vel.z)
		var hspeed := hv.length()
		var fwd_h := Vector3(fwd.x, 0.0, fwd.z)
		# DRIFT: turning hard at speed (or braking while turning = handbrake) snaps the
		# rear loose. While drifting, grip collapses so the car slides instead of
		# re-aiming — you keep your momentum and skate sideways.
		var hard: float = absf(_steer) * k
		var handbrake: bool = braking > 0.3 and absf(_steer) > 0.1
		# drift is INTENTIONAL: the handbrake breaks traction (at any steer, low speed OK);
		# a bare hard flick only breaks it near full lock so fast cornering stays gripped.
		var breaking_now: bool = hspeed > 4.0 and (handbrake or hard > slide_thresh)
		# traction break ramps IN fast but recovers SLOWLY, so a drift keeps sliding and
		# washes out naturally after you let off instead of snapping back to full grip.
		if breaking_now:
			_grip_break = move_toward(_grip_break, 1.0, delta * 16.0)   # snaps loose quickly
		else:
			_grip_break = move_toward(_grip_break, 0.0, delta * 1.3)    # ~0.75s to regrip
		drifting = _grip_break > 0.3
		var slide: float = clamp(hard, 0.0, 1.0)
		var grip_normal: float = grip * (1.0 - slide_factor * slide)
		var align_rate: float = lerpf(grip_normal, grip * 0.24, _grip_break)   # blend grip -> slidey (grippy enough to hold)
		if hspeed > 1.0 and fwd_h.length() > 0.1:
			var dir := fwd_h.normalized()
			if fwd_speed < 0.0:
				dir = -dir
			var t: float = clamp(align_rate * delta * 0.5, 0.0, 1.0)
			var nhv := hv.normalized().slerp(dir, t) * hspeed
			linear_velocity = Vector3(nhv.x, vel.y, nhv.z)
			# reward holding a slide: a little style score for a proper drift
			if drifting:
				score += hspeed * delta * 1.5
				# per-vehicle scrub: a drift bleeds forward speed (tight-but-slow rides
				# scrub hard; low-scrub rides skate through corners keeping momentum)
				var scrub: float = drift_scrub * _grip_break * absf(_steer) * delta
				linear_velocity *= (1.0 - clampf(scrub * 0.9, 0.0, 0.25))
		# steering. Grippy = bicycle model, but GRIP-LIMITED: a car can only pull so much
		# lateral G, so the faster you go the WIDER you must turn (slow down or drift for a
		# tight corner). corner_grip (per-vehicle) = max lateral accel; longer wheelbase also
		# widens turns. Mid-drift the nose instead rotates PROGRESSIVELY with steer (uncapped).
		if absf(fwd_speed) > 0.4:
			var grip_ang: float = _steer * max_steer_angle * (1.0 - k * 0.22)
			var grip_yaw: float = (fwd_speed / wheelbase) * tan(grip_ang)
			var max_yaw: float = corner_grip / maxf(absf(fwd_speed), 4.0)   # lat-accel cap
			grip_yaw = clampf(grip_yaw, -max_yaw, max_yaw)
			var prog: float = signf(_steer) * pow(absf(_steer), DRIFT_YAW_EXP)   # progressive curve
			# per-vehicle drift feel: drift_yaw_max = how far the nose swings at full lock;
			# drift_snap = how fast it chases the stick (HIGH = twitchy/loose, LOW = lazy tail).
			var drift_target: float = prog * drift_yaw_max * signf(fwd_speed)
			_drift_yaw_cur = lerpf(_drift_yaw_cur, drift_target, 1.0 - exp(-drift_snap * delta))
			var yaw_target: float = lerpf(grip_yaw, _drift_yaw_cur, _grip_break)
			# Apply the turn about the BODY up axis, NOT world Y. When the car is pitched/leaned at
			# speed, spinning about world-up bleeds onto the body PITCH axis and knifes the nose
			# into the ground. Rebuild angular velocity from body axes: set yaw, keep current pitch
			# & roll rates (suspension + pitch-stability own those).
			var pitch_c: float = angular_velocity.dot(right)
			var roll_c: float = angular_velocity.dot(fwd)
			angular_velocity = up * yaw_target + right * pitch_c + fwd * roll_c
	else:
		_grip_break = move_toward(_grip_break, 0.0, delta * 4.0)
		drifting = false   # no tire smoke in the air
		# --- airborne: full manual 3-axis (no assist) ----------------------
		var pitch := pitch_in                      # W/left-stick nose down, S nose up
		var qe := Input.get_action_strength("roll_right") - Input.get_action_strength("roll_left")  # Q/E / right stick
		apply_torque(right * pitch * air_pitch_torque * mass)   # W/S = pitch
		apply_torque(up * steer_in * air_yaw_torque * mass)     # A/D = yaw (rotate)
		apply_torque(fwd * qe * air_roll_torque * mass)         # Q/E = roll
		# arrest rotation quickly once the controls are released
		var rot_input: float = absf(pitch) + absf(steer_in) + absf(qe)
		if rot_input < 0.15:
			angular_velocity = angular_velocity.lerp(Vector3.ZERO, 1.0 - exp(-10.0 * delta))
		# WINGS: lift -> more air time the bigger the wings
		if wing_lift > 0.001:
			apply_central_force(Vector3.UP * wing_lift * mass)
		# AILERONS/RUDDER: a gentle correction back toward the road center (x=0)
		if center_assist > 0.001:
			var corr: float = clampf(-global_position.x * 0.18, -0.6, 0.6) * center_assist
			apply_central_force(Vector3((corr - linear_velocity.x * center_assist * 0.22) * mass, 0.0, 0.0))

	# The car self-levels on its four suspension springs, so it stays upright on its own —
	# there is NO tip/lean/roll-over mechanic. Cars differ in the corners purely by turn
	# radius (corner_grip / max_steer_angle / wheelbase) and drift feel, not by leaning over.
	# This clamp just stops a hard landing from flinging the chassis into a glitchy spin.
	if _grounded and angular_velocity.length() > 5.5:
		angular_velocity = angular_velocity.normalized() * 5.5

	# soft top-speed cap so downhills don't run away to absurd speeds. PER-VEHICLE now:
	# it tracks this ride's own max_speed (+ headroom for downhills/boost), so a fast car
	# (F1) genuinely runs away from a slow one instead of everything sharing one ceiling.
	var soft_cap := max_speed * 1.3
	if boosting:
		soft_cap += 8.0
	if speed > soft_cap:
		apply_central_force(-vel.normalized() * (speed - soft_cap) * mass * 2.5)

	# --- recover (R): ease upright + small lift ----------------------------
	if Input.is_action_pressed("recover"):
		var axis := up.cross(Vector3.UP)
		apply_torque(axis * 6.0 * mass)
		if up.dot(Vector3.UP) < 0.3:
			apply_central_force(Vector3.UP * 8.0 * mass)
		health -= delta * 4.0   # recovering costs a little

	_animate_surfaces(delta)

	# --- damage panel-shedding: pop small body panels at HP thresholds --------
	# telegraphs health without reading the HUD; funny on a stacked-panel car. Must
	# run AFTER _animate_surfaces per CLAUDE.md (nothing touches the suspension/ground
	# block above), and is purely visual so it's fine to sit in the FX section.
	_check_panel_shed()

	_fx.tick(delta, drive, speed)
	# skid marks under the rear wheels while drifting
	_update_skids(delta)

	# --- air-time + flip tracking (for later trick scoring) ----------------
	if airborne:
		_air_time += delta
		_flip_accum += rad_to_deg(_last_up.angle_to(up))
	elif was_grounded == false:
		_on_land(vel)
	_last_up = up

	# trick popup timer
	if _trick_timer > 0.0:
		_trick_timer -= delta
		if _trick_timer <= 0.0:
			trick_text = ""

	# gap / checkpoint resolution (jump cleared, or fell in)
	_check_gap()

	# --- off-map / fall wreck ----------------------------------------------
	# The road is a finite ribbon; past the meshed verge there's no ground at all, so
	# flying off the side (or plunging into any un-scored void) would fall forever. The
	# grounded off-road check below only catches slow roll-offs — this catches AIRBORNE
	# departures too. Scored gaps run their own fail path, so skip while armed/falling.
	if not dead and not _falling_out and not _gap_armed:
		var off_mesh: bool = _road_off() > _road_half_here() + 11.0
		if off_mesh or global_position.y < -70.0:
			health = 0.0
			dead = true
			return

	# --- JUMP-RAMP launch (only at real ramps, never on rolling hills) ------
	# A soft, force-capped raycast spring can't build real launch velocity in the split second
	# the car spends on a ramp at speed, so on its own it just skims FLAT over the pit. The
	# terrain knows exactly where the engineered jump ramps are (gap_state), so ONLY there do we
	# convert forward speed into UPWARD velocity via the ramp's own slope (rate = slope x
	# horizontal speed): you arc off the lip and the faster you hit it, the bigger the air.
	# Gated to gap ramps so rolling hills never fling the car (that was the old follow_vy bug).
	if _grounded and terrain:
		var gs: Dictionary = terrain.call("gap_state", global_position)
		if gs.get("active", false) and gs.get("on_road", true) and not gs.get("over_void", false) and not gs.get("past_far", false):
			var e := 1.5
			var gx: float = (float(terrain.call("height_at", global_position.x + e, global_position.z)) - float(terrain.call("height_at", global_position.x - e, global_position.z))) / (2.0 * e)
			var gz: float = (float(terrain.call("height_at", global_position.x, global_position.z + e)) - float(terrain.call("height_at", global_position.x, global_position.z - e))) / (2.0 * e)
			var ramp_vy: float = linear_velocity.x * gx + linear_velocity.z * gz
			if ramp_vy > 0.5:
				linear_velocity.y = maxf(linear_velocity.y, minf(ramp_vy, 24.0))

	# --- anti-tunnel safety floor (analytic ground, NO fling) ---------------
	# The wheel springs give the smooth ride and the ramp launches; this is a SAFETY NET only.
	# A big spawn/respawn drop (or a stray high-speed punch) can pierce the road before the
	# springs catch it — and the collision tiles may not have streamed in yet. So if the
	# body's lowest corner is below the ANALYTIC ground height (always available, even before
	# tiles build), lift it back onto the surface and kill only DOWNWARD speed. It adds NO
	# ground-follow velocity, so it never flings the car off rises the way the old clamp did,
	# and it leaves upward (launch) velocity from the springs intact. Suspended while falling
	# into a gap — that fall should play out.
	if terrain and not dead and not _falling_out and _col_box and _col_shape:
		# PER-CORNER ground comparison. The old check compared every corner against the
		# ground height at the car's CENTRE — on a crest or a landing downslope the nose
		# corners legitimately hang below the centre's ground level, so the car randomly
		# teleported upward mid-drive (the "random pop/hop" bug). Each corner must be
		# tested against the ground DIRECTLY UNDER IT, and only a real penetration
		# (past a small dead-band) triggers the lift.
		var hx: float = _col_box.size.x * 0.5
		var hy: float = _col_box.size.y * 0.5
		var hz: float = _col_box.size.z * 0.5
		var cy: float = _col_shape.position.y
		var deficit: float = 0.0
		for cxs in [-1.0, 1.0]:
			for cys in [-1.0, 1.0]:
				for czs in [-1.0, 1.0]:
					var cw := to_global(Vector3(hx * cxs, cy + hy * cys, hz * czs))
					var gh: float = terrain.call("height_at", cw.x, cw.z)
					deficit = maxf(deficit, gh - cw.y)
		# Dead-band: rigid-box corners legitimately sit up to ~0.2 m "inside" curved
		# terrain (front overhang in a dip, nose corner on a crest) — only a REAL
		# punch-through goes deeper. 0.35 m ignores all geometry while still catching
		# tunneling within a tick or two (a falling car gains ~0.17 m/tick at 20 m/s).
		if deficit > 0.35:
			global_position.y += deficit
			if linear_velocity.y < 0.0:
				linear_velocity.y = 0.0
			reset_physics_interpolation()

	# --- fuel/health bookkeeping -------------------------------------------
	# crash if you land/roll off the road (past the rails) — road may curve & widen
	if _grounded and _road_off() > _road_half_here() + 1.5:
		health = 0.0
	fuel = maxf(fuel, 0.0)
	if terrain:
		distance = maxf(distance, terrain.call("progress", global_position))   # arc-length on the track
	else:
		distance = maxf(distance, -global_position.z)
	if health <= 0.0 or (fuel <= 0.0 and speed < 0.5 and _grounded):
		dead = true

func _on_land(vel: Vector3) -> void:
	# Damage from the velocity INTO the surface (the normal component), NOT raw
	# vertical speed. Landing on a downslope moving ALONG it — the ski-jump "clean
	# landing" the gap landing ramps are shaped for — has a small normal component
	# even at high speed, so riding the slope down is free while pancaking onto
	# flat ground from the same height still hurts.
	var n := Vector3.UP
	if terrain:
		var gi: Dictionary = terrain.call("ground_info", global_position.x, global_position.z)
		n = gi.n
	var into: float = maxf(0.0, -vel.dot(n))
	var impact := maxf(0.0, into - land_damage_speed)
	# "flat" means aligned with the SURFACE, not with world-up — a car matching a 20°
	# landing slope IS landing flat; measuring against UP called that sloppy
	var uprightness := global_transform.basis.y.dot(n)  # 1 flat-on-surface, <0 upside down
	var flat_pen: float = 1.0 - clamp(uprightness, 0.0, 1.0)
	var dmg: float = impact * 2.1 + flat_pen * 42.0 * clamp(_air_time, 0.0, 1.5)
	if dmg > 1.0:
		health -= dmg
	# trick scoring: a clean landing confirms the combo (airtime + flips)
	var off_road := _road_off() > _road_half_here()
	if _air_time > 0.45 and not off_road:
		if uprightness > 0.45:
			var flips := int(_flip_accum / 320.0)
			var bonus: float = _air_time * 60.0 + float(flips) * 250.0
			score += bonus
			var label := ""
			if flips >= 1:
				label = "%dx FLIP  " % flips
			trick_text = "%s%.1fs AIR   +%d" % [label, _air_time, int(bonus)]
			_trick_timer = 2.2
		else:
			trick_text = "SLOPPY LANDING!"
			_trick_timer = 1.4
	# kick up dust on a real landing — scaled by impact severity. Amount can't change
	# live cheaply on a GPUParticles3D, so two pre-built emitters (small/big) cover the
	# range; a really hard hit (impact > ~8, i.e. well past the damage threshold) also
	# gets a brief ground-hugging ring puff on top.
	_fx.on_land(impact, _air_time, global_position + Vector3(0, -0.3, 0))
	landed.emit(into, _air_time)   # drives camera shake / FOV punch (surface-relative)
	_air_time = 0.0
	_flip_accum = 0.0

## Lateral distance from the road centre (path-projected on the winding track).
func _road_off() -> float:
	if terrain:
		return terrain.call("lateral_off", global_position)
	return absf(global_position.x)

## Drivable half-width here (wider through curves); falls back to road_half.
func _road_half_here() -> float:
	if terrain:
		return terrain.call("road_half_here", global_position)
	return road_half

func reset_run(start: Vector3) -> void:
	dead = false
	freeze = false   # un-park after a wreck
	fuel = max_fuel
	health = max_health
	distance = 0.0
	score = 0.0
	trick_text = ""
	_trick_timer = 0.0
	_air_time = 0.0
	_flip_accum = 0.0
	_grip_break = 0.0
	_steer = 0.0
	_drift_yaw_cur = 0.0
	drifting = false
	gaps_cleared = 0
	checkpoint_z = 0.0
	_gap_armed = false
	_falling_out = false
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = Transform3D(Basis(), start)
	reset_physics_interpolation()
	_restore_shed_panels()   # full health again -> put the panels back on

## Un-hide every panel shedding hid, clear the shed-tracking list, drop the
## threshold memory back to full health, and free any clones still tumbling
## through the air (a reset mid-flight shouldn't leave orphaned FX).
func _restore_shed_panels() -> void:
	for mi in _shed_panels:
		if is_instance_valid(mi):
			mi.visible = true
	_shed_panels.clear()
	for c in _shed_flying:
		if is_instance_valid(c):
			c.queue_free()
	_shed_flying.clear()
	_prev_health = max_health

func get_speed_kmh() -> float: return linear_velocity.length() * 3.6

# --- gaps / checkpoints ------------------------------------------------------

## Arm when airborne over a void; resolve to CLEARED (landed past it) or FAILED (fell in).
func _check_gap() -> void:
	if terrain == null or dead or _falling_out:
		return
	_check_gap_track()

## Jump resolution on the 2-D winding track (same rules as the z-corridor, but the
## track reports gap state by our world position instead of by z).
func _check_gap_track() -> void:
	var g: Dictionary = terrain.call("gap_state", global_position)
	if not g.get("active", false):
		if _gap_armed and global_position.y < -14.0:
			_on_gap_failed()
		return
	var lvl: float = g.level
	if g.over_void and not _grounded:
		_gap_armed = true
	elif _gap_armed and g.past_far and global_position.y > lvl - 3.5 and g.on_road:
		_on_gap_cleared(int(g.idx))
	if g.over_void and global_position.y < lvl - 3.5:
		_on_gap_failed()

func _on_gap_cleared(idx: int) -> void:
	_gap_armed = false
	if idx < gaps_cleared:
		return   # already credited (no double-pop)
	gaps_cleared = idx + 1
	checkpoint_z = global_position.z + 6.0
	var reward: int = 200 + idx * 75
	score += reward
	fuel = minf(fuel + max_fuel * 0.2, max_fuel)   # earned fuel = a small "keep going" carrot
	health = minf(health + 15.0, max_health)
	trick_text = "GAP %d CLEARED   +%d   ⛽+" % [idx + 1, reward]
	_trick_timer = 2.6
	gap_cleared.emit(idx)

func _on_gap_failed() -> void:
	# falling into a pit ENDS the run (shows the end screen) — no respawn. The dead
	# guard in _physics_process freezes the wreck immediately so it can't bounce.
	_gap_armed = false
	_falling_out = false
	health = 0.0
	dead = true
	gap_failed.emit(false)

## Drop the car back in above a cleared checkpoint (called by HCMain after the slow-mo).
func respawn_at(z: float) -> void:
	freeze = false
	var y := 4.0
	if terrain:
		y = terrain.call("height_at", 0.0, z) + 4.0
	global_transform = Transform3D(Basis(), Vector3(0.0, y, z))
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	fuel = maxf(fuel - max_fuel * 0.1, 0.0)   # small penalty for the wipeout
	_gap_armed = false
	_falling_out = false
	_air_time = 0.0
	_flip_accum = 0.0
	reset_physics_interpolation()
	# NOTE: health is NOT restored on a checkpoint respawn (only reset_run does that),
	# so shed panels intentionally stay off — the car should still look as beat-up as
	# its HP says. Any clones still tumbling from the wipeout keep animating/self-free
	# on their own timer regardless (see _get_shed_clone_script).

# --- build -------------------------------------------------------------------

## One raycast wheel's suspension push. Returns true if it's touching ground.
## Place a visible wheel so its bottom rides on the actual ray contact point. The
## body compresses under load (rest length > contact distance), so a STATIC wheel
## offset would sink the wheel into the ground by the compression amount. Following
## the contact each frame keeps the tyre planted; when airborne it hangs at droop.
func _update_wheel_visual(i: int, dist: float) -> void:
	if i >= _wheel_meshes.size():
		return
	var wm := _wheel_meshes[i]
	var base: Vector3 = _wheel_positions[i]
	var reach: float = suspension_rest + wheel_radius + 0.35
	var wy: float
	if dist >= 0.0:
		var d := clampf(dist, 0.0, reach)
		wy = base.y - d + wheel_radius        # wheel centre = contact + radius (bottom on ground)
	else:
		wy = base.y - reach + wheel_radius    # full droop in the air (springs stretch out)
	wm.position = Vector3(base.x, wy, base.z)
	# coil spring: spans a fixed chassis mount down to the wheel hub, so it visibly
	# COMPRESSES on landings and STRETCHES when the wheel droops in the air.
	if i < _springs.size():
		var sp := _springs[i]
		var mount_y: float = base.y + 0.35
		var length: float = maxf(mount_y - wy, 0.05)
		var rfac: float = clampf(wheel_radius / 0.5, 1.0, 2.2)
		sp.position = Vector3(base.x, mount_y, base.z)
		sp.scale = Vector3(_spring_beef * rfac, length, _spring_beef * rfac)

## A helix tube (coil spring), unit height running from y=0 (top) down to y=-1, so
## scaling its Y stretches/compresses the coils like a real spring.
func _coil_mesh(coils: float, coil_r: float, wire_r: float, sides: int, seg: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array = []
	for i in range(seg + 1):
		var t: float = float(i) / float(seg)
		var ang: float = coils * TAU * t
		var c := Vector3(coil_r * cos(ang), -t, coil_r * sin(ang))
		var dang: float = coils * TAU
		var tang := Vector3(-coil_r * sin(ang) * dang, -1.0, coil_r * cos(ang) * dang).normalized()
		var nrm := tang.cross(Vector3.UP)
		if nrm.length() < 0.001:
			nrm = tang.cross(Vector3.RIGHT)
		nrm = nrm.normalized()
		var bin := tang.cross(nrm).normalized()
		var ring: Array = []
		for s in range(sides):
			var sa: float = TAU * float(s) / float(sides)
			ring.append(c + nrm * (cos(sa) * wire_r) + bin * (sin(sa) * wire_r))
		rings.append(ring)
	for i in range(seg):
		for s in range(sides):
			var s2: int = (s + 1) % sides
			st.add_vertex(rings[i][s]); st.add_vertex(rings[i + 1][s]); st.add_vertex(rings[i][s2])
			st.add_vertex(rings[i][s2]); st.add_vertex(rings[i + 1][s]); st.add_vertex(rings[i + 1][s2])
	st.generate_normals()
	return st.commit()

func _build_springs() -> void:
	var coil := _coil_mesh(4.5, 0.13, 0.03, 6, 96)
	var mat := _metal(Color(0.95, 0.78, 0.2), 0.3)   # gold coil-over spring
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in range(_wheel_positions.size()):
		var mi := MeshInstance3D.new()
		mi.mesh = coil
		mi.material_override = mat
		add_child(mi)
		_springs.append(mi)

## Suspension upgrade: coils get chunkier as you invest (always visible so you can
## watch them work — thin at level 0, beefy at max).
func apply_suspension(level: int) -> void:
	_spring_beef = 0.55 + float(level) * 0.11

## Raise/spread the bolt-on upgrade parts (wings, rudder, rockets, engine, cage,
## cans, air-brake) so they sit on a bigger ride instead of clustering at hot-rod
## scale near the wheels. Positions are multiplied by the monster hull's scale-up so
## each part lands at the analogous spot; the scale itself comes from _part_scale
## (baked into apply_wings/apply_rockets/apply_engine) or set directly here for the
## visibility-only parts (cage / cans / air-brake) whose apply_* never touch scale.
func _fit_parts() -> void:
	# imported shell: only the HEIGHTS need refitting (footprint already matches the
	# vehicle's collision box, but the roof can sit anywhere) — lift the bolt-ons so
	# wings/rockets/cage land ON the model instead of inside it, then stop; the
	# monster's hand-tuned block below is for its procedural hull only.
	if _glb_top > 0.0:
		var ppy: float = clampf(_glb_top / 1.25, 0.85, 2.2)   # 1.25 = procedural hot-rod roofline
		var gmove: Array = []
		gmove.append_array(_wings)
		gmove.append_array(_rockets)
		for c in _cans:
			gmove.append(c)
		for n in [_rudder, _engine, _airbrake, _cage]:
			if n:
				gmove.append(n)
		for n in gmove:
			n.position.y *= ppy
		return
	if vehicle_type != "monster":
		return
	var pp := Vector3(1.5, 1.65, 1.4)   # mirror the hull scale so parts track the body
	var move: Array = []
	move.append_array(_wings)
	move.append_array(_rockets)
	for c in _cans:
		move.append(c)
	for n in [_rudder, _engine, _airbrake, _cage]:
		if n:
			move.append(n)
	for n in move:
		n.position = n.position * pp
	# parts whose apply_* set only visibility must be enlarged here
	var sc := Vector3(_part_scale, _part_scale, _part_scale)
	if _cage:
		_cage.scale = sc
	if _airbrake:
		_airbrake.scale = sc
	for c in _cans:
		c.scale = sc

func _suspend(ray: RayCast3D, up: Vector3, vel: Vector3) -> bool:
	ray.force_raycast_update()
	if not ray.is_colliding():
		return false
	var origin := ray.global_position
	var dist := origin.distance_to(ray.get_collision_point())
	var compression: float = clamp((suspension_rest - dist) / suspension_rest, -0.3, 1.0)
	var vdot := up.dot(vel)
	var force: float = (compression * suspension_stiff - vdot * suspension_damp) * mass * 0.25
	force = clampf(force, -mass * 2.5, suspension_max_force)
	apply_force(up * force, origin - global_position)
	return true

## Analytic-wheel suspension: identical spring math to _suspend, but the ground
## comes from terrain.ground_info (a smooth, continuous height + normal field)
## instead of a trimesh raycast — so collision facets, tile seams and streaming
## order can never inject a force spike. The vertical drop to the ground is
## converted to a distance ALONG the body's -up axis (what the old ray measured)
## via the local ground plane. Returns {"d": dist, "n": normal} or {} if airborne.
func _suspend_analytic(idx: int, up: Vector3, vel: Vector3) -> Dictionary:
	var origin := to_global(_wheel_positions[idx])
	var gi: Dictionary = terrain.call("ground_info", origin.x, origin.z)
	var n: Vector3 = gi.n
	var d: float = n.y * (origin.y - float(gi.h)) / maxf(up.dot(n), 0.25)
	if d > suspension_rest + wheel_radius + 0.35:   # beyond the old ray's reach = airborne
		return {}
	var compression: float = clamp((suspension_rest - d) / suspension_rest, -0.3, 1.0)
	var vdot := up.dot(vel)
	var force: float = (compression * suspension_stiff - vdot * suspension_damp) * mass * 0.25
	force = clampf(force, -mass * 2.5, suspension_max_force)
	apply_force(up * force, origin - global_position)
	return {"d": d, "n": n}

func _build_collision() -> void:
	_col_shape = CollisionShape3D.new()
	_col_box = BoxShape3D.new()
	_col_box.size = _vs.col
	_col_shape.shape = _col_box
	_col_shape.position = Vector3(0, float(_vs.col_y), 0)
	add_child(_col_shape)

func _build_rays() -> void:
	var fx: float = _vs.fx
	var fz: float = _vs.fz
	_wheel_positions = [Vector3(-fx, 0.5, -fz), Vector3(fx, 0.5, -fz), Vector3(-fx, 0.5, fz), Vector3(fx, 0.5, fz)]
	for pos in _wheel_positions:
		var ray := RayCast3D.new()
		ray.position = pos
		ray.collision_mask = 1
		ray.add_exception(self)
		add_child(ray)
		_rays.append(ray)
		# visible wheel (sized by the Bigger Wheels upgrade)
		var wm := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.height = 0.34
		wm.mesh = cyl
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.05, 0.05, 0.06)
		m.roughness = 0.9
		wm.material_override = m
		wm.rotation_degrees = Vector3(0, 0, 90)   # axle along X
		add_child(wm)
		_wheel_meshes.append(wm)
	apply_wheel_size()

## Update ray reach + wheel meshes after a ride-height / wheel-size change.
func apply_wheel_size() -> void:
	for ray in _rays:
		ray.target_position = Vector3(0, -(suspension_rest + wheel_radius + 0.35), 0)
	for i in range(_wheel_meshes.size()):
		var wm := _wheel_meshes[i]
		var cyl: CylinderMesh = wm.mesh
		cyl.top_radius = wheel_radius
		cyl.bottom_radius = wheel_radius
		# wheels get noticeably WIDER as they grow with the Bigger Wheels upgrade
		# (cyl height = tyre width, axle along X). Higher cap so maxed wheels read fat.
		cyl.height = clampf(wheel_radius * 1.15, 0.42, 2.6)
		var base: Vector3 = _wheel_positions[i]
		# bottom of wheel sits at the rest ground level (local y = 0.5 - suspension_rest)
		wm.position = Vector3(base.x, 0.5 - suspension_rest + wheel_radius, base.z)


## Open-top CONVERTIBLE hot-rod built from panels so the driver is visible and the
## whole body scales cleanly for the Stretch/Wide upgrades. Faces -Z.
## Procedural geometry is built by HCCarBodyBuilder; GLB shells stay here (A1).
func _build_body() -> void:
	_body = Node3D.new()
	add_child(_body)
	if body_glb != "" and _build_glb_body():
		return   # imported shell in place; procedural panels skipped
	_headlights.assign(_body_builder.build(_body, vehicle_type))

## Toggle every headlight spotlight this body owns (called by HCMain on the night map).
func set_headlights(on: bool) -> void:
	for sl in _headlights:
		sl.visible = on

## Toggle underglow on/off and set its colour (bought + picked in the garage).
func apply_underglow(on: bool, color: Color) -> void:
	if _fx == null:
		return   # pre-_ready no-op, same as the old inline null checks
	_fx.apply_underglow(on, color)

## Tire-smoke colour (the puffs kicked up while drifting).
func apply_smoke_color(color: Color) -> void:
	if _fx == null:
		return
	_fx.apply_smoke_color(color)

## Drift skid-streak colour (the marks laid under the rear wheels). Alpha is still
## animated per-mark in _update_skids; we only set the RGB here.
func apply_streak_color(color: Color) -> void:
	for mi in _skid_marks:
		var m := mi.material_override as StandardMaterial3D
		if m:
			m.albedo_color = Color(color.r, color.g, color.b, m.albedo_color.a)

## Boost flame colour (the rocket jets). Core is pushed toward white so it still
## reads as hot; the tint shows through the body and trailing edge of the jet.
func apply_flame_color(color: Color) -> void:
	if _fx == null:
		return
	_fx.apply_flame_color(color)

## Polished chrome material (mirror-like): metallic 1.0, very low roughness.
func _chrome(rough := 0.1) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.92, 0.93, 0.96)
	m.metallic = 1.0
	m.roughness = rough
	m.metallic_specular = 0.9
	return m

## A small box helper for the procedural body panels.
func _panel(parent: Node3D, size: Vector3, pos: Vector3, col: Color, rough := 0.5, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)
	return mi

## Imported GLB shell: fitted to this vehicle's collision footprint, matted so AI/
## photoreal PBR doesn't read "wet" next to the flat-shaded world, asset wheels
## hidden (the game animates its own suspension wheels), and — when the asset names
## its wheel nodes — the ray/wheel stance re-anchored to the model's real wheels.
## Returns false on any load problem so _build_body falls back to procedural.
func _build_glb_body() -> bool:
	var wrapper: Node3D = HCCarBody.load_body(body_glb, Vector3(_vs.col.x, _vs.col.y, _vs.col.z))
	if wrapper == null:
		push_warning("HCCar: failed to load body glb '%s' — using procedural body" % body_glb)
		return false
	HCCarBody.matte_materials(wrapper)
	var winfo: Array[Dictionary] = HCCarBody.wheel_info(wrapper)
	HCCarBody.hide_wheels(wrapper)
	# rest the shell's floor on the chassis at the collision box's bottom face
	var bottom: float = float(_vs.col_y) - _vs.col.y * 0.5
	wrapper.position = Vector3(0, bottom, 0)
	_body.add_child(wrapper)
	_glb_top = bottom + HCCarBody.body_aabb(wrapper).size.y * wrapper.scale.y
	_fit_wheels_to_body(winfo, bottom)
	return true

## Re-anchor the four wheel rays/visuals to the imported model's wheel positions
## (footprint only — the ray origin stays at local y=0.5, the suspension frame).
## Skipped when the asset has no named wheels (e.g. wheel-less Tripo bodies): the
## VSPEC stance is already correct for those. Spares (5th wheel on a tailgate) are
## dropped by keeping the 4 LOWEST wheels.
func _fit_wheels_to_body(winfo: Array[Dictionary], bottom: float) -> void:
	if winfo.size() < 4 or _rays.size() < 4:
		return
	winfo.sort_custom(func(a, b): return a.center.y < b.center.y)
	var four: Array = winfo.slice(0, 4)
	# order to match _wheel_positions: [FL, FR, RL, RR]; forward = -Z
	four.sort_custom(func(a, b): return a.center.z < b.center.z)
	var front: Array = [four[0], four[1]]
	var rear: Array = [four[2], four[3]]
	front.sort_custom(func(a, b): return a.center.x < b.center.x)
	rear.sort_custom(func(a, b): return a.center.x < b.center.x)
	var ordered: Array = [front[0], front[1], rear[0], rear[1]]
	# degenerate wheel layout (all clustered — mis-named nodes)? keep the VSPEC stance
	if absf(float(rear[0].center.z) - float(front[0].center.z)) < 1.0:
		return
	for i in range(4):
		var c: Vector3 = ordered[i].center
		_wheel_positions[i] = Vector3(c.x, 0.5, c.z)
		_rays[i].position = _wheel_positions[i]
	wheelbase = maxf(absf(float(rear[0].center.z) - float(front[0].center.z)), 1.6)
	var r_avg := 0.0
	for w in ordered:
		r_avg += float(w.radius)
	# base radius from the asset so the game wheels sit flush in its arches (the
	# Bigger Wheels upgrade re-applies over this later — gameplay owns final size)
	wheel_radius = clampf(r_avg / 4.0, 0.3, 0.75)
	apply_wheel_size()


## Stretch (length) + Wide (track) — resize collision, wheel layout, and body together.
func apply_chassis(stretch: int, wide: int) -> void:
	var sx: float = 1.0 + float(wide) * 0.16
	var sz: float = 1.0 + float(stretch) * 0.28
	var base_col: Vector3 = _vs.col    # scale from THIS vehicle's geometry, not hot-rod's
	if _col_box:
		_col_box.size = Vector3(base_col.x * sx, base_col.y, base_col.z * sz)
	var fx: float = float(_vs.fx) * sx
	var fz: float = float(_vs.fz) * sz
	_wheel_positions = [Vector3(-fx, 0.5, -fz), Vector3(fx, 0.5, -fz), Vector3(-fx, 0.5, fz), Vector3(fx, 0.5, fz)]
	for i in range(_rays.size()):
		_rays[i].position = _wheel_positions[i]
	apply_wheel_size()                 # repositions wheel meshes from _wheel_positions
	wheelbase = float(_vs.wheelbase) * sz   # longer = lazier, more stable steering
	if _body:
		_body.scale = Vector3(sx, 1.0, sz)

## A SECOND little car bolted to the right side (its own support wheel + a COM
## shift so it leans/pulls). Toggled by the Sidecar upgrade.
func _build_sidecar() -> void:
	_sidecar = Node3D.new()
	_sidecar.position = Vector3(1.95, 0.0, 0.0)
	add_child(_sidecar)
	var yel := Color(0.95, 0.75, 0.1)
	_panel(_sidecar, Vector3(1.0, 0.42, 2.4), Vector3(0, 0.58, 0), yel, 0.4, 0.1)
	_panel(_sidecar, Vector3(1.05, 0.2, 2.5), Vector3(0, 0.34, 0), Color(0.1, 0.1, 0.12), 0.7)
	_panel(_sidecar, Vector3(0.5, 0.42, 0.12), Vector3(0, 0.95, 0.4), Color(0.12, 0.12, 0.14), 0.8)  # seat
	# a tiny passenger head so it reads as a second car
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.15; hm.height = 0.3
	head.mesh = hm
	var sk := StandardMaterial3D.new()
	sk.albedo_color = Color(0.85, 0.66, 0.52)
	head.material_override = sk
	head.position = Vector3(0, 1.05, -0.1)
	_sidecar.add_child(head)
	# the sidecar's support wheel (visual)
	_sidecar_wheel = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5; cyl.bottom_radius = 0.5; cyl.height = 0.34
	_sidecar_wheel.mesh = cyl
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.05, 0.05, 0.06); wm.roughness = 0.9
	_sidecar_wheel.material_override = wm
	_sidecar_wheel.rotation_degrees = Vector3(0, 0, 90)
	_sidecar_wheel.position = Vector3(0.55, 0.0, 0.0)
	_sidecar.add_child(_sidecar_wheel)
	# its raycast wheel (in the car's body space, at the sidecar's outer side)
	_sidecar_ray = RayCast3D.new()
	_sidecar_ray.position = Vector3(2.5, 0.5, 0.0)
	_sidecar_ray.collision_mask = 1
	_sidecar_ray.add_exception(self)
	add_child(_sidecar_ray)
	apply_sidecar(0)

func apply_sidecar(level: int) -> void:
	_sidecar_on = level > 0
	if _sidecar:
		_sidecar.visible = _sidecar_on
	if _sidecar_ray:
		_sidecar_ray.enabled = _sidecar_on
		_sidecar_ray.target_position = Vector3(0, -(suspension_rest + wheel_radius + 0.35), 0)
	# shift the center of mass toward the sidecar so it leans/pulls (its wheel
	# keeps it supported, so it's wacky-but-drivable, not a death spin)
	var shift: float = 0.0 if not _sidecar_on else clampf(float(level) * 0.06, 0.0, 0.34)
	center_of_mass = Vector3(shift, com_height, 0.0)

func _metal(col: Color, rough := 0.35) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = 0.7
	m.roughness = rough
	return m

## A blower/supercharger + intake trumpets + side exhausts on the hood; grows with Engine.
func _build_engine() -> void:
	_engine = Node3D.new()
	_engine.position = Vector3(0, 1.0, -1.4)
	add_child(_engine)
	var blk := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.62, 0.36, 0.72)
	blk.mesh = bm
	blk.material_override = _metal(Color(0.12, 0.12, 0.14))
	blk.position = Vector3(0, 0.22, 0)
	_engine.add_child(blk)
	for sx in [-0.16, 0.16]:
		var stk := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.1
		cm.bottom_radius = 0.06
		cm.height = 0.22
		stk.mesh = cm
		stk.material_override = _metal(Color(0.6, 0.6, 0.66), 0.25)
		stk.position = Vector3(sx, 0.5, 0)
		_engine.add_child(stk)
	for sx2 in [-0.55, 0.55]:
		var pipe := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.06
		pm.bottom_radius = 0.07
		pm.height = 1.3
		pipe.mesh = pm
		pipe.material_override = _metal(Color(0.72, 0.72, 0.74), 0.25)
		pipe.rotation_degrees = Vector3(90, 0, 0)
		pipe.position = Vector3(sx2, -0.05, 0.7)
		_engine.add_child(pipe)
	apply_engine(0)

## Engine grows bigger/meaner with level.
func apply_engine(level: int) -> void:
	if _engine == null:
		return
	var s: float = (0.55 + float(level) * 0.16) * _part_scale
	_engine.scale = Vector3(s, s, s)

# --- roll cage (Durability upgrade) -----------------------------------------
## A chrome ball weld-node to hide/strengthen a tube joint.
func _weld_node(parent: Node3D, pos: Vector3, r: float) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	mi.mesh = sm
	mi.material_override = _chrome(0.18)
	mi.position = pos
	parent.add_child(mi)

## Matte foam material (roll-cage padding).
func _foam(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.98
	m.metallic = 0.0
	return m

func _tube(parent: Node3D, a: Vector3, b: Vector3, r: float, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = a.distance_to(b)
	mi.mesh = cm
	mi.material_override = mat
	mi.position = (a + b) * 0.5
	var d := b - a
	if absf(d.x) > absf(d.y) and absf(d.x) > absf(d.z):
		mi.rotation_degrees = Vector3(0, 0, 90)
	elif absf(d.z) > absf(d.y):
		mi.rotation_degrees = Vector3(90, 0, 0)
	parent.add_child(mi)

func _build_cage() -> void:
	_cage = Node3D.new()
	add_child(_cage)
	for _i in range(6):
		var t := Node3D.new()
		_cage.add_child(t)
		_cage_tiers.append(t)
	var mat := _metal(Color(0.56, 0.58, 0.64), 0.32)   # bare chromoly steel tube (bright, not black)
	var hx := 1.32
	var zf := -1.75
	var zr := 1.75
	var yb := 0.35
	var yt := 2.3
	var bot := [Vector3(-hx, yb, zf), Vector3(hx, yb, zf), Vector3(-hx, yb, zr), Vector3(hx, yb, zr)]
	var top := [Vector3(-hx, yt, zf), Vector3(hx, yt, zf), Vector3(-hx, yt, zr), Vector3(hx, yt, zr)]
	# tier 0 (Lv1): base cage
	for i in range(4):
		_tube(_cage_tiers[0], bot[i], top[i], 0.06, mat)
	_tube(_cage_tiers[0], top[0], top[1], 0.06, mat)
	_tube(_cage_tiers[0], top[2], top[3], 0.06, mat)
	_tube(_cage_tiers[0], top[0], top[2], 0.06, mat)
	_tube(_cage_tiers[0], top[1], top[3], 0.06, mat)
	_tube(_cage_tiers[0], bot[0], bot[2], 0.06, mat)
	_tube(_cage_tiers[0], bot[1], bot[3], 0.06, mat)
	# chrome weld nodes at every corner so the joints read welded, not floating
	for p in (bot + top):
		_weld_node(_cage_tiers[0], p, 0.085)
	# bright foam padding on the front uprights (the bars beside the driver's head)
	var pad := _foam(Color(0.92, 0.16, 0.1))
	_tube(_cage_tiers[0], Vector3(-hx, 1.15, zf), Vector3(-hx, 1.95, zf), 0.1, pad)
	_tube(_cage_tiers[0], Vector3(hx, 1.15, zf), Vector3(hx, 1.95, zf), 0.1, pad)
	# tier 1 (Lv2): side diagonal braces
	_tube(_cage_tiers[1], bot[0], top[2], 0.05, mat)
	_tube(_cage_tiers[1], bot[1], top[3], 0.05, mat)
	# tier 2 (Lv3): rear harness bar + rear X
	_tube(_cage_tiers[2], Vector3(-hx, yt - 0.5, zr), Vector3(hx, yt - 0.5, zr), 0.05, mat)
	_tube(_cage_tiers[2], bot[2], top[3], 0.05, mat)
	_tube(_cage_tiers[2], bot[3], top[2], 0.05, mat)
	# tier 3 (Lv4): roof X-brace
	_tube(_cage_tiers[3], top[0], top[3], 0.05, mat)
	_tube(_cage_tiers[3], top[1], top[2], 0.05, mat)
	# tier 4 (Lv5): roof light bar
	var lby := yt + 0.16
	_tube(_cage_tiers[4], Vector3(-0.9, lby, -0.25), Vector3(0.9, lby, -0.25), 0.05, _metal(Color(0.08, 0.08, 0.09)))
	for lx in [-0.62, -0.21, 0.21, 0.62]:
		var light := MeshInstance3D.new()
		var lbm := BoxMesh.new()
		lbm.size = Vector3(0.18, 0.13, 0.1)
		light.mesh = lbm
		var lm := StandardMaterial3D.new()
		lm.albedo_color = Color(1, 0.95, 0.6)
		lm.emission_enabled = true
		lm.emission = Color(1, 0.95, 0.6)
		lm.emission_energy_multiplier = 1.6
		light.material_override = lm
		light.position = Vector3(lx, lby, -0.25)
		_cage_tiers[4].add_child(light)
	# tier 5 (Lv6): chunky front bar + front harness
	_tube(_cage_tiers[5], bot[0], bot[1], 0.075, mat)
	_tube(_cage_tiers[5], Vector3(-hx, yt - 0.5, zf), Vector3(hx, yt - 0.5, zf), 0.06, mat)
	apply_cage(0)

func apply_cage(level: int) -> void:
	if _cage == null:
		return
	_cage.visible = level > 0
	for i in range(_cage_tiers.size()):
		_cage_tiers[i].visible = level > i

# --- air-brake flap (Dive upgrade) ------------------------------------------
func _build_airbrake() -> void:
	_airbrake = Node3D.new()
	_airbrake.position = Vector3(0, 1.35, 1.55)
	add_child(_airbrake)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.2, 0.5, 0.06)
	mi.mesh = bm
	mi.material_override = _metal(Color(0.85, 0.5, 0.18), 0.5)
	mi.position = Vector3(0, 0.25, 0.05)
	_airbrake.add_child(mi)
	apply_airbrake(0)

func apply_airbrake(level: int) -> void:
	if _airbrake:
		_airbrake.visible = level > 0

# --- jerry cans (Fuel Tank upgrade) -----------------------------------------
func _build_cans() -> void:
	for i in range(6):
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.26, 0.34, 0.2)
		mi.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.7, 0.15, 0.12)
		m.roughness = 0.7
		mi.material_override = m
		var col := i % 3
		var rz := i / 3
		mi.position = Vector3(-0.5 + col * 0.5, 1.05, 1.0 + rz * 0.32)
		mi.visible = false
		add_child(mi)
		_cans.append(mi)
	apply_cans(0)

func apply_cans(level: int) -> void:
	for i in range(_cans.size()):
		_cans[i].visible = i < level

# --- landing dust -----------------------------------------------------------
## A one-shot ground-puff burst. Shared by the small/big landing dust variants —
## amount can't cheaply change on a live GPUParticles3D, so _on_land picks WHICH
## pre-built emitter to restart() based on impact severity instead.

# --- damage panel-shedding ----------------------------------------------------
## Health-threshold panel pops: 2 panels fly off crossing below 70% HP, 3 more
## below 40%, 3 more below 20%. Skipped entirely for imported-GLB bodies (single
## mesh — nothing small to detach) and for parametric bodies with no _body built
## yet. Compares against _prev_health so each threshold fires once per DOWNWARD
## crossing; healing back above a line (a cleared gap) and dropping through it
## again is allowed to pop more panels — that's the intended "still taking a
## beating" read, not a bug.
func _check_panel_shed() -> void:
	if _glb_top > 0.0 or _body == null:
		return
	var frac: float = health / max_health if max_health > 0.0 else 0.0
	var prev_frac: float = _prev_health / max_health if max_health > 0.0 else 0.0
	if prev_frac >= 0.70 and frac < 0.70:
		_shed_n_panels(2)
	if prev_frac >= 0.40 and frac < 0.40:
		_shed_n_panels(3)
	if prev_frac >= 0.20 and frac < 0.20:
		_shed_n_panels(3)
	_prev_health = health

## Pop up to n eligible panels (fewer if the body's running low on small ones —
## the main tub/hood are never eligible, so this can't strip the car bare).
func _shed_n_panels(n: int) -> void:
	var candidates := _collect_shed_candidates()
	for i in range(n):
		if candidates.is_empty():
			break
		var idx := randi() % candidates.size()
		var mi: MeshInstance3D = candidates[idx]
		candidates.remove_at(idx)
		_shed_panel(mi)

## Every MeshInstance3D under _body that's small enough to plausibly be a bolt-on
## panel (not the tub/hood), isn't glass, and hasn't already been shed.
func _collect_shed_candidates() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	_collect_mesh_children(_body, out)
	return out

func _collect_mesh_children(node: Node, out: Array[MeshInstance3D]) -> void:
	for c in node.get_children():
		if c is MeshInstance3D and _panel_eligible(c) and not _shed_panels.has(c):
			out.append(c)
		if c.get_child_count() > 0:
			_collect_mesh_children(c, out)

## SMALL only (world-space AABB volume < ~0.35 m^3) so the main tub/hood can
## never vanish, and skip glass (a missing windshield reads as a hole, not damage).
func _panel_eligible(mi: MeshInstance3D) -> bool:
	if mi.mesh == null or not mi.visible:
		return false
	var mat := mi.material_override as StandardMaterial3D
	if mat and mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
		return false
	var sz := mi.mesh.get_aabb().size
	var sc := mi.global_transform.basis.get_scale()
	var vol: float = (sz.x * sc.x) * (sz.y * sc.y) * (sz.z * sc.z)
	return vol > 0.0005 and vol < 0.35

## Hide the real panel, remember it for reset_run to restore, spawn its free-flying
## clone, and pop a small dust puff at the detach point.
func _shed_panel(mi: MeshInstance3D) -> void:
	if not is_instance_valid(mi):
		return
	mi.visible = false
	_shed_panels.append(mi)
	_spawn_shed_clone(mi)
	if _panel_pop:
		_panel_pop.global_position = mi.global_position
		_panel_pop.restart()

## A one-shot self-contained visual: a plain clone of the panel's mesh/material,
## parented to the CAR'S PARENT (not the car) at the panel's world transform, with
## its own tiny script driving gravity + tumble + a sink-out over ~2.5s. No
## RigidBody3D — pure visual, zero physics cost, can't collide with anything.
## Parenting off the car (and giving it its own _process) means it keeps animating
## and frees itself on schedule even if the car node is freed mid-flight (vehicle
## swap) or the car dies (freeze) — it never depends on the car existing.
func _spawn_shed_clone(mi: MeshInstance3D) -> void:
	var host := get_parent()
	if host == null:
		return
	var clone := MeshInstance3D.new()
	clone.mesh = mi.mesh
	clone.material_override = mi.material_override
	clone.global_transform = mi.global_transform
	clone.set_script(_get_shed_clone_script())
	host.add_child(clone)
	var away: Vector3 = mi.global_position - global_position
	away.y = 0.0
	if away.length() < 0.05:
		away = Vector3(randf() - 0.5, 0.0, randf() - 0.5)
	away = away.normalized()
	# fly up/backward relative to the car's own velocity (a panel pops off and gets
	# left behind), plus an outward kick so a panel from the left flank flies left.
	clone.set("vel", -linear_velocity * 0.35 + Vector3.UP * randf_range(3.0, 5.5) + away * randf_range(1.5, 3.5))
	clone.set("spin", Vector3(randf_range(-9.0, 9.0), randf_range(-9.0, 9.0), randf_range(-9.0, 9.0)))
	clone.set("life", 2.5)
	_shed_flying.append(clone)

## Lazily-built script for shed-panel clones: gravity + tumble + shrink-to-nothing
## (cheaper than fading alpha, which would need a duplicated/unique material per
## clone) then queue_free. Runs on _process (not _physics_process) so it's fully
## independent of the car's RigidBody3D — it doesn't care if the car freezes, dies,
## or is freed entirely.
func _get_shed_clone_script() -> GDScript:
	if _shed_clone_script == null:
		var gs := GDScript.new()
		gs.source_code = "extends MeshInstance3D\n" \
			+ "var vel: Vector3 = Vector3.ZERO\n" \
			+ "var spin: Vector3 = Vector3.ZERO\n" \
			+ "var age: float = 0.0\n" \
			+ "var life: float = 2.5\n" \
			+ "func _process(delta: float) -> void:\n" \
			+ "\tage += delta\n" \
			+ "\tvel.y -= 9.0 * delta\n" \
			+ "\tglobal_position += vel * delta\n" \
			+ "\trotate_x(spin.x * delta)\n" \
			+ "\trotate_y(spin.y * delta)\n" \
			+ "\trotate_z(spin.z * delta)\n" \
			+ "\tif age > life * 0.6:\n" \
			+ "\t\tvar t: float = clampf((age - life * 0.6) / (life * 0.4), 0.0, 1.0)\n" \
			+ "\t\tscale = Vector3.ONE * (1.0 - t)\n" \
			+ "\tif age >= life:\n" \
			+ "\t\tqueue_free()\n"
		gs.reload()
		_shed_clone_script = gs
	return _shed_clone_script





# --- skid marks --------------------------------------------------------------
func _build_skids() -> void:
	_skid_root = Node3D.new()
	_skid_root.name = "HCSkidRoot"
	for _i in range(SKID_POOL):
		var mi := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.55, 0.95)
		mi.mesh = qm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.05, 0.05, 0.06, 0.0)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = m
		mi.visible = false
		_skid_root.add_child(mi)
		_skid_marks.append(mi)
		_skid_life.append(0.0)
	# park the pool in WORLD space (under the scene, not the car) so the marks stay
	# on the ground as we drive on. Clear any leftover root from a previous car.
	var host: Node = get_parent()
	if host:
		var ex: Node = host.get_node_or_null("HCSkidRoot")
		if ex:
			ex.queue_free()
		host.add_child.call_deferred(_skid_root)

## Lay one flat skid quad at a ground point, long axis along the travel heading.
func _stamp_skid(pos: Vector3, heading: Vector3) -> void:
	var mi := _skid_marks[_skid_idx]
	_skid_life[_skid_idx] = SKID_LIFE
	_skid_idx = (_skid_idx + 1) % SKID_POOL
	var fwd := Vector3(heading.x, 0.0, heading.z)
	if fwd.length() < 0.1:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	mi.visible = true
	mi.global_transform = Transform3D(Basis(right, fwd, Vector3.UP), pos + Vector3(0, 0.04, 0))

func _update_skids(delta: float) -> void:
	for i in range(_skid_marks.size()):
		if _skid_life[i] > 0.0:
			_skid_life[i] -= delta
			var mi := _skid_marks[i]
			if _skid_life[i] <= 0.0:
				mi.visible = false
			else:
				(mi.material_override as StandardMaterial3D).albedo_color.a = clampf(_skid_life[i] / SKID_LIFE, 0.0, 1.0) * 0.72
	if not (drifting and _grounded):
		return
	for jj in range(2):
		var wj: int = jj + 2   # rear wheels are indices 2, 3
		if wj >= _rays.size():
			continue
		var ray := _rays[wj]
		if not ray.is_colliding():
			continue
		var cp := ray.get_collision_point()
		if _skid_last[jj] != Vector3.ZERO and cp.distance_to(_skid_last[jj]) < 0.4:
			continue
		_skid_last[jj] = cp
		_stamp_skid(cp, linear_velocity)

# --- rocket boosters (Rockets upgrade) --------------------------------------
## Twin nozzles on the tail (+Z, the rear) with a glowing throat and a flame jet.
func _build_rockets() -> void:
	for sx in [-0.5, 0.5]:
		var pivot := Node3D.new()
		pivot.position = Vector3(sx, 0.7, 1.95)   # rear of the body
		add_child(pivot)
		# nozzle bell: a cone flaring toward the back (+Z)
		var bell := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.26      # wide mouth (faces back)
		cm.bottom_radius = 0.12   # narrow throat (faces the body)
		cm.height = 0.5
		bell.mesh = cm
		bell.material_override = _metal(Color(0.18, 0.18, 0.2), 0.3)
		bell.rotation_degrees = Vector3(90, 0, 0)   # axis along Z
		bell.position = Vector3(0, 0, 0.25)
		pivot.add_child(bell)
		# glowing throat plug (reads as heat even when not boosting)
		var glow := MeshInstance3D.new()
		var gm := SphereMesh.new()
		gm.radius = 0.12
		gm.height = 0.24
		glow.mesh = gm
		var gmat := StandardMaterial3D.new()
		gmat.albedo_color = Color(1.0, 0.5, 0.15)
		gmat.emission_enabled = true
		gmat.emission = Color(1.0, 0.45, 0.12)
		gmat.emission_energy_multiplier = 2.0
		glow.material_override = gmat
		glow.position = Vector3(0, 0, 0.42)
		pivot.add_child(glow)
		# flame jet (emits only while boosting)
		var flame := GPUParticles3D.new()
		flame.amount = 40
		flame.lifetime = 0.28
		flame.local_coords = true   # jet stays aligned out the back as the car rotates
		flame.emitting = false
		flame.position = Vector3(0, 0, 0.55)
		var pm := ParticleProcessMaterial.new()
		pm.direction = Vector3(0, 0, 1)   # shoot backward (+Z)
		pm.spread = 9.0
		pm.initial_velocity_min = 10.0
		pm.initial_velocity_max = 16.0
		pm.gravity = Vector3.ZERO
		pm.scale_min = 0.7
		pm.scale_max = 1.3
		var grad := Gradient.new()
		grad.set_color(0, Color(1.0, 0.95, 0.6, 1.0))   # white-hot core
		grad.set_color(1, Color(1.0, 0.25, 0.05, 0.0))  # fades to red smoke
		var gtex := GradientTexture1D.new()
		gtex.gradient = grad
		pm.color_ramp = gtex
		var scurve := Curve.new()
		scurve.add_point(Vector2(0.0, 0.3))
		scurve.add_point(Vector2(0.25, 1.0))
		scurve.add_point(Vector2(1.0, 0.0))
		var sctex := CurveTexture.new()
		sctex.curve = scurve
		pm.scale_curve = sctex
		flame.process_material = pm
		var qm := QuadMesh.new()
		qm.size = Vector2(0.6, 0.6)
		var fm := StandardMaterial3D.new()
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		fm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		fm.vertex_color_use_as_albedo = true
		fm.albedo_color = Color(1, 0.7, 0.3)
		qm.material = fm
		flame.draw_pass_1 = qm
		pivot.add_child(flame)
		_rocket_flames.append(flame)
		# hot inner core: a tighter, brighter, faster jet nested inside the main flame —
		# reads as the white-hot center of the thrust instead of one flat-colored cone.
		var core := GPUParticles3D.new()
		core.amount = 18
		core.lifetime = 0.14
		core.local_coords = true
		core.emitting = false
		core.position = Vector3(0, 0, 0.5)
		var cpm := ParticleProcessMaterial.new()
		cpm.direction = Vector3(0, 0, 1)
		cpm.spread = 3.5
		cpm.initial_velocity_min = 15.0
		cpm.initial_velocity_max = 21.0
		cpm.gravity = Vector3.ZERO
		cpm.scale_min = 0.22
		cpm.scale_max = 0.38
		var cgrad := Gradient.new()
		cgrad.set_color(0, Color(1.0, 1.0, 0.92, 1.0))   # near-white core
		cgrad.set_color(1, Color(1.0, 0.85, 0.4, 0.0))
		var cgtex := GradientTexture1D.new(); cgtex.gradient = cgrad
		cpm.color_ramp = cgtex
		core.process_material = cpm
		var cqm := QuadMesh.new()
		cqm.size = Vector2(0.28, 0.28)
		var cfm := StandardMaterial3D.new()
		cfm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		cfm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		cfm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		cfm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		cfm.vertex_color_use_as_albedo = true
		cfm.albedo_color = Color(1, 1, 1)
		cqm.material = cfm
		core.draw_pass_1 = cqm
		pivot.add_child(core)
		_rocket_cores.append(core)
		_rockets.append(pivot)
	# one cheap flickering point light between the nozzles (not per-nozzle — a single
	# light reads fine and keeps this affordable)
	_boost_light = OmniLight3D.new()
	_boost_light.position = Vector3(0, 0.7, 2.1)
	_boost_light.light_color = Color(1.0, 0.55, 0.2)
	_boost_light.omni_range = 6.0
	_boost_light.light_energy = 0.0
	add_child(_boost_light)
	apply_rockets(0)

## Rockets grow + thrust harder with level. 0 = hidden, no boost.
func apply_rockets(level: int) -> void:
	for r in _rockets:
		r.visible = level > 0
		var s: float = (0.7 + float(level) * 0.13) * _part_scale
		r.scale = Vector3(s, s, s)
	if _boost_light:
		_boost_light.visible = level > 0
	# small air nudge (gravity force is ~14450, so even maxed this barely lifts)
	boost_force = 0.0 if level == 0 else (3500.0 + float(level) * 1800.0)


## A normal tapered wing (trapezoid): wide root chord, narrower swept tip, slight dihedral.
func _wing_mesh(side: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ox := side
	var rf := Vector3(0.1 * ox, 0.0, -0.7)     # root front (at the body)
	var rb := Vector3(0.1 * ox, 0.0, 0.55)     # root back (trailing edge)
	var tf := Vector3(2.5 * ox, 0.22, -0.25)   # tip front (swept + dihedral)
	var tb := Vector3(2.5 * ox, 0.22, 0.4)     # tip back
	st.add_vertex(rf); st.add_vertex(rb); st.add_vertex(tb)
	st.add_vertex(rf); st.add_vertex(tb); st.add_vertex(tf)
	st.generate_normals()
	return st.commit()

func _build_wings() -> void:
	for side in [-1.0, 1.0]:
		var pivot := Node3D.new()
		pivot.position = Vector3(0.95 * side, 0.85, 0.0)
		pivot.visible = false   # stays hidden until the Wings upgrade is bought
		add_child(pivot)
		var wm := MeshInstance3D.new()
		wm.mesh = _wing_mesh(side)
		var wmat := _metal(Color(0.72, 0.74, 0.8))
		wmat.cull_mode = BaseMaterial3D.CULL_DISABLED
		wm.material_override = wmat
		pivot.add_child(wm)
		# aileron flap on the wing's trailing (back) edge (tilts with roll input)
		var hinge := Node3D.new()
		hinge.position = Vector3(1.35 * side, 0.13, 0.45)
		pivot.add_child(hinge)
		var flap := MeshInstance3D.new()
		var fm := BoxMesh.new()
		fm.size = Vector3(1.7, 0.05, 0.28)
		flap.mesh = fm
		flap.material_override = _metal(Color(0.5, 0.51, 0.56))
		flap.position = Vector3(0, 0, 0.15)
		hinge.add_child(flap)
		_ailerons.append(hinge)
		_wings.append(pivot)
	# rudder: rear vertical fin (tilts with yaw input)
	var rhinge := Node3D.new()
	rhinge.position = Vector3(0, 1.25, 1.6)
	rhinge.visible = false   # shown only with the Ailerons upgrade
	add_child(rhinge)
	var fin := MeshInstance3D.new()
	var finm := BoxMesh.new()
	finm.size = Vector3(0.08, 0.6, 0.7)
	fin.mesh = finm
	fin.material_override = _metal(Color(0.7, 0.72, 0.78))
	fin.position = Vector3(0, 0.3, 0.1)
	rhinge.add_child(fin)
	_rudder = rhinge
	apply_wings(0)
	apply_ailerons(0)

## Wing size + lift scale with the Wings upgrade. 0 = hidden.
## Hide with `visible` (not just scale 0) — a zero-scaled but visible node can flash
## for a frame on the freshly-spawned interpolated body ("wings on a fresh start").
func apply_wings(level: int) -> void:
	var show: bool = level > 0
	var f: float = clampf(float(level) * 0.22, 0.0, 1.4) * _part_scale
	for w in _wings:
		w.visible = show
		w.scale = Vector3(f, f, f)
	if _rudder:
		_rudder.scale = Vector3(f, f, f)
	wing_lift = float(level) * 1.4

## Ailerons + rudder (gated behind Wings): show the control surfaces and add the
## center-guidance + sharper air rotation. Size follows the wing scale.
func apply_ailerons(level: int) -> void:
	for a in _ailerons:
		a.visible = level > 0
	if _rudder:
		_rudder.visible = level > 0
	center_assist = float(level) * 1.1
	air_pitch_torque = 11.0 + float(level) * 2.0
	air_roll_torque = 9.0 + float(level) * 1.6
	air_yaw_torque = 6.0 + float(level) * 1.2

## Tilt the control surfaces with the air inputs (cosmetic feedback).
func _animate_surfaces(delta: float) -> void:
	var yaw_in := Input.get_axis("turn_right", "turn_left")
	var roll_in := Input.get_action_strength("roll_right") - Input.get_action_strength("roll_left")
	if _rudder:
		_rudder.rotation.y = lerp_angle(_rudder.rotation.y, yaw_in * 0.5, 1.0 - exp(-12.0 * delta))
	for i in range(_ailerons.size()):
		var sgn: float = -1.0 if i == 0 else 1.0
		_ailerons[i].rotation.x = lerp_angle(_ailerons[i].rotation.x, roll_in * 0.6 * sgn, 1.0 - exp(-12.0 * delta))
	if _airbrake and _airbrake.visible:
		var brake_ang: float = deg_to_rad(72.0) if Input.is_action_pressed("dive") else 0.0
		_airbrake.rotation.x = lerp_angle(_airbrake.rotation.x, brake_ang, 1.0 - exp(-14.0 * delta))
