extends Node
## Party Balloons (contraption prototype) probe. Headless checks:
##   1. shop path: _buy("balloons") levels the upgrade and configures the car
##   2. NO effect while grounded (no charge drain, no engage)
##   3. airborne + held float caps the fall speed near FLOAT_FALL_CAP
##   4. the charge drains, balloons pop one by one, and a long float feeds the combo
##   5. HUD charge strip appears once the upgrade is owned
##   6. persistence: the level round-trips through _collect_save/_apply_save
## Exit code 0 only if every check passes.
##   <godot_console> --headless --path . tests/BalloonProbe.tscn

var _ok := true

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[balloon] OK   " + what)
	else:
		print("[balloon] FAIL " + what)
		_ok = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the title screen pauses the tree

	var root: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(root)   # save_enabled stays false (headless default) — hermetic
	await get_tree().process_frame
	root.call("_begin_game")

	var car: RigidBody3D = null
	for c in root.get_children():
		if c is RigidBody3D:
			car = c
	_check(car != null, "car found")

	# settle the spawn drop so the grounded checks below mean something
	for i in range(180):
		await get_tree().physics_frame
	_check(bool(car.get("_grounded")), "car settled on the road")

	# --- stage 1: buy two levels through the real shop path ----------------------
	root.set("money", 100000)
	var money0 := int(root.get("money"))
	root.call("_buy", "balloons")
	root.call("_buy", "balloons")
	_check(int(car.get("balloon_level")) == 2, "two buys -> car balloon_level 2")
	_check(int(root.get("money")) < money0, "buys cost money")
	var cap := float(car.get("balloon_cap"))
	_check(absf(cap - 4.7) < 0.01, "level-2 charge = 4.7 s (cap=%.2f)" % cap)
	_check(absf(float(car.get("balloon_time")) - cap) < 0.01, "fresh bundle is full")

	# HUD strip exists only once owned
	await get_tree().process_frame
	await get_tree().process_frame
	var bar: ColorRect = root.get("_balloon_bar")
	_check(bar != null and bar.visible, "HUD charge strip visible once owned")

	# --- stage 2: grounded hold = no effect --------------------------------------
	Input.action_press("float")
	for i in range(120):
		await get_tree().physics_frame
	_check(bool(car.get("_grounded")), "still grounded holding float on the road")
	_check(absf(float(car.get("balloon_time")) - cap) < 0.01, "no charge drain on the ground")
	_check(float(car.get("_float_k")) < 0.01, "no engage on the ground")
	Input.action_release("float")

	# --- stage 3: airborne float caps the fall speed -----------------------------
	car.set("combo_pot", 0.0)
	car.set("combo_chain", 0)
	car.set("_combo_time", 0.0)
	car.global_position += Vector3(0, 45.0, 0)
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	Input.action_press("float")
	# 2 s in: charge (4.7 s) is still live, so the fall must be converged on the cap
	for i in range(240):
		await get_tree().physics_frame
	var vy := car.linear_velocity.y
	_check(not bool(car.get("_grounded")), "still airborne mid-float")
	_check(bool(car.get("floating")), "floating flag live while held")
	_check(vy > -7.0 and vy < 0.5, "fall speed capped near %.0f m/s (vy=%.2f)" % [4.0, vy])
	_check(float(car.get("balloon_time")) < cap - 1.5, "charge is draining while floating")
	_check(float(car.get("_balloon_infl")) > 0.5, "bundle visually inflated mid-float")

	# --- stage 4: drain to empty -> staggered pops + BALLOON FLOAT trick ----------
	var landed_ok := false
	for i in range(2400):   # up to 20 s — plenty for drain + free fall + touchdown
		await get_tree().physics_frame
		if bool(car.get("_grounded")):
			landed_ok = true
			break
	Input.action_release("float")
	_check(landed_ok, "landed after the bundle drained")
	_check(float(car.get("balloon_time")) < 0.01, "charge fully spent")
	_check(int(car.get("balloon_pops")) >= 3, "balloons popped one by one (%d pops)" % int(car.get("balloon_pops")))
	_check(float(car.get("combo_pot")) > 100.0, "long float fed the combo (pot=%.0f)" % float(car.get("combo_pot")))

	# --- stage 5: retry refills the bundle ----------------------------------------
	car.call("reset_run", car.global_position + Vector3(0, 2, 0))
	_check(absf(float(car.get("balloon_time")) - cap) < 0.01, "reset_run refills the bundle")
	_check(int(car.get("balloon_pops")) == 0, "pop counter cleared on reset")

	# --- stage 6: save round-trip (pure serialize path, file IO stays disabled) ---
	var veh := str(root.get("_vehicle"))
	var d: Dictionary = root.call("_collect_save")
	_check(int(d.levels[veh]["balloons"]) == 2, "save snapshot holds balloons=2")
	var levels: Dictionary = root.get("_levels")
	levels["balloons"] = 0
	root.call("_apply_upgrades")
	_check(int(car.get("balloon_level")) == 0, "level cleared before restore")
	root.call("_apply_save", d)
	root.call("_apply_upgrades")
	_check(int(car.get("balloon_level")) == 2, "apply_save restores balloons=2")

	print("[balloon] %s" % ("ALL PASS" if _ok else "SOME FAILED"))
	get_tree().quit(0 if _ok else 1)
