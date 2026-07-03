extends Node
## THROWAWAY: close 3/4-front screenshot of one procedural body (no GLB kit).

var _rf := 0
var _root: Node
var _cam: Camera3D

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	_root.set("save_enabled", false)
	_root.call("_begin_game")
	_root.call("_swap_vehicle", "hotrod")
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true

func _process(_d: float) -> void:
	_rf += 1
	var car: RigidBody3D = null
	for c in _root.get_children():
		if c is RigidBody3D:
			car = c
	if car and _rf > 10:
		var p := car.global_position
		var fwd: Vector3 = -car.global_transform.basis.z
		var right: Vector3 = car.global_transform.basis.x
		_cam.global_position = p + fwd * 4.6 + right * 3.0 + Vector3(0, 1.8, 0)
		_cam.look_at(p + Vector3(0, 0.7, 0), Vector3.UP)
	if _rf == 150:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://carshot.png")
		get_tree().quit()
