extends Node
## THROWAWAY: screenshot each map's new ambient-life layer (HCScenery.gd) through the
## real game camera. Run WITHOUT --headless. Hills/midnight get TWO frames a couple of
## seconds apart (birds circle slowly and the shooting star is a brief event forced via
## HCScenery.debug_trigger_star for the fixed screenshot window) so motion is visible;
## everything else gets one frame after driving long enough for the effect to read.

var _rf := 0
var _root: Node
var _maps := ["hills", "canyon", "alpine", "midnight", "gravity"]
var _idx := 0
var _shot2_pending := false

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
	if _maps[_idx] == "midnight":
		var scenery: Node = _root.get("_scenery")
		if scenery:
			scenery.call("debug_trigger_star")
	_rf = 0
	_shot2_pending = false

func _process(_d: float) -> void:
	_rf += 1
	if _rf > 30:
		Input.action_press("accelerate")
	if _rf == 260:
		Input.action_release("accelerate")
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://ambientshot_%s.png" % _maps[_idx])
		if _maps[_idx] in ["hills", "midnight"]:
			_shot2_pending = true
		else:
			_advance()
	elif _shot2_pending and _rf == 350 and _maps[_idx] == "midnight":
		# re-trigger ~0.5s before the second capture (not exactly on it) so the streak
		# is caught mid-fade near its brightest, not at progress=0 (invisible start)
		var scenery: Node = _root.get("_scenery")
		if scenery:
			scenery.call("debug_trigger_star")
	elif _shot2_pending and _rf == 380:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://ambientshot_%s_b.png" % _maps[_idx])
		_advance()

func _advance() -> void:
	_idx += 1
	if _idx >= _maps.size():
		get_tree().quit()
	else:
		_boot()
