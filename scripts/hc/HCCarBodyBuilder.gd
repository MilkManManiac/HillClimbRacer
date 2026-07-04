extends RefCounted
## Procedural vehicle body geometry for HCCar (A1: GLB path stays on the car).

# NOTE: deliberate preload cycle with HCCar (it preloads this file). Verified fine
# on Godot 4.6.3 — and the typed `car` is what lets `:=` inference work below.
const HCCarScript := preload("res://scripts/hc/HCCar.gd")

var car: HCCarScript
var _body_root: Node3D
var _headlights: Array[SpotLight3D] = []

func _init(host: HCCarScript) -> void:
	car = host

func build(body_root: Node3D, vehicle_type: String) -> Array:
	_headlights.clear()
	_body_root = body_root
	match vehicle_type:
		"monster":
			_build_monster_body()
		"minivan":
			_build_minivan_body()
		"sports":
			_build_sports_body()
		"f1":
			_build_f1_body()
		_:
			_build_hotrod_body()
	return _headlights

func _build_hotrod_body() -> void:
	var red := Color(0.86, 0.11, 0.09)        # saturated hot-rod paint
	var red_dk := Color(0.5, 0.07, 0.06)       # shadowed paint for steps
	var dark := Color(0.09, 0.09, 0.11)
	var rubber := Color(0.05, 0.05, 0.06)

	# --- lower rocker / floor pan (matte, ties the silhouette to the wheels) ---
	car._panel(_body_root, Vector3(1.92, 0.24, 3.7), Vector3(0, 0.33, 0), dark, 0.75)
	car._panel(_body_root, Vector3(2.0, 0.12, 3.5), Vector3(0, 0.27, 0), rubber, 0.85)   # skirt under-shadow

	# --- main tub: stacked, slightly tapered boxes for a rounded shoulder line ---
	car._panel(_body_root, Vector3(1.84, 0.42, 3.5), Vector3(0, 0.58, 0), red, 0.35, 0.6)      # body sides
	car._panel(_body_root, Vector3(1.6, 0.3, 3.4), Vector3(0, 0.86, 0), red, 0.35, 0.6)        # upper shoulder
	# beveled top edges (prisms) to knock the slab corners off the shoulder.
	# These run FRONT-TO-BACK along the body (length on Z) and roll about Z to chamfer
	# the top-outer corner. (A 90° YAW here was swinging the 3.4 m length out sideways
	# into a red plank that looked exactly like a wing on the bare car.)
	for sx_b in [-1.0, 1.0]:
		var bev := _prism(_body_root, Vector3(0.4, 0.3, 3.4), Vector3(0.74 * sx_b, 0.9, 0.0), red, 0.35, 0.6)
		bev.rotation_degrees = Vector3(0, 0, -35.0 * sx_b)

	# --- hood: stepped down toward the nose, with a raised center spine ---------
	car._panel(_body_root, Vector3(1.6, 0.32, 1.25), Vector3(0, 0.82, -1.2), red, 0.32, 0.6)
	car._panel(_body_root, Vector3(1.5, 0.16, 1.0), Vector3(0, 0.97, -1.0), red, 0.32, 0.6)      # raised hood crown
	car._panel(_body_root, Vector3(0.5, 0.1, 1.15), Vector3(0, 1.05, -1.05), red_dk, 0.3, 0.6)   # center spine
	# hood scoop (chunky box + a forward-facing mouth prism)
	car._panel(_body_root, Vector3(0.62, 0.2, 0.55), Vector3(0, 1.13, -0.78), dark, 0.4, 0.3)
	var scoop := _prism(_body_root, Vector3(0.62, 0.2, 0.3), Vector3(0, 1.13, -1.04), rubber, 0.6)
	scoop.rotation_degrees = Vector3(90, 0, 0)

	# --- cowl in front of the windscreen ---------------------------------------
	car._panel(_body_root, Vector3(1.55, 0.16, 0.35), Vector3(0, 1.02, -0.35), red, 0.32, 0.6)

	# --- rear deck: stepped up to a small ducktail --------------------------
	car._panel(_body_root, Vector3(1.62, 0.34, 1.0), Vector3(0, 0.9, 1.3), red, 0.32, 0.6)
	car._panel(_body_root, Vector3(1.5, 0.16, 0.55), Vector3(0, 1.06, 1.5), red, 0.32, 0.6)       # ducktail lip
	var tail := _prism(_body_root, Vector3(1.5, 0.18, 0.4), Vector3(0, 1.05, 1.72), red, 0.32, 0.6)
	tail.rotation_degrees = Vector3(180, 0, 0)

	# --- cockpit side walls (driver sits between them, in the open) ------------
	for sx in [-1.0, 1.0]:
		car._panel(_body_root, Vector3(0.18, 0.4, 1.6), Vector3(0.8 * sx, 1.0, 0.2), red, 0.35, 0.6)
		# inner trim lip
		car._panel(_body_root, Vector3(0.08, 0.1, 1.5), Vector3(0.7 * sx, 1.18, 0.2), dark, 0.5)
		# door seam + handle (the "door" is the front half of this side wall) + a
		# racing-number roundel — the classic hot-rod door decal
		_seam_v(_body_root, 0.9 * sx, 0.95, -0.35, 0.55)
		_door_handle(_body_root, 0.9 * sx, 1.0, -0.7)
		car._panel(_body_root, Vector3(0.02, 0.34, 0.34), Vector3(0.9 * sx, 0.95, 0.05), Color(0.96, 0.94, 0.9), 0.5)   # roundel disc
		car._panel(_body_root, Vector3(0.03, 0.16, 0.03), Vector3(0.92 * sx, 0.95, 0.05), dark, 0.4)                    # "number" mark

	# --- twin racing stripes over hood/crown/tail --------------------------
	var stripe := Color(0.95, 0.95, 0.92)
	for sx3 in [-0.28, 0.28]:
		car._panel(_body_root, Vector3(0.16, 0.02, 3.6), Vector3(sx3, 0.99, 0.0), stripe, 0.4)

	# --- fenders / wheel arches over the four wheels ---------------------------
	_build_fenders(red, rubber)

	# --- chrome trim, bumpers, grille, lights, mirrors, exhaust, cockpit -------
	_build_chrome_trim()
	_build_bumpers()
	_build_grille()
	_build_car_lights()
	_build_mirrors()
	_build_exhausts()
	_build_windshield()
	_build_cockpit()
	_plate(_body_root, 0, 0.62, -1.98)
	_plate(_body_root, 0, 0.66, 1.98)
	_add_headlights(_body_root, 0.66, 0.9, -1.95)

	# --- engine-block pipes poking from the hood scoop (hot-rod signature) -----
	for px in [-0.16, 0.0, 0.16]:
		_chrome_cyl(_body_root, 0.035, 0.3, Vector3(px, 1.28, -0.9), Vector3(0, 0, 0), 0.15)

func _build_monster_body() -> void:
	# Build into a scaled HULL child so the whole truck is silly-big, while the
	# parent _body_root stays unit-scaled for the Stretch/Wide chassis upgrades to scale.
	var hull := Node3D.new()
	hull.scale = Vector3(1.45, 1.65, 1.4)   # extra-tall, chunky monster proportions
	_body_root.add_child(hull)
	var body := Color(0.13, 0.45, 0.85)        # blue truck paint
	var body_dk := Color(0.08, 0.28, 0.55)
	var dark := Color(0.08, 0.08, 0.1)
	var rubber := Color(0.05, 0.05, 0.06)

	# --- heavy frame rails / skid plate (ties body to the tall stance) ---------
	car._panel(hull, Vector3(2.0, 0.3, 4.0), Vector3(0, 0.5, 0), dark, 0.8)
	for sx in [-1.0, 1.0]:
		car._panel(hull, Vector3(0.18, 0.42, 3.8), Vector3(0.92 * sx, 0.55, 0), rubber, 0.85)

	# --- flat cargo bed at the rear --------------------------------------------
	car._panel(hull, Vector3(2.1, 0.5, 1.8), Vector3(0, 0.95, 1.2), body, 0.45, 0.3)
	car._panel(hull, Vector3(2.1, 0.34, 0.16), Vector3(0, 1.25, 2.05), body_dk, 0.45)   # tailgate
	for sx in [-1.0, 1.0]:
		car._panel(hull, Vector3(0.16, 0.34, 1.8), Vector3(1.0 * sx, 1.25, 1.2), body_dk, 0.45)   # bed walls

	# --- tall boxy cab ----------------------------------------------------------
	car._panel(hull, Vector3(2.1, 1.0, 1.9), Vector3(0, 1.2, -0.7), body, 0.4, 0.3)     # cab lower
	car._panel(hull, Vector3(1.96, 0.7, 1.7), Vector3(0, 1.95, -0.6), body, 0.4, 0.3)   # cab upper / greenhouse
	# wrap windows (glass band around the upper cab)
	var glass := _glass(0.32)
	for win in [Vector3(0, 1.98, -1.46), Vector3(0, 1.98, 0.28)]:
		var w := car._panel(hull, Vector3(1.7, 0.55, 0.06), win, Color(1,1,1), 0.05)
		w.material_override = glass
	for sx in [-1.0, 1.0]:
		var ws := car._panel(hull, Vector3(0.06, 0.5, 1.6), Vector3(0.99 * sx, 1.98, -0.6), Color(1,1,1), 0.05)
		ws.material_override = glass
	car._panel(hull, Vector3(2.0, 0.16, 1.8), Vector3(0, 2.34, -0.6), body_dk, 0.4)     # roof cap
	# cab door seam + handle + a two-tone contrast panel (lower cab skirt)
	for sx in [-1.0, 1.0]:
		_seam_v(hull, 1.05 * sx, 1.15, -0.7, 0.85)
		_door_handle(hull, 1.06 * sx, 1.25, -1.05)
		car._panel(hull, Vector3(0.02, 0.24, 1.7), Vector3(1.05 * sx, 0.78, -0.7), body_dk, 0.45)

	# --- hood + grille up front -------------------------------------------------
	car._panel(hull, Vector3(2.0, 0.55, 1.3), Vector3(0, 1.18, -2.05), body, 0.4, 0.3)
	_seam_h(hull, 0, 1.46, -2.05, 1.9)   # hood shut-line
	car._panel(hull, Vector3(1.8, 0.5, 0.18), Vector3(0, 1.12, -2.74), dark, 0.5)        # grille
	for gx in [-0.6, -0.2, 0.2, 0.6]:
		_emit_panel(hull, Vector3(0.12, 0.42, 0.06), Vector3(gx, 1.12, -2.8), Color(0.9, 0.95, 1.0), 0.6)
	# headlights (visual bulb + real spotlight) + a chrome bull-bar style snorkel
	for sx in [-1.0, 1.0]:
		_emit_panel(hull, Vector3(0.34, 0.26, 0.1), Vector3(0.74 * sx, 1.2, -2.78), Color(1.0, 0.96, 0.8), 2.2)
	# real spotlights go on _body_root (not the scaled hull) so hull.scale doesn't distort
	# the light's range/angle — coordinates below are the hull position pre-multiplied
	# by hull.scale (1.45, 1.65, 1.4) to line up with the visual bulb above.
	_add_headlights(_body_root, 0.74 * 1.45, 1.2 * 1.65, -2.78 * 1.4)
	_plate(hull, 0, 0.78, -2.79)
	# snorkel (air intake tube up the A-pillar, off-road detail)
	_chrome_cyl(hull, 0.08, 1.1, Vector3(0.9, 2.1, -1.3), Vector3(0, 0, 0), 0.3)
	car._panel(hull, Vector3(0.2, 0.16, 0.2), Vector3(0.9, 2.7, -1.3), dark, 0.4)         # snorkel intake head

	# --- roll bar over the bed with a light pod (classic monster look) ----------
	for sx in [-1.0, 1.0]:
		_chrome_cyl(hull, 0.07, 1.2, Vector3(0.85 * sx, 1.9, 0.9), Vector3(0, 0, 0))
	_chrome_cyl(hull, 0.07, 1.7, Vector3(0, 2.5, 0.9), Vector3(0, 0, 90))            # top cross bar
	car._panel(hull, Vector3(1.5, 0.26, 0.3), Vector3(0, 2.62, 0.9), dark, 0.4)          # light pod
	for lx in [-0.55, -0.18, 0.18, 0.55]:
		_emit_panel(hull, Vector3(0.28, 0.22, 0.12), Vector3(lx, 2.62, 0.74), Color(1.0, 0.98, 0.85), 2.6)
	# taillights (red, on the tailgate) + rear plate
	for sx in [-0.8, 0.8]:
		_emit_panel(hull, Vector3(0.24, 0.28, 0.1), Vector3(sx, 1.25, 2.12), Color(0.95, 0.06, 0.05), 2.0)
	_plate(hull, 0, 0.95, 2.13)

	# --- chunky bumpers / nerf bars --------------------------------------------
	_chrome_cyl(hull, 0.11, 2.1, Vector3(0, 0.9, -2.95), Vector3(0, 0, 90))          # front bar
	_chrome_cyl(hull, 0.11, 2.1, Vector3(0, 0.95, 2.25), Vector3(0, 0, 90))          # rear bar
	# tow hook, hung off the front bar
	_chrome_cyl(hull, 0.045, 0.22, Vector3(0, 0.65, -2.98), Vector3(90, 0, 0), 0.2)
	# exhaust stacks up the back of the cab
	for sx in [-1.0, 1.0]:
		_chrome_cyl(hull, 0.1, 0.9, Vector3(0.8 * sx, 1.4, 0.25), Vector3(0, 0, 0))   # shorter + lower so they sit below the chase camera
	# chunky chrome suspension links, hull frame down toward each wheel corner
	for sx in [-1.0, 1.0]:
		for sz in [-1.55, 1.55]:
			_chrome_cyl(hull, 0.055, 0.65, Vector3(0.95 * sx, 0.22, sz), Vector3(0, 0, 18.0 * sx), 0.25)
	# rubber mud flaps trailing each wheel arch
	for sx in [-1.0, 1.0]:
		for sz in [-1.55, 1.55]:
			car._panel(hull, Vector3(0.05, 0.5, 0.34), Vector3(1.05 * sx, -0.15, sz + 0.35), rubber, 0.95)
	# mirrors, chrome stalks off the cab A-pillars
	for sx in [-1.0, 1.0]:
		_chrome_cyl(hull, 0.03, 0.3, Vector3(1.1 * sx, 1.75, -1.35), Vector3(0, 0, 65 * sx))
		car._panel(hull, Vector3(0.05, 0.2, 0.26), Vector3(1.26 * sx, 1.86, -1.35), dark, 0.3, 0.4)
func _build_minivan_body() -> void:
	var body := Color(0.62, 0.6, 0.5)      # faded beige
	var body_dk := Color(0.42, 0.4, 0.34)
	var dark := Color(0.1, 0.1, 0.12)
	var glass := _glass(0.3)
	car._panel(_body_root, Vector3(1.9, 0.28, 4.0), Vector3(0, 0.42, 0), dark, 0.85)                 # rocker/floor
	car._panel(_body_root, Vector3(1.9, 1.05, 3.5), Vector3(0, 1.05, 0.15), body, 0.7, 0.05)         # boxy cabin
	car._panel(_body_root, Vector3(1.86, 0.62, 0.7), Vector3(0, 0.72, -1.95), body, 0.7)             # stubby flat front
	car._panel(_body_root, Vector3(1.82, 0.14, 3.3), Vector3(0, 1.64, 0.15), body_dk, 0.6)           # roof cap
	var wt := car._panel(_body_root, Vector3(1.7, 0.5, 0.06), Vector3(0, 1.3, -1.62), Color(1, 1, 1), 0.05); wt.material_override = glass
	var rw := car._panel(_body_root, Vector3(1.6, 0.45, 0.06), Vector3(0, 1.3, 1.86), Color(1, 1, 1), 0.05); rw.material_override = glass
	for sx in [-1.0, 1.0]:
		var sw := car._panel(_body_root, Vector3(0.06, 0.48, 2.6), Vector3(0.95 * sx, 1.32, 0.2), Color(1, 1, 1), 0.05); sw.material_override = glass
		_emit_panel(_body_root, Vector3(0.3, 0.22, 0.1), Vector3(0.7 * sx, 0.8, -2.3), Color(1, 0.95, 0.8), 1.6)
		# taillights, door seam + handle
		_emit_panel(_body_root, Vector3(0.24, 0.24, 0.08), Vector3(0.85 * sx, 0.9, 2.28), Color(0.95, 0.06, 0.05), 1.8)
		_seam_v(_body_root, 0.96 * sx, 1.1, 0.35, 1.0)
		_door_handle(_body_root, 0.96 * sx, 1.15, -0.1)
	car._panel(_body_root, Vector3(1.4, 0.28, 0.1), Vector3(0, 0.6, -2.3), dark, 0.5)                # grille
	_chrome_cyl(_body_root, 0.08, 1.9, Vector3(0, 0.42, -2.3), Vector3(0, 0, 90))                # front bumper
	_chrome_cyl(_body_root, 0.08, 1.9, Vector3(0, 0.42, 2.2), Vector3(0, 0, 90))                 # rear bumper
	_add_headlights(_body_root, 0.7, 0.8, -2.32)
	_plate(_body_root, 0, 0.5, -2.32)
	_plate(_body_root, 0, 0.5, 2.22)
	# mirrors on stubby stalks
	for sx in [-1.0, 1.0]:
		_chrome_cyl(_body_root, 0.02, 0.14, Vector3(0.96 * sx, 1.4, -1.5), Vector3(0, 0, 40 * sx))
		car._panel(_body_root, Vector3(0.04, 0.12, 0.16), Vector3(1.04 * sx, 1.45, -1.5), dark, 0.4)
	# mismatched-color replacement door panel — a junkyard swap that never got painted
	car._panel(_body_root, Vector3(0.02, 0.68, 1.35), Vector3(0.96, 1.0, 0.6), Color(0.3, 0.36, 0.32), 0.8)
	# a dent: a slightly recessed offset panel low on the rear quarter
	car._panel(_body_root, Vector3(0.03, 0.3, 0.32), Vector3(-0.955, 0.75, 1.35), body_dk, 0.75)
	# duct-tape stripe patching a crack across the rear door
	car._panel(_body_root, Vector3(0.015, 0.05, 0.9), Vector3(0.965, 1.15, 0.7), Color(0.78, 0.76, 0.7), 0.9)
	car._panel(_body_root, Vector3(0.5, 0.3, 0.03), Vector3(0.96, 0.9, -0.5), Color(0.4, 0.28, 0.16), 0.95)  # rust patch
	car._panel(_body_root, Vector3(0.3, 0.2, 0.03), Vector3(-0.96, 0.55, -1.4), Color(0.36, 0.24, 0.14), 0.95) # second rust patch, lower
	# roof rack rails + two strapped boxes
	for sx in [-1.0, 1.0]:
		car._panel(_body_root, Vector3(0.06, 0.06, 2.6), Vector3(0.7 * sx, 1.76, 0.1), dark, 0.5, 0.3)
	for rz in [-0.8, 0.55]:
		car._panel(_body_root, Vector3(1.1, 0.34, 0.6), Vector3(0, 1.95, rz), Color(0.5, 0.42, 0.28), 0.8)     # cardboard-brown box
		for sx2 in [-1.0, 1.0]:
			car._panel(_body_root, Vector3(1.16, 0.03, 0.05), Vector3(0, 1.95, rz + 0.28 * sx2), Color(0.85, 0.8, 0.2), 0.7)  # tie-down strap
	# steering wheel glimpsed through the windshield
	var wheel := MeshInstance3D.new()
	var tm := TorusMesh.new(); tm.inner_radius = 0.1; tm.outer_radius = 0.14
	wheel.mesh = tm
	var wmat := StandardMaterial3D.new(); wmat.albedo_color = Color(0.1, 0.1, 0.11); wmat.roughness = 0.6
	wheel.material_override = wmat
	wheel.position = Vector3(0.35, 1.15, -1.35)
	wheel.rotation_degrees = Vector3(70, 0, 0)
	_body_root.add_child(wheel)
	car._panel(_body_root, Vector3(0.5, 0.14, 0.42), Vector3(0.35, 0.85, -1.3), dark, 0.7)    # driver seat back, in silhouette
func _build_sports_body() -> void:
	var body := Color(0.93, 0.72, 0.06)    # racing yellow
	var body_dk := Color(0.6, 0.47, 0.05)
	var dark := Color(0.08, 0.08, 0.1)
	var glass := _glass(0.26)
	car._panel(_body_root, Vector3(2.0, 0.22, 4.0), Vector3(0, 0.32, 0), dark, 0.8)                  # low floor
	car._panel(_body_root, Vector3(1.94, 0.42, 3.9), Vector3(0, 0.58, 0), body, 0.28, 0.7)           # sleek body
	var nose := car._panel(_body_root, Vector3(1.72, 0.3, 1.5), Vector3(0, 0.55, -1.75), body, 0.28, 0.7); nose.rotation_degrees = Vector3(-7, 0, 0)
	car._panel(_body_root, Vector3(1.5, 0.34, 1.6), Vector3(0, 0.92, 0.2), body, 0.3, 0.6)           # low cabin
	var ws := car._panel(_body_root, Vector3(1.4, 0.3, 0.05), Vector3(0, 1.0, -0.62), Color(1, 1, 1), 0.05); ws.material_override = glass
	var roof := car._panel(_body_root, Vector3(1.42, 0.26, 1.1), Vector3(0, 1.12, 0.32), Color(1, 1, 1), 0.05); roof.material_override = glass
	for sx in [-1.0, 1.0]:
		car._panel(_body_root, Vector3(0.14, 0.24, 3.4), Vector3(0.98 * sx, 0.48, 0), body_dk, 0.4)  # side skirt
		_emit_panel(_body_root, Vector3(0.32, 0.14, 0.1), Vector3(0.6 * sx, 0.66, -2.32), Color(1, 0.97, 0.85), 2.0)
		_emit_panel(_body_root, Vector3(0.32, 0.12, 0.08), Vector3(0.6 * sx, 0.74, 1.98), Color(1, 0.2, 0.1), 2.2)
		# pop-up-style headlight cover panel, proud of the nose, half-raised look
		car._panel(_body_root, Vector3(0.34, 0.06, 0.16), Vector3(0.6 * sx, 0.76, -2.28), body, 0.3, 0.6)
		# door seam + handle over the low cabin
		_seam_v(_body_root, 0.97 * sx, 0.85, -0.05, 0.55)
		_door_handle(_body_root, 0.97 * sx, 0.95, -0.3)
		# rear diffuser fins under the rear deck
		car._panel(_body_root, Vector3(0.06, 0.1, 0.6), Vector3(0.5 * sx, 0.28, 1.9), dark, 0.5, 0.3)
	car._panel(_body_root, Vector3(1.9, 0.2, 0.9), Vector3(0, 0.8, 1.6), body, 0.3, 0.6)             # rear deck
	car._panel(_body_root, Vector3(1.7, 0.1, 0.26), Vector3(0, 0.92, 2.02), body_dk, 0.3, 0.6)       # small ducktail lip
	for sx in [-0.75, 0.75]:
		car._panel(_body_root, Vector3(0.08, 0.3, 0.1), Vector3(sx, 0.98, 1.9), dark, 0.5)           # spoiler struts
	car._panel(_body_root, Vector3(1.94, 0.08, 0.42), Vector3(0, 1.15, 1.92), dark, 0.4)             # spoiler wing
	car._panel(_body_root, Vector3(0.9, 0.16, 0.08), Vector3(0, 0.52, -2.32), dark, 0.5)             # grille
	# twin center exhausts (not corner pipes — the sports-car signature)
	for ex in [-0.14, 0.14]:
		_chrome_cyl(_body_root, 0.055, 0.2, Vector3(ex, 0.34, 2.02), Vector3(90, 0, 0), 0.08)
	_add_headlights(_body_root, 0.6, 0.7, -2.3)
	_plate(_body_root, 0, 0.5, -2.34)
	_plate(_body_root, 0, 0.55, 2.03)
	# mirrors, low and swept
	for sx in [-1.0, 1.0]:
		_chrome_cyl(_body_root, 0.02, 0.12, Vector3(0.98 * sx, 0.98, -0.5), Vector3(0, 0, 50 * sx))
		car._panel(_body_root, Vector3(0.05, 0.1, 0.18), Vector3(1.06 * sx, 1.03, -0.5), dark, 0.3, 0.5)
	# racing stripe over the cabin/deck
	car._panel(_body_root, Vector3(0.3, 0.02, 3.6), Vector3(0, 0.99, 0.0), Color(0.06, 0.06, 0.08), 0.4)
	# a small driver seat glimpsed through the glass roof
	car._panel(_body_root, Vector3(0.44, 0.4, 0.12), Vector3(0.25, 0.98, 0.75), Color(0.08, 0.08, 0.09), 0.6)
func _build_f1_body() -> void:
	var body := Color(0.1, 0.3, 0.86)      # team blue
	var body_dk := Color(0.06, 0.16, 0.5)
	var dark := Color(0.06, 0.06, 0.08)
	var sponsor := Color(0.95, 0.78, 0.05)  # gold sponsor-block accent, high contrast on team blue
	car._panel(_body_root, Vector3(0.72, 0.34, 3.2), Vector3(0, 0.5, 0.35), body, 0.3, 0.5)          # monocoque tub
	car._panel(_body_root, Vector3(0.4, 0.22, 1.0), Vector3(0, 0.5, -1.6), body, 0.3, 0.5)           # nose base
	car._panel(_body_root, Vector3(0.28, 0.16, 1.0), Vector3(0, 0.48, -2.4), body, 0.3, 0.5)         # thin nose tip
	for sx in [-1.0, 1.0]:
		car._panel(_body_root, Vector3(0.5, 0.3, 1.7), Vector3(0.62 * sx, 0.48, 0.5), body_dk, 0.4)  # side pod
		# bargeboards — small vertical vanes ahead of the sidepods (aero furniture)
		car._panel(_body_root, Vector3(0.04, 0.24, 0.4), Vector3(0.65 * sx, 0.44, -0.65), dark, 0.4)
		car._panel(_body_root, Vector3(0.04, 0.16, 0.22), Vector3(0.5 * sx, 0.4, -0.85), dark, 0.4)
	car._panel(_body_root, Vector3(0.42, 0.5, 0.7), Vector3(0, 0.98, 1.1), body_dk, 0.35)            # airbox / intake above the driver
	car._panel(_body_root, Vector3(0.3, 0.14, 0.14), Vector3(0, 1.24, 0.78), dark, 0.5)              # airbox intake mouth
	car._panel(_body_root, Vector3(0.5, 0.16, 0.9), Vector3(0, 0.7, 0.15), dark, 0.7)                # open cockpit
	# halo bar — the curved head-protection loop, approximated with straight struts
	car._panel(_body_root, Vector3(0.05, 0.4, 0.05), Vector3(0, 0.9, -0.45), dark, 0.25, 0.6)
	car._panel(_body_root, Vector3(0.05, 0.22, 0.05), Vector3(-0.22, 1.0, 0.0), dark, 0.25, 0.6)
	car._panel(_body_root, Vector3(0.05, 0.22, 0.05), Vector3(0.22, 1.0, 0.0), dark, 0.25, 0.6)
	car._panel(_body_root, Vector3(0.5, 0.04, 0.55), Vector3(0, 1.1, -0.2), dark, 0.25, 0.6)          # halo top ring, foreshortened
	# a race number roundel on the airbox flank
	car._panel(_body_root, Vector3(0.02, 0.24, 0.24), Vector3(0.22, 0.98, 1.1), Color(0.95, 0.95, 0.92), 0.4)
	car._panel(_body_root, Vector3(0.02, 0.24, 0.24), Vector3(-0.22, 0.98, 1.1), Color(0.95, 0.95, 0.92), 0.4)
	# rear wing + sponsor-color endplates
	for sx in [-0.5, 0.5]:
		car._panel(_body_root, Vector3(0.05, 0.44, 0.5), Vector3(sx, 0.98, 2.05), dark, 0.4)
		car._panel(_body_root, Vector3(0.02, 0.4, 0.46), Vector3(sx * 1.08, 0.98, 2.05), sponsor, 0.4)   # endplate sponsor block
	car._panel(_body_root, Vector3(1.25, 0.09, 0.5), Vector3(0, 1.22, 2.05), body_dk, 0.4)
	_emit_panel(_body_root, Vector3(1.1, 0.05, 0.06), Vector3(0, 0.78, 2.28), Color(0.95, 0.06, 0.05), 1.6)  # rear crash-structure brake strip
	# front wing + sponsor-color endplates
	car._panel(_body_root, Vector3(1.5, 0.08, 0.42), Vector3(0, 0.32, -2.5), body_dk, 0.4)
	for sx in [-0.72, 0.72]:
		car._panel(_body_root, Vector3(0.05, 0.28, 0.42), Vector3(sx, 0.4, -2.5), dark, 0.4)
		car._panel(_body_root, Vector3(0.02, 0.24, 0.38), Vector3(sx * 1.06, 0.4, -2.5), sponsor, 0.4)    # endplate sponsor block
	for sx in [-1.0, 1.0]:
		_emit_panel(_body_root, Vector3(0.18, 0.1, 0.06), Vector3(0.55 * sx, 0.62, 1.9), Color(1, 0.2, 0.1), 2.2)
	# small forward marker lights (F1 cars run rain-light style lamps, not headlamps)
	for sx in [-1.0, 1.0]:
		_emit_panel(_body_root, Vector3(0.08, 0.06, 0.04), Vector3(0.3 * sx, 0.5, -2.56), Color(1.0, 0.97, 0.85), 1.4)
	_add_headlights(_body_root, 0.3, 0.5, -2.55)
	_plate(_body_root, 0, 0.42, 2.35)   # scrutineering plaque low on the tail, stands in for a plate
	# wheel-hub cones at each corner (static — reads fine at these low-poly proportions
	# even though the wheel itself spins independently)
	var hub_x: float = float(car._vs.fx) + 0.03
	var hub_z: float = float(car._vs.fz)
	for sx in [-1.0, 1.0]:
		for sz in [-hub_z, hub_z]:
			var hub := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.02; cm.bottom_radius = 0.13; cm.height = 0.14
			hub.mesh = cm
			hub.material_override = car._chrome(0.15)
			hub.position = Vector3(hub_x * sx, 0.5, sz)
			hub.rotation_degrees = Vector3(0, 0, 90 * sx)
			_body_root.add_child(hub)

# --- body-detail helpers -----------------------------------------------------

## A PrismMesh panel (triangular cross-section) for bevels / wedges / scoops.
func _prism(parent: Node3D, size: Vector3, pos: Vector3, col: Color, rough := 0.5, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PrismMesh.new()
	pm.size = size
	mi.mesh = pm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)
	return mi

## Bluish semi-transparent glass.
func _glass(alpha := 0.28) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.55, 0.72, 0.85, alpha)
	m.metallic = 0.2
	m.roughness = 0.05
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

## A glowing/emissive panel (headlights, taillights).
func _emit_panel(parent: Node3D, size: Vector3, pos: Vector3, col: Color, energy := 1.6) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = 0.2
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	mi.material_override = m
	mi.position = pos
	parent.add_child(mi)
	return mi

## A chrome cylinder helper (bumper bars, exhaust tips, mirror stalks).
func _chrome_cyl(parent: Node3D, radius: float, height: float, pos: Vector3, rot: Vector3, rough := 0.1) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	mi.mesh = cm
	mi.material_override = car._chrome(rough)
	mi.position = pos
	mi.rotation_degrees = rot
	parent.add_child(mi)
	return mi

## Forward-facing spotlight headlight pair (real SpotLight3D, not just an emissive
## panel) parented under `parent`, aimed along local -Z — the body's forward axis,
## so no rotation is needed. OFF by default; a night map (HCMain, built concurrently)
## flips them on via set_headlights(). Shadows off and a modest range/angle keep
## these cheap even with five headlight pairs live if every ride were night-lit.
func _add_headlights(parent: Node3D, x: float, y: float, z: float) -> void:
	for sx in [-1.0, 1.0]:
		var sl := SpotLight3D.new()
		sl.position = Vector3(x * sx, y, z)
		sl.light_color = Color(1.0, 0.93, 0.78)
		sl.spot_range = 35.0
		sl.spot_angle = 35.0
		sl.light_energy = 2.5
		sl.shadow_enabled = false
		sl.visible = false
		parent.add_child(sl)
		_headlights.append(sl)


## Thin dark vertical seam — reads as a door shut-line without cutting real geometry
## (flat-shaded low-poly trick: a proud dark sliver, not a boolean cut).
func _seam_v(parent: Node3D, x: float, y: float, z: float, h: float) -> void:
	car._panel(parent, Vector3(0.025, h, 0.025), Vector3(x, y, z), Color(0.04, 0.04, 0.05), 0.9)

## Thin dark horizontal seam — hood/trunk shut-lines, beltline breaks.
func _seam_h(parent: Node3D, x: float, y: float, z: float, w: float) -> void:
	car._panel(parent, Vector3(w, 0.02, 0.025), Vector3(x, y, z), Color(0.04, 0.04, 0.05), 0.9)

## A small proud door handle.
func _door_handle(parent: Node3D, x: float, y: float, z: float) -> void:
	car._panel(parent, Vector3(0.03, 0.045, 0.16), Vector3(x, y, z), Color(0.15, 0.15, 0.17), 0.3, 0.5)

## A license plate plaque (front or rear).
func _plate(parent: Node3D, x: float, y: float, z: float) -> void:
	car._panel(parent, Vector3(0.32, 0.15, 0.02), Vector3(x, y, z), Color(0.86, 0.84, 0.72), 0.6)
	# Every ride is registered to the owner. (His Rocket League handle — ask him.)
	var tag := Label3D.new()
	tag.text = "MILKY"
	tag.font_size = 44
	tag.pixel_size = 0.0022
	tag.modulate = Color(0.16, 0.2, 0.38)
	tag.outline_size = 0
	tag.position = Vector3(x, y, z + signf(z) * 0.015)
	tag.rotation.y = 0.0 if z > 0.0 else PI
	parent.add_child(tag)

## Rounded fenders / arches sitting above each of the four wheels (x≈±0.9, z≈±1.4).
func _build_fenders(paint: Color, rubber: Color) -> void:
	for sx in [-1.0, 1.0]:
		for sz in [-1.4, 1.4]:
			# arch top (flatter box) + a forward and rear wedge to round the arch
			var fx: float = 0.92 * sx
			car._panel(_body_root, Vector3(0.34, 0.26, 1.1), Vector3(fx, 0.78, sz), paint, 0.35, 0.6)
			for ez in [-0.5, 0.5]:
				var w := _prism(_body_root, Vector3(0.34, 0.34, 0.4), Vector3(fx, 0.66, sz + ez), paint, 0.35, 0.6)
				w.rotation_degrees = Vector3(90 if ez > 0.0 else -90, 0, 0)
			# black inner arch liner so the wheel reads as tucked under the fender
			car._panel(_body_root, Vector3(0.22, 0.16, 0.9), Vector3(fx, 0.62, sz), rubber, 0.9)

## Chrome trim strips along the bodyside spear + a beltline molding.
func _build_chrome_trim() -> void:
	for sx in [-1.0, 1.0]:
		var strip := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.05, 0.08, 3.3)
		strip.mesh = bm
		strip.material_override = car._chrome(0.12)
		strip.position = Vector3(0.93 * sx, 0.66, 0.0)
		_body_root.add_child(strip)
	# beltline molding around the cockpit opening top edge
	for sx2 in [-1.0, 1.0]:
		var belt := MeshInstance3D.new()
		var bbm := BoxMesh.new()
		bbm.size = Vector3(0.06, 0.06, 1.7)
		belt.mesh = bbm
		belt.material_override = car._chrome(0.12)
		belt.position = Vector3(0.8 * sx2, 1.22, 0.2)
		_body_root.add_child(belt)

## Chrome front & rear bumpers (a bar + over-riders).
func _build_bumpers() -> void:
	# front bumper (-Z)
	_chrome_cyl(_body_root, 0.09, 1.7, Vector3(0, 0.6, -1.92), Vector3(0, 0, 90))
	for sx in [-0.55, 0.55]:
		car._panel(_body_root, Vector3(0.12, 0.32, 0.12), Vector3(sx, 0.62, -1.92), Color(0.92, 0.93, 0.96), 0.1, 1.0)
	# rear bumper (+Z)
	_chrome_cyl(_body_root, 0.09, 1.7, Vector3(0, 0.66, 1.92), Vector3(0, 0, 90))
	for sx2 in [-0.55, 0.55]:
		car._panel(_body_root, Vector3(0.12, 0.32, 0.12), Vector3(sx2, 0.68, 1.92), Color(0.92, 0.93, 0.96), 0.1, 1.0)

## A chrome-framed front grille with vertical slats.
func _build_grille() -> void:
	# grille surround
	car._panel(_body_root, Vector3(1.05, 0.5, 0.08), Vector3(0, 0.86, -1.86), Color(0.92, 0.93, 0.96), 0.12, 1.0)
	# dark recess
	car._panel(_body_root, Vector3(0.92, 0.4, 0.06), Vector3(0, 0.86, -1.84), Color(0.04, 0.04, 0.05), 0.6)
	# vertical chrome slats
	for i in range(7):
		var x := -0.4 + i * 0.133
		var slat := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.04, 0.38, 0.05)
		slat.mesh = bm
		slat.material_override = car._chrome(0.15)
		slat.position = Vector3(x, 0.86, -1.86)
		_body_root.add_child(slat)

## Emissive warm headlights (front) + emissive red taillights (rear).
func _build_car_lights() -> void:
	# headlights with chrome bezels
	for sx in [-0.66, 0.66]:
		_chrome_cyl(_body_root, 0.17, 0.1, Vector3(sx, 0.9, -1.86), Vector3(90, 0, 0), 0.15)
		var hl := _emit_panel(_body_root, Vector3(0.24, 0.24, 0.06), Vector3(sx, 0.9, -1.9), Color(1.0, 0.95, 0.72), 1.8)
		var hm: StandardMaterial3D = hl.material_override
		hm.albedo_color = Color(1.0, 0.97, 0.85)
	# taillights
	for sx2 in [-0.66, 0.66]:
		_emit_panel(_body_root, Vector3(0.26, 0.16, 0.06), Vector3(sx2, 0.92, 1.9), Color(0.95, 0.06, 0.05), 1.7)

## Two side mirrors on chrome stalks.
func _build_mirrors() -> void:
	for sx in [-1.0, 1.0]:
		var stalk := _chrome_cyl(_body_root, 0.025, 0.26, Vector3(0.95 * sx, 1.18, -0.45), Vector3(0, 0, 55 * sx))
		var head := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.04, 0.16, 0.22)
		head.mesh = bm
		head.material_override = car._chrome(0.12)
		head.position = Vector3(1.08 * sx, 1.26, -0.45)
		_body_root.add_child(head)
		# the mirror glass face
		car._panel(_body_root, Vector3(0.02, 0.12, 0.18), Vector3(1.06 * sx, 1.26, -0.45), Color(0.6, 0.7, 0.8), 0.05, 0.9)

## Twin chrome exhaust tips out the back (+Z).
func _build_exhausts() -> void:
	for sx in [-0.45, 0.45]:
		# pipe running under the rocker
		_chrome_cyl(_body_root, 0.07, 1.0, Vector3(sx, 0.4, 1.4), Vector3(90, 0, 0))
		# flared tip poking past the bumper
		var tip := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.11
		cm.bottom_radius = 0.08
		cm.height = 0.3
		tip.mesh = cm
		tip.material_override = car._chrome(0.08)
		tip.rotation_degrees = Vector3(90, 0, 0)
		tip.position = Vector3(sx, 0.4, 2.0)
		_body_root.add_child(tip)

## Windshield: chrome frame + angled posts + a semi-transparent glass pane.
func _build_windshield() -> void:
	var dark := Color(0.08, 0.08, 0.1)
	# glass pane
	var ws := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.3, 0.52, 0.04)
	ws.mesh = bm
	ws.material_override = _glass(0.26)
	ws.position = Vector3(0, 1.36, -0.55)
	ws.rotation_degrees = Vector3(-24, 0, 0)
	_body_root.add_child(ws)
	# chrome top frame
	var topf := MeshInstance3D.new()
	var tbm := BoxMesh.new()
	tbm.size = Vector3(1.34, 0.06, 0.06)
	topf.mesh = tbm
	topf.material_override = car._chrome(0.12)
	topf.position = Vector3(0, 1.58, -0.65)
	topf.rotation_degrees = Vector3(-24, 0, 0)
	_body_root.add_child(topf)
	# angled posts
	for sx in [-0.64, 0.64]:
		var post := car._panel(_body_root, Vector3(0.06, 0.6, 0.06), Vector3(sx, 1.34, -0.55), dark, 0.2, 0.6)
		post.rotation_degrees = Vector3(-24, 0, 0)

## A simple dashboard, steering wheel and bucket seat in the open cockpit.
func _build_cockpit() -> void:
	var dark := Color(0.08, 0.08, 0.1)
	var leather := Color(0.14, 0.1, 0.09)
	# dashboard
	car._panel(_body_root, Vector3(1.35, 0.2, 0.3), Vector3(0, 1.14, -0.32), dark, 0.5)
	# two round gauges (emissive faint)
	for sx in [-0.25, 0.25]:
		var g := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.08
		cm.bottom_radius = 0.08
		cm.height = 0.04
		g.mesh = cm
		var gm := StandardMaterial3D.new()
		gm.albedo_color = Color(0.6, 0.75, 0.85)
		gm.emission_enabled = true
		gm.emission = Color(0.3, 0.5, 0.6)
		gm.emission_energy_multiplier = 0.6
		g.material_override = gm
		g.position = Vector3(sx, 1.2, -0.18)
		g.rotation_degrees = Vector3(70, 0, 0)
		_body_root.add_child(g)
	# steering column + wheel
	var col := _chrome_cyl(_body_root, 0.025, 0.4, Vector3(0, 1.08, 0.0), Vector3(70, 0, 0))
	var wheel := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.13
	tm.outer_radius = 0.19
	wheel.mesh = tm
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = leather
	wmat.roughness = 0.6
	wheel.material_override = wmat
	wheel.position = Vector3(0, 1.18, 0.12)
	wheel.rotation_degrees = Vector3(70, 0, 0)
	_body_root.add_child(wheel)
	# bucket seat: cushion + seat back
	car._panel(_body_root, Vector3(0.5, 0.12, 0.5), Vector3(0, 0.88, 0.45), leather, 0.7)
	car._panel(_body_root, Vector3(0.55, 0.55, 0.14), Vector3(0, 1.1, 0.66), leather, 0.7)
	car._panel(_body_root, Vector3(0.5, 0.14, 0.46), Vector3(0, 0.86, 0.45), Color(0.05, 0.05, 0.06), 0.85)  # seat base shadow
