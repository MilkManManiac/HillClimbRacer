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
var _score_lbl: Label
var _trick_lbl: Label

# --- economy / upgrades ------------------------------------------------------
const UP_KEYS := ["engine", "fuel", "suspension", "wheels", "grip", "air"]
const UP_NAME := {"engine": "Engine", "fuel": "Fuel Tank", "suspension": "Suspension", "wheels": "Bigger Wheels", "grip": "Grip", "air": "Air Control"}
const UP_BASECOST := {"engine": 160, "fuel": 130, "suspension": 150, "wheels": 170, "grip": 120, "air": 140}
const UP_MAX := 6
var money: int = 0
var _levels := {"engine": 0, "fuel": 0, "suspension": 0, "wheels": 0, "grip": 0, "air": 0}
var _was_dead := false
var _shop: Control
var _shop_header: Label
var _shop_money: Label
var _shop_rows := {}

func _ready() -> void:
	_setup_sky()
	_setup_terrain_and_car()
	_setup_camera()
	_setup_hud()
	_build_shop()
	_apply_upgrades()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ENTER:
		_restart()

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
	_car.set("road_half", _terrain.get("road_half_width"))
	_car.set("terrain", _terrain)
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
	# on death, bank the run's score into money and open the shop
	var d: bool = _car.get("dead")
	if d and not _was_dead:
		_was_dead = true
		money += int(_car.get("score"))
		_show_shop()

func _update_camera(delta: float) -> void:
	# heading from horizontal velocity (stable during flips); fall back to last heading
	var vel: Vector3 = _car.linear_velocity
	var vh := Vector3(vel.x, 0, vel.z)
	if vh.length() > 2.0:
		_cam_heading = _cam_heading.lerp(vh.normalized(), 1.0 - exp(-3.0 * delta))
	var target := _car.global_position
	var want := target - _cam_heading * 12.0 + Vector3(0, 6.0, 0)
	# don't let terrain block the view of the car: raycast from the car toward the camera
	# and pull the camera in front of any hill in the way
	var ss := _car.get_world_3d().direct_space_state
	var from := target + Vector3(0, 2.0, 0)
	var q := PhysicsRayQueryParameters3D.create(from, want, 1, [_car.get_rid()])
	var hit := ss.intersect_ray(q)
	var blocked := not hit.is_empty()
	if blocked:
		want = from.lerp(hit.position, 0.82)
	# never let the camera dip below the terrain surface
	var floor_y: float = _terrain.call("height_at", want.x, want.z) + 3.0
	if want.y < floor_y:
		want.y = floor_y
	# snap in faster when blocked so the car never disappears
	var snap: float = 16.0 if blocked else 6.0
	_cam.global_position = _cam.global_position.lerp(want, 1.0 - exp(-snap * delta))
	var look := target + Vector3(0, 1.0, 0)
	var t := _cam.global_transform.looking_at(look, Vector3.UP)
	_cam.global_transform.basis = _cam.global_transform.basis.slerp(t.basis, 1.0 - exp(-8.0 * delta))
	# FOV widens with speed for a sense of pace
	var spd: float = _car.linear_velocity.length()
	var target_fov: float = lerpf(70.0, 92.0, clamp(spd / 42.0, 0.0, 1.0))
	_cam.fov = lerpf(_cam.fov, target_fov, 1.0 - exp(-4.0 * delta))

func _restart() -> void:
	_apply_upgrades()
	_car.call("reset_run", _start)
	_cam.global_position = _start + Vector3(0, 6, 12)
	_cam_heading = Vector3(0, 0, -1)
	_was_dead = false
	if _shop:
		_shop.visible = false

# --- upgrade shop ------------------------------------------------------------

func _cost(key: String) -> int:
	return int(UP_BASECOST[key] * pow(1.7, _levels[key]))

func _apply_upgrades() -> void:
	if _car == null:
		return
	_car.set("engine_force", 19000.0 + _levels.engine * 3500.0)
	_car.set("max_speed", 125.0 + _levels.engine * 7.0)
	_car.set("max_fuel", 600.0 + _levels.fuel * 240.0)
	_car.set("land_damage_speed", 12.0 + _levels.suspension * 5.0 + _levels.wheels * 2.0)
	_car.set("grip", 8.5 + _levels.grip * 0.9)
	# Bigger Wheels: more ride height + larger wheels (clearance over bumps)
	_car.set("suspension_rest", 0.55 + _levels.wheels * 0.18)
	_car.set("wheel_radius", 0.5 + _levels.wheels * 0.12)
	if _car.has_method("apply_wheel_size"):
		_car.call("apply_wheel_size")
	_car.set("air_pitch_torque", 11.0 + _levels.air * 2.0)
	_car.set("air_roll_torque", 9.0 + _levels.air * 1.6)
	_car.set("air_yaw_torque", 6.0 + _levels.air * 1.2)

func _build_shop() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_shop = Control.new()
	_shop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shop.visible = false
	layer.add_child(_shop)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.6)
	_shop.add_child(dim)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.position = Vector2(-220, -200)
	box.custom_minimum_size = Vector2(440, 0)
	box.add_theme_constant_override("separation", 10)
	_shop.add_child(box)
	_shop_header = _shop_label(box, "", 26, Color(1, 0.8, 0.4))
	_shop_money = _shop_label(box, "", 24, Color(1, 0.95, 0.5))
	for key in UP_KEYS:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(440, 0)
		row.add_theme_constant_override("separation", 12)
		box.add_child(row)
		var lbl := Label.new()
		lbl.custom_minimum_size = Vector2(260, 0)
		lbl.add_theme_font_size_override("font_size", 19)
		row.add_child(lbl)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(150, 0)
		btn.pressed.connect(_buy.bind(key))
		row.add_child(btn)
		_shop_rows[key] = {"label": lbl, "btn": btn}
	var restart := Button.new()
	restart.text = "RESTART  (Enter)"
	restart.custom_minimum_size = Vector2(440, 44)
	restart.pressed.connect(_restart)
	box.add_child(restart)

func _shop_label(parent: Node, text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	parent.add_child(l)
	return l

func _show_shop() -> void:
	_shop_header.text = "WRECKED  —  %d m   (banked +%d)" % [int(_car.get("distance")), int(_car.get("score"))]
	_shop.visible = true
	_refresh_shop()

func _refresh_shop() -> void:
	_shop_money.text = "MONEY: $%d" % money
	for key in UP_KEYS:
		var lvl: int = _levels[key]
		var row: Dictionary = _shop_rows[key]
		row.label.text = "%s   Lv %d/%d" % [UP_NAME[key], lvl, UP_MAX]
		if lvl >= UP_MAX:
			row.btn.text = "MAX"
			row.btn.disabled = true
		else:
			var c: int = _cost(key)
			row.btn.text = "Buy  $%d" % c
			row.btn.disabled = money < c

func _buy(key: String) -> void:
	if _levels[key] >= UP_MAX:
		return
	var c: int = _cost(key)
	if money >= c:
		money -= c
		_levels[key] += 1
		_apply_upgrades()
		_refresh_shop()

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
	_score_lbl = Label.new()
	_score_lbl.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_score_lbl.position = Vector2(-200, 28)
	_score_lbl.add_theme_font_size_override("font_size", 24)
	_score_lbl.add_theme_color_override("font_color", Color(1, 0.95, 0.5))
	layer.add_child(_score_lbl)
	_trick_lbl = Label.new()
	_trick_lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_trick_lbl.position = Vector2(-240, 120)
	_trick_lbl.custom_minimum_size = Vector2(480, 0)
	_trick_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_trick_lbl.add_theme_font_size_override("font_size", 32)
	_trick_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
	layer.add_child(_trick_lbl)
	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(28, -34)
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.8, 0.8, 0.85))
	hint.text = "Shift = drive  •  S brake  •  A/D steer  •  air: W/S pitch, A/D roll, Q/E yaw  •  Space dive  •  R recover  •  Enter restart"
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
	_score_lbl.text = "SCORE %d" % int(_car.get("score"))
	_trick_lbl.text = _car.get("trick_text")
	_big.text = ""   # the shop panel now handles the death screen
