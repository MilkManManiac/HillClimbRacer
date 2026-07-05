extends Node
## Manual audio audition — NOT part of the headless battery. Run WITHOUT --headless so
## you can actually hear it: plays every one-shot with a printed label, then an
## engine sweep (idle -> full throttle) per vehicle, then a drift-squeal and a
## boost-roar hold. Takes about 25-30 seconds and quits itself.
## Human ears required to judge quality; tests/AudioProbe.tscn covers the headless
## correctness checks (non-silence/non-clipping) this demo can't verify by itself.
## Run: <godot_gui_exe> --path . tests/AudioDemo.tscn

const HCAudioScript := preload("res://scripts/hc/HCAudio.gd")
const VEH_KEYS := ["minivan", "hotrod", "monster", "sports", "f1"]

var _audio: Node

func _ready() -> void:
	_audio = HCAudioScript.new()
	add_child(_audio)
	await get_tree().process_frame   # let HCAudio._ready() build its players first
	await _run_demo()
	_label("done — quitting")
	get_tree().quit()

func _label(text: String) -> void:
	print("[audio_demo] %s" % text)

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout

## Ramp set_engine(speed_ratio, throttle) together from 0 to 1 over dur seconds —
## a simple "flooring it from a standstill" sweep for auditioning one vehicle profile.
func _sweep_engine(dur: float) -> void:
	var t := 0.0
	while t < dur:
		var k := clampf(t / dur, 0.0, 1.0)
		_audio.call("set_engine", k, k)
		await get_tree().process_frame
		t += get_process_delta_time()
	_audio.call("set_engine", 1.0, 1.0)

func _run_demo() -> void:
	_label("UI click")
	_audio.call("play_click")
	await _wait(0.6)

	_label("UI hover")
	_audio.call("play_hover")
	await _wait(0.6)

	_label("coin / pickup ding")
	_audio.call("play_coin")
	await _wait(0.8)

	_label("cash (cha-ching, shop buy/sell)")
	_audio.call("play_cash")
	await _wait(0.9)

	_label("checkpoint chime (sprint mode)")
	_audio.call("play_checkpoint")
	await _wait(1.1)

	_label("landing thud — light tap (strength 0.15)")
	_audio.call("play_landing", 0.15)
	await _wait(0.8)

	_label("landing thud — hard impact (strength 1.0)")
	_audio.call("play_landing", 1.0)
	await _wait(1.0)

	_label("wreck crunch (car death)")
	_audio.call("play_wreck")
	await _wait(1.3)

	for vk in VEH_KEYS:
		_label("engine sweep: %s  (idle -> full throttle over 3s)" % vk)
		_audio.call("set_vehicle_type", vk)
		_audio.call("set_engine", 0.0, 0.0)
		await _sweep_engine(3.0)
		await _wait(0.5)
		_audio.call("set_engine", 0.0, 0.0)
		await _wait(0.6)

	_label("drift squeal — ramp speed up, hold, release")
	_audio.call("set_vehicle_type", "hotrod")
	_audio.call("start_drift")
	await _sweep_engine(1.2)
	_audio.call("set_engine", 0.85, 0.55)
	await _wait(1.6)
	_audio.call("stop_drift")
	await _wait(1.0)

	_label("boost roar — 2s hold at speed")
	_audio.call("set_engine", 0.6, 1.0)
	_audio.call("start_boost")
	await _wait(2.0)
	_audio.call("stop_boost")
	_audio.call("set_engine", 0.0, 0.0)
	await _wait(1.0)
