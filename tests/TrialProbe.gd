extends Node
## Weekly time-trial probe. Exercises the whole trial pipeline headless:
##   1. trial mode swaps in the weekly track + its fixed car/tune and switches off fuel,
##      pickups, sprint and the garage; the garage picks are remembered, not overwritten
##   2. the clock waits for the start line, then runs; the ghost records from the line
##   3. a wreck restarts the run by itself (no shop, no money)
##   4. crossing the finish banks time + splits + ghost, brakes the car, shows results
##   5. restart clears the results; a slower second run keeps the old best
##   6. save schema round-trip through real JSON text, and the ghost version gate
##   7. ghost playback puts the mesh where the recording says
##   8. switching back to classic restores the garage map + ride (canyon = sprint again)
## Exit code 0 only if every check passes.
##   <godot_console> --headless --path . tests/TrialProbe.tscn

const HCTimeTrialScript := preload("res://scripts/hc/HCTimeTrial.gd")

var _ok := true

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[trial] OK   " + what)
	else:
		print("[trial] FAIL " + what)
		_ok = false

## Hold the throttle until the trial clock is live (start line crossed), max ~8 s of sim.
func _drive_to_start(root: Node) -> void:
	Input.action_press("accelerate")
	var f := 0
	while f < 960 and not bool(root.get("_trial_running")):
		await get_tree().physics_frame
		f += 1

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the title screen pauses the tree

	# --- stage 1: trial mode = the weekly track in its fixed car ------------------
	var root: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(root)   # save_enabled stays false (headless default) — hermetic
	await get_tree().process_frame
	var garage_veh: String = str(root.get("_vehicle"))
	var garage_map: String = str(root.get("_map"))
	root.call("_begin_game")
	root.call("_on_title_mode_button", "trial")
	var wk: String = HCTimeTrialScript.WEEKLY
	var wk_car: String = HCTimeTrialScript.car_for(wk)
	_check(str(root.get("_run_mode")) == "trial", "mode toggle -> trial")
	_check(str(root.get("_map")) == wk, "trial loads the weekly track (%s)" % str(root.get("_map")))
	_check(str(root.get("_vehicle")) == wk_car, "trial loads the track's car (%s)" % str(root.get("_vehicle")))
	_check(bool(root.get("_trial_active")) and not bool(root.get("_sprint_active")), "trial active, sprint off")
	_check(str(root.get("_garage_vehicle")) == garage_veh and str(root.get("_garage_map")) == garage_map, "garage picks remembered (%s on %s)" % [garage_veh, garage_map])
	var car: RigidBody3D = root.get("_car")
	var terrain: Node = root.get("_terrain")
	_check(bool(car.get("infinite_fuel")), "no fuel in a trial")
	_check(not bool(terrain.get("pickups_enabled")), "pickups off in a trial")
	var want_speed: float = 40.0 + 16.0 * float(HCTimeTrialScript.setup_for(wk).get("engine", 0))
	_check(absf(float(car.get("max_speed")) - want_speed) < 0.01, "fixed tune applied (max_speed %.0f)" % float(car.get("max_speed")))
	root.call("_toggle_shop")
	_check(not (root.get("_shop") as Control).visible, "garage stays shut in a trial")
	_check(is_instance_valid(root.get("_trial_props")) and (root.get("_trial_props") as Node).get_child_count() == 2 + HCTimeTrialScript.SPLIT_FRACS.size(), "start/finish gates + split markers built")

	# --- stage 2: the clock waits for the start line -------------------------------
	for i in range(30):
		await get_tree().physics_frame
	_check(not bool(root.get("_trial_running")) and float(root.get("_trial_time")) == 0.0, "clock holds before the start line")
	await _drive_to_start(root)
	_check(bool(root.get("_trial_running")), "clock starts at the line")
	for i in range(180):
		await get_tree().physics_frame
	var t_live: float = float(root.get("_trial_time"))
	_check(t_live > 1.0, "trial timer runs (t=%.2f)" % t_live)
	var ghost: Node3D = root.get("_ghost")
	var rec_n: int = int(ghost.call("sample_count"))
	_check(rec_n >= 10, "ghost recording from the line (%d samples @20Hz)" % rec_n)
	_check(absf(float(car.get("fuel")) - float(car.get("max_fuel"))) < 0.001, "tank never drains")

	# --- stage 3: a wreck restarts the run on its own -------------------------------
	var money_before: int = int(root.get("money"))
	var run_before: int = int(root.get("_trial_run_id"))
	car.set("health", 0.0)
	await get_tree().create_timer(float(root.get("TRIAL_WRECK_DELAY")) + 0.4).timeout
	_check(int(root.get("_trial_run_id")) > run_before and not bool(car.get("dead")), "wreck auto-restarts the run")
	_check(not (root.get("_shop") as Control).visible, "no shop after a trial wreck")
	_check(int(root.get("money")) == money_before, "no money from a trial")

	# --- stage 4: finish (driving 2.8 km would take the probe a minute; _update_trial
	# reads car.distance, so stamp it past the line and let one tick fire the real path)
	await _drive_to_start(root)
	for i in range(120):
		await get_tree().physics_frame
	Input.action_release("accelerate")
	car.set("distance", float(root.get("_trial_finish_s")) + 1.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(bool(root.get("_trial_finished")) and not bool(root.get("_trial_running")), "finish detected, clock stopped")
	var key := wk + "|" + wk_car
	var bt: Dictionary = root.get("_best_time")
	_check(bt.has(key) and float(bt[key]) > 0.0, "best time banked (%s=%.2fs)" % [key, float(bt.get(key, -1.0))])
	var bs: Dictionary = root.get("_best_splits")
	_check(bs.has(key) and (bs[key] as Array).size() == HCTimeTrialScript.SPLIT_FRACS.size(), "splits banked (%s)" % str(bs.get(key, [])))
	var gd: Dictionary = root.get("_ghost_data")
	_check(gd.has(key) and (gd[key] as Array).size() >= 80, "ghost banked (%d floats)" % (gd[key] as Array).size())
	_check(str(root.get("_trial_result")).contains("NEW BEST"), "finish summary formed")
	_check((root.get("_results_layer") as CanvasLayer).visible, "results panel up")
	_check(bool(car.get("autobrake")), "car brakes itself after the line")
	_check(HCTimeTrialScript.medal_for(wk, float(bt[key])) == "gold", "medal ladder (%.2fs -> gold)" % float(bt[key]))
	_check(HCTimeTrialScript.format_time(83.217) == "1:23.22", "format_time")
	_check(HCTimeTrialScript.format_delta(-0.416) == "-0.42" and HCTimeTrialScript.format_delta(1.1) == "+1.10", "format_delta")

	# --- stage 5: restart clears the panel; a slower run keeps the old best ---------
	var first_best: float = float(bt[key])
	root.call("_restart")
	_check(not (root.get("_results_layer") as CanvasLayer).visible and not bool(car.get("autobrake")) and not bool(root.get("_trial_finished")), "restart clears results + autobrake")
	_check(float(root.get("_trial_time")) == 0.0 and not bool(root.get("_trial_running")), "clock reset after the restart")
	await _drive_to_start(root)
	for i in range(200):   # longer than the first run, still on the opening straight
		await get_tree().physics_frame
	Input.action_release("accelerate")
	car.set("distance", float(root.get("_trial_finish_s")) + 1.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(absf(float((root.get("_best_time") as Dictionary)[key]) - first_best) < 0.0001 and not str(root.get("_trial_result")).contains("NEW BEST"), "slower run keeps the old best (%.2f vs %.2f, '%s')" % [float(root.get("_trial_time")), first_best, str(root.get("_trial_result"))])

	# --- stage 6: save schema round-trip through actual JSON text -------------------
	var snap: Dictionary = root.call("_collect_save")
	_check(str(snap.get("vehicle")) == garage_veh and str(snap.get("map")) == garage_map, "save keeps the garage picks, not the trial car/track")
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(snap))
	var src_ghost: Array = gd[key]

	var root2: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(root2)
	await get_tree().process_frame
	root2.call("_begin_game")
	root2.call("_apply_save", parsed)
	var bt2: Dictionary = root2.get("_best_time")
	_check(bt2.has(key) and absf(float(bt2[key]) - float(bt[key])) < 0.001, "best time survives JSON round-trip")
	var bs2: Dictionary = root2.get("_best_splits")
	_check(bs2.has(key) and (bs2[key] as Array).size() == (bs[key] as Array).size(), "splits survive JSON round-trip")
	var gd2: Dictionary = root2.get("_ghost_data")
	var rt_ghost: Array = gd2.get(key, [])
	var endpoints_ok: bool = rt_ghost.size() == src_ghost.size() and rt_ghost.size() > 0 \
		and absf(float(rt_ghost[0]) - float(src_ghost[0])) < 0.001 \
		and absf(float(rt_ghost[rt_ghost.size() - 1]) - float(src_ghost[src_ghost.size() - 1])) < 0.001
	_check(endpoints_ok, "ghost survives JSON round-trip (%d floats)" % rt_ghost.size())
	_check(str(root2.get("_run_mode")) == "trial" and str(root2.get("_map")) == wk and str(root2.get("_vehicle")) == wk_car, "a trial-mode save loads back onto the weekly track + car")
	_check(str(root2.get("_garage_vehicle")) == garage_veh, "...with the garage ride intact")

	# ghost version gate: a bumped version must DROP ghosts but keep times
	var stale := parsed.duplicate(true)
	stale["ghost_version"] = 999
	var root3: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(root3)
	await get_tree().process_frame
	root3.call("_begin_game")
	root3.call("_apply_save", stale)
	var gd3: Dictionary = root3.get("_ghost_data")
	var bt3: Dictionary = root3.get("_best_time")
	_check(not gd3.has(key) and bt3.has(key), "version mismatch drops ghosts, keeps times")

	# --- stage 7: playback positions the ghost where the recording says -------------
	var ghost2: Node3D = root2.get("_ghost")
	ghost2.call("load_data", rt_ghost)
	_check(bool(ghost2.call("has_data")), "playback data loads")
	var total: float = float(ghost2.call("total_time"))
	ghost2.call("show_at", total * 0.5)
	var expected := _pos_at(rt_ghost, total * 0.5)
	var mesh: Node3D = null
	for gc in ghost2.get_children():
		if gc is Node3D:
			mesh = gc
	var err: float = mesh.global_position.distance_to(expected) if mesh else 1e9
	_check(mesh != null and mesh.visible and err < 0.5, "show_at positions mesh (err=%.3fm)" % err)
	ghost2.call("show_at", total + 5.0)
	_check(mesh != null and not mesh.visible, "ghost hides after its run ends")

	# --- stage 8: back to classic restores the garage -------------------------------
	root.call("_on_title_mode_button", "classic")
	_check(str(root.get("_map")) == garage_map and str(root.get("_vehicle")) == garage_veh, "classic restores the garage map + ride")
	_check(not bool(root.get("_trial_active")), "trial off in classic")
	await get_tree().process_frame
	_check(not is_instance_valid(root.get("_trial_props")), "gates gone in classic")
	var car_c: RigidBody3D = root.get("_car")
	_check(not bool(car_c.get("infinite_fuel")) and bool((root.get("_terrain") as Node).get("pickups_enabled")), "fuel + pickups back in classic")
	root.call("select_map", "canyon")
	_check(bool(root.get("_sprint_active")) and not bool(root.get("_trial_active")), "canyon in classic is still the sprint")

	print("[trial] " + ("ALL OK" if _ok else "FAILURES — see above"))
	get_tree().quit(0 if _ok else 1)

## Linear-interpolated position at time t from a raw 8-float-per-sample dump
## (mirrors HCGhost's sample layout: [t, x,y,z, qx,qy,qz,qw]).
func _pos_at(data: Array, t: float) -> Vector3:
	var n := data.size() / 8
	for i in range(n - 1):
		var t0 := float(data[i * 8])
		var t1 := float(data[(i + 1) * 8])
		if t >= t0 and t <= t1:
			var f := 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)
			var p0 := Vector3(float(data[i * 8 + 1]), float(data[i * 8 + 2]), float(data[i * 8 + 3]))
			var p1 := Vector3(float(data[(i + 1) * 8 + 1]), float(data[(i + 1) * 8 + 2]), float(data[(i + 1) * 8 + 3]))
			return p0.lerp(p1, f)
	return Vector3(float(data[1]), float(data[2]), float(data[3]))
