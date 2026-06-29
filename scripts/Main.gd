extends Node3D
## Bootstraps the free-drive playground: foggy night environment, a drivable road
## network, the player-driven physics car (first-person), VHS post-process, and a
## minimal documentarian HUD. The player actually drives now (throttle/brake/steer).

const VHS_SHADER := preload("res://shaders/vhs_postprocess.gdshader")
const ArcadeCarScript := preload("res://scripts/ArcadeCar.gd")
const CockpitScript := preload("res://scripts/Cockpit.gd")
const RoadNetworkScript := preload("res://scripts/RoadNetwork.gd")
const SkyScript := preload("res://scripts/Sky.gd")
const ForestScript := preload("res://scripts/Forest.gd")
const TerrainScript := preload("res://scripts/Terrain.gd")

const GRID_XS: Array[float] = [-130.0, 0.0, 130.0]
const GRID_ZS: Array[float] = [40.0, -90.0, -220.0, -350.0]

var _car: RigidBody3D
var _prompt: Label
var _subtitle: Label
var _narrator: Label
var _rec: Label
var _speedo: Label
var _vhs_mat: ShaderMaterial
var _dread: float = 0.0
var _t: float = 0.0
var _narr_until: float = 0.0
var _sub_until: float = 0.0

func _ready() -> void:
	_setup_sky()
	_setup_terrain()
	_setup_roads()
	_setup_forest()
	_setup_car()
	_setup_postprocess()
	_setup_hud()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	show_narrator("The car's yours to drive out here. Keep it on the road.\n\nW / S — throttle & brake (S reverses when stopped)\nA / D — steer    •    Mouse — look around the cabin\n\nAt every fork, the only thing that matters is which way you turn.", 14.0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _car:
		_car.handle_look(event.relative)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _process(delta: float) -> void:
	_t += delta
	_dread = lerp(_dread, 0.0, delta * 0.4)
	if _vhs_mat:
		_vhs_mat.set_shader_parameter("time_seed", _t * 60.0)
		_vhs_mat.set_shader_parameter("dread", _dread)
	if _narrator and _t > _narr_until:
		_narrator.text = ""
	if _subtitle and _t > _sub_until:
		_subtitle.text = ""
	if _speedo and _car:
		_speedo.text = "G%d   %3d km/h" % [_car.get_gear(), int(_car.get_speed_kmh())]

# --- public API used by encounters ------------------------------------------

func nudge_dread(amount: float) -> void:
	_dread = clamp(_dread + amount, 0.0, 1.0)

func set_dread(value: float) -> void:
	_dread = clamp(value, 0.0, 1.0)

func show_narrator(text: String, secs: float = 6.0) -> void:
	_narrator.text = text
	_narr_until = _t + secs

func show_subtitle(text: String, secs: float = 4.0) -> void:
	_subtitle.text = text
	_sub_until = _t + secs

func get_camera() -> Camera3D: return _car.get_camera() if _car else null
func get_car() -> Node3D: return _car

# --- environment -------------------------------------------------------------

func _setup_sky() -> void:
	var sky := Node3D.new()
	sky.name = "Sky"
	sky.set_script(SkyScript)
	add_child(sky)

func _setup_terrain() -> void:
	var terrain := Node3D.new()
	terrain.name = "Terrain"
	terrain.set_script(TerrainScript)
	add_child(terrain)

func _setup_forest() -> void:
	var forest := Node3D.new()
	forest.name = "Forest"
	forest.set_script(ForestScript)
	forest.set("xs", GRID_XS)
	forest.set("zs", GRID_ZS)
	add_child(forest)

# --- roads -------------------------------------------------------------------

func _setup_roads() -> void:
	var roads := Node3D.new()
	roads.name = "RoadNetwork"
	roads.set_script(RoadNetworkScript)
	add_child(roads)

# --- car ---------------------------------------------------------------------

func _setup_car() -> void:
	_car = RigidBody3D.new()
	_car.name = "Car"
	_car.set_script(ArcadeCarScript)
	add_child(_car)
	# start on the southern road, facing north (-Z), dropped just above the ground
	_car.global_position = Vector3(0, 1.2, 30)
	# interactive cockpit systems hang off the car
	var cockpit := Node.new()
	cockpit.name = "Cockpit"
	cockpit.set_script(CockpitScript)
	_car.add_child(cockpit)
	cockpit.call("setup", _car, self)

# --- post-process ------------------------------------------------------------

func _setup_postprocess() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vhs_mat = ShaderMaterial.new()
	_vhs_mat.shader = VHS_SHADER
	# keep a light filmic touch, but don't darken the bright daytime scene
	_vhs_mat.set_shader_parameter("vignette_amount", 0.5)
	_vhs_mat.set_shader_parameter("scanline_amount", 0.04)
	_vhs_mat.set_shader_parameter("grain_amount", 0.03)
	_vhs_mat.set_shader_parameter("aberration", 0.0008)
	rect.material = _vhs_mat
	layer.add_child(rect)
	add_child(layer)

# --- HUD ---------------------------------------------------------------------

func _setup_hud() -> void:
	var ui := CanvasLayer.new()
	ui.layer = 5

	_rec = Label.new()
	_rec.text = "● REC"
	_rec.position = Vector2(28, 24)
	_rec.add_theme_color_override("font_color", Color(0.9, 0.2, 0.2))
	ui.add_child(_rec)

	_narrator = Label.new()
	_narrator.position = Vector2(28, 60)
	_narrator.add_theme_color_override("font_color", Color(0.7, 0.7, 0.72))
	_narrator.add_theme_font_size_override("font_size", 15)
	ui.add_child(_narrator)

	_subtitle = Label.new()
	_subtitle.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_subtitle.position = Vector2(-260, -130)
	_subtitle.custom_minimum_size = Vector2(520, 0)
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle.add_theme_font_size_override("font_size", 18)
	_subtitle.add_theme_color_override("font_color", Color(0.88, 0.86, 0.82))
	ui.add_child(_subtitle)

	_prompt = Label.new()
	_prompt.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt.position = Vector2(-160, -85)
	_prompt.add_theme_font_size_override("font_size", 28)
	_prompt.add_theme_color_override("font_color", Color(1, 1, 0.6))
	ui.add_child(_prompt)

	# speedometer, bottom-right (diegetic-ish documentarian overlay)
	_speedo = Label.new()
	_speedo.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_speedo.position = Vector2(-120, -40)
	_speedo.add_theme_font_size_override("font_size", 18)
	_speedo.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	ui.add_child(_speedo)

	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.position = Vector2(28, -34)
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.62))
	hint.text = "W/S = throttle / brake  •  A/D = steer  •  mouse = look  •  Esc = free cursor"
	ui.add_child(hint)
	add_child(ui)
