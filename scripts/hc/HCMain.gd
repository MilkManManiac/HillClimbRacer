extends Node3D
## Hill-Climb feel sandbox: sky + streaming terrain + arcade car + world-upright chase
## cam locked behind + HUD (fuel/health/distance/speed). Run ends on fuel-out or wreck;
## Enter restarts. Milestone 1 — prove the moment-to-moment is fun. No economy yet.

const SkyScript := preload("res://scripts/Sky.gd")
const HCTerrainScript := preload("res://scripts/hc/HCTerrain.gd")
const HCCarScript := preload("res://scripts/hc/HCCar.gd")

var _car: RigidBody3D
var _terrain: Node3D
var _cam: Camera3D
var _cam_heading := Vector3(0, 0, -1)
var _start := Vector3(0, 6, 0)

# HUD
var _fuel_bar: ColorRect
var _health_bar: ColorRect
var _info: Label
var _big: Label

func _ready() -> void:
	_setup_sky()
	_setup_terrain_and_car()
	_setup_camera()
	_setup_hud()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _setup_sky() -> void:
	var sky := Node3D.new()
	sky.set_script(SkyScript)
	sky.set("time_of_day", 0.42)
	add_child(sky)

func _setup_terrain_and_car() -> void:
	_terrain = Node3D.new()
	_terrain.set_script(HCTerrainScript)
	add_child(_terrain)
	_car = RigidBody3D.new()
	_car.set_script(HCCarScript)
	add_child(_car)
	# place start above the terrain so it drops onto it
	_start.y = _terrain.call("height_at", 0.0, 0.0) + 4.0
	_car.global_position = _start
	_terrain.call("set_target", _car)

func _setup_camera() -> void:
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.far = 2000.0
	_cam.current = true
	add_child(_cam)
	_cam.global_position = _start + Vector3(0, 6, 12)
	_cam.look_at(_start, Vector3.UP)

func _process(delta: float) -> void:
	if _car == null:
		return
	_update_camera(delta)
	_update_hud()
	if _car.get("dead") and Input.is_key_pressed(KEY_ENTER):
		_restart()

func _update_camera(delta: float) -> void:
	# heading from horizontal velocity (stable during flips); fall back to last heading
	var vel: Vector3 = _car.linear_velocity
	var vh := Vector3(vel.x, 0, vel.z)
	if vh.length() > 2.0:
		_cam_heading = _cam_heading.lerp(vh.normalized(), 1.0 - exp(-3.0 * delta))
	var target := _car.global_position
	var want := target - _cam_heading * 11.0 + Vector3(0, 5.0, 0)
	_cam.global_position = _cam.global_position.lerp(want, 1.0 - exp(-6.0 * delta))
	var look := target + Vector3(0, 1.0, 0)
	var t := _cam.global_transform.looking_at(look, Vector3.UP)
	_cam.global_transform.basis = _cam.global_transform.basis.slerp(t.basis, 1.0 - exp(-8.0 * delta))

func _restart() -> void:
	_car.call("reset_run", _start)
	_cam.global_position = _start + Vector3(0, 6, 12)
	_cam_heading = Vector3(0, 0, -1)

# --- HUD ---------------------------------------------------------------------

func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_bar_bg(layer, Vector2(28, 28), Color(0, 0, 0, 0.5))
	_fuel_bar = _bar(layer, Vector2(30, 30), Color(0.95, 0.8, 0.2))
	_bar_bg(layer, Vector2(28, 56), Color(0, 0, 0, 0.5))
	_health_bar = _bar(layer, Vector2(30, 58), Color(0.9, 0.3, 0.3))
	_info = Label.new()
	_info.position = Vector2(28, 84)
	_info.add_theme_font_size_override("font_size", 18)
	layer.add_child(_info)
	_big = Label.new()
	_big.set_anchors_preset(Control.PRESET_CENTER)
	_big.position = Vector2(-220, -40)
	_big.custom_minimum_size = Vector2(440, 0)
	_big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_big.add_theme_font_size_override("font_size", 26)
	_big.add_theme_color_override("font_color", Color(1, 1, 0.7))
	layer.add_child(_big)
	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(28, -34)
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	hint.text = "W/S throttle  •  A/D steer  •  air: W/S pitch, A/D roll, Q/E yaw  •  Shift dive  •  R recover  •  Enter restart"
	layer.add_child(hint)

func _bar_bg(layer: CanvasLayer, pos: Vector2, col: Color) -> void:
	var r := ColorRect.new()
	r.position = pos
	r.size = Vector2(224, 18)
	r.color = col
	layer.add_child(r)

func _bar(layer: CanvasLayer, pos: Vector2, col: Color) -> ColorRect:
	var r := ColorRect.new()
	r.position = pos
	r.size = Vector2(220, 14)
	r.color = col
	layer.add_child(r)
	return r

func _update_hud() -> void:
	var fuel: float = _car.get("fuel")
	var health: float = _car.get("health")
	var dist: float = _car.get("distance")
	var maxfuel: float = _car.get("max_fuel")
	var maxhp: float = _car.get("max_health")
	_fuel_bar.size.x = 220.0 * clamp(fuel / maxf(maxfuel, 1.0), 0.0, 1.0)
	_health_bar.size.x = 220.0 * clamp(health / maxf(maxhp, 1.0), 0.0, 1.0)
	var air: String = "  ✈ AIR" if _car.get("airborne") else ""
	_info.text = "%d m    %d km/h%s" % [int(dist), int(_car.call("get_speed_kmh")), air]
	if _car.get("dead"):
		_big.text = "WRECKED — %d m\nPress Enter to restart" % int(dist)
	else:
		_big.text = ""
