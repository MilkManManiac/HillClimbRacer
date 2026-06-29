extends Node
## Headless smoke test: instances the main scene and simulates A/D turns plus one
## [E] "speak" so the full Hitchhiker path (stand -> seat -> question/glance -> spoke
## -> stayed) executes. Run:
##   godot --headless --path . res://tests/SelfTest.tscn --quit-after 2000
## Pure dev tooling; not shipped.

var _main: Node
var _car: Node3D
var _frame: int = 0
var _press_release_at: int = -1
var _turns_done: int = 0
var _spoke_sent: bool = false

func _ready() -> void:
	var packed := load("res://scenes/Main.tscn")
	_main = packed.instantiate()
	add_child(_main)
	await get_tree().process_frame
	_car = _main.call("get_car")
	print("[selftest] main + car ready")

func _physics_process(_delta: float) -> void:
	_frame += 1
	if _car == null:
		return

	# release any held action one frame after pressing
	if _press_release_at == _frame:
		Input.action_release("turn_right")
		Input.action_release("speak")

	# at each intersection, turn right
	if _car.call("is_stopped") and _frame > _press_release_at + 5:
		Input.action_press("turn_right")
		_press_release_at = _frame + 1
		_turns_done += 1
		print("[selftest] turn %d (turn_count=%d)" % [_turns_done, _car.call("get_turn_count")])

	# once he's aboard and we're rolling, answer him once to fire the shock branch
	if not _spoke_sent and _turns_done >= 4 and not _car.call("is_stopped"):
		Input.action_press("speak")
		_press_release_at = _frame + 1
		_spoke_sent = true
		print("[selftest] spoke")

	if _frame >= 7000:
		print("[selftest] done, no crash (spoke_sent=%s)" % _spoke_sent)
		get_tree().quit()
