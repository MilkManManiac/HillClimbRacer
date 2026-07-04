extends Node
## THROWAWAY visual probe: boots the game, kills the car so the death shop opens,
## saves a PNG of the shop panel, quits. Run WITHOUT --headless.

var _f := 0
var _root: Node
var _car: RigidBody3D

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	_root.set("save_enabled", false)
	if _root.has_method("_begin_game"):
		_root.call("_begin_game")
	for c in _root.get_children():
		if c is RigidBody3D:
			_car = c

func _physics_process(_d: float) -> void:
	_f += 1
	if _f == 30 and _car:
		_car.set("health", 0.0)   # wreck instantly -> death flow opens the shop
	if _f == 150:
		get_viewport().get_texture().get_image().save_png("res://shopshot.png")
		get_tree().quit()
