#include "masked_animated_sprite_2d.hpp"
#include "masked_sprite_2d.hpp"
#include "pixel_collision_mask.hpp"
#include "pixel_collision.hpp"
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_pixel_collision(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
    ClassDB::register_class<PixelCollisionMask>();
    ClassDB::register_abstract_class<PixelCollision>();
    ClassDB::register_class<MaskedAnimatedSprite2D>();
    ClassDB::register_class<MaskedSprite2D>();
    Engine::get_singleton()->register_singleton("PixelCollision", memnew(PixelCollision));
}

static void uninitialize_pixel_collision(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
    Engine::get_singleton()->unregister_singleton("PixelCollision");
    memdelete(PixelCollision::get_singleton());
}

extern "C" GDExtensionBool GDE_EXPORT pixel_collision_library_init(
        GDExtensionInterfaceGetProcAddress get_proc_address,
        GDExtensionClassLibraryPtr library,
        GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_pixel_collision);
    init.register_terminator(uninitialize_pixel_collision);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
