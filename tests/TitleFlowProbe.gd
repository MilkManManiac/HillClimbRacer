extends Node
## Reproduces the title-screen flow exactly: boot -> click map buttons -> START.
## Times each step (a long synchronous rebuild reads as a "hang" in the GUI) and
## leaves stderr unfiltered so runtime script errors are visible.

var _root: Node
var _car: RigidBody3D
var _f := 0
var _stage := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	var t0 := Time.get_ticks_msec()
	add_child(_root)
	print("[title] boot build: %d ms" % (Time.get_ticks_msec() - t0))
	await get_tree().process_frame
	for c in _root.get_children():
		if c is RigidBody3D:
			_car = c
	# simulate the exact button handler the user clicks
	for mk in ["canyon", "alpine", "hills", "canyon"]:
		var t := Time.get_ticks_msec()
		_root.call("_on_title_map_button", mk)
		print("[title] click map '%s': %d ms" % [mk, Time.get_ticks_msec() - t])
	var t2 := Time.get_ticks_msec()
	_root.call("_begin_game")
	print("[title] START: %d ms, paused=%s" % [Time.get_ticks_msec() - t2, str(get_tree().paused)])
	# re-find the car in case the map flow rebuilt it
	for c in _root.get_children():
		if c is RigidBody3D:
			_car = c
	_stage = 1

func _physics_process(_d: float) -> void:
	if _stage != 1:
		return
	_f += 1
	if _f > 30:
		Input.action_press("accelerate")
	if _f == 600:
		var alive: bool = _car != null and not bool(_car.get("dead"))
		print("[title] after START drive: alive=%s dist=%.1f paused=%s" % [str(alive), float(_car.get("distance")) if _car else -1.0, str(get_tree().paused)])
		get_tree().quit(0 if alive else 1)
