extends Node
var _rf := 0; var _done := false; var _root: Node; var _car: RigidBody3D; var _cam: Camera3D
func _ready() -> void:
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	for c in _root.get_children():
		if c is RigidBody3D: _car = c
	_cam = Camera3D.new(); add_child(_cam); _cam.current = true
func _process(_d: float) -> void:
	_rf += 1
	if _rf == 20:
		for k in ["suspension","wings","ailerons","wheels","engine"]:
			_root.call("_set_level", k, 6)
	if _rf > 20 and _car:
		var p := _car.global_position
		_cam.global_position = p + Vector3(3.5, 2.6, 5.5)
		_cam.look_at(p + Vector3(0, 0.8, 0), Vector3.UP)
	if _rf == 70 and not _done:
		_done = true
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://hc.png")
		get_tree().quit()
