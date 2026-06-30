extends Node
var _f := 0
var _car: RigidBody3D
var _pre_air := 0.0
var _post_land := 0.0
var _was_air := false
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
	var air: bool = _car.get("airborne")
	# capture speed just before takeoff, and just after the next landing
	if air and not _was_air: _pre_air = _car.call("get_speed_kmh")
	if not air and _was_air and _pre_air > 60.0 and _post_land == 0.0:
		_post_land = _car.call("get_speed_kmh")
		print("[hc] before jump=%.0fkmh  after landing=%.0fkmh (retained %.0f%%)" % [_pre_air, _post_land, 100.0*_post_land/_pre_air])
		get_tree().quit()
	_was_air = air
	if _f > 2500: get_tree().quit()
