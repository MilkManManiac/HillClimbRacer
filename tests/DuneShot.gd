extends Node
## Boots Dune Drift in a sports car, drives at speed, and saves chase-cam PNGs so the
## golden-hour palette/rollers/scenery can be verified visually.
## Run WITHOUT --headless; delete the PNGs after looking at them.

var _rf := 0
var _began := false
var _shots := 0

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
		main.call("select_map", "dunes")
		main.call("_swap_vehicle", "sports")
		main.call("_begin_game")
		Input.action_press("accelerate")
	if _rf == 350 and _shots == 0:
		_shots = 1
		_snap("res://dune_shot_1.png")
	if _rf == 560 and _shots == 1:
		_shots = 2
		_snap("res://dune_shot_2.png")
		Input.action_release("accelerate")
		get_tree().quit()

func _snap(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
