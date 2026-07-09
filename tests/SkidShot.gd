extends Node
## Visual harness for the skid ribbons: boots canyon, drives into a deliberate
## drift, then parks an oblique camera over the trail and saves PNGs so the marks
## can be eyeballed (curved twin lines, no z-fighting, no floating quads).
## Run WITHOUT --headless; delete the PNGs after looking at them.

var _f := 0
var _phase := "boot"
var _main: Node
var _car: RigidBody3D
var _cam: Camera3D
var _shot := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_main = load("res://scenes/HillClimb.tscn").instantiate()
	_main.set("save_enabled", false)
	add_child(_main)

func _physics_process(_d: float) -> void:
	_f += 1
	if _phase == "boot" and _f == 20:
		if _main.has_method("select_map"):
			_main.call("select_map", "hills")
		_main.call("_begin_game")
		_car = _main.get("_car")
		Input.action_press("accelerate")
		_phase = "drive"
	elif _phase == "drive" and (_car.linear_velocity.length() > 15.0 or _f > 900):
		Input.action_press("turn_left")   # hard lock at speed breaks rear grip -> drift
		_phase = "drift"
		_f = 0
	elif _phase == "drift" and _f == 210:
		Input.action_release("turn_left")
		Input.action_release("accelerate")
		Input.action_press("brake")       # brake-lock finish for the all-wheel marks
		_phase = "lock"
		_f = 0
	elif _phase == "lock" and _f == 90:
		Input.action_release("brake")
		# oblique camera over the trail, looking back along where we came from
		var vel := _car.linear_velocity
		var heading := Vector3(vel.x, 0, vel.z)
		heading = heading.normalized() if heading.length() > 0.5 else Vector3.FORWARD
		_cam = Camera3D.new()
		add_child(_cam)
		_cam.global_position = _car.global_position + heading * 6.0 + Vector3.UP * 9.0
		_cam.look_at(_car.global_position - heading * 14.0, Vector3.UP)
		_cam.make_current()
		_phase = "shoot"
		_f = 0
	elif _phase == "shoot" and _f % 5 == 0:
		_cam.make_current()   # the chase cam reclaims current each frame — take it back
		_snap()

func _snap() -> void:
	_shot += 1
	var idx := _shot
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://skid_shot_%d.png" % idx)
	if idx >= 2:
		get_tree().quit()
