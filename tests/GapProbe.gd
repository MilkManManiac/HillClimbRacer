extends Node
## Hermetic HCTrack gap-ahead probe: no game boot, no title screen.

const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")
const STEP := 4.0

func _ready() -> void:
	var track := HCTrackScript.new()
	track.path_seed = 20260630
	track.noise_seed = 777
	add_child(track)
	await get_tree().process_frame

	var ok := true
	if track._gaps.is_empty():
		_check("gaps built", false, "no gaps")
		get_tree().quit(1)
		return
	_check("gaps built", true, "%d gaps" % track._gaps.size())

	var first: Dictionary = track._gaps[0]
	var lip: float = first.cs - first.vw * 0.5
	var before_s: float = lip - track.gap_ramp_len - STEP * 2.0
	var before := track.gap_ahead(_pos_at_s(track, before_s))
	ok = _expect_gap("before ramp", before, lip - before_s, first.vw) and ok

	var ramp_s: float = lip - STEP
	var ramp := track.gap_ahead(_pos_at_s(track, ramp_s))
	ok = _expect_gap("on ramp pre-lip", ramp, lip - ramp_s, first.vw) and ok

	var past := track.gap_ahead(_pos_at_s(track, lip + STEP))
	var past_ok := past.is_empty() or float(past.vw) > float(first.vw)
	ok = _check("past lip skips current", past_ok, str(past)) and ok

	var end_s: float = float(track._n - 2) * STEP
	var end := track.gap_ahead(_pos_at_s(track, end_s))
	ok = _check("near path end empty", end.is_empty(), str(end)) and ok

	get_tree().quit(0 if ok else 1)

func _expect_gap(label: String, got: Dictionary, want_dist: float, want_vw: float) -> bool:
	var ok := not got.is_empty() and absf(float(got.dist) - want_dist) <= STEP and is_equal_approx(float(got.vw), want_vw)
	return _check(label, ok, "got=%s want_dist=%.2f want_vw=%.2f" % [str(got), want_dist, want_vw])

func _check(label: String, ok: bool, detail: String) -> bool:
	print("[gap] %s %s %s" % [label, "OK" if ok else "FAIL", detail])
	return ok

func _pos_at_s(track: Node, s: float) -> Vector3:
	var fi: float = clampf(s / STEP, 0.0, float(track._n - 1))
	var i := int(fi)
	var t := fi - float(i)
	var j := mini(i + 1, track._n - 1)
	return Vector3(lerpf(track._px[i], track._px[j], t), 0.0, lerpf(track._pz[i], track._pz[j], t))
