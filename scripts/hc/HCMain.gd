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
const UP_KEYS := ["engine", "fuel", "fueleff", "suspension", "wheels", "wings", "ailerons", "dive", "rockets", "stretch", "wide"]
const UP_NAME := {"engine": "Engine", "fuel": "Fuel Tank", "fueleff": "Fuel Economy", "suspension": "Suspension", "wheels": "Bigger Wheels", "wings": "Wings", "ailerons": "Ailerons", "dive": "Dive Power", "rockets": "Rockets", "stretch": "Stretch (Limo)", "wide": "Wide Stance"}
const UP_DESC := {
	"engine": "More power & higher top speed",
	"fuel": "Bigger tank — more total fuel",
	"fueleff": "Burns fuel slower (better mileage)",
	"suspension": "Roll cage, armor (+HP), softer landings",
	"wheels": "Taller wheels, more ground clearance",
	"wings": "Lift = more air time off jumps",
	"ailerons": "Air control + auto-centering (needs Wings)",
	"dive": "Hold Space to dive + an air-brake flap",
	"rockets": "Hold Ctrl: a little air boost (chugs fuel)",
	"stretch": "Limo: longer wheelbase, lazier turns",
	"wide": "Wider stance, harder to roll over",
}
const UP_BASECOST := {"engine": 320, "fuel": 260, "fueleff": 240, "suspension": 340, "wheels": 280, "wings": 380, "ailerons": 340, "dive": 300, "rockets": 420, "stretch": 360, "wide": 320}
const UP_COSTMULT := 1.9   # each level costs 1.9x the last — costs ramp hard
const UP_MAX := 6
const MONEY_PER_M := 1.0    # money earned = metres travelled down the track
var money: int = 0
var _last_earned: int = 0
var _levels := {"engine": 0, "fuel": 0, "fueleff": 0, "suspension": 0, "wheels": 0, "wings": 0, "ailerons": 0, "dive": 0, "rockets": 0, "stretch": 0, "wide": 0}
var _was_dead := false
var _respawning := false
var _shake := 0.0           # camera shake magnitude (decays)
var _shake_off := Vector3.ZERO
var _fov_punch := 0.0       # transient FOV kick on hard landings
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
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ENTER:
			_restart()
		elif event.keycode == KEY_TAB:
			_toggle_shop()

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
	_car.connect("gap_failed", _on_car_gap_failed)
	_car.connect("landed", _on_car_landed)

func _setup_camera() -> void:
	_cam = Camera3D.new()
	_cam.fov = 70.0
	_cam.far = 2000.0
	_cam.current = true
	# we drive the camera by hand every frame in _process; with the project's
	# physics_interpolation on, Godot spams "Interpolated Camera3D triggered from
	# outside physics process". Opt this node out of interpolation to silence it.
	_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_cam)
	_cam.global_position = _start + Vector3(0, 6, 12)
	_cam.look_at(_start, Vector3.UP)

func _process(delta: float) -> void:
	if _car == null:
		return
	_update_camera(delta)
	_update_hud()
	# on death, bank money earned from how far down the track you got, open the shop
	var d: bool = _car.get("dead")
	if d and not _was_dead:
		_was_dead = true
		_last_earned = int(float(_car.get("distance")) * MONEY_PER_M)
		money += _last_earned
		_show_shop()

func _update_camera(delta: float) -> void:
	# remove last frame's shake offset so it doesn't accumulate into the smoothing
	_cam.global_position -= _shake_off
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
	var dir := look - _cam.global_position
	# looking_at() errors if the look direction is parallel to the up vector
	# (camera ends up directly above/below the car). Skip the degenerate frame,
	# and fall back to a horizontal up reference when we're near-vertical.
	if dir.length() > 0.05:
		var up_ref := Vector3.UP
		if absf(dir.normalized().dot(Vector3.UP)) > 0.985:
			up_ref = _cam_heading if _cam_heading.length() > 0.1 else Vector3.FORWARD
		var t := _cam.global_transform.looking_at(look, up_ref)
		_cam.global_transform.basis = _cam.global_transform.basis.slerp(t.basis, 1.0 - exp(-8.0 * delta))
	# FOV widens with speed (and harder while boosting) for a sense of pace
	var spd: float = _car.linear_velocity.length()
	var boosting: bool = bool(_car.get("boosting"))
	var target_fov: float = lerpf(70.0, 92.0, clamp(spd / 42.0, 0.0, 1.0))
	target_fov += (9.0 if boosting else 0.0) + _fov_punch
	_cam.fov = lerpf(_cam.fov, target_fov, 1.0 - exp(-4.0 * delta))
	_fov_punch *= exp(-7.0 * delta)
	# rockets rumble the camera; landings (above) add a one-shot jolt. Apply + decay.
	if boosting:
		_shake = maxf(_shake, 0.11)
	_shake_off = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * _shake
	_cam.global_position += _shake_off
	_shake *= exp(-7.0 * delta)

func _restart() -> void:
	_apply_upgrades()
	_car.call("reset_run", _start)
	_cam.global_position = _start + Vector3(0, 6, 12)
	_cam_heading = Vector3(0, 0, -1)
	_shake = 0.0
	_shake_off = Vector3.ZERO
	_fov_punch = 0.0
	_was_dead = false
	if _shop:
		_shop.visible = false

# --- camera juice ------------------------------------------------------------

## A landing kicks the camera: shake + a quick FOV punch, both scaled by impact.
func _on_car_landed(impact: float, _air_time: float) -> void:
	_shake = maxf(_shake, clampf(impact * 0.018, 0.0, 0.6))
	_fov_punch = maxf(_fov_punch, clampf(impact * 0.5, 0.0, 12.0))

## Falling into a pit is a wreck like any other — the car sets dead and _process
## shows the end screen. Just add a jolt here for feel.
func _on_car_gap_failed(_can_respawn: bool) -> void:
	_shake = maxf(_shake, 0.5)

# --- upgrade shop ------------------------------------------------------------

func _cost(key: String) -> int:
	return int(UP_BASECOST[key] * pow(UP_COSTMULT, _levels[key]))

func _apply_upgrades() -> void:
	if _car == null:
		return
	# starter is intentionally weak/slow; upgrades ramp it up hard
	_car.set("engine_force", 8000.0 + _levels.engine * 3600.0)
	_car.set("max_speed", 30.0 + _levels.engine * 15.0)
	if _car.has_method("apply_engine"):
		_car.call("apply_engine", _levels.engine)
	# fuel is the run timer — VERY low stock so you can barely move; two upgrades fix it:
	#   Fuel Tank = capacity, Fuel Economy = slower burn (multiplier dropped here)
	_car.set("max_fuel", 70.0 + _levels.fuel * 95.0)
	_car.set("fuel_eff", maxf(1.0 - _levels.fueleff * 0.12, 0.28))
	# hard landings hurt sooner unless you buy Suspension/Wheels
	_car.set("land_damage_speed", 9.0 + _levels.suspension * 5.0 + _levels.wheels * 2.0)
	# Bigger Wheels: more ride height + larger wheels (clearance over bumps)
	_car.set("suspension_rest", 0.55 + _levels.wheels * 0.18)
	_car.set("wheel_radius", 0.5 + _levels.wheels * 0.12)
	if _car.has_method("apply_wheel_size"):
		_car.call("apply_wheel_size")
	# Wings = lift/air time; Ailerons (gated behind Wings) = control surfaces + guidance + sharper air
	if _car.has_method("apply_wings"):
		_car.call("apply_wings", _levels.wings)
	if _car.has_method("apply_ailerons"):
		_car.call("apply_ailerons", _levels.ailerons)
	_car.set("dive_force", 30.0 + _levels.dive * 16.0)     # heavier dive to time ramps
	# Suspension also = roll cage + more health (frame/armor)
	_car.set("max_health", 100.0 + _levels.suspension * 18.0)
	if _car.has_method("apply_cage"):
		_car.call("apply_cage", _levels.suspension)
	if _car.has_method("apply_cans"):
		_car.call("apply_cans", _levels.fuel)
	if _car.has_method("apply_airbrake"):
		_car.call("apply_airbrake", _levels.dive)
	# Rockets: rear nozzles + boost thrust (hold Ctrl)
	if _car.has_method("apply_rockets"):
		_car.call("apply_rockets", _levels.rockets)
	# Chassis conversions: Stretch (longer) + Wide (wider track)
	if _car.has_method("apply_chassis"):
		_car.call("apply_chassis", _levels.stretch, _levels.wide)

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
	dim.color = Color(0, 0, 0, 0.72)
	_shop.add_child(dim)

	# a fixed-size centered panel; the upgrade list inside scrolls so nothing
	# can ever run off the bottom of the screen no matter how many upgrades.
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(540, 620)
	panel.position = Vector2(-270, -310)
	_shop.add_child(panel)
	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 18)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	pad.add_child(box)

	_shop_header = _shop_label(box, "", 26, Color(1, 0.82, 0.42))
	_shop_money = _shop_label(box, "", 19, Color(0.65, 1.0, 0.7))
	var sep := HSeparator.new()
	box.add_child(sep)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(504, 460)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)

	for key in UP_KEYS:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 10)
		list.add_child(row)
		var info := VBoxContainer.new()
		info.custom_minimum_size = Vector2(360, 0)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_constant_override("separation", 0)
		row.add_child(info)
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 18)
		info.add_child(lbl)
		var desc := Label.new()
		desc.text = UP_DESC.get(key, "")
		desc.add_theme_font_size_override("font_size", 12)
		desc.add_theme_color_override("font_color", Color(0.62, 0.64, 0.7))
		info.add_child(desc)
		var buy := Button.new()
		buy.custom_minimum_size = Vector2(96, 40)
		buy.pressed.connect(_buy.bind(key))
		row.add_child(buy)
		_shop_rows[key] = {"label": lbl, "desc": desc, "buy": buy}

	var restart := Button.new()
	restart.text = "RESTART  (Enter)"
	restart.custom_minimum_size = Vector2(0, 46)
	restart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	restart.pressed.connect(_restart)
	box.add_child(restart)

func _shop_label(parent: Node, text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	parent.add_child(l)
	return l

var _shop_summary := ""

func _show_shop() -> void:
	_shop_header.text = "WRECKED!"
	_shop_summary = "You reached %d m  —  earned +$%d this run" % [int(_car.get("distance")), _last_earned]
	_shop.visible = true
	_refresh_shop()

func _toggle_shop() -> void:
	if _shop == null:
		return
	_shop.visible = not _shop.visible
	if _shop.visible:
		_shop_header.text = "GARAGE   (Tab to close)"
		_shop_summary = ""
		_refresh_shop()

func _refresh_shop() -> void:
	var bank := "TOTAL MONEY:  $%d   (kept between tries)" % money
	_shop_money.text = (_shop_summary + "\n" + bank) if _shop_summary != "" else bank
	for key in UP_KEYS:
		var lvl: int = _levels[key]
		var row: Dictionary = _shop_rows[key]
		var locked: bool = key == "ailerons" and _levels.wings == 0
		var pips := "●".repeat(lvl) + "○".repeat(UP_MAX - lvl)
		row.label.text = "%s   %s" % [UP_NAME[key], pips]
		row.label.add_theme_color_override("font_color", Color(0.55, 0.58, 0.62) if locked else Color(1, 1, 1))
		row.desc.text = UP_DESC.get(key, "")
		var buy: Button = row.buy
		if locked:
			buy.text = "🔒 Wings"
			buy.disabled = true
		elif lvl >= UP_MAX:
			buy.text = "MAX"
			buy.disabled = true
		else:
			var c: int = _cost(key)
			buy.text = "$%d" % c
			buy.disabled = money < c

func _buy(key: String) -> void:
	if _levels[key] >= UP_MAX:
		return
	if key == "ailerons" and _levels.wings == 0:
		return   # gated behind Wings
	var c: int = _cost(key)
	if money < c:
		return
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
	hint.text = "Shift drive  •  S brake  •  A/D steer  •  Ctrl BOOST  •  air: W/S pitch, A/D rotate, Q/E roll  •  Space dive  •  R recover  •  Tab upgrades  •  Enter restart"
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
	_update_gap_telegraph()

## Warn the player to build speed on a gap run-up (green = you'll make it).
func _update_gap_telegraph() -> void:
	if _respawning or bool(_car.get("dead")):
		return   # _big is owned by the wipeout / death screen
	var gz: float = _car.global_position.z
	var g: Dictionary = _terrain.call("_gap_for_z", gz)
	if g.is_empty() or gz <= g.lip_z or (gz - g.lip_z) > 75.0:
		_big.text = ""   # not approaching a gap
		return
	var v_req: float = 6.0 + float(g.void_w) * 0.9        # m/s needed to clear it
	var spd: float = _car.linear_velocity.length()
	if spd >= v_req:
		_big.text = "SEND IT!  ▶▶"
		_big.add_theme_color_override("font_color", Color(0.5, 1.0, 0.55))
	else:
		_big.text = "⚠ GO FASTER   %d / %d km/h" % [int(spd * 3.6), int(v_req * 3.6)]
		_big.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
