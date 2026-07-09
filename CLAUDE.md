# Hill Climb Racer — working rules for Claude

The active game is the **Hill Climb sandbox**: `scenes/HillClimb.tscn` → `scripts/hc/*`.
Everything else in `scripts/` (Main, ArcadeCar, Forest, Sky, RoadCourse, Cockpit,
Hitchhiker…) belongs to a separate horror-game prototype sharing the project — leave it
alone unless asked. Read `HANDOFF.md` for vision, current state, and the roadmap.

## Godot (not on PATH)

- GUI: `C:\Users\weshu\Tools\Godot\Godot_v4.6.3-stable_win64.exe --path .`
- Console (headless/CI): `C:\Users\weshu\Tools\Godot\Godot_v4.6.3-stable_win64_console.exe`
- Parse-check: `<console> --headless --path . --check-only --script scripts/hc/HCCar.gd`
- Boot smoke: `<console> --headless --path . --quit-after 200`

**Fresh machine?** If the paths above don't exist: download **Godot 4.6.x stable**
(standard build, not .NET) from godotengine.org, use the `_console` executable for all
headless commands (on Linux/mac the single binary + `--headless` works the same), and
substitute your path everywhere `<console>` appears. The project has no other
dependencies — all assets are in `assets/`, everything else is procedural. If this
arrived as a zip (no `.git`), run `git init && git add -A && git commit -m "import HC v3"`
first so you can checkpoint and diff your own work.

## Verification battery — run after every meaningful change

```
<console> --headless --path . tests/SmoothProbe.tscn    # REQUIRED: vert rms ≤ 3.6, pitch_jerk rms ≤ 0.6
<console> --headless --path . tests/HCDrive.tscn        # full-throttle drive; prints [hc] line
<console> --headless --path . tests/MapProbe.tscn       # all three maps boot + drive
<console> --headless --path . tests/TitleFlowProbe.tscn # title → map click → START → alive
<console> --headless --path . tests/CarBodyProbe.tscn   # GLB car bodies load/scale
<console> --headless --path . tests/TrialProbe.tscn     # time-trial: timer/record/ghost/medals
<console> --headless --path . tests/AudioProbe.tscn     # synth buffers non-silent, non-clipping
<console> --headless --path . tests/StuntProbe.tscn     # overpass/corkscrew surfaces + canyon pop regression
<console> --headless --path . tests/LoopProbe.tscn      # vertical loop: fast car inverts, slow car detaches
<console> --headless --path . tests/ComboProbe.tscn     # combo v2: chain math, bank/drop, near-miss, HUD
```
When editing a map's `stunts` string, run `tests/LoopScan.tscn` first — it sweeps
anchor placements against generator collisions (the `creep_xing` tripwire).

Baseline SmoothProbe numbers (HC v7.5): `vert_accel rms=2.78` (worst ~26), `pitch_jerk
rms=0.17` — both dominated by the one-time spawn drop; healthy mid-run windows print
0.00. Excluded from the metric: gap/ramp zones AND a short settle window after real-jump
touchdowns (launches and their landings are intentional impacts, not road roughness).
Gates: vert rms ≤ 3.0, pitch_jerk rms ≤ 0.6 — if either rises, the driving got rougher;
find out why before proceeding.

For **visual** changes, don't trust "parses + boots": capture a rendered screenshot with the
`tests/TitleShot.gd` pattern (runs the real renderer in a brief window, saves a PNG, quits)
and actually look at it. Delete the PNG afterwards.

## Hard invariants (learned the expensive way)

1. **The car rides analytic ground, not collision meshes.** `HCCar._suspend_analytic`
   queries `HCTrack.ground_info(x,z)` (smooth height + normal from continuous segment
   projection). The trimesh tiles exist only for the camera occlusion ray and future props.
   Do not reintroduce raycast wheels, and do not quantise anything in
   `HCTrack._project_at / _project / ground_info / height_at / _carved_height / _base_hill`.
   In `_project_at`, the fallback seed **must stay `INF`** — seeding it with the sample's
   lateral distance ties with segment candidates on straights and silently reverts to a
   4 m height staircase (the original "bumpy driving" bug).
2. **The title screen pauses the SceneTree.** Any headless test that drives the game must
   set `process_mode = Node.PROCESS_MODE_ALWAYS` and call `HCMain._begin_game()`, or it
   hangs forever.
3. **Terrain overrides must land before `add_child`.** HCTrack generates its road in
   `_ready`; maps work by `set_script` → `_terrain.set(k, v)` → `add_child` (see
   `HCMain._apply_map`). Same for `_car.set("vehicle_type", …)`.
4. **UI must fit 1280×720** (`window/stretch/mode = viewport`). The START-button-off-screen
   bug came from a fixed-size centered panel growing past the window. Prefer adaptive
   containers (CenterContainer + ScrollContainer) over hand-placed offsets.
5. **HCCar/HCMain talk to the terrain by duck-typing** (`terrain.call(...)` guarded by
   `has_method`). HCTrack and legacy HCTerrain implement *different* method sets; if you
   add a terrain method the car/camera depends on, implement it on HCTrack (the active one,
   `USE_TRACK = true`) — a `has_method` guard will silently no-op otherwise (this killed
   the camera look-ahead for a whole version).

## Style

GDScript 4, **tabs**, `##` doc comments; inline comments explain **why**, not what.
Static typing where the codebase already does it. Keep procedural building (meshes,
materials, UI) in code — no new scene/asset dependencies unless there's a real asset
(GLBs live in `assets/`, loaded at runtime via `scripts/GlbUtil.gd`; car bodies via
`scripts/hc/HCCarBody.gd`). Record licenses in `CREDITS.md` (CC-BY needs attribution).

Audio is ON as of HC v6 — the procedural HCAudio synth (per-vehicle engine, drift/boost
loops, one-shot SFX; `master_volume` persisted, set from the pause menu). Keep every call
guarded by `if _audio:` — nulling `_audio` in `HCMain._setup_terrain_and_car` silences
the whole game if the owner rejects the mix. Owner audition still pending
(`tests/AudioDemo.tscn`, run WITHOUT `--headless`, ~28 s labelled tour).

## Fan-out

When work splits into independent streams, fan out sonnet subagents — but partition by
FILE (one owner per file at a time) and give each agent the verification battery above
with the SmoothProbe thresholds as a hard gate.
