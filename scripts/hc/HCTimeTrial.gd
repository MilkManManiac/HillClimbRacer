extends RefCounted
## Pure rules for time-trial mode: which maps support it, the finish distance, split
## call-out points, and the bronze/silver/gold time thresholds. HCMain owns all the
## LIVE state (elapsed time, whether a run is active, best-time persistence) — this
## class only answers static questions, so the numbers live in one place instead of
## scattered across HCMain. Everything here is a static func; never instantiate it.
##
## Sprint-mode maps (currently canyon) are NOT in FINISH_M — canyon keeps its own
## checkpoint/countdown sprint untouched, per the standing rule "don't break it".
## select_map()/HCMain picks trial vs sprint vs classic per-map; see HCMain._reset_run_mode.

## Finish line, in metres of HCCar.distance travelled. Picked per map to suit its
## character (alpine's big-air terrain is slower going, so a shorter line keeps
## trial runs roughly the same LENGTH in seconds across maps).
const FINISH_M := {
	"hills": 1000.0,
	"alpine": 900.0,
	"midnight": 1000.0,
	"gravity": 1800.0,   # past the first overpass (650) AND the 2-coil corkscrew (~1500-1700)
	"dunes": 1100.0,     # fast flowing rollers — a touch longer than hills at higher pace
}

## Fractions of the finish distance where a split call-out fires (elapsed time only —
## no per-split best-time delta yet; that needs recording split times into the save,
## a natural follow-up once ghost data proves out the storage pattern).
const SPLIT_FRACS: Array[float] = [0.25, 0.5, 0.75]

## Medal time thresholds (seconds; lower = better). Calibrated against the AutoDrive
## bot (2026-07-04, STOCK minivan): hills pace 14.8 m/s (712 m in 48 s, then fuel-dead)
## -> 1000 m at bot pace ~= 68 s. Ladder intent: bronze = any clean finish (well under
## bot pace, needs fuel pickups or one tank upgrade), silver ~= stock-bot pace, gold =
## a faster/upgraded ride. Alpine's line is shorter but jump-heavy (the no-air-control
## bot dies at 346 m there), so its ladder is looser per metre. Only these numbers need
## editing to re-tune; nothing else reads them.
const MEDALS := {
	"hills":    {"gold": 55.0, "silver": 70.0, "bronze": 100.0},
	"alpine":   {"gold": 65.0, "silver": 88.0, "bronze": 125.0},
	"midnight": {"gold": 60.0, "silver": 80.0, "bronze": 112.0},
	# gravity: longer line (1800 m) but the corkscrew descent is fast once learned;
	# NOT bot-calibrated (the bot can't judge stunt pacing) — human tuning pass wanted
	"gravity":  {"gold": 95.0, "silver": 125.0, "bronze": 170.0},
	# dunes: bot-calibrated 2026-07-09 — stock minivan 14.1 m/s over the rollers
	# (1100 m ≈ 78 s at bot pace); sports bot cruises it at ~40 m/s (~28 s), so gold
	# demands a fast ride, silver ≈ stock-bot pace. Human calibration pass wanted.
	"dunes":    {"gold": 45.0, "silver": 80.0, "bronze": 115.0},
}

const MEDAL_EMOJI := {"gold": "🥇", "silver": "🥈", "bronze": "🥉"}

## True if `map_key` has a time-trial finish line defined.
static func supports(map_key: String) -> bool:
	return FINISH_M.has(map_key)

static func finish_distance(map_key: String) -> float:
	return float(FINISH_M.get(map_key, 1000.0))

## Absolute split distances (metres) for a map, in ascending order.
static func split_distances(map_key: String) -> Array[float]:
	var f := finish_distance(map_key)
	var out: Array[float] = []
	for frac in SPLIT_FRACS:
		out.append(f * frac)
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

static func medal_glyph(medal: String) -> String:
	return str(MEDAL_EMOJI.get(medal, ""))

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

## One line summarising the medal ladder for a map, e.g. "🥇55s 🥈75s 🥉100s" — used as
## a compact "what am I chasing" readout under the live timer.
static func ladder_text(map_key: String) -> String:
	var m: Dictionary = MEDALS.get(map_key, {})
	if m.is_empty():
		return ""
	return "🥇%ds  🥈%ds  🥉%ds" % [int(m.get("gold", 0.0)), int(m.get("silver", 0.0)), int(m.get("bronze", 0.0))]
