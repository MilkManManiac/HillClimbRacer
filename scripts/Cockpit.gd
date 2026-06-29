extends Node
## Interactive cockpit systems for ArcadeCar. Look at a dashboard control (camera-center
## raycast against Area3D controls on physics layer 2) and click to toggle it:
##   headlights, interior dome light, dash backlight, wipers, radio, rain (weather).
## Plus a radio (procedural static with rare transmissions) and an adjustable rear-view
## mirror (click to grab, mouse to aim, click to release). Wired by Main via setup().

const RAIN_SHADER := preload("res://shaders/rain_windshield.gdshader")
const INTERACT_MASK := 2          # physics layer 2 (value 1<<1)

var _car: RigidBody3D
var _main: Node
var _cam: Camera3D
var _cabin: Node3D
var _space: PhysicsDirectSpaceState3D

# controls: array of {area, mesh, mat, kind, prompt}
var _controls: Array = []
var _hovered: int = -1

# hud
var _reticle: Label
var _prompt_lbl: Label

# toggle state
var _headlights_on := false
var _dome_on := false
var _dash_on := true
var _wipers_on := false
var _radio_on := false
var _rain_on := false

# systems
var _static_player: AudioStreamPlayer
var _voice_player: AudioStreamPlayer
var _wiper_pivots: Array[Node3D] = []
var _rain: GPUParticles3D
var _wind_mat: ShaderMaterial
var _mirror_vp: SubViewport
var _mirror_pivot: Node3D
var _mirror_eye: Node3D
var _mirror_cam: Camera3D
var _mirror_grabbed := false

var _t := 0.0
var _wipe_t := 0.0
var _next_msg := 0.0
var _rng := RandomNumberGenerator.new()

const MESSAGES := [
	"...is anyone still out on this road...?",
	"...turn back at the next fork. please turn back...",
	"...we counted the cars. yours wasn't one of them...",
	"...don't stop for the one on the shoulder...",
	"...keep your eyes forward. not on the mirror...",
	"...you've passed this tree before...",
	"...it's not following. it's waiting...",
]

func setup(car: RigidBody3D, main: Node) -> void:
	_car = car
	_main = main
	_rng.randomize()
	_cam = car.call("get_camera")
	_cabin = car.call("get_cabin")
	if _cam == null or _cabin == null:
		return
	_space = _cam.get_world_3d().direct_space_state
	_build_hud()
	_build_controls()
	_build_radio()
	_build_wipers()
	_build_rain()
	_build_mirror()
	_apply_dash()
	_next_msg = _rng.randf_range(14.0, 30.0)

func _physics_process(_delta: float) -> void:
	if _cam == null:
		return
	if _space == null:
		_space = _cam.get_world_3d().direct_space_state
	var center := get_viewport().get_visible_rect().size * 0.5
	var from := _cam.project_ray_origin(center)
	var dir := _cam.project_ray_normal(center)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 2.6, INTERACT_MASK)
	q.collide_with_areas = true
	q.collide_with_bodies = false
	var hit := _space.intersect_ray(q)
	var idx := -1
	if hit:
		var col = hit.collider
		if col.has_meta("ctrl"):
			idx = col.get_meta("ctrl")
	if idx != _hovered:
		_set_hover(idx)

func _process(delta: float) -> void:
	_t += delta
	# radio messages
	if _radio_on:
		_next_msg -= delta
		if _next_msg <= 0.0 and _voice_player and not _voice_player.playing:
			_play_message()
	# keep the mirror camera locked to the (adjustable) mirror eye on the car
	if _mirror_cam and _mirror_eye:
		_mirror_cam.global_transform = _mirror_eye.global_transform
	# wipers
	if _wipers_on:
		_wipe_t += delta * 3.2
		var s: float = absf(sin(_wipe_t))
		for i in range(_wiper_pivots.size()):
			_wiper_pivots[i].rotation.z = deg_to_rad(-10.0 - s * 95.0 + i * 4.0)
		if _wind_mat:
			_wind_mat.set_shader_parameter("wiper_angle", -0.7 + s * 1.4)
	else:
		for p in _wiper_pivots:
			p.rotation.z = lerp_angle(p.rotation.z, deg_to_rad(-10.0), delta * 6.0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _mirror_grabbed:
			_mirror_grabbed = false
			return
		if _hovered >= 0:
			_activate(_controls[_hovered].kind)

func _input(event: InputEvent) -> void:
	# while grabbing the mirror, mouse motion aims it (and is consumed so the car doesn't look)
	if _mirror_grabbed and event is InputEventMouseMotion and _mirror_pivot:
		_mirror_pivot.rotation.y = clampf(_mirror_pivot.rotation.y - event.relative.x * 0.004, -0.6, 0.6)
		_mirror_pivot.rotation.x = clampf(_mirror_pivot.rotation.x - event.relative.y * 0.004, -0.4, 0.4)
		get_viewport().set_input_as_handled()

# --- hover / activate --------------------------------------------------------

func _set_hover(idx: int) -> void:
	if _hovered >= 0:
		_controls[_hovered].mat.emission_energy_multiplier = 0.4
	_hovered = idx
	if idx >= 0:
		_controls[idx].mat.emission_energy_multiplier = 2.5
		_prompt_lbl.text = _controls[idx].prompt
		_reticle.add_theme_color_override("font_color", Color(1, 1, 0.6))
	else:
		_prompt_lbl.text = ""
		_reticle.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))

func _activate(kind: String) -> void:
	match kind:
		"headlights":
			_headlights_on = not _headlights_on
			for h in _car.headlights:
				create_tween().tween_property(h, "light_energy", 9.0 if _headlights_on else 0.0, 0.1)
			for lens in _car.headlight_lens:
				lens.material_override.emission_energy_multiplier = 3.0 if _headlights_on else 0.0
		"dome":
			_dome_on = not _dome_on
			create_tween().tween_property(_car.dome_light, "light_energy", 0.7 if _dome_on else 0.0, 0.1)
		"dash":
			_dash_on = not _dash_on
			_apply_dash()
		"wipers":
			_wipers_on = not _wipers_on
		"radio":
			_radio_on = not _radio_on
			if _radio_on:
				_static_player.play()
				_next_msg = _rng.randf_range(6.0, 16.0)
			else:
				_static_player.stop()
				if _voice_player: _voice_player.stop()
		"rain":
			_rain_on = not _rain_on
			if _rain: _rain.emitting = _rain_on
			if _wind_mat:
				create_tween().tween_property(_wind_mat, "shader_parameter/rain_amount", 1.0 if _rain_on else 0.0, 1.0)
		"mirror":
			_mirror_grabbed = true
	_update_prompt_after_toggle(kind)

func _update_prompt_after_toggle(kind: String) -> void:
	for c in _controls:
		if c.kind == kind:
			c.prompt = _prompt_for(kind)
	if _hovered >= 0:
		_prompt_lbl.text = _controls[_hovered].prompt

func _prompt_for(kind: String) -> String:
	match kind:
		"headlights": return ("Headlights: OFF" if _headlights_on else "Headlights: ON")
		"dome": return ("Cabin light: OFF" if _dome_on else "Cabin light: ON")
		"dash": return ("Dash: OFF" if _dash_on else "Dash: ON")
		"wipers": return ("Wipers: OFF" if _wipers_on else "Wipers: ON")
		"radio": return ("Radio: OFF" if _radio_on else "Radio: ON")
		"rain": return ("Stop rain" if _rain_on else "Start rain")
		"mirror": return "Adjust mirror (click, move, click)"
	return "Interact"

func _apply_dash() -> void:
	for m in _car.dash_materials:
		m.emission_energy_multiplier = 2.2 if _dash_on else 0.0

# --- build: HUD --------------------------------------------------------------

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 6
	_reticle = Label.new()
	_reticle.text = "+"
	_reticle.set_anchors_preset(Control.PRESET_CENTER)
	_reticle.add_theme_font_size_override("font_size", 22)
	_reticle.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	layer.add_child(_reticle)
	_prompt_lbl = Label.new()
	_prompt_lbl.set_anchors_preset(Control.PRESET_CENTER)
	_prompt_lbl.position = Vector2(-120, 24)
	_prompt_lbl.custom_minimum_size = Vector2(240, 0)
	_prompt_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_lbl.add_theme_font_size_override("font_size", 15)
	_prompt_lbl.add_theme_color_override("font_color", Color(1, 1, 0.7))
	layer.add_child(_prompt_lbl)
	add_child(layer)

# --- build: dashboard controls ----------------------------------------------

func _make_control(kind: String, pos: Vector3, color: Color, label: String) -> void:
	var area := Area3D.new()
	area.collision_layer = INTERACT_MASK
	area.collision_mask = 0
	area.position = pos
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.08, 0.05, 0.08)
	cs.shape = bs
	area.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.07, 0.04, 0.07)
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.4
	mi.material_override = mat
	area.add_child(mi)
	var cap := Label3D.new()
	cap.text = label
	cap.font_size = 28
	cap.pixel_size = 0.0011
	cap.position = Vector3(0, 0.06, 0)
	cap.modulate = Color(0.85, 0.85, 0.9)
	area.add_child(cap)
	area.set_meta("ctrl", _controls.size())
	_cabin.add_child(area)
	_controls.append({"area": area, "mesh": mi, "mat": mat, "kind": kind, "prompt": _prompt_for(kind)})

func _build_controls() -> void:
	# a little button cluster on the center console, angled toward the driver
	var z := -0.86
	var y := 1.16
	_make_control("headlights", Vector3(-0.02, y, z), Color(0.9, 0.85, 0.4), "LAMP")
	_make_control("dome", Vector3(0.10, y, z), Color(0.95, 0.8, 0.5), "DOME")
	_make_control("dash", Vector3(0.22, y, z), Color(0.3, 0.7, 0.95), "DASH")
	_make_control("wipers", Vector3(0.34, y, z), Color(0.5, 0.8, 0.9), "WIPE")
	_make_control("radio", Vector3(0.46, y, z), Color(0.9, 0.5, 0.3), "RADIO")
	_make_control("rain", Vector3(0.58, y, z), Color(0.6, 0.6, 0.95), "RAIN")

# --- build: radio ------------------------------------------------------------

func _build_radio() -> void:
	_static_player = AudioStreamPlayer.new()
	_static_player.stream = _make_static_wav()
	_static_player.volume_db = -14.0
	add_child(_static_player)
	_voice_player = AudioStreamPlayer.new()
	_voice_player.stream = _make_message_wav()
	_voice_player.volume_db = -4.0
	add_child(_voice_player)
	_voice_player.finished.connect(_on_message_done)

func _make_static_wav() -> AudioStreamWAV:
	var rate := 22050
	var n := int(1.5 * rate)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var prev := 0.0
	for i in range(n):
		var w := rng.randf_range(-1.0, 1.0)
		prev = lerpf(prev, w, 0.6)
		bytes.encode_s16(i * 2, int(clampf(prev, -1.0, 1.0) * 9000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = false
	wav.mix_rate = rate
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
	wav.data = bytes
	return wav

func _make_message_wav() -> AudioStreamWAV:
	# a short garbled transmission: low tone + amplitude-bursted noise
	var rate := 22050
	var n := int(2.4 * rate)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in range(n):
		var t := float(i) / float(rate)
		var env: float = clampf(sin(t * 10.0) * 0.5 + 0.5, 0.0, 1.0)
		env *= smoothstep(0.0, 0.1, t) * smoothstep(2.4, 2.0, t)
		var tone: float = sin(TAU * 150.0 * t) * 0.35 + sin(TAU * 90.0 * t) * 0.2
		var noise: float = rng.randf_range(-1.0, 1.0) * 0.5
		var s: float = clampf((tone + noise) * env, -1.0, 1.0)
		bytes.encode_s16(i * 2, int(s * 12000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = false
	wav.mix_rate = rate
	wav.data = bytes
	return wav

func _play_message() -> void:
	create_tween().tween_property(_static_player, "volume_db", -28.0, 0.15)
	_voice_player.play()
	if _main and _main.has_method("show_subtitle"):
		_main.call("show_subtitle", MESSAGES[_rng.randi() % MESSAGES.size()], 5.0)

func _on_message_done() -> void:
	create_tween().tween_property(_static_player, "volume_db", -14.0, 0.5)
	_next_msg = _rng.randf_range(20.0, 50.0)

# --- build: wipers -----------------------------------------------------------

func _build_wipers() -> void:
	for x in [-0.5, 0.25]:
		var pivot := Node3D.new()
		pivot.position = Vector3(x, 1.02, -1.32)
		pivot.rotation.z = deg_to_rad(-10.0)
		var blade := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.04, 0.9, 0.04)
		blade.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.02, 0.02, 0.02)
		blade.material_override = m
		blade.position = Vector3(0, 0.45, 0)
		pivot.add_child(blade)
		_cabin.add_child(pivot)
		_wiper_pivots.append(pivot)

# --- build: rain -------------------------------------------------------------

func _build_rain() -> void:
	# windshield droplets
	var glass := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(1.7, 0.95)
	glass.mesh = qm
	_wind_mat = ShaderMaterial.new()
	_wind_mat.shader = RAIN_SHADER
	_wind_mat.set_shader_parameter("rain_amount", 0.0)
	glass.material_override = _wind_mat
	glass.position = Vector3(0, 1.45, -1.34)
	_cabin.add_child(glass)

	# falling rain in the lit area, follows the car
	_rain = GPUParticles3D.new()
	_rain.amount = 500
	_rain.lifetime = 1.2
	_rain.emitting = false
	_rain.local_coords = false
	_rain.position = Vector3(0, 12, -4)
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, -1, 0)
	pm.gravity = Vector3(0, -40, 0)
	pm.initial_velocity_min = 14.0
	pm.initial_velocity_max = 18.0
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(12, 1, 14)
	_rain.process_material = pm
	var streak := QuadMesh.new()
	streak.size = Vector2(0.02, 0.5)
	var sm := StandardMaterial3D.new()
	sm.albedo_color = Color(0.6, 0.65, 0.75, 0.5)
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	streak.material = sm
	_rain.draw_pass_1 = streak
	_cabin.add_child(_rain)

# --- build: rear-view mirror -------------------------------------------------

func _build_mirror() -> void:
	_mirror_vp = SubViewport.new()
	_mirror_vp.size = Vector2i(320, 120)
	_mirror_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_mirror_vp.transparent_bg = false
	add_child(_mirror_vp)

	_mirror_pivot = Node3D.new()
	_mirror_pivot.position = Vector3(0, 1.78, -1.05)
	_cabin.add_child(_mirror_pivot)

	# the camera lives in the SubViewport (so it renders there) but each frame we copy
	# the transform of a "mirror eye" node mounted on the car (which the player can aim).
	_mirror_eye = Node3D.new()
	_mirror_eye.rotation_degrees = Vector3(0, 180, 0)   # look backward (+Z = rear)
	_mirror_pivot.add_child(_mirror_eye)
	_mirror_cam = Camera3D.new()
	_mirror_cam.fov = 65.0
	_mirror_cam.far = 220.0
	_mirror_vp.add_child(_mirror_cam)

	var glass := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(0.5, 0.16)
	glass.mesh = qm
	var mat := StandardMaterial3D.new()
	var tex := _mirror_vp.get_texture()
	mat.albedo_texture = tex
	mat.emission_enabled = true
	mat.emission_texture = tex
	mat.emission_energy_multiplier = 1.0
	mat.uv1_scale = Vector3(-1, 1, 1)            # mirror flip
	glass.material_override = mat
	glass.position = Vector3(0, 0, -0.02)
	_mirror_pivot.add_child(glass)

	# clickable frame to grab/adjust
	var area := Area3D.new()
	area.collision_layer = INTERACT_MASK
	area.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.55, 0.2, 0.06)
	cs.shape = bs
	area.add_child(cs)
	area.set_meta("ctrl", _controls.size())
	_mirror_pivot.add_child(area)
	var dummy_mat := StandardMaterial3D.new()
	_controls.append({"area": area, "mesh": glass, "mat": dummy_mat, "kind": "mirror", "prompt": _prompt_for("mirror")})
