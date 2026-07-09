extends Node
## Headless probe for the skid-mark ribbons (HCSkid.gd + the HCCar feed).
## Phase A drives the pool API directly (segments lay, pool caps, clear wipes);
## phase B is the integration path: accelerate to speed, slam the brakes, and
## expect real brake-lock rubber on the road; a run reset must wipe it again.

var _f := 0
var _fails := 0
var _phase := "boot"
var _main: Node
var _car: Node
var _skid: Node

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_main = load("res://scenes/HillClimb.tscn").instantiate()
	_main.set("save_enabled", false)
	add_child(_main)

func _ok(cond: bool, label: String) -> void:
	print("[skid] %s   %s" % ["OK " if cond else "FAIL", label])
	if not cond:
		_fails += 1

func _count() -> int:
	var mm: MultiMesh = _skid.get("_mm")
	return mm.visible_instance_count

func _physics_process(_d: float) -> void:
	_f += 1
	if _phase == "boot" and _f == 20:
		_main.call("_begin_game")
		_phase = "settle"
	elif _phase == "settle" and _f == 140:
		_car = _main.get("_car")
		_skid = _car.get("_skid")
		_ok(_car != null and _skid != null, "car + skid pool found")
		# --- phase A: pool API ------------------------------------------------
		var n := Vector3.UP
		_skid.call("lay", 1, Vector3(5, 1, 0), n, 0.4, 0.8)     # opens the strip
		_skid.call("lay", 1, Vector3(5, 1, 40), n, 0.4, 0.8)    # 40 m jump = strip break
		var before: int = _count()
		_skid.call("lay", 1, Vector3(5, 1, 41), n, 0.4, 0.8)
		_ok(_count() == before + 1, "teleport breaks the strip, next contact reconnects")
		for i in range(700):   # 700 lays on one track > pool of 600 must cap
			_skid.call("lay", 0, Vector3(0.0, 1.0, float(i)), n, 0.4, 0.8)
		_ok(_count() > 0, "segments laid via API (count=%d)" % _count())
		_ok(_count() <= 600, "pool capped at 600 (count=%d)" % _count())
		_skid.call("clear_all")
		_ok(_count() == 0, "clear_all wipes every mark")
		# --- phase B: drive for real -------------------------------------------
		Input.action_press("accelerate")
		_phase = "drive"
	elif _phase == "drive":
		var v: float = (_car.get("linear_velocity") as Vector3).length()
		if v > 15.5 or _f > 1800:   # lock threshold is 15; the stock van tops out ~16
			_ok(v > 15.5, "reached brake-lock speed (v=%.1f)" % v)
			Input.action_release("accelerate")
			Input.action_press("brake")
			_phase = "brake"
	elif _phase == "brake" and _f >= 0:
		# give the lock a second of road, then check rubber got laid
		_phase = "brakewait"
		_f = 0
	elif _phase == "brakewait" and _f == 120:
		Input.action_release("brake")
		_ok(_count() > 0, "brake-lock laid rubber (count=%d)" % _count())
		_car.call("reset_run", Vector3(0, 3, 0))
		_phase = "reset"
		_f = 0
	elif _phase == "reset" and _f == 10:
		_ok(_count() == 0, "reset_run cleared the marks (count=%d)" % _count())
		print("[skid] %s" % ("ALL PASS" if _fails == 0 else "%d FAILED" % _fails))
		get_tree().quit(0 if _fails == 0 else 1)
