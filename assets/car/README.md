# Car assets

Drop `.glb` car models here and `scripts/hc/HCCarBody.gd` will load them at runtime
(no editor import step) and swap them in for the procedural car body.

## Format

- **`.glb`** (glTF binary), single file, **textures embedded** (no separate `.bin`/image
  files — the loader only reads one path).
- **Low-poly**, roughly **< ~20k triangles**, to match the rest of the game's blocky/flat
  art style. Highly detailed automotive-grade models will look out of place and cost
  more to render.
- **Real-world-ish proportions** are fine but not required — `HCCarBody.load_body()`
  rescales the whole model to fit the car's collision box, so absolute size doesn't
  matter, only the aspect ratio (length vs width vs height).

## Facing

Author the car facing **either -Z or +Z** along its length (i.e. nose pointing straight
down one axis, not sideways or on a diagonal). The loader can't reliably tell which way
a car "should" face from geometry alone, so it exposes a `flip_forward` flag — if a model
loads backwards in-game, that's the fix (see HCCarBody.gd), not a re-export.

## Wheels

Author wheels as **separate nodes** (mesh instances or their parent transforms) with
names that contain **"wheel"**, **"tire"**, or **"tyre"** (case-insensitive, e.g.
`Wheel_FL`, `tire.001`). The game renders its own physics-driven wheels, so
`HCCarBody.hide_wheels()` finds and hides these by name — a model with wheels baked into
the body mesh (not separate nodes) can't be de-wheeled and will show doubled wheels.

## Licensing

Record the license for every asset:

- **CC0** preferred — no attribution needed, simplest to ship.
- **CC-BY** is fine but requires an attribution line in `CREDITS.md` (project root;
  create it if it doesn't exist) crediting the author and linking the source.
- Avoid anything non-commercial-only or share-alike unless you've confirmed it's
  compatible with how this project is distributed.

## Naming convention

Follow the pattern already used in this folder:

```
<name>_<author>_<license>.glb
```

e.g. `kenney_sedan_cc0.glb`, `car_80s_ladd_ccby.glb`. Keep `<license>` lowercase, no
punctuation (`cc0`, `ccby`, etc.) so it's easy to grep for attribution requirements.
