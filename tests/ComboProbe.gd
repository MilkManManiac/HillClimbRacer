extends Node
## Combo-v2 probe. Exercises the trick-chain state machine headless:
##   1. boot -> chained _combo_add calls grow the pot with the x1/x1.5/x2… multiplier
##   2. grace expiry on plain road BANKS the pot into score (and fires combo_event)
##   3. a finished drift segment folds into the chain as ONE trick
##   4. hugging the rail at speed fires NEAR MISS (car-local lateral math)
##   5. death drops the pot ("COMBO LOST"), score unchanged
##   6. HUD readout: combo label/bar visible while a pot is open, hidden after
## Exit code 0 only if every check passes.
##   <godot_console> --headless --path . tests/ComboProbe.tscn

var _ok := true
var _events: Array = []   # [kind, amount, chain] triples in fire order

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[combo] OK   " + what)
	else:
		print("[combo] FAIL " + what)
		_ok = false

func _on_combo(kind: String, amount: int, chain: int) -> void:
	_events.append([kind, amount, chain])

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
	car.connect("combo_event", _on_combo)

	# let the spawn drop settle so the car is grounded and the grace timer can drain
	for i in range(180):
		await get_tree().physics_frame
	_check(bool(car.get("_grounded")), "car settled on the road")
	# the spawn drop itself scores a real AIR trick — zero the combo state so the
	# arithmetic below starts from a clean chain
	car.set("combo_pot", 0.0)
	car.set("combo_chain", 0)
	car.set("_combo_time", 0.0)
	car.set("_drift_seg_pts", 0.0)
	_events.clear()

	# --- stage 1: chained tricks grow the pot with the escalating multiplier -----
	var score0 := float(car.get("score"))
	car.call("_combo_add", 100.0, "TEST A")   # x1.0 -> +100
	car.call("_combo_add", 100.0, "TEST B")   # x1.5 -> +150
	car.call("_combo_add", 100.0, "TEST C")   # x2.0 -> +200
	var pot := float(car.get("combo_pot"))
	_check(absf(pot - 450.0) < 1.0, "3-chain pot 100->450 with x1/x1.5/x2 (pot=%.0f)" % pot)
	_check(int(car.get("combo_chain")) == 3, "chain count = 3")
	_check(absf(float(car.call("combo_mult")) - 2.0) < 0.01, "multiplier x2.0 at chain 3")
	_check(float(car.call("combo_grace_frac")) > 0.9, "grace bar full right after a trick")

	# HUD: the combo readout must be live while a pot is open
	var combo_lbl: Label = root.get("_combo_lbl")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(combo_lbl != null and combo_lbl.visible, "combo HUD visible while pot open")
	_check(combo_lbl.text.contains("450"), "combo HUD shows the pot (%s)" % combo_lbl.text)

	# --- stage 2: grace expiry banks the pot into score --------------------------
	# idle on plain road well past COMBO_GRACE (1.5 s -> 240 ticks at 120 Hz is 2 s)
	for i in range(300):
		await get_tree().physics_frame
	var score1 := float(car.get("score"))
	_check(float(car.get("combo_pot")) == 0.0, "pot cleared after bank")
	_check(score1 - score0 >= 449.0, "bank paid into score (+%.0f)" % (score1 - score0))
	var banked := _events.filter(func(e): return e[0] == "bank")
	_check(banked.size() == 1 and int(banked[0][1]) >= 449, "combo_event bank fired (+%d)" % (int(banked[0][1]) if banked.size() > 0 else -1))
	await get_tree().process_frame
	_check(not combo_lbl.visible, "combo HUD hides once the pot banks")

	# --- stage 3: a finished drift segment becomes one chained trick -------------
	car.set("_drift_seg_pts", 40.0)   # as if a real slide just ended (drifting=false)
	# physics_frame fires at the START of a step — wait a few so the car has ticked
	for i in range(4):
		await get_tree().physics_frame
	_check(float(car.get("combo_pot")) >= 39.0, "drift segment fed the combo (pot=%.0f)" % float(car.get("combo_pot")))

	# --- stage 4: near-miss when hugging the rail at speed -----------------------
	var pot_before_nm := float(car.get("combo_pot"))
	var terrain: Node = car.get("terrain")
	var lv: Dictionary = terrain.call("lateral_vec", car.global_position)
	var rh: float = terrain.call("road_half_here", car.global_position)
	# park the car 0.6 m inside the rail line, doing 20 m/s along the road
	car.global_position += (lv.right as Vector3) * (rh - 0.6 - float(lv.lat))
	car.set("_grounded", true)
	car.linear_velocity = Vector3(0, 0, -20.0)
	car.call("_check_near_miss")
	var pot_after_nm := float(car.get("combo_pot"))
	_check(pot_after_nm > pot_before_nm + 30.0, "NEAR MISS fed the combo (+%.0f)" % (pot_after_nm - pot_before_nm))
	car.call("_check_near_miss")   # cooldown must swallow an immediate second fire
	_check(float(car.get("combo_pot")) == pot_after_nm, "near-miss cooldown blocks refire")
	# put the car back on the centre-line so the off-road wreck check can't trip
	car.global_position -= (lv.right as Vector3) * (rh - 0.6)

	# --- stage 5: death drops the pot, score untouched ----------------------------
	var score_before_drop := float(car.get("score"))
	car.set("health", 0.0)
	for i in range(5):
		await get_tree().physics_frame
	_check(bool(car.get("dead")), "car died on cue")
	_check(float(car.get("combo_pot")) == 0.0, "pot dropped on death")
	_check(float(car.get("score")) == score_before_drop, "dropped pot paid nothing")
	var drops := _events.filter(func(e): return e[0] == "drop")
	_check(drops.size() >= 1, "combo_event drop fired")

	print("[combo] %s" % ("ALL PASS" if _ok else "SOME FAILED"))
	get_tree().quit(0 if _ok else 1)
