extends Node
## Time-trial + ghost probe. Exercises the full trial pipeline headless:
##   1. boot -> switch to trial mode -> drive; assert the timer runs and the ghost records
##   2. force-cross the finish line; assert a best time + ghost were banked and the
##      HUD/summary strings formed
##   3. serialization round-trip: _collect_save -> JSON text -> _apply_save on a FRESH
##      instance; assert best_time + ghost data survive byte-for-byte (count + endpoints)
##   4. ghost playback: load the saved data into the fresh instance's ghost and assert
##      show_at() positions the mesh where the recording says it should be
##   5. sprint maps ignore the trial toggle (canyon stays sprint)
## Exit code 0 only if every check passes.
##   <godot_console> --headless --path . tests/TrialProbe.tscn

var _ok := true

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[trial] OK   " + what)
	else:
		print("[trial] FAIL " + what)
		_ok = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the title screen pauses the tree

	# --- stage 1: boot into trial mode on hills, drive a bit -------------------
	var root: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(root)   # save_enabled stays false (headless default) — hermetic
	await get_tree().process_frame
	root.call("_begin_game")
	root.call("_on_title_mode_button", "trial")
	_check(str(root.get("_run_mode")) == "trial", "mode toggle -> trial")
	_check(bool(root.get("_trial_active")), "trial active on hills")

	var car: RigidBody3D = null
	for c in root.get_children():
		if c is RigidBody3D:
			car = c
	_check(car != null, "car found")
	var ghost: Node3D = root.get("_ghost")
	_check(ghost != null, "ghost node exists")

	Input.action_press("accelerate")
	for i in range(240):   # ~2s of sim
		await get_tree().physics_frame
	Input.action_release("accelerate")
	var t_live: float = float(root.get("_trial_time"))
	_check(t_live > 1.0, "trial timer runs (t=%.2f)" % t_live)
	var rec_n: int = int(ghost.call("sample_count"))
	_check(rec_n >= 10, "ghost recording (%d samples @20Hz)" % rec_n)

	# --- stage 2: force-finish (teleporting 1000m of real driving would take the
	# probe minutes; _update_trial reads car.distance, so stamp it past the line and
	# let one tick fire the real finish path) ----------------------------------
	car.set("distance", 1500.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(bool(root.get("_trial_finished")), "finish detected")
	var key := "hills|" + str(root.get("_vehicle"))
	var bt: Dictionary = root.get("_best_time")
	_check(bt.has(key) and float(bt[key]) > 0.0, "best time banked (%s=%.2fs)" % [key, float(bt.get(key, -1.0))])
	var gd: Dictionary = root.get("_ghost_data")
	_check(gd.has(key) and (gd[key] as Array).size() >= 80, "ghost banked (%d floats)" % (gd[key] as Array).size())
	_check(str(root.get("_trial_result")).contains("NEW BEST"), "finish summary formed")

	# medal thresholds: the forced finish took only ~2s, so it must be gold
	var medal: String = load("res://scripts/hc/HCTimeTrial.gd").medal_for("hills", float(bt[key]))
	_check(medal == "gold", "medal ladder (%.2fs -> %s)" % [float(bt[key]), medal])
	# time formatting sanity
	var fmt: String = load("res://scripts/hc/HCTimeTrial.gd").format_time(83.217)
	_check(fmt == "1:23.22", "format_time (83.217 -> %s)" % fmt)

	# --- stage 3: save schema round-trip through actual JSON text ---------------
	var snap: Dictionary = root.call("_collect_save")
	var json_txt := JSON.stringify(snap)
	var parsed: Dictionary = JSON.parse_string(json_txt)
	var src_ghost: Array = gd[key]

	var root2: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(root2)
	await get_tree().process_frame
	root2.call("_begin_game")
	root2.call("_apply_save", parsed)
	var bt2: Dictionary = root2.get("_best_time")
	_check(bt2.has(key) and absf(float(bt2[key]) - float(bt[key])) < 0.001, "best time survives JSON round-trip")
	var gd2: Dictionary = root2.get("_ghost_data")
	var rt_ghost: Array = gd2.get(key, [])
	var endpoints_ok: bool = rt_ghost.size() == src_ghost.size() and rt_ghost.size() > 0 \
		and absf(float(rt_ghost[0]) - float(src_ghost[0])) < 0.001 \
		and absf(float(rt_ghost[rt_ghost.size() - 1]) - float(src_ghost[src_ghost.size() - 1])) < 0.001
	_check(endpoints_ok, "ghost survives JSON round-trip (%d floats)" % rt_ghost.size())
	_check(str(root2.get("_run_mode")) == "trial", "run_mode survives round-trip")

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

	# --- stage 4: playback positions the ghost where the recording says ---------
	var ghost2: Node3D = root2.get("_ghost")
	ghost2.call("load_data", rt_ghost)
	_check(bool(ghost2.call("has_data")), "playback data loads")
	var total: float = float(ghost2.call("total_time"))
	ghost2.call("show_at", total * 0.5)
	# reconstruct the expected position by scanning the raw samples around t=total/2
	var expected := _pos_at(rt_ghost, total * 0.5)
	var mesh: Node3D = null
	for gc in ghost2.get_children():
		if gc is Node3D:
			mesh = gc
	var err: float = mesh.global_position.distance_to(expected) if mesh else 1e9
	_check(mesh != null and mesh.visible and err < 0.5, "show_at positions mesh (err=%.3fm)" % err)
	ghost2.call("show_at", total + 5.0)
	_check(mesh != null and not mesh.visible, "ghost hides after its run ends")

	# --- stage 5: sprint maps ignore the trial toggle ---------------------------
	root.call("select_map", "canyon")
	_check(bool(root.get("_sprint_active")), "canyon: sprint still active in trial mode")
	_check(not bool(root.get("_trial_active")), "canyon: trial correctly inactive")
	root.call("select_map", "midnight")
	_check(bool(root.get("_trial_active")), "midnight: trial active again")

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
