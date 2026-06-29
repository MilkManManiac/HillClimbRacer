extends VehicleBody3D
## Player-driven car (full vehicle physics). First-person cabin camera, headlights,
## and a placeholder PSX interior. The player actually drives: throttle, brake/reverse,
## and steer. Built procedurally so the whole car lives in code for now.
##
## Local axes: the car faces -Z (front: hood, windshield, headlights). +X is right.

@export var max_engine_force: float = 2900.0  ## launch force (N)
@export var max_brake: float = 52.0           ## brake strength
@export var reverse_force: float = 1400.0     ## force when reversing
@export var top_speed: float = 42.0           ## m/s (~150 km/h) soft cap
@export var reverse_top_speed: float = 12.0   ## m/s
@export var max_steer: float = 0.5            ## steer angle at standstill (rad)
@export var min_steer: float = 0.12           ## steer angle at top speed (rad)
@export var steer_speed: float = 5.0          ## how fast steering eases toward target
@export var downforce: float = 22.0           ## speed^2 downforce to glue the car
@export var base_fov: float = 74.0
@export var max_fov: float = 92.0

# mouse-look state (driver can freely look around the cabin, clamped)
var _yaw: float = 0.0
var _pitch: float = 0.0
var _look_locked: bool = false
const LOOK_SENS := 0.0025
const YAW_MIN := -2.7
const YAW_MAX := 1.4
const PITCH_MIN := -1.0
const PITCH_MAX := 0.9

var _steer: float = 0.0
var _head: Node3D
var _cam: Camera3D
var _wheels: Array[VehicleWheel3D] = []

func _ready() -> void:
	mass = 800.0
	continuous_cd = true                      # swept collision so we don't tunnel at speed
	_build_chassis_collision()
	_build_wheels()
	_build_interior()
	_build_lights()

func _physics_process(delta: float) -> void:
	var speed := linear_velocity.length()

	# --- steering: less authority at speed so it doesn't spin out ------------
	var steer_input := Input.get_axis("turn_right", "turn_left")  # +1 = left
	var k: float = clamp(speed / top_speed, 0.0, 1.0)
	var allowed: float = lerp(max_steer, min_steer, k)
	_steer = move_toward(_steer, steer_input * allowed, steer_speed * delta)
	steering = _steer

	# --- throttle / brake / reverse ----------------------------------------
	var fwd := Input.get_action_strength("accelerate")
	var rev := Input.get_action_strength("brake")
	var moving_fwd := -global_transform.basis.z.dot(linear_velocity) > 0.5

	# NOTE: in this chassis, positive engine_force drives toward +Z (the car's BACK),
	# so forward throttle uses NEGATIVE engine_force to move along -Z (the camera's view).
	engine_force = 0.0
	brake = 0.0
	if fwd > 0.01:
		# strong launch, smooth asymptotic cap at top_speed (1 - t^2 curve)
		var t: float = clamp(speed / top_speed, 0.0, 1.0)
		engine_force = -fwd * max_engine_force * (1.0 - t * t)
	elif rev > 0.01:
		if speed > 1.0 and moving_fwd:
			brake = rev * max_brake          # still rolling forward -> brake first
		else:
			var rt: float = clamp(speed / reverse_top_speed, 0.0, 1.0)
			engine_force = rev * reverse_force * (1.0 - rt)
	else:
		brake = 3.0                          # gentle engine drag when coasting

	# speed-scaled downforce keeps it planted through fast corners
	apply_central_force(-global_transform.basis.y * downforce * speed * speed * 0.01)

	# camera FOV widens with speed for a sense of pace
	if _cam:
		var target_fov: float = lerp(base_fov, max_fov, k)
		_cam.fov = lerp(_cam.fov, target_fov, 5.0 * delta)

# --- look --------------------------------------------------------------------

func handle_look(rel: Vector2) -> void:
	if _look_locked or _head == null:
		return
	_yaw = clamp(_yaw - rel.x * LOOK_SENS, YAW_MIN, YAW_MAX)
	_pitch = clamp(_pitch - rel.y * LOOK_SENS, PITCH_MIN, PITCH_MAX)
	_head.rotation = Vector3(_pitch, _yaw, 0.0)

func get_camera() -> Camera3D:
	return _cam

func get_speed_kmh() -> float:
	return linear_velocity.length() * 3.6

# --- physics build -----------------------------------------------------------

func _build_chassis_collision() -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.9, 1.0, 4.2)
	col.shape = box
	col.position = Vector3(0, 0.7, 0)
	add_child(col)
	# keep the centre of mass low so the car doesn't tip in corners
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.4, 0)

func _make_wheel(pos: Vector3, traction: bool, steer: bool) -> VehicleWheel3D:
	var w := VehicleWheel3D.new()
	w.position = pos
	w.use_as_traction = traction
	w.use_as_steering = steer
	w.wheel_radius = 0.38
	w.wheel_rest_length = 0.25
	w.wheel_friction_slip = 5.0
	w.wheel_roll_influence = 0.4              # built-in anti-roll, resists flipping
	w.suspension_stiffness = 22.0
	w.suspension_max_force = 8000.0
	w.damping_compression = 0.5
	w.damping_relaxation = 0.8
	add_child(w)
	# visible wheel mesh
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.38
	cyl.bottom_radius = 0.38
	cyl.height = 0.22
	mi.mesh = cyl
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.03, 0.03, 0.035)
	m.roughness = 1.0
	mi.material_override = m
	mi.rotation_degrees = Vector3(0, 0, 90)  # lay the cylinder on the wheel axle (X)
	w.add_child(mi)
	return w

func _build_wheels() -> void:
	var fx := 0.95   # half track width
	var fz := 1.45   # front axle Z (front is -Z)
	var rz := 1.45   # rear axle Z
	var wy := 0.3    # axle height
	_wheels = [
		_make_wheel(Vector3(-fx, wy, -fz), false, true),   # front-left  (steer)
		_make_wheel(Vector3( fx, wy, -fz), false, true),   # front-right (steer)
		_make_wheel(Vector3(-fx, wy,  rz), true, false),   # rear-left   (drive)
		_make_wheel(Vector3( fx, wy,  rz), true, false),   # rear-right  (drive)
	]

# --- interior + cosmetics (placeholder PSX primitives) -----------------------

func _add_box(size: Vector3, color: Color, pos: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
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
	add_child(mi)
	return mi

func _emissive(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	return m

func _build_interior() -> void:
	var dark := Color(0.05, 0.05, 0.06)
	var darker := Color(0.03, 0.03, 0.035)
	# exterior shell (so other cars/the world see a car, not floating glass)
	_add_box(Vector3(2.0, 0.5, 4.3), Color(0.06, 0.05, 0.07), Vector3(0, 0.55, 0))
	# hood out the windshield
	_add_box(Vector3(1.85, 0.35, 1.5), Color(0.07, 0.06, 0.07), Vector3(0, 0.95, -1.55))
	# roof
	_add_box(Vector3(1.85, 0.08, 2.6), dark, Vector3(0, 1.92, 0.45))
	# dashboard
	_add_box(Vector3(1.85, 0.34, 0.4), dark, Vector3(0, 1.12, -1.05))
	# instrument binnacle (front-left, driver side)
	_add_box(Vector3(0.5, 0.16, 0.3), Color(0.02, 0.02, 0.02), Vector3(-0.45, 1.28, -0.95))
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
	add_child(wheel)
	# A-pillars
	_add_box(Vector3(0.1, 1.0, 0.1), dark, Vector3(-0.9, 1.45, -1.2))
	_add_box(Vector3(0.1, 1.0, 0.1), dark, Vector3(0.9, 1.45, -1.2))
	# door panels
	_add_box(Vector3(0.08, 0.7, 3.2), dark, Vector3(-0.92, 1.0, 0.2))
	_add_box(Vector3(0.08, 0.7, 3.2), dark, Vector3(0.92, 1.0, 0.2))
	# rear bench
	_add_box(Vector3(1.7, 0.45, 0.55), darker, Vector3(0, 0.9, 1.1))
	_add_box(Vector3(1.7, 0.7, 0.18), darker, Vector3(0, 1.3, 1.4))
	# glowing gauges to keep the static cabin alive
	for gx in [-0.58, -0.32]:
		var rim := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.07
		tm.outer_radius = 0.082
		rim.mesh = tm
		rim.material_override = _emissive(Color(0.1, 0.7, 0.9), 2.2)
		rim.position = Vector3(gx, 1.28, gz_gauge())
		add_child(rim)

	# driver head pivot (front-LEFT seat); camera is its child
	_head = Node3D.new()
	_head.name = "Head"
	_head.position = Vector3(-0.4, 1.5, -0.15)
	add_child(_head)

	_cam = Camera3D.new()
	_cam.name = "Camera"
	_cam.rotation_degrees = Vector3(-3, 0, 0)
	_cam.fov = 78.0
	_cam.current = true
	_head.add_child(_cam)

	# dim warm dome light biased to the front so the back stays dark
	var dome := OmniLight3D.new()
	dome.position = Vector3(-0.1, 1.78, -0.4)
	dome.light_energy = 0.55
	dome.light_color = Color(1.0, 0.82, 0.55)
	dome.omni_range = 2.2
	dome.omni_attenuation = 2.0
	add_child(dome)

func gz_gauge() -> float:
	return -0.9

func _build_lights() -> void:
	for x in [-0.62, 0.62]:
		var head := SpotLight3D.new()
		head.position = Vector3(x, 0.7, -2.1)
		head.rotation_degrees = Vector3(-4, 0, 0)
		head.light_energy = 2.5
		head.light_color = Color(1.0, 0.96, 0.85)
		head.spot_range = 55.0
		head.spot_angle = 48.0
		head.shadow_enabled = false
		add_child(head)
