# Editor integration tests

Build the native Windows extension first, then run from the repository root:

```powershell
./tests/editor/run_editor_tests.ps1 -Godot D:/Godot/godot.exe
```

The launcher creates a unique project in the system temporary directory. It
copies the built addon and this test plugin there, starts the headless editor,
and retains the project plus `stdout.log` and `stderr.log` for inspection. It
does not open or modify this repository's project, examples, editor state, or
project settings. Do not manually enable the test plugin in a working project.

The launcher fails on a nonzero Godot exit status, a missing success marker, or
a timeout (90 seconds by default; override with `-TimeoutSeconds`). It terminates
only the Godot process it created if that timeout expires.

The test plugin runs 65 assertions against the actual editor addon and native
extension:

The fixture uses ordinary Node2D parents. No collision manager node or project
Autoload is needed for the inspector and baking workflow.

1. Pack an isolated fixture scene.
2. Save the fixture scene.
3. Locate the active collision editor plugin.
4. Create a mask through the inspector action.
5. Automatically bake a selected sprite's new mask.
6. Rebuild after a mask property change and debounce.
7. Detect an animation rename through structural polling.
8. Preserve the source frame's logical dimensions in the preview image.
9. Compute truncated logical bounds for an exact 90-degree basis with nonuniform
   fractional scale.
10. Inverse-sample integer world positions without a half-pixel offset.
11. Return bounds without allocating an image when only placement is needed.
12. Use native integer world bounds in the editor overlay.
13. Create an overlay texture with sampled region dimensions.
14. Reuse the overlay texture when its geometry is unchanged.
15. Replace the overlay texture after fractional translation changes its bounds.
16. Sample the translated region's exact expected pixels.
17. Check an exact 45-degree basis, including truncation of negative fractional
    inverse coordinates before source bounds checking.
18. Replace the overlay texture after basis or centering changes.
19. Apply horizontal sprite flip to sampled source indices.
20. Compose horizontal and vertical sprite flips.
21. Apply fractional local offsets after truncating the node position.
22. Invalidate the image cache when the sprite offset changes.
23. Clip negative-scale sampling to the logical bounding box.
24. Apply a parent's shear and fractional placement immediately.
25. Use the composed global transform in the editor cache.
26. Invalidate the image cache when a parent moves.
27. Reject singular geometry in the native preview helper.
28. Clear the editor's cached overlay when geometry becomes invalid.
29. Recreate the overlay after valid geometry is restored.
30. Clear the preview when the quantized logical region is empty.
31. Report an image allocation limit for large, otherwise valid geometry.
32. Preserve the bounding box outline when the image exceeds the preview limit.
33. Recreate the texture after returning from a limited preview.
34. Accept a valid scene in the before-run build hook.
35. Rebuild an unselected mask through the reimport callback.
36. Reject an invalid fixed animation in the before-run build hook.
37. Repair, rebake, and save the scene before running.

The remaining 28 assertions exercise `MaskedSprite2D` through the same editor
workflow. They cover selection and mask creation, automatic sheet baking without
an intermediate SpriteFrames resource, resource-inspector context, source and
world-space previews, and immediate `frame` / `frame_coords` changes without a
rebake. Changing the grid, region, or texture identity triggers a rebake and
refreshes the preview. Mixed scenes discover both sprite classes. Static sprites
can share a mask with different current frames but must share the source texture
and layout; an independent Source Frames resource allows sharing across both
classes. Reimport and before-run checks include unselected static sprites. Saving
and reloading a mixed scene retains the native class, shared mask, source identity,
and baked data.

The reimport assertion invokes the plugin's real callback with a synthetic
notification; it does not exercise Godot's complete texture import pipeline.
The export validation hook is also invoked, but this is not an export test.
The preview fixtures use explicit, hand-derived pixel sets and exact matrix
components; they do not generate expected results from collision queries or the
native preview helper. The overlay data path checks integer world sampling,
texture invalidation, and world placement directly. The preview image is an
editor-only allocation; it is not a runtime transformed-mask cache.
Viewport preview appearance, editor camera/canvas alignment,
and mouse interaction with the inspector require a separate visual check.

An invalid-mask error is intentionally emitted for assertion 36 and is preceded
by an `EXPECTED DIAGNOSTIC` line. With Godot 4.7.2 on Windows, the headless dummy
renderer also reports `Parameter "t" is null` from `texture_2d_get` when the save
hook creates an editor thumbnail. The latest run reported no RID, ObjectDB, or
resource shutdown leaks. These diagnostics do not replace the assertions or
success marker; inspect other errors and shutdown warnings separately.
