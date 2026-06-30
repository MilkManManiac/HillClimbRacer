extends RigidBody3D
## Hill-Climb sandbox car (3rd person). Raycast-wheel arcade physics on the ground; full
## manual 3-axis control in the air (no assist — land flat or take damage). Tiny-Wings
## DIVE (hold) noses down + adds weight to hug downslopes for speed and double as air
## pitch. Fuel drains under power; Health drops on hard/bad landings. R = self-right.
##
## Inputs: W/S throttle+brake (and air pitch), A/D steer (and air roll), Q/E air yaw,
##         Shift = dive, R = recover.

const GlbUtil := preload("res://scripts/GlbUtil.gd")
const CAR_GLB := "res://assets/car/kenney_sedan_cc0.glb"

# --- tunables ---
@export var engine_force: float = 19000.0
@export var max_speed: float = 125.0
@export var brake_force: float = 5500.0
@export var grip: float = 8.5
@export var slide_factor: float = 0.7      # how much grip you lose turning hard at speed (slides)
@export var wheelbase: float = 2.8
@export var max_steer_angle: float = 0.4   # smaller = gentler turns
@export var steer_rate: float = 3.0        # lower = slower steering response
@export var gravity_force: float = 17.0    # lower = floatier, more hang time
@export var suspension_rest: float = 0.55   # ride height (raised by Bigger Wheels)
@export var wheel_radius: float = 0.5        # visual wheel size + bump reach
@export var suspension_stiff: float = 105.0
@export var suspension_damp: float = 3.2    # some bounce, but damped enough not to fling
@export var suspension_max_force: float = 8500.0   # per-wheel cap so hard landings don't launch
@export var dive_force: float = 30.0       # downward push when diving (upgradable)
@export var boost_force: float = 0.0       # rocket thrust along the nose (Rockets upgrade; 0 = none)
@export var center_assist: float = 0.0     # air-guidance upgrade: pulls toward road center
@export var air_pitch_torque: float = 11.0
@export var air_roll_torque: float = 9.0
@export var air_yaw_torque: float = 6.0
@export var max_fuel: float = 600.0   # generous for the feel/air sandbox (tune later)
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
var _wings: Array[Node3D] = []
var _ailerons: Array[Node3D] = []
var _rudder: Node3D
var _engine: Node3D
var _cage: Node3D
var _cage_tiers: Array[Node3D] = []
var _airbrake: Node3D
var _cans: Array[MeshInstance3D] = []
var _dust: GPUParticles3D
var _rockets: Array[Node3D] = []
var _rocket_flames: Array[GPUParticles3D] = []
var boosting: bool = false
var wing_lift: float = 0.0          # lift from Wings upgrade (air time)
var _grounded: bool = false
var _steer: float = 0.0
var _air_time: float = 0.0
var _flip_accum: float = 0.0
var _last_up: Vector3 = Vector3.UP

# --- gap / checkpoint state --------------------------------------------------
signal gap_cleared(idx: int)
signal gap_failed(can_respawn: bool)
var checkpoint_z: float = 0.0   # last cleared gap's far platform (respawn point)
var gaps_cleared: int = 0
var _gap_armed: bool = false    # airborne over a void, outcome pending
var _falling_out: bool = false  # fell in; awaiting respawn (suspends anti-tunnel)

func _ready() -> void:
	mass = 850.0
	can_sleep = false
	continuous_cd = true
	gravity_scale = 0.0          # we apply gravity manually; avoid double gravity
	angular_damp = 0.2
	linear_damp = 0.01           # very low so momentum carries (fast arcade feel)
	# collide with terrain (layer 1) AND guardrails (layer 2), but FRICTIONLESS so a
	# landing doesn't scrub momentum and the body can't sink/glitch through the ground
	collision_mask = 3
	var pm := PhysicsMaterial.new()
	pm.friction = 0.0
	pm.bounce = 0.0
	physics_material_override = pm
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.4, 0)
	fuel = max_fuel
	health = max_health
	_build_collision()
	_build_rays()
	_build_body()
	_build_wings()
	_build_engine()
	_build_cage()
	_build_airbrake()
	_build_cans()
	_build_dust()
	_build_rockets()

func _physics_process(delta: float) -> void:
	if dead:
		return
	var up := global_transform.basis.y
	var fwd := -global_transform.basis.z
	var right := global_transform.basis.x
	var vel := linear_velocity
	var fwd_speed := vel.dot(fwd)
	var speed := vel.length()

	# --- suspension + ground detection -------------------------------------
	var was_grounded := _grounded
	_grounded = false
	for ray in _rays:
		ray.force_raycast_update()
		if ray.is_colliding():
			_grounded = true
			var origin := ray.global_position
			var dist := origin.distance_to(ray.get_collision_point())
			var compression: float = clamp((suspension_rest - dist) / suspension_rest, -0.3, 1.0)
			var vdot := up.dot(vel)
			var force: float = (compression * suspension_stiff - vdot * suspension_damp) * mass * 0.25
			force = clampf(force, -2000.0, suspension_max_force)
			apply_force(up * force, origin - global_position)
	airborne = not _grounded

	# --- gravity ------------------------------------------------------------
	apply_central_force(Vector3.DOWN * gravity_force * mass)

	# --- dive (hold Space): drop faster, burns fuel -------------------------
	var diving := Input.is_key_pressed(KEY_SPACE) and fuel > 0.0
	if diving:
		apply_central_force(Vector3.DOWN * dive_force * mass)
		fuel -= delta * 9.0   # the drop costs fuel

	# --- rocket BOOST (hold Ctrl): thrust along the nose, burns fuel fast ---
	# works on the ground (launch speed) AND in the air (push the nose forward
	# to clear gaps / steer flips). 0 boost_force = no Rockets upgrade yet.
	boosting = Input.is_key_pressed(KEY_CTRL) and boost_force > 0.0 and fuel > 0.0
	if boosting:
		apply_central_force(fwd * boost_force)
		fuel -= delta * 16.0
	_update_flames(boosting)

	# gas pedal = Left Shift (W also drives on the ground); brake = S; A/D steer/roll
	var drive := maxf(Input.get_action_strength("accelerate"), (1.0 if Input.is_key_pressed(KEY_SHIFT) else 0.0))
	var braking := Input.get_action_strength("brake")
	var steer_in := Input.get_axis("turn_right", "turn_left")
	var pitch_in := 0.0
	if Input.is_key_pressed(KEY_W): pitch_in -= 1.0   # W = nose down / lean forward
	if Input.is_key_pressed(KEY_S): pitch_in += 1.0   # S = nose up / lean back

	if _grounded:
		# drive / brake (fuel-gated)
		if fuel > 0.0 and drive > 0.01 and fwd_speed < max_speed:
			apply_central_force(fwd * drive * engine_force)
			fuel -= delta * (0.8 + drive * 2.2)
		elif braking > 0.01:
			if fwd_speed > 0.5:
				apply_central_force(-fwd * brake_force * braking)
			else:
				apply_central_force(fwd * -braking * engine_force * 0.4)
		else:
			apply_central_force(-fwd * fwd_speed * 0.04 * mass * 0.02)   # tiny coast drag, keeps momentum
		fuel -= delta * 0.2   # idle burn
		# smoothed steering (slower response than raw input)
		_steer = lerpf(_steer, steer_in, 1.0 - exp(-steer_rate * delta))
		var k: float = clamp(speed / max_speed, 0.0, 1.0)
		# grip = re-aim horizontal velocity toward the car's heading WITHOUT losing speed
		# (so a slightly-sideways landing keeps its momentum instead of scrubbing it).
		# Turning hard at speed grips less -> it slides/drifts.
		var slide: float = clamp(absf(_steer) * k, 0.0, 1.0)
		var align_rate: float = grip * (1.0 - slide_factor * slide)
		var hv := Vector3(vel.x, 0.0, vel.z)
		var hspeed := hv.length()
		var fwd_h := Vector3(fwd.x, 0.0, fwd.z)
		if hspeed > 1.0 and fwd_h.length() > 0.1:
			var dir := fwd_h.normalized()
			if fwd_speed < 0.0:
				dir = -dir
			var t: float = clamp(align_rate * delta * 0.5, 0.0, 1.0)
			var nhv := hv.normalized().slerp(dir, t) * hspeed
			linear_velocity = Vector3(nhv.x, vel.y, nhv.z)
		# steering (bicycle model)
		if absf(fwd_speed) > 0.4:
			var ang: float = _steer * max_steer_angle * (1.0 - k * 0.4)
			angular_velocity.y = (fwd_speed / wheelbase) * tan(ang)
	else:
		# --- airborne: full manual 3-axis (no assist) ----------------------
		var pitch := pitch_in                      # W nose down / S nose up (Space no longer pitches)
		var qe := 0.0
		if Input.is_key_pressed(KEY_Q): qe -= 1.0
		if Input.is_key_pressed(KEY_E): qe += 1.0
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

	# keep a hard landing from flinging the car into a glitchy spin (only on the ground)
	if _grounded and angular_velocity.length() > 5.0:
		angular_velocity = angular_velocity.normalized() * 5.0

	# soft top-speed cap so downhills don't run away to absurd speeds
	# (rockets punch well past it — that's the point of boosting)
	var soft_cap := 78.0 if boosting else 53.0   # m/s
	if speed > soft_cap:
		apply_central_force(-vel.normalized() * (speed - soft_cap) * mass * 2.5)

	# --- recover (R): ease upright + small lift ----------------------------
	if Input.is_key_pressed(KEY_R):
		var axis := up.cross(Vector3.UP)
		apply_torque(axis * 6.0 * mass)
		if up.dot(Vector3.UP) < 0.3:
			apply_central_force(Vector3.UP * 8.0 * mass)
		health -= delta * 4.0   # recovering costs a little

	_animate_surfaces(delta)

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

	# anti-tunnel safety: if a hard landing punched us through the ground, pop back up
	# (suspended while falling into a gap — we WANT that fall to play out)
	if terrain and not dead and not _falling_out:
		var th: float = terrain.call("height_at", global_position.x, global_position.z)
		if global_position.y < th - 2.5:   # deep last-resort only; box collision handles normal landings
			var p := global_position
			p.y = th + 0.6
			global_position = p
			if linear_velocity.y < 0.0:
				linear_velocity.y = 0.0
			reset_physics_interpolation()

	# --- fuel/health bookkeeping -------------------------------------------
	# crash if you land/roll off the road (past the rails)
	if _grounded and absf(global_position.x) > road_half + 1.5:
		health = 0.0
	fuel = maxf(fuel, 0.0)
	distance = maxf(distance, -global_position.z)
	if health <= 0.0 or (fuel <= 0.0 and speed < 0.5 and _grounded):
		dead = true

func _on_land(vel: Vector3) -> void:
	# damage from hard vertical impact and from landing un-flat
	var impact := maxf(0.0, -vel.y - land_damage_speed)
	var uprightness := global_transform.basis.y.dot(Vector3.UP)  # 1 flat, <0 upside down
	var flat_pen: float = 1.0 - clamp(uprightness, 0.0, 1.0)
	var dmg: float = impact * 1.6 + flat_pen * 35.0 * clamp(_air_time, 0.0, 1.5)
	if dmg > 1.0:
		health -= dmg
	# trick scoring: a clean landing confirms the combo (airtime + flips)
	var off_road := absf(global_position.x) > road_half
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
	# kick up dust on a real landing
	if _dust and _air_time > 0.3:
		_dust.global_position = global_position + Vector3(0, -0.3, 0)
		_dust.restart()
	_air_time = 0.0
	_flip_accum = 0.0

func reset_run(start: Vector3) -> void:
	dead = false
	fuel = max_fuel
	health = max_health
	distance = 0.0
	score = 0.0
	trick_text = ""
	_trick_timer = 0.0
	_air_time = 0.0
	_flip_accum = 0.0
	gaps_cleared = 0
	checkpoint_z = 0.0
	_gap_armed = false
	_falling_out = false
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = Transform3D(Basis(), start)
	reset_physics_interpolation()

func get_speed_kmh() -> float: return linear_velocity.length() * 3.6

# --- gaps / checkpoints ------------------------------------------------------

## Arm when airborne over a void; resolve to CLEARED (landed past it) or FAILED (fell in).
func _check_gap() -> void:
	if terrain == null or dead or _falling_out:
		return
	var z := global_position.z
	var g: Dictionary = terrain.call("_gap_for_z", z)
	if not g.is_empty():
		if z < g.lip_z and z > g.far_z and not _grounded:
			_gap_armed = true   # over the void
		elif _gap_armed and z <= g.far_z and _grounded and absf(global_position.x) <= road_half:
			_on_gap_cleared(int(g.idx))   # landed on the far platform = cleared
	# fell in: we were over the void and have dropped below the road
	if _gap_armed and global_position.y < -10.0:
		_on_gap_failed()

func _on_gap_cleared(idx: int) -> void:
	_gap_armed = false
	if idx < gaps_cleared:
		return   # already credited (no double-pop)
	gaps_cleared = idx + 1
	checkpoint_z = global_position.z + 6.0
	var reward: int = 200 + idx * 75
	score += reward
	fuel = minf(fuel + max_fuel * 0.35, max_fuel)   # earned fuel = "keep going" carrot
	health = minf(health + 15.0, max_health)
	trick_text = "GAP %d CLEARED   +%d   ⛽+" % [idx + 1, reward]
	_trick_timer = 2.6
	gap_cleared.emit(idx)

func _on_gap_failed() -> void:
	_falling_out = true
	_gap_armed = false
	var can_respawn := gaps_cleared > 0
	gap_failed.emit(can_respawn)
	if not can_respawn:
		health = 0.0
		dead = true   # no checkpoint yet -> normal wreck/shop flow

## Drop the car back in above a cleared checkpoint (called by HCMain after the slow-mo).
func respawn_at(z: float) -> void:
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

# --- build -------------------------------------------------------------------

func _build_collision() -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.9, 0.9, 4.0)
	col.shape = box
	col.position = Vector3(0, 0.7, 0)
	add_child(col)

func _build_rays() -> void:
	var fx := 0.9
	var fz := 1.4
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
		cyl.height = clampf(wheel_radius * 0.72, 0.3, 1.05)   # taller wheels are also wider
		var base: Vector3 = _wheel_positions[i]
		# bottom of wheel sits at the rest ground level (local y = 0.5 - suspension_rest)
		wm.position = Vector3(base.x, 0.5 - suspension_rest + wheel_radius, base.z)

func _build_body() -> void:
	var body := GlbUtil.load_scene(CAR_GLB)
	if body:
		body.scale = Vector3.ONE * 1.7
		body.position = Vector3(0, 0.1, 0)
		body.rotation.y = PI   # face -Z (travel direction); model was leading rear-first
		add_child(body)
		_hide_glb_wheels(body)   # we draw our own (sizeable) wheels instead
	else:
		# fallback box car
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.9, 1.0, 4.0)
		mi.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.7, 0.2, 0.2)
		mi.material_override = m
		mi.position = Vector3(0, 0.7, 0)
		add_child(mi)

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
	var s: float = 0.55 + float(level) * 0.16
	_engine.scale = Vector3(s, s, s)

# --- roll cage (Suspension upgrade) -----------------------------------------
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
	var mat := _metal(Color(0.13, 0.13, 0.15))
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
func _build_dust() -> void:
	_dust = GPUParticles3D.new()
	_dust.amount = 24
	_dust.lifetime = 0.6
	_dust.one_shot = true
	_dust.emitting = false
	_dust.explosiveness = 0.85
	_dust.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 65.0
	pm.gravity = Vector3(0, -3, 0)
	pm.initial_velocity_min = 1.5
	pm.initial_velocity_max = 3.5
	pm.scale_min = 0.4
	pm.scale_max = 1.0
	_dust.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.5, 0.5)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.62, 0.57, 0.47, 0.6)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.material = dm
	_dust.draw_pass_1 = qm
	add_child(_dust)

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
		_rockets.append(pivot)
	apply_rockets(0)

## Rockets grow + thrust harder with level. 0 = hidden, no boost.
func apply_rockets(level: int) -> void:
	for r in _rockets:
		r.visible = level > 0
		var s: float = 0.7 + float(level) * 0.13
		r.scale = Vector3(s, s, s)
	boost_force = 0.0 if level == 0 else (26000.0 + float(level) * 11000.0)

## Toggle the flame jets (and pulse their rate) with the boost input.
func _update_flames(on: bool) -> void:
	for f in _rocket_flames:
		f.emitting = on

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
func apply_wings(level: int) -> void:
	var f: float = clampf(float(level) * 0.22, 0.0, 1.4)
	for w in _wings:
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
	var roll_in := 0.0
	if Input.is_key_pressed(KEY_Q): roll_in -= 1.0
	if Input.is_key_pressed(KEY_E): roll_in += 1.0
	if _rudder:
		_rudder.rotation.y = lerp_angle(_rudder.rotation.y, yaw_in * 0.5, 1.0 - exp(-12.0 * delta))
	for i in range(_ailerons.size()):
		var sgn: float = -1.0 if i == 0 else 1.0
		_ailerons[i].rotation.x = lerp_angle(_ailerons[i].rotation.x, roll_in * 0.6 * sgn, 1.0 - exp(-12.0 * delta))
	if _airbrake and _airbrake.visible:
		var brake_ang: float = deg_to_rad(72.0) if Input.is_key_pressed(KEY_SPACE) else 0.0
		_airbrake.rotation.x = lerp_angle(_airbrake.rotation.x, brake_ang, 1.0 - exp(-14.0 * delta))

func _hide_glb_wheels(node: Node) -> void:
	if str(node.name).to_lower().contains("wheel") and node is Node3D:
		(node as Node3D).visible = false
		return
	for c in node.get_children():
		_hide_glb_wheels(c)
