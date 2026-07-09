extends Node
## THROWAWAY: screenshots to eyeball the coin/guardrail visual upgrade pass.
## Captures: (1) hills daytime close-up of rail + coins, (2) midnight night close-up
## (reflector glow), (3) a collect-burst moment. Run WITHOUT --headless. Delete the
## PNGs after review — this file is not part of the game.

var _root: Node
var _cam: Camera3D
var _rf := 0
var _stage := 0
var _burst_wait := -1

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true
	_boot("hills")

func _boot(map_key: String) -> void:
	if _root:
		_root.queue_free()
	_root = load("res://scenes/HillClimb.tscn").instantiate()
	add_child(_root)
	await get_tree().process_frame
	_root.set("save_enabled", false)
	_root.call("select_map", map_key)
	_root.call("_begin_game")
	_rf = 0

func _car() -> RigidBody3D:
	for c in _root.get_children():
		if c is RigidBody3D:
			return c
	return null

func _process(_d: float) -> void:
	_rf += 1
	var car := _car()
	if car == null:
		return
	_cam.make_current()   # the game builds its own chase camera on _begin_game/_apply_map and can steal "current" — reclaim every frame
	if _stage == 0 or _stage == 1:
		# drive a stretch so tiles/rails/pickups stream in, then frame a close-up
		# of the roadside (rail + coin line) from a fixed offset off the car.
		if _rf > 20 and _rf < 180:
			Input.action_press("accelerate")
		if _rf == 180:
			Input.action_release("accelerate")
		if _rf >= 220 and _rf < 280:
			var p := car.global_position
			var fwd: Vector3 = -car.global_transform.basis.z
			var right: Vector3 = car.global_transform.basis.x
			_cam.global_position = p - fwd * 2.0 + right * 13.0 + Vector3(0, 2.6, 0)
			_cam.look_at(p + fwd * 3.0 + right * 8.0 + Vector3(0, 1.0, 0), Vector3.UP)
		if _rf == 280:
			var name := "hills_day_wide" if _stage == 0 else "midnight_night_wide"
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://pickupshot_%s.png" % name)
		if _rf >= 300 and _rf < 340:
			# macro: standing just past the rail looking straight back across the
			# road at its W-beam profile + a post/reflector, close range
			var p := car.global_position
			var fwd: Vector3 = -car.global_transform.basis.z
			var right: Vector3 = car.global_transform.basis.x
			_cam.global_position = p - fwd * 4.0 + right * 19.0 + Vector3(0, 1.8, 0)
			_cam.look_at(p + fwd * 4.0 + right * 15.0 + Vector3(0, 0.85, 0), Vector3.UP)
		if _rf == 340:
			var name := "hills_day_macro" if _stage == 0 else "midnight_night_macro"
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://pickupshot_%s.png" % name)
			if _stage == 0:
				_stage = 1
				_boot("midnight")
			else:
				_stage = 2
				_boot("hills")
		return
	if _stage == 2:
		# stage 2: trigger + capture a collect burst up close, from a FIXED world
		# camera near the pickup's own spot (not chasing the car, which can go
		# airborne on teleport and hide the ground-level burst/ring behind itself).
		if _rf == 5:
			Input.action_press("accelerate")
		if _rf > 30 and _burst_wait < 0:
			var nodes: Array = _root.get("_terrain").get("_pk_nodes")
			if nodes.size() > 0:
				var target: Node3D = nodes[0].node
				if is_instance_valid(target):
					var burst_pos: Vector3 = target.global_position
					# keep the car's own (already-grounded) height — only slide it
					# sideways onto the pickup's x/z so it drives through at ground
					# level instead of falling from the pickup's floating height
					car.global_position = Vector3(burst_pos.x, car.global_position.y, burst_pos.z)
					car.linear_velocity = Vector3.ZERO
					_cam.global_position = burst_pos + Vector3(4.5, 2.0, 4.5)
					_cam.look_at(burst_pos, Vector3.UP)
					_burst_wait = 0
		elif _burst_wait >= 0:
			_burst_wait += 1
			if _burst_wait == 14:   # ring mid-expansion, particles still airborne
				Input.action_release("accelerate")
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png("res://pickupshot_burst.png")
				get_tree().quit()
