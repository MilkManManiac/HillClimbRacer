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

## The realistic sports car: Khronos "Car Concept" (Eric Chadwick / Darmstadt Graphics
## Group, CC-BY 4.0 — see CREDITS.md). ~213k triangles, wheels as separate named nodes.
const CONCEPT_GLTF := "res://assets/car/concept/CarConcept.gltf"
const CONCEPT_WHEELS := ["WheelFrontL", "WheelFrontR", "WheelRearL", "WheelRearR"]   # game wheel order
static var _concept_packed: PackedScene
static var _concept_tried := false

## A fresh instance of the concept car, or null if the files are missing. The glTF is
## parsed once per process and kept as an in-memory PackedScene, so respawning the car
## (vehicle swap, map change) never re-reads 11 MB of model.
static func concept_instance() -> Node3D:
	if not _concept_tried:
		_concept_tried = true
		const GlbUtil := preload("res://scripts/GlbUtil.gd")
		var scene: Node3D = GlbUtil.load_scene(CONCEPT_GLTF)
		if scene != null:
			_tune_concept_materials(scene)
			_set_owner(scene, scene)
			var ps := PackedScene.new()
			if ps.pack(scene) == OK:
				_concept_packed = ps
			scene.free()
	if _concept_packed == null:
		return null
	return _concept_packed.instantiate() as Node3D

static func _set_owner(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_set_owner(c, owner)

## Godot's glTF loader ignores the clearcoat / transmission extensions this model
## leans on, so as imported the paint is flat and the glass is solid white. Rebuild
## those by material name. Also drops the Khronos logo from the plate (the logo is a
## trademark, not part of the CC-BY grant).
static func _tune_concept_materials(root: Node3D) -> void:
	var meshes: Array = []
	_collect_meshes(root, meshes)
	var seen := {}
	for mi in meshes:
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for si in range(mesh.get_surface_count()):
			var m := mesh.surface_get_material(si) as BaseMaterial3D
			if m == null or seen.has(m):
				continue
			seen[m] = true
			_mip_material(m)
			var nm := String(m.resource_name)
			if nm == "Glass":
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				m.albedo_color = Color(0.03, 0.04, 0.05, 0.62)
				m.roughness = 0.04
				m.metallic = 0.0
				m.metallic_specular = 0.8
				m.cull_mode = BaseMaterial3D.CULL_BACK
			elif nm.begins_with("Paint 1"):
				m.albedo_color = CONCEPT_PAINT
				m.metallic = 0.65
				m.roughness = 0.3
				m.clearcoat_enabled = true
				m.clearcoat = 1.0
				m.clearcoat_roughness = 0.04
				m.cull_mode = BaseMaterial3D.CULL_BACK
				# the model's metal-flake normal map and baked occlusion come through the
				# loader at the wrong tiling and mottle the panels; smooth paint reads better
				m.normal_enabled = false
				m.ao_enabled = false
			elif nm.begins_with("Paint 2"):
				m.albedo_color = Color(0.03, 0.03, 0.035)
				m.metallic = 0.4
				m.roughness = 0.28
				m.clearcoat_enabled = true
				m.clearcoat = 0.8
				m.clearcoat_roughness = 0.1
				m.normal_enabled = false
				m.ao_enabled = false
			elif nm == "License":
				m.albedo_texture = null
				m.albedo_color = Color(0.06, 0.06, 0.07)
			elif nm.begins_with("Tire"):
				# plain matte rubber: the tread/sidewall normal maps sparkle like static
				# under a low sun at chase-camera distance
				m.normal_enabled = false
				m.roughness = 0.92
				m.metallic = 0.0
			elif nm == "Rim2":
				# as shipped this is a perfect mirror, and the only thing a wheel in the
				# arch's shade has to reflect is the sky photo's dark lower half — the
				# spokes went solid black. Mostly-diffuse painted alloy stays silver.
				m.albedo_color = Color(0.70, 0.71, 0.73)
				m.metallic = 0.35
				m.roughness = 0.45
			elif nm == "Brakelight":
				m.emission_energy_multiplier = CONCEPT_TAIL_IDLE
			elif nm.begins_with("Interior 3"):
				m.albedo_color = Color(0.12, 0.10, 0.09)   # the stock seats are bright red

# Electric blue: the complement of the canyon's red rock, so the car is the one thing on
# screen that colour — it reads at a glance from the chase camera. (Rendered side by
# side against white, yellow and red before choosing; red vanished into the cliffs.)
const CONCEPT_PAINT := Color(0.04, 0.16, 0.55)

## Rebuild a material's textures with mip-maps (the runtime glTF loader creates them
## without, so fine patterns — tyre tread, drilled discs — alias into crawling noise).
static func _mip_material(m: BaseMaterial3D) -> void:
	for prop in ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture", "ao_texture", "emission_texture"]:
		var t := m.get(prop) as Texture2D
		if t == null:
			continue
		if not _mipped.has(t):
			var img := t.get_image()
			if img == null or img.is_empty():
				_mipped[t] = t
			else:
				if img.is_compressed():
					img.decompress()
				img.generate_mipmaps(prop == "normal_texture")
				_mipped[t] = ImageTexture.create_from_image(img)
		m.set(prop, _mipped[t])
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

static var _mipped := {}
const CONCEPT_TAIL_IDLE := 0.8
const CONCEPT_TAIL_BRAKE := 7.0

## The concept car as a ghost: every surface swapped for `mat` (one translucent
## material, so a tint change is one assignment), interior stripped (it would show
## through the shell as clutter), wheels straightened, and the same scale / facing /
## ride height the driven car uses, so a ghost replaying a recorded car transform sits
## exactly where that car was. `half_wheelbase` and `ground_y` come from the vehicle's
## physics stance. Null if the model is unavailable.
static func concept_ghost(mat: Material, half_wheelbase: float, ground_y: float) -> Node3D:
	var model := concept_instance()
	if model == null:
		return null
	var front := model.find_child(CONCEPT_WHEELS[0], true, false) as Node3D
	var rear := model.find_child(CONCEPT_WHEELS[2], true, false) as Node3D
	if front == null or rear == null:
		model.free()
		return null
	var fz: float = _xform_to_root(front, model).origin.z
	var rz: float = _xform_to_root(rear, model).origin.z
	var k: float = (2.0 * half_wheelbase) / maxf(absf(fz - rz), 0.5)
	for nm in CONCEPT_WHEELS:
		var w := model.find_child(nm, true, false) as Node3D
		if w:
			w.transform = Transform3D(Basis.IDENTITY, w.transform.origin)   # drop the baked steer/spin pose
	var meshes: Array = []
	_collect_meshes(model, meshes)
	for mi in meshes:
		var m3 := mi as MeshInstance3D
		var nm := String(m3.name)
		if nm.begins_with("Interior") or nm == "Engine":
			m3.visible = false
			continue
		m3.material_override = mat
		m3.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	model.position = Vector3(0.0, 0.0, -(fz + rz) * 0.5)
	var wrapper := Node3D.new()
	wrapper.add_child(model)
	wrapper.scale = Vector3(k, k, k)
	wrapper.rotation.y = PI
	wrapper.position = Vector3(0.0, ground_y, 0.0)
	return wrapper

## The tail-light material of a concept instance (shared by its meshes), so the car can
## brighten it under braking. Null if not found.
static func concept_tail_material(root: Node3D) -> BaseMaterial3D:
	var meshes: Array = []
	_collect_meshes(root, meshes)
	for mi in meshes:
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for si in range(mesh.get_surface_count()):
			var m := mesh.surface_get_material(si) as BaseMaterial3D
			if m != null and String(m.resource_name) == "Brakelight":
				return m
	return null

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
