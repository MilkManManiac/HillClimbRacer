extends Node
var _f := 0
var _car: RigidBody3D
func _ready() -> void:
	var s: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(s)
	await get_tree().process_frame
	for c in s.get_children():
		if c is RigidBody3D: _car = c
func _physics_process(_d: float) -> void:
	_f += 1
	if _car == null: return
	if _f == 90:
		print("[hc] settled y=%.2f grounded=%s" % [_car.global_position.y, str(not _car.get("airborne"))])
	if _f > 90:
		Input.action_press("accelerate")
	if _f == 420:
		print("[hc] drove dist=%.1f y=%.2f speed=%.0fkmh fuel=%.0f health=%.0f air=%s" % [
			_car.get("distance"), _car.global_position.y, _car.call("get_speed_kmh"),
			_car.get("fuel"), _car.get("health"), str(_car.get("airborne"))])
		get_tree().quit()
