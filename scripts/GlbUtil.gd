extends RefCounted
## Runtime glTF loading helpers (no editor import needed). Used for CC0 props: trees,
## rocks, signs, the car body. load_scene() keeps the full node structure + materials;
## load_mesh() merges all surfaces into one Mesh for MultiMesh instancing.

static func load_scene(path: String) -> Node3D:
	if not FileAccess.file_exists(path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		return null
	var scene := doc.generate_scene(state)
	return scene as Node3D

static func load_mesh(path: String) -> Mesh:
	if not FileAccess.file_exists(path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		return null
	var scene := doc.generate_scene(state)
	if scene == null:
		return null
	var out := ArrayMesh.new()
	var mis: Array = []
	_collect(scene, mis)
	for mi in mis:
		var src: Mesh = mi.mesh
		if src == null:
			continue
		var t := _xform_to_root(mi, scene)
		for s in range(src.get_surface_count()):
			var arrays := src.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i in range(verts.size()):
				verts[i] = t * verts[i]
			arrays[Mesh.ARRAY_VERTEX] = verts
			if arrays[Mesh.ARRAY_NORMAL] != null:
				var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				for i in range(norms.size()):
					norms[i] = (t.basis * norms[i]).normalized()
				arrays[Mesh.ARRAY_NORMAL] = norms
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var mat: Material = src.surface_get_material(s)
			if mi.get_surface_override_material(s) != null:
				mat = mi.get_surface_override_material(s)
			out.surface_set_material(out.get_surface_count() - 1, mat)
	scene.queue_free()
	return out if out.get_surface_count() > 0 else null

static func _collect(node: Node, out: Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for c in node.get_children():
		_collect(c, out)

static func _xform_to_root(node: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t
