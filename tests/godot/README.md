# Native integration checks

Build the extension and import the project before running the suite from the
repository root:

```powershell
godot --headless --path . --editor --import
godot --headless --path . --script tests/godot/run_tests.gd
```

The script creates synthetic images and scenes in memory, checks actual native
query results, prints its check and failure counts, and exits with a nonzero code
on failure. No GameMaker assets are needed. A temporary Resource round-trip file
is written under `user://` and removed by the test.

Coverage includes pixel holes and signed truncation boundaries, sprite offsets and
flips, integer and fractional scale, arbitrary rotation, inherited nonsingular
shear, independent and animated masks, alpha and manual bounds,
atlas regions, shared resources, serialization, live Godot groups, deterministic
hit selection, automatic singleton registration and teardown,
same-frame direct and ancestor movement, and invalid transform rejection.
Fixed expected sample tables cover quarter turns, 30- and 45-degree rotations,
1.5 and 0.5 scales, negative scale, sprite and mask offsets, flips, transformed
parents, two transformed masks, and subpixel translation that changes occupancy.
The tables follow the audited local Runner's integer-world sampling and complete
local-coordinate truncation rather than deriving expected values from native
query output. They deliberately retain signed-scale edge clipping and different
truncation rules for bounds and instance origins. General Godot affine bases,
floating-point operation order, and Godot centering remain documented extension
boundaries, not verified target-VM golden results.

Additional regressions check animation-wide logical bounds across distinct
frames, independent instances sharing the original baked mask, immediate
minified flip changes, movement with empty current sample sets or integer bounds,
and very large transformed extents that previously required rejected bitmap
allocations. Singular, nonfinite, and unrepresentable coordinate ranges are still
rejected explicitly.
Singleton checks verify Engine registration without a project Autoload, direct
SceneTree-root sprites, global queries across branches, nested parents, and SubViewports,
reparenting, detached-node rejection, simultaneously loaded PackedScenes, and
scene removal or replacement without stale registrations.
The public API checks also verify that the removed `test_meetings` and
`count_meetings` methods are not exposed.
A detached sprite is also configured on a worker thread using resources baked
on the main thread, then attached and queried on the main thread. This checks
detached initialization only; collision queries still require the main thread.
Regression checks also verify that repeated rebaking releases previous sources
and that separately saved SpriteFrames, AtlasTextures, and masks survive a deep
cache-bypassing reload.

The `move_contact` checks cover exact cardinal directions, normalized diagonal
steps, positive distance truncation, the 1000-step fallback for nonpositive
distances, initial overlap, pixel cavities and thin walls, live group membership,
global group matching across scene branches, source flips, integer and fractional
scale, rotated sources and targets, affine parent transforms, immediate
query visibility after movement, parent inverse-transform rounding, large
coordinate pixel jumps, and invalid arguments or collider state. The
checks use explicit expected positions rather than a second implementation of
the movement algorithm.

Invalid-state checks intentionally exercise unbaked or missing masks and
invalid transforms. Invalid `move_contact` arguments intentionally produce
native error diagnostics. Diagnostic output during these checks is expected;
the final check count and process exit code determine the suite's result.

This suite checks collision behavior rather than measuring performance. See the
project's benchmark examples for timing measurements.

`static_sprite_tests.gd` runs as part of the same suite and checks
`MaskedSprite2D` alongside `MaskedAnimatedSprite2D`. It covers plain textures,
pixel holes, centering, offsets, flips, fractional scaling, rotation, same-frame
translation, mixed-type queries and contact movement, shared registration order,
live Groups, source exclusion, disabling, and teardown. Both node types declare
`Node2D` as the `instance_place` return type so either can return the other.

Static authoring checks exercise explicit `bake_sprite`, `hframes`/`vframes`,
row-major `frame`/`frame_coords`, integral texture regions, current/union/fixed
frame policies, previews, shared source identity, independent SpriteFrames masks,
texture edits and rebaking, AtlasTexture margins, inline scene/resource round
trips using deep cache bypass, and paired external resources loaded into a cold
cache after weak references prove that the original objects were released.
Independently deep-loaded masks can explicitly supply their source texture through
`get_baked_texture()`, matching the existing `get_baked_source()` animation workflow.
Unsignaled `region_enabled` changes are checked through both the property
and inherited setter, including initially invalid targets that recover before an
unrelated source query. Inactive region rectangles do not invalidate a full-texture
mask. Fractional, empty, negative, outside-texture, and indivisible cell layouts
must fail with explicit authoring diagnostics.
