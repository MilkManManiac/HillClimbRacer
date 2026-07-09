extends Node
## Headless probe for scripts/hc/HCAudio.gd: instantiates the synth standalone (no
## game boot needed — HCAudio has zero HCMain/HCCar dependencies beyond a duck-typed
## "car" for setup()), drives every public method, and checks the generated sample
## buffers are non-silent (peak > MIN_PEAK) and non-clipping (peak < MAX_PEAK).
## Headless Godot has no audio device, so this can't verify actual playback — it
## verifies exactly what would be pushed into AudioStreamGeneratorPlayback.
## Run: <godot_console> --headless --path . tests/AudioProbe.tscn

const HCAudioScript := preload("res://scripts/hc/HCAudio.gd")
const MIN_PEAK := 0.015     # buffers quieter than this would be inaudible -> "silent" fail
const MAX_PEAK := 0.999     # buffers at/above this are flat-topping -> "clipping" fail
const VEH_KEYS := ["minivan", "hotrod", "monster", "sports", "f1"]

var _audio: Node
var _all_ok := true

func _ready() -> void:
	_audio = HCAudioScript.new()
	add_child(_audio)
	await get_tree().process_frame   # let HCAudio._ready() build its players

	_check_oneshots()
	_check_engine_profiles()
	_check_drift()
	_check_boost()
	_check_volume()
	_check_car_wiring()
	await _check_live_process_tick()

	print("[audio_probe] %s" % ("ALL PASS" if _all_ok else "SOME FAILED"))
	get_tree().quit(0 if _all_ok else 1)

func _peak(buf: PackedVector2Array) -> float:
	var m := 0.0
	for v in buf:
		m = maxf(m, absf(v.x))
	return m

func _report(label: String, buf: PackedVector2Array, expect_silent := false) -> void:
	# expect_silent flips the pass criterion: a buffer that's supposed to be inaudible
	# (gated drift/boost, a dropped sub-threshold landing tap) passes when its peak is AT
	# or below the noise floor; a real sound passes when it clears the floor but never
	# flat-tops the ceiling.
	var peak := 0.0 if buf.is_empty() else _peak(buf)
	var ok: bool = (peak <= MIN_PEAK) if expect_silent else (peak > MIN_PEAK and peak < MAX_PEAK)
	print("[audio_probe] %-28s -> %s (n=%d peak=%.4f)" % [label, ("PASS" if ok else "FAIL"), buf.size(), peak])
	_all_ok = _all_ok and ok

# --- one-shots ----------------------------------------------------------------

func _check_oneshots() -> void:
	_report("play_coin", _audio.call("play_coin"))
	_report("play_cash", _audio.call("play_cash"))
	_report("play_click", _audio.call("play_click"))
	_report("play_hover", _audio.call("play_hover"))
	_report("play_checkpoint", _audio.call("play_checkpoint"))
	_report("play_combo(1)", _audio.call("play_combo", 1))
	_report("play_combo(8)", _audio.call("play_combo", 8))
	_report("play_bank", _audio.call("play_bank"))
	_report("play_combo_lost", _audio.call("play_combo_lost"))
	_report("play_wreck", _audio.call("play_wreck"))
	_report("play_landing(0.05)", _audio.call("play_landing", 0.05))
	_report("play_landing(1.0)", _audio.call("play_landing", 1.0))
	# strengths at/under the noise-floor cutoff must stay silent (no click on tiny taps)
	_report("play_landing(0.0) [silent]", _audio.call("play_landing", 0.0), true)

# --- continuous: engine, one profile per vehicle -------------------------------

func _settle_engine(speed_ratio: float, throttle: float, blocks: int) -> PackedVector2Array:
	_audio.call("set_engine", speed_ratio, throttle)
	var last := PackedVector2Array()
	for _i in range(blocks):
		last = _audio.call("_gen_engine_block", 512)
	return last

func _check_engine_profiles() -> void:
	for vk in VEH_KEYS:
		_audio.call("set_vehicle_type", vk)
		# idle: quiet but must still hum (never total silence at a standstill)
		var idle_buf := _settle_engine(0.0, 0.0, 40)
		_report("engine[%s] idle" % vk, idle_buf)
		# WOT: loud, must stay clear of clipping even at max speed+throttle
		var wot_buf := _settle_engine(1.0, 1.0, 40)
		_report("engine[%s] full-throttle" % vk, wot_buf)
	_audio.call("set_vehicle_type", "hotrod")   # leave in the default state for later checks

# --- continuous: drift squeal ---------------------------------------------------

func _check_drift() -> void:
	_audio.call("set_engine", 0.9, 0.5)   # needs real speed — the squeal is speed-gated
	_audio.call("start_drift")
	var on_buf := PackedVector2Array()
	for _i in range(60):
		on_buf = _audio.call("_gen_drift_block", 512)
	_report("drift squeal (on, speed=0.9)", on_buf)

	_audio.call("set_engine", 0.0, 0.0)   # stationary "drifting" must stay silent (speed gate)
	var gated_buf := PackedVector2Array()
	for _i in range(60):
		gated_buf = _audio.call("_gen_drift_block", 512)
	_report("drift squeal (on, speed=0) [silent]", gated_buf, true)

	_audio.call("set_engine", 0.9, 0.5)
	_audio.call("stop_drift")
	var off_buf := PackedVector2Array()
	for _i in range(200):   # long enough for the envelope to fully decay
		off_buf = _audio.call("_gen_drift_block", 512)
	_report("drift squeal (off, decayed) [silent]", off_buf, true)

# --- continuous: boost roar ------------------------------------------------------

func _check_boost() -> void:
	_audio.call("start_boost")
	var on_buf := PackedVector2Array()
	for _i in range(60):
		on_buf = _audio.call("_gen_boost_block", 512)
	_report("boost roar (on)", on_buf)

	_audio.call("stop_boost")
	var off_buf := PackedVector2Array()
	for _i in range(200):
		off_buf = _audio.call("_gen_boost_block", 512)
	_report("boost roar (off, decayed) [silent]", off_buf, true)

# --- volume properties ------------------------------------------------------------

func _check_volume() -> void:
	_audio.call("set_master_volume", 0.0)
	var engine_p: AudioStreamPlayer = _audio.get("_engine_p")
	var muted_db: float = engine_p.volume_db
	var ok_muted := muted_db < -60.0
	print("[audio_probe] %-28s -> %s (volume_db=%.1f)" % ["master_volume=0 mutes", ("PASS" if ok_muted else "FAIL"), muted_db])
	_all_ok = _all_ok and ok_muted

	_audio.call("set_master_volume", 1.0)
	_audio.call("set_sfx_volume", 1.0)
	var restored_db: float = engine_p.volume_db
	var ok_restored := restored_db > -20.0
	print("[audio_probe] %-28s -> %s (volume_db=%.1f)" % ["master_volume=1 restores", ("PASS" if ok_restored else "FAIL"), restored_db])
	_all_ok = _all_ok and ok_restored

# --- setup()/landed-signal wiring with a minimal fake car -------------------------

func _make_fake_car(vtype: String) -> RigidBody3D:
	var src := "extends RigidBody3D\nsignal landed(impact, air_time)\nvar dead := false\nvar vehicle_type := \"%s\"\n" % vtype
	var script := GDScript.new()
	script.source_code = src
	script.reload()
	var car := RigidBody3D.new()
	car.set_script(script)
	add_child(car)
	return car

func _check_car_wiring() -> void:
	var car := _make_fake_car("monster")
	_audio.call("setup", car)
	var prof: Dictionary = _audio.get("_engine_profile")
	var ok_profile: bool = is_equal_approx(float(prof.get("idle", -1.0)), 32.0)   # monster's idle Hz
	print("[audio_probe] %-28s -> %s" % ["setup() reads vehicle_type", ("PASS" if ok_profile else "FAIL")])
	_all_ok = _all_ok and ok_profile

	# emitting "landed" on the fake car should reach _on_landed and queue a thud —
	# check a pool slot picks up fresh, non-empty data.
	var queues_before: Array = (_audio.get("_queues") as Array).duplicate()
	car.emit_signal("landed", 15.0, 1.0)
	var queues_after: Array = _audio.get("_queues")
	var got_new := false
	for i in range(queues_after.size()):
		var before: PackedVector2Array = queues_before[i]
		var after: PackedVector2Array = queues_after[i]
		if after.size() > 0 and (before.size() != after.size() or before != after):
			got_new = true
	print("[audio_probe] %-28s -> %s" % ["landed signal -> thud queued", ("PASS" if got_new else "FAIL")])
	_all_ok = _all_ok and got_new
	car.queue_free()

# --- one real tick through the live SceneTree path (push_buffer etc.) -------------

func _check_live_process_tick() -> void:
	# exercises the actual runtime path (_process -> _feed_continuous/_feed_oneshots ->
	# AudioStreamGeneratorPlayback.push_buffer) headless, not just the pure generators
	# above. A script error here would abort the tree, so surviving N frames is the pass.
	_audio.call("play_coin")
	_audio.call("start_boost")
	for _i in range(10):
		await get_tree().process_frame
	_audio.call("stop_boost")
	print("[audio_probe] %-28s -> PASS (survived 10 live frames)" % "live _process tick")
