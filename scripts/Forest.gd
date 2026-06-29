extends Node3D
## Dense, tall, eerie pine forest lining the curved RoadCourse. Real CC0 conifer GLBs
## (Quaternius, public domain) instanced via chunked MultiMesh, planted in several rows
## down both sides of the road curve (following its hills), with continuous invisible
## collision walls so you can't drive into the woods.

const PINES := [
	{"path": "res://assets/trees/pine_quaternius_cc0.glb", "scale": 1.7},
	{"path": "res://assets/trees/pine_tall_quaternius_cc0.glb", "scale": 2.0},
]
const GlbUtil := preload("res://scripts/GlbUtil.gd")
const CELL := 70.0
const ROCK_GLB := "res://assets/rocks/rock_quaternius_large_cc0.glb"
const ROCK_SCALE := 0.3   ## the mesh is ~7.7m wide natively, so this gives ~1.5-3.5m boulders

@export var course_curve: Curve3D
@export var road_width: float = 9.0

var _meshes: Array[Mesh] = []
var _rng := RandomNumberGenerator.new()
var _cells := {}
var _bush_x: Array[Transform3D] = []
var _rock_x: Array[Transform3D] = []

# tree rows by distance from the road centerline (each side), with spawn chance
const WALL_OFF := 22.0   ## collision wall distance from centerline (just outside the drivable corridor)
const ROWS := [
	{"dist": 25.0, "chance": 0.9},
	{"dist": 31.0, "chance": 0.8},
	{"dist": 39.0, "chance": 0.7},
	{"dist": 49.0, "chance": 0.55},
	{"dist": 62.0, "chance": 0.4},
	{"dist": 78.0, "chance": 0.28},
]

func _ready() -> void:
	_rng.seed = 70707
	for p in PINES:
		var m := _load_pine(p.path)
		if m:
			_meshes.append(m)
	if _meshes.is_empty():
		_meshes.append(_fallback_pine())
	if course_curve:
		_line_curve()
	_bake_cells()
	_build_floor()
	_build_rocks()

# --- placement along the curve -----------------------------------------------

func _line_curve() -> void:
	var length := course_curve.get_baked_length()
	var d := 0.0
	while d < length:
		var xf := course_curve.sample_baked_with_rotation(d, true, true)
		# horizontal frame so trees/walls sit level on slopes (no vertical swing)
		var fwd := xf.basis.z
		var fwd_h := Vector3(fwd.x, 0.0, fwd.z).normalized()
		var right_h := Vector3(fwd_h.z, 0.0, -fwd_h.x)
		var base := Vector3(xf.origin.x, xf.origin.y - 0.6, xf.origin.z)
		for side: float in [-1.0, 1.0]:
			for row in ROWS:
				if _rng.randf() > float(row.chance):
					continue
				var off: float = float(row.dist) + _rng.randf_range(-2.0, 2.0)
				var along: float = _rng.randf_range(-1.5, 1.5)
				var pos: Vector3 = base + right_h * (off * side) + fwd_h * along
				_add_pine(pos)
			# front bush just past the collision wall
			if _rng.randf() < 0.4:
				_bush_x.append(Transform3D(_bush_basis(), base + right_h * ((WALL_OFF + 1.5) * side)))
			# occasional roadside boulder
			if _rng.randf() < 0.06:
				var rs: float = ROCK_SCALE * _rng.randf_range(0.6, 1.5)
				var rb := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(rs, rs * _rng.randf_range(0.7, 1.1), rs))
				_rock_x.append(Transform3D(rb, base + right_h * (_rng.randf_range(WALL_OFF + 1.0, WALL_OFF + 9.0) * side)))
		# collision wall rings (built into a ribbon after the loop)
		_wall_l.append(base + right_h * -WALL_OFF)
		_wall_r.append(base + right_h * WALL_OFF)
		d += 3.5
	_build_wall(_wall_l)
	_build_wall(_wall_r)

var _wall_l: Array[Vector3] = []
var _wall_r: Array[Vector3] = []

func _bush_basis() -> Basis:
	var s := _rng.randf_range(0.8, 1.8)
	return Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(s, s * 0.7, s))

func _bucket(pos: Vector3, mesh_idx: int) -> void:
	var s: float = float(PINES[mesh_idx].scale) if mesh_idx < PINES.size() else 2.0
	s *= _rng.randf_range(0.8, 1.25)
	var b := Basis(Vector3.UP, _rng.randf() * TAU)
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

# --- collision wall ribbon (vertical, follows the curve) ---------------------

func _build_wall(pts: Array[Vector3]) -> void:
	if pts.size() < 2:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in pts:
		st.add_vertex(p + Vector3(0, -1.0, 0))
		st.add_vertex(p + Vector3(0, 22.0, 0))
	for r in range(pts.size() - 1):
		var a := r * 2
		var b := r * 2 + 1
		var c := (r + 1) * 2
		var dvv := (r + 1) * 2 + 1
		st.add_index(a); st.add_index(c); st.add_index(b)
		st.add_index(b); st.add_index(c); st.add_index(dvv)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.visible = false
	add_child(mi)
	mi.create_trimesh_collision()

# --- GLB loading -------------------------------------------------------------

func _load_pine(path: String) -> Mesh:
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
	if _bush_x.is_empty():
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
	mm.instance_count = _bush_x.size()
	for i in range(_bush_x.size()):
		mm.set_instance_transform(i, _bush_x[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

func _build_rocks() -> void:
	if _rock_x.is_empty():
		return
	var rock_mesh := GlbUtil.load_mesh(ROCK_GLB)
	if rock_mesh == null:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = rock_mesh
	mm.instance_count = _rock_x.size()
	for i in range(_rock_x.size()):
		mm.set_instance_transform(i, _rock_x[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
