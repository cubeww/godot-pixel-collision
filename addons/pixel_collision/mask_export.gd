@tool
extends EditorExportPlugin

var controller: EditorPlugin


func _get_name() -> String:
	return "PixelCollisionMaskValidation"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	if is_instance_valid(controller):
		controller.call("validate_export_scene")
