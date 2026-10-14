#include "pixel_collision_mask.hpp"

#include <godot_cpp/classes/atlas_texture.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

namespace godot {
namespace {
constexpr int MAX_DIMENSION = 32768;
constexpr int64_t MAX_PIXELS = 64LL * 1024 * 1024;
constexpr int64_t MAX_BAKE_PIXELS = 256LL * 1024 * 1024;
constexpr int DATA_VERSION = 1;

bool valid_size(int width, int height) {
    return width > 0 && height > 0 && width <= MAX_DIMENSION && height <= MAX_DIMENSION &&
           int64_t(width) * height <= MAX_PIXELS;
}

bool integral_rect(const Rect2 &rect) {
    return rect.position == rect.position.floor() && rect.size == rect.size.floor();
}

Dictionary texture_layout(const Ref<Texture2D> &texture, int depth = 0) {
    Dictionary descriptor;
    if (texture.is_null()) return descriptor;
    descriptor["class"] = texture->get_class();
    descriptor["size"] = Vector2i(texture->get_width(), texture->get_height());
    if (depth > 16) {
        descriptor["invalid_nested_atlas"] = true;
        return descriptor;
    }
    const Ref<AtlasTexture> atlas = texture;
    if (atlas.is_valid()) {
        descriptor["region"] = atlas->get_region();
        descriptor["margin"] = atlas->get_margin();
        descriptor["atlas"] = texture_layout(atlas->get_atlas(), depth + 1);
    } else {
        const String path = texture->get_path();
        // A ResourceSaver round trip may create separate copies of inline texture
        // resources and assign them new subresource paths. Persist structural
        // metadata rather than object identity or those unstable inline paths.
        if (!path.is_empty() && !path.contains("::")) descriptor["path"] = path;
    }
    return descriptor;
}

void record_file_dependency(Dictionary &dependencies, const String &path) {
    if (!dependencies.has(path) && FileAccess::file_exists(path)) {
        dependencies[path] = FileAccess::get_sha256(path);
    }
}

void record_texture_dependencies(Dictionary &dependencies, Ref<Texture2D> texture) {
    for (int depth = 0; depth < 17 && texture.is_valid(); ++depth) {
        const String path = texture->get_path();
        // Embedded resources are fingerprinted by layout and Resource.changed.
        // Hashing their containing scene would also hash the baked result.
        if (!path.is_empty() && !path.contains("::")) {
            record_file_dependency(dependencies, path);
            record_file_dependency(dependencies, path + String(".import"));
        }
        Ref<AtlasTexture> atlas = texture;
        if (atlas.is_null()) break;
        texture = atlas->get_atlas();
    }
}

// AtlasTexture.get_image() omits the logical margin. Reconstruct the canvas so
// mask pixels use the same local coordinate system as AnimatedSprite2D.
Ref<Image> logical_image(const Ref<Texture2D> &texture, String &error, int depth = 0) {
    if (texture.is_null() || depth > 16) {
        error = "Missing texture or excessive nested AtlasTexture depth.";
        return {};
    }
    const int width = texture->get_width();
    const int height = texture->get_height();
    if (!valid_size(width, height)) {
        error = "Texture dimensions exceed the mask size limit or are empty.";
        return {};
    }
    Ref<AtlasTexture> atlas = texture;
    if (atlas.is_valid()) {
        Rect2 region = atlas->get_region();
        const Rect2 margin = atlas->get_margin();
        if (!integral_rect(region) || !integral_rect(margin)) {
            error = "Atlas regions and margins must use whole pixel coordinates.";
            return {};
        }
        Ref<Image> source = logical_image(atlas->get_atlas(), error, depth + 1);
        if (source.is_null()) {
            return {};
        }
        if (region.size.x == 0) {
            region.size.x = source->get_width();
        }
        if (region.size.y == 0) {
            region.size.y = source->get_height();
        }
        Ref<Image> image = Image::create_empty(width, height, false, Image::FORMAT_RGBA8);
        image->fill(Color(0, 0, 0, 0));
        // blit_rect clips source and destination, including out-of-atlas margins.
        image->blit_rect(source, Rect2i(region), Vector2i(margin.position));
        return image;
    }
    Ref<Image> image = texture->get_image();
    if (image.is_null() || image->is_empty()) {
        error = "Texture has no readable image. Bake from an imported CPU-readable texture.";
        return {};
    }
    // Never modify the source texture's image while preparing a mask.
    image = image->duplicate();
    if (image->is_compressed() && image->decompress() != OK) {
        error = "The imported texture format cannot be decompressed for mask baking.";
        return {};
    }
    if (image->get_width() != width || image->get_height() != height) {
        error = "Texture image dimensions differ from its logical dimensions.";
        return {};
    }
    image->convert(Image::FORMAT_RGBA8);
    return image;
}

PixelCollisionMask::Frame extract_frame(const Ref<Image> &image, double threshold,
                                        const Rect2i &manual, PixelCollisionMask::ShapeMode shape) {
    PixelCollisionMask::Frame frame;
    frame.width = image->get_width();
    frame.height = image->get_height();
    frame.occupancy.resize(int64_t(frame.width) * frame.height);
    frame.occupancy.fill(0);
    const PackedByteArray rgba = image->get_data();
    const uint8_t *rgba_ptr = rgba.ptr();
    uint8_t *pixels = frame.occupancy.ptrw();
    int left = frame.width, top = frame.height, right = -1, bottom = -1;
    for (int y = 0; y < frame.height; ++y) {
        for (int x = 0; x < frame.width; ++x) {
            const int64_t index = int64_t(y) * frame.width + x;
            if (double(rgba_ptr[index * 4 + 3]) / 255.0 > threshold) {
                pixels[index] = 1;
                left = std::min(left, x);
                top = std::min(top, y);
                right = std::max(right, x);
                bottom = std::max(bottom, y);
            }
        }
    }
    if (manual.size.x > 0 && manual.size.y > 0) {
        left = int(std::clamp<int64_t>(manual.position.x, 0, frame.width));
        top = int(std::clamp<int64_t>(manual.position.y, 0, frame.height));
        right = int(std::clamp<int64_t>(int64_t(manual.position.x) + manual.size.x, 0, frame.width)) - 1;
        bottom = int(std::clamp<int64_t>(int64_t(manual.position.y) + manual.size.y, 0, frame.height)) - 1;
    }
    for (int y = 0; y < frame.height; ++y) {
        for (int x = 0; x < frame.width; ++x) {
            const int64_t index = int64_t(y) * frame.width + x;
            const bool inside = x >= left && x <= right && y >= top && y <= bottom;
            pixels[index] = inside && (shape == PixelCollisionMask::RECTANGLE || pixels[index]) ? 1 : 0;
        }
    }
    return frame;
}

Dictionary frame_to_dictionary(const PixelCollisionMask::Frame &frame) {
    Dictionary data;
    data["width"] = frame.width;
    data["height"] = frame.height;
    data["pixels"] = frame.occupancy;
    return data;
}

Ref<Image> frame_preview(const PixelCollisionMask::Frame *frame) {
    if (!frame) return {};
    PackedByteArray bytes;
    bytes.resize(int64_t(frame->width) * frame->height * 4);
    uint8_t *out = bytes.ptrw();
    const uint8_t *pixels = frame->occupancy.ptr();
    for (int64_t i = 0; i < frame->occupancy.size(); ++i) {
        out[i * 4] = out[i * 4 + 1] = out[i * 4 + 2] = 255;
        out[i * 4 + 3] = pixels[i] ? 255 : 0;
    }
    return Image::create_from_data(frame->width, frame->height, false, Image::FORMAT_RGBA8, bytes);
}
} // namespace

void PixelCollisionMask::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_shape_mode", "value"), &PixelCollisionMask::set_shape_mode);
    ClassDB::bind_method(D_METHOD("get_shape_mode"), &PixelCollisionMask::get_shape_mode);
    ClassDB::bind_method(D_METHOD("set_frame_mode", "value"), &PixelCollisionMask::set_frame_mode);
    ClassDB::bind_method(D_METHOD("get_frame_mode"), &PixelCollisionMask::get_frame_mode);
    ClassDB::bind_method(D_METHOD("set_alpha_threshold", "value"), &PixelCollisionMask::set_alpha_threshold);
    ClassDB::bind_method(D_METHOD("get_alpha_threshold"), &PixelCollisionMask::get_alpha_threshold);
    ClassDB::bind_method(D_METHOD("set_manual_bounds", "value"), &PixelCollisionMask::set_manual_bounds);
    ClassDB::bind_method(D_METHOD("get_manual_bounds"), &PixelCollisionMask::get_manual_bounds);
    ClassDB::bind_method(D_METHOD("set_fixed_animation", "value"), &PixelCollisionMask::set_fixed_animation);
    ClassDB::bind_method(D_METHOD("get_fixed_animation"), &PixelCollisionMask::get_fixed_animation);
    ClassDB::bind_method(D_METHOD("set_fixed_frame", "value"), &PixelCollisionMask::set_fixed_frame);
    ClassDB::bind_method(D_METHOD("get_fixed_frame"), &PixelCollisionMask::get_fixed_frame);
    ClassDB::bind_method(D_METHOD("set_source_frames", "value"), &PixelCollisionMask::set_source_frames);
    ClassDB::bind_method(D_METHOD("get_source_frames"), &PixelCollisionMask::get_source_frames);
    ClassDB::bind_method(D_METHOD("set_mask_offset", "value"), &PixelCollisionMask::set_mask_offset);
    ClassDB::bind_method(D_METHOD("get_mask_offset"), &PixelCollisionMask::get_mask_offset);
    ClassDB::bind_method(D_METHOD("set_follow_sprite_flip", "value"), &PixelCollisionMask::set_follow_sprite_flip);
    ClassDB::bind_method(D_METHOD("get_follow_sprite_flip"), &PixelCollisionMask::get_follow_sprite_flip);
    ClassDB::bind_method(D_METHOD("bake", "sprite_frames"), &PixelCollisionMask::bake, DEFVAL(Ref<SpriteFrames>()));
    ClassDB::bind_method(D_METHOD("bake_sprite", "sprite"), &PixelCollisionMask::bake_sprite);
    ClassDB::bind_method(D_METHOD("is_baked_for", "sprite_frames"), &PixelCollisionMask::is_baked_for, DEFVAL(Ref<SpriteFrames>()));
    ClassDB::bind_method(D_METHOD("is_baked_for_sprite", "sprite"), &PixelCollisionMask::is_baked_for_sprite);
    ClassDB::bind_method(D_METHOD("validate_source_files"), &PixelCollisionMask::validate_source_files);
    ClassDB::bind_method(D_METHOD("get_bake_error"), &PixelCollisionMask::get_bake_error);
    ClassDB::bind_method(D_METHOD("get_baked_source"), &PixelCollisionMask::get_baked_source);
    ClassDB::bind_method(D_METHOD("get_baked_texture"), &PixelCollisionMask::get_baked_texture);
    ClassDB::bind_method(D_METHOD("get_revision"), &PixelCollisionMask::get_revision);
    ClassDB::bind_method(D_METHOD("get_preview_image", "sprite_frames", "animation", "frame"), &PixelCollisionMask::get_preview_image);
    ClassDB::bind_method(D_METHOD("get_preview_image_for_sprite", "sprite"), &PixelCollisionMask::get_preview_image_for_sprite);
    ClassDB::bind_method(D_METHOD("set_baked_data", "value"), &PixelCollisionMask::set_baked_data);
    ClassDB::bind_method(D_METHOD("get_baked_data"), &PixelCollisionMask::get_baked_data);
    ClassDB::bind_method(D_METHOD("_on_source_changed"), &PixelCollisionMask::on_source_changed);

    ADD_PROPERTY(PropertyInfo(Variant::INT, "shape_mode", PROPERTY_HINT_ENUM, "Precise,Rectangle"), "set_shape_mode", "get_shape_mode");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "frame_mode", PROPERTY_HINT_ENUM, "Current Frame,Animation Union,Fixed Frame"), "set_frame_mode", "get_frame_mode");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "alpha_threshold", PROPERTY_HINT_RANGE, "0,1,0.001"), "set_alpha_threshold", "get_alpha_threshold");
    ADD_PROPERTY(PropertyInfo(Variant::RECT2I, "manual_bounds"), "set_manual_bounds", "get_manual_bounds");
    ADD_PROPERTY(PropertyInfo(Variant::STRING_NAME, "fixed_animation"), "set_fixed_animation", "get_fixed_animation");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "fixed_frame", PROPERTY_HINT_RANGE, "0,4096,1,or_greater"), "set_fixed_frame", "get_fixed_frame");
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "source_frames", PROPERTY_HINT_RESOURCE_TYPE, "SpriteFrames"), "set_source_frames", "get_source_frames");
    ADD_PROPERTY(PropertyInfo(Variant::VECTOR2I, "mask_offset"), "set_mask_offset", "get_mask_offset");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "follow_sprite_flip"), "set_follow_sprite_flip", "get_follow_sprite_flip");
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "_baked_data", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "set_baked_data", "get_baked_data");
    BIND_ENUM_CONSTANT(PRECISE);
    BIND_ENUM_CONSTANT(RECTANGLE);
    BIND_ENUM_CONSTANT(CURRENT_FRAME);
    BIND_ENUM_CONSTANT(ANIMATION_UNION);
    BIND_ENUM_CONSTANT(FIXED_FRAME);
}

Dictionary PixelCollisionMask::settings() const {
    Dictionary data;
    data["shape"] = int(shape_mode_);
    data["frame_mode"] = int(frame_mode_);
    data["alpha"] = alpha_threshold_;
    data["bounds"] = manual_bounds_;
    data["fixed_animation"] = fixed_animation_;
    data["fixed_frame"] = fixed_frame_;
    return data;
}

Array PixelCollisionMask::source_layout(const Ref<SpriteFrames> &source) const {
    Array layout;
    if (source.is_null()) {
        return layout;
    }
    PackedStringArray names = source->get_animation_names();
    names.sort();
    for (int64_t i = 0; i < names.size(); ++i) {
        const StringName animation(names[i]);
        Dictionary entry;
        entry["animation"] = animation;
        Array textures;
        for (int frame = 0; frame < source->get_frame_count(animation); ++frame) {
            textures.append(texture_layout(source->get_frame_texture(animation, frame)));
        }
        entry["textures"] = textures;
        layout.append(entry);
    }
    return layout;
}

Dictionary PixelCollisionMask::source_dependencies(const Ref<SpriteFrames> &source) const {
    Dictionary dependencies;
    const PackedStringArray names = source->get_animation_names();
    // External SpriteFrames files can contain inline ImageTexture data. Their
    // content hash detects edits without depending on subresource identities.
    const String source_path = source->get_path();
    if (!source_path.is_empty() && !source_path.contains("::")) record_file_dependency(dependencies, source_path);
    for (int64_t i = 0; i < names.size(); ++i) {
        const StringName animation(names[i]);
        for (int frame = 0; frame < source->get_frame_count(animation); ++frame) {
            record_texture_dependencies(dependencies, source->get_frame_texture(animation, frame));
        }
    }
    return dependencies;
}

bool PixelCollisionMask::dependencies_match() const {
    const Dictionary dependencies = baked_data_.get("dependencies", Dictionary());
    const Array paths = dependencies.keys();
    for (int64_t i = 0; i < paths.size(); ++i) {
        const String path = paths[i];
        if (!FileAccess::file_exists(path)) {
            return false;
        }
        const uint64_t modified = FileAccess::get_modified_time(path);
        const DependencyStamp *cached = dependency_stamps_.getptr(path);
        if (!cached || cached->modified != modified) {
            DependencyStamp stamp;
            stamp.modified = modified;
            stamp.digest = FileAccess::get_sha256(path);
            dependency_stamps_.insert(path, stamp);
            cached = dependency_stamps_.getptr(path);
        }
        if (cached->digest != String(dependencies[path])) return false;
    }
    return true;
}

void PixelCollisionMask::refresh_validity() {
    valid_ = false;
    if (baked_data_.is_empty() || (baked_source_.is_null() && baked_texture_.is_null()) || frames_.is_empty()) {
        bake_error_ = "The mask has no valid baked data. Use Bake / Refresh Mask.";
    } else if (source_dirty_) {
        bake_error_ = "A source resource changed. Bake the mask again.";
    } else if (!Dictionary(baked_data_.get("settings", Dictionary())).recursive_equal(settings(), 0)) {
        bake_error_ = "Mask settings changed. Bake the mask again.";
    } else if (source_frames_.is_valid() && source_frames_ != baked_source_) {
        bake_error_ = "The independent source differs from the baked source.";
    } else {
        valid_ = true;
        bake_error_ = String();
    }
}

void PixelCollisionMask::configuration_changed() {
    ++revision_;
    refresh_validity();
    emit_changed();
}

void PixelCollisionMask::set_shape_mode(ShapeMode value) {
    if ((value != PRECISE && value != RECTANGLE) || shape_mode_ == value) return;
    shape_mode_ = value;
    configuration_changed();
}
void PixelCollisionMask::set_frame_mode(FrameMode value) {
    if ((value != CURRENT_FRAME && value != ANIMATION_UNION && value != FIXED_FRAME) || frame_mode_ == value) return;
    frame_mode_ = value;
    configuration_changed();
}
void PixelCollisionMask::set_alpha_threshold(double value) {
    if (!std::isfinite(value)) return;
    value = std::clamp(value, 0.0, 1.0);
    if (alpha_threshold_ == value) return;
    alpha_threshold_ = value;
    configuration_changed();
}
void PixelCollisionMask::set_manual_bounds(const Rect2i &value) {
    if (manual_bounds_ == value) return;
    manual_bounds_ = value;
    configuration_changed();
}
void PixelCollisionMask::set_fixed_animation(const StringName &value) {
    if (fixed_animation_ == value) return;
    fixed_animation_ = value;
    configuration_changed();
}
void PixelCollisionMask::set_fixed_frame(int value) {
    value = std::max(value, 0);
    if (fixed_frame_ == value) return;
    fixed_frame_ = value;
    configuration_changed();
}
void PixelCollisionMask::set_source_frames(const Ref<SpriteFrames> &value) {
    if (source_frames_ == value) return;
    source_frames_ = value;
    configuration_changed();
}
void PixelCollisionMask::set_mask_offset(const Vector2i &value) {
    if (mask_offset_ == value) return;
    mask_offset_ = value;
    configuration_changed();
}
void PixelCollisionMask::set_follow_sprite_flip(bool value) {
    if (follow_sprite_flip_ == value) return;
    follow_sprite_flip_ = value;
    configuration_changed();
}

void PixelCollisionMask::disconnect_sources() {
    const Callable changed(this, "_on_source_changed");
    for (const Ref<Resource> &resource : watched_sources_) {
        if (resource.is_valid() && resource->is_connected("changed", changed)) {
            resource->disconnect("changed", changed);
        }
    }
    watched_sources_.clear();
}

void PixelCollisionMask::watch_sources() {
    disconnect_sources();
    const Callable changed(this, "_on_source_changed");
    auto watch = [&](const Ref<Resource> &resource) {
        if (resource.is_valid() && !resource->is_connected("changed", changed)) {
            resource->connect("changed", changed);
            watched_sources_.push_back(resource);
        }
    };
    auto watch_texture = [&](Ref<Texture2D> texture) {
        for (int depth = 0; depth < 17 && texture.is_valid(); ++depth) {
            watch(texture);
            Ref<AtlasTexture> atlas = texture;
            if (atlas.is_null()) break;
            texture = atlas->get_atlas();
        }
    };
    if (baked_texture_.is_valid()) watch_texture(baked_texture_);
    if (baked_source_.is_null()) return;
    watch(baked_source_);
    const PackedStringArray animations = baked_source_->get_animation_names();
    for (int64_t i = 0; i < animations.size(); ++i) {
        const StringName animation(animations[i]);
        for (int frame = 0; frame < baked_source_->get_frame_count(animation); ++frame) {
            watch_texture(baked_source_->get_frame_texture(animation, frame));
        }
    }
}

void PixelCollisionMask::on_source_changed() {
    dependency_stamps_.clear();
    source_dirty_ = true;
    baked_data_["source_dirty"] = true;
    configuration_changed();
}

PixelCollisionMask::~PixelCollisionMask() {
    disconnect_sources();
}

Error PixelCollisionMask::fail_bake(const String &message, Error error) {
    source_dirty_ = true;
    baked_data_["source_dirty"] = true;
    valid_ = false;
    bake_error_ = message;
    ++revision_;
    emit_changed();
    return error;
}

Error PixelCollisionMask::bake(const Ref<SpriteFrames> &sprite_frames) {
    const Ref<SpriteFrames> source = source_frames_.is_valid() ? source_frames_ : sprite_frames;
    return bake_source(source);
}

Error PixelCollisionMask::bake_sprite(Sprite2D *sprite) {
    if (!sprite) {
        return fail_bake("Assign a Sprite2D before baking a mask.", ERR_INVALID_PARAMETER);
    }
    if (source_frames_.is_valid()) return bake_source(source_frames_);
    const Ref<Texture2D> texture = sprite->get_texture();
    if (texture.is_null()) {
        return fail_bake("Assign a texture before baking a Sprite2D mask.", ERR_INVALID_PARAMETER);
    }
    const Vector2 texture_size(texture->get_width(), texture->get_height());
    const Rect2 region = sprite->is_region_enabled()
        ? sprite->get_region_rect() : Rect2(Vector2(), texture_size);
    const int hframes = sprite->get_hframes();
    const int vframes = sprite->get_vframes();
    if (!std::isfinite(region.position.x) || !std::isfinite(region.position.y) ||
        !std::isfinite(region.size.x) || !std::isfinite(region.size.y) ||
        !integral_rect(region) || region.size.x <= 0 || region.size.y <= 0 ||
        region.position.x < 0 || region.position.y < 0 ||
        region.position.x + region.size.x > texture_size.x ||
        region.position.y + region.size.y > texture_size.y || hframes <= 0 || vframes <= 0) {
        return fail_bake("Sprite2D regions must have positive whole-pixel dimensions and lie inside the logical texture canvas.", ERR_INVALID_PARAMETER);
    }
    if (int64_t(hframes) * vframes > std::numeric_limits<int>::max()) {
        return fail_bake("Sprite2D sheet frame count exceeds the supported index range.", ERR_INVALID_PARAMETER);
    }
    const Vector2 cell_size(region.size.x / hframes, region.size.y / vframes);
    if (cell_size != cell_size.floor() || cell_size.x < 1 || cell_size.y < 1 ||
        cell_size.x > MAX_DIMENSION || cell_size.y > MAX_DIMENSION ||
        double(cell_size.x) * cell_size.y > MAX_PIXELS) {
        return fail_bake("Sprite2D sheet cells must have positive whole-pixel dimensions within the mask size limit.", ERR_INVALID_PARAMETER);
    }
    if (frame_mode_ != FIXED_FRAME && double(region.size.x) * region.size.y > MAX_BAKE_PIXELS) {
        return fail_bake("Mask source exceeds the 256 million pixel bake limit.", ERR_OUT_OF_MEMORY);
    }
    // Static sheets are sliced directly during authoring. There is no hidden
    // SpriteFrames resource or wrapper resource for each cell or scene node.
    return bake_source(Ref<SpriteFrames>(), sprite);
}

Error PixelCollisionMask::bake_source(const Ref<SpriteFrames> &source, const Sprite2D *sprite) {
    if (source.is_null() && !sprite) {
        return fail_bake("Assign SpriteFrames before baking a mask.", ERR_INVALID_PARAMETER);
    }
    if (manual_bounds_.size.x < 0 || manual_bounds_.size.y < 0) {
        return fail_bake("Manual bounds cannot have a negative size.", ERR_INVALID_PARAMETER);
    }
    const int sprite_frame_count = sprite ? sprite->get_hframes() * sprite->get_vframes() : 0;
    const bool fixed_exists = sprite
        ? fixed_animation_ == StringName("default") && fixed_frame_ < sprite_frame_count
        : source->has_animation(fixed_animation_) && fixed_frame_ < source->get_frame_count(fixed_animation_);
    if (frame_mode_ == FIXED_FRAME && !fixed_exists) {
        return fail_bake("The fixed animation or fixed frame does not exist.", ERR_INVALID_PARAMETER);
    }
    Dictionary animations;
    Ref<Image> sprite_image;
    Rect2i sprite_region;
    Vector2i sprite_cell;
    if (sprite) {
        String error;
        sprite_image = logical_image(sprite->get_texture(), error);
        if (sprite_image.is_null()) return fail_bake(error, ERR_CANT_CREATE);
        sprite_region = sprite->is_region_enabled() ? Rect2i(sprite->get_region_rect())
            : Rect2i(0, 0, sprite_image->get_width(), sprite_image->get_height());
        sprite_cell = Vector2i(sprite_region.size.x / sprite->get_hframes(), sprite_region.size.y / sprite->get_vframes());
    }
    int64_t total_pixels = 0;
    PackedStringArray names;
    if (sprite) names.append("default");
    else names = source->get_animation_names();
    names.sort();
    for (int64_t i = 0; i < names.size(); ++i) {
        const StringName animation(names[i]);
        if (frame_mode_ == FIXED_FRAME && animation != fixed_animation_) continue;
        std::vector<Frame> baked_frames;
        const int count = sprite ? sprite_frame_count : source->get_frame_count(animation);
        const int first = frame_mode_ == FIXED_FRAME ? fixed_frame_ : 0;
        const int end = frame_mode_ == FIXED_FRAME ? fixed_frame_ + 1 : count;
        for (int index = first; index < end; ++index) {
            String error;
            Ref<Image> image;
            if (sprite) {
                const Vector2i cell_position(index % sprite->get_hframes(), index / sprite->get_hframes());
                image = Image::create_empty(sprite_cell.x, sprite_cell.y, false, Image::FORMAT_RGBA8);
                image->blit_rect(sprite_image, Rect2i(sprite_region.position + cell_position * sprite_cell, sprite_cell), Vector2i());
            } else {
                image = logical_image(source->get_frame_texture(animation, index), error);
            }
            if (image.is_null()) {
                return fail_bake(String(animation) + " frame " + String::num_int64(index) + ": " + error, ERR_CANT_CREATE);
            }
            total_pixels += int64_t(image->get_width()) * image->get_height();
            if (total_pixels > MAX_BAKE_PIXELS) {
                return fail_bake("Mask source exceeds the 256 million pixel bake limit.", ERR_OUT_OF_MEMORY);
            }
            if (frame_mode_ == ANIMATION_UNION && !baked_frames.empty() &&
                (baked_frames.front().width != image->get_width() || baked_frames.front().height != image->get_height())) {
                return fail_bake(String(animation) + ": Animation Union requires equal logical frame dimensions. "
                    "Pad frames to a common canvas or use Current Frame / Fixed Frame.", ERR_INVALID_PARAMETER);
            }
            baked_frames.push_back(extract_frame(image, alpha_threshold_, manual_bounds_, shape_mode_));
        }
        if (baked_frames.empty()) continue;
        Array records;
        if (frame_mode_ == ANIMATION_UNION) {
            Frame merged;
            for (const Frame &frame : baked_frames) {
                merged.width = std::max(merged.width, frame.width);
                merged.height = std::max(merged.height, frame.height);
            }
            if (!valid_size(merged.width, merged.height)) {
                return fail_bake("The animation union exceeds mask dimensions.", ERR_OUT_OF_MEMORY);
            }
            merged.occupancy.resize(int64_t(merged.width) * merged.height);
            merged.occupancy.fill(0);
            uint8_t *out = merged.occupancy.ptrw();
            for (const Frame &frame : baked_frames) {
                const uint8_t *pixels = frame.occupancy.ptr();
                for (int y = 0; y < frame.height; ++y) {
                    for (int x = 0; x < frame.width; ++x) {
                        out[int64_t(y) * merged.width + x] |= pixels[int64_t(y) * frame.width + x];
                    }
                }
            }
            // Rectangle union fills the bounding rectangle of all contributing frames.
            if (shape_mode_ == RECTANGLE) {
                int left = merged.width, top = merged.height, right = -1, bottom = -1;
                for (int y = 0; y < merged.height; ++y) for (int x = 0; x < merged.width; ++x) {
                    if (out[int64_t(y) * merged.width + x]) {
                        left = std::min(left, x); top = std::min(top, y);
                        right = std::max(right, x); bottom = std::max(bottom, y);
                    }
                }
                for (int y = top; y <= bottom; ++y) for (int x = left; x <= right; ++x) {
                    out[int64_t(y) * merged.width + x] = 1;
                }
            }
            records.append(frame_to_dictionary(merged));
        } else {
            for (const Frame &frame : baked_frames) records.append(frame_to_dictionary(frame));
        }
        animations[animation] = records;
    }
    if (animations.is_empty()) {
        return fail_bake("SpriteFrames contains no usable animation frames.", ERR_INVALID_PARAMETER);
    }
    Dictionary data;
    data["version"] = DATA_VERSION;
    if (sprite) {
        Dictionary descriptor;
        descriptor["texture"] = sprite->get_texture();
        descriptor["texture_layout"] = texture_layout(sprite->get_texture());
        descriptor["hframes"] = sprite->get_hframes();
        descriptor["vframes"] = sprite->get_vframes();
        descriptor["region_enabled"] = sprite->is_region_enabled();
        descriptor["region"] = sprite->is_region_enabled() ? sprite->get_region_rect() : Rect2();
        data["sprite_source"] = descriptor;
    } else {
        data["source"] = source;
        data["layout"] = source_layout(source);
    }
    data["settings"] = settings();
    if (sprite) {
        Dictionary dependencies;
        record_texture_dependencies(dependencies, sprite->get_texture());
        data["dependencies"] = dependencies;
    } else {
        data["dependencies"] = source_dependencies(source);
    }
    data["animations"] = animations;
    data["source_dirty"] = false;
    set_baked_data(data);
    return valid_ ? OK : ERR_INVALID_DATA;
}

void PixelCollisionMask::set_baked_data(const Dictionary &value) {
    disconnect_sources();
    // godot-cpp 4.5 Dictionary move assignment reconstructs its storage without
    // releasing the previous dictionary. Use copy assignment to release old
    // baked sources and textures when an existing resource is baked again.
    const Dictionary replacement = value.duplicate(true);
    baked_data_ = replacement;
    frames_.clear();
    dependency_stamps_.clear();
    baked_source_ = Ref<SpriteFrames>();
    baked_texture_ = Ref<Texture2D>();
    baked_hframes_ = baked_vframes_ = 1;
    baked_region_enabled_ = false;
    baked_region_ = Rect2();
    valid_ = false;
    source_dirty_ = bool(baked_data_.get("source_dirty", false));
    ++revision_;
    if (int(baked_data_.get("version", 0)) != DATA_VERSION) {
        bake_error_ = "Baked mask data is absent or has an unsupported version.";
        emit_changed();
        return;
    }
    baked_source_ = baked_data_.get("source", Ref<SpriteFrames>());
    const Dictionary sprite_source = baked_data_.get("sprite_source", Dictionary());
    if (!sprite_source.is_empty()) {
        baked_texture_ = sprite_source.get("texture", Ref<Texture2D>());
        baked_hframes_ = int(sprite_source.get("hframes", 0));
        baked_vframes_ = int(sprite_source.get("vframes", 0));
        baked_region_enabled_ = bool(sprite_source.get("region_enabled", false));
        baked_region_ = sprite_source.get("region", Rect2());
        const Dictionary texture_descriptor = sprite_source.get("texture_layout", Dictionary());
        if (baked_texture_.is_null() || baked_source_.is_valid() || baked_hframes_ < 1 || baked_vframes_ < 1 ||
            int64_t(baked_hframes_) * baked_vframes_ > std::numeric_limits<int>::max() ||
            !texture_layout(baked_texture_).recursive_equal(texture_descriptor, 0) ||
            (baked_region_enabled_ && (!std::isfinite(baked_region_.position.x) ||
             !std::isfinite(baked_region_.position.y) || !std::isfinite(baked_region_.size.x) ||
             !std::isfinite(baked_region_.size.y) || !integral_rect(baked_region_) ||
             baked_region_.size.x <= 0 || baked_region_.size.y <= 0))) {
            baked_texture_.unref();
            baked_source_.unref();
            bake_error_ = "Baked Sprite2D source data is invalid.";
            emit_changed();
            return;
        }
    }
    const Dictionary animations = baked_data_.get("animations", Dictionary());
    const Array names = animations.keys();
    int64_t total_pixels = 0;
    bool malformed = false;
    for (int64_t i = 0; i < names.size() && !malformed; ++i) {
        const StringName name = names[i];
        const Array records = animations[name];
        std::vector<Frame> frames;
        int left = MAX_DIMENSION, top = MAX_DIMENSION;
        int right = -1, bottom = -1;
        for (int64_t j = 0; j < records.size(); ++j) {
            const Dictionary record = records[j];
            Frame frame;
            frame.width = int(record.get("width", 0));
            frame.height = int(record.get("height", 0));
            frame.occupancy = record.get("pixels", PackedByteArray());
            total_pixels += int64_t(frame.width) * frame.height;
            if (!valid_size(frame.width, frame.height) ||
                frame.occupancy.size() != int64_t(frame.width) * frame.height || total_pixels > MAX_BAKE_PIXELS) {
                malformed = true;
                break;
            }
            const uint8_t *pixels = frame.occupancy.ptr();
            for (int y = 0; y < frame.height; ++y) {
                for (int x = 0; x < frame.width; ++x) {
                    if (pixels[int64_t(y) * frame.width + x]) {
                        left = std::min(left, x);
                        top = std::min(top, y);
                        right = std::max(right, x);
                        bottom = std::max(bottom, y);
                    }
                }
            }
            frames.push_back(std::move(frame));
        }
        if (!frames.empty()) {
            // Derive shared bounds on load so existing baked resources need no migration.
            const Rect2i bounds = right >= left && bottom >= top
                ? Rect2i(left, top, right - left + 1, bottom - top + 1) : Rect2i();
            for (Frame &frame : frames) frame.collision_bounds = bounds;
            frames_.insert(name, std::move(frames));
        }
    }
    if (malformed) {
        frames_.clear();
        bake_error_ = "Baked mask data has invalid dimensions or pixel counts.";
    } else {
        refresh_validity();
        watch_sources();
    }
    emit_changed();
}

bool PixelCollisionMask::is_baked_for(const Ref<SpriteFrames> &sprite_frames) const {
    const Ref<SpriteFrames> source = source_frames_.is_valid() ? source_frames_ : sprite_frames;
    if (!valid_ || source.is_null() || source != baked_source_) return false;
    Dictionary current, baked;
    current["layout"] = source_layout(source);
    baked["layout"] = baked_data_.get("layout", Array());
    // Exported packages can omit originals and rewrite .import/remap metadata.
    // Runtime validity depends only on the serialized pixels, layout and settings.
    return current.recursive_equal(baked, 0) &&
        (!Engine::get_singleton()->is_editor_hint() || dependencies_match());
}

bool PixelCollisionMask::sprite_source_matches(const Sprite2D *sprite) const {
    // Frame number is intentionally excluded: every sheet cell shares one bake.
    return sprite && baked_texture_.is_valid() && sprite->get_texture() == baked_texture_ &&
        sprite->get_hframes() == baked_hframes_ && sprite->get_vframes() == baked_vframes_ &&
        sprite->is_region_enabled() == baked_region_enabled_ &&
        (!baked_region_enabled_ || sprite->get_region_rect() == baked_region_);
}

bool PixelCollisionMask::is_baked_for_sprite(Sprite2D *sprite) const {
    if (!sprite) return false;
    if (source_frames_.is_valid()) return is_baked_for(source_frames_);
    if (!valid_ || !sprite_source_matches(sprite)) return false;
    const Dictionary descriptor = baked_data_.get("sprite_source", Dictionary());
    const Dictionary layout = descriptor.get("texture_layout", Dictionary());
    return texture_layout(baked_texture_).recursive_equal(layout, 0) &&
        (!Engine::get_singleton()->is_editor_hint() || dependencies_match());
}

bool PixelCollisionMask::validate_source_files() const {
    return valid_ && dependencies_match();
}

const PixelCollisionMask::Frame *PixelCollisionMask::get_frame(const Ref<SpriteFrames> &sprite_frames,
                                                               const StringName &animation, int frame) const {
    const Ref<SpriteFrames> source = source_frames_.is_valid() ? source_frames_ : sprite_frames;
    if (!valid_ || source.is_null() || source != baked_source_) return nullptr;
    const StringName selected = frame_mode_ == FIXED_FRAME ? fixed_animation_ : animation;
    const std::vector<Frame> *frames = frames_.getptr(selected);
    if (!frames || !source->has_animation(selected)) return nullptr;
    const int index = frame_mode_ == CURRENT_FRAME ? frame : 0;
    if (index < 0 || size_t(index) >= frames->size()) return nullptr;
    return &(*frames)[size_t(index)];
}

const PixelCollisionMask::Frame *PixelCollisionMask::get_frame_for_sprite(const Sprite2D *sprite) const {
    if (!sprite) return nullptr;
    if (source_frames_.is_valid()) return get_frame(source_frames_, StringName("default"), sprite->get_frame());
    if (!valid_ || !sprite_source_matches(sprite)) return nullptr;
    const StringName selected = frame_mode_ == FIXED_FRAME ? fixed_animation_ : StringName("default");
    const std::vector<Frame> *frames = frames_.getptr(selected);
    const int index = frame_mode_ == CURRENT_FRAME ? sprite->get_frame() : 0;
    if (!frames || index < 0 || size_t(index) >= frames->size()) return nullptr;
    return &(*frames)[size_t(index)];
}

Ref<Image> PixelCollisionMask::get_preview_image(const Ref<SpriteFrames> &sprite_frames,
                                                const StringName &animation, int index) const {
    return frame_preview(get_frame(sprite_frames, animation, index));
}

Ref<Image> PixelCollisionMask::get_preview_image_for_sprite(Sprite2D *sprite) const {
    return frame_preview(get_frame_for_sprite(sprite));
}
} // namespace godot
