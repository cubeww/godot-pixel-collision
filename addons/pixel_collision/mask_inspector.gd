@tool
extends EditorInspectorPlugin

const MaskTools = preload("res://addons/pixel_collision/mask_tools.gd")

var controller: EditorPlugin


func _can_handle(object: Object) -> bool:
	return object.is_class("MaskedAnimatedSprite2D") or object.is_class("MaskedSprite2D") or object.is_class("PixelCollisionMask")


func _parse_begin(object: Object) -> void:
	var panel := MaskTools.new()
	panel.controller = controller
	panel.target = object
	add_custom_control(panel)
