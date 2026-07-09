extends Node
## Loop-de-loop probe — the full vertical loop on the Gravity Works config:
##   A. static: the loop:S token places, its wrap clearance (entry vs exit ramp
##      daylight) and drive-under clearance verify numerically, loop_state()
##      resolves the mouth and the apex, and the GROUND through the loop's span
##      stays continuous (the ribbon is a frame, not a heightfield surface).
##   B. fast car: mounts the loop, becomes fully INVERTED at the apex, stays glued
##      to the ribbon radius the whole wrap, exits grounded + alive past the loop —
##      zero anti-tunnel lifts, no per-tick teleports.
##   C. slow car: mounts, stalls past vertical, DETACHES cleanly (ballistic fall,
##      no impulses) and comes back down to the road without teleports.
## Pass/fail: exits 1 on any failed assertion. Run headless:
##   <godot_console> --headless --path . tests/LoopProbe.tscn

const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")
const HCCarScript := preload("res://scripts/hc/HCCar.gd")

# the Gravity Works overrides WITH the loop (must match the HCMain.MAPS snippet).
# Placement note: loop:2450 is due mid-corkscrew, so it lands right after the
# corkscrew's exit (~s 2980) — a tests/LoopScan.gd sweep showed every earlier
# anchor reshuffles this seed into an at-grade self-crossing near the spawn
# straight (the generator's boxed-in creep), while 2450 keeps the whole layout
# clean (self-clearance >= 145 m outside stunt spans, creep tripwire quiet).
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
	for a in ["accelerate", "brake", "turn_left", "turn_right", "dive", "boost",
			"pitch_up", "pitch_down", "roll_left", "roll_right", "recover"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
	var t0 := Time.get_ticks_msec()
	var trk := _phase_a_static()
	await _phase_b_fast(trk)
	await _phase_c_slow(trk)
	await _phase_d_crawler(trk)
	trk.queue_free()
	print("[loop] %s in %d ms" % ["ALL PASS" if _fails == 0 else "%d FAILURES" % _fails, Time.get_ticks_msec() - t0])
	get_tree().quit(0 if _fails == 0 else 1)

func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[loop] ok   %s" % msg)
	else:
		_fails += 1
		print("[loop] FAIL %s" % msg)

func _loop_feature(trk: Node3D) -> Dictionary:
	var rep: Dictionary = trk.call("stunt_report")
	for f in rep.features:
		if bool((f as Dictionary).get("loop", false)):
			return f
	return {}

# --- A: static geometry + queries ----------------------------------------------
func _phase_a_static() -> Node3D:
	var trk := Node3D.new()
	trk.set_script(HCTrackScript)
	for k in GRAVITY:
		trk.set(k, GRAVITY[k])
	add_child(trk)
	var rep: Dictionary = trk.call("stunt_report")
	_check(int(rep.placed) == 5 and int(rep.planned) == 5, "all 5 planned stunts placed (incl. loop)")
	var f := _loop_feature(trk)
	_check(not f.is_empty(), "loop feature registered")
	if f.is_empty():
		return trk
	var lR: float = f.lp_R
	var half: float = f.lp_half
	print("[loop] A: ent=%.0fm R=%.1f half=%.1f shift=%.1f wrapclear=%.2f minclear=%.2f crossings=%d" %
		[f.lp_ent, lR, half, float(f.lp_shift), float(f.wrapclear), float(f.minclear), int(f.crossings)])
	_check(float(f.wrapclear) >= 2.0 * half + 1.0, "wrap clearance %.2fm >= %.2fm (entry/exit ramps never intersect)" % [float(f.wrapclear), 2.0 * half + 1.0])
	_check(int(f.crossings) > 0 and float(f.minclear) >= 6.0, "drive-under clearance %.1fm >= 6m over %d ribbon samples" % [float(f.minclear), int(f.crossings)])
	# loop_state at the mouth (a wheel-height point just past the tangent)
	var e: Vector3 = f.lp_e
	var fv: Vector3 = f.lp_f
	var mouth_p: Vector3 = e + fv * 1.5 + Vector3.UP * 0.2
	var stm: Dictionary = trk.call("loop_state", mouth_p)
	_check(bool(stm.get("active", false)) and bool(stm.get("mouth", false)), "loop_state resolves the mouth (active+mouth at the tangent)")
	# loop_state at the apex (centre-line, half the lateral shift applied)
	var rv: Vector3 = f.lp_r
	var apex: Vector3 = e + Vector3.UP * (2.0 * lR) + rv * (float(f.lp_shift) * 0.5)
	var sta: Dictionary = trk.call("loop_state", apex)
	var apex_ok: bool = bool(sta.get("active", false)) and absf(float(sta.get("r", 0.0)) - lR) < 1.0 and absf(absf(float(sta.get("th", 0.0))) - PI) < 0.1
	_check(apex_ok, "loop_state resolves the apex (r~R, |th|~PI)")
	# the GROUND through the loop span must stay flat + continuous (the ribbon is
	# not a heightfield surface; a detached car must find plain road below)
	var worst := 0.0
	var prev := 0.0
	var have := false
	var s: float = float(f.s0)
	while s < float(f.s1):
		var p: Vector3 = trk.call("point_at_s", s)
		var gi: Dictionary = trk.call("ground_info_y", p.x, p.z, p.y + 1.0)
		if have:
			worst = maxf(worst, absf(float(gi.h) - prev))
		prev = float(gi.h)
		have = true
		s += 0.5
	_check(worst < 0.35, "ground under the loop stays continuous: worst step %.3fm < 0.35m" % worst)
	return trk

# --- shared driving harness ------------------------------------------------------
## Drops the car onto the road `start_s` metres along the track, FACING along it —
## the loop sits ~3 km in, and marching a bot through 3 km of random bends at test
## speeds would test the bot, not the loop.
func _make_car(trk: Node3D, max_speed: float, engine: float, start_s: float) -> RigidBody3D:
	var car := RigidBody3D.new()
	car.set_script(HCCarScript)
	car.set("terrain", trk)
	car.set("road_half", trk.get("road_half"))
	car.set("max_speed", max_speed)
	car.set("engine_force", engine)
	add_child(car)
	var p0: Vector3 = trk.call("point_at_s", start_s)
	var p1: Vector3 = trk.call("point_at_s", start_s + 4.0)
	var fv := Vector3(p1.x - p0.x, 0.0, p1.z - p0.z).normalized()
	car.global_transform = Transform3D(Basis(Vector3.UP, atan2(-fv.x, -fv.z)), p0 + Vector3.UP * 3.0)
	trk.call("set_target", car)
	return car

## Steer at a look-ahead point; full throttle, hands off the wheel while riding
## the loop (a chase-aim controller reads the apex as "180 degrees off course"
## and would brake mid-wrap — a human just holds the throttle).
func _drive_step(car: RigidBody3D, trk: Node3D) -> void:
	var riding: bool = not (car.get("_loop") as Dictionary).is_empty()
	if riding:
		for a in ["turn_left", "turn_right", "brake"]:
			Input.action_release(a)
		Input.action_press("accelerate")
		return
	var pos: Vector3 = car.global_position
	var speed: float = car.linear_velocity.length()
	var aim: Vector3 = trk.call("path_ahead", pos, clampf(speed * 0.9, 12.0, 40.0))
	var fwd: Vector3 = -car.global_transform.basis.z
	fwd.y = 0.0
	var right: Vector3 = car.global_transform.basis.x
	right.y = 0.0
	var to_aim: Vector3 = aim - pos
	to_aim.y = 0.0
	var err := 0.0
	if to_aim.length() > 0.01 and fwd.length() > 0.001:
		err = atan2(to_aim.normalized().dot(right.normalized()), to_aim.normalized().dot(fwd.normalized()))
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
	if absf(err) > 0.35 and speed > 16.0:
		Input.action_release("accelerate")
		Input.action_press("brake", 0.7)
	else:
		Input.action_press("accelerate")
		Input.action_release("brake")

func _release_all() -> void:
	for a in ["accelerate", "brake", "turn_left", "turn_right"]:
		Input.action_release(a)

# --- B: fast car completes the loop ----------------------------------------------
func _phase_b_fast(trk: Node3D) -> void:
	var f := _loop_feature(trk)
	if f.is_empty():
		return
	var lR: float = f.lp_R
	var ent: float = f.lp_ent
	var car := _make_car(trk, 40.0, 20000.0, ent - 260.0)
	print("[loop] B: fast car (40 m/s) dropped 260 m before the loop at s=%.0f..." % ent)
	var min_updot := 1.0
	var worst_adh := 0.0
	var worst_dy := 0.0
	var prev_y: float = car.global_position.y
	var mounted := false
	var max_th := 0.0
	var t := 0
	while t < 6000 and not bool(car.get("dead")):
		_drive_step(car, trk)
		await get_tree().physics_frame
		t += 1
		var y: float = car.global_position.y
		if t == 180:
			car.set("tunnel_lifts", 0)   # the spawn drop may legitimately fire the floor
		if t > 180:
			worst_dy = maxf(worst_dy, absf(y - prev_y))
		prev_y = y
		if t % 600 == 0:
			print("[loop]   B t=%.0fs dist=%.0f v=%.1f y=%.1f hp=%.0f" % [t / 120.0, float(car.get("distance")), car.linear_velocity.length(), y, float(car.get("health"))])
		var riding: bool = not (car.get("_loop") as Dictionary).is_empty()
		if riding:
			mounted = true
			var th: float = car.get("_loop_th")
			max_th = maxf(max_th, th)
			var st: Dictionary = trk.call("loop_state", car.global_position)
			if bool(st.get("active", false)) and th > 0.6 and th < TAU - 0.6:
				worst_adh = maxf(worst_adh, absf(float(st.r) - lR))
			if th > 2.6 and th < 3.7:
				min_updot = minf(min_updot, car.global_transform.basis.y.dot(Vector3.UP))
		if float(car.get("distance")) > ent + 80.0 and max_th > 6.0 and not riding and not bool(car.get("airborne")):
			break
	_release_all()
	print("[loop] B end: t=%.1fs dist=%.0f max_th=%.2f min_updot=%.2f adh=%.2f dy=%.2f lifts=%d hp=%.0f" %
		[t / 120.0, float(car.get("distance")), max_th, min_updot, worst_adh, worst_dy, int(car.get("tunnel_lifts")), float(car.get("health"))])
	_check(mounted, "fast car mounted the loop")
	_check(max_th >= TAU - 0.1, "fast car completed the full wrap (max th %.2f >= %.2f)" % [max_th, TAU - 0.1])
	_check(min_updot < -0.75, "fully inverted at the apex (up.dot(UP) %.2f < -0.75)" % min_updot)
	_check(worst_adh < 2.0, "stayed on the ribbon: worst |r - R| %.2fm < 2.0m" % worst_adh)
	_check(not bool(car.get("dead")), "exited alive")
	_check(not bool(car.get("airborne")), "exited grounded on the road")
	_check(int(car.get("tunnel_lifts")) == 0, "anti-tunnel floor never fired (lifts=0)")
	_check(worst_dy < 1.2, "no teleports: worst per-tick dy %.2fm < 1.2m" % worst_dy)
	car.queue_free()

# --- C: slow car detaches and falls cleanly ---------------------------------------
func _phase_c_slow(trk: Node3D) -> void:
	var f := _loop_feature(trk)
	if f.is_empty():
		return
	var ent: float = f.lp_ent
	var lvl: float = f.lvl
	var lR: float = f.lp_R
	# 21 m/s + weak engine: enough to carry PAST ~100 deg (below that a stalled car
	# is physically wall-borne and rolls back out of the mouth — also fun, but this
	# phase demonstrates the BALLISTIC detach), not enough to hold the apex.
	var car := _make_car(trk, 21.0, 4500.0, ent - 260.0)
	print("[loop] C: slow car (21 m/s) — expecting a stall past ~100 deg + ballistic fall...")
	var mounted := false
	var detached := false
	var max_th := 0.0
	var worst_dy := 0.0
	var min_y := 1e9
	var prev_y: float = car.global_position.y
	var settled := 0
	# ring-containment watch: while the detached fall is inside the ribbon's
	# lateral band and above road level, the car's ring radius must never cross
	# the ribbon outward (that WAS the v7.3 mesh clip)
	var worst_rout := -99.0
	var cc: Vector3 = (f.lp_e as Vector3) + Vector3.UP * lR
	var fv: Vector3 = f.lp_f
	var rv: Vector3 = f.lp_r
	var half: float = f.lp_half
	var t := 0
	while t < 9000:
		_drive_step(car, trk)
		await get_tree().physics_frame
		t += 1
		var y: float = car.global_position.y
		if t % 600 == 0:
			print("[loop]   C t=%.0fs dist=%.0f v=%.1f y=%.1f hp=%.0f fuel=%.0f" % [t / 120.0, float(car.get("distance")), car.linear_velocity.length(), y, float(car.get("health")), float(car.get("fuel"))])
		if bool(car.get("dead")) and not detached:
			break   # wrecked before the loop resolved — the asserts below will say why
		var riding: bool = not (car.get("_loop") as Dictionary).is_empty()
		if riding:
			mounted = true
			max_th = maxf(max_th, float(car.get("_loop_th")))
		elif mounted and not detached and max_th < TAU - 0.5 and bool(car.get("airborne")):
			detached = true   # ballistic release mid-wrap (not a mouth roll-out)
			prev_y = y        # measure teleports from the moment of release
		if detached:
			worst_dy = maxf(worst_dy, absf(y - prev_y))
			min_y = minf(min_y, y)
			if y > lvl + 1.5:
				var q: Vector3 = car.global_position - cc
				var lat: float = q.dot(rv)
				if lat > -half - 0.5 and lat < float(f.lp_shift) + half + 0.5:
					var qf: float = q.dot(fv)
					worst_rout = maxf(worst_rout, sqrt(qf * qf + q.y * q.y) - lR)
			if bool(car.get("dead")) or not bool(car.get("airborne")):
				settled += 1
				if settled > 90:   # grounded (or a settled wreck) for ~0.75 s = landed
					break
		prev_y = y
	_release_all()
	print("[loop] C end: t=%.1fs max_th=%.2f (%.0f deg) detached=%s dead=%s dy=%.2f min_y=%.1f (lvl=%.1f) rout=%.2f" %
		[t / 120.0, max_th, rad_to_deg(max_th), detached, bool(car.get("dead")), worst_dy, min_y, lvl, worst_rout])
	_check(mounted, "slow car mounted the loop")
	_check(max_th > 1.2, "climbed past ~70 deg before stalling (max th %.2f)" % max_th)
	_check(detached and max_th < TAU - 0.5, "detached below adhesion speed (never completed the wrap)")
	_check(worst_dy < 1.2, "ballistic fall, no teleports: worst per-tick dy %.2fm < 1.2m" % worst_dy)
	_check(worst_rout < 0.35, "fall stayed INSIDE the ring, no ribbon clip (worst r-R %+.2fm < 0.35m)" % worst_rout)
	_check(min_y > lvl - 10.0 and min_y < lvl + 2.0 * lR, "fell back inside the loop to the road (min_y %.1f)" % min_y)
	_check(settled > 90 or bool(car.get("dead")), "came to rest on the ground below (landed or wrecked)")
	car.queue_free()

# --- D: sub-mount-speed crawler gets a soft bumper, never noses through -----------
func _phase_d_crawler(trk: Node3D) -> void:
	var f := _loop_feature(trk)
	if f.is_empty():
		return
	var ent: float = f.lp_ent
	var e: Vector3 = f.lp_e
	var fv: Vector3 = f.lp_f
	# 2.5 m/s cap is below the 3 m/s mount gate; the strong engine makes sure the
	# bumper is beating the MOTOR, not a weak throttle
	var car := _make_car(trk, 2.5, 8000.0, ent - 15.0)
	print("[loop] D: crawler (2.5 m/s cap) full throttle at the mouth — expecting a soft stop at the lip...")
	var max_dfwd := -1e9
	var mounted := false
	var t := 0
	while t < 3600 and not bool(car.get("dead")):
		Input.action_press("accelerate")
		await get_tree().physics_frame
		t += 1
		max_dfwd = maxf(max_dfwd, (car.global_position - e).dot(fv))
		if not (car.get("_loop") as Dictionary).is_empty():
			mounted = true
	_release_all()
	print("[loop] D end: t=%.1fs max_dfwd=%.2fm mounted=%s dead=%s v=%.1f" %
		[t / 120.0, max_dfwd, mounted, bool(car.get("dead")), car.linear_velocity.length()])
	_check(max_dfwd > -6.0, "crawler actually reached the lip (max dfwd %.2fm > -6m)" % max_dfwd)
	_check(max_dfwd < 0.5, "crawler never nosed into the ring (max dfwd %.2fm < 0.5m)" % max_dfwd)
	_check(not mounted, "crawler never mounted (below the 3 m/s gate)")
	_check(not bool(car.get("dead")), "the bumper is gentle: crawler survives it")
	car.queue_free()
