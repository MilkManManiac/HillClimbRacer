extends Node
## THROWAWAY visual probe: boots the game, dresses the active ride in a Kenney GLB
## body kit via the garage path, frames the car, saves a PNG, quits. Run WITHOUT
## --headless (viewport capture needs a renderer).

var _rf := 0
var _root: Node
var _cam: Camera3D

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	_root.call("_begin_game")
	_root.set("save_enabled", false)   # NEVER write the developer's real save from a probe
	var kits: Dictionary = _root.get("_body_kits")
	kits[str(_root.get("_vehicle"))] = "res://assets/car/kenney_sedan_cc0.glb"
	_root.call("_swap_vehicle", str(_root.get("_vehicle")))

func _process(_d: float) -> void:
	_rf += 1
	if _rf > 30:
		Input.action_press("accelerate")   # roll forward so the GAME camera frames it live
	if _rf == 150:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://kitshot.png")
		get_tree().quit()
