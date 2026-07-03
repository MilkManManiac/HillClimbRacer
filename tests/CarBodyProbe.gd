extends Node
## Headless probe: loads every .glb in assets/car/ through HCCarBody.load_body(),
## reports the original AABB, applied scale, and wheel-node detection for each, then
## exits 0 if all loaded successfully or 1 if any failed. Modeled on tests/GlbProbe.gd.

const HCCarBody := preload("res://scripts/hc/HCCarBody.gd")
const CAR_DIR := "res://assets/car"
const TARGET_SIZE := Vector3(2.0, 1.2, 4.2)

func _ready() -> void:
	var paths := _list_glbs(CAR_DIR)
	paths.sort()
	var all_ok := true
	print("[car_body_probe] target_size=%s  found %d glb(s)" % [str(TARGET_SIZE), paths.size()])
	for path in paths:
		var ok := _probe_one(path)
		all_ok = all_ok and ok
	print("[car_body_probe] %s" % ("ALL PASS" if all_ok else "SOME FAILED"))
	get_tree().quit(0 if all_ok else 1)

func _probe_one(path: String) -> bool:
	const GlbUtil := preload("res://scripts/GlbUtil.gd")

	# Load once raw (pre-fit) so we can report the original AABB size before HCCarBody
	# reparents/rescales it inside a wrapper.
	var raw: Node3D = GlbUtil.load_scene(path)
	if raw == null:
		print("[car_body_probe] %s -> FAIL (could not load scene)" % path)
		return false
	var orig_aabb := HCCarBody.body_aabb(raw)
	raw.queue_free()

	var wrapper := HCCarBody.load_body(path, TARGET_SIZE)
	if wrapper == null:
		print("[car_body_probe] %s -> FAIL (load_body returned null)" % path)
		return false

	var wheels := HCCarBody.find_wheels(wrapper)
	HCCarBody.hide_wheels(wrapper)
	var wheel_names: Array = []
	for w in wheels:
		wheel_names.append(String(w.name))

	var pass_ok := orig_aabb.size.length() > 0.0001 and wrapper.scale.x > 0.0
	print("[car_body_probe] %s -> %s" % [path, ("PASS" if pass_ok else "FAIL")])
	print("    orig_aabb_size=%s" % str(orig_aabb.size.snapped(Vector3(0.001, 0.001, 0.001))))
	print("    applied_scale=%.4f" % wrapper.scale.x)
	print("    wheels=%d %s" % [wheel_names.size(), str(wheel_names)])

	wrapper.queue_free()
	return pass_ok

func _list_glbs(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.to_lower().ends_with(".glb"):
			out.append("%s/%s" % [dir_path, fname])
		fname = dir.get_next()
	dir.list_dir_end()
	return out
