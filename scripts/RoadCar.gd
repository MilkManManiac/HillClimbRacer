extends Node3D
## Auto-paced car that drives a procedural road and stops at intersections
## to let the player choose LEFT or RIGHT. The left/right choice is the real input.
##
## Movement is deliberately simple (no vehicle physics): the car cruises the current
## leg at an eerie steady pace, slows into each intersection, and waits for a turn.

signal intersection_reached(turn_index: int)  ## fired when awaiting a choice
signal turned(direction: String)              ## "left" or "right"

@export var cruise_speed: float = 7.0         ## m/s on the open road
@export var leg_min: float = 60.0             ## min distance between intersections
@export var leg_max: float = 110.0
@export var road_width: float = 8.0
@export var slow_radius: float = 14.0         ## start slowing this far from intersection

var _heading: Vector3 = Vector3(0, 0, -1)     ## unit, XZ plane
var _leg_start: Vector3 = Vector3.ZERO
var _leg_end: Vector3 = Vector3.ZERO
var _speed: float = 0.0
var _awaiting_choice: bool = false
var _turn_count: int = 0
var _road_root: Node3D
var _bob_t: float = 0.0
var _body_base_y: float = 0.0

@onready var _body: Node3D = $Body

## Where the car is currently heading (the next intersection). Used by encounters
## that want to place something on the road ahead of the player.
func get_leg_end() -> Vector3:
	return _leg_end

func get_turn_count() -> int:
	return _turn_count

func is_stopped() -> bool:
	return _awaiting_choice

func _ready() -> void:
	randomize()
	_road_root = Node3D.new()
	_road_root.name = "RoadRoot"
	get_parent().call_deferred("add_child", _road_root)
	_leg_start = global_position
	call_deferred("_begin_leg")

var _first_leg: bool = true

func _begin_leg() -> void:
	var length := randf_range(leg_min, leg_max)
	if _first_leg:
		length = 28.0   # reach the first fork quickly so controls are discoverable
		_first_leg = false
	_leg_end = _leg_start + _heading * length
	_build_road_leg(_leg_start, _leg_end)
	_build_intersection(_leg_end)
	_awaiting_choice = false
	_speed = 0.0

func _physics_process(delta: float) -> void:
	if _awaiting_choice:
		# decelerate to a halt and read input
		_speed = lerp(_speed, 0.0, delta * 4.0)
		_apply_motion(delta)
		if Input.is_action_just_pressed("turn_left"):
			_take_turn("left")
		elif Input.is_action_just_pressed("turn_right"):
			_take_turn("right")
		return

	var to_end := _leg_end - global_position
	var dist := to_end.length()

	# slow on approach to the intersection, then hand off to the choice state
	var target := cruise_speed
	if dist < slow_radius:
		target = lerp(2.0, cruise_speed, clamp(dist / slow_radius, 0.0, 1.0))
	if Input.is_action_pressed("slow_down"):
		target *= 0.35
	_speed = lerp(_speed, target, delta * 2.0)

	if dist < 1.5:
		global_position = _leg_end
		_awaiting_choice = true
		intersection_reached.emit(_turn_count + 1)
		return

	_apply_motion(delta)

func _apply_motion(delta: float) -> void:
	global_position += _heading * _speed * delta
	# face travel direction; gentle so it reads as a heavy car.
	# +PI so the car's FRONT (local -Z: camera, hood, headlights) points along
	# the heading, not opposite it.
	if _heading.length() > 0.01:
		var target_yaw := atan2(_heading.x, _heading.z) + PI
		rotation.y = lerp_angle(rotation.y, target_yaw, delta * 5.0)
	_headbob(delta)

func _headbob(delta: float) -> void:
	if _body == null:
		return
	if _body_base_y == 0.0:
		_body_base_y = _body.position.y
	# idle engine vibration + speed-scaled bob; keeps the static cam alive
	var amt: float = 0.006 + (_speed / cruise_speed) * 0.02
	_bob_t += delta * (6.0 + _speed * 0.6)
	_body.position.y = _body_base_y + sin(_bob_t) * amt
	_body.position.x = sin(_bob_t * 0.5) * amt * 0.5

func _take_turn(direction: String) -> void:
	var angle := PI / 2.0 if direction == "right" else -PI / 2.0
	_heading = _heading.rotated(Vector3.UP, angle).normalized()
	_leg_start = _leg_end
	_turn_count += 1
	turned.emit(direction)
	_begin_leg()

# --- procedural geometry (placeholder PSX-flat assets) -----------------------

func _build_road_leg(a: Vector3, b: Vector3) -> void:
	var length := a.distance_to(b)
	var mid := (a + b) * 0.5
	var plane := PlaneMesh.new()
	plane.size = Vector2(road_width, length)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = _asphalt_mat()
	_road_root.add_child(mi)
	mi.global_position = mid
	mi.rotation.y = atan2((b - a).x, (b - a).z)
	# faint roadside posts so motion is legible in the fog
	var dir := (b - a).normalized()
	var perp := dir.cross(Vector3.UP).normalized()
	var n := int(length / 12.0)
	for i in range(1, n):
		var t := float(i) / float(n)
		var p := a.lerp(b, t)
		_spawn_post(p + perp * (road_width * 0.5 + 1.0))
		_spawn_post(p - perp * (road_width * 0.5 + 1.0))
	# faded centerline dashes for motion legibility
	var dashes := int(length / 6.0)
	for i in range(dashes):
		var t := (float(i) + 0.5) / float(dashes)
		var p := a.lerp(b, t)
		var dash := MeshInstance3D.new()
		var dm := BoxMesh.new()
		dm.size = Vector3(0.18, 0.02, 2.0)
		dash.mesh = dm
		var dmat := StandardMaterial3D.new()
		dmat.albedo_color = Color(0.35, 0.33, 0.28)
		dash.material_override = dmat
		_road_root.add_child(dash)
		dash.global_position = p + Vector3(0, 0.02, 0)
		dash.rotation.y = atan2(dir.x, dir.z)

func _build_intersection(center: Vector3) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(road_width, road_width)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = _asphalt_mat()
	_road_root.add_child(mi)
	mi.global_position = center
	# short stub arms showing the LEFT and RIGHT options at the fork
	var perp := _heading.cross(Vector3.UP).normalized()
	for s in [-1.0, 1.0]:
		var arm_dir: Vector3 = perp * float(s)
		var arm_end: Vector3 = center + arm_dir.normalized() * 16.0
		_build_stub(center, arm_end)

func _build_stub(a: Vector3, b: Vector3) -> void:
	var length := a.distance_to(b)
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(road_width, length)
	mi.mesh = plane
	mi.material_override = _asphalt_mat()
	_road_root.add_child(mi)
	mi.global_position = (a + b) * 0.5
	mi.rotation.y = atan2((b - a).x, (b - a).z)

func _spawn_post(pos: Vector3) -> void:
	var box := BoxMesh.new()
	box.size = Vector3(0.15, 1.6, 0.15)
	var mi := MeshInstance3D.new()
	mi.mesh = box
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.05, 0.05, 0.06)
	mi.material_override = m
	_road_root.add_child(mi)
	mi.global_position = pos + Vector3(0, 0.8, 0)

func _asphalt_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.04, 0.04, 0.045)
	m.roughness = 1.0
	m.metallic = 0.0
	return m
