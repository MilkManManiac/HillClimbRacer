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
@export var engine_force: float = 16500.0
@export var max_speed: float = 112.0
@export var brake_force: float = 5500.0
@export var grip: float = 8.5
@export var slide_factor: float = 0.7      # how much grip you lose turning hard at speed (slides)
@export var wheelbase: float = 2.8
@export var max_steer_angle: float = 0.4   # smaller = gentler turns
@export var steer_rate: float = 3.0        # lower = slower steering response
@export var gravity_force: float = 17.0    # lower = floatier, more hang time
@export var suspension_rest: float = 0.55
@export var suspension_stiff: float = 95.0
@export var suspension_damp: float = 6.0
@export var dive_force: float = 26.0       # downward push when diving
@export var air_pitch_torque: float = 11.0
@export var air_roll_torque: float = 9.0
@export var air_yaw_torque: float = 6.0
@export var max_fuel: float = 600.0   # generous for the feel/air sandbox (tune later)
@export var max_health: float = 100.0
@export var land_damage_speed: float = 12.0  # vertical impact speed before damage starts

var fuel: float = 100.0
var health: float = 100.0
var distance: float = 0.0
var airborne: bool = false
var dead: bool = false

var _rays: Array[RayCast3D] = []
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
	linear_damp = 0.05
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

	# --- dive (hold Shift): weight + nose-down ------------------------------
	var diving := Input.is_key_pressed(KEY_SHIFT)
	if diving:
		apply_central_force(Vector3.DOWN * dive_force * mass)

	var throttle := Input.get_action_strength("accelerate")
	var braking := Input.get_action_strength("brake")
	var steer_in := Input.get_axis("turn_right", "turn_left")

	if _grounded:
		# drive / brake (fuel-gated)
		if fuel > 0.0 and throttle > 0.01 and fwd_speed < max_speed:
			apply_central_force(fwd * throttle * engine_force)
			fuel -= delta * (0.8 + throttle * 2.2)
		elif braking > 0.01:
			if fwd_speed > 0.5:
				apply_central_force(-fwd * brake_force * braking)
			else:
				apply_central_force(fwd * -braking * engine_force * 0.4)
		else:
			apply_central_force(-fwd * fwd_speed * 0.5 * mass * 0.02)
		fuel -= delta * 0.2   # idle burn
		# smoothed steering (slower response than raw input)
		_steer = lerpf(_steer, steer_in, 1.0 - exp(-steer_rate * delta))
		var k: float = clamp(speed / max_speed, 0.0, 1.0)
		# grip: kill sideways slide, but turning hard at speed loses grip -> it slides out
		var slide: float = clamp(absf(_steer) * k, 0.0, 1.0)
		var grip_eff: float = grip * (1.0 - slide_factor * slide)
		apply_central_force(-right * right.dot(vel) * grip_eff * mass)
		# steering (bicycle model)
		if absf(fwd_speed) > 0.4:
			var ang: float = _steer * max_steer_angle * (1.0 - k * 0.4)
			angular_velocity.y = (fwd_speed / wheelbase) * tan(ang)
	else:
		# --- airborne: full manual 3-axis (no assist) ----------------------
		var pitch := throttle - braking            # W nose up / S nose down
		if diving:
			pitch -= 1.0                           # dive also pitches the nose down
		var yaw := 0.0
		if Input.is_key_pressed(KEY_Q): yaw += 1.0
		if Input.is_key_pressed(KEY_E): yaw -= 1.0
		apply_torque(right * pitch * air_pitch_torque * mass)
		apply_torque(fwd * -steer_in * air_roll_torque * mass)
		apply_torque(up * yaw * air_yaw_torque * mass)

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

	# --- fuel/health bookkeeping -------------------------------------------
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
	_air_time = 0.0
	_flip_accum = 0.0

func reset_run(start: Vector3) -> void:
	dead = false
	fuel = max_fuel
	health = max_health
	distance = 0.0
	_air_time = 0.0
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
	for pos in [Vector3(-fx, 0.5, -fz), Vector3(fx, 0.5, -fz), Vector3(-fx, 0.5, fz), Vector3(fx, 0.5, fz)]:
		var ray := RayCast3D.new()
		ray.position = pos
		ray.target_position = Vector3(0, -(suspension_rest + 0.45), 0)
		ray.collision_mask = 1
		ray.add_exception(self)
		add_child(ray)
		_rays.append(ray)

func _build_body() -> void:
	var body := GlbUtil.load_scene(CAR_GLB)
	if body:
		body.scale = Vector3.ONE * 1.7
		body.position = Vector3(0, 0.1, 0)
		body.rotation.y = PI   # face -Z (travel direction); model was leading rear-first
		add_child(body)
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
