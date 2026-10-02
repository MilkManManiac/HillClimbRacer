extends Node
## Chase-camera feel in numbers: a bot lap of the weekly trial, measuring every rendered
## frame how far the camera sits behind the car, how far off-centre the car drifts in
## the frame, and how hard the view swings. Data-gathering, not pass/fail: exits 0.
##   <godot_console> --headless --fixed-fps 60 --path . tests/CamProbe.tscn
## "Loose" shows up as a wide distance range and a big off-centre angle; "twitchy" as a
## high yaw-acceleration figure. Compare before/after when touching _update_camera.

const MAX_FRAMES := 60 * 150

var _root: Node
var _running := false
var _n := 0
var _dist_sum := 0.0
var _dist_min := INF
var _dist_max := 0.0
var _off_sq := 0.0
var _off_max := 0.0
var _offs: Array[float] = []
var _pitch_sq := 0.0
var _pitch_max := 0.0
var _yaw_prev := 0.0
var _rate_prev := 0.0
var _have_prev := 0
var _acc_sq := 0.0
var _acc_max := 0.0
var _top := 0.0
var _frames := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the title screen pauses the tree
	process_priority = 100                    # sample AFTER HCMain has moved the camera
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	_root.set("save_enabled", false)   # never touch the real save
	add_child(_root)
	await get_tree().process_frame
	_root.call("_on_title_mode_button", "trial")
	_root.call("_begin_game")
	await get_tree().process_frame
	_running = true

func _physics_process(_d: float) -> void:
	if not _running:
		return
	var car: RigidBody3D = _root.get("_car")
	if car and not bool(_root.get("_trial_finished")):
		_drive_step(car, car.get("terrain"))

func _process(delta: float) -> void:
	if not _running:
		return
	_frames += 1
	var car: RigidBody3D = _root.get("_car")
	var cam: Camera3D = _root.get("_cam")
	if bool(_root.get("_trial_finished")) or _frames > MAX_FRAMES:
		_report()
		return
	var speed: float = car.linear_velocity.length()
	_top = maxf(_top, speed)
	# skip the spawn drop and anything near standstill: the numbers are about driving
	if speed < 15.0 or delta <= 0.0:
		_have_prev = 0
		return
	var to_car: Vector3 = car.get_global_transform_interpolated().origin - cam.global_position
	var fwd: Vector3 = -cam.global_transform.basis.z
	var th := Vector2(to_car.x, to_car.z)
	var fh := Vector2(fwd.x, fwd.z)
	if th.length() < 0.01 or fh.length() < 0.01:
		return
	var d := th.length()
	_dist_sum += d
	_dist_min = minf(_dist_min, d)
	_dist_max = maxf(_dist_max, d)
	var off := rad_to_deg(fh.angle_to(th))
	_off_sq += off * off
	_off_max = maxf(_off_max, absf(off))
	_offs.append(absf(off))
	var pitch := rad_to_deg(atan2(to_car.y, d) - atan2(fwd.y, fh.length()))
	_pitch_sq += pitch * pitch
	_pitch_max = maxf(_pitch_max, absf(pitch))
	var yaw := atan2(fwd.x, -fwd.z)
	if _have_prev >= 1:
		var rate := rad_to_deg(wrapf(yaw - _yaw_prev, -PI, PI)) / delta
		if _have_prev >= 2:
			var acc := (rate - _rate_prev) / delta
			_acc_sq += acc * acc
			_acc_max = maxf(_acc_max, absf(acc))
		_rate_prev = rate
	_yaw_prev = yaw
	_have_prev = mini(_have_prev + 1, 2)
	_n += 1

func _report() -> void:
	_running = false
	for a in ["accelerate", "brake", "turn_left", "turn_right"]:
		Input.action_release(a)
	if _n == 0:
		print("[cam] no samples")
		get_tree().quit(0)
		return
	_offs.sort()
	var p95: float = _offs[int(float(_offs.size() - 1) * 0.95)]
	print("[cam] finished=%s time=%.2fs top=%.1f m/s samples=%d" % [
		str(bool(_root.get("_trial_finished"))), float(_root.get("_trial_time")), _top, _n])
	print("[cam] distance behind car: mean=%.2f m  min=%.2f  max=%.2f" % [_dist_sum / _n, _dist_min, _dist_max])
	print("[cam] car off-centre (yaw): rms=%.2f deg  p95=%.2f  max=%.2f" % [sqrt(_off_sq / _n), p95, _off_max])
	print("[cam] car off-aim (pitch): rms=%.2f deg  max=%.2f" % [sqrt(_pitch_sq / _n), _pitch_max])
	print("[cam] view yaw accel: rms=%.1f deg/s2  max=%.1f" % [sqrt(_acc_sq / _n), _acc_max])
	get_tree().quit(0)

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
