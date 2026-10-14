# Validation and performance

Recorded on 2026-10-14. This report describes the initial native addon and its
synthetic examples. It does not establish complete GameMaker compatibility.
The initial tables and `benchmark-results.json` belong to commit `00048ce`, before
`move_contact`, the global singleton, and removal of the bulk query APIs. They
describe the original world-node implementation. Batch results below are
historical and cannot be reproduced through the current API. The benchmark uses
its own query/movement workload and does not exercise `move_contact`.

## Correctness and workflow

| Check | Result |
| --- | --- |
| Standalone C++ core, Release/MSVC | 699,743 assertions passed |
| Standalone core, Clang AddressSanitizer | 699,743 assertions passed; no findings |
| Native Godot integration | 231 checks passed; exit 0; empty stderr |
| Isolated editor integration | 12 assertions passed |
| Blood example equivalence | All 800 positions, velocities, query counts and hit counts agree across batch/scalar execution for 240 steps |
| Atlas conversion | All three frame colors and occupied pixels match the original synthetic frames |
| Mask authoring | All four example masks baked and saved; clean shutdown |
| Windows release export | Exported successfully; playground and benchmark run with baked masks |

The core suite checks bit-packed overlap against a simple pixel oracle, including
word boundaries, negative positions, transforms, and spatial-index updates. The
native suite covers live Groups, lifetime changes, world isolation, immediate
ancestor movement, flips, animation modes, unsupported transforms, and resource
serialization. Regression checks explicitly verify release of old resources after
rebaking and separately saved AtlasTexture/SpriteFrames/mask round trips.

The editor harness exercises the actual plugin in an isolated temporary project.
Its intentional invalid-mask case emits a diagnostic. The headless editor's
thumbnail save also emits a dummy-renderer texture-null message. There are no
remaining RID, ObjectDB, or resource shutdown leak warnings. The reimport check
invokes the plugin callback; it is not a complete operating-system file watcher
test. The playground screenshot was visually inspected. Inspector mouse
interaction and exact overlay appearance were not exhaustively tested.

Reproduce from the repository root:

```powershell
./tools/build_windows.ps1
./tools/run_tests.ps1 -Godot D:/Godot/godot.exe
./tests/editor/run_editor_tests.ps1 -Godot D:/Godot/godot.exe
godot --headless --path . --script examples/verify_blood_benchmark.gd
```

The sanitizer run used Clang 22 with `-O1 -g -fsanitize=address
-fno-omit-frame-pointer` on `bit_mask.cpp`, `spatial_hash.cpp`, and
`tests/core_tests.cpp`.

## Rendered benchmark setup

- CPU: Intel Core i7-12700H.
- GPU: NVIDIA GeForce RTX 3060 Laptop GPU.
- Windows x86_64, MSVC 14.51 Release native library.
- Godot 4.7.2 editor/exporter with the installed official 4.7.1 Windows release
  template. The local 4.7.2 template directory contains only a web template, so
  the export used explicit 4.7.1 custom templates. The saved preset keeps its
  portable default template settings.
- Compatibility renderer, 960 x 640 viewport, VSync disabled, uncapped FPS.
- 800 real MaskedAnimatedSprite2D nodes plus 74 solid sprite nodes.
- Three blood frames share one texture atlas and one baked mask resource.
  There is no MultiMesh substitution, sleeping, or reduction in query count.
- 300 warmup frames and 3,000 measured frames; three sequential runs per case.
- Existing desktop applications, including the research prototype editor,
  remained open. These are workstation observations, not isolated lab results.

Full frame times come from successive monotonic frame-start timestamps. They
include the preceding frame's CPU work, rendering submission, and presentation
wait. Work time is a separate bracket around collision and movement code; burst
work includes GDScript integration and node synchronization. It is not a pure
bit-mask microbenchmark. Creating the particles is timed separately, outside
the warmed measurements.

## Synthetic room results

Ranges cover the three runs. P95 is the largest per-run 95th-percentile frame time.

| Workload | Query API | Mean FPS range | Mean work per frame | Frame P95 |
| --- | --- | ---: | ---: | ---: |
| Settled | One explicit batch | 1260-1374 | 0.244-0.261 ms | 1.073 ms |
| Settled | 800 individual calls | 484-497 | 1.224-1.254 ms | 2.379 ms |
| Repeated burst | Explicit movement/contact batches | 430-447 | 1.330-1.409 ms | 2.820 ms |
| Repeated burst | Individual calls | 168-173 | 4.317-4.488 ms | 8.605 ms |

Each settled run performs exactly 2,400,000 queries, all hits. Each burst run
performs 5,191,906 queries with 2,791,923 hits in both API modes. The burst restarts
every 180 frames and advances a fixed 1/50-second simulation step per rendered
frame to sustain movement pressure. Batching is explicit game code: one proposed
position batch and, when needed, two contact batches containing only colliding
particles. This is valid for these independent particles and static solid targets.
Constructing the 800 particle nodes took 6.7-8.1 ms across these runs; this is a
separate one-time cost, not included in the warmed frame-time table.

The batch settled case exceeds the user's approximate 900 FPS reference on this
machine. The scalar case does not. This is not an interchangeable claim that any
800-node GDScript program or every individual `place_meeting()` workload reaches
GameMaker performance. In that implementation, dense workloads benefited from
the now-removed explicit batch API and the shared texture atlas.

## External Stage01 geometry check

Two additional single runs loaded the earlier research fixture's 74 solid
rectangles and spawn location. They still used this addon's synthetic blood atlas
and movement code, not GameMaker artwork, recorded particle positions, or the
original event system:

| Workload | API | Mean FPS | Mean work per frame |
| --- | --- | ---: | ---: |
| Settled | Batch | 1182 | 0.282 ms |
| Repeated burst | Batch | 441 | 1.376 ms |

The external fixture is intentionally not included in this repository. These
runs establish that the adapter works and give another geometry workload. They
are not a direct YoYoYo_Engine-versus-Godot comparison.

## Reproduction and remaining work

To reproduce the historical batch/scalar results, use commit `00048ce` and its
build/export instructions. With the current per-sprite API, build and export the
current project, then run:

```powershell
./tools/run_benchmarks.ps1
```

The current helper launches individual-query workloads sequentially and saves
JSON/logs under `test-results/benchmarks/`.
[Historical raw results](benchmark-results.json) include all twelve original
synthetic runs, both geometry runs, query counts, frame distributions,
engine information, and the native library SHA256. See
[the examples](../examples/README.md) for individual commands and fixture input.

The next performance task is profiling the individual node/GDScript call path
and moving-node synchronization. The next compatibility task is a shared set of
GameMaker/Godot reference cases for origin rounding, animation masks, instance
selection, and movement/event ordering. Floor quantization and registration
order were explicit addon rules in those revisions, not verified historical
GameMaker behavior. The later on-demand sampling change below replaces the
floor-based geometry rules.
At the time of those measurements, rotation, skew, fractional global scale, and
automatic solid response were outside the supported contract. Affine geometry
support was subsequently added as recorded below; automatic solid response
remains outside scope.

## Contact movement addition

The subsequent `move_contact(direction, max_distance, group)` addition was built
in Release mode and passed the standalone core suite plus **326 native integration
checks**. Its new coverage includes required Group metadata, all cardinal
directions and normalized diagonal travel, positive distance truncation, the
nonpositive 1,000-step limit, starting overlaps, live Groups and world isolation,
precise mask holes, flips/scales, parent transforms, top-level nodes, and immediate
visibility of the moved collider.

Two numeric regressions first failed against the initial implementation and now
pass: a parent scale of three can round a nominally clear global endpoint into
a wall, and large float coordinates can turn one unit step into a two-pixel jump.
The implementation tests realizable parent-transformed coordinates, commits the
tested local position once, and stops before a step that would skip a pixel cell.
Seven deliberate invalid-argument cases emit native errors; the test output labels
these diagnostics as expected, and all checks finish with exit code zero.

No new blood-performance or GameMaker event-parity claim is made by these tests.
The existing synthetic benchmark is unchanged and does not call `move_contact`.

## Global singleton migration

Commit `5d97871` introduced the Engine singleton named `PixelCollision`. It registers
automatically and replaces the former per-ancestor `PixelCollisionWorld2D` nodes.
The Release build passed the standalone core suite and **389 Godot integration
checks** on Godot 4.7.2. The isolated editor harness passed all **12 assertions**.

New integration coverage verifies direct global GDScript access without an
Autoload, root-level sprite registration, cross-branch and SubViewport scalar
and batch queries, detached-source rejection, reparenting, concurrently loaded
PackedScenes, and scene replacement without stale collider registrations. A
worker-thread fixture configures a detached sprite, then verifies its collected
frame/flip/offset state when attached on the main thread. It does not exercise
threaded collision queries or changes to registered sprites.
Every fixture removes its sprites, leaving a zero collider count. No shutdown
leak warnings were reported. Existing geometry, resource, and `move_contact`
checks remain covered; the seven invalid-argument diagnostics remain expected.

The migrated 800-particle example produced identical batch/scalar positions,
velocities, hit counts, and query counts over 240 simulation steps. The verifier
loads the two rooms sequentially because they now share a global collision space,
and checks a zero registration count after each room unloads. The playground and
blood scene also completed 120-frame headless smoke runs with empty stderr.
These are functional checks, not rendering or performance measurements.

Those tests ran inside the ordinary main SceneTree. That revision also tracked
registered SceneTrees for batch Group enumeration, but manually initialized
secondary SceneTrees have not been exercised by this harness.

The performance tables above retain their original implementation and binary
provenance. This migration does not establish a new FPS result.

## Removal of bulk query APIs

`test_meetings` and `count_meetings` have been removed from the native interface,
along with their temporary target index and dedicated SceneTree bookkeeping.
Queries and movement use `MaskedAnimatedSprite2D.place_meeting`, `instance_place`,
and `move_contact`. The synthetic blood workload now uses individual calls only.

The Release build passed the standalone core suite and **383 Godot integration
checks**. The integration suite verifies that neither removed method is exposed
and retains scalar Group, lifecycle, SubViewport, resource, geometry, worker
initialization, and contact-movement coverage. The expected invalid-argument
diagnostics remain unchanged.

The 800-particle scalar workload was captured before and after removal over 240
steps. The trajectory digest (positions, velocities, and per-step counts) matched
exactly, with 364,664 queries and 172,664 hits. The revised verifier passed
explicit contact fixtures, 800 settled hits, and independent terrain-separation
checks over all 240 burst steps. Clean import and settled/burst headless smoke
runs also passed. These checks establish behavior preservation; no new rendered
FPS claim is made. The benchmark helper now accepts only scalar result metadata
so an old batch-mode export cannot silently supply replacement measurements.

## Arbitrary affine masks (historical raster implementation)

Commit `7a1bbd3` added arbitrary finite invertible global bases, including
fractional and negative scales, rotation, and inherited shear. The existing
integer-scale path was retained. Nearest sampling used a documented fixed
raster phase; no GameMaker transformed-mask parity claim is made.

- MSVC Release and Clang 22 AddressSanitizer both passed **989,049 core checks**,
  with no sanitizer findings. Tests include integer-path equivalence and 1,000
  affine cases checked against an independent forward-transformed pixel-square
  oracle, plus boundary, minification, and numeric-range cases. RNG draws are
  now explicitly sequenced so both compilers exercise the same workload.
- Godot 4.7.2 passed **864 integration checks**, including precise rotated
  footprints, fractional scales, negative scales with offsets and flips,
  inherited shear, immediate parent changes, transformed movement, and
  empty-minified-mask recovery after a flip.
- The isolated editor harness passed **23 assertions**. The overlay now displays
  the actual native raster and floored world bounds. Its tests cover rotated
  sparse occupancy, bounds-only updates, texture reuse, basis invalidation,
  singular rejection, and valid transparent rasters. The existing intentional
  invalid-mask and headless-thumbnail diagnostics remain expected.
- The original 800-particle functional verifier passed its explicit contact
  fixtures, settled queries, and independent terrain checks over 240 burst steps.

That implementation retained active rasters even after shared-cache eviction,
so pure translation did not cause rerasterization. Changing angles or scales
could require new work proportional to raster area. It was subsequently replaced
by the on-demand approach described below.

The common integer-transform path was also measured before and after the change
on the same i7-12700H / RTX 3060 Laptop machine, using Godot 4.7.2, the
Compatibility renderer at 960 x 640, VSync disabled, and a Release extension.
Each workload ran twice in separate rendered processes with 100 warmup frames
and 600 measured frames. These shorter samples complement the historical tables;
they do not replace them or measure continuously changing affine transforms.

| 800-particle workload | Before: mean work/frame | Final: mean work/frame | Before / final mean FPS |
| --- | ---: | ---: | ---: |
| Settled, individual queries | 1.379 ms | 1.299 ms | 501.75 / 513.90 |
| Repeated burst, individual queries | 4.775 ms | 4.685 ms | 176.73 / 177.39 |

Query/hit counts were identical in every revision. These same-host short samples
show no observed common-path regression, not a guaranteed speedup or GameMaker
performance equivalence. An intermediate implementation kept bulky cache metadata
per collider and produced slower, noisier settled samples. The final version
shares that metadata with the raster while retaining per-collider ownership.
[Affine validation timing data](affine-benchmark-results.json) retains all twelve
raw reports, including the intermediate samples, three binary hashes, and the
measurement environment.

## On-demand original-mask sampling

The transformed-raster implementation was replaced with integer-world inverse
sampling of the original bit-packed masks. The change follows the audited local
Runner's algorithm and explicit float32 bbox/conversion order. General Godot
matrix inversion, explicit sprite flips, and per-animation shared bounds remain
documented adaptations; no matching-version GameMaker VM oracle was run.

- MSVC Release and Clang Release/AddressSanitizer passed **1,715,115 core checks**.
  Independent scalar and forward-corner oracles cover 3,500 randomized views and
  pairs, plus 1,500 identity-path cases around 64-bit word boundaries. Fixed
  regressions cover truncation toward zero, negative scale edge clipping,
  separate node-position and local-offset conversion, shared bounds extending
  beyond a current frame, and native float addition order near a quarter turn.
  Huge transformed bounds are tested without allocating transformed bitmaps.
  Prepared-view reuse is checked against reconstruction across 3,500 placements.
  Randomized samples also verify conservative identity-path candidate bounds.
  AddressSanitizer reported no findings.
- Godot 4.7.2 passed **935 integration checks**, retaining Group/lifetime/resource
  and movement coverage. New fixtures exercise changing translation phase,
  shared animation bounds after resource reload, formerly rejected large
  transforms, and movement from an empty sampled region. The seven deliberate
  invalid-argument errors remain expected; no shutdown leaks were reported.
- The isolated editor harness passed **37 assertions**. It checks exact preview
  pixels, position/offset/parent cache invalidation, flips, negative scales,
  empty bounds, and bounds-only previews above the allocation limit. The
  intentional invalid-mask diagnostic and known headless thumbnail diagnostic
  remain expected; no shutdown leaks were reported.
- The unchanged blood functional verifier passed atlas/contact fixtures,
  **800 settled queries**, and independent terrain-separation checks for all
  **800 particles over 240 burst steps**, with empty stderr.

The runtime caches original masks only. Transform updates prepare numeric views;
queries clip the logical bbox intersection and stop at the first occupied pair.
Editor preview images remain explicitly allocated, with a separate size cap.
This removes transformed-area allocation during runtime updates, but does not
make large empty overlapping regions cheap to scan.

The same rendered 800-node workloads were measured before and after on the
i7-12700H / RTX 3060 Laptop host, using Godot 4.7.2 and the Release extension.
Each implementation ran twice per workload, with 100 warmup frames and 600
measured frames, in separate sequential processes. Pooled mean FPS is calculated
from the mean frame duration, rather than averaging FPS values.

| Workload | Before / final mean FPS | Before / final mean work | Work change |
| --- | ---: | ---: | ---: |
| Settled, individual queries | 506.51 / 478.31 | 1.357 / 1.457 ms | +7.4% |
| Repeated burst, individual queries | 175.90 / 172.03 | 4.780 / 4.907 ms | +2.7% |

The initial on-demand implementation increased burst work by about 19%. Reusing
prepared geometry and deduplicating equivalent bounds helped slightly. Clipping
identity-path spatial queries to the current frame's occupied bounds recovered
most of that regression: the shared animation bbox otherwise admits extra nearby
blood candidates that must be rejected by Group checks. Precise collision still
uses the documented shared logical bbox and source sampling rules.

Every settled run performed 480,000 queries/hits; every burst run performed
1,073,830 queries and 593,832 hits. Those counts agree across all four measured
implementations. The final short samples retain a modest performance regression;
they are workstation observations, not an equivalence or speedup claim. The
benchmark uses fixed bases and does not measure continuously changing rotations
or scales. It is also a synthetic per-sprite query workload, not the original
YoYoYo_Engine event loop or a `move_contact` benchmark. The approximately 900 FPS
GameMaker reference has not been matched by this workload.

[On-demand timing data](ondemand-benchmark-results.json) contains all sixteen raw
reports, including both intermediate implementations, binary hashes, and the
measurement environment. These records preserve the different geometry semantics
and should not be substituted for a matching-version GameMaker VM comparison.

## MaskedSprite2D addition

`MaskedSprite2D` now extends native `Sprite2D` and uses the same singleton,
Groups, original-mask sampling, movement, and preview implementation as
`MaskedAnimatedSprite2D`. Both `instance_place` methods return `Node2D`, allowing
mixed sprite hits. Static texture baking supports ordinary and atlas textures,
integral contained regions, sheet cells, and independent SpriteFrames sources.
It does not construct SpriteFrames wrappers or read textures during queries.

- The MSVC Release build passed the unchanged **1,715,115 core checks**.
- Godot 4.7.2 passed **1,340 integration checks**, retaining all previous
  coverage. New checks exercise mixed query directions and registration order,
  movement, static affine geometry, sheet frames and all frame policies,
  AtlasTexture margins, shared masks, texture edits/rebaking, and invalid layout
  errors. Unsignaled region toggles are tested both through the property and the
  inherited setter, including recovery of an initially invalid, unindexed target.
- Resource checks cover inline scene reloads, cold external texture/mask loads
  after weak references confirm release of the original resources, and explicit
  source rebinding with `get_baked_texture()` after deep cache bypass. Strict
  texture identity is preserved instead of accepting unrelated equal-sized images.
- The isolated editor harness passed **65 assertions**, including static mask
  creation, region/sheet rebaking, frame changes without rebaking, previews,
  mixed scene validation, shared masks, and saved-scene round trips.
- The unchanged blood verifier passed all **800 particles over 240 steps**,
  including its settled and contact fixtures, with empty stderr.

Only the existing seven intentional invalid `move_contact` diagnostics and the
editor harness's intentional invalid-mask/headless-thumbnail diagnostics were
reported. No shutdown leak diagnostics were observed. Valid static terrain is
not polled wholesale for every query: unsignaled region flags are checked on
sources/candidates, with a separate recovery check for invalid static layouts.

The existing rendered 800-AnimatedSprite2D workload was measured before and after
the manager generalization, using the same host, renderer, and two sequential
600-frame runs per mode with 100 warmup frames:

| Workload | Before / after mean FPS | Before / after mean work |
| --- | ---: | ---: |
| Settled | 487.51 / 485.07 | 1.434 / 1.421 ms |
| Repeated burst | 171.00 / 172.38 | 4.919 / 4.903 ms |

Query/hit totals matched and all benchmark stderr logs were empty. These short
samples show no material regression in the existing animated-node workload.
They do not measure 800 MaskedSprite2D nodes or establish GameMaker performance
equivalence. [Static-sprite addition timing data](static-sprite-benchmark-results.json)
preserves all eight runs, binary hashes, and measurement context.
