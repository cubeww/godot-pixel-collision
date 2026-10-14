extends SceneTree
## Functional checks: atlas occupancy, contact response, and particle trajectories.
## This script does not collect timing or rendering performance measurements.

const Assets = preload("res://examples/example_assets.gd")
const BenchmarkScene = preload("res://examples/blood_benchmark.tscn")
const EXPECTED_PIXELS := [
	[0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
	[0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
	[0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0],
]
const EXPECTED_BOUNDS := [Rect2i(1, 1, 2, 1), Rect2i(2, 1, 1, 1), Rect2i(1, 1, 2, 2)]


func _initialize() -> void:
	call_deferred("_verify")


func _verify() -> void:
	if not Assets.validate() or not _check_atlas():
		quit(1)
		return
	var benchmark = _make_benchmark()
	var passed := _check_contact_fixtures(benchmark) and _check_settled(benchmark)
	benchmark.free()
	if PixelCollision.get_collider_count() != 0:
		push_error("Contact fixture room left registered colliders after destruction.")
		passed = false
	if passed:
		benchmark = _make_benchmark()
		passed = _check_burst(benchmark)
		benchmark.free()
	if PixelCollision.get_collider_count() != 0:
		push_error("Burst room left registered colliders after destruction.")
		passed = false
	if passed:
		print("PASS: atlas occupancy, explicit contact responses, 800 settled queries, and 800-particle terrain separation over 240 burst steps.")
	quit(0 if passed else 1)


func _make_benchmark():
	var benchmark = BenchmarkScene.instantiate()
	benchmark.mode = "burst"
	benchmark.set_process(false)
	root.add_child(benchmark)
	return benchmark


func _check_contact_fixtures(benchmark) -> bool:
	for index in benchmark.PARTICLE_COUNT:
		benchmark.positions[index] = benchmark.spawn_point
		# One step adds 13 to vertical velocity, leaving these particles stationary.
		benchmark.velocities[index] = Vector2(0, -13)
	var starts := [Vector2(400, 606), Vector2(925, 100), Vector2(925, 605),
		Vector2(480, 190), Vector2(480, 100)]
	var velocities := [Vector2(100, 87), Vector2(100, -13), Vector2(100, 87),
		Vector2(100, -13), Vector2(0, 1000)]
	for index in starts.size():
		benchmark.positions[index] = starts[index]
		benchmark.velocities[index] = velocities[index]
	for index in benchmark.PARTICLE_COUNT:
		benchmark.particles[index].position = benchmark.positions[index]
	_step_benchmark(benchmark, 1)
	# Floor contact, wall contact, a blocked corner, free motion, and terminal fall.
	var expected_positions := [Vector2(402, 606), Vector2(925, 100), Vector2(925, 605),
		Vector2(482, 190), Vector2(480, 114)]
	var expected_velocities := [Vector2(85, 0), Vector2(-25, 0), Vector2(-21.25, 0),
		Vector2(100, 0), Vector2(0, 700)]
	for index in starts.size():
		if not benchmark.positions[index].is_equal_approx(expected_positions[index]) or not benchmark.velocities[index].is_equal_approx(expected_velocities[index]):
			push_error("Unexpected contact fixture response for particle %d." % index)
			return false
	if benchmark.current_queries != 806 or benchmark.current_hits != 7:
		push_error("Contact fixtures must perform 806 individual queries with seven hits.")
		return false
	return _check_room_state(benchmark)


func _check_settled(benchmark) -> bool:
	benchmark._settle_particles()
	benchmark.mode = "settled"
	benchmark._process(0.0)
	if benchmark.current_queries != 800 or benchmark.current_hits != 800:
		push_error("Every settled particle must make one individual query and hit the floor below it.")
		return false
	return _check_room_state(benchmark)


func _check_burst(benchmark) -> bool:
	var total_queries := 0
	var total_hits := 0
	# Includes contacts, settled intervals, and the second burst at step 180.
	for step in 240:
		_step_benchmark(benchmark, step)
		if not _check_room_state(benchmark):
			push_error("Invalid particle state at burst step %d." % step)
			return false
		if benchmark.current_queries < 800 or benchmark.current_queries > 2400 or benchmark.current_queries % 2 != 0:
			push_error("A burst step must query every particle and both axes of each contact.")
			return false
		total_queries += benchmark.current_queries
		total_hits += benchmark.current_hits
		if step == 180:
			for position in benchmark.positions:
				if position.distance_to(benchmark.spawn_point) > 16.0:
					push_error("The scheduled burst did not restart every particle at step 180.")
					return false
	if total_queries <= 240 * 800 or total_hits == 0:
		push_error("The burst workload did not exercise contact resolution.")
		return false
	return true


func _check_room_state(benchmark) -> bool:
	if benchmark.particles.size() != 800 or PixelCollision.get_collider_count() != 874:
		push_error("The synthetic room must contain 800 particles and 74 solid sprites.")
		return false
	for index in benchmark.PARTICLE_COUNT:
		var at: Vector2 = benchmark.positions[index]
		if not at.is_finite() or not benchmark.velocities[index].is_finite() or benchmark.particles[index].position != at:
			push_error("Particle %d has invalid or unsynchronized state." % index)
			return false
		# These three explicit occupancy shapes are filled rectangles. Check their
		# floor-quantized cells against terrain without calling the collision API.
		var occupied: Rect2i = EXPECTED_BOUNDS[index % 3]
		occupied.position += Vector2i(at.floor())
		for rectangle in benchmark.solid_rectangles:
			if occupied.intersects(rectangle):
				push_error("Particle %d overlaps solid terrain." % index)
				return false
	return true


func _step_benchmark(benchmark, step: int) -> void:
	benchmark.frame_index = step
	benchmark.current_queries = 0
	benchmark.current_hits = 0
	benchmark._step_burst()


func _check_atlas() -> bool:
	var shared_texture: Texture2D
	for frame in 3:
		var texture := Assets.BLOOD_FRAMES.get_frame_texture(&"default", frame) as AtlasTexture
		if texture == null or texture.get_size() != Vector2(4, 4):
			push_error("Blood frames must be 4-by-4 AtlasTexture regions.")
			return false
		if frame == 0:
			shared_texture = texture.atlas
		elif texture.atlas != shared_texture:
			push_error("Blood frames do not share their backing texture.")
			return false
		var source_image := texture.get_image()
		var mask_image := Assets.BLOOD_MASK.get_preview_image(Assets.BLOOD_FRAMES, &"default", frame)
		if source_image == null or mask_image == null:
			push_error("Atlas source or baked preview image is missing.")
			return false
		if source_image.get_size() != Vector2i(4, 4) or mask_image.get_size() != Vector2i(4, 4):
			push_error("Atlas source or baked preview dimensions changed.")
			return false
		for y in 4:
			for x in 4:
				var expected: int = EXPECTED_PIXELS[frame][y * 4 + x]
				var source_pixel := source_image.get_pixel(x, y)
				if int(source_pixel.a > 0.0) != expected or int(mask_image.get_pixel(x, y).a > 0.0) != expected:
					push_error("Atlas occupancy changed in frame %d at (%d, %d)." % [frame, x, y])
					return false
				if expected == 1 and not source_pixel.is_equal_approx(Color("ff7187")):
					push_error("Atlas particle color changed in frame %d." % frame)
					return false
	return true
