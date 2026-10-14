extends Node2D
## 800 real MaskedAnimatedSprite2D nodes, drawn by Godot's normal CanvasItem path.
## All particles share one SpriteFrames resource and one three-frame baked mask.
## All three AtlasTexture frames reference one backing texture for draw batching.
## Settled mode keeps querying every particle. Burst uses centralized GDScript
## integration and individual place_meeting calls for collision decisions.

const Assets = preload("res://examples/example_assets.gd")
const PARTICLE_COUNT := 800
const SIMULATION_STEP := 1.0 / 50.0

var particles: Array[MaskedAnimatedSprite2D] = []
var positions := PackedVector2Array()
var velocities := PackedVector2Array()
var targets := PackedVector2Array()
var solid_rectangles: Array[Rect2i] = []
var rng := RandomNumberGenerator.new()
var frame_times := PackedFloat64Array()
var work_times := PackedFloat64Array()
var mode := "settled"
var requested_frames := 3000
var warmup_frames := 300
var output_path := ""
var screenshot_path := ""
var fixture_path := ""
var fixture_label := "74 synthetic solid blocks / synthetic blood masks"
var world_size := Vector2(960, 640)
var spawn_point := Vector2(480, 190)
var frame_index := 0
var previous_start_us := 0
var measured_queries := 0
var measured_hits := 0
var current_queries := 0
var current_hits := 0
var creation_time_ms := 0.0
var finished := false
var display_status: Label


func _ready() -> void:
	if not _parse_arguments() or not Assets.validate():
		set_process(false)
		get_tree().quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	rng.seed = 7654321
	if fixture_path.is_empty():
		_make_synthetic_room()
	elif not _load_fixture():
		set_process(false)
		get_tree().quit(1)
		return
	var creation_start := Time.get_ticks_usec()
	positions.resize(PARTICLE_COUNT)
	velocities.resize(PARTICLE_COUNT)
	targets.resize(PARTICLE_COUNT)
	for index in PARTICLE_COUNT:
		var particle := Assets.make_sprite(Assets.BLOOD_FRAMES, Assets.BLOOD_MASK, spawn_point)
		particle.name = "Blood%03d" % index
		particle.frame = index % 3
		particle.pause()
		add_child(particle)
		particles.append(particle)
	creation_time_ms = (Time.get_ticks_usec() - creation_start) / 1000.0
	if mode == "settled":
		_settle_particles()
	else:
		_restart_burst()
	PixelCollision.sync()
	_build_ui()
	print("BENCHMARK_START ", JSON.stringify({"mode": mode, "query_mode": "scalar",
		"particles": PARTICLE_COUNT, "frames": requested_frames, "warmup": warmup_frames,
		"fixture": fixture_label, "solid_count": solid_rectangles.size()}))


func _parse_arguments() -> bool:
	for argument in OS.get_cmdline_user_args():
		if argument == "--burst":
			mode = "burst"
		elif argument == "--settled":
			mode = "settled"
		elif argument.begins_with("--frames="):
			requested_frames = argument.trim_prefix("--frames=").to_int()
		elif argument.begins_with("--warmup="):
			warmup_frames = argument.trim_prefix("--warmup=").to_int()
		elif argument.begins_with("--output="):
			output_path = argument.trim_prefix("--output=")
		elif argument.begins_with("--screenshot="):
			screenshot_path = argument.trim_prefix("--screenshot=")
		elif argument.begins_with("--fixture="):
			fixture_path = argument.trim_prefix("--fixture=")
	if requested_frames < 1 or warmup_frames < 0:
		push_error("Use --frames=N (N > 0), --warmup=N (N >= 0).")
		return false
	return true


func _make_synthetic_room() -> void:
	for x in range(0, 960, 32):
		_add_rectangle(Rect2i(x, 608, 32, 32))
	_add_rectangle(Rect2i(0, 32, 32, 576))
	_add_rectangle(Rect2i(928, 32, 32, 576))
	for origin in [Vector2i(96, 288), Vector2i(384, 288), Vector2i(672, 288),
			Vector2i(64, 448), Vector2i(352, 448), Vector2i(640, 448)]:
		for column in 7:
			_add_rectangle(Rect2i(origin.x + column * 32, origin.y, 32, 32))


func _add_rectangle(rect: Rect2i) -> void:
	var block := Assets.make_sprite(Assets.BLOCK_FRAMES, Assets.BLOCK_MASK,
		Vector2(rect.position), &"solid")
	block.scale = Vector2(rect.size) / 32.0
	add_child(block)
	solid_rectangles.append(rect)


func _load_fixture() -> bool:
	var file := FileAccess.open(fixture_path, FileAccess.READ)
	if file == null:
		push_error("Cannot open external fixture: %s" % fixture_path)
		return false
	var data = JSON.parse_string(file.get_as_text())
	if not data is Dictionary or not data.has("rects"):
		push_error("Fixture must contain a rects array with inclusive left/top/right/bottom coordinates.")
		return false
	for entry in data["rects"]:
		var width := int(entry["right"]) - int(entry["left"]) + 1
		var height := int(entry["bottom"]) - int(entry["top"]) + 1
		if width <= 0 or height <= 0 or width % 32 != 0 or height % 32 != 0:
			push_error("The optional fixture adapter requires positive 32-pixel multiples.")
			return false
		_add_rectangle(Rect2i(int(entry["left"]), int(entry["top"]), width, height))
	if solid_rectangles.is_empty():
		push_error("Fixture has no solid rectangles.")
		return false
	world_size = Vector2(float(data.get("width", 960)), float(data.get("height", 640)))
	if data.has("spawn"):
		spawn_point = Vector2(float(data["spawn"][0]), float(data["spawn"][1]))
	var camera := Camera2D.new()
	camera.position = world_size * 0.5
	var zoom_factor := minf(960.0 / world_size.x, 640.0 / world_size.y)
	camera.zoom = Vector2(zoom_factor, zoom_factor)
	add_child(camera)
	fixture_label = "External rectangle geometry / synthetic blood masks"
	return true


func _settle_particles() -> void:
	var surfaces: Array[Rect2i] = []
	for rect in solid_rectangles:
		if rect.size.y <= 96 and rect.position.y >= 32:
			surfaces.append(rect)
	if surfaces.is_empty():
		surfaces = solid_rectangles.duplicate()
	for index in PARTICLE_COUNT:
		var rect := surfaces[rng.randi_range(0, surfaces.size() - 1)]
		var bottom_pixel := 2 if index % 3 == 2 else 1
		var at := Vector2(rng.randi_range(rect.position.x + 1,
			rect.end.x - 4), rect.position.y - bottom_pixel - 1)
		var particle: MaskedAnimatedSprite2D = particles[index]
		# Initial placement is outside measurement and resolves overlapping fixture solids.
		while particle.place_meeting(at, &"solid") and at.y > -8:
			at.y -= 1
		particle.position = at
		positions[index] = at
		targets[index] = at + Vector2.DOWN


func _restart_burst() -> void:
	for index in PARTICLE_COUNT:
		positions[index] = spawn_point
		velocities[index] = Vector2(rng.randf_range(-350, 350), rng.randf_range(-500, -80))
		particles[index].position = spawn_point


func _build_ui() -> void:
	var overlay := CanvasLayer.new()
	add_child(overlay)
	var heading := Label.new()
	heading.position = Vector2(24, 18)
	heading.text = "800 REAL ANIMATED SPRITES"
	heading.modulate = Color("8ff6dc")
	heading.add_theme_font_size_override("font_size", 24)
	overlay.add_child(heading)
	var detail := Label.new()
	detail.position = Vector2(24, 54)
	detail.text = "%s | individual queries | %s\nShared frames and baked masks. Normal CanvasItem drawing. VSync disabled." % [mode, fixture_label]
	detail.add_theme_font_size_override("font_size", 14)
	detail.modulate = Color("96adc3")
	overlay.add_child(detail)
	display_status = Label.new()
	display_status.position = Vector2(24, 104)
	display_status.add_theme_font_size_override("font_size", 14)
	overlay.add_child(display_status)


func _process(_delta: float) -> void:
	if finished:
		return
	var start_us := Time.get_ticks_usec()
	# Each interval covers the entire preceding rendered frame, including query,
	# scene processing, draw submission and any driver or presentation wait.
	if frame_index > warmup_frames:
		frame_times.append((start_us - previous_start_us) / 1000.0)
	if frame_index >= warmup_frames + requested_frames:
		_finish()
		return
	previous_start_us = start_us
	current_queries = 0
	current_hits = 0
	var work_start := Time.get_ticks_usec()
	if mode == "settled":
		for index in PARTICLE_COUNT:
			_meeting(index, targets[index])
	else:
		_step_burst()
	var work_ms := (Time.get_ticks_usec() - work_start) / 1000.0
	if frame_index >= warmup_frames:
		work_times.append(work_ms)
		measured_queries += current_queries
		measured_hits += current_hits
	frame_index += 1
	if frame_index % 120 == 0:
		display_status.text = "Frame %d / %d  |  %d registered nodes  |  last workload %.3f ms" % [frame_index, warmup_frames + requested_frames, PixelCollision.get_collider_count(), work_ms]
	if frame_index == 30 and not screenshot_path.is_empty():
		_capture_screenshot()


func _meeting(index: int, at: Vector2) -> bool:
	current_queries += 1
	var hit := particles[index].place_meeting(at, &"solid")
	current_hits += int(hit)
	return hit


func _step_burst() -> void:
	# Repeated bursts retain movement pressure instead of becoming a settled test.
	# The fixed step runs once per rendered frame, matching an uncapped room-style
	# workload. This benchmark does not claim wall-clock-independent game motion.
	if frame_index % 180 == 0:
		_restart_burst()
	for index in PARTICLE_COUNT:
		velocities[index].y = minf(velocities[index].y + 650.0 * SIMULATION_STEP, 700.0)
		targets[index] = positions[index] + velocities[index] * SIMULATION_STEP
	var hits := PackedByteArray()
	hits.resize(PARTICLE_COUNT)
	for index in PARTICLE_COUNT:
		hits[index] = int(_meeting(index, targets[index]))
	for index in PARTICLE_COUNT:
		if hits[index] == 0:
			positions[index] = targets[index]
		else:
			var horizontal := Vector2(targets[index].x, positions[index].y)
			if not _meeting(index, horizontal):
				positions[index].x = horizontal.x
			else:
				velocities[index].x *= -0.25
			var vertical := Vector2(positions[index].x, targets[index].y)
			if not _meeting(index, vertical):
				positions[index].y = vertical.y
			else:
				velocities[index].y = 0.0
				velocities[index].x *= 0.85
	for index in PARTICLE_COUNT:
		if positions[index].y > world_size.y + 16 or positions[index].x < -16 or positions[index].x > world_size.x + 16:
			positions[index] = spawn_point
			velocities[index] = Vector2(rng.randf_range(-350, 350), rng.randf_range(-500, -80))
		if particles[index].position != positions[index]:
			particles[index].position = positions[index]


func _finish() -> void:
	finished = true
	var frame_summary := _statistics(frame_times)
	var work_summary := _statistics(work_times)
	var result := {
		"mode": mode,
		"query_mode": "scalar",
		"particles": PARTICLE_COUNT,
		"solid_count": solid_rectangles.size(),
		"registered_sprites": PixelCollision.get_collider_count(),
		"fixture": fixture_label,
		"fixture_path": fixture_path,
		"screenshot_path": screenshot_path,
		"shared_sprite_frames": true,
		"shared_atlas_texture": true,
		"shared_baked_mask": true,
		"render_path": "800 MaskedAnimatedSprite2D CanvasItems; no MultiMesh",
		"headless": DisplayServer.get_name() == "headless",
		"godot_version": Engine.get_version_info()["string"],
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"vsync": DisplayServer.window_get_vsync_mode(),
		"viewport_size": [get_viewport_rect().size.x, get_viewport_rect().size.y],
		"warmup_frames": warmup_frames,
		"measured_frames": frame_times.size(),
		"query_count": measured_queries,
		"hit_count": measured_hits,
		"mean_fps": 1000.0 / frame_summary["mean_ms"],
		"frame": frame_summary,
		"collision_and_update_work": work_summary,
		"creation_ms": creation_time_ms,
		"simulation_seconds_per_rendered_frame": SIMULATION_STEP if mode == "burst" else 0.0,
		"notes": "Synthetic masks; no claim of GameMaker event/trajectory parity. Headless runs measure no actual display performance. Work time includes GDScript motion and node synchronization in burst mode. Creation is measured separately from warmed steady-state timing."
	}
	var json := JSON.stringify(result, "\t")
	if not output_path.is_empty():
		var directory := output_path.get_base_dir()
		if not directory.is_empty():
			DirAccess.make_dir_recursive_absolute(directory)
		var output := FileAccess.open(output_path, FileAccess.WRITE)
		if output == null:
			push_error("Cannot write benchmark output: %s" % output_path)
			get_tree().quit(1)
			return
		output.store_string(json + "\n")
		output.close()
	print("BENCHMARK_RESULT ", JSON.stringify(result))
	get_tree().quit(0)


func _statistics(values: PackedFloat64Array) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += value
	return {"mean_ms": total / sorted.size(),
		"median_ms": sorted[sorted.size() / 2],
		"p95_ms": sorted[mini(ceili(sorted.size() * 0.95) - 1, sorted.size() - 1)],
		"min_ms": sorted[0], "max_ms": sorted[-1]}


func _capture_screenshot() -> void:
	await RenderingServer.frame_post_draw
	var result := get_viewport().get_texture().get_image().save_png(screenshot_path)
	if result != OK:
		push_error("Screenshot save failed: %s" % error_string(result))
