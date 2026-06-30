extends Node
## Fully-procedural audio synth for the Hill-Climb sandbox. There are NO audio asset
## files anywhere in the project — every sound here is generated sample-by-sample at
## runtime with AudioStreamGenerator + AudioStreamPlayer. A persistent "engine" voice is
## fed fresh frames every _process (pitch/grit follow car speed, with a filtered-noise
## rocket roar while boosting), and a small pool of one-shot players renders short
## waveforms for coin / cash / click / wreck / landing-thud so overlapping SFX don't cut
## each other. Phase accumulators are kept per oscillator so tones never click between
## frames. Wire-in: instance this node, add_child it, then call setup(car) (re-call after
## a vehicle swap) and the play_* methods from the relevant game events.

const MIX_RATE := 44100.0
const BUF_LEN := 0.1
const POOL_SIZE := 4

@export var master_db := 0.0

var _car: RigidBody3D = null

# --- continuous engine voice -------------------------------------------------
var _engine: AudioStreamPlayer
var _engine_phase := 0.0       # fundamental sine
var _engine_phase2 := 0.0      # 2nd harmonic
var _engine_saw_phase := 0.0   # sawtooth grit
var _engine_amp := 0.0         # smoothed amplitude envelope
var _noise_lp := 0.0           # low-passed noise state (rocket roar)

# --- one-shot SFX pool -------------------------------------------------------
var _pool: Array[AudioStreamPlayer] = []
var _queues: Array[PackedVector2Array] = []   # remaining samples to emit per slot
var _qpos: Array[int] = []                    # read cursor per slot

func _ready() -> void:
	# continuous engine voice intentionally DISABLED — the procedural hum is a
	# placeholder we'd rather replace with a real engine sample later. Leaving
	# _engine null makes _feed_engine a no-op; the one-shot SFX below stay live.
	#_engine = _make_player(-10.0)
	for _i in range(POOL_SIZE):
		_pool.append(_make_player(-6.0))
		_queues.append(PackedVector2Array())
		_qpos.append(0)

## Build an AudioStreamPlayer driven by its own generator, already playing.
func _make_player(db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = BUF_LEN
	p.stream = gen
	p.volume_db = db + master_db
	add_child(p)
	p.play()
	return p

# --- public API --------------------------------------------------------------

## Store the car and (re)connect the landing thud. Safe to call repeatedly (e.g. after a
## vehicle swap that freed the old car and built a new one).
func setup(car: RigidBody3D) -> void:
	if is_instance_valid(_car) and _car.is_connected("landed", _on_landed):
		_car.disconnect("landed", _on_landed)
	_car = car
	if is_instance_valid(_car) and not _car.is_connected("landed", _on_landed):
		_car.connect("landed", _on_landed)

## Short bright ding for a coin pickup.
func play_coin() -> void:
	_emit(_make_tone(1180.0, 0.13, 0.5, 0.4, 3.5))

## Richer "cha-ching": two quick ascending blips.
func play_cash() -> void:
	var buf := _make_tone(880.0, 0.08, 0.45, 0.5, 2.8)
	buf.append_array(_make_tone(1320.0, 0.14, 0.5, 0.5, 3.0))
	_emit(buf)

## Soft, very short UI click.
func play_click() -> void:
	_emit(_make_tone(1700.0, 0.028, 0.35, 0.0, 5.0))

## Noisy crunch/thud burst for a wreck.
func play_wreck() -> void:
	_emit(_make_wreck())

# --- engine voice (continuous) -----------------------------------------------

func _process(delta: float) -> void:
	_feed_engine(delta)
	_feed_oneshots()

func _feed_engine(delta: float) -> void:
	if _engine == null:
		return
	var pb = _engine.get_stream_playback()
	if pb == null:
		return
	var avail: int = pb.get_frames_available()
	if avail <= 0:
		return
	var speed := 0.0
	var dead := false
	var boosting := false
	if is_instance_valid(_car):
		speed = _car.linear_velocity.length()
		dead = bool(_car.get("dead"))
		boosting = bool(_car.get("boosting"))
	var snorm := clampf(speed / 45.0, 0.0, 1.0)
	var freq := lerpf(55.0, 180.0, snorm)
	# fade to near-silence when dead or basically stopped
	var amp_target := 0.0
	if not dead and speed > 0.3:
		amp_target = 0.18 + 0.32 * snorm
	_engine_amp = lerpf(_engine_amp, amp_target, clampf(delta * 6.0, 0.0, 1.0))
	var rocket := 0.4 if (boosting and not dead) else 0.0
	var inc1 := TAU * freq / MIX_RATE
	var inc2 := TAU * freq * 2.0 / MIX_RATE
	var incs := TAU * freq / MIX_RATE
	var buf := PackedVector2Array()
	buf.resize(avail)
	for i in range(avail):
		var s := sin(_engine_phase) * 0.6
		s += sin(_engine_phase2) * 0.3
		var saw := (_engine_saw_phase / TAU) * 2.0 - 1.0
		s += saw * 0.25
		var v := s * _engine_amp
		if rocket > 0.0:
			_noise_lp = lerpf(_noise_lp, randf() * 2.0 - 1.0, 0.25)
			v += _noise_lp * rocket
		v = clampf(v, -1.0, 1.0)
		buf[i] = Vector2(v, v)
		_engine_phase += inc1
		_engine_phase2 += inc2
		_engine_saw_phase += incs
		if _engine_phase > TAU: _engine_phase -= TAU
		if _engine_phase2 > TAU: _engine_phase2 -= TAU
		if _engine_saw_phase > TAU: _engine_saw_phase -= TAU
	pb.push_buffer(buf)

# --- one-shot pool feeding ---------------------------------------------------

func _feed_oneshots() -> void:
	for i in range(_pool.size()):
		if _qpos[i] >= _queues[i].size():
			continue
		var pb = _pool[i].get_stream_playback()
		if pb == null:
			continue
		var avail: int = pb.get_frames_available()
		if avail <= 0:
			continue
		var remaining := _queues[i].size() - _qpos[i]
		var nn := mini(avail, remaining)
		var chunk := _queues[i].slice(_qpos[i], _qpos[i] + nn)
		pb.push_buffer(chunk)
		_qpos[i] += nn

## Hand a freshly-rendered waveform to a free pool slot (else steal slot 0).
func _emit(buf: PackedVector2Array) -> void:
	for i in range(_pool.size()):
		if _qpos[i] >= _queues[i].size():
			_queues[i] = buf
			_qpos[i] = 0
			return
	_queues[0] = buf
	_qpos[0] = 0

# --- waveform builders -------------------------------------------------------

## A decaying sine (optional 2nd harmonic). decay_pow shapes the fade (higher = snappier).
func _make_tone(freq: float, dur: float, vol: float, harmonic2 := 0.0, decay_pow := 3.0) -> PackedVector2Array:
	var n := int(dur * MIX_RATE)
	var buf := PackedVector2Array()
	buf.resize(n)
	var ph := 0.0
	var ph2 := 0.0
	var inc := TAU * freq / MIX_RATE
	var inc2 := TAU * freq * 2.0 / MIX_RATE
	for i in range(n):
		var t := float(i) / float(maxi(n, 1))
		var env := pow(1.0 - t, decay_pow)
		var s := sin(ph) + sin(ph2) * harmonic2
		var v := clampf(s * env * vol, -1.0, 1.0)
		buf[i] = Vector2(v, v)
		ph += inc
		ph2 += inc2
		if ph > TAU: ph -= TAU
		if ph2 > TAU: ph2 -= TAU
	return buf

## A noisy crunch (low-passed noise) over a low sine thud — the wreck sound.
func _make_wreck() -> PackedVector2Array:
	var dur := 0.45
	var n := int(dur * MIX_RATE)
	var buf := PackedVector2Array()
	buf.resize(n)
	var lp := 0.0
	var ph := 0.0
	var inc := TAU * 70.0 / MIX_RATE
	for i in range(n):
		var t := float(i) / float(maxi(n, 1))
		var env := pow(1.0 - t, 2.2)
		lp = lerpf(lp, randf() * 2.0 - 1.0, 0.4)
		var thud := sin(ph) * pow(1.0 - t, 4.0)
		var v := clampf((lp * 0.7 + thud * 0.6) * env * 0.9, -1.0, 1.0)
		buf[i] = Vector2(v, v)
		ph += inc
		if ph > TAU: ph -= TAU
	return buf

## A soft low thud for landings, scaled by impact volume.
func _make_thud(vol: float) -> PackedVector2Array:
	var dur := 0.22
	var n := int(dur * MIX_RATE)
	var buf := PackedVector2Array()
	buf.resize(n)
	var ph := 0.0
	var lp := 0.0
	var inc := TAU * 84.0 / MIX_RATE
	for i in range(n):
		var t := float(i) / float(maxi(n, 1))
		var env := pow(1.0 - t, 3.0)
		lp = lerpf(lp, randf() * 2.0 - 1.0, 0.5)
		var v := clampf((sin(ph) * 0.8 + lp * 0.25) * env * vol, -1.0, 1.0)
		buf[i] = Vector2(v, v)
		ph += inc
		if ph > TAU: ph -= TAU
	return buf

# --- signals -----------------------------------------------------------------

## Car landing thud — volume scales with vertical impact (ignore tiny taps).
func _on_landed(impact: float, _air_time: float) -> void:
	if impact < 1.0:
		return
	_emit(_make_thud(clampf(impact * 0.045, 0.06, 0.75)))
