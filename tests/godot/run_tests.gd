extends SceneTree
## Integration checks for the native classes, using generated in-memory textures.
## Run with: godot --headless --path . --script tests/godot/run_tests.gd

const MASK_CLASS := &"PixelCollisionMask"
const SPRITE_CLASS := &"MaskedAnimatedSprite2D"
const STATIC_SPRITE_CLASS := &"MaskedSprite2D"
const COLLISION_CLASS := &"PixelCollision"
const PRECISE := 0
const RECTANGLE := 1
const CURRENT_FRAME := 0
const ANIMATION_UNION := 1
const FIXED_FRAME := 2

var checks := 0
var failures := 0
var collision: Object


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for native_class in [MASK_CLASS, SPRITE_CLASS, STATIC_SPRITE_CLASS, COLLISION_CLASS]:
		_check(ClassDB.class_exists(native_class), "Native class is registered: %s" % native_class)
	_check(Engine.has_singleton(COLLISION_CLASS), "Collision singleton is registered with Engine")
	if failures > 0:
		_finish()
		return
	collision = Engine.get_singleton(COLLISION_CLASS)
	_test_native_contract()
	_test_detached_worker_configuration()
	_test_holes_and_coordinate_quantization()
	_test_groups_queries_and_order()
	_test_lifecycle_and_global_scope()
	_test_packed_scene_cleanup()
	_test_subviewport_global_scope()
	_test_same_frame_transforms()
	_test_sprite_geometry()
	_test_fractional_scale()
	_test_rotated_geometry()
	_test_affine_flips_offsets_and_parents()
	_test_affine_sources_and_contact()
	_test_minified_sampling_and_motion()
	_test_shared_animation_bounds_and_large_transforms()
	_test_frame_selection_and_shared_resources()
	_test_shape_configuration()
	_test_atlas_texture()
	_test_independent_mask_source()
	var invalidation_source := _test_resource_invalidation()
	_check(invalidation_source.get_ref() == null,
		"Repeated baking and source edits release previous source resources after teardown")
	_test_invalid_state()
	_test_move_contact_directions_and_distance()
	_test_move_contact_groups_and_global_scope()
	_test_move_contact_pixels_and_transforms()
	_test_move_contact_numeric_boundaries()
	_test_move_contact_invalid_state()
	_test_serialization()
	_test_external_atlas_serialization()
	_test_external_source_validation()
	load("res://tests/godot/static_sprite_tests.gd").new().run(self)
	_check(collision.get_collider_count() == 0, "All fixture scenes unload without stale global registrations")
	_finish()


func _finish() -> void:
	print("%s: Pixel collision integration: %d checks, %d failures." % ["FAIL" if failures else "PASS", checks, failures])
	quit(1 if failures else 0)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + description)


func _frames(images: Array) -> SpriteFrames:
	var result := SpriteFrames.new()
	for rows in images:
		var width: int = rows[0].length()
		var image := Image.create(width, rows.size(), false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		for y in rows.size():
			for x in width:
				var symbol: String = rows[y].substr(x, 1)
				var alpha := 1.0 if symbol == "#" else 0.0
				if symbol == "l":
					alpha = 0.2
				elif symbol == "h":
					alpha = 0.8
				image.set_pixel(x, y, Color(1, 1, 1, alpha))
		result.add_frame(&"default", ImageTexture.create_from_image(image))
	return result


func _mask(frames: SpriteFrames, configuration: Dictionary = {}) -> Resource:
	var result: Resource = ClassDB.instantiate(MASK_CLASS)
	for property in configuration:
		result.set(property, configuration[property])
	_check(result.bake(frames) == OK, "Generated mask bakes successfully")
	_check(result.is_baked_for(frames), "Generated mask validates against its frames")
	return result


func _scene() -> Node2D:
	var result := Node2D.new()
	root.add_child(result)
	return result


func _sprite(parent: Node, frames: SpriteFrames, mask: Resource,
		at: Vector2 = Vector2.ZERO, group: StringName = &"") -> AnimatedSprite2D:
	var result: AnimatedSprite2D = ClassDB.instantiate(SPRITE_CLASS)
	result.sprite_frames = frames
	result.mask = mask
	result.centered = false
	result.position = at
	if not group.is_empty():
		result.add_to_group(group)
	parent.add_child(result)
	return result


func _probe(parent: Node) -> AnimatedSprite2D:
	var frames := _frames([["#"]])
	return _sprite(parent, frames, _mask(frames), Vector2(1000, 1000))


func _meeting(source: AnimatedSprite2D, at: Vector2, expected: bool,
		description: String, group: StringName = &"solid") -> void:
	_check(source.place_meeting(at, group) == expected, description)


func _footprint(probe: AnimatedSprite2D, origin: Vector2, rows: Array,
		description: String, group: StringName = &"solid") -> void:
	# Fixed expected samples include a clear one-cell border around the queried region.
	# These tables use the audited Runner formulas, independently of the native query code.
	var width: int = rows[0].length()
	for y in range(-1, rows.size() + 1):
		for x in range(-1, width + 1):
			var expected := y >= 0 and y < rows.size() and x >= 0 and x < width
			if expected:
				expected = rows[y].substr(x, 1) == "#"
			_meeting(probe, origin + Vector2(x, y), expected,
				"%s at (%d, %d)" % [description, x, y], group)


func _test_native_contract() -> void:
	_check(collision == Engine.get_singleton(COLLISION_CLASS), "Engine returns the same collision service")
	_check(not ClassDB.can_instantiate(COLLISION_CLASS), "Collision service cannot be instantiated manually")
	_check(not collision is Node, "Collision service does not require a scene node")
	_check(not ClassDB.class_exists(&"PixelCollisionWorld2D"), "Obsolete world node is no longer registered")
	_check(not ProjectSettings.has_setting("autoload/PixelCollision"), "Collision service needs no project Autoload entry")
	_check(not collision.has_method("test_meetings"), "Collision service does not expose the removed bulk result API")
	_check(not collision.has_method("count_meetings"), "Collision service does not expose the removed bulk count API")
	_check(collision.get_collider_count() == 0, "Collision service starts without registered sprites")
	var access_script := GDScript.new()
	access_script.source_code = "extends RefCounted\nfunc count_colliders() -> int:\n\treturn PixelCollision.get_collider_count()\n"
	var access_error := access_script.reload()
	_check(access_error == OK, "GDScript can address PixelCollision directly as a global singleton")
	if access_error == OK:
		var accessor: RefCounted = access_script.new()
		_check(accessor.count_colliders() == 0, "Direct global singleton access reaches the registered service")
	var sprite: AnimatedSprite2D = ClassDB.instantiate(SPRITE_CLASS)
	_check(sprite is AnimatedSprite2D, "Native sprite retains AnimatedSprite2D inheritance")
	_check(sprite.has_method("play"), "AnimatedSprite2D animation API remains available")
	_check(sprite.has_method("move_contact"), "Native sprite exposes move_contact")
	for method in sprite.get_method_list():
		if method.name == &"move_contact":
			_check(method.args.size() == 3 and method.default_args.is_empty(),
				"move_contact requires an explicit direction, distance, and group")
	var properties: Array[StringName] = []
	for property in sprite.get_property_list():
		properties.append(property.name)
	_check(not properties.has(&"collision_owner"), "No collision_owner property is introduced")
	_check(not properties.has(&"collision_tags"), "Godot groups replace duplicate tag properties")
	_check(not properties.has(&"collision_world"), "Sprites do not need a collision world property")
	_check(not sprite.has_method("get_collision_world"), "Sprites do not expose the removed world relationship")
	sprite.free()
	var frames := _frames([["#"]])
	var mask := _mask(frames)
	var root_source := _sprite(root, frames, mask, Vector2.ZERO)
	var root_target := _sprite(root, frames, mask, Vector2(4, 0), &"solid")
	_check(collision.get_collider_count() == 2, "Direct SceneTree-root children register without a manager node")
	_meeting(root_source, Vector2(4, 0), true, "Root-level sprites can query each other immediately")
	root_source.move_contact(0.0, 10.0, &"solid")
	_check(root_source.position == Vector2(3, 0), "Root-level sprites support move_contact")
	root_source.free()
	root_target.free()
	_check(collision.get_collider_count() == 0, "Removing direct root children clears their registrations")


func _build_detached_worker_sprite(frames: SpriteFrames, mask: Resource) -> Dictionary:
	# Only this detached node is modified; shared resources were baked on main.
	var sprite: AnimatedSprite2D = ClassDB.instantiate(SPRITE_CLASS)
	sprite.sprite_frames = frames
	sprite.mask = mask
	sprite.centered = false
	sprite.position = Vector2(7, 9)
	sprite.offset = Vector2(2, 1)
	sprite.frame = 1
	sprite.flip_h = true
	sprite.collision_enabled = false
	sprite.collision_enabled = true
	sprite.add_to_group(&"worker_sprite")
	return {"sprite": sprite, "thread_id": OS.get_thread_caller_id()}


func _test_detached_worker_configuration() -> void:
	var frames := _frames([["#."], [".#"]])
	var mask := _mask(frames)
	var target_frames := _frames([["#"]])
	var target := _sprite(root, target_frames, _mask(target_frames), Vector2(20, 20), &"solid")
	var worker := Thread.new()
	var error := worker.start(_build_detached_worker_sprite.bind(frames, mask))
	_check(error == OK, "Detached sprite configuration worker starts successfully")
	if error != OK:
		target.free()
		return
	var result: Dictionary = worker.wait_to_finish()
	var sprite: AnimatedSprite2D = result.sprite
	_check(result.thread_id != OS.get_thread_caller_id(), "Detached sprite configuration runs on a worker thread")
	_check(not sprite.is_inside_tree(), "Worker-created sprite remains detached until main-thread attachment")
	_check(collision.get_collider_count() == 1, "Detached worker configuration does not register with the singleton")
	root.add_child(sprite)
	_check(collision.get_collider_count() == 2, "Main-thread attachment registers the worker-created sprite once")
	_meeting(sprite, Vector2(18, 19), true, "Attachment collects the worker-configured frame, flip, and offset")
	_meeting(sprite, Vector2(17, 19), false, "Worker-configured transparent pixels remain transparent after attachment")
	_meeting(target, Vector2(9, 10), true, "Other sprites immediately see the worker-configured global position", &"worker_sprite")
	sprite.free()
	target.free()
	_check(collision.get_collider_count() == 0, "Main-thread cleanup releases worker-created sprite registration")


func _test_holes_and_coordinate_quantization() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["###", "#.#", "###"]])
	var target := _sprite(scene, frames, _mask(frames), Vector2(10, 10), &"solid")
	_meeting(probe, Vector2(11, 11), false, "Transparent center is a real hole")
	_meeting(probe, Vector2(10, 11), true, "Left opaque edge collides")
	_meeting(probe, Vector2(12, 12), true, "Last occupied pixel is included")
	_meeting(probe, Vector2(13, 11), false, "Touching the next pixel outside does not collide")
	target.position = Vector2(-3, -3)
	_meeting(probe, Vector2(-2, -2), false, "Mask hole works in negative coordinates")
	_meeting(probe, Vector2(-3, -2), true, "Opaque edge works in negative coordinates")
	var pixel_frames := _frames([["#"]])
	target.sprite_frames = pixel_frames
	target.mask = _mask(pixel_frames)
	target.position = Vector2.ZERO
	_meeting(probe, Vector2(-0.01, 0), true, "A negative fraction truncates to cell zero")
	_meeting(probe, Vector2.ZERO, true, "Exact zero occupies cell zero")
	_meeting(probe, Vector2(0.99, 0.99), true, "Positive subpixel coordinates truncate within the cell")
	_meeting(probe, Vector2(1, 0), false, "Next integer cell is outside a one-pixel mask")
	target.position = Vector2(-2, -2)
	_meeting(probe, Vector2(-2.01, -2), true, "Negative coordinates truncate toward zero at an integer boundary")
	_meeting(probe, Vector2(-1.01, -1.01), false, "Negative fractions do not use the old floor quantization")
	scene.free()


func _test_groups_queries_and_order() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#"]])
	var mask := _mask(frames)
	var first := _sprite(scene, frames, mask, Vector2(4, 8), &"solid")
	var second := _sprite(scene, frames, mask, Vector2(4, 8), &"solid")
	var original_position := probe.position
	var original_global := probe.global_position
	_meeting(probe, Vector2(4, 8), true, "Group query finds registered sprites")
	_check(probe.position == original_position and probe.global_position == original_global,
		"A query never moves its source node")
	_check(probe.instance_place(Vector2(4, 8), &"solid") == first,
		"instance_place returns the earliest registered matching sprite")
	first.position = Vector2(-100, -100)
	first.position = Vector2(4, 8)
	_check(probe.instance_place(Vector2(4, 8), &"solid") == first,
		"Moving between grid cells preserves hit-selection order")
	first.remove_from_group(&"solid")
	_check(probe.instance_place(Vector2(4, 8), &"solid") == second,
		"Removing a group is visible to the next query")
	second.remove_from_group(&"solid")
	_meeting(probe, Vector2(4, 8), false, "Removed group membership cannot remain cached")
	first.add_to_group(&"hazard")
	_meeting(probe, Vector2(4, 8), true, "Adding a group is visible immediately", &"hazard")
	first.add_to_group(&"solid")
	_meeting(probe, Vector2(4, 8), true, "One sprite can match multiple groups", &"solid")
	_meeting(probe, Vector2(4, 8), true, "Empty group matches any registered sprite", &"")
	probe.add_to_group(&"self_only")
	_meeting(probe, probe.global_position, false, "Source is excluded from its own group query", &"self_only")
	_check(probe.instance_place(Vector2(-500, 0), &"solid") == null,
		"instance_place returns null on a miss")
	var positions := PackedVector2Array([Vector2(4, 8), Vector2(5, 8), Vector2(4.5, 8)])
	var scalar_results := PackedByteArray()
	for query_position in positions:
		scalar_results.append(int(probe.place_meeting(query_position, &"solid")))
	_check(scalar_results == PackedByteArray([1, 0, 1]), "Scalar queries match explicit per-position expectations")
	scene.free()


func _test_lifecycle_and_global_scope() -> void:
	var first_scene := _scene()
	var second_scene := _scene()
	var probe := _probe(first_scene)
	var second_probe := _probe(second_scene)
	var frames := _frames([["#"]])
	var target := _sprite(first_scene, frames, _mask(frames), Vector2(8, 8), &"solid")
	_check(collision.get_collider_count() == 3, "Sprites from all scene branches register globally")
	_meeting(probe, Vector2(8, 8), true, "First scene finds its own sprite")
	_meeting(second_probe, Vector2(8, 8), true, "Matching groups collide across ordinary scene branches")
	target.collision_enabled = false
	_meeting(probe, Vector2(8, 8), false, "Disabled candidates are excluded immediately")
	target.collision_enabled = true
	_meeting(probe, Vector2(8, 8), true, "Reenabled candidate is available immediately")
	first_scene.remove_child(target)
	_meeting(probe, Vector2(8, 8), false, "Exited node is excluded immediately")
	_check(collision.get_collider_count() == 2, "Exited sprite unregisters from the singleton")
	_meeting(target, probe.global_position, false, "Detached source cannot query registered sprites", &"")
	_check(target.instance_place(probe.global_position, &"") == null, "Detached source returns no matching instance")
	var detached_position := target.position
	target.move_contact(0.0, 10.0, &"solid")
	_check(target.position == detached_position, "Detached source cannot move_contact")
	first_scene.add_child(target)
	_meeting(probe, Vector2(8, 8), true, "Reentering the tree registers the sprite again")
	target.reparent(second_scene, false)
	_meeting(probe, Vector2(8, 8), true, "Reparenting preserves visibility from the previous branch")
	_meeting(second_probe, Vector2(8, 8), true, "Reparented sprite is visible from its new branch")
	_check(collision.get_collider_count() == 3, "Reparenting does not duplicate global registrations")
	var nested_scene := Node2D.new()
	second_scene.add_child(nested_scene)
	target.reparent(nested_scene, false)
	_meeting(second_probe, Vector2(8, 8), true, "Nested parents do not create an implicit collision boundary")
	var nested_probe := _probe(nested_scene)
	_meeting(nested_probe, Vector2(8, 8), true, "Nested scene can query its own sprites")
	target.queue_free()
	_meeting(nested_probe, Vector2(8, 8), false, "Queued-for-deletion candidate is excluded before tree flush")
	var replacement := _sprite(nested_scene, frames, _mask(frames), Vector2(8, 8), &"solid")
	_meeting(nested_probe, Vector2(8, 8), true, "New registration works after another sprite queues deletion")
	replacement.free()
	_meeting(nested_probe, Vector2(8, 8), false, "Immediate destruction removes the collider without stale handles")
	first_scene.free()
	second_scene.free()
	_check(collision.get_collider_count() == 0, "Nested branch teardown clears every registered collider")


func _test_packed_scene_cleanup() -> void:
	var frames := _frames([["#"]])
	var fixture := Node2D.new()
	var target := _sprite(fixture, frames, _mask(frames), Vector2(8, 8))
	target.add_to_group(&"replacement", true)
	target.owner = fixture
	_check(collision.get_collider_count() == 0, "Constructing a detached scene does not register its sprites")
	var packed := PackedScene.new()
	_check(packed.pack(fixture) == OK, "Collision fixture packs without a manager node")
	fixture.free()
	var probe := _probe(root)
	var first_scene := packed.instantiate() as Node2D
	var second_scene := packed.instantiate() as Node2D
	root.add_child(first_scene)
	root.add_child(second_scene)
	_check(collision.get_collider_count() == 3, "Simultaneously loaded PackedScenes share one collision service")
	_meeting(probe, Vector2(8, 8), true, "Scene instances retain persistent group filtering", &"replacement")
	first_scene.free()
	_check(collision.get_collider_count() == 2, "Unloading one scene removes only its own colliders")
	_meeting(probe, Vector2(8, 8), true, "Another loaded scene remains queryable after a sibling unloads", &"replacement")
	second_scene.free()
	_check(collision.get_collider_count() == 1, "Unloading both scenes leaves only the independent source")
	_meeting(probe, Vector2(8, 8), false, "Unloaded scenes leave no stale collision data", &"replacement")
	var replacement := packed.instantiate() as Node2D
	replacement.position = Vector2(32, 0)
	root.add_child(replacement)
	_meeting(probe, Vector2(8, 8), false, "Reloading a scene does not revive its previous global coordinates", &"replacement")
	_meeting(probe, Vector2(40, 8), true, "Reloaded scene registers its new global coordinates", &"replacement")
	replacement.free()
	probe.free()
	_check(collision.get_collider_count() == 0, "Scene replacement releases all singleton registrations")


func _test_subviewport_global_scope() -> void:
	var scene := _scene()
	var viewport := SubViewport.new()
	scene.add_child(viewport)
	var probe := _probe(scene)
	var frames := _frames([["#"]])
	_sprite(viewport, frames, _mask(frames), Vector2(8, 8), &"viewport_target")
	_meeting(probe, Vector2(8, 8), true, "SubViewports do not create implicit collision spaces", &"viewport_target")
	viewport.free()
	_meeting(probe, Vector2(8, 8), false, "Removing a SubViewport unregisters its descendant colliders", &"viewport_target")
	scene.free()
	_check(collision.get_collider_count() == 0, "SubViewport teardown leaves no global registrations")


func _test_same_frame_transforms() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var container := Node2D.new()
	scene.add_child(container)
	var frames := _frames([["#"]])
	var target := _sprite(container, frames, _mask(frames), Vector2(10, 10), &"solid")
	_meeting(probe, Vector2(10, 10), true, "Initial child transform is registered")
	target.position = Vector2(70, 10)
	_meeting(probe, Vector2(10, 10), false, "Direct movement clears the old location in the same frame")
	_meeting(probe, Vector2(70, 10), true, "Direct movement reaches another grid cell in the same frame")
	container.position = Vector2(-64, 5)
	_meeting(probe, Vector2(70, 10), false, "Parent movement clears stale global coordinates immediately")
	_meeting(probe, Vector2(6, 15), true, "Parent movement is visible without awaiting a process frame")
	scene.position = Vector2(20, -30)
	_meeting(probe, Vector2(26, -15), true, "Queries use absolute global positions after scene movement")
	collision.sync()
	_meeting(probe, Vector2(26, -15), true, "Explicit sync preserves the same query semantics")
	scene.position = Vector2.ZERO
	container.position = Vector2(50, 50)
	_meeting(probe, Vector2(120, 60), true, "Parented sprite is indexed before a top-level toggle")
	target.set_as_top_level(true)
	_meeting(probe, Vector2(70, 10), true, "Top-level toggle alone immediately changes collision coordinates")
	_meeting(probe, Vector2(120, 60), false, "Top-level toggle alone removes inherited parent coordinates")
	target.position = Vector2(9, 9)
	_meeting(probe, Vector2(9, 9), true, "Top-level sprite uses its independent global transform")
	container.position = Vector2(20, 20)
	_meeting(probe, Vector2(9, 9), true, "Parent movement does not move a top-level sprite collider")
	target.set_as_top_level(false)
	_meeting(probe, Vector2(29, 29), true, "Disabling top-level mode alone immediately inherits the parent")
	target.position = Vector2(1, 1)
	_meeting(probe, Vector2(21, 21), true, "Disabling top-level mode restores parent transform inheritance")
	scene.free()


func _test_sprite_geometry() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#..", "..."]])
	var target := _sprite(scene, frames, _mask(frames), Vector2(10, 10), &"solid")
	_meeting(probe, Vector2(10, 10), true, "Uncentered mask uses the frame origin")
	target.offset = Vector2(2, 3)
	_meeting(probe, Vector2(12, 13), true, "Sprite offset changes mask position immediately")
	_meeting(probe, Vector2(10, 10), false, "Old offset does not retain a collider")
	target.offset = Vector2.ZERO
	target.centered = true
	_meeting(probe, Vector2(8, 9), true, "Centered odd width truncates its transformed occupied bound")
	_meeting(probe, Vector2(9, 9), false, "Centered mask preserves transparent pixels")
	target.centered = false
	target.flip_h = true
	_meeting(probe, Vector2(12, 10), true, "Horizontal sprite flip mirrors mask occupancy")
	_meeting(probe, Vector2(10, 10), false, "Horizontal flip clears original occupied pixel")
	target.flip_v = true
	_meeting(probe, Vector2(12, 11), true, "Vertical sprite flip mirrors mask occupancy")
	target.flip_h = false
	target.flip_v = false
	target.scale = Vector2(2, 3)
	_meeting(probe, Vector2(10, 10), true, "Integer scaling includes the first enlarged cell")
	_meeting(probe, Vector2(11, 12), true, "Integer scaling expands occupied pixels in both axes")
	_meeting(probe, Vector2(12, 12), false, "Integer scaling preserves transparent cells")
	target.scale = Vector2(-1, 1)
	_meeting(probe, Vector2(9, 10), false, "Native signed-scale bounds can clip source pixel zero")
	_meeting(probe, Vector2(10, 10), false, "Negative scale excludes the original node-origin pixel at its far bound")
	scene.free()


func _test_fractional_scale() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#.", ".#"]])
	var target := _sprite(scene, frames, _mask(frames), Vector2(10, 10), &"solid")
	target.scale = Vector2(1.5, 1.5)
	_footprint(probe, Vector2(10, 10), ["##.", "##.", "..#"],
		"Fractional enlargement samples integer world points with local truncation")
	target.scale = Vector2(0.5, 0.5)
	_footprint(probe, Vector2(10, 10), ["#"],
		"Half scale samples the top-left source pixel")
	target.flip_h = true
	_meeting(probe, Vector2(10, 10), false,
		"Half scale preserves the distinction between integer and center sampling")
	target.flip_h = false
	target.scale = Vector2(0.25, 0.25)
	_meeting(probe, Vector2(10, 10), false,
		"A valid minified source can have empty integer collision bounds")
	target.scale = Vector2(-1.5, 1.0)
	_footprint(probe, Vector2(7, 10), ["..#", ".#."],
		"Negative scale uses the same original-mask inverse sampling")
	target.position = Vector2(10.75, 10.75)
	_footprint(probe, Vector2(7, 10), ["..#", ".#."],
		"Positive fractional positions use separate bound and origin truncation")
	target.position = Vector2(-10.75, -10.75)
	_footprint(probe, Vector2(-13, -10), ["..#", ".#."],
		"Negative fractional positions use truncation rather than floor")
	target.scale = Vector2(1.5, 1.5)
	_footprint(probe, Vector2(-10, -10), ["##.", "##.", "..#"],
		"Signed position truncation is independent of positive fractional enlargement")
	scene.free()


func _test_rotated_geometry() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#.", "##"]])
	var target := _sprite(scene, frames, _mask(frames), Vector2(10, 10), &"solid")
	# Exact bases isolate the native sampling rule from trigonometric residue.
	target.transform = Transform2D(Vector2.DOWN, Vector2.LEFT, Vector2(10, 10))
	_footprint(probe, Vector2(8, 10), [".#", ".#"],
		"A quarter turn samples integer world points inside its transformed bounds")
	target.transform = Transform2D(Vector2.UP, Vector2.RIGHT, Vector2(10, 10))
	_footprint(probe, Vector2(10, 8), ["..", ".#"],
		"A negative quarter turn retains native edge clipping")
	target.transform = Transform2D(Vector2.LEFT, Vector2.UP, Vector2(10, 10))
	_footprint(probe, Vector2(8, 8), ["..", ".#"],
		"A half turn uses signed basis sampling without a pixel-center correction")
	var solid_frames := _frames([["##", "##"]])
	target.sprite_frames = solid_frames
	target.mask = _mask(solid_frames)
	target.rotation_degrees = 45.0
	_footprint(probe, Vector2(8, 10), [".##", ".##"],
		"A rotated square samples only the native integer bounding intersection")
	target.position = Vector2(10.75, 10.25)
	_footprint(probe, Vector2(9, 10), ["###", "###", ".#."],
		"Subpixel translation can change rotated occupancy without changing the basis")
	target.position = Vector2(11.0, 10.25)
	_footprint(probe, Vector2(9, 10), [".##", ".##", "..#"],
		"Crossing the integer origin changes the inverse-sampling phase immediately")
	target.position = Vector2(10, 10)
	target.rotation_degrees = 30.0
	_footprint(probe, Vector2(9, 10), ["##", "##"],
		"A non-quarter-turn angle uses its own bounds and inverse basis")
	var sparse_frames := _frames([["#...", "....", "....", "...."]])
	target.sprite_frames = sparse_frames
	target.mask = _mask(sparse_frames)
	target.position = Vector2.ZERO
	target.rotation_degrees = 45.0
	_footprint(probe, Vector2.ZERO, ["."],
		"A sparse rotated frame uses occupied logical bounds rather than the whole canvas")
	var residue_frames := _frames([["####", "####", "####", "####"]])
	target.sprite_frames = residue_frames
	target.mask = _mask(residue_frames)
	target.offset = Vector2(-16, -2)
	target.transform = Transform2D(Vector2(-4.371138828673793e-08, 1),
		Vector2(-0.5, -2.1855694143368964e-08), Vector2(-17, 16.25))
	_meeting(probe, Vector2(-16, 0), false,
		"Native bound addition order clips the far edge with near-cardinal float residue")
	_meeting(probe, Vector2(-17, 0), true,
		"Near-cardinal residue keeps the adjacent sample inside native-ordered bounds")
	scene.free()


func _test_affine_flips_offsets_and_parents() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#.", ".#"]])
	var mask := _mask(frames, {"mask_offset": Vector2i(1, -1)})
	var target := _sprite(scene, frames, mask, Vector2(10, 10), &"solid")
	target.centered = true
	target.offset = Vector2(2, 3)
	target.transform = Transform2D(Vector2(0, -1.5), Vector2(-1, 0), Vector2(10, 10))
	target.flip_h = true
	_footprint(probe, Vector2(7, 4), ["..", "..", ".#"],
		"Centered sprite and mask offsets are subtracted before local truncation")
	mask.follow_sprite_flip = false
	_footprint(probe, Vector2(7, 4), ["..", ".#", ".."],
		"Ignoring sprite flips keeps the original source-mask indices")
	mask.follow_sprite_flip = true
	target.flip_v = true
	_footprint(probe, Vector2(7, 4), ["..", ".#", ".."],
		"Both sprite flips compose after inverse sampling")
	scene.free()

	scene = _scene()
	probe = _probe(scene)
	var parent := Node2D.new()
	parent.position = Vector2(10, 10)
	scene.add_child(parent)
	var solid_frames := _frames([["##", "##"]])
	target = _sprite(parent, solid_frames, _mask(solid_frames), Vector2.ZERO, &"solid")
	parent.scale = Vector2(1.5, 0.5)
	_footprint(probe, Vector2(10, 10), ["###"],
		"Fractional parent scaling is visible on the next query")
	parent.transform = Transform2D(Vector2(0, 1.5), Vector2(-0.5, 0), Vector2(10, 10))
	_footprint(probe, Vector2(9, 10), [".", ".", "."],
		"A rotated minified parent can leave no occupied integer sample")
	parent.transform = Transform2D(Vector2(2, 0), Vector2.DOWN, Vector2(10, 10))
	target.rotation_degrees = 45.0
	_footprint(probe, Vector2(7, 10), [".####", "#####"],
		"Child rotation under nonuniform parent scale uses the complete global basis")
	parent.transform = Transform2D(Vector2(1, 0), Vector2(0.5, 1), Vector2(10, 10))
	target.rotation = 0.0
	_footprint(probe, Vector2(10, 10), ["##.", "###"],
		"Inherited shear samples the original mask at integer world positions")
	target.set_as_top_level(true)
	target.position = Vector2(20, 20)
	_footprint(probe, Vector2(20, 20), ["##", "##"],
		"Top-level sprites stop inheriting an affine parent")
	scene.free()


func _test_affine_sources_and_contact() -> void:
	var scene := _scene()
	var solid_frames := _frames([["##", "##"]])
	var solid_mask := _mask(solid_frames)
	var source := _sprite(scene, solid_frames, solid_mask, Vector2(100, 100), &"mover")
	source.rotation_degrees = 45.0
	var pixel_frames := _frames([["#"]])
	var target := _sprite(scene, pixel_frames, _mask(pixel_frames), Vector2(9, 10), &"solid")
	_meeting(source, Vector2(10, 10), true,
		"A query inverse-samples a rotated source at its proposed global position")
	_check(source.instance_place(Vector2(10, 10), &"solid") == target,
		"instance_place returns a target touched by a rotated source sample")
	_check(source.position == Vector2(100, 100),
		"Querying a rotated source never mutates its actual transform")
	target.position = Vector2(8, 10)
	_meeting(source, Vector2(10, 10), false,
		"A rotated source bounding-box corner remains transparent")
	source.position = Vector2.ZERO
	target.position = Vector2(5, 1)
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.position == Vector2(4, 0),
		"move_contact stops before a rotated source sample touches the target")
	_meeting(source, source.global_position, false,
		"Rotated source movement commits a collision-free endpoint")
	var observer := _probe(scene)
	_meeting(observer, Vector2(4, 1), true,
		"Other queries immediately see the moved rotated source", &"mover")
	source.rotation = 0.0
	source.scale = Vector2(1.5, 0.5)
	source.position = Vector2.ZERO
	target.position = Vector2(6, 0)
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.position == Vector2(3, 0),
		"move_contact includes fractional source enlargement")
	source.scale = Vector2.ONE
	source.sprite_frames = pixel_frames
	source.mask = _mask(pixel_frames)
	source.position = Vector2.ZERO
	target.sprite_frames = solid_frames
	target.mask = solid_mask
	target.rotation_degrees = 45.0
	target.position = Vector2(5, 0)
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.position == Vector2(3, 0),
		"move_contact stops at sampled pixels of a rotated target")
	source.sprite_frames = solid_frames
	source.mask = solid_mask
	source.rotation_degrees = 45.0
	_meeting(source, Vector2(6, 0), true,
		"Two transformed masks can overlap at a single integer world sample")
	_meeting(source, Vector2(7, 0), false,
		"Two transformed logical bounds can intersect without a common occupied sample")
	source.scale = Vector2(0.5, 0.5)
	target.rotation = 0.0
	_footprint(observer, Vector2(5, 0), ["##", "##"],
		"Transforming one instance does not modify another instance sharing its original mask")
	scene.free()

	scene = _scene()
	var parent := Node2D.new()
	parent.transform = Transform2D(Vector2(0, 0.5), Vector2(-1.5, 0), Vector2(10, 10))
	scene.add_child(parent)
	source = _sprite(parent, solid_frames, solid_mask)
	target = _sprite(scene, pixel_frames, _mask(pixel_frames), Vector2(16, 10), &"solid")
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.global_position.is_equal_approx(Vector2(16, 10))
			and source.position.is_equal_approx(Vector2(0, -4)),
		"move_contact commits global unit steps through a rotated fractional parent")
	_meeting(source, source.global_position, false,
		"An affine parent conversion leaves the committed source outside the target")
	scene.free()


func _test_minified_sampling_and_motion() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#.", ".#"]])
	var mask := _mask(frames)
	var target := _sprite(scene, frames, mask, Vector2(20, 20), &"solid")
	target.scale = Vector2(0.5, 0.5)
	_meeting(probe, Vector2(20, 20), true,
		"A minified mask samples its original top-left pixel")
	target.flip_h = true
	_meeting(probe, Vector2(20, 20), false,
		"Flipping a minified target changes its sampled source index immediately")
	target.flip_h = false
	_meeting(probe, Vector2(20, 20), true,
		"Flipping the target back restores the original sampled occupancy")
	var source := _sprite(scene, frames, mask, Vector2(15, 20))
	source.scale = Vector2(0.5, 0.5)
	source.flip_h = true
	_meeting(source, Vector2(20, 20), false,
		"A nonempty original mask may have no occupied samples at its current transform")
	source.move_contact(0.0, 5.0, &"solid")
	_check(source.position == Vector2(20, 20),
		"A source without occupied current samples can still move_contact")
	source.position = Vector2(15, 20)
	source.flip_h = false
	_meeting(source, Vector2(20, 20), true,
		"Flipping the source immediately restores its collision samples")
	_check(source.instance_place(Vector2(20, 20), &"solid") == target,
		"instance_place observes the changed minified source and target")
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(19, 20),
		"A minified source can immediately move to contact")
	source.scale = Vector2(0.25, 0.25)
	source.position = Vector2(15, 20)
	source.move_contact(0.0, 5.0, &"solid")
	_check(source.position == Vector2(20, 20),
		"An empty transformed bounding box does not invalidate a nonempty source mask")
	scene.free()


func _test_shared_animation_bounds_and_large_transforms() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#.."], ["..#"]])
	frames.add_animation(&"small")
	frames.add_frame(&"small", frames.get_frame_texture(&"default", 0))
	var mask := _mask(frames)
	var target := _sprite(scene, frames, mask, Vector2(10, 10), &"solid")
	target.scale = Vector2(1.5, 1.0)
	_footprint(probe, Vector2(10, 10), ["##.."],
		"Current-frame sampling retains the logical bounds shared by the animation")
	target.frame = 1
	_footprint(probe, Vector2(10, 10), ["...#"],
		"A frame change selects new pixels without tightening the shared animation bounds")
	target.frame = 0
	_meeting(probe, Vector2(11, 10), true,
		"Returning to the first frame restores the pixel beyond its individual tight bound")
	target.animation = &"small"
	_meeting(probe, Vector2(11, 10), false,
		"Shared logical bounds are scoped to the selected animation")
	target.animation = &"default"
	_meeting(probe, Vector2(11, 10), true,
		"Changing animation restores its shared bounds immediately")
	var path := "user://pixel_collision_integration_shared_bounds.tres"
	var save_error := ResourceSaver.save(mask, path)
	_check(save_error == OK, "A mask with animation-wide bounds saves successfully")
	if save_error == OK:
		var restored: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		_check(restored != null, "Animation-wide bounds reload with their baked mask")
		if restored != null:
			var restored_frames: SpriteFrames = restored.get_baked_source()
			var restored_target := _sprite(scene, restored_frames, restored, Vector2(50, 10), &"restored")
			restored_target.scale = Vector2(1.5, 1.0)
			_meeting(probe, Vector2(51, 10), true,
				"Reloading derives shared bounds without an explicit rebake", &"restored")
			restored_target.frame = 1
			_meeting(probe, Vector2(53, 10), true,
				"Reloaded frames retain their separate original pixels", &"restored")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var other := _sprite(scene, frames, mask, Vector2(30, 10), &"other")
	other.frame = 1
	other.scale = Vector2(0.5, 1.0)
	_meeting(probe, Vector2(11, 10), true,
		"Another transformed frame does not mutate the shared original mask")
	var pixel_frames := _frames([["#"]])
	target.sprite_frames = pixel_frames
	target.mask = _mask(pixel_frames)
	target.frame = 0
	target.scale = Vector2(32769, 1)
	_meeting(probe, Vector2(32778, 10), true,
		"On-demand sampling supports a transformed extent larger than the former raster limit")
	_meeting(probe, Vector2(32779, 10), false,
		"A very wide transformed mask retains its exact far boundary")
	target.scale = Vector2(8193, 8193)
	_meeting(probe, Vector2(8202, 8202), true,
		"A transformed area above the former bitmap allocation cap needs no transformed bitmap")
	target.scale = Vector2(65536, 65536)
	target.rotation_degrees = 45.0
	_meeting(probe, Vector2(10, 10), true,
		"A very large rotated collider can answer a one-pixel overlap query")
	scene.free()


func _test_frame_selection_and_shared_resources() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#."], [".#"]])
	var alternate := _frames([["..#"]])
	frames.add_animation(&"alternate")
	frames.add_frame(&"alternate", alternate.get_frame_texture(&"default", 0))
	var current_mask := _mask(frames, {"frame_mode": CURRENT_FRAME})
	var target := _sprite(scene, frames, current_mask, Vector2(10, 10), &"solid")
	var other := _sprite(scene, frames, current_mask, Vector2(20, 10), &"solid")
	other.frame = 1
	_meeting(probe, Vector2(10, 10), true, "Current frame zero selects its occupied pixel")
	_meeting(probe, Vector2(11, 10), false, "Current frame zero does not use frame-one occupancy")
	_meeting(probe, Vector2(20, 10), false, "Shared resource leaves each instance frame independent")
	_meeting(probe, Vector2(21, 10), true, "Second instance uses frame one from shared data")
	target.frame = 1
	_meeting(probe, Vector2(10, 10), false, "Frame change invalidates old occupancy in the same frame")
	_meeting(probe, Vector2(11, 10), true, "Frame change selects existing baked data immediately")
	target.mask = _mask(frames, {"frame_mode": ANIMATION_UNION})
	_meeting(probe, Vector2(10, 10), true, "Animation union includes frame-zero occupancy")
	_meeting(probe, Vector2(11, 10), true, "Animation union includes frame-one occupancy")
	target.mask = _mask(frames, {"frame_mode": FIXED_FRAME,
		"fixed_animation": &"default", "fixed_frame": 1})
	target.frame = 0
	_meeting(probe, Vector2(10, 10), false, "Fixed mask ignores displayed frame zero")
	_meeting(probe, Vector2(11, 10), true, "Fixed mask uses the selected baked frame")
	target.mask = current_mask
	target.animation = &"alternate"
	_meeting(probe, Vector2(12, 10), true, "Animation changes select the corresponding baked mask")
	_meeting(probe, Vector2(11, 10), false, "Animation changes discard the previous animation's mask")
	target.mask = _mask(frames, {"frame_mode": ANIMATION_UNION})
	target.animation = &"default"
	_meeting(probe, Vector2(12, 10), false, "Animation union does not include other animations")
	scene.free()


func _test_shape_configuration() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#.#"]])
	var target := _sprite(scene, frames, _mask(frames, {"shape_mode": RECTANGLE}),
		Vector2(10, 10), &"solid")
	_meeting(probe, Vector2(11, 10), true, "Automatic rectangle fills the opaque bounding box")
	var transparent := _frames([["....", "....", "...."]])
	target.sprite_frames = transparent
	target.mask = _mask(transparent, {"shape_mode": RECTANGLE,
		"manual_bounds": Rect2i(1, 1, 2, 1)})
	_meeting(probe, Vector2(11, 11), true, "Manual rectangle works with a transparent source")
	_meeting(probe, Vector2(12, 11), true, "Manual rectangle includes its final cell")
	_meeting(probe, Vector2(10, 11), false, "Manual rectangle excludes pixels to its left")
	_meeting(probe, Vector2(13, 11), false, "Manual rectangle excludes its exclusive end")
	var solid := _frames([["####"]])
	target.sprite_frames = solid
	target.mask = _mask(solid, {"shape_mode": PRECISE,
		"manual_bounds": Rect2i(1, 0, 2, 1)})
	_meeting(probe, Vector2(10, 10), false, "Precise manual bounds clip opaque pixels")
	_meeting(probe, Vector2(11, 10), true, "Precise manual bounds retain interior opaque pixels")
	_meeting(probe, Vector2(13, 10), false, "Precise manual bounds clip the opposite edge")
	var alpha_frames := _frames([["lh."]])
	target.sprite_frames = alpha_frames
	target.mask = _mask(alpha_frames, {"alpha_threshold": 0.5})
	_meeting(probe, Vector2(10, 10), false, "Alpha below the threshold is transparent")
	_meeting(probe, Vector2(11, 10), true, "Alpha above the threshold is occupied")
	_meeting(probe, Vector2(12, 10), false, "Zero alpha remains transparent")
	scene.free()


func _test_independent_mask_source() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var display_frames := _frames([["#####"]])
	var source_frames := _frames([["#."]])
	var mask := _mask(display_frames, {"source_frames": source_frames,
		"frame_mode": FIXED_FRAME, "fixed_animation": &"default",
		"fixed_frame": 0, "mask_offset": Vector2i(2, 1), "follow_sprite_flip": false})
	var target := _sprite(scene, display_frames, mask, Vector2(10, 10), &"solid")
	_meeting(probe, Vector2(12, 11), true, "Independent source uses its own pixels and mask offset")
	_meeting(probe, Vector2(14, 11), false, "Independent source does not adopt display dimensions")
	target.flip_h = true
	_meeting(probe, Vector2(12, 11), true, "Independent mask can ignore display flips")
	target.centered = true
	_meeting(probe, Vector2(11, 10), true, "Independent source dimensions determine centering")
	scene.free()


func _test_atlas_texture() -> void:
	var atlas_frames := _frames([["...#", "..#."]])
	var atlas := AtlasTexture.new()
	atlas.atlas = atlas_frames.get_frame_texture(&"default", 0)
	atlas.region = Rect2(2, 0, 2, 2)
	var frames := SpriteFrames.new()
	frames.add_frame(&"default", atlas)
	var scene := _scene()
	var probe := _probe(scene)
	_sprite(scene, frames, _mask(frames), Vector2(10, 10), &"solid")
	_meeting(probe, Vector2(10, 10), false, "Atlas region preserves its transparent upper-left pixel")
	_meeting(probe, Vector2(11, 10), true, "Atlas region converts source coordinates to local pixels")
	_meeting(probe, Vector2(10, 11), true, "Atlas region preserves the next row")
	_meeting(probe, Vector2(12, 10), false, "Atlas mask uses region dimensions rather than full texture dimensions")
	scene.free()


func _test_resource_invalidation() -> WeakRef:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["h"]])
	var mask := _mask(frames, {"alpha_threshold": 0.5})
	_sprite(scene, frames, mask, Vector2(10, 10), &"solid")
	_meeting(probe, Vector2(10, 10), true, "Initial baked resource is available to the node")
	mask.alpha_threshold = 0.9
	_check(not mask.is_baked_for(frames), "Mask configuration edits invalidate baked data")
	_meeting(probe, Vector2(10, 10), false, "Stale mask data is not silently reused")
	_check(mask.bake(frames) == OK, "Edited mask can be explicitly rebaked")
	_meeting(probe, Vector2(10, 10), false, "Rebaked alpha threshold updates existing nodes")
	mask.alpha_threshold = 0.5
	_check(mask.bake(frames) == OK, "Mask can be rebaked for its previous threshold")
	_meeting(probe, Vector2(10, 10), true, "Resource change refreshes existing colliders without reassignment")
	var transparent_frames := _frames([["."]])
	frames.set_frame(&"default", 0, transparent_frames.get_frame_texture(&"default", 0))
	_check(not mask.is_baked_for(frames), "Editing SpriteFrames invalidates the corresponding baked resource")
	_meeting(probe, Vector2(10, 10), false, "Changed source frames do not retain stale collider pixels")
	_check(mask.bake(frames) == OK, "Edited SpriteFrames can be explicitly rebaked")
	_meeting(probe, Vector2(10, 10), false, "Rebaking a transparent source removes occupied pixels")
	scene.free()
	return weakref(frames)


func _test_invalid_state() -> void:
	var scene := _scene()
	var probe := _probe(scene)
	var frames := _frames([["#"]])
	var target := _sprite(scene, frames, _mask(frames), Vector2(10, 10), &"solid")
	var invalid_bases := [
		[Vector2.ZERO, Vector2.DOWN, "Zero-scale target"],
		[Vector2(1, 1), Vector2(2, 2), "Singular target basis"],
		[Vector2(INF, 0), Vector2.DOWN, "Nonfinite target basis"],
		[Vector2(2251799813685248.0, 0), Vector2.DOWN, "Target exceeding the coordinate range"],
	]
	for invalid_basis in invalid_bases:
		target.transform = Transform2D(invalid_basis[0], invalid_basis[1], Vector2(10, 10))
		_meeting(probe, Vector2(10, 10), false, invalid_basis[2] + " is rejected")
	target.transform = Transform2D(0.0, Vector2(10, 10))
	_meeting(probe, Vector2(10, 10), true, "Restoring a valid transform restores collision")
	probe.transform = Transform2D(Vector2(1, 1), Vector2(2, 2), Vector2(1000, 1000))
	_meeting(probe, Vector2(10, 10), false, "A singular source basis is rejected")
	probe.transform = Transform2D(0.0, Vector2(1000, 1000))
	probe.collision_enabled = false
	_meeting(probe, Vector2(10, 10), false, "Disabled source cannot issue an active collision query")
	probe.collision_enabled = true
	var baked_mask: Resource = target.mask
	target.mask = null
	_meeting(probe, Vector2(10, 10), false, "Missing mask is not replaced by a rectangle")
	target.mask = ClassDB.instantiate(MASK_CLASS)
	_meeting(probe, Vector2(10, 10), false, "Unbaked mask is not replaced by a rectangle")
	target.mask = baked_mask
	_meeting(probe, Vector2(10, 10), true, "Assigning valid baked data restores collision")
	var orphan := _probe(root)
	_meeting(orphan, Vector2(10, 10), true, "A root-level source can query sprites in a separate branch")
	root.remove_child(orphan)
	_meeting(orphan, Vector2(10, 10), false, "A detached source cannot query sprites still in the tree")
	orphan.free()
	var unequal_frames := _frames([["#."], ["..#"]])
	var union_mask: Resource = ClassDB.instantiate(MASK_CLASS)
	union_mask.frame_mode = ANIMATION_UNION
	_check(union_mask.bake(unequal_frames) != OK,
		"Animation union rejects unequal logical frame dimensions explicitly")
	_check(not union_mask.get_bake_error().is_empty(),
		"Unsupported union dimensions provide an authoring diagnostic")
	scene.free()


func _test_move_contact_directions_and_distance() -> void:
	var scene := _scene()
	var frames := _frames([["#"]])
	var mask := _mask(frames)
	var source := _sprite(scene, frames, mask)
	var target := _sprite(scene, frames, mask, Vector2.ZERO, &"solid")
	var cardinal_cases := [
		[0.0, Vector2.RIGHT], [90.0, Vector2.UP],
		[180.0, Vector2.LEFT], [270.0, Vector2.DOWN],
		[360.0, Vector2.RIGHT], [-90.0, Vector2.DOWN],
		[450.0, Vector2.UP], [-450.0, Vector2.DOWN],
	]
	for test_case in cardinal_cases:
		var direction: float = test_case[0]
		var step: Vector2 = test_case[1]
		source.position = Vector2.ZERO
		target.position = step * 4.0
		source.move_contact(direction, 20.0, &"solid")
		_check(source.position == step * 3.0,
			"move_contact uses exact cardinal steps and normalized degrees: %s" % direction)
	target.collision_enabled = false
	for distance in [0.1, 0.9, 1.0, 1.9, 3.99, 1001.9]:
		source.position = Vector2.ZERO
		source.move_contact(0.0, distance, &"solid")
		_check(source.position == Vector2(floor(distance), 0.0),
			"move_contact uses complete unit steps for positive distance: %s" % distance)
	for distance in [0.0, -0.1, -25.0]:
		source.position = Vector2.ZERO
		source.move_contact(0.0, distance, &"solid")
		_check(source.position == Vector2(1000, 0),
			"Nonpositive finite move_contact distance selects the 1000-step cap: %s" % distance)
	source.position = Vector2.ZERO
	target.collision_enabled = true
	target.position = Vector2(4, 0)
	source.move_contact(0.0, 0.0, &"solid")
	_check(source.position == Vector2(3, 0),
		"The default 1000-step cap still stops at the first obstacle")
	source.position = Vector2.ZERO
	target.position = Vector2(2, -2)
	source.move_contact(45.0, 10.0, &"solid")
	_check(source.position.is_equal_approx(Vector2(1, -1).normalized() * 2.0),
		"Diagonal contact advances one normalized direction vector per step")
	_meeting(source, source.global_position, false,
		"Diagonal contact leaves the source outside the first occupied pixel")
	source.position = Vector2.ZERO
	target.position = Vector2(1, 0)
	source.move_contact(315.0, 3.0, &"solid")
	_check(source.position.is_equal_approx(Vector2.ONE.normalized() * 3.0),
		"Diagonal contact follows the diagonal without separate horizontal or vertical sweeps")
	scene.free()


func _test_move_contact_groups_and_global_scope() -> void:
	var scene := _scene()
	var other_scene := _scene()
	var frames := _frames([["#"]])
	var mask := _mask(frames)
	var source := _sprite(scene, frames, mask, Vector2.ZERO, &"mover")
	var solid := _sprite(scene, frames, mask, Vector2(3, 0), &"solid")
	var hazard := _sprite(scene, frames, mask, Vector2(6, 0), &"hazard")
	var cross_scene_hazard := _sprite(other_scene, frames, mask, Vector2(1, 0), &"hazard")
	source.move_contact(0.0, 10.0, &"hazard")
	_check(source.position == Vector2.ZERO,
		"move_contact stops at matching groups in another scene branch")
	cross_scene_hazard.free()
	source.move_contact(0.0, 10.0, &"hazard")
	_check(source.position == Vector2(5, 0),
		"move_contact ignores unrelated groups and observes cross-scene collider removal")
	source.position = Vector2.ZERO
	hazard.remove_from_group(&"hazard")
	source.move_contact(0.0, 10.0, &"hazard")
	_check(source.position == Vector2(10, 0),
		"move_contact sees removed group membership on the next call")
	source.position = Vector2.ZERO
	hazard.add_to_group(&"hazard")
	source.move_contact(0.0, 10.0, &"hazard")
	_check(source.position == Vector2(5, 0),
		"move_contact sees added group membership on the next call")
	source.position = Vector2.ZERO
	source.move_contact(0.0, 10.0, &"")
	_check(source.position == Vector2(2, 0),
		"An explicit empty group lets move_contact match every eligible registered sprite")
	source.position = Vector2.ZERO
	source.move_contact(0.0, 10.0, &"mover")
	_check(source.position == Vector2(10, 0),
		"move_contact excludes the source from its own group")
	source.position = Vector2.ZERO
	solid.position = Vector2.ZERO
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2.ZERO,
		"Starting inside a matching collider leaves move_contact at its original position")
	source.move_contact(0.0, 10.0, &"hazard")
	_check(source.position == Vector2(5, 0),
		"An initial overlap with an unrelated group does not prevent move_contact")
	source.position = Vector2.ZERO
	solid.position = Vector2(3, 0)
	solid.collision_enabled = false
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(10, 0),
		"move_contact ignores collision-disabled candidates")
	source.position = Vector2.ZERO
	solid.collision_enabled = true
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(2, 0),
		"move_contact sees reenabled candidates immediately")
	source.position = Vector2.ZERO
	solid.queue_free()
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(10, 0),
		"move_contact excludes queued-for-deletion candidates before the tree flush")
	var observer := _probe(scene)
	_meeting(observer, Vector2(10, 0), true,
		"A query immediately after move_contact sees the source's new position", &"mover")
	_meeting(observer, Vector2.ZERO, false,
		"A query immediately after move_contact no longer sees the old position", &"mover")
	scene.free()
	other_scene.free()


func _test_move_contact_pixels_and_transforms() -> void:
	var scene := _scene()
	var source := _probe(scene)
	var cavity_frames := _frames([["#####", "#...#", "#####"]])
	var target := _sprite(scene, cavity_frames, _mask(cavity_frames), Vector2.ZERO, &"solid")
	source.position = Vector2(1, 1)
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.position == Vector2(3, 1),
		"move_contact moves through a transparent cavity before reaching its opaque edge")
	var pixel_frames := _frames([["#"]])
	target.sprite_frames = pixel_frames
	target.mask = _mask(pixel_frames)
	source.position = Vector2(-2.2, 0)
	source.move_contact(0.0, 100.0, &"solid")
	_check(source.position.is_equal_approx(Vector2(-1.2, 0)),
		"move_contact cannot skip a thin wall from a negative fractional origin")
	source.position = Vector2(0.25, 0)
	target.position = Vector2(4, 0)
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(3.25, 0),
		"move_contact retains the starting subpixel offset while truncating query coordinates")
	var asymmetric_frames := _frames([["#.."]])
	source.sprite_frames = asymmetric_frames
	source.mask = _mask(asymmetric_frames)
	source.position = Vector2.ZERO
	source.flip_h = true
	target.position = Vector2(6, 0)
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.position == Vector2(3, 0),
		"move_contact uses the source's current flipped occupancy")
	source.position = Vector2.ZERO
	source.flip_h = false
	source.scale = Vector2(2, 1)
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.position == Vector2(4, 0),
		"move_contact accounts for enlarged integer-scaled source pixels")
	source.position = Vector2.ZERO
	source.scale = Vector2(-1, 1)
	var reflected_frames := _frames([["##."]])
	source.sprite_frames = reflected_frames
	source.mask = _mask(reflected_frames)
	target.position = Vector2(4, 0)
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.position == Vector2(4, 0),
		"move_contact respects negative source scale around the node origin")
	scene.free()

	scene = _scene()
	var parent := Node2D.new()
	parent.position = Vector2(10, 20)
	parent.scale = Vector2(2, 2)
	scene.add_child(parent)
	source = _sprite(parent, pixel_frames, _mask(pixel_frames), Vector2.ZERO, &"mover")
	target = _sprite(scene, pixel_frames, _mask(pixel_frames), Vector2(16, 20), &"solid")
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.global_position == Vector2(14, 20) and source.position == Vector2(2, 0),
		"move_contact uses global unit steps and commits the corresponding local position")
	source.position = Vector2.ZERO
	parent.position = Vector2(20, 30)
	target.position = Vector2(26, 30)
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.global_position == Vector2(24, 30),
		"move_contact immediately observes both parent and target movement in the same frame")
	var observer := _probe(scene)
	_meeting(observer, Vector2(25, 31), true,
		"The moved scaled mask is immediately available to other queries", &"mover")
	_meeting(observer, Vector2(20, 30), false,
		"Moving a parented source removes its previous occupied cells immediately", &"mover")
	source.set_as_top_level(true)
	source.position = Vector2.ZERO
	target.position = Vector2(4, 0)
	source.move_contact(0.0, 20.0, &"solid")
	_check(source.global_position == Vector2(3, 0) and source.position == Vector2(3, 0),
		"A top-level source bypasses its transformed parent during move_contact")
	scene.free()


func _test_move_contact_numeric_boundaries() -> void:
	var scene := _scene()
	var parent := Node2D.new()
	parent.scale = Vector2(3, 1)
	scene.add_child(parent)
	var frames := _frames([["#"]])
	var mask := _mask(frames)
	var source := _sprite(parent, frames, mask)
	var target := _sprite(scene, frames, mask, Vector2(-8, 0), &"solid")
	source.move_contact(180.0, 20.0, &"solid")
	_meeting(source, source.global_position, false,
		"Parent inverse-transform rounding cannot commit a colliding move_contact endpoint")
	_check(source.global_position.is_equal_approx(Vector2(-7, 0)),
		"Parent-rounded contact uses the nearest safe truncated cell: %s" % source.global_position)
	scene.free()

	scene = _scene()
	source = _sprite(scene, frames, mask, Vector2(16777218, 0))
	target = _sprite(scene, frames, _mask(frames, {"mask_offset": Vector2i(1, 0)}),
		Vector2(16777216, 0), &"solid")
	source.move_contact(180.0, 1.0, &"solid")
	_check(source.global_position == Vector2(16777218, 0),
		"A floating-point step that would jump over a pixel stops before changing position")
	_meeting(source, source.global_position, false,
		"Stopping at a floating-point grid boundary preserves a collision-free source")
	scene.free()


func _test_move_contact_invalid_state() -> void:
	var scene := _scene()
	var frames := _frames([["#"]])
	var mask := _mask(frames)
	var source := _sprite(scene, frames, mask, Vector2(7, 9))
	print("EXPECTED: Seven invalid move_contact argument calls emit native error diagnostics.")
	for invalid_call in [[NAN, 10.0], [INF, 10.0], [-INF, 10.0],
			[0.0, NAN], [0.0, INF], [0.0, -INF], [0.0, 2147483648.0]]:
		source.move_contact(invalid_call[0], invalid_call[1], &"solid")
		_check(source.position == Vector2(7, 9),
			"Invalid move_contact arguments do not mutate the source: %s" % [invalid_call])
	source.collision_enabled = false
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(7, 9), "A disabled source cannot move_contact")
	source.collision_enabled = true
	source.mask = null
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(7, 9), "A missing source mask prevents move_contact")
	source.mask = ClassDB.instantiate(MASK_CLASS)
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(7, 9), "An unbaked source mask prevents move_contact")
	var empty_frames := _frames([["."]])
	source.sprite_frames = empty_frames
	source.mask = _mask(empty_frames)
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(7, 9), "An empty source mask prevents move_contact")
	source.sprite_frames = frames
	source.mask = mask
	var invalid_bases := [
		[Vector2.ZERO, Vector2.DOWN, "Zero-scale source"],
		[Vector2(1, 1), Vector2(2, 2), "Singular source basis"],
		[Vector2(INF, 0), Vector2.DOWN, "Nonfinite source basis"],
		[Vector2(2251799813685248.0, 0), Vector2.DOWN, "Source exceeding the coordinate range"],
	]
	for invalid_basis in invalid_bases:
		source.transform = Transform2D(invalid_basis[0], invalid_basis[1], Vector2(7, 9))
		source.move_contact(0.0, 10.0, &"solid")
		_check(source.transform.origin == Vector2(7, 9), invalid_basis[2] + " prevents move_contact")
	source.transform = Transform2D(0.0, Vector2(7, 9))
	scene.remove_child(source)
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(7, 9), "A source outside the scene tree cannot move_contact")
	scene.add_child(source)
	source.queue_free()
	source.move_contact(0.0, 10.0, &"solid")
	_check(source.position == Vector2(7, 9), "A source queued for deletion cannot move_contact")
	var detached_parent := Node2D.new()
	var orphan := _sprite(detached_parent, frames, mask, Vector2(7, 9))
	orphan.move_contact(0.0, 10.0, &"solid")
	_check(orphan.position == Vector2(7, 9), "A source in an uninstantiated scene cannot move_contact")
	detached_parent.free()
	scene.free()


func _test_serialization() -> void:
	var frames := _frames([["###", "#.#", "###"]])
	var mask := _mask(frames)
	var path := "user://pixel_collision_integration_mask.tres"
	var error := ResourceSaver.save(mask, path)
	_check(error == OK, "Baked mask can be saved as a Resource")
	if error != OK:
		return
	var restored: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(restored != null and restored.is_class(MASK_CLASS), "Reloaded mask retains its native Resource class")
	if restored != null:
		var restored_frames: SpriteFrames = restored.get_baked_source()
		_check(restored_frames != null, "Baked data retains serialized source frames")
		if restored_frames != null:
			_check(restored.is_baked_for(restored_frames), "Reloaded mask validates without rebaking")
			var scene := _scene()
			var probe := _probe(scene)
			_sprite(scene, restored_frames, restored, Vector2(10, 10), &"solid")
			_meeting(probe, Vector2(11, 11), false, "Reloaded baked data preserves transparent holes")
			_meeting(probe, Vector2(10, 11), true, "Reloaded baked data preserves occupied pixels")
			scene.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_external_source_validation() -> void:
	var texture_path := "user://pixel_collision_integration_source.tres"
	var mask_path := "user://pixel_collision_integration_external_mask.tres"
	var generated := _frames([["#."]])
	var texture := generated.get_frame_texture(&"default", 0)
	var error := ResourceSaver.save(texture, texture_path)
	_check(error == OK, "External source fixture saves successfully")
	if error != OK:
		return
	texture.take_over_path(texture_path)
	var frames := SpriteFrames.new()
	frames.add_frame(&"default", texture)
	var mask := _mask(frames)
	error = ResourceSaver.save(mask, mask_path)
	_check(error == OK, "Mask with an external texture dependency saves successfully")
	if error == OK:
		var file := FileAccess.open(texture_path, FileAccess.READ_WRITE)
		_check(file != null, "External source fixture can be changed after baking")
		if file != null:
			file.seek_end()
			file.store_string("\n; Integration fixture changed after collision baking.\n")
			file.close()
			var restored: Resource = ResourceLoader.load(mask_path, "", ResourceLoader.CACHE_MODE_IGNORE)
			_check(restored != null, "Mask still loads after an external file changes")
			if restored != null:
				_check(not restored.validate_source_files(),
					"Authoring validation rejects changed external source data even with unchanged dimensions")
				_check(restored.is_baked_for(restored.get_baked_source()),
					"Runtime baked-data validation does not depend on original source files")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(mask_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(texture_path))


func _test_external_atlas_serialization() -> void:
	var texture_path := "user://pixel_collision_integration_atlas.tres"
	var frames_path := "user://pixel_collision_integration_atlas_frames.tres"
	var mask_path := "user://pixel_collision_integration_atlas_mask.tres"
	var generated := _frames([["...#", "..#."]])
	var texture := generated.get_frame_texture(&"default", 0)
	_check(ResourceSaver.save(texture, texture_path) == OK, "Atlas source texture saves as an external resource")
	texture.take_over_path(texture_path)
	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = Rect2(2, 0, 2, 2)
	var frames := SpriteFrames.new()
	frames.add_frame(&"default", atlas)
	_check(ResourceSaver.save(frames, frames_path) == OK, "SpriteFrames with atlas subresources saves independently")
	frames.take_over_path(frames_path)
	var mask := _mask(frames)
	_check(ResourceSaver.save(mask, mask_path) == OK, "Atlas mask saves separately from its external SpriteFrames")
	var restored: Resource = ResourceLoader.load(mask_path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	_check(restored != null, "Atlas mask and its external dependencies reload without cache reuse")
	if restored != null:
		var restored_frames: SpriteFrames = restored.get_baked_source()
		_check(restored_frames != null, "Reloaded atlas mask retains its external SpriteFrames source")
		if restored_frames != null:
			_check(restored.is_baked_for(restored_frames),
				"Atlas layout validation survives separate serialized subresource identities")
			_check(restored.validate_source_files(), "Reloaded atlas source files match baked dependency fingerprints")
			var scene := _scene()
			var probe := _probe(scene)
			_sprite(scene, restored_frames, restored, Vector2(10, 10), &"solid")
			_meeting(probe, Vector2(10, 10), false, "Reloaded external atlas mask preserves its transparent pixel")
			_meeting(probe, Vector2(11, 10), true, "Reloaded external atlas mask preserves its occupied pixel")
			scene.free()
	for path in [mask_path, frames_path, texture_path]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
