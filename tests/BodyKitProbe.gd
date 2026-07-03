extends Node
## Verifies the imported-GLB body path on HCCar: shell loads in place of the
## procedural panels, asset wheels are hidden, and the wheel/ray stance auto-fits
## to the model's named wheel nodes (Kenney sedan has 4). Also verifies the
## fallback: a bogus path must yield the procedural body, not a crash.

const HCCarScript := preload("res://scripts/hc/HCCar.gd")

func _ready() -> void:
	# HCCar reads input actions that HCMain registers at runtime; standalone we must
	# stub them or every physics tick spams "action doesn't exist" errors
	for a in ["dive", "boost", "recover", "pitch_up", "pitch_down", "roll_left", "roll_right"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
	var fails := 0

	# --- GLB body with named wheels: stance should re-anchor -------------------
	var car := RigidBody3D.new()
	car.set_script(HCCarScript)
	car.set("vehicle_type", "hotrod")
	car.set("body_glb", "res://assets/car/kenney_sedan_cc0.glb")
	car.freeze = true
	add_child(car)
	await get_tree().process_frame
	var top: float = car.get("_glb_top")
	var wp: Array = car.get("_wheel_positions")
	var wb: float = car.get("wheelbase")
	var vspec_fx := 0.9   # hotrod VSPEC stance — auto-fit should move off this
	var moved: bool = absf(absf(wp[0].x) - vspec_fx) > 0.01
	print("[bodykit] glb_top=%.2f wheelbase=%.2f FL=%s moved_from_vspec=%s" % [top, wb, str(wp[0]), str(moved)])
	if top <= 0.0:
		print("[bodykit] FAIL: GLB shell did not load (glb_top=0)"); fails += 1
	if not moved:
		print("[bodykit] FAIL: wheel stance did not auto-fit"); fails += 1
	if wb < 1.6 or wb > 4.5:
		print("[bodykit] FAIL: implausible wheelbase %.2f" % wb); fails += 1
	car.queue_free()

	# --- bogus path: must fall back to procedural body, no crash ---------------
	var car2 := RigidBody3D.new()
	car2.set_script(HCCarScript)
	car2.set("vehicle_type", "hotrod")
	car2.set("body_glb", "res://assets/car/does_not_exist.glb")
	car2.freeze = true
	add_child(car2)
	await get_tree().process_frame
	var top2: float = car2.get("_glb_top")
	var body: Node3D = car2.get("_body")
	var pcount: int = body.get_child_count() if body else 0
	print("[bodykit] fallback glb_top=%.2f procedural_children=%d" % [top2, pcount])
	if top2 != 0.0 or pcount < 5:
		print("[bodykit] FAIL: fallback to procedural body broken"); fails += 1
	car2.queue_free()

	print("[bodykit] %s" % ("ALL OK" if fails == 0 else "%d FAILURES" % fails))
	get_tree().quit(0 if fails == 0 else 1)
