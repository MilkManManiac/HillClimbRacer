extends Node
## Boots the real game (title screen up, tree paused) and saves a PNG so the menu
## layout can be verified visually — START must be on-screen at 1280x720.

var _rf := 0
var _done := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(load("res://scenes/HillClimb.tscn").instantiate())

func _process(_d: float) -> void:
	_rf += 1
	if _rf == 30 and not _done:
		_done = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://title.png")
		get_tree().quit()
