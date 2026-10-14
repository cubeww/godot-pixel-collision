#include "pixel_collision.hpp"
#include "masked_animated_sprite_2d.hpp"
#include "masked_sprite_2d.hpp"
#include "pixel_collision_mask.hpp"
#include "../core/bit_mask.h"
#include "../core/spatial_hash.h"

#include <godot_cpp/classes/canvas_item.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <exception>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace godot {
namespace {

using pixel_collision::BitMask;
using pixel_collision::Bounds;
using pixel_collision::AffineMask;
using pixel_collision::AffineTransform;

Node2D *resolve_sprite(uint64_t id) {
    return Object::cast_to<Node2D>(ObjectDB::get_instance(id));
}

// Registration establishes the subtype once. Query candidates need no extra
// dynamic casts or GDScript calls to access either native sprite class.
struct ColliderAccess {
    Node2D *node;
    bool is_static;

    MaskedAnimatedSprite2D *animated() const { return static_cast<MaskedAnimatedSprite2D *>(node); }
    MaskedSprite2D *sprite() const { return static_cast<MaskedSprite2D *>(node); }
    Ref<PixelCollisionMask> mask() const { return is_static ? sprite()->get_mask() : animated()->get_mask(); }
    bool enabled() const { return is_static ? sprite()->is_collision_enabled() : animated()->is_collision_enabled(); }
    Vector2 offset() const { return is_static ? sprite()->get_offset() : animated()->get_offset(); }
    bool centered() const { return is_static ? sprite()->is_centered() : animated()->is_centered(); }
    bool flip_h() const { return is_static ? sprite()->is_flipped_h() : animated()->is_flipped_h(); }
    bool flip_v() const { return is_static ? sprite()->is_flipped_v() : animated()->is_flipped_v(); }
    const PixelCollisionMask::Frame *frame(const Ref<PixelCollisionMask> &resource) const {
        return is_static ? resource->get_frame_for_sprite(sprite()) :
                resource->get_frame(animated()->get_sprite_frames(), animated()->get_animation(), animated()->get_frame());
    }
};

bool quantize(double value, int64_t &result) {
    // Leave ample headroom for mask dimensions and broadphase cell arithmetic.
    constexpr double coordinate_limit = 1125899906842624.0;
    if (!std::isfinite(value) || std::abs(value) > coordinate_limit) {
        return false;
    }
    result = static_cast<int64_t>(value);
    return true;
}

size_t combine_hash(size_t seed, size_t value) {
    return seed ^ (value + size_t(0x9e3779b9) + (seed << 6) + (seed >> 2));
}

} // namespace

struct PixelCollision::State {
    struct ParentWatch {
        Transform2D transform;
        std::unordered_set<uint64_t> children;
    };

    struct MaskKey {
        uint64_t resource_id;
        uint64_t revision;
        const PixelCollisionMask::Frame *frame;

        bool operator==(const MaskKey &other) const {
            return resource_id == other.resource_id && revision == other.revision &&
                    frame == other.frame;
        }
    };

    struct MaskKeyHash {
        size_t operator()(const MaskKey &key) const {
            size_t hash = std::hash<uint64_t>()(key.resource_id);
            hash = combine_hash(hash, std::hash<uint64_t>()(key.revision));
            hash = combine_hash(hash, std::hash<const void *>()(key.frame));
            return hash;
        }
    };

    struct CachedMask {
        MaskKey key;
        std::shared_ptr<const BitMask> pixels;
    };

    struct Entry {
        uint64_t id = 0;
        uint64_t order = 0;
        uint64_t parent_id = 0;
        bool valid = false;
        bool is_static = false;
        bool region_enabled = false;
        bool follow_flip = false;
        bool flip_h = false;
        bool flip_v = false;
        std::shared_ptr<const CachedMask> mask;
        AffineMask view;
    };

    pixel_collision::SpatialHash grid;
    std::unordered_map<uint64_t, Entry> entries;
    std::unordered_map<uint64_t, ParentWatch> parents;
    std::unordered_set<uint64_t> dirty;
    std::unordered_set<uint64_t> region_rechecks;
    std::unordered_map<MaskKey, std::shared_ptr<const CachedMask>, MaskKeyHash> mask_cache;
    size_t mask_cache_bytes = 0;
    uint64_t next_order = 1;

    State() : grid(32) {}

    void unwatch_parent(Entry &entry) {
        if (!entry.parent_id) {
            return;
        }
        auto found = parents.find(entry.parent_id);
        if (found != parents.end()) {
            found->second.children.erase(entry.id);
            if (found->second.children.empty()) {
                parents.erase(found);
            }
        }
        entry.parent_id = 0;
    }

    void watch_parent(Entry &entry, Node2D *sprite) {
        CanvasItem *parent = sprite->is_set_as_top_level() ? nullptr : Object::cast_to<CanvasItem>(sprite->get_parent());
        const uint64_t id = parent ? parent->get_instance_id() : 0;
        if (entry.parent_id == id) {
            return;
        }
        unwatch_parent(entry);
        entry.parent_id = id;
        if (parent) {
            auto found = parents.find(id);
            if (found == parents.end()) {
                found = parents.emplace(id, ParentWatch{parent->get_global_transform(), {}}).first;
            }
            found->second.children.insert(entry.id);
        }
    }

    void poll_parent_transforms() {
        // Global transform notifications are deferred in Godot. Reading each
        // distinct parent makes a parent move visible to the very next query.
        for (auto &pair : parents) {
            auto *parent = Object::cast_to<CanvasItem>(ObjectDB::get_instance(pair.first));
            if (!parent || !parent->is_inside_tree()) {
                dirty.insert(pair.second.children.begin(), pair.second.children.end());
                continue;
            }
            const Transform2D transform = parent->get_global_transform();
            if (transform != pair.second.transform) {
                pair.second.transform = transform;
                dirty.insert(pair.second.children.begin(), pair.second.children.end());
            }
        }
    }

    void poll_invalid_regions() {
        // Sprite2D's region_enabled setter has no runtime geometry signal.
        // Valid entries check it when queried. Only invalid static layouts need
        // polling, so restoring a baked layout can make an unindexed node visible
        // without scanning every valid terrain sprite on every query.
        for (uint64_t id : region_rechecks) {
            auto found = entries.find(id);
            auto *node = resolve_sprite(id);
            if (found == entries.end() || !node || !node->is_inside_tree() ||
                    static_cast<MaskedSprite2D *>(node)->is_region_enabled() != found->second.region_enabled) {
                dirty.insert(id);
            }
        }
    }

    bool live(Node2D *sprite, bool is_static) const {
        return sprite && sprite->is_inside_tree() && !sprite->is_queued_for_deletion() &&
                ColliderAccess{sprite, is_static}.enabled();
    }

    std::shared_ptr<const CachedMask> original_mask(const MaskKey &key) {
        auto found = mask_cache.find(key);
        if (found != mask_cache.end()) {
            return found->second;
        }
        const auto &occupancy = key.frame->occupancy;
        std::vector<uint8_t> bytes(occupancy.ptr(), occupancy.ptr() + occupancy.size());
        auto result = std::make_shared<CachedMask>();
        result->key = key;
        result->pixels = std::make_shared<const BitMask>(BitMask::from_bytes(key.frame->width, key.frame->height, bytes));
        // Entries retain shared ownership, so bounded cache eviction is safe.
        constexpr size_t cache_byte_limit = 32 * 1024 * 1024;
        const size_t result_bytes = result->pixels->words().size() * sizeof(uint64_t);
        if (mask_cache.size() >= 1024 || mask_cache_bytes + result_bytes > cache_byte_limit) {
            mask_cache.clear();
            mask_cache_bytes = 0;
        }
        mask_cache.emplace(key, result);
        mask_cache_bytes += result_bytes;
        return result;
    }

    void refresh(Entry &entry, Node2D *sprite) {
        entry.valid = false;
        region_rechecks.erase(entry.id);
        if (!sprite || !sprite->is_inside_tree()) {
            grid.remove(entry.id);
            return;
        }
        watch_parent(entry, sprite);
        const ColliderAccess access{sprite, entry.is_static};
        entry.region_enabled = entry.is_static && access.sprite()->is_region_enabled();
        if (!live(sprite, entry.is_static)) {
            grid.remove(entry.id);
            return;
        }
        const Ref<PixelCollisionMask> resource = access.mask();
        if (resource.is_null()) {
            grid.remove(entry.id);
            return;
        }
        const auto *frame = access.frame(resource);
        const Transform2D transform = sprite->get_global_transform();
        if (!frame) {
            if (entry.is_static) {
                region_rechecks.insert(entry.id);
            }
            grid.remove(entry.id);
            return;
        }
        const Vector2 offset = access.offset();
        const Vector2i mask_offset = resource->get_mask_offset();
        const double left = double(offset.x) + mask_offset.x - (access.centered() ? frame->width * 0.5 : 0.0);
        const double top = double(offset.y) + mask_offset.y - (access.centered() ? frame->height * 0.5 : 0.0);
        entry.follow_flip = resource->get_follow_sprite_flip();
        entry.flip_h = entry.follow_flip && access.flip_h();
        entry.flip_v = entry.follow_flip && access.flip_v();
        try {
            const MaskKey key{resource->get_instance_id(), resource->get_revision(), frame};
            // Instances retain original pixels after shared-cache eviction.
            // Transform changes only prepare numeric bounds and an inverse.
            if (!entry.mask || !(entry.mask->key == key)) {
                entry.mask = original_mask(key);
            }
            const Rect2i box = frame->collision_bounds;
            const Bounds logical_bounds{box.position.x, box.position.y,
                    int64_t(box.position.x) + box.size.x - 1, int64_t(box.position.y) + box.size.y - 1};
            const AffineTransform basis = PixelCollision::affine_basis(transform);
            if (entry.view.matches(*entry.mask->pixels, basis, left, top, logical_bounds,
                    entry.flip_h, entry.flip_v)) {
                // Translation preserves the inverse and source-space geometry.
                entry.view.set_position(transform.get_origin().x, transform.get_origin().y);
            } else {
                entry.view = AffineMask(*entry.mask->pixels, basis,
                        transform.get_origin().x, transform.get_origin().y, left, top, logical_bounds,
                        entry.flip_h, entry.flip_v);
            }
            // Explicit flips have no dedicated native signal. The broad bounds
            // include every flip so a changed target remains discoverable.
            grid.update(entry.id, entry.view.broad_bounds());
            entry.valid = true;
        } catch (const std::exception &) {
            // Invalid geometry never falls back to a rectangle.
            grid.remove(entry.id);
            entry.view = AffineMask();
            entry.mask.reset();
        }
    }

    void refresh_live_state(Entry &entry, Node2D *sprite) {
        const ColliderAccess access{sprite, entry.is_static};
        if ((entry.is_static && entry.region_enabled != access.sprite()->is_region_enabled()) ||
                (entry.follow_flip && (entry.flip_h != access.flip_h() || entry.flip_v != access.flip_v()))) {
            refresh(entry, sprite);
        }
    }
};

void PixelCollision::_bind_methods() {
    ClassDB::bind_method(D_METHOD("sync"), &PixelCollision::sync);
    ClassDB::bind_method(D_METHOD("get_collider_count"), &PixelCollision::get_collider_count);
}

PixelCollision *PixelCollision::singleton_ = nullptr;

PixelCollision::PixelCollision() : state_(std::make_unique<State>()) {
    singleton_ = this;
}

PixelCollision::~PixelCollision() {
    singleton_ = nullptr;
}

PixelCollision *PixelCollision::get_singleton() {
    return singleton_;
}

bool PixelCollision::is_scene_thread() {
    OS *os = OS::get_singleton();
    return os && os->get_thread_caller_id() == os->get_main_thread_id();
}

AffineTransform PixelCollision::affine_basis(const Transform2D &transform) {
    // Preserve the supplied basis, including small trigonometric residues.
    return AffineTransform{double(transform[0].x), double(transform[0].y),
            double(transform[1].x), double(transform[1].y)};
}

void PixelCollision::register_sprite(Node2D *sprite) {
    if (!sprite || !is_scene_thread()) {
        return;
    }
    if (!sprite->is_inside_tree()) {
        return;
    }
    const bool is_static = Object::cast_to<MaskedSprite2D>(sprite) != nullptr;
    if (!is_static && !Object::cast_to<MaskedAnimatedSprite2D>(sprite)) {
        return;
    }
    const uint64_t id = sprite->get_instance_id();
    if (state_->entries.find(id) != state_->entries.end()) {
        return;
    }
    State::Entry entry;
    entry.id = id;
    entry.is_static = is_static;
    entry.order = state_->next_order++;
    state_->entries.emplace(id, std::move(entry));
    state_->dirty.insert(id);
}

void PixelCollision::unregister_sprite(uint64_t instance_id) {
    auto found = state_->entries.find(instance_id);
    if (found == state_->entries.end()) {
        return;
    }
    state_->unwatch_parent(found->second);
    state_->grid.remove(instance_id);
    state_->dirty.erase(instance_id);
    state_->region_rechecks.erase(instance_id);
    state_->entries.erase(found);
    if (state_->entries.empty()) {
        // The manager outlives scenes. Release old scene data when its last
        // collider exits, without requiring a user-visible reset operation.
        state_->grid.clear();
        state_->parents.clear();
        state_->dirty.clear();
        state_->region_rechecks.clear();
        state_->mask_cache.clear();
        state_->mask_cache_bytes = 0;
        state_->next_order = 1;
    }
}

void PixelCollision::mark_dirty(uint64_t instance_id) {
    if (state_->entries.find(instance_id) != state_->entries.end()) {
        state_->dirty.insert(instance_id);
    }
}

void PixelCollision::sync() {
    if (!is_scene_thread()) {
        UtilityFunctions::push_error("PixelCollision.sync must run on the main scene thread.");
        return;
    }
    sync_unchecked();
}

void PixelCollision::sync_unchecked() {
    state_->poll_parent_transforms();
    state_->poll_invalid_regions();
    std::unordered_set<uint64_t> pending;
    pending.swap(state_->dirty);
    for (uint64_t id : pending) {
        auto found = state_->entries.find(id);
        if (found == state_->entries.end()) {
            continue;
        }
        auto *sprite = resolve_sprite(id);
        if (!sprite || !sprite->is_inside_tree()) {
            unregister_sprite(id);
            continue;
        }
        state_->refresh(found->second, sprite);
    }
}

int64_t PixelCollision::get_collider_count() const {
    if (!is_scene_thread()) {
        UtilityFunctions::push_error("PixelCollision.get_collider_count must run on the main scene thread.");
        return 0;
    }
    return static_cast<int64_t>(state_->entries.size());
}

Node2D *PixelCollision::find_meeting(Node2D *source,
        const Vector2 &at, const StringName &group, bool first_hit, const AffineMask *prepared_query) {
    if (!source) {
        return nullptr;
    }
    const uint64_t source_id = source->get_instance_id();
    auto source_found = state_->entries.find(source_id);
    // Synchronous registration and the preceding sync establish tree membership
    // and enabled state. Queued deletion is checked separately.
    if (source_found == state_->entries.end() || !source_found->second.valid || source->is_queued_for_deletion()) {
        return nullptr;
    }
    State::Entry &source_entry = source_found->second;
    state_->refresh_live_state(source_entry, source);
    if (!source_entry.valid || source_entry.mask->pixels->empty()) {
        return nullptr;
    }
    AffineMask temporary_query;
    if (!prepared_query) {
        temporary_query = source_entry.view;
        try {
            temporary_query.set_position(at.x, at.y);
        } catch (const std::exception &) {
            return nullptr;
        }
        prepared_query = &temporary_query;
    }
    const AffineMask &query = *prepared_query;
    if (query.empty()) {
        return nullptr;
    }
    const std::vector<uint64_t> candidates = state_->grid.query(query.query_bounds());
    Node2D *hit = nullptr;
    uint64_t earliest = std::numeric_limits<uint64_t>::max();
    for (uint64_t id : candidates) {
        if (id == source_id) {
            continue;
        }
        auto found = state_->entries.find(id);
        if (found == state_->entries.end() || !found->second.valid || found->second.order >= earliest) {
            continue;
        }
        auto *candidate = resolve_sprite(id);
        if (!candidate || (group != StringName() && !candidate->is_in_group(group)) || candidate->is_queued_for_deletion()) {
            continue;
        }
        State::Entry &target = found->second;
        state_->refresh_live_state(target, candidate);
        if (target.valid && pixel_collision::overlaps(query, target.view)) {
            if (first_hit) {
                return candidate;
            }
            hit = candidate;
            earliest = target.order;
        }
    }
    return hit;
}

bool PixelCollision::place_meeting(Node2D *source,
        const Vector2 &at, const StringName &group) {
    if (!is_scene_thread()) {
        UtilityFunctions::push_error("Pixel collision queries must run on the main scene thread.");
        return false;
    }
    return place_meeting_unchecked(source, at, group);
}

bool PixelCollision::place_meeting_unchecked(Node2D *source,
        const Vector2 &at, const StringName &group) {
    sync_unchecked();
    return find_meeting(source, at, group, true) != nullptr;
}

Node2D *PixelCollision::instance_place(Node2D *source,
        const Vector2 &at, const StringName &group) {
    if (!is_scene_thread()) {
        UtilityFunctions::push_error("Pixel collision queries must run on the main scene thread.");
        return nullptr;
    }
    return instance_place_unchecked(source, at, group);
}

Node2D *PixelCollision::instance_place_unchecked(Node2D *source,
        const Vector2 &at, const StringName &group) {
    sync_unchecked();
    return find_meeting(source, at, group, false);
}

void PixelCollision::move_contact_unchecked(Node2D *source,
        double direction, double max_distance, const StringName &group) {
    // The sprite entry point already checked the scene thread and numeric range.
    const int64_t steps = max_distance > 0.0 ? static_cast<int64_t>(max_distance) : 1000;
    if (steps == 0) {
        return;
    }
    sync_unchecked();
    auto found = state_->entries.find(source->get_instance_id());
    if (found == state_->entries.end() || !found->second.valid || source->is_queued_for_deletion()) {
        return;
    }
    State::Entry &entry = found->second;
    state_->refresh_live_state(entry, source);
    if (!entry.valid || entry.mask->pixels->empty()) {
        return;
    }

    const Vector2 start = source->get_global_position();
    if (find_meeting(source, start, group, true)) {
        return;
    }
    // Mirror Node2D's parent lookup, including top-level nodes. Test positions
    // after the parent inverse/forward round trip, then commit that exact local
    // value: set_global_position could otherwise round a clear sample into a wall.
    CanvasItem *parent = source->is_set_as_top_level() ? nullptr : Object::cast_to<CanvasItem>(source->get_parent());
    const Transform2D parent_transform = parent ? parent->get_global_transform() : Transform2D();
    const real_t parent_determinant = parent_transform.determinant();
    if (!std::isfinite(parent_determinant) || parent_determinant == 0) {
        return; // Parent inversion must also be representable in Godot's real_t.
    }
    const Transform2D parent_inverse = parent_transform.affine_inverse();
    if (!parent_inverse.is_finite()) {
        return;
    }
    double degrees = std::fmod(direction, 360.0);
    if (degrees < 0.0) {
        degrees += 360.0;
    }
    Vector2 step;
    // Exact axes avoid trigonometric residue crossing an integer sample boundary.
    if (degrees == 0.0) {
        step = Vector2(1, 0);
    } else if (degrees == 90.0) {
        step = Vector2(0, -1);
    } else if (degrees == 180.0) {
        step = Vector2(-1, 0);
    } else if (degrees == 270.0) {
        step = Vector2(0, 1);
    } else {
        constexpr double degrees_to_radians = 0.017453292519943295769;
        const double radians = degrees * degrees_to_radians;
        step = Vector2(static_cast<real_t>(std::cos(radians)), static_cast<real_t>(-std::sin(radians)));
    }

    Vector2 position = start;
    Vector2 local_position = source->get_position();
    int64_t previous_x;
    int64_t previous_y;
    if (!quantize(start.x, previous_x) || !quantize(start.y, previous_y)) {
        return;
    }
    AffineMask next_view = entry.view;
    for (int64_t i = 0; i < steps; ++i) {
        const Vector2 next_local = parent_inverse.xform(position + step);
        const Vector2 next = parent_transform.xform(next_local);
        int64_t mask_x;
        int64_t mask_y;
        // Invalid query positions are misses in the boolean API; movement must
        // stop at the supported range rather than interpreting them as free space.
        if (next == position || !quantize(next.x, mask_x) || !quantize(next.y, mask_y) ||
                std::abs(mask_x - previous_x) > 1 || std::abs(mask_y - previous_y) > 1) {
            break;
        }
        try {
            next_view.set_position(next.x, next.y);
        } catch (const std::exception &) {
            break;
        }
        if (find_meeting(source, next, group, true, &next_view)) {
            break;
        }
        position = next;
        local_position = next_local;
        previous_x = mask_x;
        previous_y = mask_y;
    }
    if (position != start) {
        // Probe registered colliders without per-step scene mutations. One final
        // transform update marks the collider dirty for the next public query.
        source->set_position(local_position);
    }
}

Dictionary PixelCollision::collision_preview_unchecked(Node2D *source, bool include_image) {
    // Editor-only image generation is explicit and never runs during queries.
    sync_unchecked();
    Dictionary result;
    auto found = state_->entries.find(source->get_instance_id());
    if (found == state_->entries.end() || !found->second.valid || source->is_queued_for_deletion()) {
        return result;
    }
    State::Entry &entry = found->second;
    state_->refresh_live_state(entry, source);
    if (!entry.valid) {
        return result;
    }
    const Bounds bounds = entry.view.bounds();
    if (bounds.empty()) {
        return result;
    }
    const int64_t width = bounds.right - bounds.left + 1;
    const int64_t height = bounds.bottom - bounds.top + 1;
    result["rect"] = Rect2(Vector2(static_cast<real_t>(bounds.left), static_cast<real_t>(bounds.top)),
            Vector2(static_cast<real_t>(width), static_cast<real_t>(height)));
    // Preview storage is an editor concern, separate from runtime geometry.
    if (width > BitMask::max_dimension || height > BitMask::max_dimension ||
            uint64_t(width) * uint64_t(height) > BitMask::max_pixels) {
        result["preview_limited"] = true;
        return result;
    }
    if (include_image) {
        PackedByteArray bytes;
        bytes.resize(width * height * 4);
        uint8_t *output = bytes.ptrw();
        for (int32_t y = 0; y < height; ++y) {
            for (int32_t x = 0; x < width; ++x) {
                const size_t index = (size_t(y) * width + x) * 4;
                output[index] = 255;
                output[index + 1] = 255;
                output[index + 2] = 255;
                output[index + 3] = entry.view.sample(bounds.left + x, bounds.top + y) ? 255 : 0;
            }
        }
        result["image"] = Image::create_from_data(static_cast<int32_t>(width), static_cast<int32_t>(height), false,
                Image::FORMAT_RGBA8, bytes);
    }
    return result;
}

} // namespace godot
