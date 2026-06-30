extends Node
var _f := 0
var _car: RigidBody3D
var _terr: Node3D
var _maxang := 0.0
var _minpen := 999.0   # min (origin.y - terrain_height); very negative = sank through road
func _ready() -> void:
	var s: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(s)
	await get_tree().process_frame
	for c in s.get_children():
		if c is RigidBody3D: _car = c
		if c.get_script() and str(c.get_script().resource_path).ends_with("HCTerrain.gd"): _terr = c
func _physics_process(_d: float) -> void:
	_f += 1
	if _car == null: return
	if _f > 60: Input.action_press("accelerate")
	if _f > 80 and not _car.get("dead"):
		_maxang = maxf(_maxang, _car.angular_velocity.length())
		var th: float = _terr.call("height_at", _car.global_position.x, _car.global_position.z)
		_minpen = minf(_minpen, _car.global_position.y - th)
	if _f == 1500:
		print("[hc] max_angvel=%.1f rad/s  deepest(origin-terrain)=%.2f m (negative=through road)" % [_maxang, _minpen])
		get_tree().quit()
