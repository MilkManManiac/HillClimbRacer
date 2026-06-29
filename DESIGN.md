# "Car Game" — Design Brief (working title)

A creepy first-person horror game inspired by the *Left/Right Game* reddit story, with
Cthulhu-esque cosmic-horror flavor. Built in **Godot 4.6.3**, PSX/VHS lo-fi, AI-assisted assets.

> **IP note:** "The Left/Right Game" and its characters (Alice Sharman, etc.) are optioned by
> Amazon/QCODE. We build the **ritual and the vibe**, never the protected title or character
> names. Working title for now: **Car Game**. Pick a real, original title before anything public.

---

## Resolved design decisions (from the grilling)

| Branch | Decision |
|---|---|
| **Core loop** | Hybrid: drive the road + get out and explore on foot at key beats |
| **Horror mechanic** | Rule-following ritual — the road has rules; breaking one invites horror |
| **Structure** | Handcrafted linear acts (Act 1–3), branching on choices — a 2–4 hr story (eventually) |
| **Companions** | Start solo (isolation); find survivors along the road who ride with you or follow in their own cars, then fracture/die |
| **Failure model** | Narrative consequence, keep going — mistakes scar the run (lose a companion, an arm, the Hitchhiker rides along) rather than respawn. Few/no hard game-overs. Mistakes are authored. |
| **Art direction** | PSX / VHS lo-fi — low-poly, low-res textures, grain, dithering, heavy fog. Hides jank, fog = free atmosphere, AI texture gen fits perfectly |
| **POV framing** | Documentarian / podcaster — you record the expedition (dashcam, audio logs, CB radio). Diegetic reason for the VHS look; narration spine; ElevenLabs VO |
| **Fear register** | ~90% slow-burn dread, ~10% rare earned shocks (cosmic indifference, not haunted-house) |
| **Scope** | **Vertical slice first** — one polished act, 20–40 min |

## Vertical slice (milestone 1)

- **Anchor horror:** **The Hitchhiker** — a pleasant man you must pick up but *never speak to /
  acknowledge*. Stay silent and he leaves. Speak, and he stays in your car, whispering, warping
  later choices. This *is* the rule mechanic in miniature and the showcase for the
  narrative-consequence model.
- **Driving model:** Simplified arcade + auto-pace. The car cruises the lane on its own; the real
  input is the **left/right choice at intersections**. No vehicle physics to tune, always feels
  intentional, all focus on dread + choice.
- **On-foot:** One short beat — a **gas-station stop** (~2 min walk) where you first encounter the
  Hitchhiker / step out. Proves both pillars (driving + walking) at bounded cost.
- **Deliverable:** one car interior, one stretch of road + intersections, one gas station, one NPC.
  Fully polished, genuinely scary, ~20–40 min.

## Signature set-pieces for later acts (from the source)
Hitchhiker (slice) → the cornfield + hidden turn (voice from the corn) → **Jubilation** (too-sweet
1950s town that won't let you leave) → the flashlight-triggered **spider-child** (light = the trap)
→ asphalt-quicksand / living road → the **tunnel** (point of no return: retrace-or-die) →
the **Static Entity** finale + mirror-self time loop (you become the thing on the road).

## Design pillars (from cosmic-horror research)
1. **The car is your Iron Lung** — vision confined to headlights + mirrors; everything beyond is the
   player's imagination working against them.
2. **Indifference, not malice** — the road doesn't hate you, it doesn't *notice* you. Worse.
3. **Establish a comforting rhythm, then corrupt the familiar** (Dredge) — repeat a roadside object,
   bring it back subtly wrong.
4. **Looking costs you** — staring, mirror-checks, breaking a rule trade information for dread.
5. **Audio-first** — CB-radio chatter, low-freq drones, sudden silence, 3D positional audio. The
   source podcast won awards for binaural sound; treat audio as the primary fear delivery.

---

## Tech stack (confirmed on this machine)
- **Engine:** Godot 4.6.3, **Forward+** renderer (volumetric fog, SDFGI, color-grading LUT,
  tonemap). `C:\Users\weshu\Tools\Godot\Godot_v4.6.3-stable_win64_console.exe`
- **First-person:** CharacterBody3D + Head pivot + Camera3D for the gas-station beat;
  SpotLight3D flashlight. (Driving uses the simplified auto-pace controller.)
- **Horror look:** black ambient/background so only lit areas show; volumetric fog; full-screen
  post-process shader (CanvasLayer + ColorRect) for grain/vignette/chromatic aberration/VHS,
  driven by a "dread" uniform. Packs: KorinDev Post-Process, ArseniyMirniy Screen Effects.
- **AI assets — ComfyUI (installed at `C:\ComfyUI`):** great for low-res **textures** (Ubisoft
  CHORD → seamless PBR), **concept art**, and **found-media** props (fake documents, VHS overlays,
  photos) — ideal for the documentarian framing. *Not* a level/mesh builder.
- **3D:** low-poly is cheap by hand or from **Kenney** / **Quaternius** (CC0). Hero props only via
  local **Hunyuan3D 2.1** (commercial-safe) → Blender cleanup → Godot. Skip heavy image-to-3D.
- **Audio/VO:** **ElevenLabs** (narrator audio logs, CB voices, text-to-SFX) + **Suno**/ElevenMusic
  for ambient drone loops. No official Godot plugin — pre-render WAVs.

## Relevant skills
- **`godot`** — primary. Build, GdUnit4 tests, PlayGodot E2E, web/desktop/itch.io export. Use as-is.
- **`verify-dont-guess`** — before any load-bearing decision (asset choice, shader params, a fact).
- **`artgen`** — *mismatch* (2D pixel-art pipeline). Don't run its loop for 3D. Its ComfyUI
  operational know-how (run own venv on :8188, API JSON, `POST /free` to release VRAM) is reusable.
- **`skill-creator`** — later, to spin up a custom "Car Game" project skill once the workflow settles.
- **`deep-research`** — for deeper dives (e.g. PSX shader techniques, ElevenLabs pipeline).
