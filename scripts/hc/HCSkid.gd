extends Node3D
## World-space skid-mark ribbons. A fixed MultiMesh pool of quad segments laid
## between consecutive wheel-ground contacts (fed by HCCar from the SAME analytic
## suspension data it already computed — no terrain queries of our own). Age fade
## happens entirely in the shader off a per-instance birth stamp, so the ONLY
## per-frame CPU cost is one uniform write; laying a segment touches exactly one
## instance slot. The ring buffer IS the persistence horizon: oldest marks are
## reclaimed when the pool wraps.

const MAX_SEGS := 600          # total segments across all four wheel tracks
const FADE_LIFE := 14.0        # seconds from full strength to invisible
const SEG_MIN := 0.28          # accumulate contacts until a segment is this long (m)
const SEG_MAX := 4.0           # longer than this = respawn/teleport, break the strip
const LIFT := 0.03             # metres above the road along its normal (z-fight guard)

var tint := Color(0.05, 0.05, 0.06)   # rubber RGB; cosmetics recolor future marks

var _mmi: MultiMeshInstance3D
var _mm: MultiMesh
var _mat: ShaderMaterial
var _idx := 0                  # ring cursor
var _laid := 0                 # grows to MAX_SEGS then sticks (drives visible count)
var _clock := 0.0              # our own time base for birth stamps (pauses with tree)
# per-track strip state (4 wheels): last contact + whether it's valid to connect from
var _last: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
var _has: Array[bool] = [false, false, false, false]

func _ready() -> void:
	# marks live in WORLD space: the car adds us as a child (so we die with it)
	# but top_level detaches our transform from the moving chassis
	top_level = true
	global_transform = Transform3D.IDENTITY
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	var quad := PlaneMesh.new()   # lies in XZ, +Y up — basis maps it onto the road plane
	quad.size = Vector2.ONE
	_mm.mesh = quad
	_mm.instance_count = MAX_SEGS
	_mm.visible_instance_count = 0
	_mat = ShaderMaterial.new()
	_mat.shader = _make_shader()
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.material_override = _mat
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# marks hug the ground under the camera; a generous manual AABB beats per-frame
	# recomputes and can't pop out of view when segments spread along the run
	_mmi.custom_aabb = AABB(Vector3(-4000, -500, -4000), Vector3(8000, 1000, 8000))
	add_child(_mmi)

func _process(delta: float) -> void:
	_clock += delta
	_mat.set_shader_parameter("u_now", _clock)

## Feed one wheel-ground contact. Lays a quad from the previous contact once the
## gap grows past SEG_MIN; a jump past SEG_MAX (respawn, streamed gap) silently
## restarts the strip instead of drawing a road-crossing streak.
func lay(track: int, pos: Vector3, n: Vector3, width: float, strength: float) -> void:
	if not _has[track]:
		_has[track] = true
		_last[track] = pos
		return
	var seg := pos - _last[track]
	var len := seg.length()
	if len < SEG_MIN:
		return
	if len > SEG_MAX:
		_last[track] = pos
		return
	var dir := seg / len
	var right := dir.cross(n)
	if right.length_squared() < 0.0001:
		_last[track] = pos
		return
	right = right.normalized()
	var mid := (_last[track] + pos) * 0.5 + n * LIFT
	# slight overlap along the direction of travel hides the joint between segments
	var xf := Transform3D(Basis(right * width, n, dir * (len + 0.06)), mid)
	_mm.set_instance_transform(_idx, xf)
	_mm.set_instance_color(_idx, Color(tint.r, tint.g, tint.b, clampf(strength, 0.0, 1.0)))
	_mm.set_instance_custom_data(_idx, Color(_clock, 0.0, 0.0, 0.0))
	_idx = (_idx + 1) % MAX_SEGS
	_laid = mini(_laid + 1, MAX_SEGS)
	_mm.visible_instance_count = _laid
	_last[track] = pos

## Close a wheel's strip (trigger ended / wheel left the ground) so the next mark
## starts fresh instead of connecting across the pause.
func break_track(track: int) -> void:
	_has[track] = false

## Wipe every mark (run reset, checkpoint respawn, map switch).
func clear_all() -> void:
	_idx = 0
	_laid = 0
	_mm.visible_instance_count = 0
	for i in range(_has.size()):
		_has[i] = false

func _make_shader() -> Shader:
	var sh := Shader.new()
	# unshaded translucent rubber; alpha = lay strength * age fade, softened toward
	# the quad's lateral edges so the ribbon doesn't read as hard-edged tape
	sh.code = """
shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled;
uniform float u_now = 0.0;
varying vec4 v_col;
void vertex() {
	float age = u_now - INSTANCE_CUSTOM.x;
	float fade = clamp(1.0 - age / %f, 0.0, 1.0);
	v_col = vec4(COLOR.rgb, COLOR.a * fade * 0.78);
}
void fragment() {
	float lat = abs(UV.x - 0.5) * 2.0;
	ALBEDO = v_col.rgb;
	ALPHA = v_col.a * (1.0 - lat * lat * 0.75);
}
""" % FADE_LIFE
	return sh
