#include "bit_mask.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

namespace pixel_collision {
namespace {

void validate_mask_dimensions(int32_t width, int32_t height) {
    if (width < 0 || height < 0) {
        throw std::invalid_argument("Pixel mask dimensions must be nonnegative.");
    }
    if (width > BitMask::max_dimension || height > BitMask::max_dimension ||
        static_cast<uint64_t>(width) * static_cast<uint64_t>(height) > BitMask::max_pixels) {
        throw std::length_error("Pixel mask exceeds the supported allocation limit.");
    }
}

// Recover the rounding error in the second product before subtracting. Plain
// a*b-c*d can turn a finite, invertible near-parallel basis into a zero determinant.
double difference_of_products(double a, double b, double c, double d) noexcept {
    const double second = c * d;
    return std::fma(a, b, -second) + std::fma(-c, d, second);
}

struct AffineInverse {
    double xx;
    double xy;
    double yx;
    double yy;
    double determinant;
    int x_exponent;
    int y_exponent;

    explicit AffineInverse(const AffineTransform &basis) {
        if (!std::isfinite(basis.xx) || !std::isfinite(basis.xy) ||
            !std::isfinite(basis.yx) || !std::isfinite(basis.yy)) {
            throw std::invalid_argument("Pixel mask transform must be finite.");
        }
        const double x_magnitude = std::max(std::abs(basis.xx), std::abs(basis.xy));
        const double y_magnitude = std::max(std::abs(basis.yx), std::abs(basis.yy));
        if (x_magnitude == 0.0 || y_magnitude == 0.0) {
            throw std::invalid_argument("Pixel mask transform must be invertible.");
        }
        // Power-of-two scaling avoids determinant overflow/underflow for tiny or
        // large uniform scales without introducing division-rounding cancellation.
        std::frexp(x_magnitude, &x_exponent);
        std::frexp(y_magnitude, &y_exponent);
        xx = std::scalbn(basis.xx, -x_exponent);
        xy = std::scalbn(basis.xy, -x_exponent);
        yx = std::scalbn(basis.yx, -y_exponent);
        yy = std::scalbn(basis.yy, -y_exponent);
        determinant = difference_of_products(xx, yy, yx, xy);
        if (!std::isfinite(determinant) || determinant == 0.0) {
            throw std::invalid_argument("Pixel mask transform has no representable inverse.");
        }
    }

};

uint32_t lowest_bit(uint64_t value) noexcept {
    uint32_t result = 0;
    if ((value & 0xffffffffULL) == 0) { value >>= 32; result += 32; }
    if ((value & 0xffffULL) == 0) { value >>= 16; result += 16; }
    if ((value & 0xffULL) == 0) { value >>= 8; result += 8; }
    if ((value & 0xfULL) == 0) { value >>= 4; result += 4; }
    if ((value & 0x3ULL) == 0) { value >>= 2; result += 2; }
    if ((value & 0x1ULL) == 0) { ++result; }
    return result;
}

uint32_t highest_bit(uint64_t value) noexcept {
    uint32_t result = 0;
    if (value >> 32) { value >>= 32; result += 32; }
    if (value >> 16) { value >>= 16; result += 16; }
    if (value >> 8) { value >>= 8; result += 8; }
    if (value >> 4) { value >>= 4; result += 4; }
    if (value >> 2) { value >>= 2; result += 2; }
    if (value >> 1) { ++result; }
    return result;
}

int64_t add_offset(int64_t coordinate, int64_t nonnegative_offset) {
    if (coordinate > std::numeric_limits<int64_t>::max() - nonnegative_offset) {
        throw std::overflow_error("Pixel mask extends outside int64 coordinates.");
    }
    return coordinate + nonnegative_offset;
}

int64_t checked_coordinate(double value) {
    if (!std::isfinite(value) || std::abs(value) > AffineMask::coordinate_limit) {
        throw std::overflow_error("Pixel mask geometry exceeds the supported coordinate range.");
    }
    return static_cast<int64_t>(value);
}

float source_float(double value) noexcept {
    // Explicitly handle out-of-range narrowing. Finite double geometry can
    // exceed float before bbox validation or a source-pixel range check.
    constexpr double maximum = std::numeric_limits<float>::max();
    if (value > maximum) { return std::numeric_limits<float>::infinity(); }
    if (value < -maximum) { return -std::numeric_limits<float>::infinity(); }
    return static_cast<float>(value);
}

Bounds unite(Bounds a, Bounds b) noexcept {
    if (a.empty()) { return b; }
    if (b.empty()) { return a; }
    return {std::min(a.left, b.left), std::min(a.top, b.top),
            std::max(a.right, b.right), std::max(a.bottom, b.bottom)};
}

bool same_bounds(Bounds a, Bounds b) noexcept {
    return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom;
}

} // namespace

bool Bounds::intersects(const Bounds &other) const noexcept {
    return !empty() && !other.empty() && left <= other.right && right >= other.left &&
           top <= other.bottom && bottom >= other.top;
}

void BitMask::validate_dimensions(int32_t width, int32_t height) {
    validate_mask_dimensions(width, height);
}

BitMask BitMask::from_bytes(int32_t width, int32_t height,
                          const std::vector<uint8_t> &pixels) {
    validate_dimensions(width, height);
    const size_t expected = static_cast<size_t>(width) * static_cast<size_t>(height);
    if (pixels.size() != expected) {
        throw std::invalid_argument("Pixel mask byte count does not match its dimensions.");
    }
    BitMask result;
    result.width_ = width;
    result.height_ = height;
    result.stride_ = (static_cast<size_t>(width) + 63) / 64;
    result.words_.resize(result.stride_ * static_cast<size_t>(height), 0);
    for (int32_t y = 0; y < height; ++y) {
        const size_t row = static_cast<size_t>(y) * static_cast<size_t>(width);
        const size_t word_row = static_cast<size_t>(y) * result.stride_;
        for (int32_t x = 0; x < width; ++x) {
            if (pixels[row + static_cast<size_t>(x)] != 0) {
                result.words_[word_row + static_cast<size_t>(x / 64)] |= 1ULL << (x % 64);
            }
        }
    }
    result.recompute_bounds();
    return result;
}

BitMask BitMask::from_words(int32_t width, int32_t height,
                          const std::vector<uint64_t> &words) {
    validate_dimensions(width, height);
    const size_t stride = (static_cast<size_t>(width) + 63) / 64;
    if (words.size() != stride * static_cast<size_t>(height)) {
        throw std::invalid_argument("Pixel mask word count does not match its dimensions.");
    }
    BitMask result;
    result.width_ = width;
    result.height_ = height;
    result.stride_ = stride;
    result.words_ = words;
    const int32_t remainder = width % 64;
    if (remainder != 0) {
        const uint64_t valid_bits = (1ULL << remainder) - 1;
        for (int32_t y = 0; y < height; ++y) {
            result.words_[static_cast<size_t>(y) * stride + stride - 1] &= valid_bits;
        }
    }
    result.recompute_bounds();
    return result;
}

void BitMask::recompute_bounds() noexcept {
    occupied_ = {};
    for (int32_t y = 0; y < height_; ++y) {
        const size_t row = static_cast<size_t>(y) * stride_;
        for (size_t word_x = 0; word_x < stride_; ++word_x) {
            const uint64_t word = words_[row + word_x];
            if (word == 0) { continue; }
            const int64_t left = static_cast<int64_t>(word_x * 64 + lowest_bit(word));
            const int64_t right = static_cast<int64_t>(word_x * 64 + highest_bit(word));
            if (occupied_.empty()) {
                occupied_ = {left, y, right, y};
            } else {
                occupied_.left = std::min(occupied_.left, left);
                occupied_.right = std::max(occupied_.right, right);
                occupied_.bottom = y;
            }
        }
    }
}

bool BitMask::test(int32_t x, int32_t y) const noexcept {
    if (x < 0 || y < 0 || x >= width_ || y >= height_) { return false; }
    return (words_[static_cast<size_t>(y) * stride_ + static_cast<size_t>(x / 64)] &
            (1ULL << (x % 64))) != 0;
}

uint64_t BitMask::read_window(int32_t x, int32_t y) const noexcept {
    const size_t column = static_cast<size_t>(x / 64);
    const size_t index = static_cast<size_t>(y) * stride_ + column;
    const uint32_t shift = static_cast<uint32_t>(x % 64);
    uint64_t result = words_[index] >> shift;
    if (shift != 0 && column + 1 < stride_) {
        result |= words_[index + 1] << (64 - shift);
    }
    return result;
}

BitMask BitMask::transformed(int32_t scale_x, int32_t scale_y,
                             bool flip_h, bool flip_v) const {
    if (scale_x == 0 || scale_y == 0) {
        throw std::invalid_argument("Pixel mask scales must be nonzero integers.");
    }
    const int64_t sx = scale_x < 0 ? -static_cast<int64_t>(scale_x) : scale_x;
    const int64_t sy = scale_y < 0 ? -static_cast<int64_t>(scale_y) : scale_y;
    const int64_t output_width = static_cast<int64_t>(width_) * sx;
    const int64_t output_height = static_cast<int64_t>(height_) * sy;
    if (output_width > max_dimension || output_height > max_dimension ||
        static_cast<uint64_t>(output_width) * static_cast<uint64_t>(output_height) > max_pixels) {
        throw std::length_error("Transformed pixel mask exceeds the supported allocation limit.");
    }
    flip_h = flip_h != (scale_x < 0);
    flip_v = flip_v != (scale_y < 0);
    BitMask result;
    result.width_ = static_cast<int32_t>(output_width);
    result.height_ = static_cast<int32_t>(output_height);
    result.stride_ = (static_cast<size_t>(output_width) + 63) / 64;
    result.words_.resize(result.stride_ * static_cast<size_t>(output_height), 0);
    if (empty()) { return result; }

    for (int32_t y = 0; y < height_; ++y) {
        for (int32_t x = 0; x < width_; ++x) {
            if (!test(x, y)) { continue; }
            const int64_t start_x = (flip_h ? width_ - 1 - x : x) * sx;
            const int64_t start_y = (flip_v ? height_ - 1 - y : y) * sy;
            for (int64_t dy = 0; dy < sy; ++dy) {
                const size_t row = static_cast<size_t>(start_y + dy) * result.stride_;
                int64_t current_x = start_x;
                const int64_t end_x = start_x + sx;
                while (current_x < end_x) {
                    const uint32_t bit_offset = static_cast<uint32_t>(current_x % 64);
                    const uint32_t count = static_cast<uint32_t>(std::min<int64_t>(64 - bit_offset, end_x - current_x));
                    const uint64_t bits = count == 64 ? ~0ULL : (1ULL << count) - 1;
                    result.words_[row + static_cast<size_t>(current_x / 64)] |= bits << bit_offset;
                    current_x += count;
                }
            }
        }
    }
    result.recompute_bounds();
    return result;
}

Bounds bounds_at(const BitMask &mask, int64_t x, int64_t y) {
    const Bounds local = mask.occupied_bounds();
    if (local.empty()) { return {}; }
    return {add_offset(x, local.left), add_offset(y, local.top),
            add_offset(x, local.right), add_offset(y, local.bottom)};
}

bool overlaps(const BitMask &a, int64_t ax, int64_t ay,
              const BitMask &b, int64_t bx, int64_t by) {
    const Bounds aa = bounds_at(a, ax, ay);
    const Bounds bb = bounds_at(b, bx, by);
    if (!aa.intersects(bb)) { return false; }
    const int64_t left = std::max(aa.left, bb.left);
    const int64_t top = std::max(aa.top, bb.top);
    const int32_t width = static_cast<int32_t>(std::min(aa.right, bb.right) - left + 1);
    const int32_t height = static_cast<int32_t>(std::min(aa.bottom, bb.bottom) - top + 1);
    const int32_t a_left = static_cast<int32_t>(left - ax);
    const int32_t b_left = static_cast<int32_t>(left - bx);
    const int32_t a_top = static_cast<int32_t>(top - ay);
    const int32_t b_top = static_cast<int32_t>(top - by);
    for (int32_t y = 0; y < height; ++y) {
        for (int32_t x = 0; x < width; x += 64) {
            uint64_t common = a.read_window(a_left + x, a_top + y) &
                              b.read_window(b_left + x, b_top + y);
            const int32_t remaining = width - x;
            if (remaining < 64) { common &= (1ULL << remaining) - 1; }
            if (common != 0) { return true; }
        }
    }
    return false;
}

AffineMask::AffineMask(const BitMask &mask, const AffineTransform &basis,
                       double node_x, double node_y, double local_left, double local_top,
                       Bounds logical_bounds, bool flip_h, bool flip_v)
    : mask_(&mask), basis_(basis), logical_bounds_(logical_bounds),
      local_left_(local_left), local_top_(local_top), flip_h_(flip_h), flip_v_(flip_v) {
    const AffineInverse inverse(basis);
    inverse_xx_ = inverse.xx;
    inverse_xy_ = inverse.xy;
    inverse_yx_ = inverse.yx;
    inverse_yy_ = inverse.yy;
    determinant_ = inverse.determinant;
    x_exponent_ = inverse.x_exponent;
    y_exponent_ = inverse.y_exponent;
    if (!std::isfinite(local_left) || !std::isfinite(local_top) ||
        std::abs(local_left) > coordinate_limit || std::abs(local_top) > coordinate_limit) {
        throw std::invalid_argument("Pixel mask offsets must be finite supported coordinates.");
    }
    if (!logical_bounds.empty()) {
        checked_coordinate(static_cast<double>(logical_bounds.left));
        checked_coordinate(static_cast<double>(logical_bounds.top));
        checked_coordinate(static_cast<double>(logical_bounds.right));
        checked_coordinate(static_cast<double>(logical_bounds.bottom));
    }
    word_path_ = basis.xx == 1 && basis.xy == 0 && basis.yx == 0 && basis.yy == 1 &&
                  !flip_h && !flip_v && std::trunc(local_left) == local_left &&
                  std::trunc(local_top) == local_top;
    // Flips often leave an animation's full-canvas bbox unchanged. Retain only
    // distinct inputs, so moving one such view evaluates one bbox rather than
    // the same geometry six times. All formerly validated inputs remain covered.
    Bounds unique[4] = {flipped_bounds(logical_bounds_, flip_h_, flip_v_)};
    size_t unique_count = 1;
    for (int flips = 0; flips < 4; ++flips) {
        const Bounds candidate = flipped_bounds(logical_bounds_, (flips & 1) != 0, (flips & 2) != 0);
        bool present = false;
        for (size_t i = 0; i < unique_count; ++i) {
            if (same_bounds(unique[i], candidate)) { present = true; break; }
        }
        if (!present) {
            other_bounds_flips_ |= uint8_t(1 << flips);
            unique[unique_count++] = candidate;
        }
    }
    const Bounds canvas{0, 0, int64_t(mask.width()) - 1, int64_t(mask.height()) - 1};
    for (size_t i = 0; i < unique_count; ++i) {
        if (same_bounds(unique[i], canvas)) { include_canvas_bounds_ = false; break; }
    }
    set_position(node_x, node_y);
}

bool AffineMask::matches(const BitMask &mask, const AffineTransform &basis,
                         double local_left, double local_top, Bounds logical_bounds,
                         bool flip_h, bool flip_v) const noexcept {
    return mask_ == &mask && basis_.xx == basis.xx && basis_.xy == basis.xy &&
            basis_.yx == basis.yx && basis_.yy == basis.yy && local_left_ == local_left &&
            local_top_ == local_top && same_bounds(logical_bounds_, logical_bounds) &&
            flip_h_ == flip_h && flip_v_ == flip_v;
}

Bounds AffineMask::flipped_bounds(Bounds local, bool flip_h, bool flip_v) const noexcept {
    if (local.empty()) { return {}; }
    // The logical bbox can be shared by unequal-sized animation frames. Explicit
    // flips reflect it about the selected frame's full canvas, not its occupancy.
    if (flip_h) {
        const int64_t left = int64_t(mask_->width()) - 1 - local.right;
        local.right = int64_t(mask_->width()) - 1 - local.left;
        local.left = left;
    }
    if (flip_v) {
        const int64_t top = int64_t(mask_->height()) - 1 - local.bottom;
        local.bottom = int64_t(mask_->height()) - 1 - local.top;
        local.top = top;
    }
    return local;
}

Bounds AffineMask::calculate_bounds(Bounds local, double node_x, double node_y,
                                    bool flip_h, bool flip_v) const {
    local = flipped_bounds(local, flip_h, flip_v);
    if (local.empty()) { return {}; }
    const double left = static_cast<double>(local.left) + local_left_;
    const double top = static_cast<double>(local.top) + local_top_;
    const double right = static_cast<double>(local.right) + 1.0 + local_left_;
    const double bottom = static_cast<double>(local.bottom) + 1.0 + local_top_;
    Bounds result;
    if (basis_.xy == 0 && basis_.yx == 0) {
        // The native zero-angle path quantizes its first endpoint before adding
        // the scaled width. This intentionally differs from transforming both
        // outer corners independently, especially at negative/subpixel origins.
        const int64_t ax = checked_coordinate(source_float(double(source_float(left * basis_.xx)) + node_x));
        const int64_t ay = checked_coordinate(source_float(double(source_float(top * basis_.yy)) + node_y));
        const double width = static_cast<double>(local.right - local.left) + 1.0;
        const double height = static_cast<double>(local.bottom - local.top) + 1.0;
        const int64_t bx = checked_coordinate(source_float(double(source_float(width * basis_.xx)) + float(ax)));
        const int64_t by = checked_coordinate(source_float(double(source_float(height * basis_.yy)) + float(ay)));
        result = {std::min(ax, bx), std::min(ay, by),
                  std::max(ax, bx) - 1, std::max(ay, by) - 1};
    } else {
        // Round each product and sum to float, as in the audited native bbox
        // path. Matrix composition and inverse evaluation remain double-based.
        const float xx0 = source_float(left * basis_.xx);
        const float xx1 = source_float(right * basis_.xx);
        const float xy0 = source_float(left * basis_.xy);
        const float xy1 = source_float(right * basis_.xy);
        const float yx0 = source_float(top * basis_.yx);
        const float yx1 = source_float(bottom * basis_.yx);
        const float yy0 = source_float(top * basis_.yy);
        const float yy1 = source_float(bottom * basis_.yy);
        // The native order adds position to the same-axis contribution first.
        // Reassociating these rounded sums can move an edge across an integer.
        const float min_x = source_float(double(source_float(node_x + std::min(xx0, xx1))) + std::min(yx0, yx1));
        const float max_x = source_float(double(source_float(node_x + std::max(xx0, xx1))) + std::max(yx0, yx1));
        const float min_y = source_float(double(source_float(node_y + std::min(yy0, yy1))) + std::min(xy0, xy1));
        const float max_y = source_float(double(source_float(node_y + std::max(yy0, yy1))) + std::max(xy0, xy1));
        result = {checked_coordinate(min_x), checked_coordinate(min_y),
                  checked_coordinate(max_x) - 1, checked_coordinate(max_y) - 1};
    }
    return result;
}

void AffineMask::set_position(double node_x, double node_y) {
    if (!mask_) { throw std::logic_error("Cannot position an unconfigured pixel mask view."); }
    if (positioned_ && node_x == raw_node_x_ && node_y == raw_node_y_) { return; }
    const double quantized_x = static_cast<double>(checked_coordinate(node_x));
    const double quantized_y = static_cast<double>(checked_coordinate(node_y));
    const Bounds next_bounds = calculate_bounds(logical_bounds_, node_x, node_y, flip_h_, flip_v_);
    Bounds next_broad = next_bounds;
    for (int flips = 0; flips < 4; ++flips) {
        if ((other_bounds_flips_ & (1 << flips)) == 0) { continue; }
        next_broad = unite(next_broad, calculate_bounds(logical_bounds_, node_x, node_y,
                                                       (flips & 1) != 0, (flips & 2) != 0));
    }
    if (include_canvas_bounds_) {
        const Bounds canvas{0, 0, int64_t(mask_->width()) - 1, int64_t(mask_->height()) - 1};
        next_broad = unite(next_broad, calculate_bounds(canvas, node_x, node_y, false, false));
    }
    // Only publish a new position after every bound has validated successfully.
    node_x_ = quantized_x;
    node_y_ = quantized_y;
    raw_node_x_ = node_x;
    raw_node_y_ = node_y;
    positioned_ = true;
    bounds_ = next_bounds;
    broad_bounds_ = next_broad;
    if (word_path_) {
        word_x_ = static_cast<int64_t>(quantized_x) + static_cast<int64_t>(local_left_);
        word_y_ = static_cast<int64_t>(quantized_y) + static_cast<int64_t>(local_top_);
    }
}

Bounds AffineMask::query_bounds() const noexcept {
    if (empty()) { return {}; }
    if (!word_path_) { return bounds_; }
    const Bounds occupied = mask_->occupied_bounds();
    // Supported positions/offsets are at most 2^50 each, while source extents
    // are at most 32768. These additions therefore cannot overflow int64.
    const Bounds result{std::max(bounds_.left, word_x_ + occupied.left),
                        std::max(bounds_.top, word_y_ + occupied.top),
                        std::min(bounds_.right, word_x_ + occupied.right),
                        std::min(bounds_.bottom, word_y_ + occupied.bottom)};
    return result.empty() ? Bounds{} : result;
}

bool AffineMask::sample(int64_t world_x, int64_t world_y) const noexcept {
    if (!mask_ || bounds_.empty() || world_x < bounds_.left || world_x > bounds_.right ||
        world_y < bounds_.top || world_y > bounds_.bottom) { return false; }
    const double x = static_cast<double>(world_x) - node_x_;
    const double y = static_cast<double>(world_y) - node_y_;
    const float source_x = source_float(std::scalbn(
            difference_of_products(inverse_yy_, x, inverse_yx_, y) / determinant_,
            -x_exponent_) - local_left_);
    const float source_y = source_float(std::scalbn(
            difference_of_products(inverse_xx_, y, inverse_xy_, x) / determinant_,
            -y_exponent_) - local_top_);
    // This range check is equivalent to truncating first and then testing the
    // source indices, while avoiding undefined conversion of NaN/huge floats.
    // In particular, (-1, 0) maps to source pixel zero instead of being rejected.
    if (!(source_x > -1.0f && source_x < mask_->width() &&
          source_y > -1.0f && source_y < mask_->height())) { return false; }
    int32_t original_x = static_cast<int32_t>(source_x);
    int32_t original_y = static_cast<int32_t>(source_y);
    if (flip_h_) { original_x = mask_->width() - 1 - original_x; }
    if (flip_v_) { original_y = mask_->height() - 1 - original_y; }
    return mask_->test(original_x, original_y);
}

bool overlaps(const AffineMask &a, const AffineMask &b) {
    if (a.empty() || b.empty() || !a.bounds_.intersects(b.bounds_)) { return false; }
    int64_t left = std::max(a.bounds_.left, b.bounds_.left);
    int64_t top = std::max(a.bounds_.top, b.bounds_.top);
    int64_t right = std::min(a.bounds_.right, b.bounds_.right);
    int64_t bottom = std::min(a.bounds_.bottom, b.bounds_.bottom);
    if (a.word_path_ && b.word_path_) {
        // Clip to both logical bboxes AND actual source occupancy. Native bbox
        // quantization may differ from the source-pixel origin near zero.
        const Bounds aa = bounds_at(*a.mask_, a.word_x_, a.word_y_);
        const Bounds bb = bounds_at(*b.mask_, b.word_x_, b.word_y_);
        left = std::max(left, std::max(aa.left, bb.left));
        top = std::max(top, std::max(aa.top, bb.top));
        right = std::min(right, std::min(aa.right, bb.right));
        bottom = std::min(bottom, std::min(aa.bottom, bb.bottom));
        if (left > right || top > bottom) { return false; }
        const int32_t width = static_cast<int32_t>(right - left + 1);
        const int32_t height = static_cast<int32_t>(bottom - top + 1);
        const int32_t a_left = static_cast<int32_t>(left - a.word_x_);
        const int32_t b_left = static_cast<int32_t>(left - b.word_x_);
        const int32_t a_top = static_cast<int32_t>(top - a.word_y_);
        const int32_t b_top = static_cast<int32_t>(top - b.word_y_);
        for (int32_t y = 0; y < height; ++y) {
            for (int32_t x = 0; x < width; x += 64) {
                uint64_t common = a.mask_->read_window(a_left + x, a_top + y) &
                                  b.mask_->read_window(b_left + x, b_top + y);
                const int32_t remaining = width - x;
                if (remaining < 64) { common &= (1ULL << remaining) - 1; }
                if (common != 0) { return true; }
            }
        }
        return false;
    }
    for (int64_t y = top;; ++y) {
        for (int64_t x = left;; ++x) {
            if (a.sample(x, y) && b.sample(x, y)) { return true; }
            if (x == right) { break; }
        }
        if (y == bottom) { break; }
    }
    return false;
}

} // namespace pixel_collision
