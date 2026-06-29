extends Node3D
const SkyScript := preload("res://scripts/Sky.gd")
var _f := 0
func _ready() -> void:
	var s := Node3D.new()
	s.set_script(SkyScript)
	add_child(s)
	var cam := Camera3D.new()
	cam.rotation_degrees = Vector3(8, 0, 0)  # look just above horizon
	add_child(cam)
	cam.current = true
	# a flat gray test plane to judge the light color on a neutral surface
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(60, 60); mi.mesh = pm
	var m := StandardMaterial3D.new(); m.albedo_color = Color(0.5, 0.5, 0.5); mi.material_override = m
	mi.position = Vector3(0, -2, -10)
	add_child(mi)
func _process(_d: float) -> void:
	_f += 1
	if _f == 90:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://sky.png")
		print("[skytest] saved")
		get_tree().quit()
