@tool
extends EditorPlugin

# The launcher copies this plugin into a temporary project. Never enable this
# test plugin in a user's working project: it creates and opens a fixture scene.
var _failures := 0
var _assertions := 0


func _enter_tree() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_assertions += 1
	if condition:
		print("PASS: " + message)
	else:
		_failures += 1
		push_error("FAIL: " + message)


func _find_collision_plugin() -> EditorPlugin:
	var pending: Array[Node] = [get_tree().root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		var script := node.get_script() as Script
		if script != null and script.resource_path == "res://addons/pixel_collision/plugin.gd":
			return node as EditorPlugin
		for child in node.get_children():
			pending.append(child)
	return null


func _preview_matches(data: Dictionary, rect: Rect2, occupied: Array[Vector2i]) -> bool:
	if data.get("rect") != rect:
		return false
	var image := data.get("image") as Image
	if image == null or image.get_size() != Vector2i(rect.size):
		return false
	for y in image.get_height():
		for x in image.get_width():
			if (image.get_pixel(x, y).a > 0.0) != (Vector2i(x, y) in occupied):
				return false
	return true


func _check_affine_preview(plugin: EditorPlugin, sprite: AnimatedSprite2D) -> void:
	var saved_transform := sprite.transform
	var parent := sprite.get_parent() as Node2D
	var saved_parent_transform := parent.transform
	# Exact basis components keep these hand-derived fixtures independent of
	# trigonometric residue. Source pixels are (0,0), (2,1), and (4,2).
	sprite.transform = Transform2D(Vector2(0, 1.5), Vector2(-0.5, 0), Vector2(12.25, 20.75))
	var native: Dictionary = sprite.call("_get_collision_preview")
	var expected_rect := Rect2(11, 17, 2, 7)
	_check(native.get("rect") == expected_rect, "Rotated fractional-scale preview uses truncated logical bounds")
	_check(_preview_matches(native, expected_rect, [Vector2i(1, 3)]), "Preview inverse-samples integer world points without a half-pixel offset")
	var bounds_only: Dictionary = sprite.call("_get_collision_preview", false)
	_check(bounds_only.get("rect") == expected_rect and not bounds_only.has("image"), "Bounds-only preview omits image allocation")
	var overlay: Dictionary = plugin.call("_update_preview_data")
	var texture := overlay.get("texture") as Texture2D
	_check(overlay.get("rect") == expected_rect and texture != null, "Editor overlay consumes native integer world bounds")
	_check(texture != null and texture.get_size() == Vector2(2, 7), "Editor texture uses sampled bounds rather than source dimensions")
	var unchanged: Dictionary = plugin.call("_update_preview_data")
	_check(unchanged.get("texture") == texture, "Unchanged geometry reuses the editor preview texture")
	sprite.position.x = 12.75
	var moved: Dictionary = plugin.call("_update_preview_data")
	_check(moved.get("texture") != null and moved.get("texture") != texture and moved.get("rect") == Rect2(12, 17, 1, 7), "Fractional translation replaces the preview when clipped bounds change")
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(12, 17, 1, 7), [Vector2i(0, 3)]), "Translated preview uses the new integer world sampling region")

	sprite.centered = false
	sprite.transform = Transform2D(Vector2(1, 1), Vector2(-1, 1), Vector2(10.25, 20.75))
	var rotated_pixels: Array[Vector2i] = [Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0), Vector2i(3, 1), Vector2i(4, 3), Vector2i(4, 4), Vector2i(5, 6), Vector2i(5, 7)]
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(7, 20, 8, 8), rotated_pixels), "A 45-degree basis truncates inverse coordinates before checking source bounds")
	var rotated: Dictionary = plugin.call("_update_preview_data")
	_check(rotated.get("texture") != null and rotated.get("texture") != moved.get("texture") and rotated.get("rect") == Rect2(7, 20, 8, 8), "Basis and centering changes replace the cached preview")

	sprite.transform = Transform2D(Vector2.RIGHT, Vector2.DOWN, Vector2(10.25, 20.75))
	sprite.flip_h = true
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(10, 20, 5, 3), [Vector2i(4, 0), Vector2i(2, 1), Vector2i(0, 2)]), "Horizontal sprite flip reflects sampled source indices")
	sprite.flip_v = true
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(10, 20, 5, 3), [Vector2i(0, 0), Vector2i(2, 1), Vector2i(4, 2)]), "Vertical sprite flip composes with horizontal flip")
	sprite.flip_h = false
	sprite.flip_v = false
	var unshifted: Dictionary = plugin.call("_update_preview_data")
	sprite.offset = Vector2(0.5, 0)
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(10, 20, 5, 3), [Vector2i(0, 0), Vector2i(1, 0), Vector2i(3, 1)]), "Fractional local offsets are applied after node-position truncation")
	var shifted: Dictionary = plugin.call("_update_preview_data")
	_check(shifted.get("texture") != null and shifted.get("texture") != unshifted.get("texture"), "Local offset changes invalidate the editor image cache")
	sprite.offset = Vector2.ZERO
	sprite.transform = Transform2D(Vector2.LEFT, Vector2.DOWN, Vector2(10.25, 20.75))
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(5, 20, 5, 3), [Vector2i(3, 1), Vector2i(1, 2)]), "Negative scaling clips source pixels using the logical bounding box")

	parent.transform = Transform2D(Vector2.RIGHT, Vector2(0.5, 1), Vector2(20.25, 30.75))
	sprite.transform = Transform2D(Vector2.RIGHT, Vector2.DOWN, Vector2(2, 3))
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(23, 33, 7, 3), [Vector2i(0, 0), Vector2i(3, 1), Vector2i(5, 2)]), "Parent shear and fractional placement affect preview sampling immediately")
	var parented: Dictionary = plugin.call("_update_preview_data")
	_check(parented.get("texture") != null and parented.get("rect") == Rect2(23, 33, 7, 3), "Editor cache uses the composed global transform")
	parent.position.x += 0.5
	var parent_moved: Dictionary = plugin.call("_update_preview_data")
	_check(parent_moved.get("texture") != null and parent_moved.get("texture") != parented.get("texture") and parent_moved.get("rect") == Rect2(24, 33, 6, 3), "Parent translation invalidates the cached preview image")
	parent.transform = saved_parent_transform
	sprite.centered = true
	# Node2D clamps zero scale properties to epsilon; assign a singular basis.
	sprite.transform = Transform2D(Vector2.ZERO, Vector2.ZERO, sprite.position)
	var invalid: Dictionary = sprite.call("_get_collision_preview")
	_check(invalid.is_empty(), "Singular transforms have no native collision preview")
	var invalid_overlay: Dictionary = plugin.call("_update_preview_data")
	_check(invalid_overlay.is_empty() and plugin.get("_preview") == null, "Invalid geometry clears the cached editor overlay")
	sprite.transform = saved_transform
	var restored: Dictionary = plugin.call("_update_preview_data")
	_check(not restored.is_empty() and restored.get("texture") != null, "Restoring valid geometry recreates the editor overlay")
	sprite.scale = Vector2(0.1, 0.1)
	var empty_preview: Dictionary = sprite.call("_get_collision_preview")
	var empty_rect: Rect2 = empty_preview.get("rect", Rect2())
	var empty_overlay: Dictionary = plugin.call("_update_preview_data")
	_check((empty_rect.size.x <= 0.0 or empty_rect.size.y <= 0.0) and empty_overlay.is_empty(), "An empty quantized logical region clears the preview")
	sprite.transform = Transform2D(Vector2(10000, 0), Vector2(0, 10000), Vector2.ZERO)
	var oversized: Dictionary = sprite.call("_get_collision_preview")
	_check(oversized.get("rect") == Rect2(-25000, -15000, 50000, 30000) and bool(oversized.get("preview_limited", false)) and not oversized.has("image"), "Large valid geometry reports preview limits without allocating a bitmap")
	var limited_overlay: Dictionary = plugin.call("_update_preview_data")
	_check(limited_overlay.get("rect") == oversized.get("rect") and bool(limited_overlay.get("preview_limited", false)) and limited_overlay.get("texture") == null, "A preview allocation limit preserves the logical bounds outline")
	sprite.transform = saved_transform
	var final_overlay: Dictionary = plugin.call("_update_preview_data")
	_check(final_overlay.get("texture") != null and not bool(final_overlay.get("preview_limited", false)), "Returning from a limited preview recreates its texture")


func _check_static_editor(plugin: EditorPlugin, animated: AnimatedSprite2D) -> void:
	var edited_root := EditorInterface.get_edited_scene_root()
	var image := Image.create(6, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.set_pixel(0, 0, Color.WHITE)
	image.set_pixel(5, 1, Color.WHITE)
	var sheet := ImageTexture.create_from_image(image)
	var sprite := ClassDB.instantiate("MaskedSprite2D") as Sprite2D
	sprite.name = "StaticSprite"
	sprite.texture = sheet
	sprite.hframes = 2
	sprite.centered = false
	sprite.position = Vector2(100, 50)
	edited_root.add_child(sprite)
	sprite.owner = edited_root
	_check(bool(plugin.call("_handles", sprite)), "Inspector and editor selection support MaskedSprite2D")
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(sprite)
	plugin.call("create_mask", sprite)
	await get_tree().create_timer(0.7).timeout
	var mask := sprite.get("mask") as Resource
	_check(mask != null, "Static sprite inspector action creates a native mask")
	if mask == null:
		return
	_check(bool(mask.call("is_baked_for_sprite", sprite)) and mask.get("source_frames") == null, "Static sheets bake automatically without generating SpriteFrames")
	_check(String(plugin.call("status_for", mask)).begins_with("Baked."), "Selected static sprite supplies context to its mask inspector")
	var raw: Image = mask.call("get_preview_image_for_sprite", sprite)
	_check(raw != null and raw.get_size() == Vector2i(3, 2) and raw.get_pixel(0, 0).a > 0.0 and raw.get_pixel(2, 1).a == 0.0, "Static mask preview uses the selected sheet cell")
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(100, 50, 3, 2), [Vector2i.ZERO]), "Static native preview shares logical sheet bounds across frames")
	var initial: Dictionary = plugin.call("_update_preview_data")
	_check(initial.get("texture") != null and initial.get("rect") == Rect2(100, 50, 3, 2), "Static sprite appears in the editor mask overlay")
	var revision: int = mask.call("get_revision")
	sprite.frame = 1
	await get_tree().create_timer(0.7).timeout
	_check(mask.call("get_revision") == revision, "Changing a static sprite frame does not rebake its sheet")
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(100, 50, 3, 2), [Vector2i(2, 1)]), "Static frame changes update preview occupancy immediately")
	var next_frame: Dictionary = plugin.call("_update_preview_data")
	_check(next_frame.get("texture") != null and next_frame.get("texture") != initial.get("texture"), "Static frame changes invalidate the editor texture")
	sprite.frame_coords = Vector2i.ZERO
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(100, 50, 3, 2), [Vector2i.ZERO]) and mask.call("get_revision") == revision, "Frame coordinates update occupancy without rebaking")
	sprite.hframes = 3
	await get_tree().create_timer(0.7).timeout
	raw = mask.call("get_preview_image_for_sprite", sprite)
	_check(bool(mask.call("is_baked_for_sprite", sprite)) and raw != null and raw.get_size() == Vector2i(2, 2), "Sheet layout changes trigger an automatic rebake")
	sprite.hframes = 1
	sprite.region_enabled = true
	sprite.region_rect = Rect2(3, 0, 3, 2)
	await get_tree().create_timer(0.7).timeout
	raw = mask.call("get_preview_image_for_sprite", sprite)
	_check(bool(mask.call("is_baked_for_sprite", sprite)) and raw != null and raw.get_size() == Vector2i(3, 2) and raw.get_pixel(2, 1).a > 0.0, "Enabling a static region rebakes its cropped source")
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(102, 51, 1, 1), [Vector2i.ZERO]), "Region previews use cropped local coordinates and occupied bounds")
	var right_region: Dictionary = plugin.call("_update_preview_data")
	sprite.region_rect.position = Vector2.ZERO
	await get_tree().create_timer(0.7).timeout
	var left_region: Dictionary = plugin.call("_update_preview_data")
	_check(_preview_matches(sprite.call("_get_collision_preview"), Rect2(100, 50, 1, 1), [Vector2i.ZERO]) and left_region.get("texture") != right_region.get("texture"), "Editing region placement rebakes and refreshes the overlay")
	var replacement_image := Image.create(6, 2, false, Image.FORMAT_RGBA8)
	replacement_image.fill(Color.TRANSPARENT)
	replacement_image.set_pixel(1, 1, Color.WHITE)
	sprite.texture = ImageTexture.create_from_image(replacement_image)
	await get_tree().create_timer(0.7).timeout
	_check(bool(mask.call("is_baked_for_sprite", sprite)) and _preview_matches(sprite.call("_get_collision_preview"), Rect2(101, 51, 1, 1), [Vector2i.ZERO]), "Replacing an inline static texture with equal dimensions rebakes pixels")
	sprite.texture = sheet
	sprite.region_enabled = false
	sprite.hframes = 2
	await get_tree().create_timer(0.7).timeout
	var twin := ClassDB.instantiate("MaskedSprite2D") as Sprite2D
	twin.name = "SharedStaticSprite"
	twin.texture = sheet
	twin.hframes = 2
	twin.frame = 1
	twin.set("mask", mask)
	edited_root.add_child(twin)
	twin.owner = edited_root
	var validation: Dictionary = plugin.call("_validate_current_scene", false)
	var sprites: Array = plugin.call("_sprites_in_scene", edited_root)
	_check(validation.errors.is_empty() and sprites.size() == 3, "Scene validation discovers animated and static sprites together")
	_check(bool(mask.call("is_baked_for_sprite", twin)), "Static sprites share a baked sheet while selecting different frames")
	twin.hframes = 1
	validation = plugin.call("_validate_current_scene", false)
	_check(str(validation.errors).contains("shares a mask"), "Shared-mask validation rejects differing static sheet layouts")
	twin.hframes = 2
	twin.texture = ImageTexture.create_from_image(image)
	validation = plugin.call("_validate_current_scene", false)
	_check(str(validation.errors).contains("shares a mask"), "Shared-mask validation rejects distinct static source textures")
	twin.texture = sheet
	var animated_mask := animated.get("mask") as Resource
	var independent := SpriteFrames.new()
	independent.add_frame(&"default", sheet)
	mask.set("source_frames", independent)
	mask.set("frame_mode", 2)
	mask.set("fixed_animation", &"default")
	animated.set("mask", mask)
	_check(bool(plugin.call("bake_target", mask)), "Mask inspector bakes a static sprite's independent source")
	validation = plugin.call("_validate_current_scene", false)
	_check(validation.errors.is_empty(), "Independent Source Frames can share one mask across both sprite classes")
	animated.set("mask", animated_mask)
	mask.set("source_frames", null)
	mask.set("frame_mode", 0)
	_check(bool(plugin.call("bake_target", sprite)), "Static sprite returns to its own sheet source after clearing the override")
	EditorInterface.get_selection().clear()
	mask.set("alpha_threshold", 0.4)
	plugin.call("_resources_reimported", PackedStringArray(["res://static_fixture.png"]))
	_check(bool(mask.call("is_baked_for_sprite", sprite)), "Reimport callback rebakes unselected static masks")
	_check(bool(plugin.call("_build")), "Before-run validation accepts a mixed sprite scene")
	plugin.call("validate_export_scene")
	var packed := PackedScene.new()
	_check(packed.pack(edited_root) == OK and ResourceSaver.save(packed, "res://mixed_fixture.tscn") == OK, "Save a mixed scene with a shared static mask")
	var reloaded := ResourceLoader.load("res://mixed_fixture.tscn", "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var restored := reloaded.instantiate() if reloaded != null else null
	_check(restored != null and restored.get_node("StaticSprite").is_class("MaskedSprite2D"), "Reload restores the native static sprite class")
	if restored != null:
		var restored_sprite := restored.get_node("StaticSprite") as Sprite2D
		var restored_twin := restored.get_node("SharedStaticSprite") as Sprite2D
		var restored_mask := restored_sprite.get("mask") as Resource
		_check(restored_mask == restored_twin.get("mask") and bool(restored_mask.call("is_baked_for_sprite", restored_sprite)) and bool(restored_mask.call("is_baked_for_sprite", restored_twin)), "Reload preserves shared static mask data and source identity")
		restored.free()


func _run() -> void:
	# Plugin initialization happens during the editor's initial filesystem scan.
	await get_tree().create_timer(0.8).timeout
	while EditorInterface.get_resource_filesystem().is_scanning():
		await get_tree().process_frame
	if not ClassDB.class_exists("MaskedAnimatedSprite2D") or not ClassDB.class_exists("MaskedSprite2D"):
		_check(false, "Native extension is loaded")
		_finish.call_deferred()
		return

	var image := Image.create(5, 3, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for pixel in [Vector2i(0, 0), Vector2i(2, 1), Vector2i(4, 2)]:
		image.set_pixelv(pixel, Color.WHITE)
	var frames := SpriteFrames.new()
	frames.add_frame(&"default", ImageTexture.create_from_image(image))
	var root := Node2D.new()
	root.name = "EditorTestRoot"
	var container := Node2D.new()
	container.name = "Container"
	root.add_child(container)
	container.owner = root
	var source := ClassDB.instantiate("MaskedAnimatedSprite2D") as AnimatedSprite2D
	source.name = "Sprite"
	source.sprite_frames = frames
	container.add_child(source)
	source.owner = root
	var packed := PackedScene.new()
	_check(packed.pack(root) == OK, "Pack fixture scene")
	_check(ResourceSaver.save(packed, "res://editor_fixture.tscn") == OK, "Save fixture scene")
	root.free()

	EditorInterface.open_scene_from_path("res://editor_fixture.tscn")
	for frame in 8:
		await get_tree().process_frame
	var plugin := _find_collision_plugin()
	_check(plugin != null, "Find active collision editor plugin")
	if plugin == null:
		_finish.call_deferred()
		return
	var edited_root := EditorInterface.get_edited_scene_root()
	if edited_root == null or not edited_root.has_node("Container/Sprite"):
		_check(false, "Open fixture scene in editor")
		_finish.call_deferred()
		return
	var sprite := edited_root.get_node("Container/Sprite") as AnimatedSprite2D
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(sprite)
	plugin.call("create_mask", sprite)
	await get_tree().create_timer(0.7).timeout
	var mask := sprite.get("mask") as Resource
	_check(mask != null, "Inspector action creates native mask")
	if mask == null:
		_finish.call_deferred()
		return
	_check(mask.call("is_baked_for", sprite.sprite_frames), "Selected mask automatically bakes")

	mask.set("alpha_threshold", 0.4)
	await get_tree().create_timer(0.7).timeout
	_check(mask.call("is_baked_for", sprite.sprite_frames), "Configuration changes debounce and rebake")
	sprite.sprite_frames.rename_animation(&"default", &"walk")
	sprite.animation = &"walk"
	await get_tree().create_timer(0.7).timeout
	_check(mask.call("is_baked_for", sprite.sprite_frames), "Animation rename structural polling rebakes")
	var preview: Image = mask.call("get_preview_image", sprite.sprite_frames, &"walk", 0)
	_check(preview != null and preview.get_size() == Vector2i(5, 3), "Preview retains logical source dimensions")
	_check_affine_preview(plugin, sprite)
	_check(plugin.call("_build"), "Before-run validation accepts baked scene")

	EditorInterface.get_selection().clear()
	mask.set("alpha_threshold", 0.6)
	# Call the real reimport callback with a synthetic event. No real texture
	# importer is required for this assertion about scene rebaking behavior.
	plugin.call("_resources_reimported", PackedStringArray(["res://fixture.png"]))
	_check(mask.call("is_baked_for", sprite.sprite_frames), "Reimport callback rebakes unselected scene mask")
	plugin.call("validate_export_scene")

	mask.set("frame_mode", 2)
	mask.set("fixed_animation", &"missing")
	print("EXPECTED DIAGNOSTIC: invalid fixed animation must prevent running.")
	_check(not plugin.call("_build"), "Before-run validation rejects invalid mask")
	mask.set("fixed_animation", &"walk")
	_check(plugin.call("_build"), "Before-run validation rebakes and saves repaired mask")
	await _check_static_editor(plugin, sprite)
	_finish.call_deferred()


func _finish() -> void:
	print("EDITOR TESTS: %d assertions, %d failures" % [_assertions, _failures])
	get_tree().quit(0 if _failures == 0 and _assertions == 65 else 1)
