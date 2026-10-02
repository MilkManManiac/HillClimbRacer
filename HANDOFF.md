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

## Plan (2026-10-02, night — shipping the trial to Scryproof; NOT deployed)

Owner direction: ship like Drain The Swamp (Scryproof Activities, repo
`CodeProjects/GoOffline`, see its `docs/activities/README.md`), trial only, and show
other people's best times. "No deploys yet", plan only.

**Direction (same night, owner): not a browser game.** "Can we just say this shouldn't
be played on browser?" Yes: ship a Windows download linked from Scryproof instead of
an Activity. The browser findings below are why. The plan in plain words is in
`README.md`; steps 3–4 there (hosting the download, a times API with a per-person game
code) are Scryproof changes and wait on Matt. Scryproof already serves its own
installer from `scryproof.com/download/` (`GoOffline/scripts/publish-installer.sh`);
it has no per-user token system today, so the game code is new work.

- **Air controls locked before the start line** (owner's idea). On a keyboard W is both
  throttle and air nose-down, so flooring it through the spawn drop dug the nose in.
  `HCCar.air_control_locked`, set every frame by `HCMain._update_trial` (trial active,
  clock not started). KbmProbe measures it: 44.4° nose dip without the lock, 1.1° with.
- **Trial web export, measured in a scratch copy** (templates for 4.6.3 are installed;
  headless Chrome on the RTX 4060 Ti, 1280×720). The repo has no `export_presets.cfg`
  yet. What the test showed:
  - It boots and plays. Browser = Compatibility renderer (WebGL2), single-threaded.
  - **The realistic look does not survive as-is**: the frame is blown out to white
    (exposure/tonemap/sky energy read differently in Compatibility) and the scanned
    sports car falls back to the blocky panel body (`_build_concept_body` returned
    false; the raw glTF is in the pack, cause not yet found, GlbUtil fails silently).
  - **28 fps while driving, 120 on the paused title** with the same scene on screen,
    so the cost is game code, not drawing. Likely (not proven) `HCLand` chunk jobs:
    they use `WorkerThreadPool`, which runs on the main thread in a no-threads build.
  - **Download 182 MB** (`index.pck`; every raw asset ships twice, raw + imported, and
    all six maps' art is in). Wasm is 37.7 MB raw, 9.5 MB gzipped. Scryproof's game
    router caps each connection at 2 MB/s and the installer rejects exports over 256 MB.
  - File dialogs (ghost export/import/open folder) do not exist in a browser.
- **Scryproof side**: the Activities host is static by design (no backend, CSP
  `connect-src 'self'`, cookies stripped, the game gets no account data). Game id
  `drain-the-swamp` is hardcoded in `build-drain-the-swamp.py`, `publish.sh`,
  `infra/activities/nginx.conf` and the bridge; a second game needs those generalised
  and an entry in `web/src/lib/activities.ts`. The builder needs a clean, committed
  checkout. Times would travel game → `postMessage` → the signed-in Scryproof page →
  its own API (same shape as the Purdle routes).

## Update (2026-10-02, evening — "HC v10.2", keyboard + drift polish)

Owner direction: "make sure kbm works properly. Space should be break/aka drift", plus
"any other things we can improve on? Go wild."

- **Space = handbrake** (new `handbrake` action: Space / pad A). On the ground it brakes
  at full `brake_force` off the throttle (never into reverse) and at 30% while on the gas
  (`HANDBRAKE_POWER_DRAG`), and with any steer it breaks traction — the same drift the
  S-brake always triggered. In the air Space is still the dive; a hold carried off a
  crest is blocked from diving until re-pressed (`HCCar._dive_block`). Brake lights and
  rear skid marks follow the handbrake.
- **Arrow keys** now steer (project.godot only bound Up/Down) and pitch in the air.
- **Space/Enter can no longer click a stale button**: focus is released when START is
  pressed, and the results panel hands RETRY the focus 0.6 s late so a drift held across
  the line doesn't skip the time. Enter still restarts instantly via its own action.
- **Cursor** hides after 1.5 s of still mouse while driving, returns on any movement or
  menu.
- **`tests/KbmProbe.tscn`**: drives with real key events (`Input.parse_input_event`), so
  the bindings themselves are tested — every other probe presses actions directly.
- **Skid marks were dashed** because segments overlapped by 6 cm and are alpha-blended
  (each joint drew twice as dark over a ribbon barely darker than the road in linear
  light). Now butt-jointed and black. Ruled out with measurements, don't re-chase: wheel
  contact flicker (solid) and the ribbon being buried by the road mesh (mesh is at most
  2.1 cm above the analytic surface over the whole canyon; the ribbon sits at 3 cm).
- **Tyre smoke was a row of grey balls**: GPUParticles step at 30 Hz by default and drop
  each step's puffs in one spot. Realistic body now steps every frame and scatters the
  puffs over about a frame's travel (`_soften_smoke`, `emission_sphere_radius`).
- **Wheels on the car's shaded side were black discs** (most visible on the title hero
  shot). Cause: the model's baked occlusion map is near-black on the wheels and occlusion
  scales ambient light, which is all a shaded wheel gets. `ao_enabled = false` on
  Rim1/Rim2/Tire*. This, not the albedo retune in v10.1, was the real "dark spokes" bug.
- **Landing dust and exhaust backfire** on the realistic body drew as flat squares (tan
  for dust, a blocky white mosaic for backfire). Both now use the soft puff sprite
  (`_soften_smoke`). Arcade bodies unchanged.
- `LookShot` gained `HC_SHOT_DRIFT=1` (bot pulls the handbrake through bends). Use
  `HC_SHOT_ORBIT=1` and look at BOTH sides of the car: o0/o1 are its right (sunlit on the
  canyon straight), o3 its left.
- Open: a rare segfault on exit after a probe has already passed (seen in TrialProbe
  about 1 run in 6-10, once in TitleFlowProbe, 0 of 12 when hunted). Present at v10
  (HEAD) too. All checks print before it; treat exit 139 with "ALL OK" as a pass.
- Noticed, not changed: braking is about 0.7 g (31 m/s to rest takes 4.3 s), so from top
  speed a stop is ~10 s. The bot and medals are calibrated on it; owner call.

## Update (2026-10-02, later — "HC v10.1", canyon polish)

Owner direction: perfect Sunset Canyon (the trial track) first; it becomes the standard
the other maps are brought up to. His notes: camera "a little funky maybe a little too
loose", and a centre line "will help with seeing turns".

- **Chase camera, realistic maps only** (`HCMain._update_camera`, `CAM_TIGHT_*`): rig
  swings behind the velocity faster, position follow is quicker with most of the
  speed-lag trail fed forward, aim follows faster, corner look-ahead capped at 2.6 m
  (was 7 m, which from 7 m back threw the car to the edge of the frame), and it follows
  the car's interpolated (drawn) position. Arcade maps keep the old rig.
- **`tests/CamProbe.tscn`** (`--headless --fixed-fps 60`): bot lap, prints camera
  distance, how far off-centre the car sits, and view yaw acceleration. Before → after:
  distance 7.0–13.6 m → 6.4–8.7 m; car off-centre rms 19° / max 41° → 11° / 20°; yaw
  accel rms 110 → 129 deg/s². Owner has not driven it yet; retune from his verdict.
- **Centre line** (`hc_ground.gdshader`, `centre_color`): highway yellow, dashed on
  straights, solid through bends (same `widen` signal as the kerbs), held to about a
  pixel wide at distance so the road's direction reads far ahead.
- **Skid ribbons** default tint near-black (they are unshaded and were drawing lighter
  than the canyon's dark asphalt). **Wheels**: `Rim1` lifted from black to gunmetal, so
  the spokes no longer vanish in shade (closes the v10 known issue).

## Update (2026-10-02 — "HC v10", realistic look on Sunset Canyon)

Owner reaction: "the most insane upgrade ive ever fucking seen in anything ever." This
is the visual direction now: real scanned/photographed assets, not procedural colour.

- **Opt-in per map**: `MAPS[key].overrides.look = "desert"` (HCTrack export `look`).
  Only Sunset Canyon has it; the other maps are untouched. Everything realistic is
  skipped under `--headless`, so tests stay fast and physics are identical.
- **`HCLook.gd`**: per-look config (textures, sky, sun angle, haze) and the shared
  material/sky builders. Sky = Poly Haven HDRI that also lights the scene; the sun is
  aimed from where the sun is in the photo. AgX tonemap, SSAO, light fog, soft shadows.
- **`shaders/hc_ground.gdshader`**: one shader for road AND land so the seam vanishes.
  Road markings (edge lines, kerbs on tight corners, cracks, patches, rubber line, sand
  at the edges) are computed per pixel from ribbon vertex data (UV = lateral m /
  arc-length m, UV2 = half-width / widen, COLOR = level paint).
- **`HCLand.gd`**: canyon terrain generated from distance to the road (floor → talus →
  terraced walls → mesa), streamed in near/far chunks on WorkerThreadPool. Scatters
  baked boulders and scrub.
- **Car**: Khronos "Car Concept" (CC-BY, credited) on the trial's sports car, scaled to
  the physics wheelbase, wheels re-hung on steer/spin rigs (`HCCar._build_concept_body`,
  `HCCarBody.concept_instance`). Physics/VSPEC untouched. Ghost = same body as glass.
- **Gates**: steel truss gantries + sector boards (`HCMain._build_gate_real`).
- **UI**: title rebuilt over the live scene, Barlow Condensed, amber accent, no emoji;
  trial HUD speed readout; results panel restyled.
- **Assets** (~85 MB): `assets/pbr`, `assets/sky`, `assets/desert` (+ `baked/*.res`
  made by `tools/BakeProps.gd`, run without `--headless`), `assets/car/concept`,
  `assets/fonts`. All loaded at runtime, no editor import needed.
- **Visual review**: `tests/LookShot.tscn` (no `--headless`; env `HC_SHOT_S`,
  `HC_SHOT_MAP`, `HC_SHOT_ORBIT=1`, `HC_SHOT_PERF=1`). ~117 fps on an RTX 4060 Ti.
- **Known issues**: other maps still have the old look. (Dark wheel spokes: fixed in
  v10.1.)

## Direction change (2026-10-01 — "HC v9", weekly trial)

Owner call: "drop a lot of the upgrade stuff and focus more on a multiplayer trial type
game." His format, in his words: "almost like a weekly track. same car/setup for each
map. go with mid to fast range cars. Then whoever can get the fastest time they win.
show ghosts of fastest… roughly a 45 - 60 second map but with the idea some people may
get really good at it." Then: "no boost. we can just pick one map for now and fix others
as needed." So the weekly trial is now the main game; classic (endless + shop) is still
there behind the CLASSIC toggle, untouched.

- **One track, one car**: `HCTimeTrial.TRACKS` names the car, its fixed upgrade levels
  and the length per track. Week 1 = Sunset Canyon, Sports Car, engine 2 (72 m/s cap),
  2800 m. Why engine 2: a stock sports car (40 m/s) was held flat through every corner
  by the bot — no time to find. At 72 the bot averages 52.6 m/s, so the line matters.
- **Trial rules** (`HCMain._is_trial()` is the one switch): no fuel, no pickups, no
  money, no shop, no score/combo HUD, stock body (kits refit the wheel stance). Garage
  picks are remembered (`_garage_vehicle/_garage_map`) and restored on CLASSIC.
- **Clock runs line to line**: starts 24 m past spawn, stops at the finish; crossings
  are sub-frame corrected (overshoot / speed). 4 splits flash the GAP to your best
  (green/red) and to the rival. A wreck auto-restarts after 0.7 s; Enter/Back restarts
  any time. The finish ends the run: car brakes itself, results panel (time, gap,
  medal, next medal, rival gap, Retry / Main Menu).
- **Props**: chequered start/finish gates + glowing split hoops, built by HCMain from
  `HCTrack.frame_at_s` (visual only, no collision).
- **Ghost files** now carry the run's splits (optional field, outside the checksum).
- Tests: `TrialProbe` rewritten (46 checks), `GhostShareProbe` moved to canyon,
  `tests/TrialBot.tscn` = bot lap for calibration (53.3 s, 0 wrecks),
  `tests/TrialShot.tscn` = renders title/start/split/finish/results PNGs.
- Medals (gold 50 / silver 54 / bronze 65) are bot-calibrated — human pass wanted.
- NOT built yet: the online board, more than one rival ghost, the week rollover /
  archive, any second track. Gravity Works likely needs shortening when it gets a turn
  (owner: "took awhile").

## Update (2026-07-09, eleventh pass — "HC v8", same session)

- **6th map: Dune Drift** (amber card, classic mode): golden-hour desert, long
  rhythmic rollers (hill_amp 9 / noise_freq 0.0015 / straight_bias 0.68), rare
  modest gaps, rock-only scatter, dune/mesa silhouettes + wind-blown sand motes,
  trial at 1100 m (medals bot-calibrated — human pass wanted, like gravity).
  Bot: van 681 m (fuel plateau), sports 2424 m untouched at 40 m/s, F1 3804 m.
  AutoDrive now sweeps all six maps + takes HC_AUTODRIVE_MAPS/VEHICLE env filters.
- **Prop near-misses**: `HCTrack.props_near(x,z,r)` (flat [x,y,z,r] quads, per-tile
  index, zero-alloc scratch buffer); HCCar pays NEAR MISS only when a prop passes
  front-to-behind with tightest edge gap 0.05–1.6 m at ≥18 m/s — shares the rail
  cooldown. Props sit 5 m off the drivable width, wreck line at +11 m: a real
  verge gamble.
- **Balloon tiers float softer** (5.20 m/s at L1 → 3.40 at L6), shop copy updated.
- Gap landing pads are now `gap_pad_color` (export) — dunes overrides to earthy
  green; default lime read alien on sand.
- Owner played a mid-session build (through v7.9 + dunes). Battery 12/12 at the
  session-long baseline 2.78/0.17.

## Update (2026-07-09, tenth pass — "HC v7.9", same session)

- **Drift skid marks** (`HCSkid.gd`): 600-segment MultiMesh ring buffer of ribbon
  quads laid between consecutive wheel contacts (reuses the suspension's own
  analytic ground data — zero extra terrain queries). Rear wheels while drifting,
  all four under brake-lock >15 m/s, 0.3 s scuff after hard landings; shader age
  fade; strips break across gaps/teleports; loop zones never mark; reset wipes.
  `tests/SkidProbe.tscn` in the battery (12 probes now), SkidShot harness kept.
- **Ambient life per map** (HCScenery): hills birds, alpine snowfall, canyon warm
  dust (subtle — favorite map untinted), midnight fireflies + rare shooting star,
  gravity-works embers + breathing beacon pulse. All car-following, ≤70 particles
  per map, AmbientShot harness kept.
- **Smoke fix**: `_make_smoke`'s untextured BILLBOARD_ENABLED quad rendered every
  tire/exhaust/damage puff as a 1 m hard-edged square AND discarded per-particle
  scale; now routed through the explosion pass's `_fx_puff_mat` (soft radial
  sprite, BILLBOARD_PARTICLES + keep_scale). If you add particles, use that
  helper — plain BILLBOARD_ENABLED on code-built particle quads is a trap.
- Baselines unchanged through the whole session: SmoothProbe 2.78/0.17.

## Update (2026-07-09, ninth pass — "HC v7.7–7.8", same session as v7.6)

- **Balloon float shipped** (roadmap item 8's first absurd contraption, end-to-end):
  "Party Balloons" 6-tier shop part; hold F (pad-X) airborne → buoyant ~5 m/s fall,
  C1 engage, roof balloon cluster inflates/sways/pops as the charge drains, hard
  slams burst 25%, floats >2 s feed the combo. `tests/BalloonProbe.tscn` (24 checks)
  + BalloonShot harness. Owner-playtest asks: should higher tiers fall SLOWER (one
  constant); should rails pop balloons on contact?
- **Visual wave (owner ask "coins, guard rails, explosions, menus")**:
  - Pickups redesigned (chamfered gold coin, jerry-can fuel, nitro bottle; periodic
    glints, richer collect bursts + ground ring). W-beam guardrail profile, tapered
    posts, night reflector dots (night derived from grass_color luminance), rails
    flare into the ground at gap edges. `tests/PickupRailShot` harness.
  - Wreck explosions (health deaths only): core flash, ground shockwave ring, debris
    + panel shed, fire licks/embers, 4 s smoke, camera kick, sub-thump audio layer;
    landings speak an impact language (directional dirt spray vs clean white streak
    on perfect landings). `tests/WreckShot` harness (has a --diag flag).
  - Menu polish: one procedural UI theme (rounded, shadows, amber focus), hover/press
    tweens on all buttons, panel slide/slam transitions, title vignette + drifting
    motes + logo bob, outlined HUD fonts. All cosmetic — probe-visible state stays
    synchronous.
  - Violent deaths wait 0.9 s before the shop so the fireball reads (headless keeps
    the synchronous open).
- Battery is 11 probes now (+BalloonProbe). Baselines still 2.78/0.17, StuntProbe
  rms 1.92 lifts=0, LoopScan canyon xing=0.

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

Anti-goals: no collided realtime multiplayer (ghost-based trial multiplayer IS the
direction as of 2026-10-01 — see the top of this file), no open world, no realism sim, don't touch the horror-game
files, don't add heavyweight assets (keep the low-poly/procedural look — it's the style).

## Definition of "amazing" for this pass

A stranger given the keyboard should, within 3 minutes, have: drifted a corner on purpose,
cleared a gap, bought an upgrade they can SEE, switched maps, and said "one more run."
Every one of those moments should already feel good today — your job is to make each one
POP and to remove every remaining rough edge you find on the way.
