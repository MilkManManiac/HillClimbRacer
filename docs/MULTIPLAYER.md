# Multiplayer research — how HC could grow beyond single-player

Research date: 2026-07-04. Read-only investigation; no game code touched. `HANDOFF.md`
currently lists "no multiplayer" as an anti-goal from the v1-v5 build passes — this doc
is scoped narrowly (async-first, ghost-based) specifically because that anti-goal was
about NOT building a synchronous-physics racing game, which is correctly out of scope.
Async leaderboards/ghosts are a very different, much cheaper ask that fits the existing
architecture almost for free. Treat this as input to a decision, not a mandate to build.

## TL;DR recommendation

Build in this order, and stop whenever it stops paying for itself:

1. **Stage 0 (in flight)**: local ghost recording + "race your own best" — already being
   built in the parallel workstream. No network code at all.
2. **Stage 1**: shared ghost **files** — "send a friend your ghost." An evening of work,
   zero infrastructure, zero ongoing cost. Turns the existing save/JSON pattern into a
   shareable artifact.
3. **Stage 2**: online leaderboard + ghost download via a hosted backend (Talo or a
   one-file Cloudflare Worker). A weekend of work, $0/month at this game's scale. This is
   the one that actually feels like "multiplayer" to a player — global times, download
   the #1 ghost, race it.
4. **Stage 3**: realtime ghost-cars (see each other live, no collision) over Godot's
   ENetMultiplayerPeer. 1-2 weeks, real scope risk, and it's the first stage that fights
   the "feel is sacred" pillar (network jitter on a physics-feel game is a hard problem).
   Only worth it if the owner specifically wants "friends racing live" as a marquee
   feature, not just a nice-to-have.

Full collision-racing (cars can bump each other) is **not recommended at all** — this
game's car is a custom analytic-suspension RigidBody, not a networked-deterministic
sim, and Godot has no server-authoritative vehicle-physics story that would keep this
game's specific feel. That tier would be a rewrite, not a feature. Stage 3 already gets
"race with friends" without that cost by making remote cars non-solid.

---

## Architecture facts verified in this codebase

- **Deterministic worlds from a seed.** `HCMain.MAPS` (`scripts/hc/HCMain.gd:25-87`) is a
  dict of per-map override sets (`path_seed`, `noise_seed`, geometry knobs, palette)
  applied to `HCTrack` exports via `_apply_map_overrides` (`HCMain.gd:672`) **before**
  `add_child`, per the hard invariant in `CLAUDE.md`. `HCTrack._ready` (`scripts/hc/
  HCTrack.gd`) then builds the centre-line with a seeded `RandomNumberGenerator`
  (`HCTrack.gd:131-132`, `rng.seed = path_seed`) and hill noise seeded at `HCTrack.gd:125`
  (`_noise.seed = noise_seed`). Roadside scatter is also seeded per-tile off `path_seed`
  (`HCTrack.gd:932-933`, explicitly commented "streaming must be repeatable"). **Confirmed:
  two clients with the same map key generate byte-identical terrain**, which is exactly
  the property that makes ghost playback (and later, shared-seed racing) meaningful
  without shipping the terrain data itself — only the map key + car transforms need to
  travel.
- **Car physics is NOT cross-machine deterministic.** `HCCar.gd` extends `RigidBody3D`
  and drives itself from Godot's physics tick (`_physics_process`, `HCCar.gd:222`) with
  scripted suspension (`_suspend_analytic`) against `HCTrack.ground_info`. RigidBody
  integration, floating-point order-of-operations, and frame-rate-coupled forces are not
  guaranteed identical across two machines even with the same inputs — Godot's own docs
  are explicit that physics is not lockstep-safe this way. **Consequence: any realtime
  multiplayer must be state-sync (server/host owns the truth, clients see interpolated
  snapshots), never input-replication/lockstep.** This lines up with what the ghost
  system will already need to do (record actual transforms, not inputs) — the same data
  shape serves both features.
- **Session loop** is death → shop → retry, all local: `HCMain._process` (`HCMain.gd:789`)
  detects `_car.get("dead")` going true (line 798), banks money, updates `_best[_map]`
  (line 804-805), calls `_save_game()` (line 806), then `_show_shop()` (line 809). **This
  is the single hook point for "submit my run"** — a leaderboard POST or ghost-file write
  belongs right after the `_best` update and before/alongside `_save_game()`.
- **Persistence** already exists and sets the pattern to extend: `SAVE_PATH := "user://
  hc_save.json"` (`HCMain.gd:287`), written via `FileAccess` + `JSON.stringify` in
  `_collect_save`/save (`HCMain.gd:299`, `~373-378`), read back with `JSON.new().parse`
  (`~385-396`), and explicitly disabled under headless (`save_enabled := DisplayServer
  .get_name() != "headless"`, line 294) so probes stay hermetic. A ghost file or a
  leaderboard cache is the same shape: JSON (or a compact binary blob) on disk, gated by
  the same `save_enabled` flag so test probes don't hit the network.
- **No ghost-recorder file exists yet** in `scripts/hc/` as of this research pass (the
  parallel workstream is presumably mid-flight in another worktree). Per the task brief,
  it samples car transforms at ~20 Hz and serializes per map. Following this codebase's
  naming convention (`HCCar`, `HCTrack`, `HCPickup`, `HCCarBody`, `HCAudio`), it will
  likely land as `scripts/hc/HCGhost.gd`. Everything below assumes that recorder produces
  a serializable array of `{t: float, pos: Vector3, rot: Basis/Quat, ...}` samples keyed
  by map — that array *is* the payload for every stage below; nothing here requires
  redesigning it, only adding "send this array somewhere" on top.
- **No export pipeline / no networking code anywhere in the project today.** No
  `HTTPRequest`, no `ENetMultiplayerPeer`, no autoload singletons for networking. This is
  a from-scratch integration at any stage, which argues for the cheapest stage first.

---

## 1. Async multiplayer (leaderboards + downloadable ghosts)

### The simplest thing that works from Godot 4.6

Godot's built-in `HTTPRequest` node can do everything Stage 1-2 need: `POST` a JSON body
(map key, distance/time, seed, ghost blob or a URL to it) and `GET` a leaderboard page or
a specific ghost back down. No plugin required for the client side; the only real
decision is what's on the other end of the wire.

### Backend options, current as of mid-2026

| Option | What it is | Free tier | Verdict for this game |
|---|---|---|---|
| **A dumb HTTPS endpoint** (Cloudflare Worker + Workers KV, or a Supabase Edge Function + Postgres row) | You write ~50 lines: `POST /score` validates+stores, `GET /top?map=hills` returns top N + ghost blob URLs | Cloudflare Workers/KV free tier is generous (100k req/day class); Supabase free tier likewise | **Recommended for Stage 2.** Total control, no vendor lock-in, no risk of the *service itself* disappearing (see SilentWolf below) since it's your Cloudflare account, not a third party's game-backend product. |
| **Talo** (`trytalo.com`, MIT-licensed, open source, has a Godot plugin/asset-library entry) | Purpose-built game backend: leaderboards with score + arbitrary key/value "props" (usable to attach a ghost-blob reference), player auth, cloud saves, and a WebSocket-based realtime layer | Free tier covers up to 10,000 players with all features; self-hostable if you outgrow it | **Recommended if you'd rather not write backend code at all.** Its Godot SDK plugs straight into `HTTPRequest` under the hood; leaderboard "props" can carry the ghost data or a pointer to it. Its "multiplayer with sockets" (secure WebSocket, server does auth+validation+delivery) is also a plausible **cheaper alternative to raw ENet for Stage 3**, since a WSS connection to a server you don't have to NAT-punch is one less unsolved problem for a solo dev. |
| **LootLocker / PlayFab / Beamable** | Enterprise-grade full backends (economy, live-ops, matchmaking, leaderboards) | LootLocker: free to ~10k MAU/month, no self-hosting below enterprise. PlayFab: free to 100k players, but steep learning curve, "requires a spreadsheet to understand pricing." | Overkill for one leaderboard + ghost files. Keep in back pocket only if the game later grows a live-ops/economy need beyond racing. |
| **SilentWolf** | Was *the* recommended free Godot leaderboard service in tutorials for years | N/A — **shut down without warning in November 2025**, breaking games that depended on it | **Do not use.** Cited here specifically as the cautionary tale: don't pick a single-vendor free service you can't self-host or export from. This is exactly why the dumb-endpoint or self-hostable-open-source options above are preferred. |
| **LEADR** | Newer, leaderboard-specific service, Apache-2.0 core, self-hostable, has built-in anti-cheat + replay storage, Godot/Unity SDKs, EU-hosted/GDPR | Free cloud tier exists | Worth a look if "replay storage" + "built-in anti-cheat" out of the box is appealing, but it's newer/less proven than Talo; verify current status before committing. |
| **Platform-native (Steam leaderboards via GodotSteam, etc.)** | Free, built into the platform | Free with a Steam app | Only relevant once/if this game ships on Steam ($100 Steam Direct fee, refunded against first $1,000 revenue). Steam leaderboards + Steam Workshop-style ghost sharing is a legitimate long-term answer, but it gates the whole feature behind a store launch the project isn't set up for yet (no export pipeline exists today per `CLAUDE.md`). |

**Recommendation: start with a hand-rolled endpoint (Cloudflare Worker + KV) for Stage 2.**
It's the least infrastructure, costs nothing at this game's scale, has no third-party
product-death risk, and a solo dev can read/write every line of it. Reach for Talo instead
if the owner wants a dashboard/auth/player-accounts story without writing server code —
it's the more "batteries included" choice and its WebSocket layer keeps Stage 3 open
without adding a second vendor.

### Anti-cheat reality check

For submitted times *and* the ghosts that go with them, there are three honest tiers:

1. **"Just accept it" (friends-game trust model).** Appropriate for Stage 1-2 if the
   leaderboard is scoped to friends/a private code, not a public global list. Zero extra
   work. Given this is currently a single-owner sandbox with no public audience, this is
   the right starting posture.
2. **Server-side sanity checks (cheap, catches obvious/lazy cheats).** Before accepting a
   score: does the ghost's sample count roughly match `distance / avg_speed` at ~20 Hz?
   Does the ghost's final position match the claimed distance via `HCTrack`'s own
   deterministic projection (server re-runs `ground_info`/arc-length math on the
   submitted transform stream — cheap since it's pure math, no physics sim needed)? Is
   elapsed wall-clock time plausible for a sprint-mode timer? This tier is a few hours of
   work and matches what Trackmania actually does in spirit: it validates the *replay*
   against physical/geometric plausibility rather than re-simulating it, because
   re-simulating someone else's ghost through this game's non-deterministic RigidBody
   physics wouldn't even reproduce the same result on the server.
3. **Full replay re-simulation / physics validation.** What Trackmania eventually built
   (their "Competition Patch" replay validator) — and even there it has known false
   positives on older records and is described as historically hard to keep automated.
   Not worth it for this game's scale; only reconsider if the leaderboard becomes public
   and cheating actually becomes a problem.

Start at tier 1 (private/friends leaderboard) or tier 2 (basic plausibility check) and
stop there. This is a hill-climb sandbox for friends, not a competitive esport.

---

## 2. Realtime multiplayer (Stage 3, if wanted)

### Godot 4.6's high-level multiplayer, current state

Godot 4's networking stack is built around `MultiplayerAPI` with three swappable
transports; `ENetMultiplayerPeer` (UDP, reliable+unreliable channels, client-server or
mesh) is the default and still the mainstream choice in 4.6. On top of that,
`MultiplayerSpawner` replicates node instantiation and `MultiplayerSynchronizer`
replicates a chosen set of properties (e.g. a car's `global_transform`) to all peers
automatically; one-off events (horn honk, wreck, boost) go over `@rpc`-annotated
functions. This is unchanged in spirit since Godot 4.0's "scene replication" launch and
remains the documented, supported path in 4.6.

**Gotcha specific to this game (confirmed above): the car is not cross-machine
deterministic.** That rules out input-lockstep (send inputs, let every machine simulate
identically) — the standard trick for cheap racing-game netcode — because two RigidBodies
fed the same inputs on two machines will not track each other exactly. The only viable
model is **state-sync**: one authority (host, or a dedicated relay) owns each car's real
transform and streams it out; everyone else's copy of that car is a dumb interpolated
puppet, not a locally-simulated RigidBody. This is exactly the data shape the ghost
recorder already produces (transform snapshots, not inputs) — Stage 3 is substantially
"pipe the ghost recorder's live stream over the network instead of to disk," which is a
nice reason to build Stage 0's recorder with this reuse in mind.

### Who hosts / NAT traversal

- **Plain ENet client-server**: one player's machine is host, others connect directly.
  Works instantly on a LAN or via manual port-forward; breaks for most real-world
  home-NAT setups without help.
- **GodotSteam**: wraps Steamworks' P2P networking (handles NAT traversal via Steam's
  relay network for free once a player owns the game on Steam). Only available once the
  game is on Steam — gated behind the same $100 Steam Direct fee and a currently
  nonexistent export pipeline (per `CLAUDE.md`, "Windows desktop, no export pipeline set
  up yet"). The cleanest long-term answer if/when this ships on Steam.
- **Noray / `netfox.noray`** (open-source, free, actively maintained addon): a small
  self-hostable or free public orchestration server that performs NAT punchthrough
  between two Godot clients and integrates directly with Godot's `MultiplayerAPI`; falls
  back to relaying traffic through itself when punchthrough fails (symmetric NAT/strict
  firewalls). This is the realistic pre-Steam option — free, no store dependency, made
  for exactly this ("2-4 friends play together") use case.
- **A hosted-relay/WebSocket approach** (e.g. Talo's WSS multiplayer layer, or a tiny
  custom relay): sidesteps NAT punching entirely because everyone connects outward to a
  known server. Simpler to reason about than punchthrough, at the cost of running (or
  paying for) that always-on relay and added latency vs direct P2P.
- **WebRTC** (`WebRTCMultiplayerPeer`) is Godot's option for browser export and/or
  P2P without a dedicated always-on server, using STUN/TURN for NAT traversal similar in
  spirit to Noray; only worth it if a browser build is ever wanted (it isn't, today).

**Recommendation for Stage 3: Noray for a pre-Steam friends build (free, made for this),
or GodotSteam once/if the game ships on Steam.** Skip WebRTC/browser entirely — there is
no browser export goal here.

### Two honest scope tiers for "friends race together"

**Tier A — Ghost-like remote cars, no collision (recommended scope).** Each remote car
is a visual-only puppet: no `RigidBody3D`, no collision shape that interacts with
anything, just a `MultiplayerSynchronizer`-replicated transform driven by the same
snapshot format the ghost recorder already produces, interpolated between updates for
smoothness. Terrain doesn't need to sync at all — it's regenerated identically on both
machines from the shared map key/seed (already proven true above). This is *the exact
same problem as ghost playback*, just live instead of pre-recorded, over the network
instead of from disk. **Realistic estimate: 1-2 weeks** for a solo dev already familiar
with this codebase — most of the time goes into connection UX (host/join, Noray
handshake, disconnect/reconnect handling) and camera/HUD work for "which car is mine,"
not the sync itself.

**Tier B — Real collided racing (cars can bump each other).** Requires either (a) full
server authority re-simulating every car's analytic-suspension RigidBody physics
server-side and streaming corrected state to clients (rewrites `HCCar`'s physics to be
splittable into "authoritative" and "predicted" halves, plus client-side prediction and
reconciliation to hide latency — a substantial netcode project even for engines built for
it), or (b) accepting visibly desynced collisions where two players see different bump
outcomes. **Realistic estimate: multiple weeks to months**, and it directly threatens
pillar #1 in `HANDOFF.md` ("feel is sacred... zero mechanical jank, ever") — added
latency and reconciliation correction on a physics-feel game is the single hardest thing
to keep feeling good. **Not recommended** unless collided racing is a specifically
requested, must-have feature; Tier A gets "race with friends" for a fraction of the cost
and risk.

---

## 3. What comparable indie games do (patterns worth copying)

- **Trackmania** is the canonical example this whole design already resembles: fully
  deterministic tracks, players race ghosts asynchronously, leaderboards are global/
  friends/personal, and anti-cheat is "validate the replay's plausibility," not
  re-simulate it authoritatively (and even that has known false-positive pain). Lesson:
  validate, don't re-simulate.
- **Ghost Pro Racing** (PlayCanvas/HTML5, shown on Hacker News Oct 2025): async
  multiplayer where you race up to 7 recorded ghosts of past players, then can share a
  link to your own ghost for a friend to race 1v1. This is essentially Stage 1+2 of this
  plan validated as a shipped, well-received pattern by a solo/small team in 2025 — "race
  ghosts, share a link" is enough to read as "multiplayer" to players without any
  realtime networking at all.
- **Async Racing** (older, Kongregate-era): opponents are the ghost recordings of the
  last N players on that track, pulled automatically — no explicit "invite a friend"
  step, just always-populated ghosts. A good model for Stage 2's leaderboard screen:
  default to "race the current #1 (or the last few) ghost on this map" rather than
  requiring the player to go find one.
- **Common thread across all of them**: none of these games do live collided racing.
  Async ghosts (recorded ephemeral opponents) is the dominant pattern in exactly this
  genre (arcade hill-climb/time-trial), which reinforces that Stage 2 is where most of
  the player-facing "this feels multiplayer" value lives, and Stage 3/Tier B is a
  disproportionate amount of extra engineering for a genre that historically doesn't need
  it.

---

## Staged plan, effort, and cost summary

| Stage | What | Tech | Effort (solo dev, this codebase) | Cost | Code touch points |
|---|---|---|---|---|---|
| **0** | Local ghost recording, race your own best | In-flight parallel workstream (`HCGhost.gd`, ~20 Hz transform sampling per map) | Already underway | $0 | New `scripts/hc/HCGhost.gd`; hooks into `HCCar._physics_process` (`HCCar.gd:222`) to sample, and `HCMain._process`'s death block (`HCMain.gd:797-809`) to finalize/save a run |
| **1** | Shared ghost **files** — export/import a ghost as a small JSON/binary file or a copy-pasteable code, "send your friend a ghost" | Reuse `HCMain`'s existing `FileAccess`/`JSON.stringify` pattern (`HCMain.gd:287,373-396`); add an export button in the shop/post-run UI and an import path (file picker or paste-a-code) | **A few hours to one evening** | $0 (no network at all) | `HCMain.gd` shop UI (`_build_shop`/`_show_shop`, `HCMain.gd:1250,1647`) for export/import buttons; `HCGhost.gd` for (de)serialization |
| **2** | Online leaderboard + ghost download | `HTTPRequest` node + Cloudflare Worker/KV (or Talo's Godot plugin) for POST-score/GET-top-N+ghost-blob | **A weekend** (endpoint: a few hours; client `HTTPRequest` calls + a leaderboard UI screen: rest of it) | $0/month at this scale (Cloudflare/Supabase/Talo free tiers) | New `scripts/hc/HCLeaderboard.gd` (or similar) called from the death block in `HCMain._process` (`HCMain.gd:797-809`) right after `_best[_map]` updates; new leaderboard screen alongside the existing shop UI |
| **3** | Realtime ghost-cars (Tier A: visible, non-colliding remote cars) | `ENetMultiplayerPeer` + `MultiplayerSynchronizer` on a lightweight puppet node (not `HCCar`'s full RigidBody); Noray for NAT traversal pre-Steam, GodotSteam if/when the game ships on Steam | **1-2 weeks** | $0 (Noray public instance or free self-host); GodotSteam path requires the $100 Steam Direct fee (refunded against first $1,000 revenue) plus building the export pipeline that doesn't exist yet | New autoload for connection/session state; a new lightweight `RemoteCar` puppet scene distinct from `HCCar`; reuses `HCGhost.gd`'s snapshot format live instead of to-disk |
| *(not recommended)* | Full collided realtime racing | Server-authoritative physics + client prediction/reconciliation | Multiple weeks-months | $0-ish infra, but large ongoing complexity cost | Would require splitting `HCCar.gd`'s physics into authoritative/predicted halves — a rewrite of the game's core feel system, directly risking pillar #1 |

### Risks worth flagging to the owner

- **Vendor risk**: pick self-hostable/exportable options (Cloudflare Worker you own,
  Talo's self-host path) over closed free services — SilentWolf's November 2025 shutdown
  is the concrete cautionary tale here, not a hypothetical.
- **Scope creep risk**: Stage 3 is a genuinely different kind of engineering (networking,
  connection UX, NAT edge cases) than everything else in this codebase to date; budget it
  as a separate project, not a quick add-on, and validate Stage 2 first — it may already
  deliver "feels multiplayer" for a fraction of the cost.
- **Feel risk**: this game's #1 design pillar is buttery, jank-free feel, verified by a
  numeric smoothness gate (`SmoothProbe`, `CLAUDE.md`). Realtime networking (even Tier A)
  introduces interpolation/latency for *other players' cars*, which is fine, but any
  temptation to let network state touch the local player's own physics (for Tier B) is
  exactly the kind of change that could quietly blow the vert/pitch-jerk gates — if Stage
  3 or beyond is pursued, treat "local player's own car is never touched by network code"
  as a hard invariant on par with the ones already in `CLAUDE.md`.
- **Export pipeline gap**: `CLAUDE.md` notes there is no export pipeline set up yet.
  Stage 1-2 don't need one (still a local Windows build talking to the internet). Stage
  3's Steam/GodotSteam path does — factor that setup cost in separately if that path is
  chosen.

## Sources

- [SilentWolf shutdown / Godot leaderboard landscape — LEADR blog](https://www.leadr.gg/blog/free-open-source-leaderboard-api-for-games)
- [Best game backend service in 2026 — LEADR blog](https://www.leadr.gg/blog/the-best-backend-service-for-your-game-in-2026)
- [Godot BaaS — cloud backend for Godot](https://godotbaas.com/)
- [Talo — open source, self-hostable game backend](https://trytalo.com/)
- [Talo Godot plugin — leaderboards docs](https://docs.trytalo.com/docs/godot/leaderboards)
- [Talo Godot plugin — GitHub](https://github.com/TaloDev/godot)
- [Talo — Godot page (multiplayer with sockets)](https://trytalo.com/godot)
- [LootLocker — selecting the right backend for your game](https://lootlocker.com/blog/selecting-the-right-backend-for-your-game)
- [PlayFab pricing](https://playfab.com/pricing/)
- [Godot docs — High-level multiplayer](https://docs.godotengine.org/en/stable/tutorials/networking/high_level_multiplayer.html)
- [Godot docs — ENetMultiplayerPeer](https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html)
- [Godot docs — MultiplayerSynchronizer](https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html)
- [Multiplayer in Godot 4.0: Scene Replication — godotengine.org](https://godotengine.org/article/multiplayer-in-godot-4-0-scene-replication/)
- [Godot 4 Multiplayer: Best Practices & Benchmarks (2026) — Ziva](https://ziva.sh/blogs/godot-multiplayer)
- [netfox.noray — Godot Asset Library](https://godotengine.org/asset-library/asset/2376)
- [NAT Punchthrough and Connectivity — netfox.noray DeepWiki](https://deepwiki.com/foxssake/netfox/6.1-nat-punchthrough-and-connectivity)
- [Steam Direct Fee — Steamworks documentation](https://partner.steamgames.com/doc/gettingstarted/appfee)
- [How to Publish a Game on Steam in 2026 — Ziva](https://ziva.sh/blogs/publish-game-steam)
- [TMX Replay Investigation (Trackmania replay/anti-cheat)](https://donadigo.com/tmx1)
- [Trackmania anticheat discussion — Maniaplanet forum](https://forum.maniaplanet.com/viewtopic.php?t=29212)
- [Ghost Pro Racing — Hacker News discussion](https://news.ycombinator.com/item?id=45490844)
- [Ghost Pro Racing — PlayCanvas forum showcase](https://forum.playcanvas.com/t/ghost-pro-racing-async-multiplayer-racer/40733)
- [Async Racing — Kongregate Wiki](https://kongregate.fandom.com/wiki/Async_Racing)
- [Cloudflare Workers KV docs](https://developers.cloudflare.com/kv/)
