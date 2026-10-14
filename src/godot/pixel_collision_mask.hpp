#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/sprite2d.hpp>
#include <godot_cpp/classes/sprite_frames.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/templates/hash_map.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rect2i.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <cstdint>
#include <vector>

namespace godot {

// Configuration and baked data are shared. Queries never read texture images.
class PixelCollisionMask : public Resource {
    GDCLASS(PixelCollisionMask, Resource)

public:
    enum ShapeMode { PRECISE = 0, RECTANGLE = 1 };
    enum FrameMode { CURRENT_FRAME = 0, ANIMATION_UNION = 1, FIXED_FRAME = 2 };

    struct Frame {
        int32_t width = 0;
        int32_t height = 0;
        PackedByteArray occupancy; // One byte per pixel, including transparent margins.
        // Occupied bounds shared by all baked frames in the selected animation.
        // Bounds can extend beyond this frame's canvas when frame sizes differ.
        Rect2i collision_bounds;
    };

private:
    ShapeMode shape_mode_ = PRECISE;
    FrameMode frame_mode_ = CURRENT_FRAME;
    double alpha_threshold_ = 0.0;
    Rect2i manual_bounds_;
    StringName fixed_animation_ = StringName("default");
    int fixed_frame_ = 0;
    Ref<SpriteFrames> source_frames_;
    Vector2i mask_offset_;
    bool follow_sprite_flip_ = true;

    Dictionary baked_data_;
    Ref<SpriteFrames> baked_source_;
    Ref<Texture2D> baked_texture_;
    int baked_hframes_ = 1;
    int baked_vframes_ = 1;
    bool baked_region_enabled_ = false;
    Rect2 baked_region_;
    HashMap<StringName, std::vector<Frame>> frames_;
    std::vector<Ref<Resource>> watched_sources_;
    struct DependencyStamp {
        uint64_t modified = 0;
        String digest;
    };
    mutable HashMap<String, DependencyStamp> dependency_stamps_;
    uint64_t revision_ = 1;
    bool valid_ = false;
    bool source_dirty_ = false;
    String bake_error_ = "The mask has not been baked.";

    Dictionary settings() const;
    Array source_layout(const Ref<SpriteFrames> &source) const;
    Dictionary source_dependencies(const Ref<SpriteFrames> &source) const;
    bool sprite_source_matches(const Sprite2D *sprite) const;
    Error bake_source(const Ref<SpriteFrames> &source, const Sprite2D *sprite = nullptr);
    bool dependencies_match() const;
    void configuration_changed();
    void refresh_validity();
    void disconnect_sources();
    void watch_sources();
    void on_source_changed();
    Error fail_bake(const String &message, Error error);

protected:
    static void _bind_methods();

public:
    ~PixelCollisionMask() override;

    void set_shape_mode(ShapeMode value);
    ShapeMode get_shape_mode() const { return shape_mode_; }
    void set_frame_mode(FrameMode value);
    FrameMode get_frame_mode() const { return frame_mode_; }
    void set_alpha_threshold(double value);
    double get_alpha_threshold() const { return alpha_threshold_; }
    void set_manual_bounds(const Rect2i &value);
    Rect2i get_manual_bounds() const { return manual_bounds_; }
    void set_fixed_animation(const StringName &value);
    StringName get_fixed_animation() const { return fixed_animation_; }
    void set_fixed_frame(int value);
    int get_fixed_frame() const { return fixed_frame_; }
    void set_source_frames(const Ref<SpriteFrames> &value);
    Ref<SpriteFrames> get_source_frames() const { return source_frames_; }
    void set_mask_offset(const Vector2i &value);
    Vector2i get_mask_offset() const { return mask_offset_; }
    void set_follow_sprite_flip(bool value);
    bool get_follow_sprite_flip() const { return follow_sprite_flip_; }

    Error bake(const Ref<SpriteFrames> &sprite_frames);
    Error bake_sprite(Sprite2D *sprite);
    // Authoring validation: checks frame structure, without downloading image pixels.
    bool is_baked_for(const Ref<SpriteFrames> &sprite_frames) const;
    bool is_baked_for_sprite(Sprite2D *sprite) const;
    // Explicit tooling check. Original source files must be available; not needed in exports.
    bool validate_source_files() const;
    String get_bake_error() const { return bake_error_; }
    Ref<SpriteFrames> get_baked_source() const { return baked_source_; }
    Ref<Texture2D> get_baked_texture() const { return baked_texture_; }
    uint64_t get_revision() const { return revision_; }
    const Frame *get_frame(const Ref<SpriteFrames> &sprite_frames,
                          const StringName &animation, int frame) const;
    const Frame *get_frame_for_sprite(const Sprite2D *sprite) const;
    Ref<Image> get_preview_image(const Ref<SpriteFrames> &sprite_frames,
                                 const StringName &animation, int frame) const;
    Ref<Image> get_preview_image_for_sprite(Sprite2D *sprite) const;

    void set_baked_data(const Dictionary &value);
    Dictionary get_baked_data() const { return baked_data_; }
};

} // namespace godot

VARIANT_ENUM_CAST(godot::PixelCollisionMask::ShapeMode)
VARIANT_ENUM_CAST(godot::PixelCollisionMask::FrameMode)
