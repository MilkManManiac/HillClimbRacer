extends Node3D
## Headless: drive up to speed, then hold a turn; verify the car yaws and its velocity
## stays aligned with its heading (natural turn, not a slide or pivot-in-place).
const ArcadeCarScript := preload("res://scripts/ArcadeCar.gd")
const RoadNetworkScript := preload("res://scripts/RoadNetwork.gd")

var _car: RigidBody3D
var _frame: int = 0
var _yaw0: float = 0.0

func _ready() -> void:
	var roads := Node3D.new()
	roads.set_script(RoadNetworkScript)
	add_child(roads)
	_car = RigidBody3D.new()
	_car.set_script(ArcadeCarScript)
	add_child(_car)
	_car.global_position = Vector3(0, 1.2, 30)
	await get_tree().physics_frame

func _physics_process(_delta: float) -> void:
	_frame += 1
	if _frame > 40:
		Input.action_press("accelerate")
	if _frame == 160:
		_yaw0 = _car.rotation.y
		Input.action_press("turn_left")
	if _frame == 320:
		var fwd := -_car.global_transform.basis.z
		var vel := _car.linear_velocity
		var align := 1.0
		if vel.length() > 0.1:
			align = fwd.normalized().dot(vel.normalized())
		print("[turn] yaw change over 160 frames = %.1f deg" % rad_to_deg(_car.rotation.y - _yaw0))
		print("[turn] speed=%.1f km/h  vel-vs-heading align=%.3f (1.0 = no slide)" % [vel.length() * 3.6, align])
		print("[turn] y=%.2f (grounded ~ -0.18)" % _car.global_position.y)
		get_tree().quit()
