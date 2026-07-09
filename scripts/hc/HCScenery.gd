extends Node3D
## Distant background scenery: 2-3 concentric rings of huge, cheap, unshaded silhouette
## ridgelines/skylines around the play area — the classic "reads huge, costs nothing"
## depth trick. Owned entirely by this file; HCMain just calls configure(cfg) once per
## map (boot + every map switch) and update_follow() every frame.
##
## The track winds for kilometres in ANY direction (not a fixed -z corridor), and only
## meshes a narrow ribbon either side of the road — everywhere else is empty out to the
## horizon. Fixed world-space geometry would eventually fall behind (or never cover the
## sides at all), so this node's XZ position is loosely re-centred on the car every
## frame (see update_follow): the rings are far and tall enough that the recentring is
## imperceptible frame-to-frame, but the horizon is never empty no matter how far or
## which way a run travels.

const SEG := 40                  # verts per ring; 3 rings * 2*SEG tris is trivially cheap
const FOLLOW_RATE := 0.5         # exp-smoothing rate for the loose XZ follow (see update_follow)
const BAND_R := [520.0, 900.0, 1400.0]      # ring radii, near -> far
const BAND_BASE_Y := [-6.0, 8.0, 24.0]      # ring base height, far bands sit a bit higher (reads as taller/further)
const BAND_DEPTH := [220.0, 260.0, 320.0]   # how far the ring skirt extends below its base (hides any seam)

# --- ambient-life tuning (near/mid-field layer, cheap, re-centres with the same rig) --
const BIRD_COUNT := 4
const BIRD_RADIUS := [100.0, 220.0]      # local orbit-centre distance, midfield (well short of the near ring at 520)
const BIRD_HEIGHT := [14.0, 38.0]        # world Y, kept low: the visible sky sliver above the road horizon is
                                          # shallow in the chase camera, so anything much higher renders off-frame
const STAR_INTERVAL := [20.0, 40.0]      # seconds between Midnight Run shooting stars
const STAR_DURATION := 1.2               # streak sweep time once triggered

var _style := "hills"
var _seeded := false
var _t_accum := 0.0              # shared animation clock, advanced once per update_follow tick

# hills: circling chevron "birds" -- Array[Dictionary] of {mi, center, radius, height, speed, phase, bob}
var _birds: Array = []
# gravity: crane/stack beacons that breathe -- Array[Dictionary] of {mat, base, phase}
var _beacon_pulses: Array = []
# midnight: rare shooting-star streak state
var _star_mesh: MeshInstance3D
var _star_mat: StandardMaterial3D
var _star_timer := 0.0
var _star_active := false
var _star_progress := 0.0
var _star_from := Vector3.ZERO
var _star_to := Vector3.ZERO

## Rebuild every band for the given map. cfg (from HCMain._scenery_config()):
##   style: String   -- one of hills/canyon/alpine/midnight/gravity (matches HCMain.MAPS keys)
##   accent: Color    -- the map's UI accent, folded into the palette for a bit of unity
##   night: bool      -- true only for midnight; kept for any future night-flagged map
func configure(cfg: Dictionary) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	# ambient state references the children just freed above -- drop them all before
	# rebuilding, or a leftover reference (e.g. the shooting-star mesh) crashes next use.
	_birds.clear()
	_beacon_pulses.clear()
	_star_mesh = null
	_star_mat = null
	_star_active = false
	_star_progress = 0.0
	_star_timer = randf_range(STAR_INTERVAL[0], STAR_INTERVAL[1])
	_style = str(cfg.get("style", "hills"))
	var accent: Color = cfg.get("accent", Color(0.7, 0.75, 0.7))
	match _style:
		"canyon":
			_build_canyon(accent)
		"alpine":
			_build_alpine(accent)
		"midnight":
			_build_midnight(accent)
		"gravity":
			_build_gravity(accent)
		_:
			_build_hills(accent)
	# per-map near/mid-field ambient life layer -- keyed off the same `style` HCMain
	# already passes in (see _scenery_config); each builder is CHEAP (a handful of
	# meshes or one small GPUParticles3D box) and re-centres for free as a child of
	# this node (see update_follow).
	match _style:
		"canyon":
			_build_dust(accent)
		"alpine":
			_build_snow()
		"midnight":
			_build_fireflies(accent)
		"gravity":
			_build_embers(accent)
		_:
			_build_birds(accent)

## Loosely re-centre the whole scenery rig over the car's XZ every frame. Only X/Z
## follow (Y stays fixed) so the bands read as a stable horizon, not something bobbing
## with the car's jumps. First call snaps instantly (nothing to lag from yet).
func update_follow(car_pos: Vector3, delta: float) -> void:
	if not _seeded:
		global_position = Vector3(car_pos.x, global_position.y, car_pos.z)
		_seeded = true
		return
	var want := Vector3(car_pos.x, global_position.y, car_pos.z)
	global_position = global_position.lerp(want, 1.0 - exp(-FOLLOW_RATE * delta))
	_t_accum += delta
	match _style:
		"hills":
			_animate_birds()
		"gravity":
			_animate_beacons()
		"midnight":
			_animate_shooting_star(delta)

# --- per-map shapes ------------------------------------------------------------

## Rolling Hills: soft green sweeps, three bands rising and hazing toward the horizon.
func _build_hills(accent: Color) -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 5001
	# aerial-perspective palette: a darker near ridge (contrasts with the bright
	# foreground grass) fading to a cool BLUE-grey haze, not more green — matching
	# hue against the grass is what made the very first pass invisible.
	var haze := Color(0.70, 0.78, 0.85)
	var near := Color(0.16, 0.30, 0.16).lerp(accent, 0.15)
	var mid := near.lerp(haze, 0.45)
	var far := near.lerp(haze, 0.8)
	_ring(0, _rolling(rng, 45.0, 80.0, 1.0), near)
	_ring(1, _rolling(rng, 65.0, 110.0, 0.7), mid)
	_ring(2, _rolling(rng, 85.0, 140.0, 0.45), far)

## Sunset Canyon: blocky red-sandstone mesas — flat-topped plateaus, warm and dusty.
func _build_canyon(accent: Color) -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 5002
	var haze := Color(0.86, 0.60, 0.42)
	var near := Color(0.55, 0.28, 0.16).lerp(accent, 0.15)
	var mid := near.lerp(haze, 0.4)
	var far := near.lerp(haze, 0.7)
	_ring(0, _mesas(rng, 30.0, 65.0, 6), near)
	_ring(1, _mesas(rng, 45.0, 95.0, 5), mid)
	_ring(2, _mesas(rng, 60.0, 120.0, 4), far)

## Alpine Ridge: jagged snow peaks — high-frequency spiky silhouette, whiter at the tips.
func _build_alpine(accent: Color) -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 5003
	var rock := Color(0.32, 0.36, 0.44).lerp(accent, 0.15)
	var snow := Color(0.94, 0.96, 1.0)
	var haze := Color(0.80, 0.86, 0.97)
	for b in range(3):
		var min_h := 50.0 + float(b) * 25.0
		var max_h := 100.0 + float(b) * 45.0
		var heights := _jagged(rng, min_h, max_h, 2.2 - float(b) * 0.4)
		_ring_snowcap(b, heights, rock.lerp(haze, float(b) * 0.28), snow, max_h)

## Midnight Run: a lit city skyline — blocky towers with warm window-dots against the night.
func _build_midnight(accent: Color) -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 5004
	var near := Color(0.05, 0.06, 0.10)
	var mid := Color(0.03, 0.04, 0.09)
	var far := Color(0.02, 0.03, 0.08)
	var h0 := _buildings(rng, 20.0, 60.0)
	var h1 := _buildings(rng, 30.0, 85.0)
	var h2 := _buildings(rng, 40.0, 110.0)
	_ring(0, h0, near)
	_ring(1, h1, mid)
	_ring(2, h2, far)
	var window_col := accent.lerp(Color(1.0, 0.85, 0.5), 0.6)
	_windows(0, h0, window_col, 140)
	_windows(1, h1, window_col, 100)

## Gravity Works: an industrial horizon — low ridgeline plus scattered crane/stack silhouettes.
func _build_gravity(accent: Color) -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 5005
	var base := Color(0.40, 0.38, 0.35)
	_ring(0, _mesas(rng, 18.0, 32.0, 11), base)
	_ring(1, _mesas(rng, 24.0, 40.0, 8), base.lerp(Color(0.62, 0.60, 0.56), 0.4))
	_ring(2, _mesas(rng, 30.0, 50.0, 6), base.lerp(Color(0.78, 0.76, 0.72), 0.7))
	var beacon := accent.lerp(Color(1.0, 0.85, 0.4), 0.5)
	var n_props := 16
	for i in range(n_props):
		var ang := TAU * float(i) / float(n_props) + rng.randf_range(-0.2, 0.2)
		# near band 0's radius (520) — close enough to stand proud of the ridge, far
		# enough that a 100 m mast doesn't tower over roadside trees like a glitch
		var r := rng.randf_range(450.0, 600.0)
		var pos := Vector3(cos(ang) * r, 0.0, sin(ang) * r)
		if rng.randf() < 0.5:
			_add_crane(pos, rng, beacon)
		else:
			_add_stack(pos, rng, beacon)

# --- ambient life (near/mid-field, per map) ---------------------------------------
# Everything here is either a handful of MeshInstance3Ds animated by hand (birds,
# beacon pulse, shooting star) or one small GPUParticles3D with local_coords = true
# (snow/dust/fireflies/embers), so it's carried along by the SAME loose car-follow
# as the rings above -- nothing streams, nothing chases the car on its own. Kept
# well clear of the road surface (>= 6 m) so nothing reads as an obstacle.

## Rolling Hills: a few small dark chevron "birds" gliding slow circles at midfield
## height -- near enough to read as motion, far enough to never distract from driving.
## Animated every tick in _animate_birds().
func _build_birds(accent: Color) -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 7001
	var mesh := _bird_mesh()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.05, 0.05, 0.06).lerp(accent, 0.1)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for i in range(BIRD_COUNT):
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mi)
		# forward-biased placement: -PI/2 is world -Z (the direction the car/camera
		# faces), spread ~±70 deg across the flock so most of them fall inside a
		# normal forward FOV instead of orbiting out of view half the time
		var ang := -PI / 2.0 + (float(i) - float(BIRD_COUNT - 1) / 2.0) * 0.7 + rng.randf_range(-0.25, 0.25)
		var dist := rng.randf_range(BIRD_RADIUS[0], BIRD_RADIUS[1])
		_birds.append({
			"mi": mi,
			"center": Vector3(cos(ang) * dist, 0.0, sin(ang) * dist),
			"radius": rng.randf_range(30.0, 70.0),
			"height": rng.randf_range(BIRD_HEIGHT[0], BIRD_HEIGHT[1]),
			"speed": rng.randf_range(0.05, 0.11) * (1.0 if rng.randf() < 0.5 else -1.0),
			"phase": rng.randf_range(0.0, TAU),
			"bob": rng.randf_range(3.0, 8.0),
		})

## Small flat chevron silhouette authored in local XY (the "screen plane"), so
## billboarding it toward the car in _animate_birds keeps it readable from any
## camera angle -- a single filled triangle reads as a bird-shaped dart at distance.
func _bird_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# sized against real-world birds-of-prey wingspan (~3-4 m tip to tip) scaled up a
	# little more so a 4-6 px silhouette actually survives at 100-220 m — the same
	# "reads huge, costs nothing" trick as the horizon rings, just at a smaller scale.
	var tip_l := Vector3(-3.4, 0.7, 0.0)
	var center := Vector3(0.0, -1.1, 0.0)
	var tip_r := Vector3(3.4, 0.7, 0.0)
	st.add_vertex(tip_l); st.add_vertex(center); st.add_vertex(tip_r)
	st.generate_normals()
	return st.commit()

## Advance each bird along its slow circular glide path and billboard it toward the
## car -- i.e. toward this node's local origin, since the whole rig re-centres there
## every frame (same "look toward the centre" trick _windows() uses for building dots).
func _animate_birds() -> void:
	for b in _birds:
		var ang: float = b.phase + _t_accum * b.speed
		var pos: Vector3 = b.center + Vector3(cos(ang) * b.radius, b.height + sin(_t_accum * 0.3 + b.phase) * b.bob, sin(ang) * b.radius)
		var to_car := -pos
		if to_car.length() < 0.01:
			to_car = Vector3.FORWARD
		var mi: MeshInstance3D = b.mi
		mi.transform = Transform3D(Basis.looking_at(to_car.normalized(), Vector3.UP), pos)

## Alpine Ridge: gentle, sparse falling snow around the car -- atmosphere, not a
## blizzard. The box is centred a little ahead of the car (-Z, the direction the
## camera looks) and kept low (7-30 m, well above the 6 m obstacle floor) so flakes
## actually cross the visible forward frustum instead of falling somewhere overhead.
func _build_snow() -> void:
	_add_motes(Vector3(0, 18.0, -18.0), Vector3(45.0, 11.0, 45.0), Vector3(0, -1, 0), 12.0,
			3.0, 8.0, 70, Vector2(0.28, 0.28), Color(1, 1, 1, 0.9), false)

## Sunset Canyon: a couple of huge, barely-there warm dust motes drifting slowly up
## out of the canyon just ahead of the car -- texture for the owner's favourite map,
## deliberately NOT touching its fog or tint (only two-to-three soft billboards).
func _build_dust(accent: Color) -> void:
	var warm := Color(0.95, 0.75, 0.5, 0.14).lerp(Color(accent.r, accent.g, accent.b, 0.14), 0.2)
	_add_motes(Vector3(0, 14.0, -15.0), Vector3(28.0, 6.0, 28.0), Vector3(0, 1, 0), 8.0,
			0.5, 14.0, 3, Vector2(9.0, 9.0), warm, false)

## Midnight Run: warm firefly motes drifting near the roadside just ahead of the car
## (kept above the 6 m obstacle-read floor) plus a rare distant shooting star -- see
## _animate_shooting_star. Emissive against the night sky is the whole read.
func _build_fireflies(accent: Color) -> void:
	var warm := accent.lerp(Color(1.0, 0.85, 0.45), 0.6)
	_add_motes(Vector3(0, 9.0, -14.0), Vector3(26.0, 3.0, 26.0), Vector3(0, 1, 0), 40.0,
			0.4, 6.0, 26, Vector2(0.32, 0.32), warm, true)

## Gravity Works: drifting spark/ember motes plus a faint synced pulse on the
## industrial crane/stack beacons -- see _tint_industrial (which populates
## _beacon_pulses) and _animate_beacons.
func _build_embers(accent: Color) -> void:
	var warm := accent.lerp(Color(1.0, 0.45, 0.1), 0.8)
	_add_motes(Vector3(0, 10.0, -14.0), Vector3(28.0, 5.0, 28.0), Vector3(0, 1, 0), 25.0,
			1.4, 5.0, 40, Vector2(0.34, 0.34), warm, true)

## Tiny procedurally-generated radial falloff dot (white RGB, alpha 1 at centre -> 0
## at the rim) -- built once per call (16x16, trivial) so mote billboards read as
## soft round motes/flakes/sparks instead of hard flat squares. No asset dependency:
## this is the whole "texture", generated in code like everything else in this file.
func _dot_texture() -> ImageTexture:
	const PX := 16
	var img := Image.create(PX, PX, false, Image.FORMAT_RGBA8)
	var c := Vector2(PX, PX) * 0.5
	for y in range(PX):
		for x in range(PX):
			var d := (Vector2(x, y) + Vector2(0.5, 0.5)).distance_to(c) / (PX * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a *= a   # softer core-bright, rim-fades falloff
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)

## Shared cheap "drifting motes" rig: a single box-emission GPUParticles3D in this
## node's OWN local space (local_coords = true) so already-emitted particles are
## carried along by the same loose car-follow as the rings -- nothing streams, no
## per-frame respawn logic needed. `preprocess` pre-fills the lifetime so the effect
## is never empty on the very first frame (screenshots included). `visibility_aabb`
## is sized generously (box + max travel distance) since the default auto-computed
## AABB is too small for these wide, slow-moving emission boxes and would cull them.
func _add_motes(center: Vector3, extents: Vector3, direction: Vector3, spread_deg: float,
		speed: float, life: float, amount: int, size: Vector2, color: Color, emissive: bool) -> GPUParticles3D:
	var gp := GPUParticles3D.new()
	gp.amount = amount
	gp.lifetime = life
	gp.preprocess = life
	gp.local_coords = true
	gp.position = center
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = extents
	pm.direction = direction
	pm.spread = spread_deg
	pm.initial_velocity_min = speed * 0.6
	pm.initial_velocity_max = speed * 1.4
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.85
	pm.scale_max = 1.15
	gp.process_material = pm
	var qm := QuadMesh.new()
	qm.size = size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.albedo_texture = _dot_texture()   # soft round falloff -- a flat quad reads as a hard little square otherwise
	if emissive:
		mat.emission_enabled = true
		mat.emission = Color(color.r, color.g, color.b)
		mat.emission_energy_multiplier = 3.2
		mat.emission_texture = mat.albedo_texture
	qm.material = mat
	gp.draw_pass_1 = qm
	gp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gp.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var travel := speed * life * 1.5 + 20.0
	var half := extents + Vector3.ONE * travel
	gp.visibility_aabb = AABB(-half, half * 2.0)
	add_child(gp)
	return gp

## Faint industrial "power pulse": beacons breathe slowly rather than sitting at a
## flat brightness -- cheap (just re-scribbles emission_energy_multiplier on
## materials that already exist) and reads as the site being alive without being gaudy.
func _animate_beacons() -> void:
	for e in _beacon_pulses:
		var mat: StandardMaterial3D = e.mat
		var s: float = 0.55 + 0.45 * sin(_t_accum * 0.6 + e.phase)
		mat.emission_energy_multiplier = e.base * s

## Advance the Midnight Run shooting-star timer; when it fires, sweep a thin emissive
## streak across the far sky over STAR_DURATION seconds, then re-roll the next
## STAR_INTERVAL wait. Rare (~20-40 s) and far (skyline-ring distance) so it never
## competes with the road for attention.
func _animate_shooting_star(delta: float) -> void:
	if _star_active:
		_star_progress += delta / STAR_DURATION
		if _star_progress >= 1.0:
			_star_active = false
			_star_mesh.visible = false
			_star_timer = randf_range(STAR_INTERVAL[0], STAR_INTERVAL[1])
			return
		var pos: Vector3 = _star_from.lerp(_star_to, _star_progress)
		var fade: float = 1.0 - absf(_star_progress * 2.0 - 1.0)   # fade in then out
		var to_car := -pos
		if to_car.length() < 0.01:
			to_car = Vector3.FORWARD
		_star_mesh.transform = Transform3D(Basis.looking_at(to_car.normalized(), Vector3.UP), pos)
		_star_mat.albedo_color.a = fade
		_star_mat.emission_energy_multiplier = 4.0 * fade
		return
	_star_timer -= delta
	if _star_timer <= 0.0:
		_trigger_shooting_star()

## Test-only hook (tests/AmbientShot.gd): the real timer is 20-40 s, far too slow to
## verify in a short screenshot harness, so let the harness force one on demand.
func debug_trigger_star() -> void:
	if _style == "midnight":
		_trigger_shooting_star()

## Build (once) and (re)launch the shooting-star streak from a random point high on
## the far skyline to a nearby point along the sky, fading in-out over its sweep.
func _trigger_shooting_star() -> void:
	if not _star_mesh:
		_star_mesh = MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(60.0, 2.5)
		_star_mat = StandardMaterial3D.new()
		_star_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_star_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_star_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_star_mat.albedo_color = Color(1.0, 1.0, 0.9, 0.0)
		_star_mat.emission_enabled = true
		_star_mat.emission = Color(1.0, 1.0, 0.85)
		qm.material = _star_mat
		_star_mesh.mesh = qm
		_star_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_star_mesh.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(_star_mesh)
	var ang := randf_range(0.0, TAU)
	var r := 1250.0
	var h0 := randf_range(180.0, 260.0)
	_star_from = Vector3(cos(ang) * r, h0, sin(ang) * r)
	var ang2 := ang + randf_range(-0.35, 0.35)
	_star_to = Vector3(cos(ang2) * r, h0 - randf_range(40.0, 90.0), sin(ang2) * r)
	_star_mesh.visible = true
	_star_progress = 0.0
	_star_active = true

# --- height-profile generators ---------------------------------------------------

## Smooth rolling silhouette: two summed sine waves, random phase/frequency per call.
func _rolling(rng: RandomNumberGenerator, min_h: float, max_h: float, freq: float) -> PackedFloat32Array:
	var out := PackedFloat32Array(); out.resize(SEG)
	var f1 := rng.randf_range(1.0, 2.0) * freq
	var f2 := rng.randf_range(2.5, 4.0) * freq
	var p1 := rng.randf_range(0.0, TAU)
	var p2 := rng.randf_range(0.0, TAU)
	for i in range(SEG):
		var a := TAU * float(i) / float(SEG)
		var v := 0.6 * sin(a * f1 + p1) + 0.4 * sin(a * f2 + p2)
		v = (v + 1.0) * 0.5
		out[i] = lerpf(min_h, max_h, v)
	return out

## Blocky flat-topped plateaus: `groups` contiguous runs of a shared random height —
## the sudden jumps between runs read as cliff faces (canyon mesas / gravity rooftops).
func _mesas(rng: RandomNumberGenerator, min_h: float, max_h: float, groups: int) -> PackedFloat32Array:
	var out := PackedFloat32Array(); out.resize(SEG)
	var i := 0
	while i < SEG:
		var h := rng.randf_range(min_h, max_h)
		var w: int = maxi(1, int(SEG / groups))
		for _k in range(w):
			if i >= SEG:
				break
			out[i] = h
			i += 1
	return out

## Fully per-vertex random heights biased toward the extremes (pow curve) for a sharp,
## jagged skyline — alpine's snow peaks.
func _jagged(rng: RandomNumberGenerator, min_h: float, max_h: float, sharpness: float) -> PackedFloat32Array:
	var out := PackedFloat32Array(); out.resize(SEG)
	for i in range(SEG):
		var t := pow(rng.randf(), sharpness)
		out[i] = lerpf(min_h, max_h, t)
	return out

## Narrow variable-width "buildings" with an occasional tall spike tower — a city skyline.
func _buildings(rng: RandomNumberGenerator, min_h: float, max_h: float) -> PackedFloat32Array:
	var out := PackedFloat32Array(); out.resize(SEG)
	var i := 0
	while i < SEG:
		var w := rng.randi_range(1, 3)
		var h := rng.randf_range(min_h, max_h)
		if rng.randf() < 0.12:
			h = max_h * rng.randf_range(1.15, 1.5)
		for _k in range(w):
			if i >= SEG:
				break
			out[i] = h
			i += 1
	return out

# --- mesh builders -----------------------------------------------------------------

## Build ring band `idx` (radius/base-y/depth from the BAND_* tables) from a per-vertex
## height profile. Unshaded + double-sided so distant silhouettes never need exact
## winding math, cast no shadows (they're background, not occluders), and respect the
## environment's depth fog like any other opaque material (the "fog-tinted" read).
func _ring(idx: int, heights: PackedFloat32Array, color: Color) -> void:
	_add_mesh_from(_ring_mesh(BAND_R[idx], BAND_BASE_Y[idx], BAND_DEPTH[idx], heights, color, color))

## Alpine variant: blends each vertex's own color toward `snow` as its height approaches
## the band's max — cheap per-vertex "snow line" without a second material/pass.
func _ring_snowcap(idx: int, heights: PackedFloat32Array, rock: Color, snow: Color, max_h: float) -> void:
	var n := heights.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(n):
		var j := (i + 1) % n
		_quad(st, BAND_R[idx], BAND_BASE_Y[idx], BAND_DEPTH[idx], i, j, n, heights[i], heights[j],
			rock.lerp(snow, pow(clampf(heights[i] / max_h, 0.0, 1.0), 2.0)),
			rock.lerp(snow, pow(clampf(heights[j] / max_h, 0.0, 1.0), 2.0)))
	st.generate_normals()
	_add_mesh_from(st.commit())

func _ring_mesh(radius: float, base_y: float, depth: float, heights: PackedFloat32Array, color_a: Color, color_b: Color) -> ArrayMesh:
	var n := heights.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(n):
		var j := (i + 1) % n
		_quad(st, radius, base_y, depth, i, j, n, heights[i], heights[j], color_a, color_b)
	st.generate_normals()
	return st.commit()

## One skirt quad between ring segments i and j (two triangles, bottom-to-top).
func _quad(st: SurfaceTool, radius: float, base_y: float, depth: float, i: int, j: int, n: int,
		h_i: float, h_j: float, col_i: Color, col_j: Color) -> void:
	var a_i := TAU * float(i) / float(n)
	var a_j := TAU * float(j) / float(n)
	var bi := Vector3(cos(a_i) * radius, base_y - depth, sin(a_i) * radius)
	var ti := Vector3(cos(a_i) * radius, base_y + h_i, sin(a_i) * radius)
	var bj := Vector3(cos(a_j) * radius, base_y - depth, sin(a_j) * radius)
	var tj := Vector3(cos(a_j) * radius, base_y + h_j, sin(a_j) * radius)
	st.set_color(col_i); st.add_vertex(bi)
	st.set_color(col_j); st.add_vertex(bj)
	st.set_color(col_j); st.add_vertex(tj)
	st.set_color(col_i); st.add_vertex(bi)
	st.set_color(col_j); st.add_vertex(tj)
	st.set_color(col_i); st.add_vertex(ti)

func _add_mesh_from(mesh: ArrayMesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true   # the v4 color-fix invariant: unset = washed-out vertex color
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED   # double-sided so winding never matters at this scale
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)
	return mi

## Sparse warm "window" dots on a building band: small unlit emissive quads, oriented
## to face the ring's centre so they read correctly from anywhere inside it. Skips any
## sample that would float above its building's roofline.
func _windows(idx: int, heights: PackedFloat32Array, color: Color, count: int) -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 6000 + idx
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.2, 3.0)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.use_colors = false
	mm.instance_count = count
	var n := heights.size()
	var radius: float = BAND_R[idx] - 1.5
	var base_y: float = BAND_BASE_Y[idx]
	for k in range(count):
		var i := rng.randi_range(0, n - 1)
		var h_cap: float = heights[i]
		if h_cap < 10.0:
			mm.set_instance_transform(k, Transform3D(Basis(), Vector3(0, -10000, 0)))   # park it out of sight
			continue
		var a := TAU * (float(i) + rng.randf()) / float(n)
		var h := rng.randf_range(4.0, h_cap - 4.0)
		var pos := Vector3(cos(a) * radius, base_y + h, sin(a) * radius)
		var to_centre := Vector3(-pos.x, 0.0, -pos.z).normalized()
		var basis := Basis.looking_at(to_centre, Vector3.UP)
		mm.set_instance_transform(k, Transform3D(basis, pos))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.5
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)

## A silhouette construction crane: a mast + a boom, with a small beacon light on top.
func _add_crane(pos: Vector3, rng: RandomNumberGenerator, beacon: Color) -> void:
	var rig := Node3D.new()
	rig.position = pos
	var h := rng.randf_range(70.0, 130.0)
	var mast := MeshInstance3D.new()
	var mast_mesh := BoxMesh.new(); mast_mesh.size = Vector3(4.5, h, 4.5)
	mast.mesh = mast_mesh
	mast.position = Vector3(0, h * 0.5, 0)
	rig.add_child(mast)
	var boom := MeshInstance3D.new()
	var boom_len := rng.randf_range(40.0, 65.0)
	var boom_mesh := BoxMesh.new(); boom_mesh.size = Vector3(boom_len, 3.5, 3.5)
	boom.mesh = boom_mesh
	boom.position = Vector3(boom_len * 0.35, h, 0)
	rig.add_child(boom)
	var beacon_mesh := SphereMesh.new(); beacon_mesh.radius = 1.6; beacon_mesh.height = 3.2
	var beacon_mi := MeshInstance3D.new()
	beacon_mi.mesh = beacon_mesh
	beacon_mi.position = Vector3(0, h + 2.0, 0)
	rig.add_child(beacon_mi)
	_tint_industrial(rig, beacon_mi, beacon)
	add_child(rig)

## A silhouette smokestack: a tall thin cylinder with the same beacon treatment.
func _add_stack(pos: Vector3, rng: RandomNumberGenerator, beacon: Color) -> void:
	var rig := Node3D.new()
	rig.position = pos
	var h := rng.randf_range(60.0, 100.0)
	var stack := MeshInstance3D.new()
	var stack_mesh := CylinderMesh.new()
	stack_mesh.top_radius = 4.5; stack_mesh.bottom_radius = 6.5; stack_mesh.height = h
	stack.mesh = stack_mesh
	stack.position = Vector3(0, h * 0.5, 0)
	rig.add_child(stack)
	var beacon_mesh := SphereMesh.new(); beacon_mesh.radius = 1.4; beacon_mesh.height = 2.8
	var beacon_mi := MeshInstance3D.new()
	beacon_mi.mesh = beacon_mesh
	beacon_mi.position = Vector3(0, h + 1.5, 0)
	rig.add_child(beacon_mi)
	_tint_industrial(rig, beacon_mi, beacon)
	add_child(rig)

## Shared silhouette material for crane/stack meshes, plus a small emissive beacon —
## the one warm accent point against an otherwise flat industrial silhouette.
func _tint_industrial(rig: Node3D, beacon_mi: MeshInstance3D, beacon: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# darker than the ridge bands behind it (0.4-0.78 grey) so it reads as a
	# silhouette, but warm dark grey rather than void-black — pure 0.10 punched
	# through the haze and read as a rendering artifact at play distance
	mat.albedo_color = Color(0.26, 0.24, 0.22)
	for c in rig.get_children():
		if c is MeshInstance3D and c != beacon_mi:
			c.material_override = mat
			c.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			c.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var bmat := StandardMaterial3D.new()
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.albedo_color = beacon
	bmat.emission_enabled = true
	bmat.emission = beacon
	bmat.emission_energy_multiplier = 3.0
	beacon_mi.material_override = bmat
	beacon_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beacon_mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# faint industrial pulse (Gravity Works ambient life): _animate_beacons() breathes
	# this material's emission slowly every frame; random phase so the beacons don't
	# all blink in lockstep.
	_beacon_pulses.append({"mat": bmat, "base": 3.0, "phase": randf() * TAU})
