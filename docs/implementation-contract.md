# Implementation contract

This file records the version 0.1 implementation boundary. Public names below
describe the first release; internal indexing and caching details may evolve.

## Public classes

- `PixelCollisionMask : Resource`: shared mask configuration and serialized baked
  pixel data. `shape_mode`: `PRECISE=0`, `RECTANGLE=1`. `frame_mode`:
  `CURRENT_FRAME=0`, `ANIMATION_UNION=1`, `FIXED_FRAME=2`. Properties include
  `alpha_threshold` (0..1), `manual_bounds: Rect2i` (empty means automatic),
  `fixed_animation: StringName`, `fixed_frame: int`, `source_frames: SpriteFrames`
  (optional independent source), `mask_offset: Vector2i`, and
  `follow_sprite_flip: bool` (default true).
  `bake(frames: SpriteFrames) -> Error` is an explicit authoring operation; never
  called implicitly for each instance or collision query. Static sprites use
  `bake_sprite(sprite: Sprite2D) -> Error`. `is_baked_for(frames)`,
  `is_baked_for_sprite(sprite: Sprite2D)`, and `get_bake_error()` allow
  editor/export validation. `get_preview_image_for_sprite(sprite: Sprite2D)`
  returns the selected static sprite mask image in source coordinates.
  `get_baked_texture() -> Texture2D` returns the source of a native texture bake,
  or null for a SpriteFrames bake; `get_baked_source()` returns the baked
  SpriteFrames source.
  `validate_source_files()`
  checks original source-file fingerprints explicitly; runtime validation does
  not depend on editor files being present in an exported package. Serialized baked
  fields must survive ResourceSaver/ResourceLoader round trips.
- `MaskedSprite2D : Sprite2D`: native class retaining the built-in texture, region,
  sheet frame, and drawing properties. It does not require a SpriteFrames resource.
- `MaskedAnimatedSprite2D : AnimatedSprite2D`: native class retaining the built-in
  SpriteFrames editor and playback API.
  Both sprite classes expose properties `mask: PixelCollisionMask` and
  `collision_enabled: bool`, with no custom tags, object-type resource, or owner field.
  `place_meeting(at: Vector2, group: StringName) -> bool` and
  `instance_place(at: Vector2, group: StringName) -> Node2D` query
  an absolute global position without moving the source. A hit is the actual
  `MaskedSprite2D` or `MaskedAnimatedSprite2D`; a miss returns null.
  Groups are checked on the candidate sprite itself and self is excluded.
  `move_contact(direction: float, max_distance: float, group: StringName) -> void`
  requires an explicit Group and updates global position after a native search.
- `PixelCollision : Object`: native Engine singleton registered by the extension.
  It cannot be instantiated through ClassDB and requires no Node or Autoload.
  Sprites register/unregister on entering/leaving the SceneTree. Empty group
  matches all registered, enabled sprites. Hit selection is lowest registration
  order, independent of hash bucket order. Missing masks or unsupported transforms produce editor
  warnings; invalid masks are not silently replaced by rectangles.
  `sync()` explicitly refreshes state. `get_collider_count() -> int`.
  Collision queries are exposed on individual sprites; there is no bulk query API.

There is one global index, not per-parent collision scopes. Simultaneously loaded
scenes, CanvasLayers, Viewports, and registered SceneTrees share numeric global
coordinates without canvas conversion. Groups select independent target sets.
The index, parent watches, and mask cache clear when the last collider unregisters; extension
shutdown unregisters and frees the singleton. Detached nodes are never query
sources or targets. No `PixelCollisionWorld2D` class or `get_collision_world()`
accessor remains.

`instance_place` previously declared a `MaskedAnimatedSprite2D` return type.
Callers with that explicit result type must change it to `Node2D` or cast the
result with `as MaskedAnimatedSprite2D`. A cast to one concrete class returns null
when the other class is hit. Boolean queries and movement signatures are unchanged.

## Static sprite mask sources

`MaskedSprite2D` uses its normal Texture2D source, including AtlasTexture logical
dimensions and margins. Baking extracts the enabled `region_rect`, or the full
logical texture canvas when regions are disabled, then splits it into
`hframes * vframes` cells in row-major order. All cells belong to the `default`
animation. `frame` and `frame_coords` select the current mask without rebaking;
they are not part of the baked source signature. `CURRENT_FRAME` reads that cell,
`ANIMATION_UNION` reads their union, and `FIXED_FRAME` uses `fixed_frame` with
`fixed_animation == &"default"` for this texture source.

Cell dimensions must be positive integers. Enabled regions must have integer
coordinates and positive integer dimensions entirely within the logical texture
canvas. Reject fractional or out-of-bounds regions and layouts whose width or
height is not divisible by its corresponding frame count. A failed bake exposes
a clear error and cannot leave an old mask active for a mismatching source.

Static source validation compares the Texture resource identity, region settings,
and sheet layout. Nodes using the same texture and layout share a baked mask even
when their current frames differ. Source pixels are read only by explicit baking;
runtime validation and collision queries must not create a SpriteFrames resource
or download texture pixels. Texture or layout changes require rebaking. Existing
animated resource data remains loadable; the static source descriptor is serialized
with newly baked masks and survives ResourceSaver/ResourceLoader round trips.

An external mask should reference an external paired Texture2D, including the
AtlasTexture or ImageTexture resource itself, or both resources should remain
embedded in one scene. An external mask paired with an inline visual texture can
reload as distinct source objects. Normal cached loading shares paired external
resources. `CACHE_MODE_IGNORE_DEEP` deliberately bypasses that sharing across
dependencies; callers can restore the source identity with
`sprite.texture = mask.get_baked_texture()` after a native texture bake reload.
Equal layouts alone must not make two distinct textures interchangeable.

An explicit `source_frames` overrides either sprite class's visual source. For
`MaskedSprite2D`, `CURRENT_FRAME` and `ANIMATION_UNION` use the `default` animation
of that source, while `FIXED_FRAME` uses the configured `fixed_animation` and
`fixed_frame`. The independent mask keeps its own logical frame dimensions.

The editor plugin provides mask creation, baking, source validation, and collision
overlays for both classes, including mixed scenes. It uses `bake_sprite` for a
static sprite and `bake` for an animated sprite. Static sprites need only their
usual texture and the shared mask resource; no hidden per-instance SpriteFrames
object is required. The existing source-file fingerprint and export-validation
limitations apply to both source types.

## Collision semantics

Collision queries sample original baked occupancy at integer world coordinates,
clipped to inclusive integer bounds. No transformed occupancy bitmap is built in
the runtime query or transform-update path. The sampling and bounding-box rules
follow the audited local Runner where they map to Godot, without claiming full
GameMaker VM compatibility. Support finite, invertible 2D
affine bases: arbitrary rotation, positive and negative fractional scales, and
skew, in addition to translation and sprite flips. Use the full global basis,
including parent transforms; a nonuniformly scaled parent and rotated child can
produce skew even when neither node has an explicit skew property.
Masks use the selected source frame's logical dimensions and apply the sprite's
centered/offset settings plus mask_offset. Independent source frames retain their
own dimensions. Automatic masks and serialized baked data are shared across nodes.
Animation union requires equal logical frame dimensions within each animation.

Group changes are observed live using native Node.is_in_group checks on spatial
candidates. Do not enumerate entire SceneTree groups per query or mirror group
membership without synchronization. Queries and changes to registered sprites
must run on the main scene thread. Detached sprite changes do not access the
singleton index; their state is collected when they enter the tree. Exit-tree,
disabled, and queued-for-deletion sprites cannot be returned.
Movement/mask/frame changes must be visible to the next query in the same frame.
Parent transforms require explicit synchronization support, not a claim that
deferred global-transform notifications are immediate.

## On-demand transformed-mask sampling

Let the selected mask frame's logical canvas be `[0, w) x [0, h)`, `B` the
sprite's full global 2x2 basis, and `P` its proposed global position. Define the
local mask placement as:

```text
O = sprite.offset + mask.mask_offset - (centered ? (w / 2, h / 2) : (0, 0))
```

The logical collision bbox is the union of occupied source pixels across the
baked frames of the selected animation. Every `CURRENT_FRAME` record shares that
bbox but retains its own occupancy. `ANIMATION_UNION` and `FIXED_FRAME` already
use one baked record. The bbox is derived from the serialized pixels when loaded;
it does not require a new resource format or rebake. With unequal current-frame
dimensions, the shared bbox can extend beyond a selected frame's canvas. Source
sampling still checks that frame's actual dimensions.

### Integer world samples

For each integer point `W` in the intersection of the two collision bboxes:

```text
Q = trunc(P)                            # Each component, toward zero.
S = B.inverse() * (W - Q) - O
I = trunc(float32(S))                   # Each complete source coordinate.
```

Reject `I` outside `[0, w) x [0, h)`. If `follow_sprite_flip` is enabled, reflect
valid source indices with `w - 1 - I.x` and/or `h - 1 - I.y`, then read the
original bit-packed mask. A pair overlaps as soon as both reads are occupied at
the same `W`. Empty bbox intersections perform no pixel sampling.

There is no `+0.5` center offset, floor operation, or antialiasing. In particular,
a complete source coordinate strictly between `-1` and `0` truncates to pixel
zero; it must not be rejected as negative before conversion. Quantize the node
position separately from `O`, rather than truncating `P + B * O`. The inverse is
computed robustly in double precision; each resulting source coordinate is
converted to float32 before truncation.

### Logical collision bounds

Mirror the shared source bbox within the selected frame's canvas for each enabled
explicit sprite flip. Let its resulting inclusive bounds be `[L, R] x [T, D]`.
The full canvas may be used for conservative spatial indexing, but must not
replace these logical bounds in the precise overlap test.

An exactly diagonal basis (`B.xy == 0 && B.yx == 0`) uses the audited zero-angle
branch. For the x axis, with scale `sx = B.xx`:

```text
a = trunc(float32(float32((L + O.x) * sx) + P.x))
b = trunc(float32(float32((R - L + 1) * sx) + float32(a)))
left = min(a, b)
right = max(a, b) - 1
```

Apply the same formula to y. The second endpoint begins at the already-quantized
first endpoint; independently transforming both endpoints gives different results
at some signed fractional positions.

For other bases, transform the outer rectangle
`[L + O.x, R + 1 + O.x] x [T + O.y, D + 1 + O.y]`. Round each matrix product to
float32. For each output component, choose the minimum or maximum contributions
from the input x and y coordinates independently. Add those contributions to the
unquantized position in the audited native order:

```text
x_extreme = trunc(float32(float32(P.x + x_term) + y_term))
y_extreme = trunc(float32(float32(P.y + y_term) + x_term))
```

Here `x_term` and `y_term` are the corresponding output component's contributions
from input x and input y. Position is added first; x contributions precede y
contributions for output x, and y contributions precede x contributions for output
y. Combining the two contributions before adding position can change rounding.
The resulting minima are `left` and `top`; subtract one from the resulting maxima
for `right` and `bottom`. A quantized bbox can be empty even when the original
mask is nonempty.

Do not normalize near-cardinal basis residue or round transforms into angle
bins. Negative matrix scales follow these same formulas; replacing them with
preflipped bitmaps or adding a hidden one-pixel translation changes the result.
The spatial index conservatively covers the logical bounds for all explicit
flip states and the complete canvas, so a flip cannot hide a new hit behind a
stale candidate bbox. The precise test always uses the current flip's logical
bounds.

### Updates, limits, and preview

Cache only the original masks by resource, revision, and frame. A collider stores
its numeric basis, inverse, position, local offset, and bounds. Transform updates
do not allocate or fill transformed bitmaps. Movement probes reuse the prepared
inverse and recompute only position-dependent data. Identity bases with integer
local offsets and no explicit flips may use a 64-bit overlap path, clipped to
both logical bboxes so it agrees with the sampling rule. Their spatial query
bounds may also intersect the current frame's translated occupied bounds; this
excludes impossible candidates without changing the shared logical bbox.

Translation can change occupancy on the world grid because the bbox uses raw
position while source sampling uses truncated position. Downscaling can remove
all samples at one position and recover them at another. An empty logical bbox
does not invalidate the transform or prevent `move_contact` from moving an
otherwise nonempty baked mask.

Reject singular or nonfinite bases, nonfinite offsets and positions, and geometry
outside the supported coordinate range of `[-2^50, 2^50]`. Rejection must leave
no stale collider active and produce an editor configuration warning where
applicable. Original-mask allocations remain limited to 32,768 pixels per axis
and 67,108,864 pixels in total. There is no corresponding runtime limit on the
area of transformed bounds, since no transformed bitmap is allocated. The spatial
index has an oversized-entry fallback; a large intersecting region may still
require a long pixel scan, and queries must not silently omit samples to cap work.

The editor overlay explicitly samples the same view into a temporary preview
image. Its allocation is capped at 32,768 pixels per axis and 67,108,864 pixels in
total, independently of collision support. Its image cache must include position,
since changing position can change sampled pixels without changing the basis.
Preview allocation limits must not disable runtime collisions.

### Compatibility boundary

The audited local Runner performs on-demand inverse sampling, integer world
iteration, truncation, and separate bbox clipping. These establish the algorithm
and guide regression fixtures, but an exact-version GameMaker VM comparison has
not established bit-exact results. General Godot matrix composition, skew, the
robust double inverse followed by float32 conversion, explicit sprite flips,
and the per-animation bbox mapping are addon choices. A matrix cannot retain
GameMaker's original angle/scale parameterization, so the exact diagonal test
chooses the zero-angle branch even when another angle/scale pair could represent
the same transform. Historical conversion instructions and intermediate inverse
arithmetic remain compatibility questions rather than guaranteed parity.

## Contact movement

`move_contact` uses degrees with 0 right, 90 up, 180 left, and 270 down. Finite
angles wrap; cardinal vectors are exact. Positive distances truncate to whole
unit-vector steps; nonpositive distances select 1,000 steps. Positive distances
below one do not move. Nonfinite arguments or positive distances greater than
INT32_MAX report an error without changing position.

After synchronizing the singleton, require a valid, enabled, nonempty source
collider. Detached sources, missing masks, unsupported source geometry, queued
deletion, and a starting overlap all leave position unchanged. Test each successive
global position using the same group, self-exclusion, precise masks, and sampling
rules as `place_meeting`.
Stop before the first overlap, at the step limit, at the supported coordinate
boundary, or when float precision prevents further position changes or would
skip a pixel cell. For parented sprites, test each position after the parent's
inverse/forward transform round trip and commit the tested local position
directly. This avoids a final conversion rounding a clear position into a wall;
travel can stop earlier at unrepresentable coordinate boundaries.

The probe loop stays native and mutates no scene nodes. Apply only its final
position, so transform notifications occur once and the next query observes the
move. All other colliders, including source descendants, are queried at their
pre-move positions during this call. This operation does not change velocities,
dispatch events, or provide solid rollback, depenetration, or continuous sweeping.
The unit-step behavior is based on the audited local Runner; exact floating-point
parity with a particular GameMaker runtime remains separate validation work.

## Repository boundaries

- `src/core/`: standalone C++ pixel mask and dynamic spatial grid, no Godot headers.
- `src/godot/pixel_collision_mask.*`: Resource/baking/serialization.
- `src/godot/masked_sprite_2d.*`, `masked_animated_sprite_2d.*`, `pixel_collision.*`:
  sprite APIs and global manager.
- `addons/pixel_collision/`: editor plugin, extension descriptor, generated binary.
- `examples/`, `tests/`, `tools/`, `docs/`: runnable examples, verification, build tools.

All source comments and documentation are English. Original research source and
GameMaker assets remain outside this repository. godot-cpp is a pinned submodule.
