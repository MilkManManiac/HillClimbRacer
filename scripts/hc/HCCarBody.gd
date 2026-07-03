extends RefCounted
## Runtime GLB car-body pipeline. Loads a .glb via GlbUtil.load_scene, fits it to a
## target footprint, and hides any nodes that look like wheels (the game draws its
## own physics wheels, so imported wheel meshes would double up).
##
## INTEGRATION CONTRACT (HCCar.gd, not owned by this file — read only):
##   1. HCCar calls `HCCarBody.load_body(path, _vs.col)` where `_vs.col` is the
##      VSPEC collision-box Vector3(width_x, height_y, length_z) for the active
##      vehicle_type. This returns a Node3D wrapper already centered, floor-aligned
##      (local y=0 = bottom of model), uniformly scaled to fit that footprint, and
##      facing -Z.
##   2. HCCar calls `HCCarBody.hide_wheels(wrapper)` to hide any child nodes whose
##      names match "wheel"/"tire"/"tyre", since HCCar renders its own wheels.
##   3. HCCar `add_child()`s the wrapper in place of (or alongside, then frees) its
##      procedural `_body` node. The wrapper is a plain Node3D so it composes with
##      existing `_body.scale` stretch/wide chassis-upgrade logic the same way the
##      procedural body does.
##   4. If `load_body()` returns null (missing file / bad glTF), the caller should
##      fall back to the procedural body — this module never throws.

const _WHEEL_KEYWORDS := ["wheel", "tire", "tyre"]

## Loads the GLB at glb_path and returns a Node3D wrapper fit to target_size
## (Vector3(width_x, height_y, length_z)). Returns null on load failure.
## Set flip_forward = true if the source model is authored facing +Z instead of -Z
## (Godot's forward), since facing can't be reliably auto-detected from geometry alone.
static func load_body(glb_path: String, target_size: Vector3, flip_forward: bool = false) -> Node3D:
	const GlbUtil := preload("res://scripts/GlbUtil.gd")
	var model: Node3D = GlbUtil.load_scene(glb_path)
	if model == null:
		return null

	var wrapper := Node3D.new()
	wrapper.name = "GlbBody"
	wrapper.add_child(model)

	var aabb := body_aabb(model)
	if aabb.size.length() <= 0.0001:
		# Degenerate mesh (no MeshInstance3Ds found) — still return the wrapper as-is.
		return wrapper

	# Center horizontally (x, z) and drop the bottom to local y=0.
	model.position = Vector3(
		-(aabb.position.x + aabb.size.x * 0.5),
		-aabb.position.y,
		-(aabb.position.z + aabb.size.z * 0.5)
	)

	if flip_forward:
		model.rotate_y(PI)

	# Uniform scale that fits the footprint (x = width, z = length) without overflowing
	# either axis; pick the smaller of the two candidate scales to preserve aspect.
	var scale := 1.0
	if aabb.size.x > 0.0001 and aabb.size.z > 0.0001:
		var sx: float = target_size.x / aabb.size.x
		var sz: float = target_size.z / aabb.size.z
		scale = min(sx, sz)
	elif aabb.size.x > 0.0001:
		scale = target_size.x / aabb.size.x
	elif aabb.size.z > 0.0001:
		scale = target_size.z / aabb.size.z
	if scale <= 0.0:
		scale = 1.0
	wrapper.scale = Vector3(scale, scale, scale)

	return wrapper

## Per-wheel geometry for auto-fitting the game's wheel/ray stance to the asset.
## Call AFTER load_body. Returns one entry per OUTERMOST wheel-named node:
##   {"center": Vector3 (wrapper-local, wrapper scale already applied),
##    "radius": float (scaled)}
## Nested wheel-named children (a mesh inside a wheel container) are skipped so a
## 4-wheel car yields 4 entries, and spares can be filtered by the caller (they sit
## higher than the ground wheels).
static func wheel_info(wrapper: Node3D) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var s: float = wrapper.scale.x
	for w in find_wheels(wrapper):
		var nested := false
		var p := w.get_parent()
		while p != null and p != wrapper:
			var lname := String(p.name).to_lower()
			for kw in _WHEEL_KEYWORDS:
				if lname.find(kw) != -1:
					nested = true
					break
			if nested:
				break
			p = p.get_parent()
		if nested:
			continue
		var t := _xform_to_root(w, wrapper)
		var center := t.origin
		var radius := 0.3
		var meshes: Array = []
		_collect_meshes(w, meshes)
		if not meshes.is_empty():
			var ab: AABB = (meshes[0] as MeshInstance3D).get_aabb()
			for k in range(1, meshes.size()):
				ab = ab.merge((meshes[k] as MeshInstance3D).get_aabb())
			center = t * ab.get_center()
			radius = ab.size.y * 0.5          # wheel circle spans the local Y extent
		out.append({"center": center * s, "radius": radius * s})
	return out

## Clamp imported PBR toward matte. AI-generated / photoreal materials come in glossy
## and read "wet" next to the game's flat-shaded procedural look; pulling roughness up
## and metallic down blends them in without touching albedo.
static func matte_materials(root: Node3D, min_rough := 0.6, max_metal := 0.5) -> void:
	var meshes: Array = []
	_collect_meshes(root, meshes)
	for mi in meshes:
		var m3 := mi as MeshInstance3D
		for si in range(m3.mesh.get_surface_count()):
			for m in [m3.mesh.surface_get_material(si), m3.get_surface_override_material(si)]:
				if m is BaseMaterial3D:
					m.roughness = maxf(m.roughness, min_rough)
					m.metallic = minf(m.metallic, max_metal)

## Returns descendant nodes of root whose name case-insensitively contains
## "wheel", "tire", or "tyre".
static func find_wheels(root: Node3D) -> Array[Node3D]:
	var out: Array[Node3D] = []
	_find_wheels_recursive(root, out)
	return out

## Hides (visible = false) every node returned by find_wheels(root).
static func hide_wheels(root: Node3D) -> void:
	for w in find_wheels(root):
		if w is Node3D:
			w.visible = false
		elif w.has_method("set_visible"):
			w.call("set_visible", false)

## Returns the merged AABB of every MeshInstance3D under root, expressed in root's
## local space (i.e. each mesh's local AABB transformed by its path down to root).
static func body_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var meshes: Array = []
	_collect_meshes(root, meshes)
	for mi in meshes:
		var t := _xform_to_root(mi, root)
		var local_aabb: AABB = (mi as MeshInstance3D).get_aabb()
		var world_aabb := t * local_aabb
		if first:
			result = world_aabb
			first = false
		else:
			result = result.merge(world_aabb)
	return result

static func _find_wheels_recursive(node: Node, out: Array[Node3D]) -> void:
	var lname := String(node.name).to_lower()
	for kw in _WHEEL_KEYWORDS:
		if lname.find(kw) != -1:
			if node is Node3D:
				out.append(node)
			break
	for c in node.get_children():
		_find_wheels_recursive(c, out)

static func _collect_meshes(node: Node, out: Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for c in node.get_children():
		_collect_meshes(c, out)

static func _xform_to_root(node: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t
