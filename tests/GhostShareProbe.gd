extends Node
## Stage 1 async multiplayer ("send a friend your ghost") round-trip probe, headless.
## Exercises the full export/import pipeline end to end:
##   1. record a real ghost via the same drive-then-force-finish trick TrialProbe uses
##   2. export it to a standalone .hcghost file (redirected to a temp subdir — see
##      ghost_dir_override on HCMain — so this never touches the real user://ghosts)
##   3. corrupt-checksum reject: a tampered copy of the exported file must fail import
##   4. valid import: the ORIGINAL exported file loads as this map's rival ghost
##   5. rival appears in trial playback state (has_data), alongside the personal-best
##      ghost, simultaneously — "only one" degrades gracefully via Clear Rival
##   6. save/load persists the rival through a real JSON round-trip (mirrors
##      TrialProbe's in-memory _collect_save -> JSON text -> _apply_save pattern, so
##      it never touches the real user://hc_save.json)
##   7. wrong-map import (unknown map key) is rejected
## Exit code 0 only if every check passes.
##   <godot_console> --headless --path . tests/GhostShareProbe.tscn

const HCGhostScript := preload("res://scripts/hc/HCGhost.gd")
const HCTimeTrialScript := preload("res://scripts/hc/HCTimeTrial.gd")
const TMP_DIR := "user://ghost_share_probe_tmp"

var _ok := true

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[ghost] OK   " + what)
	else:
		print("[ghost] FAIL " + what)
		_ok = false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the title screen pauses the tree — see HCMain

	_cleanup_dir(TMP_DIR)   # in case a previous crashed run left this behind

	# --- stage 1: boot, switch to trial mode, drive, force-finish a real ghost ------
	var root: Node = load("res://scenes/HillClimb.tscn").instantiate()
	root.set("ghost_dir_override", TMP_DIR)   # redirect exports away from the real folder
	add_child(root)   # save_enabled stays false (headless default) — hermetic
	await get_tree().process_frame
	root.call("_begin_game")
	root.call("_on_title_mode_button", "trial")
	_check(bool(root.get("_trial_active")), "trial active on hills")

	var car: RigidBody3D = null
	for c in root.get_children():
		if c is RigidBody3D:
			car = c
	_check(car != null, "car found")

	Input.action_press("accelerate")
	for i in range(240):   # ~2s of sim
		await get_tree().physics_frame
	Input.action_release("accelerate")
	car.set("distance", 1500.0)   # past hills' 1000m finish line
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(bool(root.get("_trial_finished")), "finish detected")

	var vehicle: String = str(root.get("_vehicle"))
	var key := "hills|" + vehicle
	var ghost_data: Dictionary = root.get("_ghost_data")
	var rec_n: int = (ghost_data[key] as Array).size() if ghost_data.has(key) else 0
	_check(rec_n >= 80, "synthetic ghost recorded (%d floats)" % rec_n)

	# --- stage 2: export ---------------------------------------------------------
	root.call("_export_best_ghost")
	var d := DirAccess.open(TMP_DIR)
	var exported_name := ""
	if d:
		for f in d.get_files():
			if f.ends_with(".hcghost"):
				exported_name = f
	_check(exported_name != "" and exported_name.begins_with("hills_" + vehicle + "_"), "exported file named correctly (%s)" % exported_name)

	var ef := FileAccess.open(TMP_DIR + "/" + exported_name, FileAccess.READ)
	var original_text := ef.get_as_text() if ef else ""
	if ef:
		ef.close()
	_check(original_text != "", "exported file readable")

	# --- stage 3: corrupt-checksum reject ----------------------------------------
	var json := JSON.new()
	json.parse(original_text)
	var payload: Dictionary = json.data
	var corrupt: Dictionary = payload.duplicate(true)
	corrupt["checksum"] = int(corrupt["checksum"]) + 1
	var corrupt_res: Dictionary = root.call("import_rival_ghost_text", JSON.stringify(corrupt), "corrupt_test")
	_check(not bool(corrupt_res.get("ok", true)), "corrupt checksum rejected (%s)" % str(corrupt_res.get("msg", "")))
	_check(not (root.get("_rival_data") as Dictionary).has("hills"), "corrupt import did not install a rival")

	# --- stage 4: valid import -----------------------------------------------------
	var import_res: Dictionary = root.call("import_rival_ghost_text", original_text, "friend_hills_52s")
	_check(bool(import_res.get("ok", false)), "valid import accepted (%s)" % str(import_res.get("msg", "")))
	var rival_data: Dictionary = root.get("_rival_data")
	_check(rival_data.has("hills"), "rival stored under map key \"hills\"")
	_check(str((rival_data.get("hills", {}) as Dictionary).get("name", "")) == "friend_hills_52s", "rival keeps source filename as its label")

	# --- stage 5: rival appears in trial playback state, alongside your own best ---
	root.call("_reset_run_mode_state")   # reloads both ghosts for the (already active) map
	var ghost: Node3D = root.get("_ghost")
	var rival: Node3D = root.get("_rival_ghost")
	_check(rival != null and bool(rival.call("has_data")), "rival ghost has playback data")
	_check(ghost != null and bool(ghost.call("has_data")), "personal-best ghost STILL has playback data (racing both at once)")
	var t_mid: float = float(rival.call("total_time")) * 0.5
	rival.call("show_at", t_mid)
	ghost.call("show_at", t_mid)
	var rival_mesh: Node3D = null
	for gc in rival.get_children():
		if gc is Node3D:
			rival_mesh = gc
	_check(rival_mesh != null and rival_mesh.visible, "rival mesh visible mid-run")

	# "if only one exists, show that one": clearing the rival must not touch your own ghost
	root.call("_clear_rival_ghost")
	_check(not bool(rival.call("has_data")), "clear rival drops its playback data")
	_check(bool(ghost.call("has_data")), "personal-best ghost survives clearing the rival")
	_check(not (root.get("_rival_data") as Dictionary).has("hills"), "clear rival removes the save-schema entry")

	# re-import for the save/load stage below
	root.call("import_rival_ghost_text", original_text, "friend_hills_52s")

	# --- stage 6: save/load persists the rival (in-memory JSON round-trip, like
	# TrialProbe's ghost round-trip — never touches the real user://hc_save.json) -----
	var snap: Dictionary = root.call("_collect_save")
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(snap))
	var root2: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(root2)
	await get_tree().process_frame
	root2.call("_begin_game")
	root2.call("_apply_save", parsed)
	var rival_data2: Dictionary = root2.get("_rival_data")
	var ok2 := rival_data2.has("hills") \
		and str((rival_data2["hills"] as Dictionary).get("name", "")) == "friend_hills_52s" \
		and absf(float((rival_data2["hills"] as Dictionary).get("time", -1.0)) - float((rival_data["hills"] as Dictionary).get("time", -2.0))) < 0.001
	_check(ok2, "rival survives save/load JSON round-trip")
	remove_child(root2)
	root2.queue_free()

	# --- stage 7: wrong-map import rejected -----------------------------------------
	var samples: Array = payload["samples"]
	var time_val: float = float(payload["time"])
	var bad_map := payload.duplicate(true)
	bad_map["map"] = "not_a_real_map"
	bad_map["checksum"] = HCGhostScript.checksum(samples, time_val)   # valid checksum — must still fail on the map check
	var bad_map_res: Dictionary = root.call("import_rival_ghost_text", JSON.stringify(bad_map), "bad_map_test")
	_check(not bool(bad_map_res.get("ok", true)), "unknown-map import rejected (%s)" % str(bad_map_res.get("msg", "")))

	# --- cleanup ---------------------------------------------------------------------
	_cleanup_dir(TMP_DIR)

	print("[ghost] " + ("ALL OK" if _ok else "FAILURES — see above"))
	get_tree().quit(0 if _ok else 1)

func _cleanup_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d:
		for f in d.get_files():
			DirAccess.remove_absolute(path + "/" + f)
	if DirAccess.dir_exists_absolute(path):
		DirAccess.remove_absolute(path)
