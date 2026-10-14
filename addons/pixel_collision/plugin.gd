@tool
extends EditorPlugin

const MaskInspector = preload("res://addons/pixel_collision/mask_inspector.gd")
const MaskExport = preload("res://addons/pixel_collision/mask_export.gd")
const BAKE_DELAY := 0.25
const POLL_INTERVAL := 0.2
const MENU_NAME := "Bake Pixel Collision Masks in Current Scene"

var _inspector: EditorInspectorPlugin
var _exporter: EditorExportPlugin
var _selected: Node2D
var _watched: Array[Resource] = []
var _signature := 0
var _poll_elapsed := 0.0
var _pending_bake := -1.0
var _baking := false
var _preview: ImageTexture
var _preview_key: Array = []
var _preview_limited := false


func _enter_tree() -> void:
	_inspector = MaskInspector.new()
	_inspector.controller = self
	add_inspector_plugin(_inspector)
	_exporter = MaskExport.new()
	_exporter.controller = self
	add_export_plugin(_exporter)
	get_editor_interface().get_selection().selection_changed.connect(_selection_changed)
	get_editor_interface().get_resource_filesystem().resources_reimported.connect(_resources_reimported)
	add_tool_menu_item(MENU_NAME, _bake_current_scene)
	set_process(true)
	_selection_changed()


func _exit_tree() -> void:
	_disconnect_resources()
	get_editor_interface().get_selection().selection_changed.disconnect(_selection_changed)
	get_editor_interface().get_resource_filesystem().resources_reimported.disconnect(_resources_reimported)
	remove_tool_menu_item(MENU_NAME)
	remove_export_plugin(_exporter)
	remove_inspector_plugin(_inspector)
	_selected = null
	_preview = null


func _handles(object: Object) -> bool:
	return is_instance_valid(object) and (object.is_class("MaskedAnimatedSprite2D") or object.is_class("MaskedSprite2D"))


func _edit(object: Object) -> void:
	if _handles(object):
		_select(object as Node2D)


func _apply_changes() -> void:
	# Flush the debounce before the editor serializes the scene or changes tabs.
	if _pending_bake >= 0.0 and is_instance_valid(_selected):
		_pending_bake = -1.0
		bake_target(_selected)


func _selection_changed() -> void:
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	if nodes.size() == 1 and _handles(nodes[0]):
		_select(nodes[0] as Node2D)
	else:
		_select(null)


func _select(sprite: Node2D) -> void:
	if _selected == sprite:
		return
	_disconnect_resources()
	_selected = sprite
	_signature = 0
	_pending_bake = -1.0
	_invalidate_preview()
	_poll_selected()


func _process(delta: float) -> void:
	_poll_elapsed += delta
	if _poll_elapsed >= POLL_INTERVAL:
		_poll_elapsed = 0.0
		_poll_selected()
	if _pending_bake >= 0.0:
		_pending_bake -= delta
		if _pending_bake <= 0.0:
			_pending_bake = -1.0
			if is_instance_valid(_selected):
				bake_target(_selected)
	if is_instance_valid(_selected):
		# Camera, parent transforms, frame changes, and flips can change independently.
		update_overlays()


func mask_for(target: Object) -> Resource:
	if not is_instance_valid(target):
		return null
	if target.is_class("PixelCollisionMask"):
		return target as Resource
	if _handles(target):
		return target.get("mask") as Resource
	return null


func _sprite_for(target: Object) -> Node2D:
	if _handles(target):
		return target as Node2D
	if is_instance_valid(_selected) and mask_for(_selected) == mask_for(target):
		return _selected
	return null


func _frames_for(target: Object) -> SpriteFrames:
	var mask := mask_for(target)
	if mask == null:
		return null
	var independent := mask.get("source_frames") as SpriteFrames
	if independent != null:
		return independent
	var sprite := _sprite_for(target)
	if sprite is AnimatedSprite2D:
		return sprite.sprite_frames
	return null


func _is_baked_for(mask: Resource, target: Object) -> bool:
	var sprite := _sprite_for(target)
	if sprite is Sprite2D:
		return bool(mask.call("is_baked_for_sprite", sprite))
	return bool(mask.call("is_baked_for", _frames_for(target)))


func _source_identity(mask: Resource, sprite: Node2D) -> Array:
	var independent := mask.get("source_frames") as SpriteFrames
	if independent != null:
		return [independent]
	if sprite is AnimatedSprite2D:
		return [sprite.sprite_frames]
	if sprite is Sprite2D:
		# Frame selection changes occupancy, not the sheet that is baked and shared.
		return [sprite.texture, sprite.hframes, sprite.vframes, sprite.region_enabled, sprite.region_rect if sprite.region_enabled else Rect2()]
	return []


func status_for(target: Object) -> String:
	var mask := mask_for(target)
	if mask == null:
		return "Create a shared mask, then edit its properties below. Groups on this sprite are collision query tags."
	var sprite := _sprite_for(target)
	if _frames_for(target) == null:
		if not sprite is Sprite2D:
			return "Assign SpriteFrames to the sprite, or Source Frames to this mask."
		if sprite.texture == null:
			return "Assign a texture to the sprite, or Source Frames to this mask."
	if _is_baked_for(mask, target):
		return "Baked. The selected sprite's mask is shown in cyan in the 2D viewport."
	var reason := String(mask.call("get_bake_error"))
	return "Needs baking." if reason.is_empty() else "Needs baking: " + reason


func create_mask(target: Object) -> void:
	if not _handles(target) or not ClassDB.can_instantiate("PixelCollisionMask"):
		return
	if mask_for(target) != null:
		return
	var mask := ClassDB.instantiate("PixelCollisionMask") as Resource
	var undo := get_undo_redo()
	undo.create_action("Create Pixel Collision Mask")
	undo.add_do_property(target, "mask", mask)
	undo.add_undo_property(target, "mask", null)
	undo.commit_action()
	_poll_selected()


func bake_target(target: Object) -> bool:
	var mask := mask_for(target)
	if mask == null:
		return false
	var error := _bake(mask, target)
	if not error.is_empty():
		push_error("Pixel Collision: " + error)
		return false
	return true


func _bake(mask: Resource, target: Object) -> String:
	_baking = true
	var sprite := _sprite_for(target)
	var result: int
	if sprite is Sprite2D:
		result = mask.call("bake_sprite", sprite)
	else:
		result = mask.call("bake", _frames_for(target))
	_baking = false
	_invalidate_preview()
	if result != OK:
		return "Mask bake failed: " + String(mask.call("get_bake_error"))
	# External masks own their serialized cache. Inline masks are saved with the scene.
	var path := mask.resource_path
	if not path.is_empty() and not path.contains("::"):
		var save_error := ResourceSaver.save(mask)
		if save_error != OK:
			return "Could not save baked mask at %s (error %d)." % [path, save_error]
	get_editor_interface().mark_scene_as_unsaved()
	return ""


func _poll_selected() -> void:
	if not is_instance_valid(_selected):
		return
	var mask := mask_for(_selected)
	var resources: Array[Resource] = []
	if mask != null:
		resources.append(mask)
		var source := mask.get("source_frames") as Resource
		if source != null:
			resources.append(source)
	var visual_source: Resource
	if _selected is AnimatedSprite2D:
		visual_source = _selected.sprite_frames
	elif _selected is Sprite2D:
		visual_source = _selected.texture
	if visual_source != null and not resources.has(visual_source):
		resources.append(visual_source)
	if resources != _watched:
		_disconnect_resources()
		_watched = resources
		for resource in _watched:
			resource.changed.connect(_resource_changed)
	var signature := _structural_signature(mask, _selected)
	if signature != _signature:
		var previously_observed := _signature != 0
		_signature = signature
		_invalidate_preview()
		# Object identity detects inline texture replacements that have the same
		# serialized layout and may not emit a SpriteFrames changed signal.
		if mask != null and (previously_observed or not _is_baked_for(mask, _selected)):
			_pending_bake = BAKE_DELAY


func _structural_signature(mask: Resource, sprite: Node2D) -> int:
	if mask == null:
		return 0
	var source := _frames_for(sprite)
	var values: Array = [mask.get_instance_id(), _source_identity(mask, sprite)]
	for property in ["shape_mode", "frame_mode", "alpha_threshold", "manual_bounds", "fixed_animation", "fixed_frame"]:
		values.append(mask.get(property))
	if source != null:
		# SpriteFrames animation rename/remove operations do not all emit changed.
		for animation in source.get_animation_names():
			values.append(animation)
			values.append(source.get_frame_count(animation))
			for frame in source.get_frame_count(animation):
				var texture := source.get_frame_texture(animation, frame)
				values.append(texture)
				if texture != null:
					values.append(texture.get_size())
	elif sprite is Sprite2D and sprite.texture != null:
		values.append(sprite.texture.get_size())
	return hash(values)


func _resource_changed() -> void:
	if _baking:
		return
	_invalidate_preview()
	_pending_bake = BAKE_DELAY


func _disconnect_resources() -> void:
	for resource in _watched:
		if is_instance_valid(resource) and resource.changed.is_connected(_resource_changed):
			resource.changed.disconnect(_resource_changed)
	_watched.clear()


func _invalidate_preview() -> void:
	_preview = null
	_preview_key.clear()
	_preview_limited = false
	update_overlays()


func _update_preview_data() -> Dictionary:
	if not is_instance_valid(_selected):
		return {}
	var mask := mask_for(_selected)
	if mask == null or not _is_baked_for(mask, _selected):
		_preview = null
		_preview_key.clear()
		_preview_limited = false
		return {}
	var follow_flip := bool(mask.get("follow_sprite_flip"))
	var world := _selected.get_global_transform()
	var animation: StringName = _selected.animation if _selected is AnimatedSprite2D else &"default"
	var key: Array = [mask, animation, _selected.get("frame"), _selected.get("flip_h"), _selected.get("flip_v"), follow_flip, _selected.get("centered"), _selected.get("offset"), mask.get("mask_offset"), world.x, world.y, world.origin]
	var needs_image := key != _preview_key or (_preview == null and not _preview_limited)
	# Native code samples the original mask at integer world positions. Translation
	# can change the clipped pixels, so placement is part of the image cache key.
	var data: Dictionary = _selected.call("_get_collision_preview", needs_image)
	if typeof(data.get("rect")) != TYPE_RECT2:
		_preview = null
		_preview_key.clear()
		_preview_limited = false
		return {}
	var rect: Rect2 = data["rect"]
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		_preview = null
		_preview_key.clear()
		_preview_limited = false
		return {}
	if bool(data.get("preview_limited", false)):
		_preview = null
		_preview_key = key
		_preview_limited = true
		return {"rect": rect, "texture": null, "preview_limited": true}
	if needs_image:
		var image := data.get("image") as Image
		if image == null or image.is_empty():
			_preview = null
			_preview_key.clear()
			_preview_limited = false
			return {}
		_preview = ImageTexture.create_from_image(image)
		_preview_key = key
		_preview_limited = false
	if _preview == null:
		return {}
	return {"rect": rect, "texture": _preview}


func _forward_canvas_draw_over_viewport(overlay: Control) -> void:
	if not is_instance_valid(_selected) or not _selected.is_visible_in_tree():
		return
	var data := _update_preview_data()
	if data.is_empty():
		return
	var rect: Rect2 = data["rect"]
	var view := get_editor_interface().get_editor_viewport_2d()
	# The sampled rect is already in global sprite coordinates; apply only the
	# canvas and editor view transforms, not the sprite's basis a second time.
	var transform := view.global_canvas_transform * _selected.get_canvas_transform()
	overlay.draw_set_transform_matrix(transform)
	if _preview != null:
		overlay.draw_texture_rect(_preview, rect, false, Color(0.1, 1.0, 1.0, 0.5))
	overlay.draw_rect(rect, Color(0.1, 0.9, 1.0, 0.8), false, 1.0)
	overlay.draw_set_transform_matrix(Transform2D.IDENTITY)


func _sprites_in_scene(root: Node) -> Array[Node]:
	var sprites: Array[Node] = []
	if root == null:
		return sprites
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if _handles(node):
			sprites.append(node)
		for child in node.get_children():
			pending.append(child)
	return sprites


func _validate_current_scene(rebake: bool, force: bool = false) -> Dictionary:
	var errors: Array[String] = []
	var baked := 0
	var sources: Dictionary = {}
	var checked: Dictionary = {}
	for sprite in _sprites_in_scene(get_editor_interface().get_edited_scene_root()):
		var mask := mask_for(sprite)
		if mask == null:
			if bool(sprite.get("collision_enabled")):
				errors.append("%s has collision enabled but no mask." % sprite.name)
			continue
		var effective := _source_identity(mask, sprite as Node2D)
		var id := mask.get_instance_id()
		if sources.has(id) and sources[id] != effective:
			errors.append("%s shares a mask across different sprite sources or sheet layouts. Use separate masks or set Source Frames." % sprite.name)
			continue
		sources[id] = effective
		if checked.has(id):
			continue
		checked[id] = true
		var current := _is_baked_for(mask, sprite)
		if rebake and (force or not current):
			var error := _bake(mask, sprite)
			if not error.is_empty():
				errors.append("%s: %s" % [sprite.name, error])
			else:
				baked += 1
		elif not current:
			errors.append("%s has missing or stale baked mask data." % sprite.name)
	return {"errors": errors, "baked": baked}


func _bake_current_scene() -> void:
	var result := _validate_current_scene(true, true)
	_report_errors(result)
	print("Pixel Collision: baked %d mask(s) in the current scene. Save the scene to persist inline masks." % result.baked)


func _resources_reimported(_paths: PackedStringArray) -> void:
	# Reimport can change pixels while texture identities and sizes remain unchanged.
	var result := _validate_current_scene(true, true)
	_report_errors(result)


func _build() -> bool:
	_pending_bake = -1.0
	var result := _validate_current_scene(true)
	_report_errors(result)
	if not result.errors.is_empty():
		return false
	if result.baked > 0:
		# Godot's regular save-before-run happens before EditorPlugin._build().
		var root := get_editor_interface().get_edited_scene_root()
		if root != null and not root.scene_file_path.is_empty():
			var error := get_editor_interface().save_scene()
			if error != OK:
				push_error("Pixel Collision: could not save baked masks before running.")
				return false
	return true


func validate_export_scene() -> void:
	var result := _validate_current_scene(false)
	_report_errors(result)
	if not result.errors.is_empty():
		push_error("Pixel Collision: export validation found invalid masks in the current scene. This hook reports errors but cannot cancel export. Bake and save before exporting.")
	print("Pixel Collision: export validation covers only the currently edited scene. Unopened scenes and dynamically loaded assets must be baked and saved separately.")


func _report_errors(result: Dictionary) -> void:
	for error in result.errors:
		push_error("Pixel Collision: " + String(error))
