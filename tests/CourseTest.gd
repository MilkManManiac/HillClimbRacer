extends Node3D
## Headless: build the curved RoadCourse, spawn the car at its start, accelerate, and
## confirm the car stays on the road surface (doesn't fall through the trimesh) and moves.
const ArcadeCarScript := preload("res://scripts/ArcadeCar.gd")
const RoadCourseScript := preload("res://scripts/RoadCourse.gd")

var _car: RigidBody3D
var _road: Node3D
var _frame: int = 0
var _start: Vector3

func _ready() -> void:
	_road = Node3D.new()
	_road.set_script(RoadCourseScript)
	add_child(_road)
	_car = RigidBody3D.new()
	_car.set_script(ArcadeCarScript)
	add_child(_car)
	await get_tree().physics_frame
	_car.global_transform = _road.call("get_start_transform")
	await get_tree().physics_frame

func _physics_process(_delta: float) -> void:
	_frame += 1
	if _frame == 40:
		_start = _car.global_position
	if _frame > 40:
		Input.action_press("accelerate")
	if _frame == 220:
		var d := _car.global_position - _start
		print("[course] start_y=%.2f now_y=%.2f (stays near road = on surface)" % [_start.y, _car.global_position.y])
		print("[course] moved %.1f m, speed=%.1f km/h" % [Vector2(d.x, d.z).length(), _car.linear_velocity.length() * 3.6])
		get_tree().quit()
