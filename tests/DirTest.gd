extends Node3D
## Headless: spawn the road + car, hold ACCELERATE, and report which way the car
## actually moves so we can fix W-goes-backward without guessing.
##   godot --headless --path . res://tests/DirTest.tscn --quit-after 200

const DriveCarScript := preload("res://scripts/DriveCar.gd")
const RoadNetworkScript := preload("res://scripts/RoadNetwork.gd")

var _car: VehicleBody3D
var _start: Vector3
var _frame: int = 0

func _ready() -> void:
	var roads := Node3D.new()
	roads.set_script(RoadNetworkScript)
	add_child(roads)
	_car = VehicleBody3D.new()
	_car.set_script(DriveCarScript)
	add_child(_car)
	_car.global_position = Vector3(0, 0.8, 30)
	await get_tree().physics_frame
	_start = _car.global_position

func _physics_process(_delta: float) -> void:
	_frame += 1
	Input.action_press("accelerate")
	if _frame == 100:
		var d := _car.global_position - _start
		var fwd := -_car.global_transform.basis.z   # car's nominal forward
		print("[dirtest] moved dz=%.2f  full delta=%s" % [d.z, str(d)])
		print("[dirtest] car forward(-Z)=%s  velocity=%s" % [str(fwd), str(_car.linear_velocity)])
		print("[dirtest] moving along forward? dot=%.2f" % fwd.dot(_car.linear_velocity))
		get_tree().quit()
