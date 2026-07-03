extends Node
## Save/load round-trip probe. Boots HillClimb.tscn, stamps money, saves, tears the
## instance down, boots a SECOND fresh instance and confirms it restored. Then writes
## garbage over the save file and confirms a THIRD boot survives (silent fresh start).
## Cleans up user://hc_save.json afterward so this never pollutes a real dev save.
##   <godot_console> --headless --path . tests/SaveProbe.tscn

const SAVE_PATH := "user://hc_save.json"

var _ok := true

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the title screen pauses the tree — see HCMain
	# clean slate: don't let a stray dev save on this machine skew the test
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)

	# --- stage 1: boot, stamp money, save, tear down ---------------------------
	# persistence is disabled under the headless driver by default (keeps the rest of
	# the probe battery hermetic) — opt in BEFORE add_child so _ready's _load_game runs
	var root1: Node = load("res://scenes/HillClimb.tscn").instantiate()
	root1.set("save_enabled", true)
	add_child(root1)
	await get_tree().process_frame
	root1.call("_begin_game")
	root1.set("money", 1234)
	root1.call("_save_game")
	remove_child(root1)
	root1.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame   # let queue_free actually free before the next boot

	# --- stage 2: boot a fresh instance, confirm the restore --------------------
	var root2: Node = load("res://scenes/HillClimb.tscn").instantiate()
	root2.set("save_enabled", true)
	add_child(root2)
	await get_tree().process_frame
	root2.call("_begin_game")
	var restored_money: int = int(root2.get("money"))
	if restored_money == 1234:
		print("[save] roundtrip OK")
	else:
		print("[save] roundtrip FAILED (expected 1234, got %d)" % restored_money)
		_ok = false
	remove_child(root2)
	root2.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame

	# --- stage 3: corrupt save file must not crash boot -------------------------
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	f.store_string("{ this is not valid json ]][[")
	f.close()
	var root3: Node = load("res://scenes/HillClimb.tscn").instantiate()
	root3.set("save_enabled", true)
	add_child(root3)
	await get_tree().process_frame
	root3.call("_begin_game")
	await get_tree().process_frame
	# survives AND lands on a clean fresh start (default money), no crash / no carry-over
	var alive3: bool = is_instance_valid(root3) and root3.is_inside_tree()
	if alive3 and int(root3.get("money")) == 0:
		print("[save] corrupt OK")
	else:
		print("[save] corrupt FAILED (alive=%s money=%s)" % [str(alive3), str(root3.get("money")) if alive3 else "?"])
		_ok = false
	remove_child(root3)
	root3.queue_free()

	# --- cleanup: never leave a probe-generated save behind ---------------------
	if FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(SAVE_PATH)

	await get_tree().process_frame
	get_tree().quit(0 if _ok else 1)
