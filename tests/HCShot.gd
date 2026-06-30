extends Node
var _rf := 0; var _done := false; var _root: Node
func _ready() -> void:
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
func _process(_d: float) -> void:
	_rf += 1
	if _rf == 20:
		for k in ["wings","ailerons","suspension","wheels","engine"]:
			_root.call("_set_level", k, 6)
	if _rf > 40: Input.action_press("accelerate")
	if _rf == 200 and not _done:
		_done = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://hc.png")
		get_tree().quit()
