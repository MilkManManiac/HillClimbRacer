extends Node3D
## Headless: ground + arcade car, hold accelerate, report grounding + motion direction.
const ArcadeCarScript := preload("res://scripts/ArcadeCar.gd")
const RoadNetworkScript := preload("res://scripts/RoadNetwork.gd")

var _car: RigidBody3D
var _start: Vector3
var _frame: int = 0
var _settled_y: float = 0.0

func _ready() -> void:
	var roads := Node3D.new()
	roads.set_script(RoadNetworkScript)
	add_child(roads)
	_car = RigidBody3D.new()
	_car.set_script(ArcadeCarScript)
	add_child(_car)
	_car.global_position = Vector3(0, 1.2, 30)
	await get_tree().physics_frame
	await get_tree().physics_frame

func _physics_process(_delta: float) -> void:
	_frame += 1
	if _frame == 40:
		_settled_y = _car.global_position.y
		_start = _car.global_position
	if _frame > 40:
		Input.action_press("accelerate")
	if _frame == 200:
		var d := _car.global_position - _start
		var fwd := -_car.global_transform.basis.z
		print("[arcade] settled_y=%.2f  now_y=%.2f  (stable if ~equal)" % [_settled_y, _car.global_position.y])
		print("[arcade] moved dz=%.2f  delta=%s  speed=%.1f km/h" % [d.z, str(d), _car.linear_velocity.length() * 3.6])
		print("[arcade] forward dot velocity=%.2f (positive = drives where it looks)" % fwd.dot(_car.linear_velocity))
		get_tree().quit()
