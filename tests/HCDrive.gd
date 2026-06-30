extends Node
var _f := 0
var _car: RigidBody3D
var _maxspeed := 0.0
var _air_frames := 0
var _max_air_y := 0.0
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
		_maxspeed = maxf(_maxspeed, _car.call("get_speed_kmh"))
		if _car.get("airborne"): _air_frames += 1
	if _f == 1600:
		print("[hc] dist=%.0fm maxspeed=%.0fkmh airframes=%d fuel=%.0f health=%.0f" % [
			_car.get("distance"), _maxspeed, _air_frames, _car.get("fuel"), _car.get("health")])
		get_tree().quit()
