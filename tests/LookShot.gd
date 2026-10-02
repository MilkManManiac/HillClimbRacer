extends Node
## Renders the realistic look for visual review (run WITHOUT --headless, ~25 s): boots
## the weekly trial, drops the car at a handful of spots along the track with the bot
## driving, and saves a chase-camera frame at each, plus a few fixed beauty angles.
## TitleShot.gd pattern — real renderer, save, quit. PNGs land in HC_SHOT_DIR (default
## res://) — delete them after looking.
##   HC_SHOT_S      comma list of arc-lengths to visit (default below)
##   HC_SHOT_MAP    map key (default: the weekly trial track)
##   HC_SHOT_ORBIT  "1" also saves side / front / high orbit frames at each spot
##   HC_SHOT_DRIFT  "1" the bot pulls the handbrake through bends (smoke / skid review)

const DEFAULT_S := [150.0, 620.0, 1180.0, 1750.0, 2400.0]

var _root: Node
var _dir := "res://"
var _stops: Array = []
var _stop := -1
var _f := 0
var _stage := 0
var _orbit := false
var _orbit_i := 0
var _free_cam: Camera3D
var _drift := false         # HC_SHOT_DRIFT=1
var _perf := false          # HC_SHOT_PERF=1: no stills, just drive 20 s and report frame times
var _perf_t := 0.0
var _perf_frames := 0
var _perf_worst := 0.0
var _perf_slow := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.get_environment("HC_SHOT_DIR") != "":
		_dir = OS.get_environment("HC_SHOT_DIR").rstrip("/") + "/"
	_orbit = OS.get_environment("HC_SHOT_ORBIT") == "1"
	_perf = OS.get_environment("HC_SHOT_PERF") == "1"
	_drift = OS.get_environment("HC_SHOT_DRIFT") == "1"
	var s_env := OS.get_environment("HC_SHOT_S")
	if s_env != "":
		for part in s_env.split(","):
			_stops.append(float(part))
	else:
		_stops = DEFAULT_S.duplicate()
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	_root.set("save_enabled", false)   # never touch the real save
	add_child(_root)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

func _physics_process(_d: float) -> void:
	if _stage < 2:
		return
	var car: RigidBody3D = _root.get("_car")
	if car and not bool(_root.get("_trial_finished")):
		_drive_step(car, car.get("terrain"))

func _process(_d: float) -> void:
	_f += 1
	if _stage == 9:
		# skip the first 2 s (first-use shader compiles), then tally real frame times
		_perf_t += _d
		if _perf_t > 2.0:
			_perf_frames += 1
			_perf_worst = maxf(_perf_worst, _d)
			if _d > 1.0 / 50.0:
				_perf_slow += 1
		if _perf_t > 22.0:
			print("[perf] avg fps=%.1f  worst frame=%.1f ms  frames over 20 ms=%d of %d" % [
				float(_perf_frames) / (_perf_t - 2.0), _perf_worst * 1000.0, _perf_slow, _perf_frames])
			get_tree().quit()
		return
	match _stage:
		0:
			if _f == 10:
				var mk := OS.get_environment("HC_SHOT_MAP")
				if mk != "":
					_root.call("select_map", mk)
				else:
					_root.call("_on_title_mode_button", "trial")
			elif _f == 30:
				_root.call("_begin_game")
				_stage = 1
				_f = 0
		1:
			if _f > 5:
				if _perf:
					_stage = 9
				else:
					_next_stop()
		2:   # let the bot settle into the road and the terrain stream in
			var terrain: Node = _root.get("_terrain")
			var settled: bool = not terrain.has_method("land_settled") or bool(terrain.call("land_settled"))
			if (_f >= 110 and settled) or _f > 600:
				var vp := get_viewport().get_viewport_rid()
				print("[look] s=%d  fps=%d  cpu=%.1fms gpu=%.1fms  draws=%d  tris=%dk" % [
					int(_stops[_stop]), int(Engine.get_frames_per_second()),
					RenderingServer.viewport_get_measured_render_time_cpu(vp),
					RenderingServer.viewport_get_measured_render_time_gpu(vp),
					int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
					int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)) / 1000])
				_snap("look_%d.png" % int(_stops[_stop]))
				_stage = 3 if _orbit else 4
				_f = 0
				_orbit_i = 0
		3:   # fixed beauty angles around the car (free camera, the game keeps running)
			if _f == 3:
				_place_free_cam(_orbit_i)
			elif _f == 6:
				_snap("look_%d_o%d.png" % [int(_stops[_stop]), _orbit_i])
			elif _f == 9:
				_orbit_i += 1
				_f = 0
				if _orbit_i >= 4:
					if _free_cam:
						_free_cam.current = false
					(_root.get("_cam") as Camera3D).current = true
					_stage = 4
		4:
			if _f == 4:
				_next_stop()

func _next_stop() -> void:
	_stop += 1
	if _stop >= _stops.size():
		get_tree().quit()
		return
	var car: RigidBody3D = _root.get("_car")
	var terrain: Node = _root.get("_terrain")
	var s: float = _stops[_stop]
	var here: Vector3 = terrain.call("point_at_s", s)
	var ahead: Vector3 = terrain.call("point_at_s", s + 6.0)
	var fwd := (ahead - here)
	fwd.y = 0.0
	fwd = fwd.normalized()
	car.global_transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), here + Vector3(0, 1.2, 0))
	car.linear_velocity = fwd * 42.0
	car.angular_velocity = Vector3.ZERO
	var cam: Camera3D = _root.get("_cam")
	cam.global_position = here - fwd * 9.0 + Vector3(0, 4.0, 0)
	_root.set("_cam_heading", fwd)
	_root.set("_cam_look_ready", false)
	_stage = 2
	_f = 0

func _place_free_cam(i: int) -> void:
	var car: RigidBody3D = _root.get("_car")
	if _free_cam == null:
		_free_cam = Camera3D.new()
		_free_cam.fov = 50.0
		_free_cam.far = 6000.0
		add_child(_free_cam)
	var b := car.global_transform.basis
	var p := car.global_position
	var offs := [
		-b.z * 5.5 + b.x * 4.2 + Vector3(0, 1.1, 0),      # front three-quarter, low
		b.x * 6.5 + b.z * 1.0 + Vector3(0, 1.6, 0),       # side on
		b.z * 30.0 + Vector3(0, 55.0, 0) - b.x * 20.0,    # high, looking over the landscape
		-b.z * 3.2 - b.x * 3.4 + Vector3(0, 0.7, 0),      # close on the front-left wheel
	]
	_free_cam.global_position = p + offs[i]
	_free_cam.look_at(p + Vector3(0, 0.5, 0), Vector3.UP)
	_free_cam.current = true

func _snap(fname: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_dir + fname)

## TrialBot's centre-line controller.
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
	if to_aim.length() > 0.01 and fwd.length() > 0.001 and right.length() > 0.001:
		to_aim = to_aim.normalized()
		err = atan2(to_aim.dot(right.normalized()), to_aim.dot(fwd.normalized()))
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
	if _drift and absf(err) > 0.1 and speed > 20.0:
		Input.action_press("handbrake")
	else:
		Input.action_release("handbrake")
