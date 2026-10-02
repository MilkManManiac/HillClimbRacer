extends Node3D
## Real terrain around the road for the realistic maps. HCTrack only meshes a ribbon a
## few dozen metres either side of the centre-line; this node fills in everything else,
## so the road runs along the floor of an actual canyon instead of a strip floating in
## front of painted backdrop rings.
##
## Purely visual: no collision, nothing the car or camera queries. The car still rides
## HCTrack's analytic ground.
##
## Shape: the land's height is a function of DISTANCE TO THE NEAREST ROAD. Under and
## beside the ribbon it hugs the road's own surface (tucked just beneath it); past the
## verge it stays a flat sandy floor for a stretch, then climbs into stepped sandstone
## walls whose height and set-back wander with slow noise. Far from any road it is a
## plateau of mesas. Because the walls key off the road, they never block it.
##
## Two grids streamed around the car: fine chunks close in, coarse chunks out to the
## horizon. The coarse mesh is cut out (in the shader) where the fine one covers it.
## Heights are computed on worker threads; only the mesh upload happens on the main one.

const HCLook := preload("res://scripts/hc/HCLook.gd")

const NEAR_SIZE := 128.0      # fine chunk edge (m)
const NEAR_CELLS := 16        # 8 m cells
const NEAR_RADIUS := 3        # chunks each way -> a 7x7 window, ~450 m out
const FAR_SIZE := 640.0       # coarse chunk edge (m)
const FAR_CELLS := 16         # 40 m cells
const FAR_RADIUS := 4         # 9x9 window, ~2.9 km out
const REACH := 190.0          # how far from a road sample the road still shapes the land
const FAR_DROP := 1.5         # coarse mesh sits this far below, so the fine one wins overlaps
const MAX_TASKS := 6
const PROP_TRIES := 46        # random spots tried per fine chunk for a boulder / bush
# baked mesh, texture folder, [min, max] scale
const BOULDERS := [
	["boulder_03", "namaqualand_boulder_03"], ["boulder_04", "namaqualand_boulder_04"],
	["boulder_05", "namaqualand_boulder_05"], ["boulder_06", "namaqualand_boulder_06"],
]
const BUSHES := ["bush_c", "bush_d", "bush_e"]   # the lighter ones: there are hundreds on screen
const UPLOADS_PER_FRAME := 4

var _track: Node
var _look := ""
var _target: Node3D
var _px := PackedFloat32Array()
var _pz := PackedFloat32Array()
var _eh := PackedFloat32Array()   # per road sample: ground height at the ribbon's outer edge
var _grid := {}
var _cell := 24.0
var _half := 44.0                 # ribbon half-width (where this mesh takes over)

var _n_open := FastNoiseLite.new()    # slow: tall-walled stretches vs open country
var _n_warp := FastNoiseLite.new()    # how far back the wall foot sits
var _n_relief := FastNoiseLite.new()  # mesa-top relief + side gullies
var _n_dune := FastNoiseLite.new()    # ripples on the floor

var _chunks := {}        # Vector3i(kind, cx, cz) -> MeshInstance3D
var _pending := {}       # Vector3i -> WorkerThreadPool task id
var _done: Array = []    # finished jobs awaiting upload (guarded by _mutex)
var _mutex := Mutex.new()
var _near_mat: ShaderMaterial
var _far_mat: ShaderMaterial
var _cut_c := Vector2i(1 << 30, 0)   # chunk the committed fine window is centred on
var _have_cut := false

func setup(track: Node, look: String) -> void:
	_track = track
	_look = look
	var d: Dictionary = track.call("land_data")
	_px = d.px
	_pz = d.pz
	_eh = d.eh
	_grid = d.grid
	_cell = float(d.cell)
	_half = float(d.half)
	var seed_base: int = int(d.seed)
	for pair in [[_n_open, 0.0011, 11], [_n_warp, 0.0075, 23], [_n_relief, 0.0042, 37], [_n_dune, 0.021, 51]]:
		var n: FastNoiseLite = pair[0]
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = 3
		n.frequency = float(pair[1])
		n.seed = seed_base + int(pair[2])
	_near_mat = HCLook.ground_material(look, false)
	_far_mat = HCLook.far_land_material(look)
	_far_mat.set_shader_parameter("cut_rect", Vector4(0, 0, 0, 0))
	process_mode = Node.PROCESS_MODE_ALWAYS   # keep streaming behind the paused title screen

func set_target(t: Node3D) -> void:
	_target = t

## True once the fine window around the car is fully built (screenshot harnesses wait
## on this so they never capture a half-streamed landscape).
func is_settled() -> bool:
	return _have_cut and _pending.is_empty()

func _exit_tree() -> void:
	for key in _pending:
		WorkerThreadPool.wait_for_task_completion(int(_pending[key]))
	_pending.clear()

func _process(_delta: float) -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var pos := _target.global_position
	var nc := Vector2i(int(floor(pos.x / NEAR_SIZE)), int(floor(pos.z / NEAR_SIZE)))
	var fc := Vector2i(int(floor(pos.x / FAR_SIZE)), int(floor(pos.z / FAR_SIZE)))
	var want := {}
	var order: Array = []   # [dist2, key] so the closest chunks build first
	for dz in range(-NEAR_RADIUS, NEAR_RADIUS + 1):
		for dx in range(-NEAR_RADIUS, NEAR_RADIUS + 1):
			var key := Vector3i(0, nc.x + dx, nc.y + dz)
			want[key] = true
			order.append([dx * dx + dz * dz, key])
			if _have_cut:
				# hold the previous fine window until the new one is complete, or the
				# coarse mesh (still cut out there) would show a hole
				want[Vector3i(0, _cut_c.x + dx, _cut_c.y + dz)] = true
	for dz in range(-FAR_RADIUS, FAR_RADIUS + 1):
		for dx in range(-FAR_RADIUS, FAR_RADIUS + 1):
			var key := Vector3i(1, fc.x + dx, fc.y + dz)
			want[key] = true
			order.append([1000 + dx * dx + dz * dz, key])
	for key in _chunks.keys():
		if not want.has(key):
			_chunks[key].queue_free()
			_chunks.erase(key)
	order.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
	for o in order:
		if _pending.size() >= MAX_TASKS:
			break
		var key: Vector3i = o[1]
		if _chunks.has(key) or _pending.has(key):
			continue
		_pending[key] = WorkerThreadPool.add_task(_job.bind(key))
	_upload()
	# commit the fine window (and move the coarse cut-out) once it is whole
	if not _have_cut or _cut_c != nc:
		var whole := true
		for dz in range(-NEAR_RADIUS, NEAR_RADIUS + 1):
			for dx in range(-NEAR_RADIUS, NEAR_RADIUS + 1):
				if not _chunks.has(Vector3i(0, nc.x + dx, nc.y + dz)):
					whole = false
					break
			if not whole:
				break
		if whole:
			_cut_c = nc
			_have_cut = true
			var half := (float(NEAR_RADIUS) + 0.5) * NEAR_SIZE
			var cx := (float(nc.x) + 0.5) * NEAR_SIZE
			var cz := (float(nc.y) + 0.5) * NEAR_SIZE
			_far_mat.set_shader_parameter("cut_rect", Vector4(cx, cz, half - 12.0, 1.0))

func _upload() -> void:
	var batch: Array = []
	_mutex.lock()
	while not _done.is_empty() and batch.size() < UPLOADS_PER_FRAME:
		batch.append(_done.pop_front())
	_mutex.unlock()
	for r in batch:
		var key: Vector3i = r.key
		if _pending.has(key):
			WorkerThreadPool.wait_for_task_completion(int(_pending[key]))
			_pending.erase(key)
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, r.arrays)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _near_mat if key.x == 0 else _far_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mi)
		_add_props(mi, r.get("props", {}))
		if _chunks.has(key):
			_chunks[key].queue_free()
		_chunks[key] = mi

## Boulders, scrub and rock outcrops for a fine chunk, as MultiMeshes parented to the
## chunk (so they stream out with it). `props` maps "mesh|texture folder" -> transforms.
func _add_props(chunk: MeshInstance3D, props: Dictionary) -> void:
	for key in props:
		var xforms: Array = props[key]
		if xforms.is_empty():
			continue
		var parts: PackedStringArray = String(key).split("|")
		var mesh := HCLook.prop_mesh(parts[0], parts[1])
		if mesh == null:
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = xforms.size()
		for i in range(xforms.size()):
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		if parts[0].begins_with("bush"):
			mmi.visibility_range_end = 190.0
			mmi.visibility_range_end_margin = 30.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		chunk.add_child(mmi)

# --- worker side (no scene access below this line) --------------------------------

func _job(key: Vector3i) -> void:
	var fine := key.x == 0
	var size := NEAR_SIZE if fine else FAR_SIZE
	var cells := NEAR_CELLS if fine else FAR_CELLS
	var step := size / float(cells)
	var x0 := float(key.y) * size
	var z0 := float(key.z) * size
	var cands := _gather(x0 - step - REACH, z0 - step - REACH, x0 + size + step + REACH, z0 + size + step + REACH, 1 if fine else 3)
	# heights on a grid one cell wider than the chunk all round, so edge normals come
	# from the same central difference as interior ones and neighbours shade seamlessly
	var n := cells + 3
	var hh := PackedFloat32Array()
	hh.resize(n * n)
	for iz in range(n):
		var z := z0 + float(iz - 1) * step
		for ix in range(n):
			hh[iz * n + ix] = _height(x0 + float(ix - 1) * step, z, cands, fine)
	var drop := 0.0 if fine else FAR_DROP
	var vn := cells + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	verts.resize(vn * vn)
	norms.resize(vn * vn)
	for iz in range(vn):
		for ix in range(vn):
			var c := (iz + 1) * n + (ix + 1)
			verts[iz * vn + ix] = Vector3(x0 + float(ix) * step, hh[c] - drop, z0 + float(iz) * step)
			norms[iz * vn + ix] = Vector3(hh[c - 1] - hh[c + 1], 2.0 * step, hh[c - n] - hh[c + n]).normalized()
	for iz in range(cells):
		for ix in range(cells):
			var a := iz * vn + ix
			# split along whichever diagonal is flatter: a fixed diagonal turns every
			# slope that runs the other way into a row of sawteeth
			if absf(verts[a].y - verts[a + vn + 1].y) <= absf(verts[a + 1].y - verts[a + vn].y):
				idx.append(a); idx.append(a + 1); idx.append(a + vn + 1)
				idx.append(a); idx.append(a + vn + 1); idx.append(a + vn)
			else:
				idx.append(a); idx.append(a + 1); idx.append(a + vn)
				idx.append(a + 1); idx.append(a + vn + 1); idx.append(a + vn)
	if fine:
		_skirt(verts, norms, idx, vn, 7.0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var props := _scatter(key, x0, z0, size, cands) if fine else {}
	_mutex.lock()
	_done.append({"key": key, "arrays": arrays, "props": props})
	_mutex.unlock()

## Where the loose rock and scrub go in a fine chunk. Seeded by the chunk's own
## coordinates, so a chunk always grows the same things. Three zones by distance from
## the road: nothing on or right beside the ribbon (HCTrack dresses its own verge),
## scrub and small boulders across the open floor, big fallen blocks and the odd
## outcrop where the wall foot begins.
func _scatter(key: Vector3i, x0: float, z0: float, size: float, cands: PackedInt32Array) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(key.y, key.z, 7717))
	var out := {}
	for _i in range(PROP_TRIES):
		var x := x0 + rng.randf() * size
		var z := z0 + rng.randf() * size
		var d := _road_dist(x, z, cands)
		if d < _half + 2.5:
			continue
		var foot := _foot(x, z)
		var roll := rng.randf()
		var kind := ""
		var s := 1.0
		if d < foot - 6.0:
			if roll < 0.55:
				kind = BUSHES[rng.randi() % BUSHES.size()] + "|wild_rooibos_bush"
				s = rng.randf_range(1.6, 3.6)
			elif roll < 0.80:
				var b: Array = BOULDERS[rng.randi() % BOULDERS.size()]
				kind = "%s|%s" % [b[0], b[1]]
				s = rng.randf_range(0.5, 1.6)
		elif d < foot + 9.0:
			# fallen blocks gather where the wall starts — but only at its very foot:
			# any higher and they would sit on a face too steep to hold them
			if roll < 0.7:
				var b2: Array = BOULDERS[rng.randi() % 2]   # the two blocky ones
				kind = "%s|%s" % [b2[0], b2[1]]
				s = rng.randf_range(1.4, 3.8)
		if kind == "":
			continue
		var y := _height(x, z, cands, true)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		if not out.has(kind):
			out[kind] = []
		out[kind].append(Transform3D(basis, Vector3(x, y - 0.2 * s, z)))
	return out

## Distance from (x,z) to the nearest road sample (REACH if none is that close).
func _road_dist(x: float, z: float, cands: PackedInt32Array) -> float:
	var dmin2 := REACH * REACH
	for j in cands:
		var dx: float = _px[j] - x
		var dz: float = _pz[j] - z
		var d2 := dx * dx + dz * dz
		if d2 < dmin2:
			dmin2 = d2
	return sqrt(dmin2)

## How far from the road the canyon wall starts climbing here.
func _foot(x: float, z: float) -> float:
	var warp := _n_warp.get_noise_2d(x, z)
	var relief := 0.5 + 0.5 * _n_relief.get_noise_2d(x, z)
	return _half + 8.0 + 30.0 * (0.5 + 0.5 * warp) + 16.0 * relief

## Hang a short curtain off the chunk's four edges: hides the hairline cracks where a
## fine chunk meets the coarser mesh beyond the window.
func _skirt(verts: PackedVector3Array, norms: PackedVector3Array, idx: PackedInt32Array, vn: int, depth: float) -> void:
	var edges: Array = []
	var top: Array = []; var bottom: Array = []; var left: Array = []; var right: Array = []
	for i in range(vn):
		top.append(i)
		bottom.append((vn - 1) * vn + (vn - 1 - i))
		right.append(i * vn + (vn - 1))
		left.append((vn - 1 - i) * vn)
	edges = [top, right, bottom, left]
	for e in edges:
		var base := verts.size()
		for v in e:
			verts.append(verts[v] - Vector3(0, depth, 0))
			norms.append(norms[v])
		for i in range(e.size() - 1):
			var a: int = e[i]
			var b: int = e[i + 1]
			var c: int = base + i
			var d: int = base + i + 1
			# both windings: the curtain is seen from either side depending on which
			# way the neighbouring mesh is lower
			idx.append(a); idx.append(c); idx.append(b)
			idx.append(b); idx.append(c); idx.append(d)
			idx.append(a); idx.append(b); idx.append(c)
			idx.append(b); idx.append(d); idx.append(c)

## Road samples whose influence can reach the rectangle (every `stride`-th one).
func _gather(xmin: float, zmin: float, xmax: float, zmax: float, stride: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var gx0 := int(floor(xmin / _cell)); var gx1 := int(floor(xmax / _cell))
	var gz0 := int(floor(zmin / _cell)); var gz1 := int(floor(zmax / _cell))
	for gz in range(gz0, gz1 + 1):
		for gx in range(gx0, gx1 + 1):
			var key := Vector2i(gx, gz)
			if _grid.has(key):
				for j in _grid[key]:
					if j % stride == 0:
						out.append(j)
	return out

func _height(x: float, z: float, cands: PackedInt32Array, fine: bool) -> float:
	var dmin2 := INF
	var imin := -1
	var wsum := 0.0
	var hsum := 0.0
	var reach2 := REACH * REACH
	for j in cands:
		var dx: float = _px[j] - x
		var dz: float = _pz[j] - z
		var d2 := dx * dx + dz * dz
		if d2 < reach2:
			if d2 < dmin2:
				dmin2 = d2
				imin = j
			var w := 1.0 / (d2 * d2 + 1.0)
			wsum += w
			hsum += w * _eh[j]
	var d := REACH
	var floor_h := 0.0
	if imin >= 0:
		d = sqrt(dmin2)
		floor_h = hsum / wsum
	var h := floor_h + _wild(x, z, d)
	# under and beside the ribbon: ride just beneath the road's own surface
	if fine and imin >= 0 and d < _half + 2.0:
		var rib: float = _track.call("land_ribbon_h", imin, x, z)
		h = lerpf(rib - 0.8, h, smoothstep(_half - 6.0, _half + 2.0, d))
	return h

## Everything that is not road: canyon walls keyed to distance-from-road `d`, mesa
## relief on top, soft ripples on the floor.
func _wild(x: float, z: float, d: float) -> float:
	var open := _n_open.get_noise_2d(x, z)
	var rim := lerpf(14.0, 96.0, smoothstep(-0.28, 0.28, open))
	var warp := _n_warp.get_noise_2d(x, z)
	var relief := 0.5 + 0.5 * _n_relief.get_noise_2d(x, z)
	# the wall foot wanders in and out (alcoves, buttresses) so the canyon is never a
	# constant-width trench following the road
	var foot := _foot(x, z)
	var t := smoothstep(foot, foot + 62.0, d)
	var h := t * (rim * (0.74 + 0.26 * relief) + 18.0 * relief)
	# ledge heights drift with the relief noise, so a layer is not one flat contour
	h = _terrace(h + 5.0 * warp * t, 17.0)
	# talus: loose slope piled at the wall foot softens the first step
	h += 4.0 * smoothstep(foot - 16.0, foot + 8.0, d) * (1.0 - t)
	h += 0.9 * _n_dune.get_noise_2d(x, z) * smoothstep(_half, _half + 22.0, d) * (1.0 - t * 0.7)
	return h

## Flatten a height into ledges with steep risers between them — hard sandstone
## layers standing proud of the softer ones.
func _terrace(h: float, step: float) -> float:
	var t := h / step
	var f := floorf(t)
	var r := t - f
	return (f + 0.10 * r + 0.90 * smoothstep(0.34, 0.66, r)) * step
