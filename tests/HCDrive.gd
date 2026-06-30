extends Node
var _f := 0
var _car: RigidBody3D
var _root: Node
func _ready() -> void:
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	for c in _root.get_children():
		if c is RigidBody3D: _car = c
func _physics_process(_d: float) -> void:
	_f += 1
	if _car == null: return
	if _f > 60 and not _car.get("dead"):
		Input.action_press("accelerate")
		# steer hard so it eventually goes off-road / crashes
		if _f % 120 < 60: Input.action_press("turn_left")
		else: Input.action_release("turn_left")
	if _f == 1500:
		print("[hc] dead=%s score=%.0f money=%d" % [str(_car.get("dead")), _car.get("score"), _root.get("money")])
		get_tree().quit()
