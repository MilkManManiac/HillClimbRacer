extends Node
## Multi-surface road probe — covers the three ground-continuity features in one run:
##   A. canyon-config hairpin regression (the "random pop" bug): overlap patches exist,
##      and a WIDE weaving sweep of hinted wheel queries never sees a height step.
##   B. Gravity Works stunt config, static: both overpasses + corkscrews place, crossing
##      clearances hold, under/over hint queries resolve to the right decks, and the
##      same continuity sweep stays smooth through ramps, decks and banked coils.
##   C. Gravity Works, driven: an AutoDrive-style bot drives under the first bridge,
##      over it, and down the first corkscrew — asserting the car rides the correct
##      surface, the anti-tunnel floor never fires, and grounded vertical accel /
##      per-tick car height stay smooth (no teleports, no spring spikes).
## Pass/fail: exits 1 on any failed assertion. Run headless:
##   <godot_console> --headless --path . tests/StuntProbe.tscn

const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")
const HCCarScript := preload("res://scripts/hc/HCCar.gd")

# canyon's real overrides (from HCMain.MAPS) — the map where road_half_turn (32)
# exceeds turn_radius_min (26), so hairpin legs genuinely overlap
const CANYON := {
	"straight_bias": 0.22, "max_turn_deg": 150.0, "turn_radius_min": 26.0, "turn_radius_max": 60.0,
	"road_half": 20.0, "road_half_turn": 32.0, "hill_amp": 2.5, "noise_frequency": 0.004,
	"gap_start": 9.9e8, "path_seed": 424242, "noise_seed": 99,
}

# the Gravity Works map's overrides (must match the HCMain.MAPS snippet in the report).
# loop:2450 lands right after corkscrew 1's exit (~s 2980) — earlier anchors reshuffle
# this seed into an at-grade self-crossing (see the creep_xing tripwire + LoopProbe).
const GRAVITY := {
	"stunts": "loop:2450,overpass:650,corkscrew:1500:2,overpass:2900,corkscrew:3900:1",
	"straight_bias": 0.6, "turn_radius_min": 40.0, "turn_radius_max": 80.0,
	"road_half": 18.0, "road_half_turn": 26.0,
	"hill_amp": 5.0, "noise_frequency": 0.0024,
	"gap_start": 5600.0, "gap_spacing": 420.0,
	"path_seed": 777333, "noise_seed": 424,
}

var _fails := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# HCMain normally registers the game's InputMap actions in code; this probe runs
	# HCCar without HCMain, so register (empty) actions to keep Input calls quiet
	for a in ["accelerate", "brake", "turn_left", "turn_right", "dive", "boost",
			"pitch_up", "pitch_down", "roll_left", "roll_right", "recover"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
	var t0 := Time.get_ticks_msec()
	_phase_a_hairpins()
	var trk := _phase_b_static()
	await _phase_c_drive(trk)
	print("[stunt] %s in %d ms" % ["ALL PASS" if _fails == 0 else "%d FAILURES" % _fails, Time.get_ticks_msec() - t0])
	get_tree().quit(0 if _fails == 0 else 1)

func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[stunt] ok   %s" % msg)
	else:
		_fails += 1
		print("[stunt] FAIL %s" % msg)

func _make_track(overrides: Dictionary) -> Node3D:
	var trk := Node3D.new()
	trk.set_script(HCTrackScript)
	for k in overrides:
		trk.set(k, overrides[k])
	add_child(trk)   # generation runs in _ready
	return trk

# --- A: canyon hairpins ---------------------------------------------------------
func _phase_a_hairpins() -> void:
	var trk := _make_track(CANYON)
	var rep: Dictionary = trk.call("stunt_report")
	print("[stunt] A canyon: patches=%d residual=%.2fm" % [rep.patches, rep.overlap_residual])
	_check(int(rep.patches) > 0, "canyon has overlapping hairpins to reconcile (patches > 0)")
	# residual counts centre-line disagreement out to barely-grazing ribbons — the
	# sweep below is the real gate (what a wheel would feel in the drivable band)
	_check(float(rep.overlap_residual) < 3.5, "overlap residual %.2fm < 3.5m" % float(rep.overlap_residual))
	var worst := _sweep(trk, 120.0, 4200.0, 30.0)   # weave ±30 m: right through the pinch zones
	_check(worst < 0.35, "canyon wide-weave ground continuity: worst step %.3fm < 0.35m" % worst)
	trk.queue_free()

# --- B: Gravity Works static ------------------------------------------------------
func _phase_b_static() -> Node3D:
	var trk := _make_track(GRAVITY)
	var rep: Dictionary = trk.call("stunt_report")
	var feats: Array = rep.features
	print("[stunt] B gravity: placed=%d/%d partner_tiles=%d patches=%d creep_xing=%d" % [rep.placed, rep.planned, rep.partner_tiles, rep.patches, rep.creep_xing])
	_check(int(rep.placed) == int(rep.planned) and int(rep.planned) == 5, "all 5 planned stunts placed")
	_check(int(rep.partner_tiles) > 0, "crossing tiles are partner-linked for streaming")
	_check(int(rep.creep_xing) == 0, "no boxed-in creep ever tunnelled toward distant road")
	for f in feats:
		var fd: Dictionary = f
		print("[stunt]   %s s=[%.0f..%.0f] H=%.1f crossings=%d minclear=%.1fm" % [fd.kind, fd.s0, fd.s1, fd.h, fd.crossings, fd.minclear])
		_check(int(fd.crossings) > 0, "%s@%.0f actually crosses itself" % [fd.kind, float(fd.s0)])
		_check(float(fd.minclear) >= 6.0, "%s@%.0f clearance %.1fm >= 6m" % [fd.kind, float(fd.s0), float(fd.minclear)])
		if bool(fd.get("loop", false)):
			# the loop ribbon is a ridden FRAME, not a heightfield deck — there is
			# no under/over hint column to resolve; instead the wrap clearance
			# (entry vs exit ramp daylight) must hold. LoopProbe drives the ride.
			_check(float(fd.wrapclear) >= 2.0 * float(fd.lp_half) + 1.0, "loop@%.0f wrap clearance %.1fm" % [float(fd.s0), float(fd.wrapclear)])
			continue
		# under/over: at a mid-feature crossing column, a low hint and a high hint
		# must resolve to two surfaces separated by the promised clearance
		if int(fd.crossings) > 0:
			_check_column(trk, fd)
	var last: Dictionary = feats[feats.size() - 1]
	var worst := _sweep(trk, 200.0, float(last.s1) + 150.0, 12.0)
	_check(worst < 0.35, "gravity ground continuity through all stunts: worst step %.3fm < 0.35m" % worst)
	return trk

## Find an actual stacked column inside feature fd and probe it with low/high hints.
func _check_column(trk: Node3D, fd: Dictionary) -> void:
	# scan the feature span for the (x,z) where a low-hint and high-hint query
	# disagree the most — that's the bridge column
	var best_sep := 0.0
	var s: float = float(fd.s0)
	while s < float(fd.s1):
		var p: Vector3 = trk.call("point_at_s", s)
		var lo: float = trk.call("height_at_y", p.x, p.z, float(fd.lvl) + 1.0)
		var hi: float = trk.call("height_at_y", p.x, p.z, float(fd.lvl) + float(fd.h) + 1.0)
		if lo > -1e5 and hi > -1e5:   # skip the free-air sentinel
			best_sep = maxf(best_sep, hi - lo)
		s += 8.0
	_check(best_sep >= 6.0, "%s@%.0f hint queries resolve both decks (max separation %.1fm)" % [fd.kind, float(fd.s0), best_sep])

## Weaving wheel-query sweep: walk the road at 0.5 m steps with a slow ±`amp` m
## lateral sine, querying ground_info_y with a wheel-height hint that tracks the
## previous answer (exactly how a rolling wheel samples the field). Returns the
## worst per-step height change — a branch snap shows up as metres, real road
## grades stay well under 0.35 m per 0.5 m step.
func _sweep(trk: Node3D, s0: float, s1: float, amp: float) -> float:
	var worst := 0.0
	var worst_s := 0.0
	var prev_h := 0.0
	var have := false
	var s := s0
	while s < s1:
		var p0: Vector3 = trk.call("point_at_s", s)
		var p1: Vector3 = trk.call("point_at_s", s + 2.0)
		var fwd := Vector3(p1.x - p0.x, 0.0, p1.z - p0.z)
		if fwd.length() < 0.01:
			s += 0.5
			continue
		fwd = fwd.normalized()
		var lat := amp * sin(s * 0.02)
		var x := p0.x - fwd.z * lat
		var z := p0.z + fwd.x * lat
		var gi: Dictionary = trk.call("ground_info_y", x, z, (prev_h if have else p0.y) + 1.0)
		var h: float = gi.h
		if have and h > -1e5 and prev_h > -1e5:
			if absf(h - prev_h) > worst:
				worst = absf(h - prev_h)
				worst_s = s
		if h > -1e5:
			prev_h = h
			have = true
		else:
			have = false   # free air: re-seed from the road top next step
		s += 0.5
	if worst > 0.3:
		print("[stunt]   (sweep worst step %.2fm at s=%.1f, lat=%.1f)" % [worst, worst_s, amp * sin(worst_s * 0.02)])
	return worst

# --- C: drive the stunts ----------------------------------------------------------
func _phase_c_drive(trk: Node3D) -> void:
	var car := RigidBody3D.new()
	car.set_script(HCCarScript)
	add_child(car)
	car.set("terrain", trk)
	car.set("road_half", trk.get("road_half"))
	# rein the raw default exports in to real in-game pace: HCMain's VEHICLES tune
	# max_speed to 16..40 m/s — the bare script default (125) would send the bot
	# into the teardrop sweeper at triple any real gameplay speed
	car.set("max_speed", 26.0)
	car.set("engine_force", 14000.0)
	var start: Vector3 = trk.call("spawn_pos")
	car.global_position = start
	trk.call("set_target", car)
	var rep: Dictionary = trk.call("stunt_report")
	var cork: Dictionary = {}
	for f in rep.features:
		if str((f as Dictionary).kind) == "corkscrew":
			cork = f
			break
	# stop short of the loop mouth (~120 m past this corkscrew's exit) — the wrap
	# ride has its own dedicated probe (LoopProbe) with its own metrics; this
	# phase gates the SMOOTHNESS of bridge/corkscrew surfaces
	var target_s: float = float(cork.s1) + 60.0
	print("[stunt] C driving to s=%.0f (under+over bridge, down corkscrew 1)..." % target_s)

	var acc_sq := 0.0
	var worst_acc := 0.0
	var samples := 0
	var prev_vy := 0.0
	var worst_dy := 0.0
	var prev_y := start.y
	var on_deck_ok := true
	var t := 0
	while t < 26000 and not bool(car.get("dead")):
		_drive_step(car, trk)
		await get_tree().physics_frame
		t += 1
		var y: float = car.global_position.y
		if t == 180:
			car.set("tunnel_lifts", 0)   # the spawn DROP may legitimately fire the floor
		if t > 180:
			var vy: float = car.linear_velocity.y
			if not bool(car.get("airborne")):
				var a := absf(vy - prev_vy) * 120.0
				acc_sq += a * a
				worst_acc = maxf(worst_acc, a)
				samples += 1
				# a grounded car must sit ON the blended surface it's told about
				var gi: Dictionary = trk.call("ground_info_y", car.global_position.x, car.global_position.z, y)
				if absf(y - float(gi.h)) > 3.5:
					on_deck_ok = false
			worst_dy = maxf(worst_dy, absf(y - prev_y))
			prev_vy = vy
		prev_y = y
		if t % 2400 == 0:
			print("[stunt]   t=%ds dist=%.0fm y=%.1f hp=%.0f fuel=%.0f" % [t / 120, float(car.get("distance")), y, float(car.get("health")), float(car.get("fuel"))])
		if float(car.get("distance")) > target_s:
			break
	_release_all()
	var dist: float = car.get("distance")
	var rms: float = sqrt(acc_sq / maxf(float(samples), 1.0))
	print("[stunt] C end: t=%ds dist=%.0fm dead=%s lifts=%d acc_rms=%.2f worst=%.1f worst_dy=%.2fm" %
		[t / 120, dist, bool(car.get("dead")), int(car.get("tunnel_lifts")), rms, worst_acc, worst_dy])
	_check(not bool(car.get("dead")), "bot survived the bridge + corkscrew")
	_check(dist > target_s, "bot cleared the corkscrew (dist %.0f > %.0f)" % [dist, target_s])
	_check(int(car.get("tunnel_lifts")) == 0, "anti-tunnel floor never fired (lifts=0)")
	_check(worst_dy < 1.2, "no car teleports: worst per-tick dy %.2fm < 1.2m" % worst_dy)
	_check(rms < 4.5, "grounded vert accel rms %.2f < 4.5" % rms)
	_check(on_deck_ok, "grounded car always sits on its reported surface (|y-h| <= 3.5m)")
	car.queue_free()
	trk.queue_free()

## AutoDrive's controller, trimmed: steer at a speed-scaled look-ahead point, brake
## when overcooking a bend.
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
