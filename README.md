# Hill Climb Racer

A weekly time trial: one track (Sunset Canyon), one fixed car, a clock that runs from
the start line to the finish line, and a ghost of your best lap to race. Built in
Godot 4.6.3. `HANDOFF.md` has the full history and `CLAUDE.md` the working rules.

Run it: `C:\Users\weshu\Tools\Godot\Godot_v4.6.3-stable_win64.exe --path .`

## Shipping plan (2026-10-02 — nothing is deployed yet)

**The goal:** friends on Scryproof can play the weekly trial and see each other's best
times.

**The decision: a Windows download, not a browser game.** Drain The Swamp runs inside
the Scryproof window as a browser game. This one was test-built the same way and it
does not hold up:

| | In the browser | As a Windows program |
|---|---|---|
| Look | washed out to white, scanned car replaced by a blocky stand-in | exactly as on the dev machine |
| Speed while driving | 28 frames a second (RTX 4060 Ti) | full speed |
| Wait | 182 MB loaded before first play, about 90 s on the game host | one download, no wait after that |

Fixing the browser version would be a separate project (re-light the scene, find why
the car fails to load, find the slowdown, shrink the art). The download skips all of it.

**What the download costs**
- Friends install it once instead of clicking play inside a call. They can still share
  the game window in a call.
- Windows only to start.
- Windows will likely warn "unknown publisher" on first run, because the game is not
  signed.
- A new version or a new weekly track is a new download until there is an updater.

**Steps**
1. **Trial-only build.** Strip the classic sandbox, the other maps and the shop from
   what ships; keep the weekly trial. Done on the dev machine, deploys nothing.
2. **Windows export.** Add the export settings to this repo and build the .exe. Size
   is estimated at 150–200 MB and has not been built yet.
3. **Host the download** on the Scryproof box next to the Scryproof installer
   (`scryproof.com/download/`) and link it from inside Scryproof. Needs Matt.
4. **Friends' best times.** The game sends each finished lap (time + ghost) to a small
   new piece of the Scryproof server and reads the board back. Because the game runs
   outside Scryproof, it needs a way to know who is playing: Scryproof gives each
   person a game code, pasted into the game once. Needs Matt, and goes through review.
5. **Race the leader's ghost.** The game downloads the fastest lap and shows it on
   track. Falls out of step 4.

**Known weak spot:** the game reports its own time, so a time can be faked. The server
can reject impossible times and require the ghost with every lap. Good enough for
friends.

**Already done for this:** air controls are locked until the car crosses the start
line, so holding W off the grid no longer tips the nose into the road (measured nose
dip 44.4° before, 1.1° after).

**Waiting on:** Matt's answer on steps 3 and 4.
