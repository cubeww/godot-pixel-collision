# Examples

All artwork in this directory is synthetic and created for this repository.
No GameMaker project assets are required. Scenes use ordinary Node Groups on
`MaskedAnimatedSprite2D` itself: `solid`, `hazard`, and `player`.

Scene roots are ordinary `Node2D` nodes. Sprites register automatically with the
native `PixelCollision` singleton when they enter the scene tree; no collision
world node or Autoload setup is needed. All active scenes share the same collision
space and Group names, so objects in separate scene branches can collide.

## Authoring the masks

The SpriteFrames and PixelCollisionMask resources in `resources/` are editable
assets. Frames are shared by the corresponding scene instances. Player collision
uses one fixed rectangle while the sprite animates; spikes and blood use precise
alpha masks. Blood has three frames but its animation is paused after choosing
a frame, just as a stationary particle sprite should be.

Blood's three 4-by-4 frames are AtlasTexture regions in one 12-by-4 synthetic
sprite sheet. They keep one backing texture while retaining separate frame
regions and masks. Sharing SpriteFrames alone does not make separate source
textures share a GPU texture. For large numbers of normal animated sprites,
use a shared atlas so alternating animation frames can remain in the same draw
batch. This does not reduce the number of nodes or CanvasItems and does not
guarantee one draw call when other render state or draw-order constraints differ.

Mask baking is an authoring operation. After changing source art or mask settings,
use the addon's Bake action, or run this command after importing the project:

```powershell
godot --headless --path . --script examples/bake_example_masks.gd
```

Save the generated `.tres` files. Examples validate these saved masks on startup
and stop with an error if they are stale; they do not silently rebuild masks for
each instance or each query. `bake_example_masks.gd` is the explicit one-time
authoring command and is excluded from the benchmark's measured workload.

## Playground

Run `playground.tscn`, or start the project normally. Move with A/D or the arrow
keys, jump with Space, and reset with R. F adds/removes the purple platform's
`solid` group using standard Node methods. The next collision query observes the
change. B opens the node benchmark. Player movement is an illustrative platformer
controller, not a port of GameMaker's solid response or event system.

The individual `player.tscn`, `block.tscn`, and `spike.tscn` scenes demonstrate
the editable native node workflow. The playground generates repeated level
geometry from those same shared resources to keep the scene source compact.

## 800-node benchmark

The benchmark creates **800 real `MaskedAnimatedSprite2D` nodes**, each with its
own CanvasItem and transform. It does not use MultiMesh, particle rendering, or
sleeping to reduce the number of rendered sprite instances. All nodes share one
three-frame SpriteFrames and one baked mask. Collision sources are also registered
colliders, but do not belong to `solid`, so they cannot collide with each other.
The three frame textures also share one atlas; interleaved frame indices therefore
do not require alternating between three unrelated textures.

```powershell
godot --path . -- --benchmark --settled --frames=3000 --warmup=300 --output=C:/temp/settled.json
godot --path . -- --benchmark --burst --frames=3000 --warmup=300 --output=C:/temp/burst.json
```

Run a rendered build without `--headless` when comparing actual FPS. The script
disables VSync and the FPS cap. Do not run competing benchmarks simultaneously.
`--headless` is useful for correctness smoke checks, and the JSON labels it
explicitly. It cannot establish rendering performance.

- **Settled:** exactly 800 independent queries every measured frame, including
  particles that never move. Each particle calls `place_meeting()` once.
- **Burst:** centralized GDScript integrates all particles and calls
  `place_meeting()` individually for each proposed position. Each initially
  colliding particle makes two additional queries: horizontal contact followed
  by vertical contact. Final node positions are applied after resolution.
  The scene restarts a burst every 180 frames to sustain motion.
  JSON records all actual queries, including both contact stages.
- **Timing:** monotonic frame-start intervals include complete preceding frames.
  JSON reports mean FPS, mean/median/p95 frame time, collision/update workload,
  actual query count, hit count, renderer, viewport, and node creation time.
  Creation time is excluded from warmed frame measurements and is reported
  separately. The burst uses a fixed 1/50-second simulation step per rendered
  frame, deliberately matching an uncapped room-style workload.

Only individual collision queries are supported. Reports retain
`"query_mode": "scalar"` to identify this workload when comparing historical
reports. `tools/run_benchmarks.ps1` runs both workloads sequentially; there is no
query-mode option.

Default terrain contains 74 synthetic solid rectangles. An optional external
`--fixture=C:/absolute/path/stage01.json` can load the earlier research fixture's
inclusive solid rectangle coordinates. The adapter requires sizes divisible by
32 and reads only geometry and the spawn location; it continues to use this
repository's synthetic blood masks. Fixture data is not copied into the repo.
Such a result is **not** an identical reproduction of the earlier prototype.

`--screenshot=C:/absolute/path/image.png` captures the thirtieth rendered frame.
Use it with at least 30 total warmup/measurement frames and without `--headless`.
The normal Godot `--quit-after` option also works for smoke checks, though it may
quit before the benchmark writes its final report.

To check atlas pixels and particle behavior without measuring FPS:

```powershell
godot --headless --path . --script examples/verify_blood_benchmark.gd
```

This verifies all three frame images and masks against explicit expected pixels,
then checks explicit floor, wall, corner, free-motion, and terminal-velocity
fixtures with expected positions, velocities, and query/hit counts. Settled mode
must perform 800 queries with 800 hits. A separate 800-particle simulation runs for
240 deterministic steps, including a repeated burst, and checks node state and
terrain separation using known occupancy rectangles independently of the
collision API. Each room is freed before loading the next, and the singleton must
have no colliders left after cleanup. These are synthetic workload checks, not
GameMaker trajectory compatibility results.
