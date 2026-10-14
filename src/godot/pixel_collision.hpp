#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/transform2d.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>
#include <memory>

namespace pixel_collision { struct AffineTransform; class AffineMask; }

namespace godot {

class MaskedAnimatedSprite2D;
class MaskedSprite2D;

// Extension-owned Engine singleton for all active pixel colliders.
class PixelCollision : public Object {
    GDCLASS(PixelCollision, Object)
    friend class MaskedAnimatedSprite2D;
    friend class MaskedSprite2D;

    static PixelCollision *singleton_;
    struct State;
    std::unique_ptr<State> state_;

    Node2D *find_meeting(Node2D *source,
            const Vector2 &at, const StringName &group, bool first_hit,
            const pixel_collision::AffineMask *prepared_query = nullptr);
    // Only called after a public singleton or sprite API verifies the scene thread.
    void sync_unchecked();
    bool place_meeting_unchecked(Node2D *source,
            const Vector2 &at, const StringName &group);
    Node2D *instance_place_unchecked(Node2D *source,
            const Vector2 &at, const StringName &group);
    void move_contact_unchecked(Node2D *source,
            double direction, double max_distance, const StringName &group);
    Dictionary collision_preview_unchecked(Node2D *source, bool include_image);

protected:
    static void _bind_methods();

public:
    PixelCollision();
    ~PixelCollision() override;

    static PixelCollision *get_singleton();
    static bool is_scene_thread();
    static pixel_collision::AffineTransform affine_basis(const Transform2D &transform);

    void register_sprite(Node2D *sprite);
    void unregister_sprite(uint64_t instance_id);
    void mark_dirty(uint64_t instance_id);

    void sync();
    int64_t get_collider_count() const;
    bool place_meeting(Node2D *source,
            const Vector2 &at, const StringName &group);
    Node2D *instance_place(Node2D *source,
            const Vector2 &at, const StringName &group);
};

} // namespace godot
