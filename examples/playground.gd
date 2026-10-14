extends Node2D
## A small platformer showing ordinary Node Groups and shared baked masks.
## Its movement rules are illustrative, not a GameMaker compatibility layer.

const Assets = preload("res://examples/example_assets.gd")
const START := Vector2(92, 540)
const RUN_SPEED := 180.0
const JUMP_SPEED := 440.0
const GRAVITY := 1000.0

@onready var player: MaskedAnimatedSprite2D = $Player
var velocity := Vector2.ZERO
var jump_requested := false
var switch_block: MaskedAnimatedSprite2D
var status: Label
var message: Label
var status_time := 0.0
var rendered_frames := 0
var screenshot_path := ""


func _ready() -> void:
	if "--benchmark" in OS.get_cmdline_user_args():
		set_physics_process(false)
		set_process(false)
		call_deferred("_start_benchmark")
		return
	if not Assets.validate():
		get_tree().quit(1)
		return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--screenshot="):
			screenshot_path = argument.trim_prefix("--screenshot=")
	for x in range(0, 960, 32):
		_add_block(Vector2(x, 576))
	for x in [160, 192, 224]:
		_add_block(Vector2(x, 496))
	for x in [288, 320, 352]:
		_add_block(Vector2(x, 416))
	for x in [576, 608, 640, 672]:
		_add_block(Vector2(x, 352))
	for x in [768, 800, 832, 864]:
		_add_block(Vector2(x, 464))
	switch_block = _add_block(Vector2(416, 416))
	switch_block.name = "LiveGroupPlatform"
	switch_block.scale = Vector2(3, 1)
	switch_block.modulate = Color("c5a3ff")
	for x in [544, 576, 608, 640]:
		var spike := Assets.make_sprite(Assets.SPIKE_FRAMES, Assets.SPIKE_MASK,
			Vector2(x, 544), &"hazard")
		add_child(spike)
	player.play(&"idle")
	_build_ui()
	queue_redraw()


func _add_block(at: Vector2) -> MaskedAnimatedSprite2D:
	var block := Assets.make_sprite(Assets.BLOCK_FRAMES, Assets.BLOCK_MASK, at, &"solid")
	add_child(block)
	return block


func _build_ui() -> void:
	var overlay := CanvasLayer.new()
	add_child(overlay)
	var title := Label.new()
	title.position = Vector2(32, 22)
	title.text = "PIXEL COLLISION / PLAYGROUND"
	title.add_theme_font_size_override("font_size", 24)
	title.modulate = Color("8ff6dc")
	overlay.add_child(title)
	var description := Label.new()
	description.position = Vector2(32, 60)
	description.text = "AnimatedSprite2D + shared masks + ordinary Node Groups"
	description.modulate = Color("96adc3")
	overlay.add_child(description)
	var controls := Label.new()
	controls.position = Vector2(32, 94)
	controls.text = "A / D or arrows: move     Space: jump     R: reset\nF: toggle purple platform's solid group     B: 800-sprite benchmark"
	controls.add_theme_font_size_override("font_size", 15)
	overlay.add_child(controls)
	message = Label.new()
	message.position = Vector2(32, 150)
	message.modulate = Color("c5a3ff")
	message.text = "Purple platform belongs to solid. Group changes apply to the next query."
	message.add_theme_font_size_override("font_size", 15)
	overlay.add_child(message)
	status = Label.new()
	status.position = Vector2(32, 610)
	status.add_theme_font_size_override("font_size", 14)
	status.modulate = Color("96adc3")
	overlay.add_child(status)


func _draw() -> void:
	for x in range(0, 961, 32):
		draw_line(Vector2(x, 208), Vector2(x, 608), Color(0.13, 0.19, 0.25, 0.35))
	for y in range(224, 609, 32):
		draw_line(Vector2(0, y), Vector2(960, y), Color(0.13, 0.19, 0.25, 0.35))


func _physics_process(delta: float) -> void:
	if not is_instance_valid(switch_block):
		return
	var direction := int(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
	direction -= int(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT))
	velocity.x = direction * RUN_SPEED
	var grounded := player.place_meeting(player.global_position + Vector2.DOWN, &"solid")
	if grounded and jump_requested:
		velocity.y = -JUMP_SPEED
	jump_requested = false
	velocity.y = minf(velocity.y + GRAVITY * delta, 600.0)
	_move_axis(Vector2.RIGHT, velocity.x * delta)
	_move_axis(Vector2.DOWN, velocity.y * delta)
	if direction != 0:
		player.flip_h = direction < 0
		player.play(&"run")
	else:
		player.play(&"idle")
	if player.place_meeting(player.global_position, &"hazard") or player.global_position.y > 650:
		_reset_player()
	player.position.x = clampf(player.position.x, 8.0, 952.0)


func _move_axis(axis: Vector2, distance: float) -> void:
	var remaining := absf(distance)
	var direction := signf(distance)
	while remaining > 0.00001:
		var step := minf(remaining, 1.0)
		var next_position := player.global_position + axis * step * direction
		if player.place_meeting(next_position, &"solid"):
			if axis == Vector2.DOWN:
				velocity.y = 0.0
			return
		player.global_position = next_position
		remaining -= step


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_SPACE:
			jump_requested = true
		KEY_R:
			_reset_player()
		KEY_F:
			if switch_block.is_in_group(&"solid"):
				switch_block.remove_from_group(&"solid")
				switch_block.modulate.a = 0.25
				message.text = "Removed solid with remove_from_group(). The purple platform is passable."
			else:
				switch_block.add_to_group(&"solid")
				switch_block.modulate.a = 1.0
				message.text = "Added solid with add_to_group(). The purple platform is solid again."
		KEY_B:
			_start_benchmark()


func _reset_player() -> void:
	player.global_position = START
	velocity = Vector2.ZERO


func _process(delta: float) -> void:
	status_time += delta
	if status_time >= 0.25 and is_instance_valid(status):
		status_time = 0.0
		var ground := player.instance_place(player.global_position + Vector2.DOWN, &"solid")
		var ground_name := "none" if ground == null else str(ground.name)
		status.text = "%d registered sprites    Ground: %s    Fixed player mask / precise spike mask" % [PixelCollision.get_collider_count(), ground_name]
	rendered_frames += 1
	if rendered_frames == 30 and not screenshot_path.is_empty():
		_capture_screenshot()


func _capture_screenshot() -> void:
	await RenderingServer.frame_post_draw
	var error := get_viewport().get_texture().get_image().save_png(screenshot_path)
	if error != OK:
		push_error("Screenshot save failed: %s" % error_string(error))


func _start_benchmark() -> void:
	get_tree().change_scene_to_file("res://examples/blood_benchmark.tscn")
