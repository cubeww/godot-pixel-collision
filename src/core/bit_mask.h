#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace pixel_collision {

// Inclusive pixel bounds. The default value represents an empty region.
struct Bounds {
    int64_t left = 0;
    int64_t top = 0;
    int64_t right = -1;
    int64_t bottom = -1;

    bool empty() const noexcept { return right < left || bottom < top; }
    bool intersects(const Bounds &other) const noexcept;
};

// Column-major linear transform: (xx*x + yx*y, xy*x + yy*y).
// Node placement and local mask offsets are supplied separately to AffineMask.
struct AffineTransform {
    double xx = 1.0;
    double xy = 0.0;
    double yx = 0.0;
    double yy = 1.0;
};

class AffineMask;

// Immutable, row-aligned 64-bit occupancy. Unused high bits are always zero.
class BitMask {
public:
    static constexpr int32_t max_dimension = 32768;
    static constexpr uint64_t max_pixels = 64ULL * 1024ULL * 1024ULL;

    BitMask() = default;
    static BitMask from_bytes(int32_t width, int32_t height,
                             const std::vector<uint8_t> &pixels);
    static BitMask from_words(int32_t width, int32_t height,
                             const std::vector<uint64_t> &words);

    int32_t width() const noexcept { return width_; }
    int32_t height() const noexcept { return height_; }
    size_t words_per_row() const noexcept { return stride_; }
    const std::vector<uint64_t> &words() const noexcept { return words_; }
    bool empty() const noexcept { return occupied_.empty(); }
    Bounds occupied_bounds() const noexcept { return occupied_; }
    bool test(int32_t x, int32_t y) const noexcept;

    // Returns a new local-top-left mask. Signed scales compose with explicit flips.
    // Translation caused by a negative transform is the caller's responsibility.
    BitMask transformed(int32_t scale_x, int32_t scale_y,
                        bool flip_h = false, bool flip_v = false) const;

private:
    int32_t width_ = 0;
    int32_t height_ = 0;
    size_t stride_ = 0;
    std::vector<uint64_t> words_;
    Bounds occupied_;

    static void validate_dimensions(int32_t width, int32_t height);
    void recompute_bounds() noexcept;
    uint64_t read_window(int32_t x, int32_t y) const noexcept;
    friend bool overlaps(const BitMask &, int64_t, int64_t,
                         const BitMask &, int64_t, int64_t);
    friend bool overlaps(const AffineMask &, const AffineMask &);
};

// Positions specify the top-left of the complete mask, not its occupied bounds.
// Throws overflow_error when a nonempty mask extends outside int64 coordinates.
Bounds bounds_at(const BitMask &mask, int64_t x, int64_t y);
bool overlaps(const BitMask &a, int64_t ax, int64_t ay,
              const BitMask &b, int64_t bx, int64_t by);

// A non-owning view of baked source pixels, sampled only when queried. The mask
// must outlive the view. Construction validates the basis without allocating a
// transformed bitmap; set_position() reuses that inverse for movement probes.
class AffineMask {
public:
    static constexpr double coordinate_limit = 1125899906842624.0; // 2^50.

    AffineMask() = default;
    AffineMask(const BitMask &mask, const AffineTransform &basis,
               double node_x, double node_y, double local_left, double local_top,
               Bounds logical_bounds, bool flip_h = false, bool flip_v = false);

    bool matches(const BitMask &mask, const AffineTransform &basis,
                 double local_left, double local_top, Bounds logical_bounds,
                 bool flip_h = false, bool flip_v = false) const noexcept;
    void set_position(double node_x, double node_y);
    Bounds bounds() const noexcept { return bounds_; }
    // A conservative occupied region for candidate lookup. Identity integer-
    // offset views can clip shared animation bounds to their current pixels.
    Bounds query_bounds() const noexcept;
    // Covers every explicit-flip state and the complete source canvas. This is
    // suitable for an index whose sprites have no dedicated flip notification.
    Bounds broad_bounds() const noexcept { return broad_bounds_; }
    bool sample(int64_t world_x, int64_t world_y) const noexcept;
    bool empty() const noexcept { return !mask_ || mask_->empty() || bounds_.empty(); }

private:
    const BitMask *mask_ = nullptr;
    AffineTransform basis_;
    Bounds logical_bounds_;
    Bounds bounds_;
    Bounds broad_bounds_;
    double local_left_ = 0;
    double local_top_ = 0;
    double node_x_ = 0;
    double node_y_ = 0;
    double raw_node_x_ = 0;
    double raw_node_y_ = 0;
    double inverse_xx_ = 1;
    double inverse_xy_ = 0;
    double inverse_yx_ = 0;
    double inverse_yy_ = 1;
    double determinant_ = 1;
    int x_exponent_ = 0;
    int y_exponent_ = 0;
    bool flip_h_ = false;
    bool flip_v_ = false;
    bool word_path_ = false;
    bool positioned_ = false;
    bool include_canvas_bounds_ = true;
    uint8_t other_bounds_flips_ = 0;
    int64_t word_x_ = 0;
    int64_t word_y_ = 0;

    Bounds calculate_bounds(Bounds local, double node_x, double node_y,
                            bool flip_h, bool flip_v) const;
    Bounds flipped_bounds(Bounds local, bool flip_h, bool flip_v) const noexcept;
    friend bool overlaps(const AffineMask &, const AffineMask &);
};

// The integer-world intersection is inverse-sampled with source-coordinate
// float conversion and truncation. A first occupied pair ends the scan.
bool overlaps(const AffineMask &a, const AffineMask &b);

} // namespace pixel_collision
