extends Node
## Boots the real game, starts a run, forces an open combo pot, and saves a PNG so
## the combo HUD can be verified visually (720p-safe, readable, not overlapping HUD).
## Run WITHOUT --headless; delete the PNG after looking at it.

var _rf := 0
var _began := false
var _potted := false
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
	if _rf == 90 and not _potted:
		_potted = true
		var car: Node = main.get("_car")
		if car:
			car.call("_combo_add", 100.0, "DRIFT")
			car.call("_combo_add", 100.0, "NEAR MISS")
			car.call("_combo_add", 100.0, "2.1s AIR")
	if _rf == 96 and not _done:
		_done = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://combo_shot.png")
		get_tree().quit()
