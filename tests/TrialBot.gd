extends Node
## Bot lap of the weekly trial track — the calibration tool for track length and medal
## times. Data-gathering, not pass/fail: always exits 0. Boots into trial mode, drives
## the AutoDrive controller from the start line to the finish, prints the time, the
## splits, the average speed and how many wrecks (automatic restarts) it took.
##   <godot_console> --headless --path . tests/TrialBot.tscn
## HC_TRIALBOT_BRAKE_ERR / HC_TRIALBOT_BRAKE_SPEED tune how hot the bot takes corners
## (heading error in rad / speed in m/s above which it lifts and brakes).

const MAX_FRAMES := 120 * 150   # 2.5 minutes of sim at 120 Hz

var _brake_err := 0.5
var _brake_speed := 18.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the title screen pauses the tree
	if OS.get_environment("HC_TRIALBOT_BRAKE_ERR") != "":
		_brake_err = float(OS.get_environment("HC_TRIALBOT_BRAKE_ERR"))
	if OS.get_environment("HC_TRIALBOT_BRAKE_SPEED") != "":
		_brake_speed = float(OS.get_environment("HC_TRIALBOT_BRAKE_SPEED"))
	var root: Node = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(root)
	await get_tree().process_frame
	root.call("_on_title_mode_button", "trial")
	root.call("_begin_game")
	await get_tree().process_frame
	print("[bot] map=%s car=%s start_s=%.0f finish_s=%.0f" % [str(root.get("_map")), str(root.get("_vehicle")), float(root.get("_trial_start_s")), float(root.get("_trial_finish_s"))])

	var first_run: int = int(root.get("_trial_run_id"))
	var top := 0.0
	var f := 0
	while f < MAX_FRAMES and not bool(root.get("_trial_finished")):
		var car: RigidBody3D = root.get("_car")   # re-read: a vehicle swap would replace it
		_drive_step(car, car.get("terrain"))
		top = maxf(top, car.linear_velocity.length())
		await get_tree().physics_frame
		f += 1
	for a in ["accelerate", "brake", "turn_left", "turn_right"]:
		Input.action_release(a)
	var wrecks: int = int(root.get("_trial_run_id")) - first_run
	if bool(root.get("_trial_finished")):
		var t: float = float(root.get("_trial_time"))
		var length: float = float(root.get("_trial_finish_s")) - float(root.get("_trial_start_s"))
		print("[bot] FINISH time=%.2fs  avg=%.1f m/s  top=%.1f m/s  wrecks=%d  splits=%s" % [t, length / t, top, wrecks, str(root.get("_run_splits"))])
	else:
		var car2: RigidBody3D = root.get("_car")
		print("[bot] DNF after %ds sim  wrecks=%d  dist=%.0f" % [f / 120, wrecks, float(car2.get("distance"))])
	get_tree().quit(0)

## AutoDrive's controller: steer at a speed-scaled look-ahead point on the centre-line,
## hold the throttle, brake when the nose is badly off line at speed.
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
	if absf(err) > _brake_err and speed > _brake_speed:
		Input.action_release("accelerate")
		Input.action_press("brake", 0.7)
	else:
		Input.action_press("accelerate")
		Input.action_release("brake")
