extends Node3D
## A dense, tall, eerie pine forest that walls in the road. Real CC0 conifer GLB meshes
## (Quaternius, public domain) instanced via chunked MultiMesh for culling, packed in
## bands along every road so you can't see or drive through them. Invisible collision
## walls behind the front trunk row stop the car. Low ground scatter blocks sightlines.

const PINES := [
	{"path": "res://assets/trees/pine_quaternius_cc0.glb", "scale": 1.9},
	{"path": "res://assets/trees/pine_tall_quaternius_cc0.glb", "scale": 2.2},
]
const CELL := 70.0          # chunk size for per-cell MultiMesh culling

@export var road_width: float = 9.0
@export var xs: Array[float] = [-130.0, 0.0, 130.0]
@export var zs: Array[float] = [40.0, -90.0, -220.0, -350.0]
@export var border: float = 150.0

var _meshes: Array[Mesh] = []
var _rng := RandomNumberGenerator.new()
var _cells := {}            # Vector2i -> Array (one Array[Transform3D] per pine mesh)
var _bush := {"x": [], "wall": []}   # bush transforms; (wall reuses nothing)

func _ready() -> void:
	_rng.seed = 70707
	for p in PINES:
		var m := _load_pine(p.path)
		if m:
			_meshes.append(m)
	if _meshes.is_empty():
		_meshes.append(_fallback_pine())     # never leave the world bare
	_scatter_fill()
	_line_roads()
	_bake_cells()
	_build_floor()

# --- GLB loading -------------------------------------------------------------

func _load_pine(path: String) -> Mesh:
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
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
	_collect_mesh_instances(scene, mis)
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
			if mat is StandardMaterial3D:
				var sm: StandardMaterial3D = mat.duplicate()
				sm.roughness = 0.95
				sm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				mat = sm
			out.surface_set_material(out.get_surface_count() - 1, mat)
	scene.queue_free()
	return out if out.get_surface_count() > 0 else null

func _collect_mesh_instances(node: Node, out: Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for c in node.get_children():
		_collect_mesh_instances(c, out)

func _xform_to_root(node: Node3D, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t

func _fallback_pine() -> Mesh:
	# crude tall conifer if the GLBs are missing: trunk + stacked cones
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.18
	trunk.bottom_radius = 0.32
	trunk.height = 7.0
	st.append_from(trunk, 0, Transform3D(Basis.IDENTITY, Vector3(0, 3.5, 0)))
	var radii := [2.0, 1.5, 1.0, 0.5]
	var bases := [3.0, 6.0, 9.0, 11.5]
	for i in range(4):
		var c := CylinderMesh.new()
		c.top_radius = 0.0
		c.bottom_radius = radii[i]
		c.height = 4.0
		c.radial_segments = 7
		st.append_from(c, 0, Transform3D(Basis.IDENTITY, Vector3(0, bases[i] + 2.0, 0)))
	var m := st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.07, 0.12, 0.08)
	mat.roughness = 1.0
	m.surface_set_material(0, mat)
	return m

# --- placement ---------------------------------------------------------------

func _bucket(pos: Vector3, mesh_idx: int) -> void:
	var s: float = float(PINES[mesh_idx].scale) if mesh_idx < PINES.size() else 2.5
	s *= _rng.randf_range(0.8, 1.25)
	var b := Basis(Vector3.UP, _rng.randf() * TAU)
	# very slight lean for organic feel
	var lean := Vector3(_rng.randf() * 2.0 - 1.0, 0.0, _rng.randf() * 2.0 - 1.0).normalized()
	b = b.rotated(lean, deg_to_rad(_rng.randf_range(0.0, 3.0)))
	b = b.scaled(Vector3(s, s * _rng.randf_range(0.9, 1.25), s))
	var xform := Transform3D(b, pos)
	var key := Vector2i(int(floor(pos.x / CELL)), int(floor(pos.z / CELL)))
	if not _cells.has(key):
		var lists: Array = []
		for _i in range(_meshes.size()):
			lists.append([] as Array)
		_cells[key] = lists
	_cells[key][mesh_idx].append(xform)

func _add_pine(pos: Vector3) -> void:
	_bucket(pos, _rng.randi() % _meshes.size())

func _on_road(x: float, z: float, clearance: float) -> bool:
	for rz in zs:
		if abs(z - rz) < clearance and x > _amin(xs) - clearance and x < _amax(xs) + clearance:
			return true
	for rx in xs:
		if abs(x - rx) < clearance and z > _amin(zs) - clearance and z < _amax(zs) + clearance:
			return true
	return false

func _scatter_fill() -> void:
	# the bulk forest filling everything that isn't road
	var min_x: float = _amin(xs) - border
	var max_x: float = _amax(xs) + border
	var min_z: float = _amin(zs) - border
	var max_z: float = _amax(zs) + border
	var stepf := 9.5
	var x := min_x
	while x < max_x:
		var z := min_z
		while z < max_z:
			var px := x + _rng.randf_range(-3.0, 3.0)
			var pz := z + _rng.randf_range(-3.0, 3.0)
			z += stepf
			if _on_road(px, pz, road_width * 0.5 + 5.0):
				continue
			if _rng.randf() < 0.1:
				continue
			_add_pine(Vector3(px, 0, pz))
		x += stepf

func _line_roads() -> void:
	for z in zs:
		_line_leg(Vector3(_amin(xs), 0, z), Vector3(_amax(xs), 0, z))
	for x in xs:
		_line_leg(Vector3(x, 0, _amin(zs)), Vector3(x, 0, _amax(zs)))

func _line_leg(a: Vector3, b: Vector3) -> void:
	var length: float = a.distance_to(b)
	var dir: Vector3 = (b - a).normalized()
	var perp: Vector3 = dir.cross(Vector3.UP).normalized()
	# how close a tree may get to ANY road centerline before it's rejected (keeps
	# trunks off this road AND off crossing roads at intersections)
	var guard: float = road_width * 0.5 + 1.5
	var inset := road_width
	var d := inset
	while d < length - inset:
		var p: Vector3 = a + dir * d
		for side: float in [-1.0, 1.0]:
			for off: float in [3.5, 6.0]:
				var jp: Vector3 = p + perp * (road_width * 0.5 + off) * side
				jp += dir * _rng.randf_range(-1.0, 1.0)
				if not _on_road(jp.x, jp.z, guard):
					_add_pine(Vector3(jp.x, 0, jp.z))
			# ground-level bush at the front to block sightlines under trunks
			var bp: Vector3 = p + perp * (road_width * 0.5 + 2.5) * side
			if _rng.randf() < 0.5 and not _on_road(bp.x, bp.z, guard):
				_bush.x.append(bp)
		d += 2.4
	# invisible collision walls behind the front row — built in short segments so
	# they can break at intersections (no wall across a crossing road)
	for side: float in [-1.0, 1.0]:
		var seg := inset
		while seg < length - inset - 8.0:
			var s0: Vector3 = a + dir * seg
			var s1: Vector3 = a + dir * (seg + 9.0)
			var midp: Vector3 = (s0 + s1) * 0.5 + perp * (road_width * 0.5 + 3.5) * side
			if not _on_road(midp.x, midp.z, road_width * 0.5 + 4.0):
				_make_wall(s0, s1, perp * side, road_width * 0.5 + 3.5)
			seg += 9.0

func _make_wall(a: Vector3, b: Vector3, side: Vector3, offset: float) -> void:
	var length: float = a.distance_to(b)
	if length < 4.0:
		return
	var mid: Vector3 = (a + b) * 0.5 + side * offset
	var dir: Vector3 = (b - a).normalized()
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(length, 22.0, 1.0)
	cs.shape = box
	body.add_child(cs)
	var basis := Basis()
	basis.x = dir
	basis.y = Vector3.UP
	basis.z = dir.cross(Vector3.UP).normalized()
	body.transform = Transform3D(basis, mid + Vector3(0, 11.0, 0))
	add_child(body)

# --- bake --------------------------------------------------------------------

func _bake_cells() -> void:
	for key in _cells.keys():
		var lists: Array = _cells[key]
		for mi in range(lists.size()):
			var xforms: Array = lists[mi]
			if xforms.is_empty():
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = _meshes[mi]
			mm.instance_count = xforms.size()
			for i in range(xforms.size()):
				mm.set_instance_transform(i, xforms[i])
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			add_child(mmi)

func _build_floor() -> void:
	if _bush.x.is_empty():
		return
	var bush := SphereMesh.new()
	bush.radius = 0.9
	bush.height = 1.3
	bush.radial_segments = 6
	bush.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.10, 0.14, 0.09)
	mat.roughness = 1.0
	bush.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = bush
	mm.instance_count = _bush.x.size()
	for i in range(_bush.x.size()):
		var s := _rng.randf_range(0.8, 1.8)
		var b := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(s, s * 0.7, s))
		mm.set_instance_transform(i, Transform3D(b, _bush.x[i] + Vector3(0, 0.4, 0)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

# --- helpers -----------------------------------------------------------------

func _amin(arr: Array[float]) -> float:
	var v: float = arr[0]
	for x in arr:
		v = min(v, x)
	return v

func _amax(arr: Array[float]) -> float:
	var v: float = arr[0]
	for x in arr:
		v = max(v, x)
	return v
