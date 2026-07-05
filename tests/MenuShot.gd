extends Node
## Renders the four overhauled UI states to PNGs for visual review (run WITHOUT
## --headless): title screen, pause menu, time-trial HUD mid-run, and the wreck shop.
## TitleShot.gd pattern — real renderer, brief window, save, quit. Delete the PNGs
## after looking at them.

var _root: Node
var _car: RigidBody3D
var _f := 0
var _stage := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	# this harness runs the REAL renderer (not --headless), so HCMain would default to
	# save_enabled=true — and this script mutates mode/money/wreck state, which must
	# never leak into the developer's actual save
	_root.set("save_enabled", false)
	add_child(_root)

func _process(_d: float) -> void:
	_f += 1
	# NOTE: _snap() is async (it awaits frame_post_draw) — the capture lands a frame or
	# two AFTER the call. Every state mutation therefore happens on a LATER frame than
	# its snap, or the screenshot records the post-mutation screen (learned the hard way:
	# the first pause shot captured an already-resumed run).
	match _stage:
		0:   # title screen up (tree paused)
			if _f == 30:
				_snap("res://shot_title.png")
			elif _f == 40:
				_root.call("_begin_game")
				_root.call("_toggle_pause_menu")
				_f = 0
				_stage = 1
		1:   # pause menu open
			if _f == 20:
				_snap("res://shot_pause.png")
			elif _f == 30:
				_root.call("_toggle_pause_menu")   # resume
				_root.call("_on_title_mode_button", "trial")
				_root.call("_restart")
				for c in _root.get_children():
					if c is RigidBody3D:
						_car = c
				_f = 0
				_stage = 2
		2:   # drive a few seconds so the trial timer + HUD are live
			Input.action_press("accelerate")
			if _f == 240:
				_snap("res://shot_trial_hud.png")
			elif _f == 250:
				Input.action_release("accelerate")
				if _car:
					_car.set("health", 0.0)   # trigger the wreck shop
				_f = 0
				_stage = 3
		3:
			if _f == 30:
				_snap("res://shot_shop.png")
			elif _f == 40:
				get_tree().quit()

func _snap(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("[shot] saved " + path)
