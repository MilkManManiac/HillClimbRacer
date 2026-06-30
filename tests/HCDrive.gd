extends Node
var _f := 0
var _car: RigidBody3D
var _maxs := 0.0
var _sum := 0.0
var _n := 0
func _ready() -> void:
	var s: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(s)
	await get_tree().process_frame
	for c in s.get_children():
		if c is RigidBody3D: _car = c
func _physics_process(_d: float) -> void:
	_f += 1
	if _car == null: return
	if _f > 60:
		Input.action_press("accelerate")
		if not _car.get("dead"):
			var s: float = _car.call("get_speed_kmh")
			_maxs = maxf(_maxs, s); _sum += s; _n += 1
	if _f == 1200:
		print("[hc] dist=%.0f topspeed=%.0f avgspeed=%.0f score=%.0f" % [
			_car.get("distance"), _maxs, _sum/maxf(_n,1), _car.get("score")])
		get_tree().quit()
