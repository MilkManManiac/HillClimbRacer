extends Node
var _f := 0
var _car: RigidBody3D
var _maxs := 0.0; var _airf := 0
func _ready() -> void:
	var s: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(s)
	await get_tree().process_frame
	for c in s.get_children():
		if c is RigidBody3D: _car = c
func _physics_process(_d: float) -> void:
	_f += 1
	if _car == null: return
	if _f > 60: Input.action_press("accelerate")
	if _f > 60:
		_maxs = maxf(_maxs, _car.call("get_speed_kmh"))
		if _car.get("airborne"): _airf += 1
	if _f == 1000:
		print("[hc] dist=%.0f topspeed=%.0f airframes=%d" % [_car.get("distance"), _maxs, _airf])
		get_tree().quit()
