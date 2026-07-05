extends Node3D
## THROWAWAY visual harness: renders the Gravity Works loop-de-loop and saves PNGs.
## Run WITHOUT --headless:  <godot_console> --path . tests/LoopShot.tscn
##   loopshot_side.png   — whole circle from the side (static)
##   loopshot_mouth.png  — mount view up the approach (static)
##   loopshot_wall.png   — car climbing the wall at ~85 deg (side cam)
##   loopshot_apex.png   — car INVERTED at the apex through an HCMain-style chase
##                         camera (heading-from-velocity + occlusion + floor rules)

const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")
const HCCarScript := preload("res://scripts/hc/HCCar.gd")
const GRAVITY := {
	"stunts": "loop:2450,overpass:650,corkscrew:1500:2,overpass:2900,corkscrew:3900:1",
	"straight_bias": 0.6, "turn_radius_min": 40.0, "turn_radius_max": 80.0,
	"road_half": 18.0, "road_half_turn": 26.0,
	"hill_amp": 5.0, "noise_frequency": 0.0024,
	"gap_start": 5600.0, "gap_spacing": 420.0,
	"path_seed": 777333, "noise_seed": 424,
	"grass_color": Color(0.30, 0.42, 0.24), "asphalt_color": Color(0.15, 0.15, 0.17),
	"rail_band_color": Color(0.95, 0.45, 0.1),
}

var _trk: Node3D
var _car: RigidBody3D
var _cam: Camera3D
var _f: Dictionary
var _phase := "warm"      # warm -> side -> mouth -> drive (wall/apex) -> done
var _wait := 0
var _snapping := false
var _shot_wall := false
var _shot_apex := false
var _shot_fix := false
var _cam_heading := Vector3(0, 0, -1)

func _ready() -> void:
	for a in ["accelerate", "brake", "turn_left", "turn_right", "dive", "boost",
			"pitch_up", "pitch_down", "roll_left", "roll_right", "recover"]:
		if not InputMap.has_action(a):
			InputMap.add_action(a)
	_trk = Node3D.new()
	_trk.set_script(HCTrackScript)
	for k in GRAVITY:
		_trk.set(k, GRAVITY[k])
	add_child(_trk)
	var rep: Dictionary = _trk.call("stunt_report")
	for f in rep.features:
		if bool((f as Dictionary).get("loop", false)):
			_f = f
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, 35, 0)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	add_child(sun)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)
	_cam = Camera3D.new()
	_cam.far = 2000.0
	add_child(_cam)
	_cam.current = true
	# park a dummy target at the loop so its tiles (incl. the ribbon) stream in
	var tgt := Node3D.new()
	add_child(tgt)
	tgt.global_position = _centre()
	_trk.call("set_target", tgt)

func _centre() -> Vector3:
	var e: Vector3 = _f.lp_e
	return e + Vector3.UP * float(_f.lp_R) + (_f.lp_r as Vector3) * (float(_f.lp_shift) * 0.5)

func _process(_d: float) -> void:
	if _snapping:
		return
	match _phase:
		"warm":
			_wait += 1
			if _wait > 90:
				_phase = "side"
				_wait = 0
		"side":
			var c := _centre()
			_cam.global_position = c + (_f.lp_r as Vector3) * 52.0 + Vector3.UP * 4.0 - (_f.lp_f as Vector3) * 10.0
			_cam.look_at(c)
			_wait += 1
			if _wait > 30:
				_snap("side")
				_phase = "mouth"
				_wait = 0
		"mouth":
			var e: Vector3 = _f.lp_e
			var fv: Vector3 = _f.lp_f
			_cam.global_position = e - fv * 34.0 + Vector3.UP * 4.5 - (_f.lp_r as Vector3) * 7.0
			_cam.look_at(e + Vector3.UP * float(_f.lp_R) * 0.9)
			_wait += 1
			if _wait > 30:
				_snap("mouth")
				_phase = "drive"
				_spawn_car()
		"drive":
			if _car == null:
				return
			var th: float = _car.get("_loop_th")
			var riding: bool = not (_car.get("_loop") as Dictionary).is_empty()
			if riding and not _shot_wall and th > 1.25 and th < 1.75:
				_shot_wall = true
				var c := _centre()
				_cam.global_position = c + (_f.lp_r as Vector3) * 42.0 - (_f.lp_f as Vector3) * 30.0
				_cam.look_at(_car.global_position)
				_snap("wall")
			elif riding and not _shot_apex and th > 2.95 and th < 3.25:
				_shot_apex = true
				_snap("apex")
			elif riding and _shot_apex and not _shot_fix and th > 3.35 and th < 3.95:
				_shot_fix = true
				# the CANDIDATE HCMain camera rule for loop zones (reported as a
				# snippet): a ring-side vantage at hub height while loop_state is
				# active — the trailing chase hides the car behind the deck up top
				var lst: Dictionary = _trk.call("loop_state", _car.global_position)
				if bool(lst.get("active", false)):
					var e3: Vector3 = lst.e
					_cam.global_position = e3 + Vector3.UP * float(lst.R) + (lst.right as Vector3) * (float(lst.shift) * 0.5 + 26.0)
					_cam.look_at(_car.global_position + Vector3.UP * 1.0)
				_snap("apex_fix")
			elif _shot_fix and (not riding or bool(_car.get("dead"))):
				_phase = "done"
				_finish()
			if not _shot_apex:
				_chase_cam_update(_d)

## The core of HCMain._update_camera (heading from horizontal velocity, chase
## offset, occlusion ray, terrain floor, roll-free look_at) so the apex shot shows
## what the real game camera would show through the inversion.
func _chase_cam_update(delta: float) -> void:
	if _shot_wall and not _shot_apex:
		var target: Vector3 = _car.global_position
		var vel: Vector3 = _car.linear_velocity
		var vh := Vector3(vel.x, 0, vel.z)
		if vh.length() > 2.0:
			_cam_heading = _cam_heading.lerp(vh.normalized(), 1.0 - exp(-3.0 * delta))
		var want := target - _cam_heading * 12.0 + Vector3(0, 6.0, 0)
		var ss := _car.get_world_3d().direct_space_state
		var from := target + Vector3(0, 2.0, 0)
		var q := PhysicsRayQueryParameters3D.create(from, want, 1, [_car.get_rid()])
		var hit := ss.intersect_ray(q)
		if not hit.is_empty():
			want = from.lerp(hit.position, 0.82)
		var floor_y: float = float(_trk.call("height_at", want.x, want.z)) + 3.0
		if want.y < floor_y:
			want.y = floor_y
		_cam.global_position = _cam.global_position.lerp(want, 1.0 - exp(-16.0 * delta))
		var look := target + Vector3(0, 1.0, 0)
		var dir := look - _cam.global_position
		if dir.length() > 0.05:
			var up_ref := Vector3.UP
			if absf(dir.normalized().dot(Vector3.UP)) > 0.985:
				up_ref = _cam_heading if _cam_heading.length() > 0.1 else Vector3.FORWARD
			_cam.look_at(look, up_ref)

func _physics_process(_d: float) -> void:
	if _car == null or _phase != "drive":
		return
	var riding: bool = not (_car.get("_loop") as Dictionary).is_empty()
	if riding:
		for a in ["turn_left", "turn_right", "brake"]:
			Input.action_release(a)
		Input.action_press("accelerate")
		return
	var pos: Vector3 = _car.global_position
	var aim: Vector3 = _trk.call("path_ahead", pos, 25.0)
	var fwd: Vector3 = -_car.global_transform.basis.z
	fwd.y = 0.0
	var right: Vector3 = _car.global_transform.basis.x
	right.y = 0.0
	var to_aim: Vector3 = aim - pos
	to_aim.y = 0.0
	var err := 0.0
	if to_aim.length() > 0.01 and fwd.length() > 0.001:
		err = atan2(to_aim.normalized().dot(right.normalized()), to_aim.normalized().dot(fwd.normalized()))
	if err > 0.02:
		Input.action_press("turn_right", clampf(absf(err) * 2.5, 0.0, 1.0))
		Input.action_release("turn_left")
	elif err < -0.02:
		Input.action_press("turn_left", clampf(absf(err) * 2.5, 0.0, 1.0))
		Input.action_release("turn_right")
	else:
		Input.action_release("turn_left")
		Input.action_release("turn_right")
	Input.action_press("accelerate")

func _spawn_car() -> void:
	_car = RigidBody3D.new()
	_car.set_script(HCCarScript)
	_car.set("terrain", _trk)
	_car.set("road_half", _trk.get("road_half"))
	_car.set("max_speed", 40.0)
	_car.set("engine_force", 20000.0)
	_car.set("vehicle_type", "sports")
	add_child(_car)
	var ent: float = _f.lp_ent
	var p0: Vector3 = _trk.call("point_at_s", ent - 260.0)
	var p1: Vector3 = _trk.call("point_at_s", ent - 256.0)
	var fv := Vector3(p1.x - p0.x, 0.0, p1.z - p0.z).normalized()
	_car.global_transform = Transform3D(Basis(Vector3.UP, atan2(-fv.x, -fv.z)), p0 + Vector3.UP * 3.0)
	_trk.call("set_target", _car)
	_cam_heading = fv

func _snap(name: String) -> void:
	_snapping = true
	_do_snap(name)

func _do_snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://loopshot_%s.png" % name)
	print("[shot] saved loopshot_%s.png" % name)
	_snapping = false

func _finish() -> void:
	for a in ["accelerate", "brake", "turn_left", "turn_right"]:
		Input.action_release(a)
	await get_tree().create_timer(0.5).timeout
	get_tree().quit()
