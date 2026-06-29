extends Node
var _main: Node
var _curve: Curve3D
var _cam: Camera3D
var _f := 0
var _i := 0
var _dists := [80.0, 320.0, 560.0, 820.0]
func _ready() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	add_child(_main)
	_cam = Camera3D.new()
	add_child(_cam)
func _process(_d: float) -> void:
	_f += 1
	if _f == 30:
		_curve = _main.get_node("RoadCourse").call("get_curve")
	if _f >= 40 and _curve and (_f - 40) % 40 == 0 and _i < _dists.size():
		var xf: Transform3D = _curve.sample_baked_with_rotation(_dists[_i], true, true)
		var fwd := xf.basis.z
		var fwd_h := Vector3(fwd.x, 0, fwd.z).normalized()
		# above the road, looking down it at a low angle to see road vs dirt edge
		_cam.global_position = xf.origin - fwd_h * 6.0 + Vector3(0, 3.0, 0)
		_cam.look_at(xf.origin + fwd_h * 20.0 + Vector3(0, -1.0, 0), Vector3.UP)
		_cam.current = true
	if _f >= 60 and (_f - 60) % 40 == 0 and _i < _dists.size():
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://shot_%d.png" % _i)
		print("[shots] saved %d at d=%.0f" % [_i, _dists[_i]])
		_i += 1
		if _i >= _dists.size():
			get_tree().quit()
