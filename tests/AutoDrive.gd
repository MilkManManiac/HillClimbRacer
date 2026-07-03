extends Node
## Autonomous test-driver bot: plays all three HC maps like a decent (not perfect)
## human, gathering full-run playability data. Data-gathering probe, not pass/fail —
## always exits 0. Run headless:
##   <godot_console> --headless --path . tests/AutoDrive.tscn
##
## Controller (see _drive_step): steers toward HCTrack.path_ahead() with a speed-scaled
## look-ahead distance, proportional steering strength, and lifts off the throttle onto
## the brake through hard corners taken at speed. Mirrors the MapProbe boot/map-switch
## pattern (process_mode ALWAYS + _begin_game past the title pause).

const HCMainScript := preload("res://scripts/hc/HCMain.gd")
const MAP_KEYS := ["hills", "canyon", "alpine"]
const MAX_FRAMES := 7200      # 60s @ 60Hz physics tick cap per map
const SAMPLE_EVERY := 600     # 5s

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root_scene := load("res://scenes/HillClimb.tscn") as PackedScene
	var summary: Array = []
	for key in MAP_KEYS:
		var result: Dictionary = await _run_map(root_scene, key)
		summary.append(result)
	_release_all()
	print("[auto] SUMMARY")
	for r in summary:
		print("[auto]   %s: dist=%.1fm t=%.1fs dead=%s fuel=%.1f hp=%.1f cause=%s" %
			[r.map, r.dist, r.t, r.dead, r.fuel, r.hp, r.cause])
	get_tree().quit(0)

## Boot one HillClimb instance, switch to `key`, drive with the controller for up to
## MAX_FRAMES physics ticks (or until dead), sampling telemetry every SAMPLE_EVERY.
func _run_map(root_scene: PackedScene, key: String) -> Dictionary:
	var inst: Node3D = root_scene.instantiate()
	add_child(inst)
	await get_tree().process_frame
	if inst.has_method("select_map"):
		inst.call("select_map", key)
	if inst.has_method("_begin_game"):
		inst.call("_begin_game")
	await get_tree().process_frame

	var car: RigidBody3D = null
	for c in inst.get_children():
		if c is RigidBody3D:
			car = c
	if car == null:
		print("[auto] %s FAIL no car found" % key)
		inst.queue_free()
		await get_tree().process_frame
		return {"map": key, "dist": 0.0, "t": 0.0, "dead": true, "fuel": 0.0, "hp": 0.0, "cause": "no car found"}

	var terrain: Node = car.get("terrain")
	_release_all()

	var t := 0
	while t < MAX_FRAMES and not bool(car.get("dead")):
		_drive_step(car, terrain)
		await get_tree().physics_frame
		t += 1
		if t % SAMPLE_EVERY == 0:
			_sample(key, inst, car, terrain, t)

	_release_all()
	var result: Dictionary = _verdict(key, inst, car, terrain, t)
	inst.queue_free()
	await get_tree().process_frame
	return result

## One control tick: steer toward a speed-scaled look-ahead point on the road
## centre-line, hold the throttle, and brake through corners taken too hot.
func _drive_step(car: RigidBody3D, terrain: Node) -> void:
	if terrain == null:
		Input.action_press("accelerate")
		return
	var pos: Vector3 = car.global_position
	var vel: Vector3 = car.linear_velocity
	var speed: float = vel.length()
	var aim_dist: float = clampf(speed * 0.9, 12.0, 40.0)
	var aim: Vector3 = terrain.call("path_ahead", pos, aim_dist)

	var fwd: Vector3 = -car.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() > 0.001:
		fwd = fwd.normalized()
	var right: Vector3 = car.global_transform.basis.x
	right.y = 0.0
	if right.length() > 0.001:
		right = right.normalized()
	var to_aim: Vector3 = aim - pos
	to_aim.y = 0.0
	var err := 0.0
	if to_aim.length() > 0.01 and fwd.length() > 0.001:
		to_aim = to_aim.normalized()
		err = atan2(to_aim.dot(right), to_aim.dot(fwd))   # signed heading error (rad); + = aim to the right

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

	# corner management: a hard heading error at real speed means we're overcooking the
	# bend — lift off the gas and brake until the nose comes back in line.
	if absf(err) > 0.5 and speed > 18.0:
		Input.action_release("accelerate")
		Input.action_press("brake", 0.7)
	else:
		Input.action_press("accelerate")
		Input.action_release("brake")

## Release every drive action — called between maps and at the very end so no held
## input state leaks across a fresh HillClimb instance.
func _release_all() -> void:
	for a in ["accelerate", "brake", "turn_left", "turn_right"]:
		Input.action_release(a)

## Periodic telemetry line (every SAMPLE_EVERY physics frames == 5s of sim time).
func _sample(key: String, inst: Node3D, car: RigidBody3D, terrain: Node, frame: int) -> void:
	var t_s: float = float(frame) / 120.0   # project runs physics at 120 Hz
	var dist: float = float(car.get("distance"))
	var speed: float = car.linear_velocity.length()
	var fuel: float = float(car.get("fuel"))
	var hp: float = float(car.get("health"))
	var offroad := 0.0
	if terrain != null:
		var lat: float = float(terrain.call("lateral_off", car.global_position))
		var half: float = maxf(float(terrain.call("road_half_here", car.global_position)), 0.001)
		offroad = lat / half
	print("[auto] %s t=%ds dist=%.1fm speed=%.1fm/s fuel=%.1f hp=%.1f offroad=%.2f" %
		[key, int(t_s), dist, speed, fuel, hp, offroad])
	if key == "canyon":
		var sprint_active: bool = bool(inst.get("_sprint_active"))
		var sprint_time: float = float(inst.get("_sprint_time"))
		var next_cp: float = float(inst.get("_sprint_next_checkpoint"))
		print("[auto] canyon t=%ds sprint_time=%.1fs next_checkpoint=%.1fm (dist=%.1fm, %.1fm to go)" %
			[int(t_s), sprint_time, next_cp, dist, next_cp - dist])

## End-of-run verdict: distance/state at death or timeout, plus an inferred cause.
func _verdict(key: String, inst: Node3D, car: RigidBody3D, terrain: Node, frame_ended: int) -> Dictionary:
	var t_s: float = float(frame_ended) / 120.0   # project runs physics at 120 Hz
	var dist: float = float(car.get("distance"))
	var dead: bool = bool(car.get("dead"))
	var fuel: float = float(car.get("fuel"))
	var hp: float = float(car.get("health"))
	# HCCar._physics_process kills the car via `if health <= 0.0 or (fuel <= 0.0 and
	# speed < 0.5 and _grounded): dead = true` — health<=0 is checked FIRST and is set
	# by three different paths (sprint timer, off-road, hard landing), so hp must be
	# examined before falling back to the fuel-exhaustion (coast-to-a-stop) case, or
	# a sprint/crash/off-road death that happens to occur after the tank ran dry gets
	# misreported as "fuel exhausted" just because fuel also reads 0 at that point.
	var cause := "timeout (still alive at frame cap)"
	if dead:
		if hp <= 0.0:
			if key == "canyon" and float(inst.get("_sprint_time")) <= 0.05:
				cause = "sprint timer expired"
			else:
				var lat := 0.0
				var half := 1.0
				if terrain != null:
					lat = float(terrain.call("lateral_off", car.global_position))
					half = maxf(float(terrain.call("road_half_here", car.global_position)), 0.001)
				if lat > half:
					cause = "drove off-road (past road_half)"
				else:
					cause = "crash / hard-landing damage (hp hit 0 on-road)"
		elif fuel <= 0.5:
			cause = "fuel exhausted (coasted to a stop, hp still %.0f)" % hp
		else:
			cause = "dead (unresolved: fuel>0, hp>0)"
	print("[auto] %s END t=%.1fs dist=%.1fm dead=%s fuel=%.1f hp=%.1f cause=%s" %
		[key, t_s, dist, dead, fuel, hp, cause])
	return {"map": key, "t": t_s, "dist": dist, "dead": dead, "fuel": fuel, "hp": hp, "cause": cause}
