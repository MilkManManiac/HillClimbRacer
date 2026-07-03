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

## Where it stands today (2026-07-03)

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
