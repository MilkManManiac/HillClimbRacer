# Foundation Pass — design (2026-07-03)

## Thesis and provenance

First structural pass on the HC sandbox before feature work (audio, tricks, contraptions).
Source of truth: the 2026-07-03 four-agent audit, every finding re-verified against source
by the coordinator (one auditor claim — `DirAccess.remove_absolute` on `user://` — was
struck after an empirical test on Godot 4.6.3 proved it works). Scope: 7 verified bug
fixes + 3 structural refactors. No behavior changes beyond the named fixes.

Gate (all waves): `bash tests/run_battery.sh` — 5 probes, exits nonzero on any failure.
SmoothProbe thresholds vert rms ≤ 3.0 / pitch_jerk rms ≤ 0.6 (baseline on this machine:
2.70 / 0.51, identical to the Windows baseline). Committed as W0 (b7efb16).

## Constraints / invariants (binding on every lane)

- Analytic ground is sacred: no quantisation in `HCTrack._project_at/_project/ground_info/
  height_at/_carved_height/_base_hill`; the `best_d2 := INF` seed (HCTrack.gd:299) stays.
- Terrain overrides `set()` BEFORE `add_child` (HCMain `_apply_map`).
- Headless probes: `PROCESS_MODE_ALWAYS` + `_begin_game()`.
- Horror-game files off-limits: scripts/{Main,ArcadeCar,Forest,Sky,RoadCourse,Cockpit,
  Hitchhiker}.gd and their tests. (tests/GapTest.* is HC-owned, in scope.)
- GDScript 4, tabs, `##` doc comments, static typing where present. No new scene/asset
  dependencies. Audio calls stay behind `if _audio:`.
- Delegates do NOT commit. Local-only; no remote push.

## W1 — seven bug fixes

**F1. Gap telegraph rewire (the design item).** `HCMain._update_gap_telegraph`
(HCMain.gd:2017–2036) checks `has_method("_gap_for_z")`, which only the deleted-in-W2
legacy terrain has — the "SEND IT! / GO FASTER" advisory has been dead since HCTrack
shipped. `gap_state(pos)` can't replace it directly: it reports the gap zone you are
*inside*, and the telegraph must warn *ahead*.

Fix: add one public method to HCTrack:

```gdscript
## First gap ahead of `pos` within `max_dist` metres of arc-length.
## Returns {} when none. dist = metres from pos to the void lip.
func gap_ahead(pos: Vector3, max_dist: float = 100.0) -> Dictionary
```

Implementation shape: `_project(pos.x, pos.z)` → arc-length `s` and sample `i`; scan
`_gsamp[i .. i + int(max_dist / STEP)]` (bounds-clamped) for the first `gi >= 0` whose
lip (`_gaps[gi].cs - _gaps[gi].vw * 0.5`) is `> s`; return
`{"dist": lip - s, "vw": g.vw}`. Cost: ≤ 25 array reads on top of one `_project` (which
the caller effectively already pays elsewhere per frame — acceptable; do NOT add caching).

`_update_gap_telegraph` then: guard `has_method("gap_ahead")`; empty dict or
`dist > 75.0` → blank text; else keep the existing v_req formula
(`6.0 + vw * 0.9`) and the existing SEND IT / GO FASTER text + colors
(HCMain.gd:2029–2036) driven by `linear_velocity.length()` vs `v_req`.
Remove the dead `_respawning` variable (declared HCMain.gd:220, never set) and its
check while in this function.

**F2. reset_run drift-state.** HCCar.gd:642 `reset_run` — add
`_grip_break = 0.0`, `_steer = 0.0`, `_drift_yaw_cur = 0.0` (verify exact names in
HCCar; audit anchors lines 333–386). Failure today: die mid-drift → respawn with loose
grip, phantom tire smoke, steering twitch.

**F3. Debug-gate the test money button.** HCMain.gd:1455–1462. Wrap creation in
`if OS.is_debug_build():`. `_money_btn` is also referenced in the gamepad focus chain
(HCMain.gd:1590) — every reference must be guarded (`if _money_btn:` or conditional
append) so a release build's focus chain has no null hole. Editor/dev runs keep the
button.

**F4. Sidecar CoM.** HCCar.gd:1820: `center_of_mass = Vector3(shift, -0.4, 0.0)` →
`Vector3(shift, com_height, 0.0)`.

**F5. Remove dead `tippiness`.** Delete the key from all five VEHICLES entries
(HCMain.gd:159/170/181/192/204). HCCar has no such property; the data is a lie.

**F6. AutoDrive map coverage.** tests/AutoDrive.gd:13 hardcodes
`["hills", "canyon", "alpine"]` — replace with `HCMainScript.MAP_KEYS` (the pattern
MapProbe.gd:15 already uses) so midnight and all future maps are covered.

**F7. CREDITS.md CC-BY completeness.** Three committed CC-BY GLBs are uncredited:
`pine_tree_ballentine_ccby.glb`, `pine_tree_dannibittman_ccby.glb`,
`pine_tree_minipoly_ccby.glb`. Verified unused in-game (no `scatter_kinds` or code
reference) → add to the existing "downloaded but not currently used in-game"
parenthetical block, same format (title, author, license, source). Extract author
names from GLB metadata where present (`strings <file> | grep -i -A2 copyright` or
the asset filenames); do not invent source URLs — attribute what is verifiable.

Owned files: `scripts/hc/HCMain.gd`, `scripts/hc/HCCar.gd`, `scripts/hc/HCTrack.gd`,
`tests/AutoDrive.gd`, `CREDITS.md`. Nothing else.

## W2 — delete the legacy terrain (behavior-preserving)

`HCTerrain.gd` (858 lines) is unreachable: `USE_TRACK := true` is a const
(HCMain.gd:11), no scene or test instantiates it except tests/GapTest.gd (stale,
always-exit-0, not in battery).

- Delete `scripts/hc/HCTerrain.gd`, `tests/GapTest.gd`, `tests/GapTest.tscn`.
- HCMain: remove the `HCTerrainScript` preload (line 7), the `USE_TRACK` const, and
  both arms of every `if USE_TRACK else` ternary (keep the HCTrack arm); remove the
  `road_half_width` fallback branches (HCMain.gd:645,708).
- HCCar: remove the legacy `_gap_for_z` fallback path (HCCar.gd:688–692) and the
  `road_center_x` fallback (HCCar.gd:625) — dead under HCTrack.
- Guard policy: `has_method` guards for methods HCTrack ALWAYS provides
  (`ground_info`, `gap_state`, `spawn_pos`, `progress`, `lateral_off`,
  `road_half_here`, `path_ahead`, `reset_pickups`, `gap_ahead`) become direct calls
  — a missing method should be a loud crash, not a silent no-op (that failure mode
  already killed two features). KEEP the duck-typed `terrain` variable itself
  (typed as Node) — formalizing a base class is out of scope.
- `HCPickup` "nitro" kind: leave in place (deferred item; possible future feature).

Owned files: `scripts/hc/HCMain.gd`, `scripts/hc/HCCar.gd`, deletions above.

## W3 — split the god files (behavior-preserving, two parallel lanes)

Mechanics for both: **verbatim function moves + reference rewiring**, not rewrites.
Extracted units are plain `RefCounted` helpers instantiated by the host with an
explicit host reference (`var shop := HCShop.new(self)`) — no new scene nodes, no
autoloads, no signals-for-the-sake-of-signals. State (money, levels, owned, vehicle)
STAYS on the host; the helper reads/writes through the host reference. Public entry
points on the host that other files call (`_show_shop`, etc.) become one-line
delegating stubs so no external call site changes.

**W3a — `scripts/hc/HCShop.gd` out of HCMain** (~800 lines: `_build_shop` through the
cosmetic swatch logic, tabs, focus chains, buy/sell, body-kit cycling, fresh-start
confirm). HCMain keeps: economy math (`_cost`, `_apply_upgrades`), save system, maps,
camera, HUD, sprint. Boundary calls back into HCMain: `_restart`, `_swap_vehicle`,
`_apply_map`, save triggers.

**W3b — out of HCCar:**
- `scripts/hc/HCCarBodyBuilder.gd` (~800 lines): the five `_build_*_body` functions +
  geometry helpers (`_panel`, `_prism`, `_chrome`, `_glass`, `_emit_panel`,
  `_chrome_cyl`, `_tube`, `_weld_node`, fenders/trim/bumpers/grille/lights/mirrors/
  exhausts/windshield/cockpit builders, and the material helpers they use). Interface:
  `build(body_root: Node3D, vehicle_type: String) -> Array[SpotLight3D]` (headlights).
- `scripts/hc/HCCarFX.gd` (~600 lines): dust/ring/tire-smoke/exhaust/damage-smoke/
  backfire/wind-streaks/boost-flames/skid-marks/underglow build + update. Interface:
  explicit state-in calls from HCCar's physics loop (`on_land(impact, air_time)`,
  `set_drifting(...)`, `set_boosting(...)`, `set_health(...)`, `tick(delta, ...)`).
  Physics, suspension, drift model, upgrades-as-physics stay in HCCar.

W3a and W3b touch disjoint files → parallel worktree lanes; coordinator merges.

## Testing strategy

- Per wave: full battery + parse-check each touched/new file. Coordinator re-runs;
  lane claims don't count.
- W1 adds probe coverage implicitly: MapProbe (all-map boot) exercises the telegraph
  path each frame; AutoDrive covers midnight after F6.
- Acceptance (after W3): battery ×5 (any flake = fail), AutoDrive telemetry all 4 maps
  compared against pre-pass numbers, TitleShot + MapShot rendered screenshots
  eyeballed, save/load round-trip via SaveProbe + BodyKitProbe (not in battery but
  both gate-capable — run them at acceptance).
- SmoothProbe numbers must stay at baseline (2.70/0.51); any drift = stop and diagnose.

## Cost basis

Measured: full battery ≈ 2.5 min wall on this machine (5 probes, ~30 s each).
Acceptance ×5 sweep ≈ 13 min. Lane budget: Codex + Cursor subscriptions (flat),
GLM per-token only as third-family fix lane. 3-round cap per review→fix cycle.

## Dependencies

None added. No new assets. No plugin, no framework, no test library.

## Non-goals

Audio revival, trick system, pause menu, per-map sprint constants, VSPEC/VEHICLES
merge, shed-clone script file, nitro pickups, tile-build threading, horror-game
cleanup, export configuration — all logged in DEFERRED.md, untouched here.

## Wave plan / lanes

| Wave | Work | Implement | Review | Fix |
|---|---|---|---|---|
| W0 | Gate hardening | coordinator (done, b7efb16) | — | — |
| W1 | F1–F7 | codex `work` | cursor `safe` | GLM `droid glm work` (if needed) |
| W2 | HCTerrain deletion | cursor `work` | codex `safe` | GLM |
| W3a | HCShop extraction | codex `work` (worktree) | cursor `safe` | GLM |
| W3b | BodyBuilder+FX extraction | cursor `work` (worktree) | codex `safe` | GLM |

Serialized W1 → W2 → W3 (same files touched; extraction last so fixes land once).
Coordinator: merge, gate, riskiest-file read (W1: gap_ahead + telegraph; W2: the
guard-strip diff in HCCar's physics loop; W3: the state-ownership boundary in both
extractions), triage, commits.
