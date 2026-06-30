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
@export var suspension_damp: float = 2.2    # low damping = springy bounce on landing
@export var dive_force: float = 30.0       # downward push when diving (upgradable)
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
var _grounded: bool = false
var _steer: float = 0.0
var _air_time: float = 0.0
var _flip_accum: float = 0.0
var _last_up: Vector3 = Vector3.UP

func _ready() -> void:
	mass = 850.0
	can_sleep = false
	continuous_cd = true
	gravity_scale = 0.0          # we apply gravity manually; avoid double gravity
	angular_damp = 0.2
	linear_damp = 0.01           # very low so momentum carries (fast arcade feel)
	# the body only collides with guardrails (layer 2); the TERRAIN (layer 1) is handled
	# by the suspension raycasts, so a landing never scrubs speed on the chassis box
	collision_mask = 2
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.4, 0)
	fuel = max_fuel
	health = max_health
	_build_collision()
	_build_rays()
	_build_body()

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
			apply_force(up * force, origin - global_position)
	airborne = not _grounded

	# --- gravity ------------------------------------------------------------
	apply_central_force(Vector3.DOWN * gravity_force * mass)

	# --- dive (hold Space): weight + nose-down ------------------------------
	var diving := Input.is_key_pressed(KEY_SPACE)
	if diving:
		apply_central_force(Vector3.DOWN * dive_force * mass)

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
		var pitch := pitch_in                      # W nose up / S nose down
		if diving:
			pitch -= 1.0                           # dive also pitches the nose down
		var qe := 0.0
		if Input.is_key_pressed(KEY_Q): qe += 1.0
		if Input.is_key_pressed(KEY_E): qe -= 1.0
		apply_torque(right * pitch * air_pitch_torque * mass)   # W/S = pitch
		apply_torque(up * steer_in * air_yaw_torque * mass)     # A/D = yaw (rotate)
		apply_torque(fwd * qe * air_roll_torque * mass)         # Q/E = roll
		# arrest rotation quickly once the controls are released
		var rot_input: float = absf(pitch) + absf(steer_in) + absf(qe)
		if rot_input < 0.15:
			angular_velocity = angular_velocity.lerp(Vector3.ZERO, 1.0 - exp(-10.0 * delta))
		# air-guidance upgrade: a slow correction back toward the road center (x=0)
		if center_assist > 0.001:
			var corr: float = clampf(-global_position.x * 0.3, -1.0, 1.0) * center_assist
			apply_central_force(Vector3((corr - linear_velocity.x * center_assist * 0.4) * mass, 0.0, 0.0))

	# soft top-speed cap so downhills don't run away to absurd speeds
	var soft_cap := 53.0   # m/s (~190 km/h)
	if speed > soft_cap:
		apply_central_force(-vel.normalized() * (speed - soft_cap) * mass * 2.5)

	# --- recover (R): ease upright + small lift ----------------------------
	if Input.is_key_pressed(KEY_R):
		var axis := up.cross(Vector3.UP)
		apply_torque(axis * 6.0 * mass)
		if up.dot(Vector3.UP) < 0.3:
			apply_central_force(Vector3.UP * 8.0 * mass)
		health -= delta * 4.0   # recovering costs a little

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

	# anti-tunnel safety: if a hard landing punched us through the ground, pop back up
	if terrain and not dead:
		var th: float = terrain.call("height_at", global_position.x, global_position.z)
		if global_position.y < th - 1.0:
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
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	global_transform = Transform3D(Basis(), start)
	reset_physics_interpolation()

func get_speed_kmh() -> float: return linear_velocity.length() * 3.6

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

func _hide_glb_wheels(node: Node) -> void:
	if str(node.name).to_lower().contains("wheel") and node is Node3D:
		(node as Node3D).visible = false
		return
	for c in node.get_children():
		_hide_glb_wheels(c)
