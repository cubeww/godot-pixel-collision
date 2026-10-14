extends RefCounted
## Sprite2D-specific integration checks, invoked by run_tests.gd.

const SPRITE_CLASS := &"MaskedSprite2D"
const ANIMATED_CLASS := &"MaskedAnimatedSprite2D"
const MASK_CLASS := &"PixelCollisionMask"
const CURRENT_FRAME := 0
const ANIMATION_UNION := 1
const FIXED_FRAME := 2

var suite: SceneTree


func run(test_suite: SceneTree) -> void:
	suite = test_suite
	_test_contract()
	_test_plain_texture_and_geometry()
	_test_atlas_texture()
	_test_groups_order_and_lifetime()
	_test_cells_and_regions()
	_test_region_recovery()
	_test_frame_modes()
	_test_independent_source()
	_test_invalidation()
	_test_invalid_layouts()
	_test_movement()
	_test_serialization()
	_test_external_serialization()


func _check(condition: bool, description: String) -> void:
	suite._check(condition, description)


func _texture(rows: Array) -> Texture2D:
	return suite._frames([rows]).get_frame_texture(&"default", 0)


func _sprite(parent: Node, texture: Texture2D, at := Vector2.ZERO,
		group: StringName = &"", configuration: Dictionary = {}) -> Sprite2D:
	var result: Sprite2D = ClassDB.instantiate(SPRITE_CLASS)
	result.texture = texture
	result.centered = false
	result.position = at
	for property in configuration:
		result.set(property, configuration[property])
	if not group.is_empty():
		result.add_to_group(group)
	parent.add_child(result)
	return result


func _bake(sprite: Sprite2D, configuration: Dictionary = {}) -> Resource:
	var mask: Resource = ClassDB.instantiate(MASK_CLASS)
	for property in configuration:
		mask.set(property, configuration[property])
	_check(mask.bake_sprite(sprite) == OK, "Sprite2D mask bakes explicitly")
	_check(mask.is_baked_for_sprite(sprite), "Sprite2D mask validates against its visual source")
	sprite.mask = mask
	return mask


func _meeting(source: Node2D, at: Vector2, expected: bool, description: String,
		group: StringName = &"solid") -> void:
	_check(source.place_meeting(at, group) == expected, description)


func _test_contract() -> void:
	var sprite: Sprite2D = ClassDB.instantiate(SPRITE_CLASS)
	_check(sprite is Sprite2D, "MaskedSprite2D inherits the built-in Sprite2D API")
	for name in [&"place_meeting", &"instance_place", &"move_contact"]:
		_check(sprite.has_method(name), "MaskedSprite2D exposes %s" % name)
	for native_class in [SPRITE_CLASS, ANIMATED_CLASS]:
		var instance: Node2D = ClassDB.instantiate(native_class)
		for method in instance.get_method_list():
			if method.name == &"instance_place":
				_check(method["return"].class_name == &"Node2D",
					"%s instance_place declares a mixed-sprite Node2D result" % native_class)
			elif method.name == &"move_contact":
				_check(method.args.size() == 3 and method.default_args.is_empty(),
					"%s move_contact retains its explicit Group argument" % native_class)
		instance.free()
	var mask: Resource = ClassDB.instantiate(MASK_CLASS)
	for name in [&"bake_sprite", &"is_baked_for_sprite", &"get_preview_image_for_sprite", &"get_baked_texture"]:
		_check(mask.has_method(name), "Mask resource exposes static sprite authoring method %s" % name)
	_check(sprite.collision_enabled and sprite.mask == null,
		"Static sprites start enabled and require an explicit mask")
	sprite.free()


func _test_plain_texture_and_geometry() -> void:
	var scene: Node2D = suite._scene()
	var probe: AnimatedSprite2D = suite._probe(scene)
	var target := _sprite(scene, _texture(["###", "#.#", "###"]), Vector2(10, 10), &"solid")
	var initial_mask := _bake(target)
	_check(initial_mask.get_baked_texture() == target.texture,
		"Texture-native masks expose their original shared baked Texture2D")
	suite._footprint(probe, Vector2(10, 10), ["###", "#.#", "###"],
		"A plain Sprite2D texture retains its pixel cavity")
	_check(probe.instance_place(Vector2(10, 10), &"solid") == target,
		"An animated query returns the actual static target node")
	_meeting(target, target.global_position, false, "Static query excludes its own collider")
	target.texture = _texture(["#..", "..."])
	var mask := _bake(target)
	target.offset = Vector2(2, 3)
	_meeting(probe, Vector2(12, 13), true, "Sprite2D offset changes collision placement immediately")
	_meeting(probe, Vector2(10, 10), false, "Sprite2D offset removes the old occupied location")
	target.offset = Vector2.ZERO
	target.centered = true
	_meeting(probe, Vector2(8, 9), true, "Sprite2D centering follows the selected mask canvas")
	target.centered = false
	target.flip_h = true
	_meeting(probe, Vector2(12, 10), true, "Sprite2D horizontal flip updates native occupancy immediately")
	target.flip_v = true
	_meeting(probe, Vector2(12, 11), true, "Sprite2D vertical flip updates native occupancy immediately")
	mask.follow_sprite_flip = false
	_meeting(probe, Vector2(10, 10), true, "Static mask can ignore both visual flips")
	mask.follow_sprite_flip = true
	target.flip_h = false
	target.flip_v = false
	target.scale = Vector2(2, 3)
	_meeting(probe, Vector2(11, 12), true, "Sprite2D integer scaling samples enlarged opaque pixels")
	_meeting(probe, Vector2(12, 12), false, "Sprite2D integer scaling retains transparency")
	target.texture = _texture(["#.", ".#"])
	_bake(target)
	target.scale = Vector2(1.5, 1.5)
	suite._footprint(probe, Vector2(10, 10), ["##.", "##.", "..#"],
		"Sprite2D fractional scaling uses original-mask sampling")
	target.texture = _texture(["##", "##"])
	_bake(target)
	target.scale = Vector2.ONE
	target.rotation_degrees = 45.0
	suite._footprint(probe, Vector2(8, 10), [".##", ".##"],
		"Sprite2D arbitrary rotation uses the existing integer-world rules")
	target.position = Vector2(10.75, 10.25)
	suite._footprint(probe, Vector2(9, 10), ["###", "###", ".#."],
		"Static subpixel translation updates rotated sample phase immediately")
	scene.free()


func _test_groups_order_and_lifetime() -> void:
	var scene: Node2D = suite._scene()
	var texture := _texture(["#"])
	var source := _sprite(scene, texture)
	var shared := _bake(source)
	var first := _sprite(scene, texture, Vector2(10, 0), &"solid")
	first.mask = shared
	_check(shared.is_baked_for_sprite(first), "Identical Texture2D and cell layout share a baked static mask")
	var frames: SpriteFrames = suite._frames([["#"]])
	var second: AnimatedSprite2D = suite._sprite(scene, frames, suite._mask(frames), Vector2(10, 0), &"solid")
	_check(suite.collision.get_collider_count() == 3, "Both sprite types share the singleton registration count")
	_check(source.instance_place(Vector2(10, 0), &"solid") == first,
		"Mixed target selection follows registration order across node types")
	first.remove_from_group(&"solid")
	_check(source.instance_place(Vector2(10, 0), &"solid") == second,
		"Static queries observe a static target leaving a Group immediately")
	_check(source.instance_place(Vector2(10, 0), &"") == first,
		"Empty Group matches static and animated targets in registration order")
	first.add_to_group(&"solid")
	first.collision_enabled = false
	_check(source.instance_place(Vector2(10, 0), &"solid") == second,
		"Disabled static targets cannot hide later animated targets")
	first.collision_enabled = true
	scene.remove_child(first)
	_check(suite.collision.get_collider_count() == 2, "Static exit-tree removes its native registration")
	_check(source.instance_place(Vector2(10, 0), &"solid") == second,
		"A detached static target is excluded in the same frame")
	_meeting(first, Vector2(10, 0), false, "A detached static source cannot query live targets")
	scene.add_child(first)
	_check(source.instance_place(Vector2(10, 0), &"solid") == second,
		"Re-entering static targets receive a later registration order")
	second.queue_free()
	_check(source.instance_place(Vector2(10, 0), &"solid") == first,
		"Queued animated targets are excluded from static queries immediately")
	first.queue_free()
	_meeting(source, Vector2(10, 0), false, "Queued static targets are excluded immediately")
	scene.free()
	_check(suite.collision.get_collider_count() == 0, "Mixed scene destruction clears both collider types")


func _test_atlas_texture() -> void:
	var scene: Node2D = suite._scene()
	var probe: AnimatedSprite2D = suite._probe(scene)
	var atlas := AtlasTexture.new()
	atlas.atlas = _texture(["..#", ".#."])
	atlas.region = Rect2(1, 0, 2, 2)
	atlas.margin = Rect2(1, 1, 2, 2)
	var target := _sprite(scene, atlas, Vector2(10, 10), &"solid")
	_bake(target)
	suite._footprint(probe, Vector2(10, 10), ["....", "..#.", ".#..", "...."],
		"Static AtlasTexture masks retain region pixels and logical margins")
	scene.free()


func _test_cells_and_regions() -> void:
	var scene: Node2D = suite._scene()
	var probe: AnimatedSprite2D = suite._probe(scene)
	var texture := _texture(["..#..#..", "........", "..##....", ".....#.."])
	var layout := {"region_enabled": true, "region_rect": Rect2(2, 0, 4, 4), "hframes": 2, "vframes": 2}
	var target := _sprite(scene, texture, Vector2(10, 10), &"solid", layout)
	var mask := _bake(target)
	suite._footprint(probe, Vector2(10, 10), ["#.", ".."], "Static region and cells select frame zero")
	target.frame = 1
	suite._footprint(probe, Vector2(10, 10), [".#", ".."], "Static frame changes use row-major cells immediately")
	target.frame_coords = Vector2i(1, 1)
	_check(target.frame == 3, "Sprite2D frame_coords selects the inherited row-major frame")
	suite._footprint(probe, Vector2(10, 10), ["..", ".#"], "Static frame_coords changes update collision immediately")
	target.frame = 2
	suite._footprint(probe, Vector2(10, 10), ["##", ".."], "Static vertical sheet cells preserve their pixels")
	var preview: Image = mask.get_preview_image_for_sprite(target)
	_check(preview != null and preview.get_size() == Vector2i(2, 2),
		"Static source preview uses logical cell dimensions")
	if preview != null:
		_check(preview.get_pixel(1, 0).a > 0 and preview.get_pixel(1, 1).a == 0,
			"Static source preview follows the selected frame occupancy")
	var same := _sprite(scene, texture, Vector2(30, 10), &"solid", layout)
	same.mask = mask
	same.frame = 1
	_check(mask.is_baked_for_sprite(same), "The selected frame is excluded from shared-source identity")
	_meeting(probe, Vector2(31, 10), true, "Shared static masks retain independent per-node frame selections")
	_meeting(probe, Vector2(10, 10), true, "Changing a peer frame does not change another static node")
	target.region_enabled = false
	_check(not mask.is_baked_for_sprite(target), "Unsignaled region_enabled changes invalidate static source layout")
	_meeting(probe, Vector2(10, 10), false, "Unsignaled region toggle removes stale collider data immediately")
	target.region_enabled = true
	_meeting(probe, Vector2(10, 10), true, "Restoring region_enabled recovers the matching baked source immediately")
	target.hframes = 1
	_meeting(probe, Vector2(10, 10), false, "Changing sheet columns cannot reuse stale cell geometry")
	target.hframes = 2
	target.frame = 2
	_meeting(probe, Vector2(10, 10), true, "Restoring sheet layout recovers its original baked geometry")
	scene.free()


func _test_frame_modes() -> void:
	var scene: Node2D = suite._scene()
	var probe: AnimatedSprite2D = suite._probe(scene)
	var texture := _texture(["#..#"])
	var target := _sprite(scene, texture, Vector2(10, 10), &"solid", {"hframes": 2})
	_bake(target, {"frame_mode": ANIMATION_UNION})
	target.frame = 1
	suite._footprint(probe, Vector2(10, 10), ["##"], "Static union combines all sheet cells")
	_bake(target, {"frame_mode": FIXED_FRAME, "fixed_frame": 1})
	target.frame = 0
	suite._footprint(probe, Vector2(10, 10), [".#"], "Static fixed mode ignores visual frame playback")
	var invalid: Resource = ClassDB.instantiate(MASK_CLASS)
	invalid.frame_mode = FIXED_FRAME
	invalid.fixed_animation = &"missing"
	_check(invalid.bake_sprite(target) != OK, "Texture-native fixed masks reject nonexistent animation names")
	invalid.fixed_animation = &"default"
	invalid.fixed_frame = 2
	_check(invalid.bake_sprite(target) != OK, "Static fixed mode rejects frames outside the sheet")
	scene.free()


func _test_region_recovery() -> void:
	var scene: Node2D = suite._scene()
	var probe: AnimatedSprite2D = suite._probe(scene)
	var detached := Node2D.new()
	var target := _sprite(detached, _texture([".#"]), Vector2(60, 10), &"solid",
		{"region_enabled": true, "region_rect": Rect2(1, 0, 1, 1)})
	_bake(target)
	target.region_enabled = false
	scene.add_child(detached)
	_meeting(probe, Vector2(60, 10), false, "Static sprites can enter the tree with mismatched source layout")
	target.region_enabled = true
	_meeting(probe, Vector2(60, 10), true,
		"An unrelated animated query discovers an initially invalid static target after region recovery")
	target.set_region_enabled(false)
	_meeting(probe, Vector2(60, 10), false, "Direct native region setter removes a static collider immediately")
	target.set_region_enabled(true)
	_meeting(probe, Vector2(60, 10), true, "Direct native region setter restores target discovery immediately")
	var dormant := _sprite(scene, _texture(["#.#"]), Vector2(80, 10), &"solid",
		{"region_rect": Rect2(0, 0, 1, 1)})
	var mask := _bake(dormant)
	dormant.region_rect = Rect2(2, 0, 1, 1)
	_check(mask.is_baked_for_sprite(dormant), "Inactive region rectangles do not change static source identity")
	_meeting(probe, Vector2(82, 10), true, "Inactive region edits retain full-texture collision geometry")
	dormant.region_enabled = true
	_meeting(probe, Vector2(82, 10), false, "Activating an edited region rejects the old full-texture mask")
	_check(mask.bake_sprite(dormant) == OK, "An activated region can be explicitly rebaked")
	_meeting(probe, Vector2(80, 10), true, "Rebaking an activated region moves its texture pixel into local cell coordinates")
	scene.free()


func _test_independent_source() -> void:
	var scene: Node2D = suite._scene()
	var probe: AnimatedSprite2D = suite._probe(scene)
	var target := _sprite(scene, _texture(["####"]), Vector2(10, 10), &"solid", {"hframes": 2})
	var frames: SpriteFrames = suite._frames([["#.."], ["..#"]])
	var mask := _bake(target, {"source_frames": frames})
	_check(mask.get_baked_texture() == null, "Independent SpriteFrames masks do not expose a visual baked texture")
	target.frame = 1
	suite._footprint(probe, Vector2(10, 10), ["..#"], "Independent static mask uses default animation and visual frame index")
	target.texture = null
	target.region_enabled = true
	target.region_rect = Rect2(0.5, -8, 0, 1)
	_check(mask.is_baked_for_sprite(target), "Independent source validation ignores missing visual texture and invalid visual region")
	_meeting(probe, Vector2(12, 10), true, "Independent static masks remain active without a visual texture")
	frames.add_animation(&"collision")
	frames.add_frame(&"collision", _texture([".#"]))
	mask.frame_mode = FIXED_FRAME
	mask.fixed_animation = &"collision"
	mask.fixed_frame = 0
	_check(mask.bake_sprite(target) == OK, "Independent fixed static masks select a named SpriteFrames animation")
	_meeting(probe, Vector2(11, 10), true, "Independent fixed static masks use their own source dimensions")
	_meeting(probe, Vector2(12, 10), false, "Independent fixed static mask discards previous source pixels")
	scene.free()


func _test_invalidation() -> void:
	var scene: Node2D = suite._scene()
	var probe: AnimatedSprite2D = suite._probe(scene)
	var texture: ImageTexture = _texture(["#."])
	var target := _sprite(scene, texture, Vector2(10, 10), &"solid")
	var mask := _bake(target)
	# The headless dummy renderer retains this image but does not implement uploads.
	var edited := texture.get_image()
	edited.set_pixel(0, 0, Color.TRANSPARENT)
	edited.set_pixel(1, 0, Color.WHITE)
	texture.update(edited)
	_check(not mask.is_baked_for_sprite(target), "Editing source texture pixels invalidates static baked data")
	_meeting(probe, Vector2(10, 10), false, "Texture edits cannot retain stale static occupancy")
	_check(mask.bake_sprite(target) == OK, "Edited static textures can be explicitly rebaked")
	_meeting(probe, Vector2(11, 10), true, "Rebaking changed texture pixels refreshes attached static nodes")
	target.texture = _texture([".#"])
	_check(not mask.is_baked_for_sprite(target), "A distinct same-sized texture does not satisfy source identity")
	_meeting(probe, Vector2(11, 10), false, "Replacing a static texture invalidates the collider immediately")
	target.texture = texture
	_meeting(probe, Vector2(11, 10), true, "Restoring the original static texture restores baked validity")
	scene.free()


func _test_invalid_layouts() -> void:
	var detached := Node2D.new()
	var target := _sprite(detached, _texture(["####", "####"]))
	for region in [Rect2(0.5, 0, 2, 2), Rect2(0, 0, 2.5, 2), Rect2(-1, 0, 2, 2),
			Rect2(3, 0, 2, 2), Rect2(0, 0, 0, 2), Rect2(0, 0, -2, 2)]:
		target.region_enabled = true
		target.region_rect = region
		var invalid: Resource = ClassDB.instantiate(MASK_CLASS)
		_check(invalid.bake_sprite(target) != OK, "Invalid static pixel region is rejected explicitly: %s" % region)
		_check(not invalid.get_bake_error().is_empty(), "Invalid static region reports an authoring diagnostic")
	target.region_enabled = false
	target.hframes = 3
	var invalid: Resource = ClassDB.instantiate(MASK_CLASS)
	_check(invalid.bake_sprite(target) != OK, "Fractional sheet cell widths are rejected explicitly")
	target.hframes = 8
	_check(invalid.bake_sprite(target) != OK, "Subpixel sheet cells are rejected explicitly")
	target.hframes = 1
	target.vframes = 3
	_check(invalid.bake_sprite(target) != OK, "Fractional sheet cell heights are rejected explicitly")
	detached.free()


func _test_movement() -> void:
	var scene: Node2D = suite._scene()
	var texture := _texture(["#"])
	var source := _sprite(scene, texture, Vector2.ZERO, &"mover")
	_bake(source)
	var frames: SpriteFrames = suite._frames([["#"]])
	var wall: AnimatedSprite2D = suite._sprite(scene, frames, suite._mask(frames), Vector2(5, 0), &"solid")
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.position == Vector2(4, 0), "Static move_contact stops before an animated target")
	_meeting(wall, Vector2(4, 0), true, "Animated queries see moved static sources immediately", &"mover")
	_check(source.instance_place(Vector2(5, 0), &"solid") == wall,
		"Static instance_place returns an animated target as Node2D")
	source.add_to_group(&"solid")
	source.position = Vector2(5, 0)
	wall.position = Vector2.ZERO
	wall.move_contact(0.0, 20.0, &"solid")
	_check(wall.position == Vector2(4, 0), "Animated move_contact stops before a static target")
	source.collision_enabled = false
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(5, 0), "Disabled static sources do not move_contact")
	scene.free()


func _test_serialization() -> void:
	var scene := Node2D.new()
	var target := _sprite(scene, _texture(["#..#"]), Vector2(10, 10), &"solid", {"hframes": 2})
	target.name = "StaticTarget"
	target.owner = scene
	target.frame = 1
	_bake(target)
	var packed := PackedScene.new()
	_check(packed.pack(scene) == OK, "A static sprite and its baked mask pack into a scene")
	var path := "user://pixel_collision_static_sprite_roundtrip.tscn"
	var error := ResourceSaver.save(packed, path)
	_check(error == OK, "A static sprite scene saves with its texture and baked source identity")
	scene.free()
	if error != OK:
		return
	var restored: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	_check(restored != null, "Static scene resources reload without reusing cached resource identities")
	if restored != null:
		var instance: Node2D = restored.instantiate()
		suite.root.add_child(instance)
		var restored_target: Sprite2D = instance.get_node("StaticTarget")
		restored_target.add_to_group(&"solid")
		_check(restored_target.mask.is_baked_for_sprite(restored_target),
			"Restored static mask validates using the serialized Texture2D reference")
		var probe: AnimatedSprite2D = suite._probe(instance)
		_meeting(probe, Vector2(10, 10), false, "Restored static mask retains its transparent cell pixel")
		_meeting(probe, Vector2(11, 10), true, "Restored static mask retains its selected frame occupancy")
		instance.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_external_serialization() -> void:
	var texture_path := "user://pixel_collision_static_external_texture.tres"
	var mask_path := "user://pixel_collision_static_external_mask.tres"
	var scene_path := "user://pixel_collision_static_external_scene.tscn"
	var texture := _texture(["#..#"])
	_check(ResourceSaver.save(texture, texture_path) == OK, "Static texture saves as a paired external resource")
	texture.take_over_path(texture_path)
	var scene := Node2D.new()
	var target := _sprite(scene, texture, Vector2(10, 10), &"", {"hframes": 2})
	target.name = "ExternalStaticTarget"
	target.owner = scene
	target.frame = 1
	var mask := _bake(target)
	_check(ResourceSaver.save(mask, mask_path) == OK, "Static mask saves separately from its paired external texture")
	mask.take_over_path(mask_path)
	var packed := PackedScene.new()
	_check(packed.pack(scene) == OK, "A static scene packs with paired external mask and texture references")
	var error := ResourceSaver.save(packed, scene_path)
	_check(error == OK, "Static scene saves its external source references")
	var original_texture: WeakRef = weakref(texture)
	var original_mask: WeakRef = weakref(mask)
	scene.free()
	# A normal cold load resolves both external references to the same resource.
	texture = null
	mask = null
	packed = null
	_check(not ResourceLoader.has_cached(texture_path) and not ResourceLoader.has_cached(mask_path),
		"External static source fixtures release their original cached resources")
	_check(original_texture.get_ref() == null and original_mask.get_ref() == null,
		"External static source fixtures release the original Texture2D and mask objects")
	if error == OK:
		var restored: PackedScene = ResourceLoader.load(scene_path)
		_check(restored != null, "Paired external static resources load without a warm resource cache")
		if restored != null:
			var instance: Node2D = restored.instantiate()
			suite.root.add_child(instance)
			var restored_target: Sprite2D = instance.get_node("ExternalStaticTarget")
			restored_target.add_to_group(&"solid")
			_check(restored_target.mask.is_baked_for_sprite(restored_target),
				"A cold scene load resolves the same paired external Texture2D for its mask and sprite")
			_check(restored_target.mask.validate_source_files(),
				"Static external source fingerprints validate after resource reload")
			var probe: AnimatedSprite2D = suite._probe(instance)
			_meeting(probe, Vector2(10, 10), false, "External static resources preserve transparent cell pixels")
			_meeting(probe, Vector2(11, 10), true, "External static resources preserve selected frame occupancy")
			instance.free()
		# Deep cache bypass may create a new external texture for each load edge.
		# Explicitly use the mask's serialized source, as with get_baked_source for animations.
		var deep_mask: Resource = ResourceLoader.load(mask_path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		_check(deep_mask != null, "An external static mask can be reloaded independently with deep cache bypass")
		if deep_mask != null:
			var deep_texture: Texture2D = deep_mask.get_baked_texture()
			_check(deep_texture != null, "A deep-loaded static mask exposes its serialized Texture2D source")
			if deep_texture != null:
				var deep_scene: Node2D = suite._scene()
				var deep_target := _sprite(deep_scene, deep_texture, Vector2(10, 10), &"solid", {"hframes": 2})
				deep_target.frame = 1
				deep_target.mask = deep_mask
				_check(deep_mask.is_baked_for_sprite(deep_target),
					"Explicit source rebinding validates independently deep-loaded static masks")
				var deep_probe: AnimatedSprite2D = suite._probe(deep_scene)
				_meeting(deep_probe, Vector2(10, 10), false, "Deep-loaded static masks preserve transparent pixels after rebinding")
				_meeting(deep_probe, Vector2(11, 10), true, "Deep-loaded static masks preserve occupied pixels after rebinding")
				deep_scene.free()
	for path in [scene_path, mask_path, texture_path]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
