extends Node
## Renders the weekly-trial screens to PNGs for visual review (run WITHOUT --headless;
## takes about a minute and a half because the bot drives a full lap in real time, then
## part of a second one against its own ghost): the trial title
## card, the start line, a split call-out, the approach to the finish gate, and the
## results panel. TitleShot.gd pattern — real renderer, save, quit. PNGs land in
## HC_SHOT_DIR (default res://) — delete them after looking.

var _root: Node
var _f := 0
var _stage := 0
var _dir := "res://"
var _driving := false
var _title_snapped := -1
var _slow := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.get_environment("HC_SHOT_DIR") != "":
		_dir = OS.get_environment("HC_SHOT_DIR").rstrip("/") + "/"
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	_root.set("save_enabled", false)   # real renderer = saves would be on; never touch the real save
	add_child(_root)

func _physics_process(_d: float) -> void:
	if not _driving:
		return
	var car: RigidBody3D = _root.get("_car")
	if car == null or bool(_root.get("_trial_finished")):
		for a in ["accelerate", "brake", "turn_left", "turn_right"]:
			Input.action_release(a)
		return
	_drive_step(car, car.get("terrain"))

func _process(_d: float) -> void:
	_f += 1
	# _snap() is async — the capture lands a frame or two after the call, so every state
	# change happens on a LATER frame than the snap before it.
	match _stage:
		0:   # title screen, switched to the weekly trial
			if _f == 20:
				_root.call("_on_title_mode_button", "trial")
			elif _f >= 50 and _title_snapped < 0 and _land_ready():
				# the title's backdrop is the live scene: wait for the terrain to stream in
				_title_snapped = _f
				_snap("trial_title.png")
			elif _title_snapped > 0 and _f == _title_snapped + 6:
				_root.call("_on_title_mode_button", "classic")
			elif _title_snapped > 0 and _f == _title_snapped + 30:
				_snap("classic_title.png")
			elif _title_snapped > 0 and _f == _title_snapped + 36:
				_root.call("_on_title_mode_button", "trial")
			elif _title_snapped > 0 and _f == _title_snapped + 50:
				_root.call("_begin_game")
				_f = 0
				_stage = 1
		1:   # sitting on the grid, start gate ahead
			if _f == 50:
				_snap("trial_start.png")
			elif _f == 60:
				_driving = true
				_stage = 2
		2:   # first split call-out
			if (_root.get("_run_splits") as Array).size() >= 1:
				_f = 0
				_stage = 3
		3:
			if _f == 12:
				_snap("trial_split.png")
				_stage = 4
		4:   # finish gate coming up
			var car: RigidBody3D = _root.get("_car")
			if float(car.get("distance")) > float(_root.get("_trial_finish_s")) - 110.0:
				_snap("trial_finish_gate.png")
				_stage = 5
		5:
			if bool(_root.get("_trial_finished")):
				_f = 0
				_stage = 6
		6:   # results panel
			if _f == 50:
				_snap("trial_results.png")
			elif _f == 70:
				# second run, a little slower, so the ghost of the first pulls ahead and
				# the split shows a real gap
				_root.call("_restart")
				_slow = true
				_stage = 7
		7:
			if (_root.get("_run_splits") as Array).size() >= 1:
				_f = 0
				_stage = 8
		8:
			if _f == 12:
				_snap("trial_ghost_split.png")
			elif _f == 30:
				get_tree().quit()

func _land_ready() -> bool:
	var terrain: Node = _root.get("_terrain")
	return terrain == null or not terrain.has_method("land_settled") or bool(terrain.call("land_settled"))

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
		Input.action_press("accelerate", 0.82 if _slow else 1.0)
		Input.action_release("brake")
