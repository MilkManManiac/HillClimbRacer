extends Node3D
## THROWAWAY-style visual harness: renders the Gravity Works stunts (overpass +
## corkscrew) from readable angles and saves PNGs. Run WITHOUT --headless:
##   <godot_console> --path . tests/StuntShot.tscn
## Streams tiles by parking a dummy target at each vantage before shooting.

const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")
const GRAVITY := {
	"stunts": "overpass:650,corkscrew:1500:2,overpass:2900,corkscrew:3900:1",
	"straight_bias": 0.6, "turn_radius_min": 40.0, "turn_radius_max": 80.0,
	"road_half": 18.0, "road_half_turn": 26.0,
	"hill_amp": 5.0, "noise_frequency": 0.0024,
	"gap_start": 5600.0, "gap_spacing": 420.0,
	"path_seed": 777333, "noise_seed": 424,
	"grass_color": Color(0.30, 0.42, 0.24), "asphalt_color": Color(0.15, 0.15, 0.17),
	"rail_band_color": Color(0.95, 0.45, 0.1),
}

var _trk: Node3D
var _tgt: Node3D
var _cam: Camera3D
var _shots: Array = []
var _idx := 0
var _wait := 0

func _ready() -> void:
	_trk = Node3D.new()
	_trk.set_script(HCTrackScript)
	for k in GRAVITY:
		_trk.set(k, GRAVITY[k])
	add_child(_trk)
	_tgt = Node3D.new()
	add_child(_tgt)
	_trk.call("set_target", _tgt)
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

	# vantage list from the actual placed features
	var rep: Dictionary = _trk.call("stunt_report")
	var f0: Dictionary = rep.features[0]   # overpass 1
	var f1: Dictionary = rep.features[1]   # corkscrew 1 (2 coils)
	var cross_mid: float = (float(f0.u1) + float(f0.d0)) * 0.5
	var coil_mid: float = (float(f1.d0) + float(f1.d1)) * 0.5
	var coil_hi: float = float(f1.d0) + (float(f1.d1) - float(f1.d0)) * 0.2
	_shots = [
		# [name, focus_s, cam offset from focus, look_at offset]
		["overpass_under", float(f0.s0) + 40.0, Vector3.ZERO, Vector3.ZERO],   # from the approach, bridge ahead
		["overpass_side", cross_mid, Vector3(70, 26, 0), Vector3.ZERO],
		["corkscrew_wide", coil_mid, Vector3(150, 55, 90), Vector3(0, -6, 0)],
		["corkscrew_deck", coil_hi, Vector3.ZERO, Vector3.ZERO],
	]

func _process(_d: float) -> void:
	if _idx >= _shots.size():
		get_tree().quit()
		return
	var sh: Array = _shots[_idx]
	var focus: Vector3 = _trk.call("point_at_s", sh[1])
	_tgt.global_position = focus
	if _wait == 0:
		# aim the camera for this vantage
		if sh[0] == "overpass_under":
			# low chase view up the approach, the deck crossing overhead ahead
			var ahead: Vector3 = _trk.call("point_at_s", sh[1] + 90.0)
			ahead.y = float(_trk.call("height_at_y", ahead.x, ahead.z, focus.y + 1.0)) + 4.0
			_cam.global_position = focus + Vector3(0, 5, 0) + (focus - ahead).normalized() * 14.0
			_cam.look_at(ahead + Vector3(0, 4, 0))
		elif sh[0] == "corkscrew_deck":
			var fwd: Vector3 = (_trk.call("point_at_s", sh[1] + 20.0) as Vector3) - focus
			_cam.global_position = focus - fwd.normalized() * 16.0 + Vector3(0, 7, 0)
			_cam.look_at(focus + fwd.normalized() * 30.0)
		else:
			_cam.global_position = focus + (sh[2] as Vector3)
			_cam.look_at(focus + (sh[3] as Vector3))
	_wait += 1
	if _wait >= 70:   # ~1.2 s: tiles (incl. partners) fully streamed
		_snap(sh[0])
		_idx += 1
		_wait = 0

func _snap(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("res://stuntshot_%s.png" % name)
	print("[shot] saved stuntshot_%s.png" % name)
