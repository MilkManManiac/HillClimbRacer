extends Node
## Fully-procedural audio synth for the Hill-Climb sandbox. There are NO audio asset
## files anywhere in the project — every sound here is generated sample-by-sample at
## runtime and pushed into AudioStreamGenerator playbacks. Three continuous voices
## (engine hum, drift squeal, boost roar) are fed fresh frames every _process, with
## their amplitude/pitch envelopes smoothed PER SAMPLE (not per game-frame) so they
## can never click or zipper regardless of caller frame rate. A small pool of
## one-shot players renders short waveforms for coin/cash/click/hover/checkpoint/
## wreck/landing so overlapping SFX don't cut each other off.
##
## This file is intentionally the ONLY place that knows how any sound is made — every
## event is one public method (play_coin(), set_engine(...), start_drift()/stop_drift(),
## ...) with no game logic inside. Swapping any of these for a real sample later means
## replacing the body of one function; call sites in HCMain/HCCar never change.
##
## Wire-in: instance this node, add_child it, call setup(car) once (re-call after a
## vehicle swap — it re-reads car.vehicle_type for the engine character and reconnects
## the "landed" signal), then drive it every frame with set_engine(speed_ratio,
## throttle) plus start_/stop_drift() and start_/stop_boost() on state transitions, and
## call the one-shot play_*() methods from the relevant game events.

const MIX_RATE := 44100.0
const BUF_LEN := 0.1
const POOL_SIZE := 4

# Per-player base gains (dB) before the master/SFX trim is added — balances the three
# continuous voices and the one-shot pool against each other at unity volume.
const ENGINE_BASE_DB := -9.0
const DRIFT_BASE_DB := -11.0
const BOOST_BASE_DB := -7.0
const ONESHOT_BASE_DB := -6.0

## Per-vehicle engine character: idle/top fundamental frequency (Hz), how much raw
## sawtooth grit (roughness), low-passed noise texture (diesel/growl), a sub-octave
## sine (heavy rumble), and a bright upper harmonic (screamy top end). Keys match
## HCMain.VEH_KEYS; anything unrecognised falls back to "hotrod" (HCCar's own default
## vehicle_type), so a fresh/unknown vehicle never plays silence.
const ENGINE_PROFILES := {
	"minivan": {"idle": 42.0, "top": 145.0, "saw": 0.16, "noise": 0.12, "sub": 0.28, "bright": 0.08},
	"hotrod":  {"idle": 55.0, "top": 190.0, "saw": 0.26, "noise": 0.14, "sub": 0.16, "bright": 0.20},
	"monster": {"idle": 32.0, "top": 118.0, "saw": 0.18, "noise": 0.30, "sub": 0.40, "bright": 0.06},
	"sports":  {"idle": 68.0, "top": 250.0, "saw": 0.32, "noise": 0.09, "sub": 0.10, "bright": 0.32},
	"f1":      {"idle": 88.0, "top": 410.0, "saw": 0.40, "noise": 0.05, "sub": 0.04, "bright": 0.46},
}
const DEFAULT_PROFILE_KEY := "hotrod"

# --- volume: linear 0-1 properties for a future settings menu ----------------
# Kept as plain exported floats (bindable straight to a Slider.value in the editor)
# rather than property setters, so assigning the default at parse time can't race
# _ready(); call set_master_volume()/set_sfx_volume() at runtime to also push the
# change onto the live players immediately.
@export_range(0.0, 1.0) var master_volume: float = 1.0
@export_range(0.0, 1.0) var sfx_volume: float = 1.0

var _car: RigidBody3D = null
var _car_dead := false

# --- continuous engine voice -------------------------------------------------
var _engine_p: AudioStreamPlayer
var _engine_profile: Dictionary = ENGINE_PROFILES[DEFAULT_PROFILE_KEY]
var _speed_ratio := 0.0        # last value handed to set_engine(), 0-1
var _throttle := 0.0           # last value handed to set_engine(), 0-1
var _engine_amp := 0.0         # per-sample-smoothed amplitude envelope
var _engine_freq := 55.0       # per-sample-smoothed fundamental (Hz)
var _engine_phase := 0.0
var _engine_bright_phase := 0.0
var _engine_sub_phase := 0.0
var _engine_saw_phase := 0.0
var _engine_noise_lp := 0.0
var _last_engine_buf := PackedVector2Array()   # debug/test hook, see debug_last_buffers()

# --- continuous drift squeal voice -------------------------------------------
var _drift_p: AudioStreamPlayer
var _drift_target := 0.0       # 1.0 while start_drift()..stop_drift(), else 0.0
var _drift_amp := 0.0
var _drift_phase1 := 0.0
var _drift_phase2 := 0.0
var _drift_vib_phase := 0.0
var _drift_noise_lp := 0.0
var _last_drift_buf := PackedVector2Array()

# --- continuous boost roar voice ----------------------------------------------
var _boost_p: AudioStreamPlayer
var _boost_target := 0.0       # 1.0 while start_boost()..stop_boost(), else 0.0
var _boost_amp := 0.0
var _boost_phase := 0.0
var _boost_noise_lp := 0.0
var _last_boost_buf := PackedVector2Array()

# --- one-shot SFX pool -------------------------------------------------------
var _pool: Array[AudioStreamPlayer] = []
var _queues: Array[PackedVector2Array] = []   # remaining samples to emit per slot
var _qpos: Array[int] = []                    # read cursor per slot

func _ready() -> void:
	_engine_p = _make_player(ENGINE_BASE_DB)
	_drift_p = _make_player(DRIFT_BASE_DB)
	_boost_p = _make_player(BOOST_BASE_DB)
	for _i in range(POOL_SIZE):
		_pool.append(_make_player(ONESHOT_BASE_DB))
		_queues.append(PackedVector2Array())
		_qpos.append(0)
	_apply_volumes()

## Build an AudioStreamPlayer driven by its own generator, already playing.
func _make_player(db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = BUF_LEN
	p.stream = gen
	p.volume_db = db
	add_child(p)
	p.play()
	return p

# --- public API: setup / volume ----------------------------------------------

## Store the car, (re)connect the landing signal, and pick the engine character from
## car.vehicle_type. Safe to call repeatedly (e.g. after a vehicle swap that freed the
## old car and built a new one).
func setup(car: RigidBody3D) -> void:
	if is_instance_valid(_car) and _car.is_connected("landed", _on_landed):
		_car.disconnect("landed", _on_landed)
	_car = car
	if is_instance_valid(_car):
		if not _car.is_connected("landed", _on_landed):
			_car.connect("landed", _on_landed)
		_car_dead = bool(_car.get("dead"))
		set_vehicle_type(String(_car.get("vehicle_type")))
	else:
		_car_dead = false

## Pick the engine timbre by vehicle key (also called automatically from setup()).
## Unknown keys fall back to the same default HCCar itself uses ("hotrod").
func set_vehicle_type(vtype: String) -> void:
	_engine_profile = ENGINE_PROFILES.get(vtype, ENGINE_PROFILES[DEFAULT_PROFILE_KEY])

## Overall volume, linear 0-1 (e.g. straight off a settings-menu slider).
func set_master_volume(v: float) -> void:
	master_volume = clampf(v, 0.0, 1.0)
	_apply_volumes()

## SFX volume, linear 0-1. Kept separate from master so a future music bus (or a
## "mute engine, keep UI sounds" toggle) has somewhere to live without touching master.
func set_sfx_volume(v: float) -> void:
	sfx_volume = clampf(v, 0.0, 1.0)
	_apply_volumes()

func _apply_volumes() -> void:
	var gain_db := _lin_to_db(master_volume) + _lin_to_db(sfx_volume)
	if _engine_p: _engine_p.volume_db = ENGINE_BASE_DB + gain_db
	if _drift_p: _drift_p.volume_db = DRIFT_BASE_DB + gain_db
	if _boost_p: _boost_p.volume_db = BOOST_BASE_DB + gain_db
	for p in _pool:
		p.volume_db = ONESHOT_BASE_DB + gain_db

func _lin_to_db(v: float) -> float:
	return -80.0 if v <= 0.0001 else linear_to_db(v)

# --- public API: continuous voices --------------------------------------------

## Drive the engine hum. speed_ratio and throttle are both 0-1 (caller normalises,
## e.g. speed_ratio = car.linear_velocity.length() / car.max_speed) — HCAudio does no
## physics of its own. Also feeds the speed-scaling of the drift squeal and boost roar
## so those two don't need their own per-frame speed argument.
func set_engine(speed_ratio: float, throttle: float) -> void:
	_speed_ratio = clampf(speed_ratio, 0.0, 1.0)
	_throttle = clampf(throttle, 0.0, 1.0)

## Begin the tire-squeal layer (fades in, no click). Call once on the false->true edge
## of the game's "drifting" flag.
func start_drift() -> void:
	_drift_target = 1.0

## End the tire-squeal layer (fades out, no click). Call once on the true->false edge.
func stop_drift() -> void:
	_drift_target = 0.0

## Begin the boost/rocket roar layer (fades in). Call once when the boost input is
## first pressed.
func start_boost() -> void:
	_boost_target = 1.0

## End the boost/rocket roar layer (fades out). Call once when the boost input is
## released or fuel runs out.
func stop_boost() -> void:
	_boost_target = 0.0

# --- public API: one-shots -----------------------------------------------------
# Each returns the buffer it queued (useful for headless testing); game call sites can
# ignore the return value, e.g. `_audio.call("play_coin")`.

## Short bright ding for a coin/fuel/nitro pickup.
func play_coin() -> PackedVector2Array:
	var buf := _make_tone(1180.0, 0.13, 0.5, 0.4, 3.5)
	_emit(buf)
	return buf

## Richer "cha-ching": two quick ascending blips, for a shop purchase/sale.
func play_cash() -> PackedVector2Array:
	var buf := _make_tone(880.0, 0.08, 0.45, 0.5, 2.8)
	buf.append_array(_make_tone(1320.0, 0.14, 0.5, 0.5, 3.0))
	_emit(buf)
	return buf

## Soft, very short UI click (menu/shop button press).
func play_click() -> PackedVector2Array:
	var buf := _make_tone(1700.0, 0.028, 0.35, 0.0, 5.0)
	_emit(buf)
	return buf

## Even softer/quieter tick for UI hover (mouse_entered/focus_entered) — meant to be
## nearly subliminal, just enough presence to confirm focus moved.
func play_hover() -> PackedVector2Array:
	var buf := _make_tone(1100.0, 0.02, 0.16, 0.0, 6.0)
	_emit(buf)
	return buf

## Three-note ascending chime for clearing a sprint checkpoint — distinct from the
## plain coin ding so a checkpoint reads as a bigger, more "official" event.
func play_checkpoint() -> PackedVector2Array:
	var buf := _make_tone(523.25, 0.10, 0.40, 0.35, 3.2)   # C5
	buf.append_array(_make_tone(659.25, 0.10, 0.42, 0.35, 3.2))   # E5
	buf.append_array(_make_tone(784.0, 0.18, 0.46, 0.4, 2.6))     # G5 — the chime lands here
	_emit(buf)
	return buf

## Escalating combo blip — pitch climbs with the chain length so a growing combo
## audibly winds up (capped so a monster chain stays musical, not shrill).
func play_combo(chain: int) -> PackedVector2Array:
	var f := 740.0 * pow(1.122, float(clampi(chain, 1, 8)))   # ~a semitone per step
	var buf := _make_tone(f, 0.09, 0.42, 0.35, 3.0)
	_emit(buf)
	return buf

## Bright ascending triad for banking a combo pot — bigger than the cash blip,
## smaller than a checkpoint chime.
func play_bank() -> PackedVector2Array:
	var buf := _make_tone(659.25, 0.07, 0.40, 0.4, 3.0)    # E5
	buf.append_array(_make_tone(880.0, 0.07, 0.44, 0.4, 3.0))    # A5
	buf.append_array(_make_tone(1174.66, 0.16, 0.48, 0.45, 2.6)) # D6 — payout lands here
	_emit(buf)
	return buf

## Descending two-note womp for a dropped combo pot (wreck / flat slam).
func play_combo_lost() -> PackedVector2Array:
	var buf := _make_tone(520.0, 0.09, 0.40, 0.3, 2.6)
	buf.append_array(_make_tone(392.0, 0.20, 0.42, 0.3, 2.2))
	_emit(buf)
	return buf

## Squeaky rising chirp for the balloon bundle inflating (float deploy). Three fast
## ascending tones with a strong 2nd harmonic read as rubber stretching, not music.
func play_balloon_inflate() -> PackedVector2Array:
	var buf := _make_tone(620.0, 0.07, 0.34, 0.8, 2.2)
	buf.append_array(_make_tone(910.0, 0.07, 0.36, 0.8, 2.2))
	buf.append_array(_make_tone(1340.0, 0.12, 0.38, 0.7, 2.6))
	_emit(buf)
	return buf

## One balloon bursting: a very short bright snap over a tiny low thump. Randomly
## detuned a little so a staggered chain of pops doesn't sound machine-gun identical.
func play_balloon_pop() -> PackedVector2Array:
	var f := 2200.0 * randf_range(0.9, 1.15)
	var buf := _make_tone(f, 0.035, 0.5, 0.5, 7.0)
	buf.append_array(_make_tone(180.0, 0.06, 0.3, 0.0, 5.0))
	_emit(buf)
	return buf

## Noisy crunch/thud burst for a wreck (car death).
func play_wreck() -> PackedVector2Array:
	var buf := _make_wreck()
	_emit(buf)
	return buf

## Landing thud, impact-scaled. strength is 0-1 (caller normalises the car's landing
## severity, e.g. clamp(impact_speed / 20.0, 0, 1)) — tiny taps under ~0.02 are dropped
## so gentle touchdowns stay silent rather than clicking.
func play_landing(strength: float) -> PackedVector2Array:
	var s := clampf(strength, 0.0, 1.0)
	if s <= 0.02:
		return PackedVector2Array()
	var buf := _make_thud(s)
	_emit(buf)
	return buf

# --- per-frame feed ------------------------------------------------------------

func _process(_delta: float) -> void:
	if is_instance_valid(_car):
		_car_dead = bool(_car.get("dead"))
	_feed_continuous(_engine_p, "_gen_engine_block")
	_feed_continuous(_drift_p, "_gen_drift_block")
	_feed_continuous(_boost_p, "_gen_boost_block")
	_feed_oneshots()

func _feed_continuous(player: AudioStreamPlayer, gen_method: StringName) -> void:
	if player == null:
		return
	var pb = player.get_stream_playback()
	if pb == null:
		return
	var avail: int = pb.get_frames_available()
	if avail <= 0:
		return
	pb.push_buffer(call(gen_method, avail))

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

# --- continuous voice generators ------------------------------------------------
# All envelope/pitch smoothing happens PER SAMPLE (not per call), so these are safe to
# call at any rate — a headless test calling them back-to-back gets the same clickless
# ramp behaviour as _process() calling them once per frame.

## Engine hum: sine fundamental + sub-octave rumble + bright harmonic + sawtooth grit +
## low-passed noise texture, mixed per the active vehicle's ENGINE_PROFILES entry.
func _gen_engine_block(n: int) -> PackedVector2Array:
	var buf := PackedVector2Array()
	buf.resize(n)
	var prof: Dictionary = _engine_profile
	var amp_target := 0.0
	# freq_target is a plain local — _engine_freq (the persistent, per-sample-smoothed
	# state) chases it below. Never assign _engine_freq directly here or the smoothing
	# collapses to an instant snap every block.
	var freq_target: float = lerpf(prof.idle, prof.top, pow(_speed_ratio, 0.75))
	if not _car_dead:
		# small transient rev when flooring it from a standstill (wheelspin character)
		var rev_lift: float = _throttle * (1.0 - _speed_ratio) * 0.18
		freq_target *= (1.0 + rev_lift)
		amp_target = clampf(0.08 + 0.26 * _speed_ratio + 0.14 * _throttle, 0.0, 0.55)
	var k_amp := 6.0 / MIX_RATE
	var k_freq := 3.0 / MIX_RATE
	for i in range(n):
		_engine_amp += (amp_target - _engine_amp) * k_amp
		_engine_freq += (freq_target - _engine_freq) * k_freq
		var inc := TAU * _engine_freq / MIX_RATE
		var inc_bright := TAU * _engine_freq * 3.0 / MIX_RATE
		var inc_sub := TAU * _engine_freq * 0.5 / MIX_RATE
		var s := sin(_engine_phase) * 0.5
		s += sin(_engine_bright_phase) * float(prof.bright)
		s += sin(_engine_sub_phase) * float(prof.sub)
		var saw := (_engine_saw_phase / TAU) * 2.0 - 1.0
		s += saw * float(prof.saw)
		_engine_noise_lp = lerpf(_engine_noise_lp, randf() * 2.0 - 1.0, 0.35)
		s += _engine_noise_lp * float(prof.noise)
		var v := clampf(s * _engine_amp, -0.95, 0.95)
		buf[i] = Vector2(v, v)
		_engine_phase = fmod(_engine_phase + inc, TAU)
		_engine_bright_phase = fmod(_engine_bright_phase + inc_bright, TAU)
		_engine_sub_phase = fmod(_engine_sub_phase + inc_sub, TAU)
		_engine_saw_phase = fmod(_engine_saw_phase + inc, TAU)
	_last_engine_buf = buf
	return buf

## Drift squeal: two closely-detuned sines (beating screech) plus filtered noise, faded
## by both the drift on/off flag AND the current speed (a stationary "drifting" flag —
## e.g. handbrake at a standstill — should stay silent).
func _gen_drift_block(n: int) -> PackedVector2Array:
	var buf := PackedVector2Array()
	buf.resize(n)
	var speed_gate := clampf(_speed_ratio * 3.0, 0.0, 1.0)
	var target := _drift_target * speed_gate
	var base_freq := lerpf(900.0, 2200.0, _speed_ratio)
	var k_amp := 10.0 / MIX_RATE
	for i in range(n):
		_drift_amp += (target - _drift_amp) * k_amp
		var vib := sin(_drift_vib_phase) * 14.0
		var f1 := base_freq + vib
		var f2 := base_freq + 35.0 + vib
		_drift_noise_lp = lerpf(_drift_noise_lp, randf() * 2.0 - 1.0, 0.5)
		var s := (sin(_drift_phase1) + sin(_drift_phase2)) * 0.28 + _drift_noise_lp * 0.32
		var v := clampf(s * _drift_amp, -0.9, 0.9)
		buf[i] = Vector2(v, v)
		_drift_phase1 = fmod(_drift_phase1 + TAU * f1 / MIX_RATE, TAU)
		_drift_phase2 = fmod(_drift_phase2 + TAU * f2 / MIX_RATE, TAU)
		_drift_vib_phase = fmod(_drift_vib_phase + TAU * 6.0 / MIX_RATE, TAU)
	_last_drift_buf = buf
	return buf

## Boost/rocket roar: low-passed noise (rocket wash) over a low rumbling tone, scaled
## with speed so a boosted top-speed run roars a bit deeper than a standing-start kick.
func _gen_boost_block(n: int) -> PackedVector2Array:
	var buf := PackedVector2Array()
	buf.resize(n)
	var freq := lerpf(70.0, 110.0, _speed_ratio)
	var k_amp := 8.0 / MIX_RATE
	var inc := TAU * freq / MIX_RATE
	for i in range(n):
		_boost_amp += (_boost_target - _boost_amp) * k_amp
		_boost_noise_lp = lerpf(_boost_noise_lp, randf() * 2.0 - 1.0, 0.22)
		var tone := sin(_boost_phase)
		var s := tone * 0.4 + _boost_noise_lp * 0.6
		var v := clampf(s * _boost_amp * 0.55, -0.9, 0.9)
		buf[i] = Vector2(v, v)
		_boost_phase = fmod(_boost_phase + inc, TAU)
	_last_boost_buf = buf
	return buf

# --- one-shot waveform builders --------------------------------------------------

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
		var v := clampf(s * env * vol, -0.95, 0.95)
		buf[i] = Vector2(v, v)
		ph = fmod(ph + inc, TAU)
		ph2 = fmod(ph2 + inc2, TAU)
	return buf

## A noisy crunch (low-passed noise) over a low sine thud — the wreck sound.
func _make_wreck() -> PackedVector2Array:
	# three layers: the original metal crunch (front-loaded), a 42 Hz sub thump so the
	# explosion lands in the chest, and a sparse crackle tail (debris settling) that
	# rises after the hit and dies with the buffer
	var dur := 0.9
	var n := int(dur * MIX_RATE)
	var buf := PackedVector2Array()
	buf.resize(n)
	var lp := 0.0
	var ph := 0.0
	var sph := 0.0
	var crk := 0.0
	var inc := TAU * 70.0 / MIX_RATE
	var sinc := TAU * 42.0 / MIX_RATE
	for i in range(n):
		var t := float(i) / float(maxi(n, 1))
		# the crunch occupies the first half of the (now longer) buffer at its old feel
		var tc := minf(t * 2.0, 1.0)
		var env := pow(1.0 - tc, 2.2)
		lp = lerpf(lp, randf() * 2.0 - 1.0, 0.4)
		var thud := sin(ph) * pow(1.0 - tc, 4.0)
		var sub := sin(sph) * pow(1.0 - t, 2.6) * 0.5
		# crackle: rare impulses smeared through a one-pole low-pass, fading over the tail
		if randf() < 0.015:
			crk = randf() * 2.0 - 1.0
		crk *= 0.994
		var tail := crk * clampf(t * 6.0, 0.0, 1.0) * pow(1.0 - t, 1.6) * 0.55
		var v := clampf((lp * 0.5 + thud * 0.4) * env * 0.85 + sub + tail, -0.95, 0.95)
		buf[i] = Vector2(v, v)
		ph = fmod(ph + inc, TAU)
		sph = fmod(sph + sinc, TAU)
	return buf

## Low thud for landings. strength 0-1 scales both loudness and how boomy/long it is —
## a hard hit drops in pitch and lasts longer than a light tap.
func _make_thud(strength: float) -> PackedVector2Array:
	var vol := lerpf(0.12, 0.85, strength)
	var freq := lerpf(100.0, 58.0, strength)
	var dur := lerpf(0.16, 0.30, strength)
	var n := int(dur * MIX_RATE)
	var buf := PackedVector2Array()
	buf.resize(n)
	var ph := 0.0
	var lp := 0.0
	var inc := TAU * freq / MIX_RATE
	var noise_mix := 0.15 + 0.25 * strength
	for i in range(n):
		var t := float(i) / float(maxi(n, 1))
		var env := pow(1.0 - t, 3.0)
		lp = lerpf(lp, randf() * 2.0 - 1.0, 0.5)
		var v := clampf((sin(ph) * 0.65 + lp * noise_mix) * env * vol, -0.95, 0.95)
		buf[i] = Vector2(v, v)
		ph = fmod(ph + inc, TAU)
	return buf

# --- signals -----------------------------------------------------------------

## Car landing thud — volume/pitch scale with vertical impact (ignore tiny taps). The
## car's "landed" signal reports a raw velocity-into-surface in m/s; 20 m/s is roughly
## the hardest hit HCCar's own damage/dust thresholds treat as "big", so that's the
## normalisation point for the public 0-1 play_landing() strength.
func _on_landed(impact: float, _air_time: float) -> void:
	if impact < 1.0:
		return
	play_landing(clampf(impact / 20.0, 0.0, 1.0))

# --- test/debug hook -----------------------------------------------------------

## Most recently generated sample block for each continuous voice. Not used by any
## gameplay code — exists so a headless probe can assert non-silence/non-clipping
## without a real audio device (which can't play back what's queued via push_buffer).
func debug_last_buffers() -> Dictionary:
	return {"engine": _last_engine_buf, "drift": _last_drift_buf, "boost": _last_boost_buf}
