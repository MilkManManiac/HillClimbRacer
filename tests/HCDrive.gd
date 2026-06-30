extends Node
var _f := 0; var _car: RigidBody3D; var _root: Node
var _streak := 0; var _maxstreak := 0
var _wings := false
func _ready() -> void:
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	for c in _root.get_children():
		if c is RigidBody3D: _car = c
	_wings = OS.get_cmdline_user_args().has("wings")
	if _wings: _root.call("_set_level", "center", 6)
func _physics_process(_d: float) -> void:
	_f += 1
	if _car == null: return
	if _f > 60: Input.action_press("accelerate")
	if _f > 60:
		if _car.get("airborne"):
			_streak += 1; _maxstreak = maxi(_maxstreak, _streak)
		else: _streak = 0
	if _f == 1800:
		print("[hc] wings=%s longest_jump=%d frames (%.2fs at 120hz)" % [str(_wings), _maxstreak, _maxstreak/120.0])
		get_tree().quit()
