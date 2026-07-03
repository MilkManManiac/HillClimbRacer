extends Node
## Smoothness probe: full-throttle run with metrics. Records, per physics tick while
## GROUNDED: vertical acceleration (dVy/dt) and pitch-rate jerk (change in the body's
## pitch angular velocity) — the two things the player feels as "bumping". Prints
## RMS + worst-case at the end. Run headless:
##   <godot_console> --headless --path . tests/SmoothProbe.tscn

var _f := 0
var _car: RigidBody3D
var _root: Node
var _prev_vy := 0.0
var _prev_pitch_rate := 0.0
var _acc_sq := 0.0        # sum of squared vertical accel (grounded ticks)
var _jerk_sq := 0.0       # sum of squared pitch-rate change
var _worst_acc := 0.0
var _worst_jerk := 0.0
var _samples := 0
var _air_ticks := 0
var _win_jerk0 := 0.0
var _win_acc0 := 0.0
var _win_n0 := 0

func _ready() -> void:
	# the title screen pauses the whole tree at boot — dismiss it or nothing ticks
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	if _root.has_method("_begin_game"):
		_root.call("_begin_game")
	for c in _root.get_children():
		if c is RigidBody3D:
			_car = c

func _physics_process(delta: float) -> void:
	_f += 1
	if _car == null:
		return
	if _f > 60:
		Input.action_press("accelerate")
	if _f > 120 and not bool(_car.get("dead")):
		var vy: float = _car.linear_velocity.y
		var right: Vector3 = _car.global_transform.basis.x
		var pitch_rate: float = _car.angular_velocity.dot(right)
		if bool(_car.get("airborne")):
			_air_ticks += 1
		else:
			var acc := absf(vy - _prev_vy) / delta
			var jerk := absf(pitch_rate - _prev_pitch_rate) / delta
			_acc_sq += acc * acc
			_jerk_sq += jerk * jerk
			_worst_acc = maxf(_worst_acc, acc)
			_worst_jerk = maxf(_worst_jerk, jerk)
			_samples += 1
		_prev_vy = vy
		_prev_pitch_rate = pitch_rate
		# per-window trace so a regression can be LOCALISED (spawn settle? ramps? turns?)
		if _f % 240 == 0 and _samples > 0:
			var wn := maxi(_samples - _win_n0, 1)
			print("[win] f=%4d dist=%4.0fm  jerk_rms=%.2f  acc_rms=%.2f" % [_f, float(_car.get("distance")), sqrt((_jerk_sq - _win_jerk0) / wn), sqrt((_acc_sq - _win_acc0) / wn)])
			_win_jerk0 = _jerk_sq
			_win_acc0 = _acc_sq
			_win_n0 = _samples
	if _f == 2400 or (_f > 240 and bool(_car.get("dead"))):
		var n := maxi(_samples, 1)
		print("[smooth] dist=%.0fm grounded_ticks=%d air_ticks=%d" % [float(_car.get("distance")), _samples, _air_ticks])
		print("[smooth] vert_accel  rms=%.2f m/s^2   worst=%.2f m/s^2" % [sqrt(_acc_sq / n), _worst_acc])
		print("[smooth] pitch_jerk  rms=%.2f rad/s^2 worst=%.2f rad/s^2" % [sqrt(_jerk_sq / n), _worst_jerk])
		get_tree().quit()
