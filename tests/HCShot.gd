extends Node
var _rf := 0
var _done := false
func _ready() -> void:
	add_child(load("res://scenes/HillClimb.tscn").instantiate())
func _process(_d: float) -> void:
	_rf += 1
	if _rf > 30:
		Input.action_press("accelerate")
	if _rf == 220 and not _done:
		_done = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://hc.png")
		get_tree().quit()
