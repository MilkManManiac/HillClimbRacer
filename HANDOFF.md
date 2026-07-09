# HANDOFF — make this an amazing game

Read `CLAUDE.md` first for the working rules, verification battery, and hard invariants.
This file is the vision, the current state, and the roadmap. You have latitude: the owner
trusts the direction below — build, verify, iterate. Don't ask permission between steps;
do keep the test battery green and commit in coherent checkpoints.

## The vision

A **juicy, wacky arcade hill-climb sandbox** — Hill Climb Racing's "one more run" loop
with real 3-D drifting, big air, and toys. The fantasy: pick a ridiculous vehicle, tear
down an endless scenic road, drift the sweepers, launch the gaps, watch your car visibly
grow rockets/wings/fat wheels as you spend your run money, and immediately go again.

Design pillars (in priority order):
1. **Feel is sacred.** Extremely smooth driving — zero mechanical jank, ever. Every
   vehicle handles distinctly (the F1 runs away from the van; the monster truck is a
   top-heavy meme). Drifting is intentional and rewarding.
2. **Juice everywhere.** Landings kick the camera, smoke pours, coins burst, tricks pop
   score text. If something happens, the player should feel it.
3. **Upgrades you can SEE.** Every purchase changes the car's body, not just numbers.
4. **Maps are moods.** Each map is a different game flavor: classic endless hills,
   all-drift sprint against the clock, big-air snow ridge. More flavors welcome.
5. **Session-friendly.** Death → shop → retry in seconds. No friction.

## Update (2026-07-09, eighth pass — "HC v7.6")

- **Trick & combo system v2 shipped** (roadmap item 4): tricks (air/flips, drift
  segments, near-misses, perfect landings) chain into an unbanked pot with an
  escalating multiplier (+x0.5/trick, cap x5) that BANKS on clean settle and DROPS on
  wreck/flat-slam. Combo HUD (pot + mult + grace drain bar, top-right), escalating
  combo/bank/lost synth one-shots. `tests/ComboProbe.tscn` (19 checks) is in the
  battery; `tests/ComboShot.tscn` renders the HUD for eyeballing. Deliberately
  skipped: slow-mo apex beat (time-scale is the riskiest juice — feel is sacred).
- **Canyon creep_xing FIXED** (was detect-only): root cause — `_next_segment`'s
  boxed-in fallback creeps a blind straight; on canyon seed it chain-tunneled two
  branches to 18.9 m apart near s≈27.5 km. Fix: `_escape_turn` sweeps deterministic
  sharper turns only when the tripwire's own 55 m danger gate fires — zero RNG
  consumed, first 6 km of canyon (the feel reference) byte-identical. LoopScan: 7→0.
- **Loop detach containment** (v7.3 known cosmetic): mid-loop detach now rides a
  one-sided analytic wall rail down the INSIDE of the ring (no more mesh clipping);
  sub-3 m/s crawlers get a gentle lip bumper and can't nose through the mouth.
  LoopProbe grew phases C (fall containment) and D (crawler pin).
- Battery is now 10 probes (ComboProbe added). Baselines unchanged: SmoothProbe
  2.78/0.17, StuntProbe rms 1.92 lifts=0.
- In flight: balloon-float contraption prototype (roadmap item 8, first absurd part).

## Update (2026-07-04, fifth pass — "HC v7")

- **The road can now cross OVER itself.** Multi-surface analytic ground: `ground_info_y /
  height_at_y (x, z, y_hint)` resolve stacked surfaces with a continuous asymmetric blend
  (surfaces above a querier decay much faster than below — the anti-runaway rule).
  Stunts are per-map export strings (`stunts = "overpass:650,corkscrew:1500:2,…"`), pure
  C1 analytic profiles; bridge decks get real meshes/undersides/partner-tile streaming.
- **POP/HOP BUG FIXED** (owner-reported, twice-survived): root cause was nearest-sample
  projection snapping between overlapping road branches (canyon: road_half_turn 32 >
  turn_radius_min 26). Fix = build-time overlap height reconciliation (cosine-windowed
  patches) + the query-time blend + stateful branch hints in HCCar. Canyon wide-weave
  regression in `tests/StuntProbe.tscn`: worst step 0.171 m, zero anti-tunnel lifts
  (new `HCCar.tunnel_lifts` counter).
- **Alpine trees-on-road FIXED**: scatter + chevrons now reject positions claimed by any
  other road branch (`_claimed_by_other`), MapShot-verified on alpine/canyon.
- **5th map: Gravity Works** (gold accent) — 2 overpasses + 2 banked corkscrews (13°,
  constant-pitch helix, suspension rides the banking with zero car changes), trial line
  at 1800 m (medals NOT bot-calibrated — human pass wanted, like all trial medals).
- Full vertical loops: not attempted (deliberate) — needs an opt-in spline-adherence
  "loop zone" in HCCar; the branch-candidate machinery is the foundation. Design sketch
  in the 2026-07-04 loop-agent report (session transcript).

## Update (2026-07-05, seventh pass — "HC v7.4-7.5")

- **Ghost sharing (multiplayer stage 1)**: export best trial ghost to a checksummed
  `.hcghost` file, import a friend's as a red RIVAL ghost (name label, races alongside
  your blue PB simultaneously, persisted). GHOSTS row on the title screen.
- **Fast-car jump fairness (owner's playtest ask)**: gaps are now scheduled INSIDE path
  generation — each claims a dead-straight window covering ramp + void + speed-aware
  landing catch + worst-case-overshoot reserve (~282 m for a capped F1), so the road
  can never bend away under a max-speed flight. Airborne lateral guidance nudges toward
  the centerline (hard-capped 1.5 m/s², fades under active steering — imperceptible).
  Fixed a latent landing-platform bug: unclamped `_ground_from` gradient at void edges
  faked "grounded" for cars 6 m in the air; land rises now physically capped.
  JumpProbe: maxed F1 at 95 m/s, 7/7 gaps on-road on hills AND alpine, zero wrecks.
- **Hills opener softened** (rise 5 / width 15 / grow 8): the new scheduling surfaced
  the first jump inside a stock tank's range and a stock van couldn't clear 34 m; bot
  now reaches 804 m (fuel death, hp 95) vs the old 712 m baseline.
- SmoothProbe fixed (quit condition could be skipped inside gap zones; landings from
  real jumps now excluded like the launches that cause them) — new baseline 2.78/0.17.

## Update (2026-07-05, sixth pass — "HC v7.1-7.3")

- **FULL VERTICAL LOOP shipped** (`loop:S[:R]` stunt token; on Gravity Works at s=2450).
  The ribbon is an analytic vertical circle with a 13 m corkscrew shift — NOT a
  heightfield surface; the flat road continues underneath. HCCar rides it via a
  loop-zone state machine (mount at the mouth, per-wheel radial springs + rail
  constraint, feed-forward spin) and detaches ballistically below adhesion speed —
  slow cars stall past ~100° and fall back inside the ring. "LOOP-DE-LOOP! +500" on
  completion. `tests/LoopProbe.tscn` guards both paths; `tests/LoopScan.tscn` sweeps
  stunt-string placements against generator collisions (`creep_xing` tripwire — fires
  7x on canyon past ~6 km, pre-existing, detect-only, future pass).
- **Upgrade bolt-on visuals REMOVED per owner** (stats stay): engine block, roll cage,
  wheel widening (tyre width frozen; Bigger Wheels grows radius only). Round-2 body
  detail on all 5 rides: per-vehicle exhausts, brake rotors/calipers, interiors,
  antennas, winch/hitch/tow hooks. Shop copy updated.
- **Distant scenery on all 5 maps** (HCScenery.gd): fog-tinted silhouette rings that
  re-centre on the car — ridges/mesas/snow peaks/night skyline with window dots/
  industrial cranes+stacks with beacons. Per-map fog/sun tuning.
- Known cosmetic: a mid-loop detach can clip ramp meshes on the way down; sub-3 m/s
  crawlers can nose through the loop mouth (no collision by design, mask 2).

## Update (2026-07-04, fourth pass — "HC v6")

- **Owner playtested the maps (finally!)**: Sunset Canyon APPROVED — favorite by far,
  "challenging but super fun" with fast cars; its tuning is the feel reference. Midnight
  Run: fun. Alpine: trees spawn ON the road (fix in flight). The **pop/hop bug survived
  the v5 fix** — root-caused to nearest-segment projection branch flips where the track
  self-approaches (canyon: road_half_turn 32 > turn_radius_min 26; the car collides with
  nothing physically — HCCar mask=2 vs tiles layer 1), fix in flight with the loop-track
  work. Fast cars overshoot jumps into curves / slide off landings — next tuning target.
- **UI overhaul**: rebuilt title (logo, CLASSIC/TIME TRIAL toggle, per-map accent cards
  with live stats, vehicle strip with lock states), ESC pause menu (resume/restart/menu/
  fullscreen/volume), styled shop/wreck, all adaptive-container 720p-safe.
- **Time-trial mode**: per-map finish lines (HCTimeTrial.FINISH_M), best times keyed
  map|vehicle in the save, bronze/silver/gold medals (bot-calibrated), 20 Hz **ghost
  record/playback** (HCGhost.gd, versioned float-array format — deliberately the seed
  for async multiplayer). Canyon's sprint mode is untouched; trial composes with the
  death→shop loop. `tests/TrialProbe.tscn` (22 checks) guards all of it.
- **Audio is ON**: HCAudio rewritten — per-vehicle engine synth (van rumble → F1 scream),
  drift squeal, boost roar, impact-scaled landing thuds, coin/cash/checkpoint/wreck/UI
  one-shots, master volume from the pause menu. All calls stay `if _audio:` guarded;
  owner audition pending (`tests/AudioDemo.tscn`).
- **Multiplayer researched** (`docs/MULTIPLAYER.md`): recommended path is async — ghost
  files → online leaderboard + ghost download (Cloudflare Worker or Talo) → realtime
  non-collided ghost-cars (ENet). Collided racing: rejected (feel risk, determinism).
- In flight: loops/corkscrew/over-under track tech + showcase map (multi-surface ground
  queries with continuity — same machinery fixes the pop bug and alpine trees).

## Update (2026-07-03, third pass — "HC v5")

- **Random pop/hop bug fixed** (anti-tunnel floor now per-corner with a 0.35 m dead-band);
  smoothness baseline improved — gates are now vert rms ≤ 3.0 / jerk ≤ 0.6 (see CLAUDE.md).
- **Clean-landing math**: damage vs the surface NORMAL, flat-landing vs the slope, and a
  ski-jump landing profile (steepest at the lip, easing to grade, longer catch on wider
  gaps). Riding a landing downslope is free at any speed — bot finishes hills at ~96 hp.
- **All 5 procedural bodies detailed** (seams/lights/mirrors/plates + per-ride character)
  and every car has real SpotLight3D headlights behind `set_headlights(on)`.
- **4th map: Midnight Run** — neon night cruise (per-map `night: true` flag drives
  headlights + a night env branch in `_tune_arcade_environment`). Map switches now
  correctly re-apply sky colors (was a latent bug).
- Owner has still not play-approved canyon/alpine/midnight — that's the standing ask.
  Audio remains the top roadmap item after that.

## Update (2026-07-03, second pass — "HC v4")

Since the list below was written, these shipped and verified:
- **Persistence**: money/upgrades/vehicles/cosmetics/map/best-distances/body-kits save to
  `user://hc_save.json` (disabled under headless so probes stay hermetic).
- **GLB body kits, end-to-end**: Garage tab picker cycles any .glb in assets/car/ onto the
  active ride; wheel stance auto-fits to the model's named wheels; AI-glossy materials
  auto-matted; procedural fallback on bad files. (`HCCar._build_glb_body`, `tests/BodyKitProbe`.)
- **THE COLOR FIX**: ground vertex colors were rendering several stops too bright —
  `vertex_color_is_srgb` was missing on the road/rail materials. The entire art direction
  was hiding behind that flag. Road markings are now real overlay-strip geometry
  (`_build_lines`) instead of smeared vertex paint. If you add a vertex-colored
  material, SET `vertex_color_is_srgb = true`.
- **Auto-driver bot** (`tests/AutoDrive.tscn`): plays all 3 maps unattended, reports
  distance/fuel/hp/cause-of-death. Use it to validate any tuning change.
- **Bot-driven tuning**: sprint checkpoints now REFUEL (+40% tank) and PAY (escalating cash)
  — a stock van chains them (992 m vs 698 m before); alpine's first jumps softened
  (start 340 m, rise 6.0, width 24) but a no-air-control bot still dies there — HUMAN
  playtest still needed; per-vehicle `speed_cap` ends the maxed-F1 ~184 m/s runaway.
- **Damage juice**: body panels visibly fly off at 70/40/20% health (procedural bodies
  only; restored on retry). **Chevron warning signs** on the outside of bends.
- Visual harnesses: `tests/KitShot.tscn` / `tests/MapShot.tscn` render real-camera PNGs
  (run WITHOUT --headless). Probes that boot the game must `set("save_enabled", false)`
  unless testing saves.

Roadmap deltas: items 2 (GLB garage) and 5 (persistence) are DONE; item 1 is bot-tuned but
awaits the owner's play-approval; **item 3 (audio) is now the top priority**, then 4
(tricks/combo), 6 (pause/settings), 7 (world variety), 8 (contraptions).

## Where it stands today (2026-07-03, first pass)

Shipped and verified (all tests green — see CLAUDE.md battery):
- **Buttery driving**: analytic-ground suspension (no trimesh contact for wheels), fixed
  the 4 m quantisation sawtooth, ramp launches now smooth and consistent. SmoothProbe
  guards this numerically.
- **Look & feel pass**: fixed warm-afternoon lighting (ACES, color grade, depth fog),
  roadside tree/rock scatter, road edge lines + surface variation, guardrails with posts
  and emissive band, impact-scaled landing dust + ring puff, speed-scaled drift smoke off
  the real wheel positions, boost flame cores + light flicker, speed wind streaks,
  bobbing pickups with collect bursts, camera corner look-ahead on the winding track.
- **Maps system**: 3 maps in `HCMain.MAPS` (Rolling Hills / Sunset Canyon drift-sprint
  with countdown+checkpoints / Alpine Ridge big-air), title-screen selector + shop
  switcher, per-map palette/seed/gap/scatter/sky overrides on HCTrack exports.
  *The owner has NOT play-approved the two new maps yet — they're built and boot-tested,
  treat their tuning as a draft.*
- **GLB car-body pipeline**: `scripts/hc/HCCarBody.gd` + probe; loads/auto-scales any
  .glb, hides named wheel nodes. `assets/car/README.md` documents the asset spec (the
  owner is collecting car models). NOT yet wired into HCCar.

Architecture in one breath: `HCMain.gd` (~1500 ln — world setup, camera, HUD, shop,
economy, maps, sprint mode) + `HCCar.gd` (~2000 ln — physics core, procedural bodies per
vehicle, upgrade visuals, FX) + `HCTrack.gd` (~900 ln — deterministic winding road,
streamed tiles, gaps, pickups, scatter, analytic ground API) + `HCPickup.gd`, `HCAudio.gd`
(dormant), `HCCarBody.gd` (unwired). A detailed structural review (including suggested
file splits and the terrain interface table) lives in the project memory of the previous
session; the code comments are thorough — read them.

## Roadmap — in rough priority order

Work in passes; after each pass run the battery, screenshot what changed, commit.

1. **Playtest-tune the two new maps.** Drive each (GUI or via probes + screenshots).
   Canyon: corner rhythm should chain drifts; sprint timer should feel tight but fair
   (tune 40 s / +15 s / 350 m). Alpine: jumps should feel huge but landable with the
   downslope landings. Adjust palettes if they read flat. Consider per-map fuel/economy
   multipliers so fast cars shine in canyon.
2. **Wire GLB bodies into HCCar as garage cosmetics.** Use HCCarBody. Suggested shape: a
   per-vehicle optional `body_glb` (or a cosmetics shop entry "Body Kit") that swaps the
   procedural `_body` for the loaded model, keeps physics wheels/springs/upgrade bolt-ons.
   The 3 Kenney models are ready; 3 CC-BY models have baked-in wheels (hide fails
   gracefully — acceptable). Keep the procedural bodies as the default look.
3. **Audio pass.** HCAudio (procedural synth) exists but is disabled. Either revive it
   behind a volume setting or build a small SFX set: engine pitch vs speed, drift squeal,
   landing thump, coin ding, boost roar, UI clicks. Owner may source better samples later —
   keep it swappable (one function per event, `if _audio:` guards stay).
4. **Trick & combo system v2.** Flips/air already score; add: drift-chain multipliers,
   near-miss (rails/props at speed), perfect-landing bonus, a combo meter HUD that banks
   on landing. Slow-mo beat (0.6×, ~0.5 s) at big-jump apex if it doesn't hurt feel.
5. **Persistence.** Save money/upgrades/best-distance/selected map+vehicle to
   `user://save.json` (load on boot, save on death/purchase). Huge session-quality win.
6. **Pause menu + settings.** ESC pause (the tree-pause pattern exists), resume/restart/
   quit, volume sliders (when audio lands), a fullscreen toggle.
7. **More world variety along a run**: distant silhouette ridgelines, occasional set
   dressing (signs from `assets/signs/`, the odd billboard), weather/time variants per
   map (the Sky rig supports time_of_day). Cheap, high-read.
8. **Stretch — the contraption spirit**: modular bolt-on system already half-exists
   (wings/rockets/cage). Push toward absurd combos: jet stacks, balloon float, magnet
   wheels. This is the long-term "wacky sandbox" identity — prototype one absurd part
   end-to-end (shop → visual → physics → feel) before building many.

Anti-goals: no multiplayer, no open world, no realism sim, don't touch the horror-game
files, don't add heavyweight assets (keep the low-poly/procedural look — it's the style).

## Definition of "amazing" for this pass

A stranger given the keyboard should, within 3 minutes, have: drifted a corner on purpose,
cleared a gap, bought an upgrade they can SEE, switched maps, and said "one more run."
Every one of those moments should already feel good today — your job is to make each one
POP and to remove every remaining rough edge you find on the way.
