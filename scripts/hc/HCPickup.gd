extends Area3D
## A collectible floating along the road / over the gap jumps. Three flavours:
## coin (cash), fuel (refill), nitro (boost). Built entirely in code so there's no
## scene dependency. The player car is a RigidBody3D on physics layer 1 that adds
## itself to the "car" group in _ready; this Area3D monitors layer 1 and only reacts
## to that body, emitting `collected(kind, value)` then freeing itself.

signal collected(kind: String, value: float)

var kind := "coin"            ## "coin" | "fuel" | "nitro"
var value := 0.0              ## payout amount (cash / fuel units / nitro amount)

var _spin := true             ## coins & nitro spin for visual life
var _bob := true              ## coins & nitro bob gently up/down (fuel sits still)
var _bob_phase := 0.0
var _glint_phase := 0.0       ## offsets the periodic sparkle so a row of pickups doesn't flash in lockstep
var _glint_mesh: MeshInstance3D
var _visual: Node3D           ## the mesh lives here, NOT on self — bobbing must never move the Area3D (would shift the collision sphere)

const GLINT_PERIOD := 2.0     ## seconds between sparkle flashes
const GLINT_FLASH := 0.22     ## how long the flash lasts within that period

# Shared per-kind meshes/materials, built ONCE and reused by every pickup instance —
# cheap even with a dense field of coins streamed along the road (see CLAUDE.md:
# reuse shared Mesh/Material resources instead of building per-instance).
static var _mesh_cache: Dictionary = {}
static var _mat_cache: Dictionary = {}

## Factory: build a ready-to-add pickup of the given kind/value.
static func make(p_kind: String, p_value: float) -> Area3D:
	var pu := new()
	pu.setup(p_kind, p_value)
	return pu

## Configure kind/value and build the visual mesh + collision. Call right after new()
## (the factory does this for you) BEFORE adding to the tree.
func setup(p_kind: String, p_value: float) -> void:
	kind = p_kind
	value = p_value

func _ready() -> void:
	# Detect the car body (layer 1) without being a physics obstacle itself.
	collision_layer = 0
	collision_mask = 1
	monitoring = true
	_build_visual()
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.2
	shape.shape = sphere
	add_child(shape)
	body_entered.connect(_on_body_entered)

static func _mesh(key: String, builder: Callable) -> Mesh:
	if not _mesh_cache.has(key):
		_mesh_cache[key] = builder.call()
	return _mesh_cache[key]

static func _mat(key: String, builder: Callable) -> StandardMaterial3D:
	if not _mat_cache.has(key):
		_mat_cache[key] = builder.call()
	return _mat_cache[key]

## Build the in-code mesh for this kind. Each kind gets a distinct silhouette + color
## identity (gold coin wheel / red jerry-can / cyan boost bottle) at the same juice
## level: a proper low-poly read, an emissive rim/accent, and a periodic glint.
func _build_visual() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	_bob_phase = randf() * TAU     # random phase so a row of pickups doesn't bob in lockstep
	_glint_phase = randf() * GLINT_PERIOD
	match kind:
		"fuel":
			_spin = false
			_bob = false
			_build_fuel()
		"nitro":
			_build_nitro()
		_:
			_build_coin()

## Coin: chamfered-read cylinder (body + a bright rim ring standing slightly proud of
## the face) with an embossed inner disc, gold metallic material, subtle emissive rim
## so it reads at distance and at night.
func _build_coin() -> void:
	# stand the coin on edge so the spin reads as a flipping coin; rotate the whole
	# _visual (not just one mesh) so body/rim/inner/glint all tip together
	_visual.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
	var body_mesh := _mesh("coin_body", func():
		var c := CylinderMesh.new()
		c.top_radius = 0.62; c.bottom_radius = 0.62; c.height = 0.12
		c.radial_segments = 20
		return c)
	var body_mat := _mat("coin_body", func():
		var m := StandardMaterial3D.new()
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.albedo_color = Color(0.95, 0.76, 0.18)
		m.metallic = 0.9; m.roughness = 0.28
		m.emission_enabled = true
		m.emission = Color(0.85, 0.55, 0.05)
		m.emission_energy_multiplier = 0.3
		return m)
	var body := MeshInstance3D.new(); body.mesh = body_mesh; body.material_override = body_mat
	_visual.add_child(body)
	# chamfer read: a flattened torus standing proud of the rim edge
	var rim_mesh := _mesh("coin_rim", func():
		var t := TorusMesh.new()
		t.inner_radius = 0.50; t.outer_radius = 0.72
		t.rings = 6; t.ring_segments = 14
		return t)
	var rim_mat := _mat("coin_rim", func():
		var m := StandardMaterial3D.new()
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.albedo_color = Color(1.0, 0.86, 0.35)
		m.metallic = 0.95; m.roughness = 0.2
		m.emission_enabled = true
		m.emission = Color(1.0, 0.75, 0.2)
		m.emission_energy_multiplier = 0.55
		return m)
	var rim := MeshInstance3D.new(); rim.mesh = rim_mesh; rim.material_override = rim_mat
	rim.scale = Vector3(1.0, 1.0, 0.55)   # squash the torus tube so it hugs the coin's edge
	_visual.add_child(rim)
	# embossed inner disc: proud of both faces, brighter gold — the coin's "face"
	var inner_mesh := _mesh("coin_inner", func():
		var c := CylinderMesh.new()
		c.top_radius = 0.36; c.bottom_radius = 0.36; c.height = 0.16
		c.radial_segments = 14
		return c)
	var inner_mat := _mat("coin_inner", func():
		var m := StandardMaterial3D.new()
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.albedo_color = Color(1.0, 0.92, 0.55)
		m.metallic = 0.85; m.roughness = 0.22
		m.emission_enabled = true
		m.emission = Color(1.0, 0.85, 0.4)
		m.emission_energy_multiplier = 0.5
		return m)
	var inner := MeshInstance3D.new(); inner.mesh = inner_mesh; inner.material_override = inner_mat
	_visual.add_child(inner)
	_add_glint(Color(1.0, 0.95, 0.7), Vector3(0.62, 0.0, 0.08))

## Fuel: a jerry-can silhouette (boxy body + spout + carry handle) — matte warning red,
## sits still on the road so it reads as "grab this, don't dodge it".
func _build_fuel() -> void:
	var body_mesh := _mesh("fuel_body", func():
		var b := BoxMesh.new()
		b.size = Vector3(0.82, 0.95, 0.55)
		return b)
	var body_mat := _mat("fuel_body", func():
		var m := StandardMaterial3D.new()
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.albedo_color = Color(0.82, 0.16, 0.14)
		m.metallic = 0.15; m.roughness = 0.55
		m.emission_enabled = true
		m.emission = Color(0.5, 0.06, 0.04)
		m.emission_energy_multiplier = 0.35
		return m)
	var body := MeshInstance3D.new(); body.mesh = body_mesh; body.material_override = body_mat
	_visual.add_child(body)
	var spout_mesh := _mesh("fuel_spout", func():
		var c := CylinderMesh.new()
		c.top_radius = 0.09; c.bottom_radius = 0.11; c.height = 0.24
		c.radial_segments = 10
		return c)
	var steel_mat := _mat("fuel_steel", func():
		var m := StandardMaterial3D.new()
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.albedo_color = Color(0.22, 0.2, 0.19)
		m.metallic = 0.5; m.roughness = 0.5
		return m)
	var spout := MeshInstance3D.new(); spout.mesh = spout_mesh; spout.material_override = steel_mat
	spout.position = Vector3(0.28, 0.58, 0.0)
	_visual.add_child(spout)
	var handle_mesh := _mesh("fuel_handle", func():
		var t := TorusMesh.new()
		t.inner_radius = 0.06; t.outer_radius = 0.15
		t.rings = 5; t.ring_segments = 10
		return t)
	var handle := MeshInstance3D.new(); handle.mesh = handle_mesh; handle.material_override = steel_mat
	handle.position = Vector3(-0.1, 0.5, 0.0)
	handle.rotation = Vector3(0.0, 0.0, deg_to_rad(90.0))
	_visual.add_child(handle)
	_add_glint(Color(1.0, 0.55, 0.15), Vector3(0.0, 0.4, 0.29))

## Nitro: a boost bottle (tapered body + a dark nozzle cap) — cyan metallic with a
## bright emissive glow, the loudest-reading of the three since it's the rarest.
func _build_nitro() -> void:
	var body_mesh := _mesh("nitro_body", func():
		var c := CylinderMesh.new()
		c.top_radius = 0.18; c.bottom_radius = 0.32; c.height = 1.1
		c.radial_segments = 12
		return c)
	var body_mat := _mat("nitro_body", func():
		var m := StandardMaterial3D.new()
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.albedo_color = Color(0.15, 0.75, 0.92)
		m.metallic = 0.45; m.roughness = 0.28
		m.emission_enabled = true
		m.emission = Color(0.1, 0.7, 0.95)
		m.emission_energy_multiplier = 0.95
		return m)
	var body := MeshInstance3D.new(); body.mesh = body_mesh; body.material_override = body_mat
	_visual.add_child(body)
	var cap_mesh := _mesh("nitro_cap", func():
		var c := CylinderMesh.new()
		c.top_radius = 0.09; c.bottom_radius = 0.15; c.height = 0.22
		c.radial_segments = 10
		return c)
	var cap_mat := _mat("nitro_cap", func():
		var m := StandardMaterial3D.new()
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.albedo_color = Color(0.12, 0.13, 0.15)
		m.metallic = 0.6; m.roughness = 0.35
		return m)
	var cap := MeshInstance3D.new(); cap.mesh = cap_mesh; cap.material_override = cap_mat
	cap.position = Vector3(0.0, 0.65, 0.0)
	_visual.add_child(cap)
	_add_glint(Color(0.5, 0.95, 1.0), Vector3(0.0, 0.75, 0.2))

## A small unshaded billboard quad that stays hidden except for a brief periodic
## flash — a cheap "glint" that reads as sunlight/streetlight catching the pickup
## without a real-time reflection probe. Position is LOCAL to _visual, so on a
## spinning pickup (coin/nitro) it orbits with the mesh; on a still one (fuel) it
## just blinks in place like a warning light.
func _add_glint(color: Color, local_pos: Vector3) -> void:
	var quad_mesh := _mesh("glint_quad", func():
		var q := QuadMesh.new()
		q.size = Vector2(0.3, 0.3)
		return q)
	var mat := StandardMaterial3D.new()   # per-instance: tinted per kind, so not cached
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = color
	_glint_mesh = MeshInstance3D.new()
	_glint_mesh.mesh = quad_mesh
	_glint_mesh.material_override = mat
	_glint_mesh.position = local_pos
	_glint_mesh.visible = false
	_visual.add_child(_glint_mesh)

func _process(delta: float) -> void:
	if _spin:
		rotate_y(delta * 2.5)
	if _bob and _visual:
		# bob the VISUAL child only — moving self would drag the Area3D's collision
		# sphere off the spot the pickup was placed at.
		_bob_phase += delta * 2.4
		_visual.position.y = sin(_bob_phase) * 0.14
	if _glint_mesh:
		var t := fmod(Time.get_ticks_msec() / 1000.0 + _glint_phase, GLINT_PERIOD)
		var show := t < GLINT_FLASH
		_glint_mesh.visible = show
		if show:
			var k := t / GLINT_FLASH
			var s := 1.0 - absf(k * 2.0 - 1.0)   # triangular ramp up then down
			_glint_mesh.scale = Vector3.ONE * lerpf(0.5, 1.4, s)

func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("car"):
		return
	collected.emit(kind, value)
	_spawn_collect_burst()
	queue_free()

## Gold sparks for a coin, red for fuel, cyan for nitro.
func _burst_color() -> Color:
	match kind:
		"fuel":
			return Color(0.95, 0.18, 0.14)
		"nitro":
			return Color(0.15, 0.85, 0.95)
		_:
			return Color(1.0, 0.84, 0.2)

## How many spark particles per kind — coin is the most common pickup and gets the
## showiest burst; fuel (a "utility" grab) is a touch more restrained.
func _burst_amount() -> int:
	match kind:
		"fuel":
			return 20
		"nitro":
			return 28
		_:
			return 32

## A brief one-shot spark burst PLUS an expanding emissive ring on collect. We free
## ourselves immediately (the collision needs to vanish right away), so both effects
## are parented to OUR parent instead and self-destruct once done — nothing left to
## clean up, no dangling reference back to us.
func _spawn_collect_burst() -> void:
	var host := get_parent()
	if host == null:
		return
	var pos := global_position   # capture before queue_free (we're still in-tree here)
	var col := _burst_color()
	_spawn_spark_particles(host, pos, col)
	_spawn_expanding_ring(host, pos, col)

func _spawn_spark_particles(host: Node, pos: Vector3, col: Color) -> void:
	var g := GPUParticles3D.new()
	g.amount = _burst_amount()
	g.lifetime = 0.55
	g.one_shot = true
	g.explosiveness = 0.9
	g.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0   # burst outward in every direction
	pm.gravity = Vector3(0, -6.0, 0)
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 5.5
	pm.scale_min = 0.16
	pm.scale_max = 0.4
	var grad := Gradient.new()
	grad.set_color(0, Color(col.r, col.g, col.b, 1.0))
	grad.set_color(1, Color(col.r, col.g, col.b, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = grad
	pm.color_ramp = gt
	g.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.22, 0.22)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(1, 1, 1)
	qm.material = m
	g.draw_pass_1 = qm
	host.add_child(g)
	g.global_position = pos
	g.emitting = true
	g.finished.connect(g.queue_free)

## A flat expanding+fading emissive ring — the "pop" that reads even at a glance from
## the chase camera, distinct from the particle spray (which reads best up close).
func _spawn_expanding_ring(host: Node, pos: Vector3, col: Color) -> void:
	var ring_mesh := _mesh("burst_ring", func():
		var t := TorusMesh.new()
		t.inner_radius = 0.55; t.outer_radius = 0.78
		t.rings = 4; t.ring_segments = 18
		return t)
	var mat := StandardMaterial3D.new()   # per-burst: alpha gets tweened, can't be shared
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(col.r, col.g, col.b, 1.0)
	var ring := MeshInstance3D.new()
	ring.mesh = ring_mesh
	ring.material_override = mat
	# TorusMesh already lies flat in the XZ plane (hole axis = Y) — no rotation
	# needed, this is what makes it read as a ground-hugging shockwave ring.
	ring.scale = Vector3.ONE * 0.4
	host.add_child(ring)
	ring.global_position = pos
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * 2.6, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(ring.queue_free)
