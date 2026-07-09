extends Node
## Boots the real game, buys Party Balloons, throws the car in the air with the float
## held, and saves a PNG so the inflated bundle can be verified visually on the car.
## Run WITHOUT --headless; delete the PNG after looking at it.

var _rf := 0
var _began := false
var _flying := false
var _done := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var main: Node = load("res://scenes/HillClimb.tscn").instantiate()
	main.set("save_enabled", false)
	add_child(main)

func _process(_d: float) -> void:
	_rf += 1
	var main := get_child(0)
	if _rf == 20 and not _began:
		_began = true
		main.call("_begin_game")
	if _rf == 90 and not _flying:
		_flying = true
		main.set("money", 100000)
		main.call("_buy", "balloons")
		main.call("_buy", "balloons")
		main.call("_buy", "balloons")
		var car: Node = main.get("_car")
		if car:
			(car as Node3D).global_position += Vector3(0, 18.0, 0)
			(car as RigidBody3D).linear_velocity = Vector3.ZERO
		Input.action_press("float")
	if _rf == 170 and not _done:   # ~1.3 s later: inflate envelope fully open
		_done = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://balloon_shot.png")
		Input.action_release("float")
		get_tree().quit()
