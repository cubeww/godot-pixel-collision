#pragma once

#include "pixel_collision_mask.hpp"

#include <godot_cpp/classes/sprite2d.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <cstdint>

namespace godot {

class PixelCollision;

// The native Sprite2D workflow with an explicitly baked collision mask.
class MaskedSprite2D : public Sprite2D {
    GDCLASS(MaskedSprite2D, Sprite2D)

    Ref<PixelCollisionMask> mask_;
    bool collision_enabled_ = true;

    void on_state_changed();
    void mark_collision_dirty();

protected:
    static void _bind_methods();
    void _notification(int what);

public:
    MaskedSprite2D();
    ~MaskedSprite2D() override;

    void set_mask(const Ref<PixelCollisionMask> &mask);
    Ref<PixelCollisionMask> get_mask() const;
    void set_collision_enabled(bool enabled);
    bool is_collision_enabled() const;

    bool place_meeting(const Vector2 &at, const StringName &group);
    Node2D *instance_place(const Vector2 &at, const StringName &group);
    void move_contact(double direction, double max_distance, const StringName &group);
    // Internal editor overlay data, sampled from the same view as queries.
    Dictionary _get_collision_preview(bool include_image = true);
    PackedStringArray _get_configuration_warnings() const override;
};

} // namespace godot
