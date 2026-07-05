extends Node3D
## Records a car's transform at a fixed cadence for time-trial ghost playback, and
## renders a recorded run back as a translucent, COLLISION-FREE stand-in car (no
## RigidBody, no physics — just a positioned MeshInstance3D). One HCGhost node is
## created once by HCMain and reused across runs/maps: `start_recording` resets the
## record buffer, `load_data`/`show_at` drive playback independently.
##
## This is deliberately boring and versioned (flat float array, one purpose per
## field) because it is the intended seed of an eventual async-multiplayer "race a
## friend's ghost" feature — a clever/compact format now just means a painful
## migration later.
##
## Stage 1 async multiplayer ("send a friend your ghost") landed: `configure()` sets
## a tint + optional floating name label so HCMain can run two of these nodes at once
## (your own best in blue, an imported rival in red with its filename as a tag), and
## the static `checksum()` backs the shareable .hcghost file format (see HCMain's
## export/import functions) — both live here because they're properties of the
## sample format itself, not of any one HCMain feature.
##
## Sample layout, 8 floats each: [t, x, y, z, qx, qy, qz, qw]. `t` is seconds since
## the recording (or, on playback, the trial run) started — both are the same clock
## (HCMain's trial timer), so show_at(elapsed_trial_time) lines the ghost up directly.

const VERSION := 1
const SAMPLE_HZ := 20.0
const SAMPLE_DT := 1.0 / SAMPLE_HZ
const FLOATS_PER_SAMPLE := 8

var recording := false
var _rec_target: Node3D
var _rec_clock := 0.0
var _rec_next := 0.0
var _rec_samples: PackedFloat32Array = PackedFloat32Array()

var _play_samples: PackedFloat32Array = PackedFloat32Array()
var _play_count := 0

var _mesh_root: Node3D   # built lazily on first load_data() with real samples

# --- appearance (used to tell "your best" apart from an imported rival) --------
var _tint := Color(0.35, 0.75, 1.0, 0.38)   # default: your-ghost blue
var _label_text := ""                        # non-empty shows a floating Label3D (rival name)
var _label3d: Label3D

## Set the mesh tint (and an optional floating name tag) BEFORE or after load_data —
## safe either way: applied immediately if the mesh already exists, else remembered
## for the lazy _build_mesh() on the next load_data() with real samples. HCMain uses
## this to give the personal-best ghost and an imported rival distinct looks.
func configure(tint: Color, label_text: String = "") -> void:
	_tint = tint
	_label_text = label_text
	if _mesh_root:
		_apply_tint()
		_apply_label()

func _apply_tint() -> void:
	for c in _mesh_root.get_children():
		if c is MeshInstance3D and c.material_override is StandardMaterial3D:
			(c.material_override as StandardMaterial3D).albedo_color = _tint

func _apply_label() -> void:
	if _label_text == "":
		if _label3d:
			_label3d.visible = false
		return
	if _label3d == null:
		_label3d = Label3D.new()
		_label3d.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label3d.font_size = 40
		_label3d.outline_size = 10
		_label3d.no_depth_test = true
		_label3d.position = Vector3(0, 1.9, 0)
		_mesh_root.add_child(_label3d)
	_label3d.text = _label_text
	_label3d.modulate = Color(_tint.r, _tint.g, _tint.b, 1.0)
	_label3d.visible = _mesh_root.visible

# --- shareable ghost-file format (Stage 1 async multiplayer) --------------------
## A cheap, dependency-free integrity check for exported .hcghost files: samples are
## rounded to the millisecond-equivalent (x1000) before folding into a 32-bit FNV-1a
## so the check is exact for JSON round-tripped floats (JSON text -> float -> this
## hash reproduces byte-identically, unlike hashing raw float bit patterns which can
## drift a ULP through text round-tripping). Kept in the low 32 bits throughout so
## there is no dependence on GDScript's int overflow behaviour.
static func checksum(samples: Array, time: float) -> int:
	var h: int = 2166136261
	for v in samples:
		var iv: int = int(round(float(v) * 1000.0))
		h = (h ^ (iv & 0xFFFFFFFF)) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	var it: int = int(round(time * 1000.0))
	h = (h ^ it) & 0xFFFFFFFF
	h = (h * 16777619) & 0xFFFFFFFF
	return h

# --- recording -----------------------------------------------------------------

## Begin recording `target`'s transform at SAMPLE_HZ. Call once per trial attempt;
## the buffer is discarded (not appended to) on each call.
func start_recording(target: Node3D) -> void:
	_rec_target = target
	_rec_samples = PackedFloat32Array()
	_rec_clock = 0.0
	_rec_next = 0.0
	recording = true

func stop_recording() -> void:
	recording = false
	_rec_target = null

## Call every frame (any delta source is fine — this drives a visual, not physics).
## No-ops when not recording, so it's always safe to call unconditionally.
func tick_record(delta: float) -> void:
	if not recording or _rec_target == null or not is_instance_valid(_rec_target):
		return
	_rec_clock += delta
	if _rec_clock < _rec_next:
		return
	_rec_next += SAMPLE_DT
	var p: Vector3 = _rec_target.global_position
	var q: Quaternion = _rec_target.global_transform.basis.orthonormalized().get_rotation_quaternion()
	_rec_samples.append(_rec_clock)
	_rec_samples.append(p.x); _rec_samples.append(p.y); _rec_samples.append(p.z)
	_rec_samples.append(q.x); _rec_samples.append(q.y); _rec_samples.append(q.z); _rec_samples.append(q.w)

## Snapshot the current recording as a plain Array[float] (JSON-safe). Empty if
## nothing has been recorded yet.
func recorded_data() -> Array:
	return Array(_rec_samples)

func sample_count() -> int:
	return _rec_samples.size() / FLOATS_PER_SAMPLE

# --- playback --------------------------------------------------------------------

## Load a recording (as produced by recorded_data(), round-tripped through JSON) for
## playback. Malformed data (wrong length) is dropped silently — a ghost that fails
## to parse just never appears; it never crashes the run.
func load_data(data: Array) -> void:
	_play_samples = PackedFloat32Array()
	_play_count = 0
	if data.is_empty() or data.size() % FLOATS_PER_SAMPLE != 0:
		return
	_play_samples.resize(data.size())
	for i in range(data.size()):
		_play_samples[i] = float(data[i])
	_play_count = _play_samples.size() / FLOATS_PER_SAMPLE
	if _play_count > 1 and _mesh_root == null:
		_build_mesh()

func clear_data() -> void:
	_play_samples = PackedFloat32Array()
	_play_count = 0
	hide_ghost()

func has_data() -> bool:
	return _play_count > 1

func total_time() -> float:
	if _play_count == 0:
		return 0.0
	return _play_samples[(_play_count - 1) * FLOATS_PER_SAMPLE]

## Position the ghost mesh at trial-clock time `t` (interpolated between the two
## bracketing samples). Hidden before the first sample / after the last one, rather
## than clamped, so the ghost visibly "finishes" instead of idling on the line.
func show_at(t: float) -> void:
	if not has_data() or _mesh_root == null:
		return
	if t < 0.0 or t > total_time():
		_mesh_root.visible = false
		return
	var lo := 0
	var hi := _play_count - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if _play_samples[mid * FLOATS_PER_SAMPLE] <= t:
			lo = mid
		else:
			hi = mid
	var t0: float = _play_samples[lo * FLOATS_PER_SAMPLE]
	var t1: float = _play_samples[hi * FLOATS_PER_SAMPLE]
	var f: float = 0.0 if t1 <= t0 else clampf((t - t0) / (t1 - t0), 0.0, 1.0)
	_mesh_root.visible = true
	_mesh_root.global_position = _sample_pos(lo).lerp(_sample_pos(hi), f)
	_mesh_root.global_transform.basis = Basis(_sample_rot(lo).slerp(_sample_rot(hi), f))
	if _label3d:
		_label3d.visible = true

func hide_ghost() -> void:
	if _mesh_root:
		_mesh_root.visible = false
	if _label3d:
		_label3d.visible = false

func _sample_pos(i: int) -> Vector3:
	var b := i * FLOATS_PER_SAMPLE
	return Vector3(_play_samples[b + 1], _play_samples[b + 2], _play_samples[b + 3])

func _sample_rot(i: int) -> Quaternion:
	var b := i * FLOATS_PER_SAMPLE
	return Quaternion(_play_samples[b + 4], _play_samples[b + 5], _play_samples[b + 6], _play_samples[b + 7]).normalized()

## A cheap, collision-free silhouette so the ghost reads as "a car" without touching
## HCCarBody/HCCar (out of scope for this pass) or loading a GLB. Unshaded + additive-
## ish alpha keeps it cheap and unmistakably "not a real car".
func _build_mesh() -> void:
	_mesh_root = Node3D.new()
	add_child(_mesh_root)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _tint
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.8, 0.9, 3.6)
	body.mesh = box
	body.position = Vector3(0, 0.55, 0)
	body.material_override = mat
	_mesh_root.add_child(body)
	var cabin := MeshInstance3D.new()
	var cbox := BoxMesh.new()
	cbox.size = Vector3(1.3, 0.6, 1.6)
	cabin.mesh = cbox
	cabin.position = Vector3(0, 1.15, -0.2)
	cabin.material_override = mat
	_mesh_root.add_child(cabin)
	_mesh_root.visible = false
	_apply_label()
