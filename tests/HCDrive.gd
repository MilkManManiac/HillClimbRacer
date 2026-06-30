extends Node
var _f := 0
var _car: RigidBody3D
var _pre := 0.0; var _was_air := false; var _done := false
func _ready() -> void:
	var s: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(s)
	await get_tree().process_frame
	for c in s.get_children():
		if c is RigidBody3D: _car = c
func _physics_process(_d: float) -> void:
	_f += 1
	if _car == null: return
	if _f == 80:
		print("[hc] settled y=%.2f grounded=%s" % [_car.global_position.y, str(not _car.get("airborne"))])
	if _f > 80: Input.action_press("accelerate")
	var air: bool = _car.get("airborne")
	if air and not _was_air: _pre = _car.call("get_speed_kmh")
	if not air and _was_air and _pre > 70.0 and not _done:
		_done = true
		var post: float = _car.call("get_speed_kmh")
		print("[hc] jump %.0f -> land %.0f kmh (retained %.0f%%)" % [_pre, post, 100.0*post/_pre])
		get_tree().quit()
	_was_air = air
	if _f > 2500: print("[hc] no big jump captured"); get_tree().quit()
