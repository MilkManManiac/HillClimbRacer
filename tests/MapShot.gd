extends Node
## THROWAWAY: screenshot each non-default map through the game camera (drive a few
## seconds first so tiles/scatter stream in). Run WITHOUT --headless.

var _rf := 0
var _root: Node
var _maps := ["canyon", "alpine"]
var _idx := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_boot()

func _boot() -> void:
	if _root:
		_root.queue_free()
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	_root.set("save_enabled", false)
	_root.call("select_map", _maps[_idx])
	_root.call("_begin_game")
	_rf = 0

func _process(_d: float) -> void:
	_rf += 1
	if _rf > 30:
		Input.action_press("accelerate")
	if _rf == 260:
		Input.action_release("accelerate")
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://mapshot_%s.png" % _maps[_idx])
		_idx += 1
		if _idx >= _maps.size():
			get_tree().quit()
		else:
			_boot()
