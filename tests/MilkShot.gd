extends Node
## THROWAWAY: close screenshot of the milk pickup + a car rear plate.

const HCPickupScript := preload("res://scripts/hc/HCPickup.gd")
var _f := 0
var _root: Node
var _cam: Camera3D

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	_root.set("save_enabled", false)
	_root.call("_begin_game")
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true

func _process(_d: float) -> void:
	_f += 1
	var car: RigidBody3D = null
	for c in _root.get_children():
		if c is RigidBody3D:
			car = c
	if car == null:
		return
	if _f == 12:
		var milk := HCPickupScript.make("milk", 0.3)
		_root.add_child(milk)
		milk.global_position = car.global_position + -car.global_transform.basis.z * 0.2 + Vector3(0, 1.2, 0) + car.global_transform.basis.x * 1.4
	if _f > 12:
		# camera behind the car: rear MILKY plate + carton in one frame
		var p := car.global_position
		_cam.global_position = p + car.global_transform.basis.z * 3.4 + Vector3(0, 1.4, 0)
		_cam.look_at(p + Vector3(0, 0.7, 0))
	if _f == 40:
		get_viewport().get_texture().get_image().save_png("res://milkshot.png")
		get_tree().quit()
