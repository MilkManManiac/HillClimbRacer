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
	if _f > 60: Input.action_press("accelerate")
	if _f == 1100:
		print("[hc] dist=%.0f score=%.0f health=%.0f trick='%s'" % [
			_car.get("distance"), _car.get("score"), _car.get("health"), _car.get("trick_text")])
		get_tree().quit()
