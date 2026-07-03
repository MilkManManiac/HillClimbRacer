extends Node
## Map-select probe: for each entry in HCMain.MAPS, spin up a fresh HillClimb.tscn,
## switch to that map, hold the throttle for ~600 physics ticks, and assert the car
## is alive with meaningful distance covered. Run headless:
##   <godot_console> --headless --path . tests/MapProbe.tscn

const TICKS := 600
const MIN_DIST := 30.0
const HCMainScript := preload("res://scripts/hc/HCMain.gd")

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var ok := true
	var root := load("res://scenes/HillClimb.tscn") as PackedScene
	for key in HCMainScript.MAP_KEYS:
		var pass_ok := await _run_map(root, key)
		ok = ok and pass_ok

	get_tree().quit(0 if ok else 1)

## Boot one HillClimb instance, switch to `key`, drive for TICKS physics frames
## holding the accelerator, then check the car survived and covered ground.
func _run_map(root: PackedScene, key: String) -> bool:
	var inst: Node3D = root.instantiate()
	add_child(inst)
	await get_tree().process_frame
	if inst.has_method("select_map"):
		inst.call("select_map", key)
	if inst.has_method("_begin_game"):
		inst.call("_begin_game")
	await get_tree().process_frame

	var car: RigidBody3D = null
	for c in inst.get_children():
		if c is RigidBody3D:
			car = c
	if car == null:
		print("[map] %s FAIL no car found" % key)
		inst.queue_free()
		return false

	var start_dist: float = car.get("distance")
	Input.action_press("accelerate")
	for i in range(TICKS):
		await get_tree().physics_frame
	Input.action_release("accelerate")

	var alive := not bool(car.get("dead"))
	var dist: float = car.get("distance")
	var gained := dist - start_dist
	var pass_ok := alive and gained > MIN_DIST
	print("[map] %s %s dist=%.1f gained=%.1f alive=%s" % [key, "OK" if pass_ok else "FAIL", dist, gained, alive])

	inst.queue_free()
	await get_tree().process_frame
	return pass_ok
