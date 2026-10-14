@tool
extends VBoxContainer

var controller: EditorPlugin
var target: Object
var status: Label
var create_button: Button
var bake_button: Button
var elapsed := 0.0


func _ready() -> void:
	var title := Label.new()
	title.text = "Pixel Collision Mask"
	add_child(title)
	var buttons := HBoxContainer.new()
	add_child(buttons)
	create_button = Button.new()
	create_button.text = "Create Mask"
	create_button.pressed.connect(_create_mask)
	buttons.add_child(create_button)
	bake_button = Button.new()
	bake_button.text = "Bake / Refresh"
	bake_button.tooltip_text = "Rebuild serialized pixels from the source textures."
	bake_button.pressed.connect(_bake_mask)
	buttons.add_child(bake_button)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.x = 160
	add_child(status)
	_refresh()


func _process(delta: float) -> void:
	elapsed += delta
	if elapsed >= 0.3:
		elapsed = 0.0
		_refresh()


func _refresh() -> void:
	if not is_instance_valid(controller) or not is_instance_valid(target):
		set_process(false)
		return
	var mask: Resource = controller.call("mask_for", target)
	create_button.visible = bool(controller.call("_handles", target)) and mask == null
	create_button.disabled = not ClassDB.can_instantiate("PixelCollisionMask")
	bake_button.disabled = mask == null
	status.text = controller.call("status_for", target)


func _create_mask() -> void:
	if is_instance_valid(controller) and is_instance_valid(target):
		controller.call("create_mask", target)
		_refresh()


func _bake_mask() -> void:
	if is_instance_valid(controller) and is_instance_valid(target):
		controller.call("bake_target", target)
		_refresh()
