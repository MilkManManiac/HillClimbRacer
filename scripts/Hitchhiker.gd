extends Node
## The Hitchhiker encounter — the slice's anchor and the rule mechanic in miniature.
##
## A figure waits on the shoulder. You stop; he gets in. The rule: do NOT speak to him.
## During the ride he asks questions and opens brief "speak" windows ([E]).
##   - Stay silent the whole ride  -> at the drop-off he leaves; dread eases. You passed.
##   - Speak even once             -> he stays. He turns to you. Dread spikes and never
##                                    fully settles; he rides on, whispering. (The earned shock.)

enum State { WAITING, STANDING, SEATED, GONE, STAYED }

@export var pickup_at_turn: int = 2     ## seat him at the Nth intersection
@export var dropoff_after: int = 3      ## intersections riding before he gets out
@export var speak_window: float = 4.0   ## seconds the [E] temptation stays open

var _main: Node
var _car: Node3D
var _state: int = State.WAITING
var _turns: int = 0
var _pickup_idx: int = -1
var _spoke: bool = false

var _figure: Node3D            # world figure on the shoulder
var _passenger: Node3D         # silhouette in the seat
var _clock: float = 0.0
var _speak_open: bool = false
var _speak_until: float = 0.0
var _next_question: float = -1.0
var _questions := [
	"\"...cold night to be driving.\"",
	"\"You're not from the road, are you.\"",
	"\"What do they call you?\"",
	"\"You can talk to me. No one else will know.\"",
]
var _q_index: int = 0

func setup(main: Node, car: Node3D) -> void:
	_main = main
	_car = car
	_car.connect("turned", Callable(self, "_on_turned"))
	_car.connect("intersection_reached", Callable(self, "_on_intersection_reached"))

func _process(delta: float) -> void:
	_clock += delta

	# schedule a question shortly after a leg begins while he's riding
	if _state == State.SEATED and not _spoke and _next_question > 0.0 and _clock >= _next_question:
		_ask_question()
		_next_question = -1.0

	# the temptation window
	if _speak_open:
		if Input.is_action_just_pressed("speak"):
			_on_spoke()
		elif _clock >= _speak_until:
			_speak_open = false
			_main.call("show_subtitle", "(I kept my mouth shut.)", 2.5)
			_main.call("nudge_dread", -0.1)

	# if he stayed, keep the dread simmering
	if _state == State.STAYED:
		_main.call("nudge_dread", delta * 0.06)

# --- pickup / dropoff timing -------------------------------------------------

func _on_turned(_direction: String) -> void:
	_turns += 1
	# the leg leading to the pickup intersection just began — show him ahead
	if _state == State.WAITING and _turns == pickup_at_turn - 1:
		_spawn_figure()
	# queue a question a couple seconds into each riding leg
	if _state == State.SEATED and not _spoke:
		_next_question = _clock + 2.5

func _on_intersection_reached(idx: int) -> void:
	match _state:
		State.STANDING:
			if idx >= pickup_at_turn:
				_seat_him(idx)
		State.SEATED:
			if not _spoke and idx - _pickup_idx >= dropoff_after:
				_drop_off()

# --- beats -------------------------------------------------------------------

func _spawn_figure() -> void:
	_state = State.STANDING
	var end: Vector3 = _car.call("get_leg_end")
	var heading := (end - _car.global_position)
	heading.y = 0.0
	heading = heading.normalized()
	var perp := heading.cross(Vector3.UP).normalized()
	var pos := end + perp * 4.5   # on the shoulder
	_figure = _make_humanoid(Color(0.06, 0.06, 0.07))
	_main.add_child(_figure)
	_figure.global_position = pos
	# face the oncoming car
	var to_car := (_car.global_position - pos)
	_figure.rotation.y = atan2(to_car.x, to_car.z)
	_main.call("show_narrator", "Someone's waiting up ahead.", 4.0)

func _seat_him(idx: int) -> void:
	_state = State.SEATED
	_pickup_idx = idx
	if is_instance_valid(_figure):
		_figure.queue_free()
		_figure = null
	var body: Node3D = _main.call("get_body")
	_passenger = _make_humanoid(Color(0.05, 0.05, 0.06))
	_passenger.scale = Vector3.ONE * 0.9
	body.add_child(_passenger)
	_passenger.position = Vector3(0.45, -0.05, 1.05)  # BACK-RIGHT seat, behind you
	_passenger.rotation.y = 0.0                        # facing forward, not at you... yet
	_main.call("show_narrator", "He gets in. He doesn't look at me. Don't talk to him.", 6.0)
	_main.call("nudge_dread", 0.2)
	_next_question = _clock + 3.0

func _ask_question() -> void:
	if _q_index >= _questions.size():
		return
	var q: String = _questions[_q_index]
	_q_index += 1
	_main.call("show_subtitle", q + "\n[E] answer", speak_window)
	# look is yours — you can choose to turn and meet his eyes, or stare at the road
	_speak_open = true
	_speak_until = _clock + speak_window
	_main.call("nudge_dread", 0.12)

func _drop_off() -> void:
	_state = State.GONE
	_speak_open = false
	if is_instance_valid(_passenger):
		_passenger.queue_free()
		_passenger = null
	_main.call("show_narrator", "He's gone. I never said a word.\nThe road feels lighter.", 7.0)
	_main.call("set_dread", 0.05)

func _on_spoke() -> void:
	_speak_open = false
	_spoke = true
	_state = State.STAYED
	# he turns to face you — the earned shock
	if is_instance_valid(_passenger):
		_passenger.rotation.y = 0.6                # head/torso turns toward the driver
		_passenger.position += Vector3(-0.12, 0, -0.2)  # leans forward between the seats
	_main.call("show_subtitle", "\"...there it is. I knew you'd talk.\"", 6.0)
	_main.call("set_dread", 0.95)
	# forced turn: your head snaps back-right to look at him, then releases
	_main.call("force_look", -2.4, 0.08, 2.4)

# --- helpers -----------------------------------------------------------------

func _make_humanoid(col: Color) -> Node3D:
	var root := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = 1.0
	var torso := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.5, 1.1, 0.3)
	torso.mesh = tm
	torso.material_override = mat
	torso.position = Vector3(0, 1.05, 0)
	root.add_child(torso)
	var head := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(0.28, 0.3, 0.28)
	head.mesh = hm
	head.material_override = mat
	head.position = Vector3(0, 1.78, 0)
	root.add_child(head)
	var legs := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(0.4, 0.9, 0.28)
	legs.mesh = lm
	legs.material_override = mat
	legs.position = Vector3(0, 0.45, 0)
	root.add_child(legs)
	return root
