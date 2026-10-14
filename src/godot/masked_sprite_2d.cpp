#include "masked_sprite_2d.hpp"
#include "pixel_collision.hpp"
#include "../core/bit_mask.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <cmath>
#include <stdexcept>
#include <vector>

namespace godot {

void MaskedSprite2D::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_mask", "mask"), &MaskedSprite2D::set_mask);
    ClassDB::bind_method(D_METHOD("get_mask"), &MaskedSprite2D::get_mask);
    ClassDB::bind_method(D_METHOD("set_collision_enabled", "enabled"), &MaskedSprite2D::set_collision_enabled);
    ClassDB::bind_method(D_METHOD("is_collision_enabled"), &MaskedSprite2D::is_collision_enabled);
    ClassDB::bind_method(D_METHOD("place_meeting", "at", "group"), &MaskedSprite2D::place_meeting, DEFVAL(StringName()));
    ClassDB::bind_method(D_METHOD("instance_place", "at", "group"), &MaskedSprite2D::instance_place, DEFVAL(StringName()));
    ClassDB::bind_method(D_METHOD("move_contact", "direction", "max_distance", "group"), &MaskedSprite2D::move_contact);
    ClassDB::bind_method(D_METHOD("_get_collision_preview", "include_image"), &MaskedSprite2D::_get_collision_preview, DEFVAL(true));
    ADD_GROUP("Pixel Collision", "");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "mask", PROPERTY_HINT_RESOURCE_TYPE, "PixelCollisionMask"), "set_mask", "get_mask");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "collision_enabled"), "set_collision_enabled", "is_collision_enabled");
}

MaskedSprite2D::MaskedSprite2D() {
    set_notify_local_transform(true);
    set_notify_transform(true);
    const Callable changed = callable_mp(this, &MaskedSprite2D::on_state_changed);
    connect("frame_changed", changed);
    connect("texture_changed", changed);
    connect("item_rect_changed", changed);
}

MaskedSprite2D::~MaskedSprite2D() {
    if (mask_.is_valid()) {
        const Callable changed = callable_mp(this, &MaskedSprite2D::on_state_changed);
        if (mask_->is_connected("changed", changed)) {
            mask_->disconnect("changed", changed);
        }
    }
}

void MaskedSprite2D::_notification(int what) {
    switch (what) {
        case NOTIFICATION_ENTER_TREE: {
            if (auto *collision = PixelCollision::get_singleton()) {
                collision->register_sprite(this);
            }
            break;
        }
        case NOTIFICATION_EXIT_TREE: {
            if (auto *collision = PixelCollision::get_singleton()) {
                collision->unregister_sprite(get_instance_id());
            }
            break;
        }
        case NOTIFICATION_LOCAL_TRANSFORM_CHANGED:
        case NOTIFICATION_TRANSFORM_CHANGED:
            mark_collision_dirty();
            break;
        default:
            break;
    }
}

void MaskedSprite2D::mark_collision_dirty() {
    // Detached scenes may be configured on a worker thread. Their state is
    // collected on ENTER_TREE; they must not access the shared scene index yet.
    if (!is_inside_tree()) {
        return;
    }
    if (auto *collision = PixelCollision::get_singleton()) {
        collision->mark_dirty(get_instance_id());
    }
}

void MaskedSprite2D::on_state_changed() {
    mark_collision_dirty();
    if (Engine::get_singleton()->is_editor_hint()) {
        update_configuration_warnings();
    }
}

void MaskedSprite2D::set_mask(const Ref<PixelCollisionMask> &mask) {
    if (mask_ == mask) {
        return;
    }
    const Callable changed = callable_mp(this, &MaskedSprite2D::on_state_changed);
    if (mask_.is_valid() && mask_->is_connected("changed", changed)) {
        mask_->disconnect("changed", changed);
    }
    mask_ = mask;
    if (mask_.is_valid()) {
        mask_->connect("changed", changed);
    }
    on_state_changed();
}

Ref<PixelCollisionMask> MaskedSprite2D::get_mask() const {
    return mask_;
}

void MaskedSprite2D::set_collision_enabled(bool enabled) {
    if (collision_enabled_ == enabled) {
        return;
    }
    collision_enabled_ = enabled;
    on_state_changed();
}

bool MaskedSprite2D::is_collision_enabled() const {
    return collision_enabled_;
}

bool MaskedSprite2D::place_meeting(const Vector2 &at, const StringName &group) {
    if (!PixelCollision::is_scene_thread()) {
        UtilityFunctions::push_error("Pixel collision queries must run on the main scene thread.");
        return false;
    }
    auto *collision = PixelCollision::get_singleton();
    return collision && collision->place_meeting_unchecked(this, at, group);
}

Node2D *MaskedSprite2D::instance_place(const Vector2 &at, const StringName &group) {
    if (!PixelCollision::is_scene_thread()) {
        UtilityFunctions::push_error("Pixel collision queries must run on the main scene thread.");
        return nullptr;
    }
    auto *collision = PixelCollision::get_singleton();
    return collision ? collision->instance_place_unchecked(this, at, group) : nullptr;
}

void MaskedSprite2D::move_contact(double direction, double max_distance, const StringName &group) {
    if (!PixelCollision::is_scene_thread()) {
        UtilityFunctions::push_error("Pixel collision movement must run on the main scene thread.");
        return;
    }
    if (!std::isfinite(direction) || !std::isfinite(max_distance) ||
            max_distance > double(INT32_MAX)) {
        UtilityFunctions::push_error("move_contact requires finite arguments and max_distance <= 2147483647.");
        return;
    }
    if (auto *collision = PixelCollision::get_singleton()) {
        collision->move_contact_unchecked(this, direction, max_distance, group);
    }
}

PackedStringArray MaskedSprite2D::_get_configuration_warnings() const {
    PackedStringArray warnings;
    if (!collision_enabled_) {
        return warnings;
    }
    const PixelCollisionMask::Frame *frame = nullptr;
    if (mask_.is_null()) {
        warnings.push_back("Assign and bake a PixelCollisionMask. Missing masks never fall back to rectangular collisions.");
    } else {
        frame = mask_->get_frame_for_sprite(this);
        if (!frame) {
            warnings.push_back("The collision mask has no valid baked data for the selected frame. Bake it in the Pixel Collision editor panel.");
        }
    }
    const Transform2D transform = is_inside_tree() ? get_global_transform() : get_transform();
    try {
        if (!transform.is_finite()) {
            throw std::invalid_argument("nonfinite transform");
        }
        // Configuration warnings are an explicit authoring check, never part of
        // a collision query. Validate the same geometry as the runtime view.
        const auto pixels = frame ? pixel_collision::BitMask::from_bytes(frame->width, frame->height,
                std::vector<uint8_t>(frame->occupancy.ptr(), frame->occupancy.ptr() + frame->occupancy.size()))
                : pixel_collision::BitMask::from_bytes(1, 1, {1});
        const Rect2i box = frame ? frame->collision_bounds : Rect2i(0, 0, 1, 1);
        const Vector2i mask_offset = mask_.is_valid() ? mask_->get_mask_offset() : Vector2i();
        const double left = double(get_offset().x) + mask_offset.x - (is_centered() ? pixels.width() * 0.5 : 0.0);
        const double top = double(get_offset().y) + mask_offset.y - (is_centered() ? pixels.height() * 0.5 : 0.0);
        const pixel_collision::Bounds logical_bounds{box.position.x, box.position.y,
                int64_t(box.position.x) + box.size.x - 1, int64_t(box.position.y) + box.size.y - 1};
        const pixel_collision::AffineMask view(pixels, PixelCollision::affine_basis(transform),
                transform.get_origin().x, transform.get_origin().y, left, top, logical_bounds);
    } catch (const std::exception &) {
        warnings.push_back("Pixel collision requires a finite, invertible transform and coordinates within the supported range. Zero scale and singular transforms are unsupported.");
    }
    return warnings;
}

Dictionary MaskedSprite2D::_get_collision_preview(bool include_image) {
    if (!PixelCollision::is_scene_thread()) {
        UtilityFunctions::push_error("Pixel collision previews must run on the main scene thread.");
        return Dictionary();
    }
    auto *collision = PixelCollision::get_singleton();
    return collision ? collision->collision_preview_unchecked(this, include_image) : Dictionary();
}

} // namespace godot
