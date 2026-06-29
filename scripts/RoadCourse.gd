extends Node3D
## A curved, hilly road built from a Curve3D loop: a winding asphalt ribbon that rises
## and falls over hills, with trimesh collision the car drives on, a ground skirt that
## follows the road, double-yellow centerline + white edge lines. The forest lines this
## curve (Forest.gd reads get_curve()). Replaces the old flat grid.

const ASPHALT_SHADER := preload("res://shaders/asphalt.gdshader")
const ROADLINE_SHADER := preload("res://shaders/roadline.gdshader")
const GlbUtil := preload("res://scripts/GlbUtil.gd")

@export var road_width: float = 9.0
@export var loop_radius: float = 460.0
@export var radius_wobble: float = 150.0
@export var hill_height: float = 8.0
@export var num_points: int = 48
@export var drive_half_width: float = 22.0   ## wide drivable corridor so you can feel it

var _curve: Curve3D
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.seed = 1337
	_build_curve()
	_build_road()

func get_curve() -> Curve3D:
	return _curve

func get_start_transform() -> Transform3D:
	var xf := _curve.sample_baked_with_rotation(2.0, true, true)
	# face along travel (-Z is forward for the car; curve basis.z is forward)
	var b := Basis()
	var fwd := -xf.basis.z
	b = Basis.looking_at(fwd, Vector3.UP)
	return Transform3D(b, xf.origin + Vector3(0, 1.4, 0))

# --- curve -------------------------------------------------------------------

func _build_curve() -> void:
	_curve = Curve3D.new()
	_curve.bake_interval = 1.0
	var rr := FastNoiseLite.new()
	rr.seed = 11
	rr.frequency = 0.9
	var hn := FastNoiseLite.new()
	hn.seed = 22
	hn.frequency = 0.4
	var pts: Array[Vector3] = []
	for i in range(num_points):
		var ang := float(i) / float(num_points) * TAU
		var r: float = loop_radius + rr.get_noise_1d(float(i)) * radius_wobble
		var y: float = hn.get_noise_1d(float(i) * 1.3) * hill_height
		pts.append(Vector3(cos(ang) * r, y, sin(ang) * r))
	# close the loop
	pts.append(pts[0])
	var n := pts.size()
	for i in range(n):
		var prevp: Vector3 = pts[(i - 1 + n) % n]
		var nextp: Vector3 = pts[(i + 1) % n]
		var handle: Vector3 = (nextp - prevp) * 0.16
		_curve.add_point(pts[i], -handle, handle)

# --- meshes ------------------------------------------------------------------

func _build_road() -> void:
	var asphalt := ShaderMaterial.new()
	asphalt.shader = ASPHALT_SHADER
	# ground skirt (wide, follows the road elevation, but horizontal across so it does
	# NOT swing up/down at the sides on slopes — that made it look like a hill swallowing you)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.07, 0.08, 0.06)
	ground_mat.roughness = 1.0
	_ground_skirt(190.0, -0.6, ground_mat)
	# drivable asphalt
	_ribbon(0.0, road_width * 0.5, 0.0, asphalt, 0.14, false)
	# wide invisible collision corridor (lets you roam off the lane and feel the car)
	var col := _ribbon(0.0, drive_half_width, -0.05, null, 0.1, true)
	col.visible = false
	# lane lines
	var yellow := _line_mat(Color(0.82, 0.70, 0.20), 0.45)
	var white := _line_mat(Color(0.78, 0.80, 0.82), 0.5)
	_ribbon(-0.22, 0.08, 0.05, yellow, 1.0, false)
	_ribbon(0.22, 0.08, 0.05, yellow, 1.0, false)
	_ribbon(-(road_width * 0.5 - 0.5), 0.08, 0.05, white, 1.0, false)
	_ribbon(road_width * 0.5 - 0.5, 0.08, 0.05, white, 1.0, false)
	# safety net far below in case the car ever leaves the surface
	_fallback_ground()
	_place_signs()

const SIGN_A := "res://assets/signs/roadsign_sollested_ccby.glb"
const SIGN_B := "res://assets/signs/construction_sign_caspers_ccby.glb"

func _place_signs() -> void:
	var a := GlbUtil.load_scene(SIGN_A)
	var b := GlbUtil.load_scene(SIGN_B)
	var length := _curve.get_baked_length()
	var count := 7
	for i in range(count):
		var d: float = fmod(length * float(i) / float(count) + 20.0, length)
		var src: Node3D = a if i % 2 == 0 else b
		if src == null:
			continue
		var xf := _curve.sample_baked_with_rotation(d, true, true)
		var right := xf.basis.x
		var pos := xf.origin + right * (road_width * 0.5 + 1.8) + Vector3(0, -0.6, 0)
		var nxf := _curve.sample_baked_with_rotation(fmod(d + 2.0, length), true, true)
		var travel := nxf.origin - xf.origin
		var s := src.duplicate() as Node3D
		add_child(s)
		s.global_position = pos
		if travel.length() > 0.05:
			s.look_at(pos - travel, Vector3.UP)   # face oncoming traffic
	if a:
		a.free()
	if b:
		b.free()

func _line_mat(col: Color, wear: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ROADLINE_SHADER
	m.set_shader_parameter("paint_color", col)
	m.set_shader_parameter("wear", wear)
	return m

## Build a ribbon following the curve at a lateral offset, given half-width. Returns the
## MeshInstance3D; if collision, attaches a trimesh static body.
func _ribbon(lateral: float, half_w: float, y_lift: float, mat: Material, uv_tile: float, collision: bool) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length := _curve.get_baked_length()
	var step := 2.0
	var rings := 0
	var d := 0.0
	while d <= length:
		var xf := _curve.sample_baked_with_rotation(d, true, true)
		# horizontal cross-section: level across, only the centerline elevation (hills)
		# changes along the road. No sideways roll, so edges never dip below the dirt.
		var fwd := xf.basis.z
		var fwd_h := Vector3(fwd.x, 0.0, fwd.z).normalized()
		var right_h := Vector3(fwd_h.z, 0.0, -fwd_h.x)
		var c := xf.origin + Vector3(0, y_lift, 0)
		var vL := c + right_h * (lateral - half_w)
		var vR := c + right_h * (lateral + half_w)
		var v := d * uv_tile
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0.0, v))
		st.add_vertex(vL)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(1.0, v))
		st.add_vertex(vR)
		rings += 1
		d += step
	for r in range(rings - 1):
		var a := r * 2
		var b := r * 2 + 1
		var cc := (r + 1) * 2
		var dd := (r + 1) * 2 + 1
		st.add_index(a)
		st.add_index(cc)
		st.add_index(b)
		st.add_index(b)
		st.add_index(cc)
		st.add_index(dd)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if mat:
		mi.material_override = mat
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)
	if collision:
		mi.create_trimesh_collision()
	return mi

## Ground band that follows the road's centerline elevation along its length but stays
## HORIZONTAL across its width (so the sides never swing up on slopes/curves).
func _ground_skirt(half_w: float, y_lift: float, mat: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length := _curve.get_baked_length()
	var step := 3.0
	var rings := 0
	var d := 0.0
	while d <= length:
		var xf := _curve.sample_baked_with_rotation(d, true, true)
		# horizontal forward, then horizontal right (perpendicular in the XZ plane)
		var fwd := xf.basis.z
		var fwd_h := Vector3(fwd.x, 0.0, fwd.z).normalized()
		var right_h := Vector3(fwd_h.z, 0.0, -fwd_h.x)
		var c := Vector3(xf.origin.x, xf.origin.y + y_lift, xf.origin.z)
		var vL := c - right_h * half_w
		var vR := c + right_h * half_w   # same Y as vL -> flat across
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0.0, d * 0.04))
		st.add_vertex(vL)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(1.0, d * 0.04))
		st.add_vertex(vR)
		rings += 1
		d += step
	for r in range(rings - 1):
		var a := r * 2
		var b := r * 2 + 1
		var cc := (r + 1) * 2
		var dd := (r + 1) * 2 + 1
		st.add_index(a); st.add_index(cc); st.add_index(b)
		st.add_index(b); st.add_index(cc); st.add_index(dd)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)

func _fallback_ground() -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2000, 2.0, 2000)
	cs.shape = box
	cs.position = Vector3(0, -40.0, 0)
	body.add_child(cs)
	add_child(body)
