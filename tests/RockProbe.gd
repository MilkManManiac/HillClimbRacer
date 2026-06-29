extends Node
const GlbUtil := preload("res://scripts/GlbUtil.gd")
func _ready() -> void:
	var m: Mesh = GlbUtil.load_mesh("res://assets/rocks/rock_quaternius_large_cc0.glb")
	if m:
		var aabb := m.get_aabb()
		print("[rock] native size = %s  (scaled x22 = %s)" % [str(aabb.size), str(aabb.size * 22.0)])
	else:
		print("[rock] failed to load")
	get_tree().quit()
