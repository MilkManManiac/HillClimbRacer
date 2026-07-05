extends Node
## THROWAWAY: screenshots every procedural body at upgrade level 0 and level 6
## (engine/durability/wheels maxed) from front-3/4 and rear-3/4, to verify (a) no
## cage/engine-block/wheel-width growth as upgrades rise and (b) new body detail
## reads well. Delete the PNGs after review — this file is not part of the game.

var _root: Node
var _cam: Camera3D
var _vehicles := ["hotrod", "minivan", "monster", "sports", "f1"]
var _shots := []   # built in _ready: [vehicle, level, angle]
var _shot_i := 0
var _frame := 0
var _frozen_at := -1   # render-frame index the car was frozen on (for this shot)
const SHOT_DELAY := 12   # frames after freezing before we snap the picture

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for v in _vehicles:
		_shots.append([v, 0, "front"])
		_shots.append([v, 0, "rear"])
		_shots.append([v, 6, "front"])
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
	var veh: String = s[0]
	var lvl: int = s[1]
	_root.call("_swap_vehicle", veh)
	_root.set("money", 999999999)
	for i in range(lvl):
		_root.call("_buy", "engine")
		_root.call("_buy", "durability")
		_root.call("_buy", "wheels")
	# buying Durability changes max_health without rescaling current health, which
	# can cross a panel-shed threshold (a real gameplay interaction, but noise for
	# a clean reference shot) — reset_run restores full health and clears any
	# flying debris so every screenshot is a clean, comparable pose.
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
	# The track is a downhill road — with no drive input the car just rolls under
	# gravity once it lands and can be doing 100+ km/h (or mid-jump) within a
	# second of wall-clock time. FREEZE it the moment it first touches down (not
	# after a fixed frame count — real-time rendering vs. the fixed physics tick
	# rate means "N render frames" is not a reliable proxy for "N physics steps")
	# so every vehicle/level gets a clean, comparable static pose.
	if _frozen_at < 0:
		if _frame > 2 and not bool(car.get("airborne")):
			car.freeze = true
			car.linear_velocity = Vector3.ZERO
			car.angular_velocity = Vector3.ZERO
			_frozen_at = _frame
		return
	var s: Array = _shots[_shot_i]
	var angle: String = s[2]
	var p := car.global_position
	var fwd: Vector3 = -car.global_transform.basis.z
	var right: Vector3 = car.global_transform.basis.x
	var dir: float = 1.0 if angle == "front" else -1.0
	_cam.global_position = p + fwd * 7.5 * dir + right * 4.8 + Vector3(0, 2.8, 0)
	_cam.look_at(p + Vector3(0, 0.9, 0), Vector3.UP)
	if _frame - _frozen_at >= SHOT_DELAY:
		var fname := "res://detailshot_%s_L%d_%s.png" % [s[0], s[1], s[2]]
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(fname)
		_shot_i += 1
		_setup_shot()
