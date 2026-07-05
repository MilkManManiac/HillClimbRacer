extends Node
## Fairness probe for big jumps at maxed-out speed. HCTrack now reserves a fair, flat
## road window past every gap sized to a worst-case launch (HCTrack._max_jump_flight /
## _try_gap), and HCCar nudges the car gently toward the road's own centerline while
## airborne (HCCar's AIR_GUIDE_* block). This probe drives a MAXED-ENGINE car AT its
## speed_cap through every gap on alpine + hills for several kilometres and asserts
## every landing actually lands ON the road, alive — the regression target for the
## owner's report: "you overshoot a lot of jumps and crash where the road curves
## because you just fly over it."
##
## Pass/fail: exits 1 on any failed assertion. Run headless:
##   <godot_console> --headless --path . tests/JumpProbe.tscn

const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")
const HCCarScript := preload("res://scripts/hc/HCCar.gd")

# alpine's real overrides (from HCMain.MAPS) — the big-air map; colour/scatter fields
# dropped (irrelevant to physics), matching the convention in tests/StuntProbe.gd
const ALPINE := {
	"hill_amp": 14.0, "straight_bias": 0.7, "turn_radius_min": 50.0, "turn_radius_max": 95.0,
	"gap_start": 340.0, "gap_spacing": 280.0, "gap_ramp_rise": 6.0, "gap_land_len": 75.0,
	"gap_base_width": 24.0, "gap_grow": 12.0, "noise_frequency": 0.0034,
	"path_seed": 1337, "noise_seed": 2026,
}
# hills: plain HCTrack defaults (no overrides) — the classic map, occasional jumps
const HILLS := {}

const TARGET_DIST := 6000.0    # "several km" per the mission brief
const MAX_TICKS := 90000       # 750s @ 120Hz hard stop so a stuck bot can't hang CI
# F1, maxed engine (HCMain.VEHICLES.f1 @ upgrade level 6): max_speed clamps to speed_cap
# (95 m/s) regardless of how far engine_force is pushed past it — see HCMain._apply_map.
const F1_SPEED_CAP := 95.0
const F1_ENGINE_FORCE := 57000.0   # engine_base 21000 + 6*engine_per 6000

var _fails := 0
var _pending_idx := -1
var _cleared := 0
var _failed := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# HCMain normally registers the game's InputMap actions in code; this probe runs
	# HCCar without HCMain, so register (empty) actions to keep Input calls quiet
	for a in ["accelerate", "brake", "turn_left", "turn_right", "dive", "boost",
			"pitch_up", "pitch_down", "roll_left", "roll_right", "recover"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
	var t0 := Time.get_ticks_msec()
	await _run_map("alpine", ALPINE)
	await _run_map("hills", HILLS)
	print("[jump] %s in %d ms" % ["ALL PASS" if _fails == 0 else "%d FAILURES" % _fails, Time.get_ticks_msec() - t0])
	get_tree().quit(0 if _fails == 0 else 1)

func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[jump] ok   %s" % msg)
	else:
		_fails += 1
		print("[jump] FAIL %s" % msg)

func _on_gap_cleared(idx: int) -> void:
	_pending_idx = idx
	_cleared += 1

func _on_gap_failed(_can_respawn: bool) -> void:
	_failed += 1

## Drive one map end-to-end: maxed F1 at speed_cap, forced to full speed on every
## ramp approach (so every launch is the worst case, not whatever the bot's own
## throttle happened to build), asserting every landing ends up on-road and alive.
func _run_map(key: String, overrides: Dictionary) -> void:
	_pending_idx = -1
	_cleared = 0
	_failed = 0

	var trk := Node3D.new()
	trk.set_script(HCTrackScript)
	for k in overrides:
		trk.set(k, overrides[k])
	add_child(trk)   # generation runs in _ready

	var car := RigidBody3D.new()
	car.set_script(HCCarScript)
	add_child(car)
	car.set("terrain", trk)
	car.set("road_half", trk.get("road_half"))
	car.set("max_speed", F1_SPEED_CAP)
	car.set("engine_force", F1_ENGINE_FORCE)
	car.set("gravity_force", 17.0)
	car.set("grip", 15.0)
	car.set("corner_grip", 74.0)
	car.set("com_height", -0.6)
	car.connect("gap_cleared", _on_gap_cleared)
	car.connect("gap_failed", _on_gap_failed)

	var start: Vector3 = trk.call("spawn_pos")
	car.global_position = start
	trk.call("set_target", car)

	var was_airborne := false
	var prev_hp: float = float(car.get("health"))
	var dbg: bool = OS.get_environment("JUMPDBG") != ""
	var t := 0
	while t < MAX_TICKS and not bool(car.get("dead")) and float(car.get("distance")) < TARGET_DIST:
		_force_launch_speed(car, trk)
		_regulate_offgap_speed(car, trk)
		_drive_step(car, trk)
		await get_tree().physics_frame
		t += 1
		var hp_now: float = float(car.get("health"))
		if dbg and (hp_now < prev_hp - 1.0 or hp_now <= 0.0):
			var pos: Vector3 = car.global_position
			var s_here: float = trk.call("progress", pos)
			var lat_here: float = trk.call("lateral_off", pos)
			var half_here: float = trk.call("road_half_here", pos)
			var gi: Dictionary = trk.call("ground_info_y", pos.x, pos.z, pos.y)
			print("[jdbg] %s t=%d dist=%.1f s=%.1f lat=%.1f/%.1f y=%.2f gh=%.2f vy=%.2f hp %.1f->%.1f airborne=%s dead=%s" %
				[key, t, float(car.get("distance")), s_here, lat_here, half_here, pos.y, float(gi.h),
				car.get("linear_velocity").y, prev_hp, hp_now, bool(car.get("airborne")), bool(car.get("dead"))])
		prev_hp = hp_now
		var airborne: bool = bool(car.get("airborne"))
		if was_airborne and not airborne and _pending_idx >= 0:
			# first ground contact after clearing a gap — this IS the landing spot
			var pos: Vector3 = car.global_position
			var lat: float = absf(float(trk.call("lateral_off", pos)))
			var half: float = float(trk.call("road_half_here", pos))
			_check(lat < half, "%s gap %d: landed on-road (|lat|=%.1fm < half=%.1fm)" % [key, _pending_idx, lat, half])
			_check(not bool(car.get("dead")), "%s gap %d: alive at touchdown" % [key, _pending_idx])
			_pending_idx = -1
		was_airborne = airborne
		if t % 2400 == 0:
			print("[jump] %s t=%ds dist=%.0fm speed=%.1fm/s hp=%.0f cleared=%d failed=%d" %
				[key, t / 120, float(car.get("distance")), car.get("linear_velocity").length(), float(car.get("health")), _cleared, _failed])

	_release_all()
	var dist: float = car.get("distance")
	print("[jump] %s END t=%ds dist=%.0fm dead=%s hp=%.0f cleared=%d failed=%d" %
		[key, t / 120, dist, bool(car.get("dead")), float(car.get("health")), _cleared, _failed])
	_check(_cleared >= 3, "%s: exercised at least 3 gaps (cleared=%d)" % [key, _cleared])
	_check(_failed == 0, "%s: zero wrecked jumps (gap_failed count=%d)" % [key, _failed])
	car.queue_free()
	trk.queue_free()
	await get_tree().process_frame

## This probe's job is landing fairness, not "can a simple proportional-steer bot
## carry speed_cap through an ordinary bend" — no real driver takes a normal 30-95 m
## radius turn at 95 m/s either, gap or no gap. So: bleed speed back to a safely
## drivable pace whenever the car is grounded and NOT on a gap's approach, then
## _force_launch_speed slams it back to the worst case for the next ramp. This lets
## the probe exercise many gaps in sequence instead of dying to an ordinary corner
## between two of them (a real, but orthogonal, driving-skill limit of this bot).
## Also tops health back up off-gap: cumulative wear from firing SEVEN consecutive
## worst-case launches back-to-back with zero recovery (no real run ever does that —
## gap-clear already heals 15 hp, and a human varies speed) is a damage-ECONOMY
## question, not the landing-POSITION fairness this probe exists to check; topping up
## between gaps isolates "did THIS jump's landing kill you" from "did death by a
## thousand cuts across an unrealistic gauntlet."
const OFFGAP_SAFE_SPEED := 42.0
func _regulate_offgap_speed(car: RigidBody3D, trk: Node3D) -> void:
	if bool(car.get("airborne")):
		return
	var gs: Dictionary = trk.call("gap_state", car.global_position)
	if gs.get("active", false):
		return   # on some gap's approach/landing — leave speed alone (launch or catch)
	var vel: Vector3 = car.get("linear_velocity")
	var h := Vector3(vel.x, 0.0, vel.z)
	if h.length() > OFFGAP_SAFE_SPEED:
		var scale: float = OFFGAP_SAFE_SPEED / h.length()
		car.set("linear_velocity", Vector3(vel.x * scale, vel.y, vel.z * scale))
	car.set("health", float(car.get("max_health")))

## Force the car up to speed_cap while it's on a gap's RAMP approach (gap_state
## active, still short of the void) so every launch tests the worst case — a maxed
## car hitting the lip AT its speed_cap — regardless of how much straight run-up the
## bot's own throttle happened to build by then. Only touches horizontal velocity;
## any vertical speed the ramp-launch conversion has already added is left alone.
func _force_launch_speed(car: RigidBody3D, trk: Node3D) -> void:
	if bool(car.get("airborne")):
		return
	var gs: Dictionary = trk.call("gap_state", car.global_position)
	if not gs.get("active", false) or gs.get("over_void", false) or gs.get("past_far", false):
		return
	var max_speed: float = float(car.get("max_speed"))
	var vel: Vector3 = car.get("linear_velocity")
	var h := Vector3(vel.x, 0.0, vel.z)
	if h.length() >= max_speed:
		return
	var fwd: Vector3 = -car.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		return
	fwd = fwd.normalized()
	car.set("linear_velocity", Vector3(fwd.x * max_speed, vel.y, fwd.z * max_speed))

## AutoDrive's controller, unchanged: steer at a speed-scaled look-ahead point, brake
## when overcooking a bend, otherwise pin the throttle.
func _drive_step(car: RigidBody3D, terrain: Node) -> void:
	var pos: Vector3 = car.global_position
	var speed: float = car.linear_velocity.length()
	var aim: Vector3 = terrain.call("path_ahead", pos, clampf(speed * 0.9, 12.0, 40.0))
	var fwd: Vector3 = -car.global_transform.basis.z
	fwd.y = 0.0
	var right: Vector3 = car.global_transform.basis.x
	right.y = 0.0
	var to_aim: Vector3 = aim - pos
	to_aim.y = 0.0
	var err := 0.0
	if to_aim.length() > 0.01 and fwd.length() > 0.001:
		to_aim = to_aim.normalized()
		fwd = fwd.normalized()
		err = atan2(to_aim.dot(right.normalized()), to_aim.dot(fwd))
	var strength: float = clampf(absf(err) * 2.5, 0.0, 1.0)
	if err > 0.02:
		Input.action_press("turn_right", strength)
		Input.action_release("turn_left")
	elif err < -0.02:
		Input.action_press("turn_left", strength)
		Input.action_release("turn_right")
	else:
		Input.action_release("turn_left")
		Input.action_release("turn_right")
	if absf(err) > 0.5 and speed > 18.0:
		Input.action_release("accelerate")
		Input.action_press("brake", 0.7)
	else:
		Input.action_press("accelerate")
		Input.action_release("brake")

func _release_all() -> void:
	for a in ["accelerate", "brake", "turn_left", "turn_right"]:
		Input.action_release(a)
