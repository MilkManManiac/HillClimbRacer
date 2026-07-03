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
var _visual: Node3D           ## the mesh lives here, NOT on self — bobbing must never move the Area3D (would shift the collision sphere)

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

## Build the in-code mesh for this kind.
func _build_visual() -> void:
	_visual = Node3D.new()
	add_child(_visual)
	_bob_phase = randf() * TAU   # random phase so a row of pickups doesn't bob in lockstep
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	match kind:
		"fuel":
			_spin = false
			_bob = false
			var box := BoxMesh.new()
			box.size = Vector3(0.9, 1.1, 0.6)
			mi.mesh = box
			mat.albedo_color = Color(0.82, 0.16, 0.14)
			mat.metallic = 0.2
			mat.roughness = 0.5
			mat.emission_enabled = true
			mat.emission = Color(0.4, 0.05, 0.04)
			mat.emission_energy_multiplier = 0.3
		"nitro":
			var bottle := CylinderMesh.new()
			bottle.top_radius = 0.18
			bottle.bottom_radius = 0.32
			bottle.height = 1.2
			bottle.radial_segments = 10
			mi.mesh = bottle
			mat.albedo_color = Color(0.15, 0.75, 0.92)
			mat.metallic = 0.4
			mat.roughness = 0.3
			mat.emission_enabled = true
			mat.emission = Color(0.1, 0.7, 0.95)
			mat.emission_energy_multiplier = 0.9
		_:  # coin
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.7
			cyl.bottom_radius = 0.7
			cyl.height = 0.14
			cyl.radial_segments = 16
			mi.mesh = cyl
			# stand the coin on edge so the spin reads as a flipping coin
			mi.rotation = Vector3(deg_to_rad(90.0), 0.0, 0.0)
			mat.albedo_color = Color(1.0, 0.82, 0.2)
			mat.metallic = 0.9
			mat.roughness = 0.25
			mat.emission_enabled = true
			mat.emission = Color(0.9, 0.6, 0.05)
			mat.emission_energy_multiplier = 0.35
	mi.material_override = mat
	_visual.add_child(mi)

func _process(delta: float) -> void:
	if _spin:
		rotate_y(delta * 2.5)
	if _bob and _visual:
		# bob the VISUAL child only — moving self would drag the Area3D's collision
		# sphere off the spot the pickup was placed at.
		_bob_phase += delta * 2.4
		_visual.position.y = sin(_bob_phase) * 0.14

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

## A brief one-shot spark burst on collect. We free ourselves immediately (the
## collision needs to vanish right away), so the burst is parented to OUR parent
## instead and self-destructs once its one-shot particles finish (`finished`
## signal) — nothing left to clean up, no dangling reference back to us.
func _spawn_collect_burst() -> void:
	var host := get_parent()
	if host == null:
		return
	var pos := global_position   # capture before queue_free (we're still in-tree here)
	var g := GPUParticles3D.new()
	g.amount = 22
	g.lifetime = 0.5
	g.one_shot = true
	g.explosiveness = 0.9
	g.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0   # burst outward in every direction
	pm.gravity = Vector3(0, -6.0, 0)
	pm.initial_velocity_min = 2.0
	pm.initial_velocity_max = 5.0
	pm.scale_min = 0.16
	pm.scale_max = 0.38
	var col := _burst_color()
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
