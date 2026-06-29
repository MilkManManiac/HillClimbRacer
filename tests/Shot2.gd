extends Node
var _f := 0
var _main: Node
var _cam: Camera3D
func _ready() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	add_child(_main)
func _process(_d: float) -> void:
	_f += 1
	if _f == 60:
		var car: Node3D = _main.call("get_car")
		var fwd := -car.global_transform.basis.z
		_cam = Camera3D.new()
		add_child(_cam)
		_cam.global_position = car.global_position - fwd * 14.0 + Vector3(0, 9, 0)
		_cam.look_at(car.global_position + fwd * 30.0, Vector3.UP)
		_cam.current = true
	if _f == 120:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://shot2.png")
		print("[shot2] saved")
		get_tree().quit()
