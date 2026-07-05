extends Node
## THROWAWAY: closer-in shots to check small details (mirrors, exhaust tips,
## brake calipers, antennas) actually read instead of being lost in the wide shot.

var _root: Node
var _cam: Camera3D
var _shots := [
	["f1", "front", 3.2, 2.0, 1.2],
	["f1", "side", 3.5, 0.0, 1.0],
	["hotrod", "side", 3.5, 0.0, 1.0],
	["monster", "front", 5.0, 3.2, 1.8],
	["sports", "side", 3.2, 0.0, 0.9],
]
var _shot_i := 0
var _frame := 0
var _frozen_at := -1
const SHOT_DELAY := 12

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	_root.set("save_enabled", false)
	_root.call("_begin_game")
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true
	_setup_shot()

func _setup_shot() -> void:
	if _shot_i >= _shots.size():
		get_tree().quit()
		return
	var s: Array = _shots[_shot_i]
	_root.call("_swap_vehicle", s[0])
	var car = _root.get("_car")
	if car:
		car.call("reset_run", car.global_position)
	_frame = 0
	_frozen_at = -1

func _process(_d: float) -> void:
	if _shot_i >= _shots.size():
		return
	_frame += 1
	var car: RigidBody3D = null
	for c in _root.get_children():
		if c is RigidBody3D:
			car = c
	if car == null:
		return
	if _frozen_at < 0:
		if _frame > 2 and not bool(car.get("airborne")):
			car.freeze = true
			car.linear_velocity = Vector3.ZERO
			car.angular_velocity = Vector3.ZERO
			_frozen_at = _frame
		return
	var s: Array = _shots[_shot_i]
	var angle: String = s[1]
	var dist: float = s[2]
	var side_amt: float = s[3]
	var up_amt: float = s[4]
	var p := car.global_position
	var fwd: Vector3 = -car.global_transform.basis.z
	var right: Vector3 = car.global_transform.basis.x
	if angle == "front":
		_cam.global_position = p + fwd * dist + right * side_amt + Vector3(0, up_amt, 0)
	else:   # side profile
		_cam.global_position = p + right * dist + Vector3(0, up_amt, 0)
	_cam.look_at(p + Vector3(0, 0.6, 0), Vector3.UP)
	if _frame - _frozen_at >= SHOT_DELAY:
		var fname := "res://detail2_%s_%s.png" % [s[0], s[1]]
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fname)
		_shot_i += 1
		_setup_shot()
