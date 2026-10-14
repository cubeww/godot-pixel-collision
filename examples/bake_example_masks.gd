extends SceneTree
## One-time authoring command, never part of a particle update or collision query.
## Run after --editor --headless --import, then commit the saved mask resources.


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var exit_code := _bake_all()
	# Let the authoring scope release resources and deferred work finish before exit.
	await process_frame
	quit(exit_code)


func _bake_all() -> int:
	for kind in ["player", "block", "spike", "blood"]:
		var frames := load("res://examples/resources/%s_frames.tres" % kind) as SpriteFrames
		var path := "res://examples/resources/%s_mask.tres" % kind
		var shared_mask := load(path) as PixelCollisionMask
		if frames == null or shared_mask == null:
			push_error("Could not load authoring assets for %s." % kind)
			return 1
		var result := shared_mask.bake(frames)
		if result != OK:
			push_error("Mask bake failed: %s" % shared_mask.get_bake_error())
			return 1
		result = ResourceSaver.save(shared_mask, path)
		if result != OK:
			push_error("Could not save %s: %s" % [path, error_string(result)])
			return 1
		print("Baked and saved ", path)
	return 0
