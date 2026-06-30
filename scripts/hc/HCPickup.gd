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
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	match kind:
		"fuel":
			_spin = false
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
	add_child(mi)

func _process(delta: float) -> void:
	if _spin:
		rotate_y(delta * 2.5)

func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("car"):
		return
	collected.emit(kind, value)
	queue_free()
