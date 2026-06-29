extends Node
var _f := 0
func _ready() -> void:
	add_child(load("res://scenes/Main.tscn").instantiate())
func _process(_d: float) -> void:
	_f += 1
	if _f == 120:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://shot.png")
		print("[shot] saved")
		get_tree().quit()
