#include "core/bit_mask.h"
#include "core/spatial_hash.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

using pixel_collision::BitMask;
using pixel_collision::Bounds;
using pixel_collision::AffineMask;
using pixel_collision::AffineTransform;
using pixel_collision::SpatialHash;

namespace {

uint64_t check_count = 0;

void require(bool condition, const std::string &message) {
    ++check_count;
    if (!condition) { throw std::runtime_error(message); }
}

template <typename Function>
void require_throws(Function function, const std::string &message) {
    bool threw = false;
    try { function(); } catch (const std::exception &) { threw = true; }
    require(threw, message);
}

struct Raster {
    int32_t width;
    int32_t height;
    std::vector<uint8_t> pixels;

    bool at(int64_t x, int64_t y) const {
        return x >= 0 && y >= 0 && x < width && y < height &&
               pixels[static_cast<size_t>(y) * width + static_cast<size_t>(x)] != 0;
    }
    BitMask mask() const { return BitMask::from_bytes(width, height, pixels); }
};

Raster random_raster(std::mt19937_64 &rng, int32_t width, int32_t height) {
    Raster result{width, height, std::vector<uint8_t>(static_cast<size_t>(width) * height)};
    for (uint8_t &pixel : result.pixels) { pixel = rng() % 7 == 0 ? 255 : 0; }
    return result;
}

// The oracle uses original bytes, without bounds or word-window helpers.
bool raster_overlap(const Raster &a, int64_t ax, int64_t ay,
                    const Raster &b, int64_t bx, int64_t by) {
    for (int32_t y = 0; y < a.height; ++y) {
        for (int32_t x = 0; x < a.width; ++x) {
            if (a.at(x, y) && b.at(ax + x - bx, ay + y - by)) { return true; }
        }
    }
    return false;
}

Raster raster_transform(const Raster &source, int32_t sx, int32_t sy, bool flip_h, bool flip_v) {
    if (sx < 0) { sx = -sx; flip_h = !flip_h; }
    if (sy < 0) { sy = -sy; flip_v = !flip_v; }
    Raster result{source.width * sx, source.height * sy,
                  std::vector<uint8_t>(static_cast<size_t>(source.width * sx) * source.height * sy)};
    for (int32_t y = 0; y < result.height; ++y) {
        for (int32_t x = 0; x < result.width; ++x) {
            const int32_t original_x = flip_h ? source.width - 1 - x / sx : x / sx;
            const int32_t original_y = flip_v ? source.height - 1 - y / sy : y / sy;
            result.pixels[static_cast<size_t>(y) * result.width + x] = source.at(original_x, original_y);
        }
    }
    return result;
}

void compare_raster(const BitMask &actual, const Raster &expected) {
    require(actual.width() == expected.width && actual.height() == expected.height,
            "Transformed mask dimensions differ from the oracle.");
    bool any = false;
    int64_t left = expected.width, top = expected.height, right = -1, bottom = -1;
    for (int32_t y = 0; y < expected.height; ++y) {
        for (int32_t x = 0; x < expected.width; ++x) {
            const bool occupied = expected.at(x, y);
            require(actual.test(x, y) == occupied, "Mask occupancy differs from the byte oracle.");
            if (occupied) {
                any = true;
                left = std::min<int64_t>(left, x);
                top = std::min<int64_t>(top, y);
                right = std::max<int64_t>(right, x);
                bottom = std::max<int64_t>(bottom, y);
            }
        }
    }
    require(actual.empty() == !any, "Empty-mask state differs from the oracle.");
    const Bounds bounds = actual.occupied_bounds();
    require(!any ? bounds.empty() : bounds.left == left && bounds.top == top &&
            bounds.right == right && bounds.bottom == bottom, "Occupied bounds differ from the oracle.");
    require(!actual.test(-1, 0) && !actual.test(0, -1) &&
            !actual.test(expected.width, 0) && !actual.test(0, expected.height),
            "Out-of-range mask samples must be false.");
}

void test_mask_fixtures() {
    const Raster ring{5, 5, {1, 1, 1, 1, 1,
                             1, 0, 0, 0, 1,
                             1, 0, 0, 0, 1,
                             1, 0, 0, 0, 1,
                             1, 1, 1, 1, 1}};
    const BitMask outer = ring.mask();
    const BitMask point = BitMask::from_bytes(1, 1, {1});
    require(!pixel_collision::overlaps(outer, -12, -8, point, -10, -6),
            "A point in a pixel-mask hole must not collide.");
    require(pixel_collision::overlaps(outer, -12, -8, point, -12, -6),
            "A point on an occupied boundary must collide.");
    require(!pixel_collision::overlaps(outer, -12, -8, point, -7, -6),
            "Adjacent pixel cells must not overlap.");

    const BitMask empty = BitMask::from_bytes(65, 3, std::vector<uint8_t>(65 * 3));
    require(empty.empty(), "All-zero masks must have empty occupied bounds.");
    require(!pixel_collision::overlaps(empty, 0, 0, point, 0, 0), "Empty masks must never collide.");
    require(BitMask::from_bytes(0, 17, {}).empty(), "Zero-width masks must be supported.");
    require(BitMask::from_words(17, 0, {}).empty(), "Zero-height masks must be supported.");

    for (int width : {1, 63, 64, 65, 129}) {
        const size_t stride = (static_cast<size_t>(width) + 63) / 64;
        const BitMask full = BitMask::from_words(width, 2, std::vector<uint64_t>(stride * 2, ~0ULL));
        compare_raster(full, Raster{width, 2, std::vector<uint8_t>(static_cast<size_t>(width) * 2, 1)});
        if (width % 64 != 0) {
            require((full.words()[stride - 1] >> (width % 64)) == 0,
                    "Unused high bits must be cleared on deserialization.");
        }
        require(!pixel_collision::overlaps(full, 0, 0, point, width, 0),
                "Padding bits must not produce a collision.");
        require(pixel_collision::overlaps(full, 0, 0, point, width - 1, 1),
                "The last valid pixel must remain occupied.");
    }

    const int64_t minimum = std::numeric_limits<int64_t>::min();
    const int64_t maximum = std::numeric_limits<int64_t>::max();
    require(pixel_collision::overlaps(point, minimum, minimum, point, minimum, minimum),
            "A point at int64 minimum must be representable.");
    require(pixel_collision::overlaps(point, maximum, maximum, point, maximum, maximum),
            "A point at int64 maximum must be representable.");
    require(!pixel_collision::overlaps(point, minimum, 0, point, maximum, 0),
            "Opposite coordinate extremes must not overflow the broadphase.");
    require_throws([&] { pixel_collision::bounds_at(outer, maximum, 0); },
                   "Position plus occupied extent overflow must be rejected.");
    require_throws([] { BitMask::from_bytes(-1, 1, {}); }, "Negative dimensions must be rejected.");
    require_throws([] { BitMask::from_words(65, 1, {1}); }, "Invalid word lengths must be rejected.");
    require_throws([] { BitMask::from_bytes(2, 2, {1}); }, "Invalid byte lengths must be rejected.");
    require_throws([] { BitMask::from_bytes(32769, 0, {}); }, "Oversized dimensions must be rejected.");
    require_throws([] { BitMask::from_bytes(32768, 32768, {}); }, "Oversized pixel counts must be rejected.");
    require_throws([&] { point.transformed(0, 1); }, "Zero scales must be rejected.");
    require_throws([&] { point.transformed(std::numeric_limits<int32_t>::min(), 1); },
                   "Minimum signed scales must be rejected without abs overflow.");
    require_throws([&] { outer.transformed(32768, 32768); }, "Scaled allocation overflow must be rejected.");
}

void test_mask_oracles() {
    std::mt19937_64 rng(0x504958454c4d4153ULL);
    const int widths[] = {1, 2, 7, 31, 63, 64, 65, 129};
    for (int iteration = 0; iteration < 12000; ++iteration) {
        const int32_t a_width = widths[rng() % 8];
        const int32_t a_height = static_cast<int32_t>(rng() % 10 + 1);
        const Raster a = random_raster(rng, a_width, a_height);
        const int32_t b_width = widths[rng() % 8];
        const int32_t b_height = static_cast<int32_t>(rng() % 10 + 1);
        const Raster b = random_raster(rng, b_width, b_height);
        const BitMask am = a.mask();
        const BitMask bm = b.mask();
        const int64_t ax = static_cast<int64_t>(rng() % 257) - 128;
        const int64_t ay = static_cast<int64_t>(rng() % 21) - 10;
        const int64_t bx = ax + static_cast<int64_t>(rng() % 259) - 129;
        const int64_t by = ay + static_cast<int64_t>(rng() % 23) - 11;
        const bool expected = raster_overlap(a, ax, ay, b, bx, by);
        require(pixel_collision::overlaps(am, ax, ay, bm, bx, by) == expected,
                "Word overlap differs from independent byte overlap.");
        require(pixel_collision::overlaps(bm, bx, by, am, ax, ay) == expected,
                "Word overlap must be symmetric.");
        if (iteration % 24 == 0) {
            compare_raster(BitMask::from_words(a.width, a.height, am.words()), a);
        }
    }

    for (int iteration = 0; iteration < 600; ++iteration) {
        const int32_t width = widths[rng() % 8];
        const int32_t height = static_cast<int32_t>(rng() % 9 + 1);
        const Raster raster = random_raster(rng, width, height);
        int32_t sx = static_cast<int32_t>(rng() % 3 + 1);
        if (rng() % 2 == 0) { sx = -sx; }
        int32_t sy = static_cast<int32_t>(rng() % 3 + 1);
        if (rng() % 2 == 0) { sy = -sy; }
        const bool flip_h = rng() % 2 != 0;
        const bool flip_v = rng() % 2 != 0;
        compare_raster(raster.mask().transformed(sx, sy, flip_h, flip_v),
                       raster_transform(raster, sx, sy, flip_h, flip_v));
    }
}

struct ViewOracle {
    const Raster &source;
    AffineTransform basis;
    double node_x = 0;
    double node_y = 0;
    double local_x = 0;
    double local_y = 0;
    Bounds logical;
    bool flip_h = false;
    bool flip_v = false;

    Bounds bounds() const {
        if (logical.empty()) { return {}; }
        const int64_t l = flip_h ? source.width - 1 - logical.right : logical.left;
        const int64_t r = flip_h ? source.width - 1 - logical.left : logical.right;
        const int64_t t = flip_v ? source.height - 1 - logical.bottom : logical.top;
        const int64_t b = flip_v ? source.height - 1 - logical.top : logical.bottom;
        if (basis.xy == 0 && basis.yx == 0) {
            const int64_t x0 = static_cast<int64_t>(float(double(float((l + local_x) * basis.xx)) + node_x));
            const int64_t y0 = static_cast<int64_t>(float(double(float((t + local_y) * basis.yy)) + node_y));
            const int64_t x1 = static_cast<int64_t>(float(float((r - l + 1) * basis.xx) + float(x0)));
            const int64_t y1 = static_cast<int64_t>(float(float((b - t + 1) * basis.yy) + float(y0)));
            return {std::min(x0, x1), std::min(y0, y1), std::max(x0, x1) - 1, std::max(y0, y1) - 1};
        }
        // Transform the four outer corners independently; this differs from
        // production's per-axis interval arithmetic and never reads its bounds.
        float minimum_x = std::numeric_limits<float>::infinity();
        float minimum_y = minimum_x;
        float maximum_x = -minimum_x;
        float maximum_y = -minimum_x;
        for (int corner = 0; corner < 4; ++corner) {
            const double x = ((corner & 1) ? r + 1 : l) + local_x;
            const double y = ((corner & 2) ? b + 1 : t) + local_y;
            const float world_x = float(float(node_x + float(x * basis.xx)) + float(y * basis.yx));
            const float world_y = float(float(node_y + float(y * basis.yy)) + float(x * basis.xy));
            minimum_x = std::min(minimum_x, world_x);
            minimum_y = std::min(minimum_y, world_y);
            maximum_x = std::max(maximum_x, world_x);
            maximum_y = std::max(maximum_y, world_y);
        }
        return {static_cast<int64_t>(minimum_x), static_cast<int64_t>(minimum_y),
                static_cast<int64_t>(maximum_x) - 1, static_cast<int64_t>(maximum_y) - 1};
    }

    bool sample(int64_t world_x, int64_t world_y) const {
        const Bounds box = bounds();
        if (world_x < box.left || world_x > box.right || world_y < box.top || world_y > box.bottom) {
            return false;
        }
        // Straight scalar reference over the original bytes. Test coefficients
        // stay well-conditioned; production separately tests robust inverses.
        const double determinant = basis.xx * basis.yy - basis.xy * basis.yx;
        const double dx = double(world_x) - std::trunc(node_x);
        const double dy = double(world_y) - std::trunc(node_y);
        const float x = float((basis.yy * dx - basis.yx * dy) / determinant - local_x);
        const float y = float((basis.xx * dy - basis.xy * dx) / determinant - local_y);
        if (!std::isfinite(x) || !std::isfinite(y) || std::abs(x) > 1000000000 || std::abs(y) > 1000000000) {
            return false;
        }
        int64_t ix = static_cast<int64_t>(x);
        int64_t iy = static_cast<int64_t>(y);
        if (ix < 0 || iy < 0 || ix >= source.width || iy >= source.height) { return false; }
        if (flip_h) { ix = source.width - 1 - ix; }
        if (flip_v) { iy = source.height - 1 - iy; }
        return source.at(ix, iy);
    }
};

bool same_bounds(Bounds a, Bounds b) {
    return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom;
}

void test_affine_fixtures() {
    const BitMask line = BitMask::from_bytes(4, 1, {1, 0, 1, 0});
    const Bounds line_bounds{0, 0, 3, 0};
    const AffineMask half(line, {0.5, 0, 0, 1}, 0, 0, 0, 0, line_bounds);
    require(same_bounds(half.bounds(), {0, 0, 1, 0}) && half.sample(0, 0) && half.sample(1, 0),
            "Minification must inverse-sample integer world points, without a center offset.");
    const AffineMask half_flip(line, {0.5, 0, 0, 1}, 0, 0, 0, 0, line_bounds, true);
    require(!half_flip.sample(0, 0) && !half_flip.sample(1, 0),
            "Explicit flips must reflect the selected source indices after sampling.");
    const AffineMask enlarged(line, {1.5, 0, 0, 1}, 0, 0, 0, 0, line_bounds);
    const bool expected[] = {true, true, false, true, true, false};
    for (int x = 0; x < 6; ++x) {
        require(enlarged.sample(x, 0) == expected[x], "Fractional enlargement uses truncated source coordinates.");
    }

    const BitMask point = BitMask::from_bytes(1, 1, {1});
    const AffineMask tiny(point, {0.75, 0, 0, 0.75}, 0, 0, 0, 0, {0, 0, 0, 0});
    require(tiny.bounds().empty() && !tiny.sample(0, 0),
            "Native two-stage bounds can remove a subpixel-size source canvas.");
    const AffineMask minimum_scale(point, {1e-250, 0, 0, 1e-250}, 0, 0, 0, 0, {0, 0, 0, 0});
    require(minimum_scale.empty(), "Finite tiny transforms must not allocate a raster or produce invalid inverses.");
    const AffineMask subnormal_scale(point, {std::numeric_limits<double>::denorm_min(), 0,
                                           0, std::numeric_limits<double>::denorm_min()},
                                     0, 0, 0, 0, {0, 0, 0, 0});
    require(subnormal_scale.empty(), "Invertible subnormal uniform scales must remain valid.");

    const BitMask three = BitMask::from_bytes(3, 1, {1, 0, 1});
    const AffineMask negative(three, {-1, 0, 0, 1}, 0, 0, 0, 0, {0, 0, 2, 0});
    require(same_bounds(negative.bounds(), {-3, 0, -1, 0}) && !negative.sample(-3, 0) &&
                negative.sample(-2, 0) && !negative.sample(-1, 0) && !negative.sample(0, 0),
            "Negative-scale bounds retain the audited outer-edge subtraction and source lookup behavior.");
    const AffineMask fractional_local(three, {}, 0, 0, 0.5, 0, {0, 0, 2, 0});
    require(fractional_local.sample(0, 0),
            "A source coordinate in (-1, 0) truncates to zero before the range check.");
    const double almost_one = 1.0 - std::ldexp(1.0, -26);
    const AffineMask float_conversion(three, {}, 0, 0, -almost_one, 0, {0, 0, 2, 0});
    require(!float_conversion.sample(0, 0),
            "Source coordinates must round to float before truncation selects the pixel.");

    AffineMask moving(three, {}, 1.8, 0, 0, 0, {0, 0, 2, 0});
    require(same_bounds(moving.bounds(), {1, 0, 3, 0}) && moving.sample(1, 0),
            "Positive subpixel node positions truncate separately from local offsets.");
    moving.set_position(-1.8, 0);
    require(same_bounds(moving.bounds(), {-1, 0, 1, 0}) && moving.sample(-1, 0),
            "Negative subpixel node positions truncate toward zero, not floor.");
    const Bounds before = moving.bounds();
    require_throws([&] { moving.set_position(std::numeric_limits<double>::infinity(), 0); },
                   "Nonfinite movement must be rejected.");
    require(same_bounds(moving.bounds(), before) && moving.sample(-1, 0),
            "Failed movement must not partially change the prepared view.");
    require(moving.matches(three, {}, 0, 0, {0, 0, 2, 0}),
            "Prepared geometry must match independently of its current position.");
    require(!moving.matches(point, {}, 0, 0, {0, 0, 2, 0}) &&
                !moving.matches(three, {1.01, 0, 0, 1}, 0, 0, {0, 0, 2, 0}) &&
                !moving.matches(three, {}, 0.5, 0, {0, 0, 2, 0}) &&
                !moving.matches(three, {}, 0, 0, {0, 0, 1, 0}) &&
                !moving.matches(three, {}, 0, 0, {0, 0, 2, 0}, true),
            "Mask identity, basis, placement, logical bounds, and flips must invalidate prepared geometry reuse.");

    const BitMask lone = BitMask::from_bytes(3, 1, {1, 0, 0});
    const AffineMask shared(lone, {}, 0.25, 0, -1, 0, {0, 0, 2, 0});
    const AffineMask target(point, {}, -1, 0, 0, 0, {0, 0, 0, 0});
    require(!pixel_collision::overlaps(shared, target),
            "The identity word path must clip source occupancy to the native logical bbox.");
    require(shared.query_bounds().empty(),
            "Identity candidate bounds must be empty when logical clipping excludes all current pixels.");
    const AffineMask negative_shared(lone, {}, -1.25, 0.75, 0, 0, {0, 0, 7, 3});
    require(same_bounds(negative_shared.query_bounds(), {-1, 0, -1, 0}) && negative_shared.sample(-1, 0),
            "Identity candidate lookup must clip a shared bbox to current occupancy at negative subpixel positions.");
    const AffineMask selected(point, {}, 0, 0, 0, 0, {0, 0, 7, 5}, true, true);
    require(same_bounds(selected.bounds(), {-7, -5, 0, 0}) && selected.sample(0, 0),
            "Shared animation bboxes may exceed the selected frame and mirror around its canvas.");
    require(selected.broad_bounds().left <= -7 && selected.broad_bounds().right >= 7 &&
                selected.broad_bounds().top <= -5 && selected.broad_bounds().bottom >= 5,
            "Broad bounds must discover changes to either explicit flip without a notification.");

    const BitMask source = BitMask::from_bytes(3, 2, {1, 0, 1, 0, 1, 0});
    const AffineMask quarter(source, {0, 1, -1, 0}, 0, 0, 0, 0, {0, 0, 2, 1});
    require(same_bounds(quarter.bounds(), {-2, 0, -1, 2}) && quarter.sample(-1, 1) &&
                !quarter.sample(-2, 0) && !quarter.sample(0, 0),
            "Quarter-turn sampling must use original pixels and the native outer bbox.");
    const BitMask solid_four = BitMask::from_bytes(4, 4, std::vector<uint8_t>(16, 1));
    const AffineMask addition_order(solid_four,
            {-4.371138828673793e-08, 1, -0.5, -2.1855694143368964e-08},
            -17, 16.25, -16, -2, {0, 0, 3, 3});
    require(same_bounds(addition_order.bounds(), {-18, 0, -17, 3}) && !addition_order.sample(-16, 0),
            "General bbox sums must round position plus the same-axis term before adding the cross-axis term.");
    const AffineMask excluded_edge(point, {}, -16, 0, 0, 0, {0, 0, 0, 0});
    require(!pixel_collision::overlaps(addition_order, excluded_edge),
            "Float bbox addition order must exclude the audited near-cardinal outer edge.");
    const double epsilon = std::ldexp(1.0, -27);
    const AffineTransform cancellation{1 + epsilon, 1, 1, 1 - epsilon};
    require(cancellation.xx * cancellation.yy - cancellation.xy * cancellation.yx == 0.0,
            "Cancellation fixture must lose its determinant under naive evaluation.");
    const AffineMask near_parallel(point, cancellation, 0, 0, 0, 0, {0, 0, 0, 0});
    require(near_parallel.sample(0, 0), "Compensated inversion must retain a valid near-parallel basis.");

    const AffineMask huge(point, {100000000, 0, 0, 100000000}, 0, 0, 0, 0, {0, 0, 0, 0});
    const AffineMask huge_probe(point, {}, 99999999, 99999999, 0, 0, {0, 0, 0, 0});
    require(huge.bounds().right == 99999999 && huge.bounds().bottom == 99999999,
            "Transform bounds must not inherit source-raster allocation limits.");
    require(pixel_collision::overlaps(huge, huge),
            "Huge overlap must short-circuit at the first occupied point without allocating a transformed bitmap.");
    // Float bbox precision can make a one-pixel probe empty at this magnitude.
    require(!pixel_collision::overlaps(huge, huge_probe),
            "Native float bounds must remain authoritative at large coordinates.");
    const AffineMask wide(point, {100000, 0, 0, 100000}, 0, 0, 0, 0, {0, 0, 0, 0});
    const AffineMask wide_probe(point, {}, 99999, 99999, 0, 0, {0, 0, 0, 0});
    require(pixel_collision::overlaps(wide, wide_probe),
            "A small query against a huge transformed source samples only their overlap.");
    const AffineMask empty_view;
    require(empty_view.empty() && !empty_view.sample(0, 0) && !pixel_collision::overlaps(empty_view, wide),
            "Default views must be harmless empty values.");
    require_throws([&] { AffineMask(point, {0, 0, 0, 1}, 0, 0, 0, 0, {0, 0, 0, 0}); },
                   "Zero affine columns must be rejected.");
    require_throws([&] { AffineMask(point, {1, 2, 2, 4}, 0, 0, 0, 0, {0, 0, 0, 0}); },
                   "Parallel affine columns must be rejected.");
    require_throws([&] { AffineMask(point, {std::numeric_limits<double>::infinity(), 0, 0, 1},
                                  0, 0, 0, 0, {0, 0, 0, 0}); }, "Nonfinite bases must be rejected.");
    require_throws([&] { AffineMask(point, {}, 0, 0, std::numeric_limits<double>::quiet_NaN(),
                                  0, {0, 0, 0, 0}); }, "Nonfinite offsets must be rejected.");
    require_throws([&] { AffineMask(point, {1e308, 0, 0, 1e308}, 0, 0, 0, 0, {0, 0, 0, 0}); },
                   "Unrepresentable transformed bounds must be rejected before integer conversion.");
    require_throws([&] { AffineMask(point, {}, AffineMask::coordinate_limit * 2, 0, 0, 0,
                                  {0, 0, 0, 0}); }, "Out-of-range coordinates must be rejected.");
}

void test_affine_oracles() {
    std::mt19937_64 rng(0x4f4e44454d414e44ULL);
    for (int iteration = 0; iteration < 3500; ++iteration) {
        const int width = static_cast<int>(rng() % 8) + 1;
        const int height = static_cast<int>(rng() % 6) + 1;
        const Raster raster = random_raster(rng, width, height);
        const BitMask mask = raster.mask();
        AffineTransform basis;
        if (iteration < 500) {
            basis = {};
        } else if (iteration < 1000) {
            double sx = (static_cast<int>(rng() % 8) + 1) * 0.5;
            if (rng() % 2) { sx = -sx; }
            double sy = (static_cast<int>(rng() % 8) + 1) * 0.5;
            if (rng() % 2) { sy = -sy; }
            basis = {sx, 0, 0, sy};
        } else if (iteration < 3000) {
            do {
                basis = {(static_cast<int>(rng() % 25) - 12) * 0.25,
                         (static_cast<int>(rng() % 25) - 12) * 0.25,
                         (static_cast<int>(rng() % 25) - 12) * 0.25,
                         (static_cast<int>(rng() % 25) - 12) * 0.25};
            } while (basis.xx * basis.yy == basis.xy * basis.yx);
        } else {
            const double angle = (rng() % 1000000 + 0.25) * 0.000006283185307179586;
            const double sx = (rng() % 3000 + 1) / 1000.0;
            const double sy = (rng() % 3000 + 1) / 1000.0;
            basis = {std::cos(angle) * sx, std::sin(angle) * sx,
                     -std::sin(angle) * sy, std::cos(angle) * sy};
            if (rng() % 2) { basis.xx = -basis.xx; basis.xy = -basis.xy; }
        }
        const double node_x = (static_cast<int>(rng() % 81) - 40) * 0.25;
        const double node_y = (static_cast<int>(rng() % 81) - 40) * 0.25;
        const double local_x = (static_cast<int>(rng() % 25) - 12) * 0.25;
        const double local_y = (static_cast<int>(rng() % 25) - 12) * 0.25;
        const int extra_width = static_cast<int>(rng() % 4);
        const int extra_height = static_cast<int>(rng() % 4);
        const Bounds logical{0, 0, width - 1 + extra_width, height - 1 + extra_height};
        const bool flip_h = rng() % 2 != 0;
        const bool flip_v = rng() % 2 != 0;
        ViewOracle oracle{raster, basis, node_x, node_y, local_x, local_y, logical, flip_h, flip_v};
        AffineMask view(mask, basis, node_x, node_y, local_x, local_y, logical, flip_h, flip_v);
        const Bounds box = oracle.bounds();
        const Bounds query_box = view.query_bounds();
        require(same_bounds(view.bounds(), box), "Prepared bounds differ from independent forward corner evaluation.");
        require(query_box.empty() || (query_box.left >= box.left && query_box.top >= box.top &&
                    query_box.right <= box.right && query_box.bottom <= box.bottom),
                "Candidate bounds must remain inside the authoritative logical bbox.");
        for (int64_t y = box.top - 1; y <= box.bottom + 1; ++y) {
            for (int64_t x = box.left - 1; x <= box.right + 1; ++x) {
                const bool occupied = oracle.sample(x, y);
                require(view.sample(x, y) == occupied,
                        "On-demand source sampling differs from the independent float/truncation oracle.");
                if (occupied) {
                    require(!query_box.empty() && query_box.left <= x && query_box.top <= y &&
                                query_box.right >= x && query_box.bottom >= y,
                            "Every occupied oracle sample must lie inside conservative candidate bounds.");
                }
            }
        }
        for (int flips = 0; flips < 4; ++flips) {
            oracle.flip_h = (flips & 1) != 0;
            oracle.flip_v = (flips & 2) != 0;
            const Bounds flipped = oracle.bounds();
            const Bounds broad = view.broad_bounds();
            require(flipped.empty() || (!broad.empty() && broad.left <= flipped.left && broad.top <= flipped.top &&
                        broad.right >= flipped.right && broad.bottom >= flipped.bottom),
                    "Broadphase bounds must contain every explicit-flip state.");
        }
        AffineMask repositioned = view;
        repositioned.set_position(node_x + 0.25, node_y - 0.75);
        const AffineMask rebuilt(mask, basis, node_x + 0.25, node_y - 0.75, local_x, local_y,
                                  logical, flip_h, flip_v);
        require(same_bounds(repositioned.bounds(), rebuilt.bounds()) &&
                    same_bounds(repositioned.broad_bounds(), rebuilt.broad_bounds()),
                "Repositioning a prepared view must match rebuilding all validated bounds.");
        require(repositioned.matches(mask, basis, local_x, local_y, logical, flip_h, flip_v),
                "Position changes must retain the same prepared geometry identity.");
        const Bounds repositioned_box = repositioned.bounds();
        repositioned.set_position(node_x + 0.25, node_y - 0.75);
        require(same_bounds(repositioned.bounds(), repositioned_box),
                "Repeating an already validated position must preserve its exact bounds.");

        const Raster other = random_raster(rng, width + 2, height + 2);
        const BitMask other_mask = other.mask();
        const double other_x = node_x + static_cast<int>(rng() % 7) - 3;
        const double other_y = node_y + static_cast<int>(rng() % 7) - 3;
        const AffineTransform other_basis = iteration % 2 == 0 ? AffineTransform{} : basis;
        const Bounds other_logical{0, 0, other.width - 1, other.height - 1};
        const ViewOracle other_oracle{other, other_basis, other_x, other_y, 0, 0, other_logical};
        const AffineMask other_view(other_mask, other_basis, other_x, other_y, 0, 0, other_logical);
        oracle.flip_h = flip_h;
        oracle.flip_v = flip_v;
        bool expected = false;
        for (int64_t y = box.top; y <= box.bottom && !expected; ++y) {
            for (int64_t x = box.left; x <= box.right; ++x) {
                if (oracle.sample(x, y) && other_oracle.sample(x, y)) { expected = true; break; }
            }
        }
        require(pixel_collision::overlaps(view, other_view) == expected,
                "Prepared overlap differs from independent byte sampling.");
        require(pixel_collision::overlaps(other_view, view) == expected,
                "Prepared overlap must remain symmetric.");
    }

    const int widths[] = {63, 64, 65, 129};
    for (int iteration = 0; iteration < 1500; ++iteration) {
        const int width = widths[rng() % 4];
        const Raster first = random_raster(rng, width, 3);
        const Raster second = random_raster(rng, width, 3);
        const BitMask first_mask = first.mask();
        const BitMask second_mask = second.mask();
        const double ax = (static_cast<int>(rng() % 33) - 16) * 0.25;
        const double ay = (static_cast<int>(rng() % 17) - 8) * 0.25;
        const double bx = ax + static_cast<int>(rng() % 137) - 68;
        const double by = ay + static_cast<int>(rng() % 5) - 2;
        const double offset = static_cast<int>(rng() % 13) - 6;
        const int inset = static_cast<int>(rng() % 5);
        const Bounds logical{inset, 0, width - 1 - inset, 2};
        const ViewOracle a{first, {}, ax, ay, offset, 0, logical};
        const ViewOracle b{second, {}, bx, by, -offset, 0, logical};
        const AffineMask av(first_mask, {}, ax, ay, offset, 0, logical);
        const AffineMask bv(second_mask, {}, bx, by, -offset, 0, logical);
        const Bounds box = a.bounds();
        bool expected = false;
        for (int64_t y = box.top; y <= box.bottom && !expected; ++y) {
            for (int64_t x = box.left; x <= box.right; ++x) {
                if (a.sample(x, y) && b.sample(x, y)) { expected = true; break; }
            }
        }
        require(pixel_collision::overlaps(av, bv) == expected,
                "BBox-clipped identity word overlap must match the oracle across 64-bit boundaries.");
        require(pixel_collision::overlaps(bv, av) == expected,
                "BBox-clipped identity word overlap must remain symmetric across 64-bit boundaries.");
    }
}

bool bounds_overlap_oracle(const Bounds &a, const Bounds &b) {
    if (a.right < a.left || a.bottom < a.top || b.right < b.left || b.bottom < b.top) { return false; }
    if (a.right < b.left || b.right < a.left) { return false; }
    if (a.bottom < b.top || b.bottom < a.top) { return false; }
    return true;
}

void compare_query(const SpatialHash &hash, const std::unordered_map<uint64_t, Bounds> &oracle,
                   Bounds query) {
    std::vector<uint64_t> expected;
    for (const auto &entry : oracle) {
        if (bounds_overlap_oracle(entry.second, query)) { expected.push_back(entry.first); }
    }
    auto actual = hash.query(query);
    std::sort(actual.begin(), actual.end());
    std::sort(expected.begin(), expected.end());
    require(actual == expected, "Spatial query differs from an independent full scan or contains duplicates.");
    require(hash.size() == oracle.size(), "Spatial hash entry count differs from the oracle.");
}

void test_spatial_movement() {
    SpatialHash hash(32, 8);
    std::unordered_map<uint64_t, Bounds> oracle;
    const auto move = [&](uint64_t id, Bounds bounds) {
        hash.update(id, bounds);
        oracle[id] = bounds;
    };
    // Repeated registration and subcell movement must preserve identity and exact bounds.
    for (int64_t x = -30; x <= -4; ++x) {
        const Bounds current{x, -20, x + 2, -18};
        move(7, current);
        move(7, current);
        move(7, current);
        compare_query(hash, oracle, {x, -20, x, -20});
        compare_query(hash, oracle, {x - 1, -20, x - 1, -20});
        compare_query(hash, oracle, {x + 3, -20, x + 3, -20});
        compare_query(hash, oracle, {-100, -100, 100, 100});
    }
    // Move a multicell object without crossing its outer grid boundaries.
    for (int64_t inset = 0; inset <= 10; ++inset) {
        move(9, {inset, inset, 63 - inset, 63 - inset});
        compare_query(hash, oracle, {inset, inset, inset, inset});
        compare_query(hash, oracle, {inset - 1, inset - 1, inset - 1, inset - 1});
        compare_query(hash, oracle, {-100, -100, 100, 100});
    }
    // Oversized movement and transitions into and out of normal buckets must remain exact.
    for (Bounds bounds : {Bounds{-2048, -2048, 2048, 2048}, Bounds{4096, 4096, 8192, 8192},
                          Bounds{-25, -25, -23, -23}, Bounds{-8192, -8192, -4096, -4096}}) {
        move(11, bounds);
        compare_query(hash, oracle, {-25, -25, -23, -23});
        compare_query(hash, oracle, {4096, 4096, 4096, 4096});
        compare_query(hash, oracle, {-4096, -4096, -4096, -4096});
        compare_query(hash, oracle, {-10000, -10000, 10000, 10000});
    }
    require(hash.remove(11), "A moved oversized entry must be removable.");
    oracle.erase(11);
    compare_query(hash, oracle, {-10000, -10000, 10000, 10000});
}

void test_spatial_hash() {
    SpatialHash hash(32, 32);
    std::unordered_map<uint64_t, Bounds> oracle;
    const auto insert = [&](uint64_t id, Bounds bounds) {
        hash.update(id, bounds);
        if (bounds.empty()) { oracle.erase(id); } else { oracle[id] = bounds; }
    };
    insert(0, {-32, -32, -1, -1});
    insert(1, {0, 0, 31, 31});
    insert(2, {32, 32, 64, 64});
    insert(3, {-1, -1, 32, 32});
    insert(4, {-1000000, -1000000, 1000000, 1000000});
    const int64_t minimum = std::numeric_limits<int64_t>::min();
    const int64_t maximum = std::numeric_limits<int64_t>::max();
    insert(5, {minimum, minimum, maximum, maximum});
    insert(6, {minimum, minimum, minimum, minimum});
    insert(7, {maximum, maximum, maximum, maximum});
    insert(std::numeric_limits<uint64_t>::max(), {33, 33, 34, 34});
    for (Bounds query : {Bounds{-1, -1, 0, 0}, Bounds{-32, -32, -32, -32},
                         Bounds{32, 32, 32, 32}, Bounds{minimum, minimum, maximum, maximum},
                         Bounds{minimum, minimum, minimum, minimum},
                         Bounds{maximum, maximum, maximum, maximum}, Bounds{}}) {
        compare_query(hash, oracle, query);
    }
    hash.set_cell_size(1);
    compare_query(hash, oracle, {maximum, maximum, maximum, maximum});
    compare_query(hash, oracle, {minimum, minimum, minimum, minimum});
    hash.set_cell_size(maximum);
    compare_query(hash, oracle, {-1, -1, 0, 0});
    hash.set_cell_size(17);
    for (uint64_t id = 0; id < 8; ++id) {
        require(hash.remove(id), "Existing entries must be removable.");
        oracle.erase(id);
        compare_query(hash, oracle, {minimum, minimum, maximum, maximum});
    }
    require(!hash.remove(12345), "Removing a missing entry must return false.");
    insert(std::numeric_limits<uint64_t>::max(), {});
    compare_query(hash, oracle, {minimum, minimum, maximum, maximum});

    std::mt19937_64 rng(0x475249444f524143ULL);
    for (int iteration = 0; iteration < 12000; ++iteration) {
        const uint64_t id = rng() % 300;
        if (rng() % 5 == 0) {
            const bool expected = oracle.erase(id) != 0;
            require(hash.remove(id) == expected, "Dynamic removal result differs from the oracle.");
        } else {
            const int64_t x = static_cast<int64_t>(rng() % 2049) - 1024;
            const int64_t y = static_cast<int64_t>(rng() % 2049) - 1024;
            const int64_t width = rng() % 9 == 0 ? 200000 : static_cast<int64_t>(rng() % 100);
            const int64_t height = rng() % 9 == 0 ? 200000 : static_cast<int64_t>(rng() % 100);
            insert(id, {x, y, x + width - 1, y + height - 1});
        }
        const int64_t qx = static_cast<int64_t>(rng() % 2049) - 1024;
        const int64_t qy = static_cast<int64_t>(rng() % 2049) - 1024;
        compare_query(hash, oracle, {qx, qy, qx + static_cast<int64_t>(rng() % 150),
                                     qy + static_cast<int64_t>(rng() % 150)});
        if (iteration % 500 == 0) {
            hash.set_cell_size(static_cast<int64_t>(rng() % 65 + 1));
            compare_query(hash, oracle, {minimum, minimum, maximum, maximum});
        }
    }
    require_throws([&] { hash.set_cell_size(0); }, "Zero cell sizes must be rejected.");
    require_throws([] { SpatialHash invalid(-1); }, "Negative cell sizes must be rejected.");
    require_throws([] { SpatialHash invalid(32, 0); }, "Zero cell budgets must be rejected.");
    require_throws([] { SpatialHash invalid(32, 1024 * 1024 + 1); }, "Excessive cell budgets must be rejected.");
    hash.clear();
    oracle.clear();
    compare_query(hash, oracle, {minimum, minimum, maximum, maximum});
}

} // namespace

int main() {
    try {
        test_mask_fixtures();
        test_mask_oracles();
        test_affine_fixtures();
        test_affine_oracles();
        test_spatial_movement();
        test_spatial_hash();
        std::cout << "Core correctness tests passed: " << check_count << " checks.\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "Core correctness test failed after " << check_count << " checks: " << error.what() << '\n';
        return 1;
    }
}
