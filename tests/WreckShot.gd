extends Node
## Boots the real game, drives briefly, forces a health wreck, and captures the
## explosion timeline as PNGs (~0.1 / 0.5 / 1.5 / 3.0 s after death) so the fireball
## can be verified visually. Run WITHOUT --headless; delete the PNGs after looking.

var _rf := 0
var _began := false
var _killed := false
var _t_dead := -1.0
var _shots_done: Array[bool] = [false, false, false, false]
const SHOT_TIMES := [0.1, 0.5, 1.5, 3.0]

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var main: Node = load("res://scenes/HillClimb.tscn").instantiate()
	main.set("save_enabled", false)
	add_child(main)

func _process(delta: float) -> void:
	_rf += 1
	var main := get_child(0)
	if _rf == 20 and not _began:
		_began = true
		main.call("_begin_game")
	# let the car settle + roll a moment so the wreck happens on real road
	if _rf == 140 and not _killed:
		_killed = true
		var car: Node = main.get("_car")
		if car:
			# diagnostic toggle: silence chosen emitters via --diag=embers,debris,fire,smoke
			for arg in OS.get_cmdline_user_args():
				if arg.begins_with("--diag="):
					var names := {"embers": "_expl_embers", "debris": "_expl_debris",
							"fire": "_expl_fire", "smoke": "_expl_smoke"}
					for key in arg.trim_prefix("--diag=").split(","):
						if names.has(key) and car.get(names[key]):
							(car.get(names[key]) as GPUParticles3D).amount = 1
			car.set("health", 0.0)
		_t_dead = 0.0
	if _t_dead >= 0.0:
		_t_dead += delta
		# the death shop covers the whole screen — hide it so the shots show the FX
		var shop: Node = main.get("_shop")
		if shop:
			shop.set("visible", false)
		for i in range(SHOT_TIMES.size()):
			if not _shots_done[i] and _t_dead >= float(SHOT_TIMES[i]):
				_shots_done[i] = true
				_snap(i)
				return

func _snap(i: int) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://wreck_shot_%d.png" % i)
	if i == SHOT_TIMES.size() - 1:
		get_tree().quit()
