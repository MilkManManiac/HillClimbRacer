extends Node
## Keyboard probe: drives the weekly trial with REAL key events (Input.parse_input_event),
## so the bindings themselves are under test — the other probes press actions directly
## and would pass with every key unbound. Covers: Space = handbrake (stops, never
## reverses, kicks a drift with steer, keeps speed on the gas), Space never clicks a
## menu button mid-run, arrow keys steer, a handbrake hold carried into the air is not
## a dive, and the results panel can't be dismissed by a Space still held from the lap.
##   <godot_console> --headless --path . tests/KbmProbe.tscn

var _ok := true

func _check(cond: bool, what: String) -> void:
	if cond:
		print("[kbm] OK   " + what)
	else:
		print("[kbm] FAIL " + what)
		_ok = false

func _key(kc: int, down: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = kc
	e.keycode = kc
	e.pressed = down
	Input.parse_input_event(e)
	# events are buffered until the next DRAWN frame; under load several physics ticks
	# pass between frames, so a check a couple of ticks later would race the key
	Input.flush_buffered_events()

func _bound(action: String, kc: int) -> bool:
	var e := InputEventKey.new()
	e.physical_keycode = kc
	return InputMap.has_action(action) and InputMap.action_has_event(action, e)

func _ticks(n: int) -> void:
	for i in range(n):
		await get_tree().physics_frame

func _fwd_speed(car: RigidBody3D) -> float:
	return car.linear_velocity.dot(-car.global_transform.basis.z)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the title screen pauses the tree
	var root: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(root)   # save_enabled stays false (headless default) — hermetic
	await get_tree().process_frame

	# --- bindings -----------------------------------------------------------------
	_check(_bound("handbrake", KEY_SPACE), "Space is bound to the handbrake")
	_check(_bound("accelerate", KEY_W) and _bound("accelerate", KEY_UP), "W and Up accelerate")
	_check(_bound("brake", KEY_S) and _bound("brake", KEY_DOWN), "S and Down brake")
	_check(_bound("turn_left", KEY_A) and _bound("turn_left", KEY_LEFT), "A and Left steer left")
	_check(_bound("turn_right", KEY_D) and _bound("turn_right", KEY_RIGHT), "D and Right steer right")

	root.call("_on_title_mode_button", "trial")
	root.call("_begin_game")
	await _ticks(60)
	_check(get_viewport().gui_get_focus_owner() == null, "no button holds keyboard focus once driving")
	var car: RigidBody3D = root.get("_car")
	var run_id: int = int(root.get("_trial_run_id"))

	# --- Space alone: stops the car, never reverses it --------------------------------
	# (every stage restarts at the spawn and keeps it short: the opening straight is the
	# only stretch a probe can hold W without steering, and it bends at ~190 m)
	_key(KEY_W, true)
	await _ticks(200)
	var v_go: float = _fwd_speed(car)
	_check(v_go > 20.0, "W gets the car moving (%.1f m/s after 1.7 s, %d m in)" % [v_go, int(car.get("distance"))])
	_key(KEY_W, false)
	_key(KEY_SPACE, true)
	await _ticks(2)
	_check(bool(car.get("handbraking")), "Space engages the handbrake")
	var stop_ticks := 0
	while stop_ticks < 1200 and _fwd_speed(car) > 1.0:
		await get_tree().physics_frame
		stop_ticks += 1
	_check(_fwd_speed(car) <= 1.0, "handbrake stops the car (%.1f s from %.0f m/s)" % [stop_ticks / 120.0, v_go])
	var min_v := 0.0
	for i in range(180):
		await get_tree().physics_frame
		min_v = minf(min_v, _fwd_speed(car))
	_check(min_v > -0.6, "holding Space at a standstill never reverses (min %.2f m/s)" % min_v)
	_check(int(root.get("_trial_run_id")) == run_id and get_viewport().gui_get_focus_owner() == null,
			"Space did not restart the run or click anything")
	_key(KEY_SPACE, false)

	# --- W + steer + Space: a drift that keeps its speed ----------------------------
	root.call("_restart")
	run_id = int(root.get("_trial_run_id"))
	_key(KEY_W, true)
	# W is also "nose down" in the air, and the car spawns with a small drop: before the
	# start line the air controls are locked, so flooring it off the grid can't dip the nose
	var nose_down := 0.0
	for i in range(200):
		await get_tree().physics_frame
		nose_down = maxf(nose_down, rad_to_deg(asin(clampf(car.global_transform.basis.z.y, -1.0, 1.0))))
	var v_in: float = car.linear_velocity.length()
	_check(bool(car.get("air_control_locked")) or bool(root.get("_trial_running")), "air controls locked until the start line")
	_check(nose_down < 4.0, "W held off the grid doesn't dip the nose (worst %.1f deg, %.1f m/s at 1.7 s)" % [nose_down, v_in])
	_key(KEY_RIGHT, true)
	_key(KEY_SPACE, true)
	await _ticks(60)
	_check(bool(car.get("drifting")), "Space + steer breaks traction within 0.5 s")
	_check(float(car.get("_steer")) < -0.2, "Right arrow steers right (steer %.2f)" % float(car.get("_steer")))
	await _ticks(60)
	var v_out: float = car.linear_velocity.length()
	_check(v_out > v_in * 0.6, "a 1 s power drift keeps most of its speed (%.0f -> %.0f m/s)" % [v_in, v_out])
	_check(int(root.get("_trial_run_id")) == run_id, "no wreck during the drift")
	_key(KEY_SPACE, false)
	_key(KEY_RIGHT, false)
	var regrip := 0
	while regrip < 360 and bool(car.get("drifting")):
		await get_tree().physics_frame
		regrip += 1
	_check(not bool(car.get("drifting")), "grip returns after letting go (%.2f s)" % (regrip / 120.0))
	root.call("_restart")
	await _ticks(120)
	_key(KEY_LEFT, true)
	await _ticks(40)
	_check(float(car.get("_steer")) > 0.2, "Left arrow steers left (steer %.2f)" % float(car.get("_steer")))
	_key(KEY_LEFT, false)
	_key(KEY_W, false)

	# --- a handbrake hold carried into the air is not a dive --------------------------
	_key(KEY_SPACE, true)
	await _ticks(4)
	car.global_position += Vector3.UP * 7.0
	await _ticks(6)
	_check(not bool(car.get("_grounded")) and bool(car.get("_dive_block")) and not bool(car.get("handbraking")),
			"Space held at takeoff: no handbrake and no dive in the air")
	_key(KEY_SPACE, false)
	await _ticks(3)
	_check(not bool(car.get("_dive_block")), "releasing Space re-arms the dive")
	_key(KEY_SPACE, true)
	await _ticks(3)
	_check(not bool(car.get("_grounded")) and not bool(car.get("_dive_block")), "a fresh Space press in the air dives")
	_key(KEY_SPACE, false)
	await _ticks(240)

	# --- results: a Space held (or tapped) across the line must not skip the panel -----
	root.call("_restart")
	_key(KEY_W, true)
	var f := 0
	while f < 960 and not bool(root.get("_trial_running")):
		await get_tree().physics_frame
		f += 1
	await _ticks(120)
	_key(KEY_W, false)
	car.set("distance", float(root.get("_trial_finish_s")) + 1.0)
	await _ticks(2)
	var results := root.get("_results_layer") as CanvasLayer
	_check(results.visible, "results panel up at the finish")
	_key(KEY_SPACE, true)
	await _ticks(3)
	_key(KEY_SPACE, false)
	await _ticks(10)
	_check(results.visible and bool(root.get("_trial_finished")), "a Space tap right at the finish leaves the results up")
	await get_tree().create_timer(float(root.get("RESULTS_FOCUS_DELAY")) + 0.3).timeout
	_check(get_viewport().gui_get_focus_owner() == root.get("_results_retry_btn"), "RETRY takes focus a beat later")
	_key(KEY_SPACE, true)
	await _ticks(2)
	_key(KEY_SPACE, false)
	await _ticks(10)
	_check(not results.visible and not bool(root.get("_trial_finished")), "then Space retries")
	await _ticks(30)
	_check(get_viewport().gui_get_focus_owner() == null, "no focus left behind after the retry")

	print("[kbm] ALL OK" if _ok else "[kbm] FAILED")
	get_tree().quit(0 if _ok else 1)
