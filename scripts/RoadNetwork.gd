extends Node3D
## The drivable winter road network: snowy ground collider, a grid of asphalt roads
## (procedural asphalt shader) with worn/faded lane lines, plowed snow banks, reflective
## marker stakes, road signs, and a few tire-mark decals. Forest/terrain live elsewhere.

const ASPHALT_SHADER := preload("res://shaders/asphalt.gdshader")
const ROADLINE_SHADER := preload("res://shaders/roadline.gdshader")

@export var road_width: float = 9.0
@export var xs: Array[float] = [-130.0, 0.0, 130.0]
@export var zs: Array[float] = [40.0, -90.0, -220.0, -350.0]

var _asphalt: ShaderMaterial
var _yellow: ShaderMaterial
var _white: ShaderMaterial
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.seed = 51
	_asphalt = ShaderMaterial.new()
	_asphalt.shader = ASPHALT_SHADER
	_yellow = ShaderMaterial.new()
	_yellow.shader = ROADLINE_SHADER
	_yellow.set_shader_parameter("paint_color", Color(0.82, 0.70, 0.20))
	_yellow.set_shader_parameter("wear", 0.45)
	_white = ShaderMaterial.new()
	_white.shader = ROADLINE_SHADER
	_white.set_shader_parameter("paint_color", Color(0.78, 0.80, 0.82))
	_white.set_shader_parameter("wear", 0.5)
	_build_ground()
	_build_grid()
	_build_signs()

# --- ground ------------------------------------------------------------------

func _build_ground() -> void:
	var min_x: float = _amin(xs) - 220.0
	var max_x: float = _amax(xs) + 220.0
	var min_z: float = _amin(zs) - 220.0
	var max_z: float = _amax(zs) + 220.0
	var size_x := max_x - min_x
	var size_z := max_z - min_z
	var mid := Vector3((min_x + max_x) * 0.5, 0.0, (min_z + max_z) * 0.5)

	var ground := MeshInstance3D.new()
	var gp := PlaneMesh.new()
	gp.size = Vector2(size_x, size_z)
	gp.subdivide_width = 8
	gp.subdivide_depth = 8
	ground.mesh = gp
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.86, 0.88, 0.93)
	gmat.roughness = 0.9
	ground.material_override = gmat
	ground.position = mid
	add_child(ground)

	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size_x, 2.0, size_z)
	col.shape = box
	col.position = mid + Vector3(0, -1.0, 0)
	body.add_child(col)
	add_child(body)

# --- road grid ---------------------------------------------------------------

func _build_grid() -> void:
	for z in zs:
		_build_road_leg(Vector3(_amin(xs), 0, z), Vector3(_amax(xs), 0, z))
	for x in xs:
		_build_road_leg(Vector3(x, 0, _amin(zs)), Vector3(x, 0, _amax(zs)))
	for x in xs:
		for z in zs:
			_build_intersection(Vector3(x, 0, z))

func _road_quad(size: Vector2, mat: Material, pos: Vector3, yaw: float) -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	mi.material_override = mat
	mi.position = pos
	mi.rotation.y = yaw
	add_child(mi)

func _build_road_leg(a: Vector3, b: Vector3) -> void:
	var length: float = a.distance_to(b)
	var mid: Vector3 = (a + b) * 0.5
	var dir: Vector3 = (b - a).normalized()
	var yaw := atan2(dir.x, dir.z)
	var perp: Vector3 = dir.cross(Vector3.UP).normalized()

	_road_quad(Vector2(road_width, length), _asphalt, mid + Vector3(0, 0.02, 0), yaw)

	# plowed snow banks
	for s in [-1.0, 1.0]:
		var bank := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.8, 0.3, length)
		bank.mesh = bm
		var bmat := StandardMaterial3D.new()
		bmat.albedo_color = Color(0.80, 0.83, 0.88)
		bmat.roughness = 0.9
		bank.material_override = bmat
		bank.position = mid + perp * (road_width * 0.5 + 0.4) * s + Vector3(0, 0.13, 0)
		bank.rotation.y = yaw
		add_child(bank)

	# faded white edge lines + double solid yellow centerline
	for s in [-1.0, 1.0]:
		_road_quad(Vector2(0.16, length), _white, mid + perp * (road_width * 0.5 - 0.5) * s + Vector3(0, 0.05, 0), yaw)
		_road_quad(Vector2(0.16, length), _yellow, mid + perp * 0.22 * s + Vector3(0, 0.05, 0), yaw)

	# reflective marker stakes
	var n := int(length / 16.0)
	for i in range(2, n - 1):
		var t := float(i) / float(n)
		var p: Vector3 = a.lerp(b, t)
		_spawn_stake(p + perp * (road_width * 0.5 + 1.2))
		_spawn_stake(p - perp * (road_width * 0.5 + 1.2))

func _build_intersection(center: Vector3) -> void:
	_road_quad(Vector2(road_width, road_width), _asphalt, center + Vector3(0, 0.025, 0), 0.0)
	if _rng.randf() < 0.6:
		_tire_decal(center)

func _spawn_stake(pos: Vector3) -> void:
	var post := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.09, 1.2, 0.09)
	post.mesh = box
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.1, 0.1, 0.11)
	post.material_override = m
	post.position = pos + Vector3(0, 0.6, 0)
	add_child(post)
	var mark := MeshInstance3D.new()
	var mb := BoxMesh.new()
	mb.size = Vector3(0.11, 0.18, 0.11)
	mark.mesh = mb
	var mm := StandardMaterial3D.new()
	mm.albedo_color = Color(0.95, 0.45, 0.05)
	mm.emission_enabled = true
	mm.emission = Color(0.95, 0.45, 0.05)
	mm.emission_energy_multiplier = 0.6
	mark.material_override = mm
	mark.position = pos + Vector3(0, 1.05, 0)
	add_child(mark)

# --- decals ------------------------------------------------------------------

func _tire_decal(center: Vector3) -> void:
	var d := Decal.new()
	d.texture_albedo = _tire_texture()
	d.size = Vector3(_rng.randf_range(1.5, 3.0), 0.6, _rng.randf_range(4.0, 7.0))
	d.albedo_mix = 0.85
	d.modulate = Color(0.08, 0.08, 0.08, 0.7)
	d.upper_fade = 0.2
	d.lower_fade = 0.2
	d.rotation.y = _rng.randf() * TAU
	d.position = center + Vector3(_rng.randf_range(-2, 2), 0.3, _rng.randf_range(-2, 2))
	add_child(d)

var _tire_tex: ImageTexture
func _tire_texture() -> ImageTexture:
	if _tire_tex:
		return _tire_tex
	var w := 64
	var h := 256
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var n := FastNoiseLite.new()
	n.frequency = 0.08
	for y in range(h):
		for x in range(w):
			var u := float(x) / w
			var streak: float = exp(-pow((u - 0.35) / 0.08, 2.0)) + exp(-pow((u - 0.65) / 0.08, 2.0))
			var a: float = clampf(streak, 0.0, 1.0) * (0.4 + 0.6 * (n.get_noise_2d(x, y) * 0.5 + 0.5))
			img.set_pixel(x, y, Color(0, 0, 0, a))
	_tire_tex = ImageTexture.create_from_image(img)
	return _tire_tex

# --- road signs --------------------------------------------------------------

func _build_signs() -> void:
	# a handful of readable signs on the right shoulder, facing oncoming (+Z) traffic
	_place_sign(_stop_sign(), Vector3(xs[1] + road_width * 0.5 + 1.6, 0, zs[1] + 7.0))
	_place_sign(_yield_sign(), Vector3(float(xs[0]) + road_width * 0.5 + 1.6, 0, zs[1] + 7.0))
	_place_sign(_warning_sign(), Vector3(float(xs[2]) + road_width * 0.5 + 1.6, 0, zs[2] + 7.0))
	_place_sign(_speed_sign(), Vector3(xs[1] + road_width * 0.5 + 1.6, 0, zs[2] + 7.0))

func _place_sign(sign: Node3D, pos: Vector3) -> void:
	sign.position = pos
	add_child(sign)

func _sign_post(height: float) -> MeshInstance3D:
	var post := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.04
	cyl.height = height
	post.mesh = cyl
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.4, 0.4, 0.42)
	m.metallic = 0.6
	m.roughness = 0.4
	post.material_override = m
	post.position = Vector3(0, height * 0.5, 0)
	return post

func _sign_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.4
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 0.5   # cheap retroreflective glow
	return m

func _sign_label(text: String, size: int, col: Color, y: float) -> Label3D:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = size
	lbl.pixel_size = 0.004
	lbl.modulate = col
	lbl.outline_size = 0
	lbl.position = Vector3(0, y, 0.06)
	lbl.render_priority = 1
	return lbl

func _stop_sign() -> Node3D:
	var root := Node3D.new()
	root.add_child(_sign_post(2.1))
	var face := MeshInstance3D.new()
	var oct := CylinderMesh.new()
	oct.radial_segments = 8
	oct.top_radius = 0.45
	oct.bottom_radius = 0.45
	oct.height = 0.05
	face.mesh = oct
	face.rotation_degrees = Vector3(90, 22.5, 0)
	face.material_override = _sign_mat(Color(0.7, 0.05, 0.05))
	face.position = Vector3(0, 2.2, 0)
	root.add_child(face)
	root.add_child(_sign_label("STOP", 110, Color.WHITE, 2.2))
	return root

func _yield_sign() -> Node3D:
	var root := Node3D.new()
	root.add_child(_sign_post(2.1))
	var face := MeshInstance3D.new()
	var pr := PrismMesh.new()
	pr.size = Vector3(0.9, 0.8, 0.05)
	face.mesh = pr
	face.rotation_degrees = Vector3(0, 0, 180)   # point down
	face.material_override = _sign_mat(Color(0.85, 0.1, 0.1))
	face.position = Vector3(0, 2.3, 0)
	root.add_child(face)
	root.add_child(_sign_label("YIELD", 60, Color.WHITE, 2.3))
	return root

func _warning_sign() -> Node3D:
	var root := Node3D.new()
	root.add_child(_sign_post(2.1))
	var face := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.7, 0.7, 0.05)
	face.mesh = box
	face.rotation_degrees = Vector3(0, 0, 45)    # diamond
	face.material_override = _sign_mat(Color(0.9, 0.75, 0.05))
	face.position = Vector3(0, 2.3, 0)
	root.add_child(face)
	root.add_child(_sign_label("!", 130, Color.BLACK, 2.3))
	return root

func _speed_sign() -> Node3D:
	var root := Node3D.new()
	root.add_child(_sign_post(2.1))
	var face := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 0.8, 0.05)
	face.mesh = box
	face.material_override = _sign_mat(Color(0.92, 0.92, 0.92))
	face.position = Vector3(0, 2.3, 0)
	root.add_child(face)
	root.add_child(_sign_label("80", 100, Color.BLACK, 2.35))
	root.add_child(_sign_label("km/h", 34, Color.BLACK, 2.05))
	return root

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
