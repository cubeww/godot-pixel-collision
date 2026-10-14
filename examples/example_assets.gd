extends RefCounted
## Shared authoring assets used by the playground and the node benchmark.
## Runtime code only loads baked resources; it never reads texture pixels.

const PLAYER_FRAMES: SpriteFrames = preload("res://examples/resources/player_frames.tres")
const PLAYER_MASK: PixelCollisionMask = preload("res://examples/resources/player_mask.tres")
const BLOCK_FRAMES: SpriteFrames = preload("res://examples/resources/block_frames.tres")
const BLOCK_MASK: PixelCollisionMask = preload("res://examples/resources/block_mask.tres")
const SPIKE_FRAMES: SpriteFrames = preload("res://examples/resources/spike_frames.tres")
const SPIKE_MASK: PixelCollisionMask = preload("res://examples/resources/spike_mask.tres")
const BLOOD_FRAMES: SpriteFrames = preload("res://examples/resources/blood_frames.tres")
const BLOOD_MASK: PixelCollisionMask = preload("res://examples/resources/blood_mask.tres")


static func validate() -> bool:
	for pair in [[PLAYER_MASK, PLAYER_FRAMES], [BLOCK_MASK, BLOCK_FRAMES],
			[SPIKE_MASK, SPIKE_FRAMES], [BLOOD_MASK, BLOOD_FRAMES]]:
		if not pair[0].is_baked_for(pair[1]):
			push_error("Example mask needs baking: %s. Run examples/bake_example_masks.gd once after importing assets." % pair[0].resource_path)
			return false
	return true


static func make_sprite(frames: SpriteFrames, shared_mask: PixelCollisionMask,
		at: Vector2, group: StringName = &"") -> MaskedAnimatedSprite2D:
	var sprite := MaskedAnimatedSprite2D.new()
	sprite.sprite_frames = frames
	sprite.mask = shared_mask
	sprite.position = at
	sprite.centered = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.pause()
	if group != &"":
		sprite.add_to_group(group)
	return sprite
