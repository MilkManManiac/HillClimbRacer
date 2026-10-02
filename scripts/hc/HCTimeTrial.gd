extends RefCounted
## Pure rules for the weekly time trial: which track is live, the fixed car + setup
## everyone drives on it, how long it is, where the splits sit, and the medal times.
## HCMain owns all the LIVE state (clock, ghost, best-time persistence) — this class
## only answers static questions, so the numbers live in one place. Everything here
## is a static func; never instantiate it.
##
## A trial is deliberately NOT "your garage car on any map" any more: times are only
## comparable between players when the car and its setup are identical, so each track
## names its own ride and upgrade levels and the garage is ignored while trial mode
## is on. One track for now (owner call 2026-10-01: "pick one map for now and fix
## others as needed") — add a row to TRACKS + MEDALS to open another.

## Per-track spec. "car" is a HCMain.VEHICLES key; "setup" maps upgrade keys to fixed
## levels (anything missing is level 0 — a bone-stock car); "length" is metres of road
## between the start line and the finish line.
## Canyon runs engine 2 (72 m/s cap) on purpose: a stock sports car tops out at 40 m/s
## and the bot held that flat through every corner, so there was no time to find. At 72
## the corners cost speed and the line matters. 2800 m puts a lap at 45-60 s.
const TRACKS := {
	"canyon": {"week": 1, "car": "sports", "length": 2800.0, "setup": {"engine": 2}},
}
## The track the title screen offers in trial mode.
const WEEKLY := "canyon"

## The clock starts when the car crosses a line this far past the spawn point (not at
## reset), so the spawn drop and the first wheel-settle are never part of anyone's time.
const START_RUNUP := 24.0

## Fractions of the track length where a split fires. The call-out is the GAP to your
## best run (and to an imported rival) at that same point, not the elapsed time.
const SPLIT_FRACS: Array[float] = [0.2, 0.4, 0.6, 0.8]

## Medal time thresholds (seconds; lower = better). Bot-calibrated 2026-10-01 with
## tests/TrialBot: the centre-line bot holds full throttle and laps canyon in 53.3 s
## (52.6 m/s average against the tune's 72 m/s cap — the gap is what a good line is
## worth). Silver ~ the bot, gold needs corner speed the bot never finds, bronze is a
## clean lap with lifts. A human pass is still wanted.
const MEDALS := {
	"canyon": {"gold": 50.0, "silver": 54.0, "bronze": 65.0},
}

## True if `map_key` has a trial track defined.
static func supports(map_key: String) -> bool:
	return TRACKS.has(map_key)

static func car_for(map_key: String) -> String:
	return str(TRACKS.get(map_key, {}).get("car", ""))

static func setup_for(map_key: String) -> Dictionary:
	return TRACKS.get(map_key, {}).get("setup", {})

static func week_of(map_key: String) -> int:
	return int(TRACKS.get(map_key, {}).get("week", 0))

## Metres from the start line to the finish line.
static func length(map_key: String) -> float:
	return float(TRACKS.get(map_key, {}).get("length", 1000.0))

## Split points as metres PAST THE START LINE, ascending.
static func split_offsets(map_key: String) -> Array[float]:
	var l := length(map_key)
	var out: Array[float] = []
	for frac in SPLIT_FRACS:
		out.append(l * frac)
	return out

## "gold"/"silver"/"bronze"/"" (no medal) for a finish time on `map_key`.
static func medal_for(map_key: String, time_s: float) -> String:
	var m: Dictionary = MEDALS.get(map_key, {})
	if m.is_empty():
		return ""
	if time_s <= float(m.get("gold", 0.0)):
		return "gold"
	if time_s <= float(m.get("silver", 0.0)):
		return "silver"
	if time_s <= float(m.get("bronze", 0.0)):
		return "bronze"
	return ""

static func medal_color(medal: String) -> Color:
	match medal:
		"gold":
			return Color(1.0, 0.84, 0.2)
		"silver":
			return Color(0.80, 0.83, 0.88)
		"bronze":
			return Color(0.80, 0.5, 0.25)
		_:
			return Color(0.62, 0.64, 0.7)

## Plain-word medal tag for labels ("GOLD"), "" for no medal.
static func medal_glyph(medal: String) -> String:
	return medal.to_upper()

## Format a seconds value as "M:SS.dd" (or "SS.dd" under a minute) for HUD/labels.
static func format_time(t: float) -> String:
	if t < 0.0 or not is_finite(t):
		return "--:--"
	var whole := int(t)
	var cs := int(round((t - float(whole)) * 100.0))
	if cs >= 100:
		cs -= 100
		whole += 1
	var m := whole / 60
	var s := whole % 60
	if m > 0:
		return "%d:%02d.%02d" % [m, s, cs]
	return "%d.%02d" % [s, cs]

## Signed gap for split/finish call-outs: "-0.42" (ahead) / "+1.10" (behind).
static func format_delta(d: float) -> String:
	return ("-" if d < 0.0 else "+") + "%.2f" % absf(d)

## One line summarising the medal ladder for a map — the "what am I chasing" readout.
static func ladder_text(map_key: String) -> String:
	var m: Dictionary = MEDALS.get(map_key, {})
	if m.is_empty():
		return ""
	return "gold %s   silver %s   bronze %s" % [format_time(float(m.get("gold", 0.0))), format_time(float(m.get("silver", 0.0))), format_time(float(m.get("bronze", 0.0)))]
