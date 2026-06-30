extends Node
const GlbUtil := preload("res://scripts/GlbUtil.gd")
func _ready() -> void:
	var scn := GlbUtil.load_scene("res://assets/car/kenney_sedan_cc0.glb")
	if scn == null:
		print("[glb] FAILED to load")
	else:
		print("[glb] tree:")
		_dump(scn, 0)
	get_tree().quit()
func _dump(n: Node, d: int) -> void:
	var pad := ""
	for i in range(d): pad += "  "
	var extra := ""
	if n is MeshInstance3D:
		var aabb: AABB = (n as MeshInstance3D).get_aabb()
		extra = "  MESH aabb_pos=%s size=%s" % [str(aabb.position.snapped(Vector3(0.01,0.01,0.01))), str(aabb.size.snapped(Vector3(0.01,0.01,0.01)))]
	print("%s- %s [%s]%s" % [pad, n.name, n.get_class(), extra])
	for c in n.get_children():
		_dump(c, d + 1)
