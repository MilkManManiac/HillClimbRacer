extends RigidBody3D
## Arcade car (raycast suspension + grip model) — grounded and responsive, not the
## floaty VehicleBody3D. Four RayCast3D "wheels" hold the body at ride height; a grip
## model kills sideways slide; steering sets yaw directly. A visual Tilt node leans the
## cabin into turns/braking without destabilizing the physics. First-person cabin camera.
##
## Local axes: front is -Z (windshield, headlights, camera look). +X is right.

# --- feel tunables -----------------------------------------------------------
@export var max_speed: float = 34.0      ## m/s (~122 km/h)
@export var reverse_speed: float = 11.0
@export var grip: float = 9.0            ## how hard lateral velocity is killed
@export var wheelbase: float = 2.8       ## front-to-rear axle (turn geometry)
@export var max_steer_angle: float = 0.6 ## rad at full lock (low speed)
@export var high_speed_steer: float = 0.45 ## fraction of steer removed at top speed
@export var max_yaw_rate: float = 1.7    ## rad/s cap so fast turns stay stable
@export var gravity_force: float = 32.0  ## strong gravity = planted, not floaty
# --- automatic gearbox (slow, gradual build to top speed) --------------------
@export var engine_power: float = 5200.0 ## drive force (N) at full torque in 1st gear
@export var brake_force: float = 6800.0
@export var coast_drag: float = 70.0     ## N per m/s when off throttle
@export var gear_top: Array[float] = [9.0, 16.0, 23.0, 29.0, 36.0]   ## upshift speeds (m/s)
@export var gear_force: Array[float] = [1.0, 0.70, 0.52, 0.40, 0.32] ## force multiplier per gear
@export var suspension_rest: float = 0.55
@export var suspension_stiff: float = 130.0
@export var suspension_damp: float = 9.0
@export var steer_smooth: float = 9.0
@export var base_fov: float = 74.0
@export var max_fov: float = 90.0
# CC0 exterior body (Kenney Car Kit, public domain). Tunable so it lines up nicely.
const GlbUtil := preload("res://scripts/GlbUtil.gd")
const CAR_GLB := "res://assets/car/kenney_sedan_cc0.glb"
@export var car_scale: float = 1.7
@export var car_offset: Vector3 = Vector3(0, 0.05, 0)
@export var car_yaw_deg: float = 0.0

# mouse-look
var _yaw: float = 0.0
var _pitch: float = 0.0
var _look_locked: bool = false
const LOOK_SENS := 0.0025
const YAW_MIN := -2.7
const YAW_MAX := 1.4
const PITCH_MIN := -1.0
const PITCH_MAX := 0.9

var _steer: float = 0.0
var _gear: int = 0
var _shift_cd: float = 0.0
var _rays: Array[RayCast3D] = []
var _grounded: bool = false
var _tilt: Node3D
var _cabin: Node3D
var _head: Node3D
var _cam: Camera3D
var _wheel_meshes: Array[MeshInstance3D] = []
var _prev_fwd_speed: float = 0.0

# cabin systems exposed for the cockpit
var headlights: Array[SpotLight3D] = []
var dome_light: OmniLight3D
var headlight_lens: Array[MeshInstance3D] = []
var dash_materials: Array[StandardMaterial3D] = []

func _ready() -> void:
	mass = 800.0
	can_sleep = false
	continuous_cd = true
	angular_damp = 3.0
	linear_damp = 0.15
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.5, 0)
	_build_chassis_collision()
	_build_rays_and_wheels()
	_build_tilt_and_cabin()

func _physics_process(delta: float) -> void:
	var up := global_transform.basis.y
	var fwd := -global_transform.basis.z
	var right := global_transform.basis.x
	var vel := linear_velocity
	var fwd_speed := vel.dot(fwd)
	var speed := vel.length()

	# --- raycast suspension: hold ride height, damped ----------------------
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

	# --- gravity (manual, strong) ------------------------------------------
	apply_central_force(Vector3.DOWN * gravity_force * mass)

	# --- steering input (smoothed + return to center) ----------------------
	var steer_raw := Input.get_axis("turn_right", "turn_left")  # +1 = left
	_steer = lerpf(_steer, steer_raw, 1.0 - exp(-steer_smooth * delta))

	if _grounded:
		# --- automatic gearbox: shift by speed, brief power cut on shift -----
		if _shift_cd > 0.0:
			_shift_cd -= delta
		if _gear < gear_top.size() - 1 and fwd_speed > gear_top[_gear]:
			_gear += 1
			_shift_cd = 0.28
		elif _gear > 0 and fwd_speed < gear_top[_gear - 1] * 0.65:
			_gear -= 1
			_shift_cd = 0.18

		var throttle := Input.get_action_strength("accelerate") - Input.get_action_strength("brake")
		if throttle > 0.01:
			# torque fades toward the top of the current gear, so each gear takes a
			# while and the whole climb to top speed is gradual
			if fwd_speed < max_speed and _shift_cd <= 0.0:
				var gf: float = clamp(fwd_speed / float(gear_top[_gear]), 0.0, 1.0)
				var torque: float = lerpf(1.0, 0.4, gf)
				var f: float = engine_power * float(gear_force[_gear]) * torque * throttle
				apply_central_force(fwd * f)
		elif throttle < -0.01:
			if fwd_speed > 0.5:
				apply_central_force(-fwd * brake_force * -throttle)          # brake
			elif fwd_speed > -reverse_speed:
				apply_central_force(fwd * throttle * engine_power * 0.30)     # reverse
		else:
			apply_central_force(-fwd * fwd_speed * coast_drag)               # engine drag

		# THE GRIP MODEL: cancel sideways velocity so it doesn't slide like a boat
		var lateral := right.dot(vel)
		apply_central_force(-right * lateral * grip * mass)

		# steering: bicycle model -> yaw rate scales with SPEED (natural feel; the car
		# can't pivot in place, and turn radius = wheelbase / tan(steer) is constant for
		# a given steer input). Steering authority eases off as speed rises for stability.
		var k: float = clamp(absf(fwd_speed) / max_speed, 0.0, 1.0)
		var steer_angle: float = _steer * max_steer_angle * (1.0 - k * high_speed_steer)
		# visually turn the front wheels
		if _wheel_meshes.size() >= 2:
			_wheel_meshes[0].rotation.y = steer_angle
			_wheel_meshes[1].rotation.y = steer_angle
		if absf(fwd_speed) > 0.3:
			var yaw_rate: float = (fwd_speed / wheelbase) * tan(steer_angle)
			yaw_rate = clamp(yaw_rate, -max_yaw_rate, max_yaw_rate)
			angular_velocity.y = yaw_rate
		else:
			angular_velocity.y = lerpf(angular_velocity.y, 0.0, 0.25)

	# --- visual lean (Tilt node only — physics body stays stable) ----------
	var fwd_accel: float = (fwd_speed - _prev_fwd_speed) / maxf(delta, 0.0001)
	_prev_fwd_speed = fwd_speed
	if _tilt:
		var lateral2 := right.dot(vel)
		var pitch: float = clamp(-fwd_accel * 0.010, -0.07, 0.07)
		var roll: float = clamp(-lateral2 * 0.018, -0.10, 0.10)
		_tilt.rotation.x = lerpf(_tilt.rotation.x, pitch, 1.0 - exp(-10.0 * delta))
		_tilt.rotation.z = lerpf(_tilt.rotation.z, roll, 1.0 - exp(-10.0 * delta))

	# camera FOV by speed
	if _cam:
		var kf: float = clamp(speed / max_speed, 0.0, 1.0)
		_cam.fov = lerpf(_cam.fov, lerpf(base_fov, max_fov, kf), 1.0 - exp(-6.0 * delta))

# --- look --------------------------------------------------------------------

func handle_look(rel: Vector2) -> void:
	if _look_locked or _head == null:
		return
	_yaw = clamp(_yaw - rel.x * LOOK_SENS, YAW_MIN, YAW_MAX)
	_pitch = clamp(_pitch - rel.y * LOOK_SENS, PITCH_MIN, PITCH_MAX)
	_head.rotation = Vector3(_pitch, _yaw, 0.0)

func get_camera() -> Camera3D: return _cam
func get_cabin() -> Node3D: return _cabin
func get_head() -> Node3D: return _head
func get_speed_kmh() -> float: return linear_velocity.length() * 3.6
func get_gear() -> int: return _gear + 1

# --- physics build -----------------------------------------------------------

func _build_chassis_collision() -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.9, 0.9, 4.2)
	col.shape = box
	col.position = Vector3(0, 0.75, 0)
	add_child(col)

func _build_rays_and_wheels() -> void:
	var fx := 0.95
	var fz := 1.45
	var ry := 0.55                 # ray origin height (local)
	for pos in [Vector3(-fx, ry, -fz), Vector3(fx, ry, -fz), Vector3(-fx, ry, fz), Vector3(fx, ry, fz)]:
		var ray := RayCast3D.new()
		ray.position = pos
		ray.target_position = Vector3(0, -(suspension_rest + 0.45), 0)
		ray.enabled = true
		ray.collision_mask = 1
		ray.add_exception(self)
		add_child(ray)
		_rays.append(ray)
		# visual wheel
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.38
		cyl.bottom_radius = 0.38
		cyl.height = 0.24
		mi.mesh = cyl
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.03, 0.03, 0.035)
		m.roughness = 1.0
		mi.material_override = m
		mi.rotation_degrees = Vector3(0, 0, 90)
		mi.position = pos + Vector3(0, -suspension_rest, 0)
		add_child(mi)
		_wheel_meshes.append(mi)

func _build_tilt_and_cabin() -> void:
	_tilt = Node3D.new()
	_tilt.name = "Tilt"
	_tilt.position = Vector3(0, 0.0, 0)
	add_child(_tilt)
	_cabin = Node3D.new()
	_cabin.name = "Cabin"
	_tilt.add_child(_cabin)
	_build_interior(_cabin)

func _build_car_body(c: Node3D) -> void:
	var body := GlbUtil.load_scene(CAR_GLB)
	if body == null:
		return                                  # keep procedural look if asset missing
	body.scale = Vector3.ONE * car_scale
	body.rotation_degrees = Vector3(0, car_yaw_deg, 0)
	body.position = car_offset
	c.add_child(body)
	# the GLB car has its own wheels; hide our raycast wheel cylinders
	for w in _wheel_meshes:
		w.visible = false

# --- interior (placeholder primitives; Cockpit.gd adds interactivity) --------

func _add_box(parent: Node3D, size: Vector3, color: Color, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	mi.material_override = m
	mi.position = pos
	mi.rotation_degrees = rot
	parent.add_child(mi)
	return mi

func _emissive(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m

func _build_interior(c: Node3D) -> void:
	var dark := Color(0.05, 0.05, 0.06)
	var darker := Color(0.03, 0.03, 0.035)
	# exterior shell + lower hood (out of sightline) + roof
	_add_box(c, Vector3(2.0, 0.5, 4.3), Color(0.10, 0.09, 0.11), Vector3(0, 0.55, 0))
	_add_box(c, Vector3(1.7, 0.18, 1.3), Color(0.11, 0.10, 0.11), Vector3(0, 0.82, -1.75))
	_add_box(c, Vector3(1.85, 0.08, 2.6), Color(0.10, 0.10, 0.11), Vector3(0, 1.95, 0.55))
	# dashboard
	_add_box(c, Vector3(1.85, 0.34, 0.4), dark, Vector3(0, 1.12, -1.05))
	_add_box(c, Vector3(0.5, 0.16, 0.3), Color(0.02, 0.02, 0.02), Vector3(-0.45, 1.28, -0.95))
	# steering wheel
	var wheel := MeshInstance3D.new()
	var wm := TorusMesh.new()
	wm.inner_radius = 0.14
	wm.outer_radius = 0.19
	wheel.mesh = wm
	wheel.material_override = StandardMaterial3D.new()
	wheel.material_override.albedo_color = Color(0.02, 0.02, 0.02)
	wheel.position = Vector3(-0.45, 1.16, -0.78)
	wheel.rotation_degrees = Vector3(75, 0, 0)
	c.add_child(wheel)
	# pillars, doors, seats
	_add_box(c, Vector3(0.1, 1.0, 0.1), dark, Vector3(-0.9, 1.45, -1.2))
	_add_box(c, Vector3(0.1, 1.0, 0.1), dark, Vector3(0.9, 1.45, -1.2))
	_add_box(c, Vector3(0.08, 0.7, 3.2), dark, Vector3(-0.92, 1.0, 0.2))
	_add_box(c, Vector3(0.08, 0.7, 3.2), dark, Vector3(0.92, 1.0, 0.2))
	_add_box(c, Vector3(1.7, 0.45, 0.55), darker, Vector3(0, 0.9, 1.1))
	_add_box(c, Vector3(1.7, 0.7, 0.18), darker, Vector3(0, 1.3, 1.4))
	# glowing gauges (dash backlight, toggleable)
	for gx in [-0.58, -0.32]:
		var rim := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.07
		tm.outer_radius = 0.082
		rim.mesh = tm
		var dm := _emissive(Color(0.1, 0.7, 0.9), 2.2)
		rim.material_override = dm
		rim.position = Vector3(gx, 1.28, -0.9)
		c.add_child(rim)
		dash_materials.append(dm)

	# head pivot + camera (front-left seat) — sit forward/up for a clear road view
	_head = Node3D.new()
	_head.name = "Head"
	_head.position = Vector3(-0.4, 1.58, -0.55)
	c.add_child(_head)
	_cam = Camera3D.new()
	_cam.name = "Camera"
	_cam.rotation_degrees = Vector3(-3, 0, 0)
	_cam.fov = base_fov
	_cam.current = true
	_head.add_child(_cam)

	# faint always-on cabin fill so the interior isn't pure black in daylight
	var fill := OmniLight3D.new()
	fill.position = Vector3(-0.1, 1.7, -0.3)
	fill.light_energy = 0.35
	fill.light_color = Color(0.7, 0.75, 0.85)
	fill.omni_range = 2.6
	c.add_child(fill)

	# interior dome light (off by default)
	dome_light = OmniLight3D.new()
	dome_light.position = Vector3(-0.1, 1.78, -0.4)
	dome_light.light_energy = 0.0
	dome_light.light_color = Color(1.0, 0.82, 0.55)
	dome_light.omni_range = 2.2
	dome_light.omni_attenuation = 2.0
	c.add_child(dome_light)

	# headlights (off by default) + lenses
	for x in [-0.62, 0.62]:
		var head := SpotLight3D.new()
		head.position = Vector3(x, 0.7, -2.1)
		head.rotation_degrees = Vector3(-4, 0, 0)
		head.light_energy = 0.0
		head.light_color = Color(1.0, 0.96, 0.85)
		head.spot_range = 60.0
		head.spot_angle = 48.0
		head.shadow_enabled = false
		c.add_child(head)
		headlights.append(head)
		var lens := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.3, 0.18, 0.05)
		lens.mesh = lm
		lens.material_override = _emissive(Color(1.0, 0.96, 0.85), 0.0)
		lens.position = Vector3(x, 0.85, -2.28)
		c.add_child(lens)
		headlight_lens.append(lens)
