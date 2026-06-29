extends Node
## Headless: load the real Main scene, find the car, and report whether it's upright,
## grounded, and able to move (to diagnose "stuck / everything red").
var _main: Node
var _car: RigidBody3D
var _frame: int = 0
var _p0: Vector3

func _ready() -> void:
	_main = load("res://scenes/Main.tscn").instantiate()
	add_child(_main)
	await get_tree().process_frame
	await get_tree().physics_frame
	_car = _main.call("get_car")
	if _car:
		print("[probe] spawn pos=%s up.y=%.2f" % [str(_car.global_position), _car.global_transform.basis.y.y])

func _physics_process(_d: float) -> void:
	if _car == null:
		return
	_frame += 1
	if _frame == 30:
		_p0 = _car.global_position
	if _frame > 30:
		Input.action_press("accelerate")
	if _frame == 200:
		var disp := (_car.global_position - _p0).length()
		print("[probe] after throttle: moved=%.2f m  speed=%.1f km/h  up.y=%.2f  y=%.2f" % [
			disp, _car.linear_velocity.length() * 3.6, _car.global_transform.basis.y.y, _car.global_position.y])
		print("[probe] (up.y~1 = upright, ~ -1 = flipped; moved~0 = wedged)")
		get_tree().quit()
