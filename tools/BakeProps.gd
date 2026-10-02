extends SceneTree
## One-off asset bake: turns the photo-scanned Poly Haven models in assets/desert/ (60-190k
## triangles each — fine for a film, far too heavy to scatter by the hundred) into small
## game meshes saved as native .res files the game can load() with no import step.
## Run from the project root, WITHOUT --headless (mesh data needs the real renderer):
##   <godot> --path . --script tools/BakeProps.gd
## Re-run only when a source model changes; the baked files are committed.

const GlbUtil := preload("res://scripts/GlbUtil.gd")
const OUT_DIR := "res://assets/desert/baked/"

## source gltf -> [output name, triangle budget (0 = keep as authored), split per node]
const JOBS := [
	["res://assets/desert/namaqualand_boulder_03/namaqualand_boulder_03_1k.gltf", "boulder_03", 1400, false],
	["res://assets/desert/namaqualand_boulder_04/namaqualand_boulder_04_1k.gltf", "boulder_04", 1400, false],
	["res://assets/desert/namaqualand_boulder_05/namaqualand_boulder_05_1k.gltf", "boulder_05", 1200, false],
	["res://assets/desert/namaqualand_boulder_06/namaqualand_boulder_06_1k.gltf", "boulder_06", 1200, false],
	["res://assets/desert/namaqualand_cliff_02/namaqualand_cliff_02_1k.gltf", "cliff_02", 9000, false],
	["res://assets/desert/concrete_road_barrier/concrete_road_barrier_1k.gltf", "barrier", 900, false],
	["res://assets/desert/old_tyre/old_tyre_1k.gltf", "tyre", 0, false],
	["res://assets/desert/wild_rooibos_bush/wild_rooibos_bush_1k.gltf", "bush", 0, true],
]

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for job in JOBS:
		_bake(str(job[0]), str(job[1]), int(job[2]), bool(job[3]))
	quit()

func _bake(src: String, out_name: String, budget: int, split: bool) -> void:
	var scene := GlbUtil.load_scene(src)
	if scene == null:
		push_error("bake: cannot load %s" % src)
		return
	var mis: Array = []
	_collect(scene, mis)
	var idx := 0
	var merged: Array = []   # [arrays] across nodes when not splitting
	for mi in mis:
		var m: Mesh = mi.mesh
		var xf := _xform_to_root(mi, scene)
		var parts: Array = []
		for s in range(m.get_surface_count()):
			parts.append(_transformed(m.surface_get_arrays(s), xf))
		if split:
			# one output per NODE (a bush is twigs + leaves + stem surfaces sharing one
			# texture set — baked together so it can be a single MultiMesh instance)
			_save(_recentre(_reduce(_merge(parts), budget)), "%s_%s" % [out_name, char(97 + idx)])
			idx += 1
		else:
			merged.append_array(parts)
	if not split:
		_save(_recentre(_reduce(_merge(merged), budget)), out_name)
	scene.free()

## Concatenate several surfaces' arrays into one (they must share a texture set).
func _merge(parts: Array) -> Array:
	if parts.size() == 1:
		return parts[0]
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var tans := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for a in parts:
		var base := verts.size()
		verts.append_array(a[Mesh.ARRAY_VERTEX])
		norms.append_array(a[Mesh.ARRAY_NORMAL])
		if a[Mesh.ARRAY_TANGENT] != null:
			tans.append_array(a[Mesh.ARRAY_TANGENT])
		uvs.append_array(a[Mesh.ARRAY_TEX_UV])
		for i in (a[Mesh.ARRAY_INDEX] as PackedInt32Array):
			idx.append(base + i)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = verts
	out[Mesh.ARRAY_NORMAL] = norms
	if tans.size() == verts.size() * 4:
		out[Mesh.ARRAY_TANGENT] = tans
	out[Mesh.ARRAY_TEX_UV] = uvs
	out[Mesh.ARRAY_INDEX] = idx
	return out

## Simplify to roughly `budget` triangles using the engine's own LOD generator, then
## drop the vertices the chosen index buffer no longer references.
func _reduce(arrays: Array, budget: int) -> Array:
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if budget <= 0 or indices.size() / 3 <= budget:
		return arrays
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
	im.generate_lods(25.0, 60.0, [])
	var best: PackedInt32Array = indices
	var best_err := INF
	for k in range(im.get_surface_lod_count(0)):
		var li := im.get_surface_lod_indices(0, k)
		var err := absf(float(li.size() / 3 - budget))
		if err < best_err:
			best_err = err
			best = li
	var out := arrays.duplicate()
	out[Mesh.ARRAY_INDEX] = best
	return _compact(out)

## Rebuild the vertex arrays keeping only referenced vertices.
func _compact(arrays: Array) -> Array:
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var remap := {}
	var order := PackedInt32Array()
	var new_idx := PackedInt32Array()
	new_idx.resize(indices.size())
	for i in range(indices.size()):
		var v := indices[i]
		if not remap.has(v):
			remap[v] = order.size()
			order.append(v)
		new_idx[i] = remap[v]
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nv := PackedVector3Array(); nv.resize(order.size())
	for i in range(order.size()):
		nv[i] = verts[order[i]]
	out[Mesh.ARRAY_VERTEX] = nv
	if arrays[Mesh.ARRAY_NORMAL] != null:
		var src_n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var nn := PackedVector3Array(); nn.resize(order.size())
		for i in range(order.size()):
			nn[i] = src_n[order[i]]
		out[Mesh.ARRAY_NORMAL] = nn
	if arrays[Mesh.ARRAY_TANGENT] != null:
		var src_t: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		var nt := PackedFloat32Array(); nt.resize(order.size() * 4)
		for i in range(order.size()):
			for c in range(4):
				nt[i * 4 + c] = src_t[order[i] * 4 + c]
		out[Mesh.ARRAY_TANGENT] = nt
	if arrays[Mesh.ARRAY_TEX_UV] != null:
		var src_uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var nuv := PackedVector2Array(); nuv.resize(order.size())
		for i in range(order.size()):
			nuv[i] = src_uv[order[i]]
		out[Mesh.ARRAY_TEX_UV] = nuv
	out[Mesh.ARRAY_INDEX] = new_idx
	return out

func _transformed(arrays: Array, xf: Transform3D) -> Array:
	var out := arrays.duplicate()
	var verts: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	for i in range(verts.size()):
		verts[i] = xf * verts[i]
	out[Mesh.ARRAY_VERTEX] = verts
	if out[Mesh.ARRAY_NORMAL] != null:
		var norms: PackedVector3Array = out[Mesh.ARRAY_NORMAL]
		for i in range(norms.size()):
			norms[i] = (xf.basis * norms[i]).normalized()
		out[Mesh.ARRAY_NORMAL] = norms
	# keep only what the game's materials read; colours/uv2/bones would just bloat the file
	for k in [Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1,
			Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
		out[k] = null
	return out

## Centre on X/Z and sit the lowest point on y = 0, so a scatter transform's origin is
## the spot on the ground the prop stands on.
func _recentre(arrays: Array) -> Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for v in verts:
		lo = lo.min(v)
		hi = hi.max(v)
	var off := Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)
	for i in range(verts.size()):
		verts[i] -= off
	arrays[Mesh.ARRAY_VERTEX] = verts
	return arrays

func _save(arrays: Array, out_name: String) -> void:
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var path := OUT_DIR + out_name + ".res"
	var err := ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS)
	var tris: int = (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	print("[bake] %s  tris=%d  aabb=%s  err=%d" % [path, tris, str(mesh.get_aabb().size), err])

func _collect(node: Node, out: Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for c in node.get_children():
		_collect(c, out)

func _xform_to_root(node: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t
