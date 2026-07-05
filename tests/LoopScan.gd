extends Node
## THROWAWAY placement sweep: for each candidate loop anchor S, build the gravity
## track (classic generator, detect-only tripwire) and report layout health:
## stunts placed, creep-crossing tripwire, near/far self-clearance, wrap clearance.
## Also prints the legacy configs once to confirm the tripwire is quiet there.

const HCTrackScript := preload("res://scripts/hc/HCTrack.gd")

const LEGACY := {
	"hills": {},
	"canyon": {
		"straight_bias": 0.22, "max_turn_deg": 150.0, "turn_radius_min": 26.0, "turn_radius_max": 60.0,
		"road_half": 20.0, "road_half_turn": 32.0, "hill_amp": 2.5, "noise_frequency": 0.004,
		"gap_start": 9.9e8, "path_seed": 424242, "noise_seed": 99,
	},
	"alpine": {
		"hill_amp": 14.0, "straight_bias": 0.7, "turn_radius_min": 50.0, "turn_radius_max": 95.0,
		"gap_start": 340.0, "gap_spacing": 280.0, "gap_ramp_rise": 6.0, "gap_land_len": 75.0,
		"gap_base_width": 24.0, "gap_grow": 12.0, "noise_frequency": 0.0034,
		"path_seed": 1337, "noise_seed": 2026,
	},
	"midnight": {
		"straight_bias": 0.45, "turn_radius_min": 34.0, "turn_radius_max": 70.0,
		"road_half": 19.0, "hill_amp": 5.0, "noise_frequency": 0.003,
		"gap_start": 500.0, "gap_spacing": 380.0,
		"path_seed": 20261111, "noise_seed": 611,
	},
	"gravity_old": {
		"stunts": "overpass:650,corkscrew:1500:2,overpass:2900,corkscrew:3900:1",
		"straight_bias": 0.6, "turn_radius_min": 40.0, "turn_radius_max": 80.0,
		"road_half": 18.0, "road_half_turn": 26.0,
		"hill_amp": 5.0, "noise_frequency": 0.0024,
		"gap_start": 5600.0, "gap_spacing": 420.0,
		"path_seed": 777333, "noise_seed": 424,
	},
}

const LOOP_S := [420, 440, 460, 480, 500, 530, 560, 2450, 4900, 5000]

func _ready() -> void:
	for name in LEGACY:
		_report(name, LEGACY[name], -1)
	for s in LOOP_S:
		var cfg: Dictionary = (LEGACY["gravity_old"] as Dictionary).duplicate()
		cfg["stunts"] = "loop:%d,overpass:650,corkscrew:1500:2,overpass:2900,corkscrew:3900:1" % s
		_report("loop:%d" % s, cfg, s)
	get_tree().quit(0)

func _report(name: String, cfg: Dictionary, _s: int) -> void:
	var trk := Node3D.new()
	trk.set_script(HCTrackScript)
	for k in cfg:
		trk.set(k, cfg[k])
	add_child(trk)
	var rep: Dictionary = trk.call("stunt_report")
	var wrap := -1.0
	for f in rep.features:
		if bool((f as Dictionary).get("loop", false)):
			wrap = float((f as Dictionary).wrapclear)
	var near := _self_clearance(trk, 184.0)
	var far := _self_clearance(trk, 480.0)
	print("[scan] %-12s placed=%d/%d xing=%d near=%.1f far=%.1f wrap=%.1f" %
		[name, int(rep.placed), int(rep.planned), int(rep.creep_xing), near, far, wrap])
	trk.queue_free()

## Min centre-line distance between samples at least `gap_m` apart in s that are
## NOT inside stunt spans (stunts self-cross on purpose, vertically separated).
func _self_clearance(trk: Node3D, gap_m: float) -> float:
	var rep: Dictionary = trk.call("stunt_report")
	var spans: Array = []
	for f in rep.features:
		spans.append(Vector2(float((f as Dictionary).s0) - 60.0, float((f as Dictionary).s1) + 60.0))
	var worst := 1e9
	var sa := 0.0
	while sa < 6000.0:
		if _in_spans(sa, spans):
			sa += 8.0
			continue
		var pa: Vector3 = trk.call("point_at_s", sa)
		var sb := sa + gap_m
		while sb < 6000.0:
			if _in_spans(sb, spans):
				sb += 8.0
				continue
			var pb: Vector3 = trk.call("point_at_s", sb)
			var d := Vector2(pa.x - pb.x, pa.z - pb.z).length()
			worst = minf(worst, d)
			sb += maxf(8.0, d - 90.0)   # skip ahead while far apart (cheap sweep)
		sa += 8.0
	return worst

func _in_spans(s: float, spans: Array) -> bool:
	for sp in spans:
		if s > (sp as Vector2).x and s < (sp as Vector2).y:
			return true
	return false
