#pragma once

#include "bit_mask.h"

#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace pixel_collision {

// Dynamic broadphase. Each result is unique and intersects the requested bounds;
// ordering is intentionally unspecified. Oversized entries use a separate list.
class SpatialHash {
public:
    explicit SpatialHash(int64_t cell_size = 32, size_t max_cells_per_entry = 4096);

    void insert(uint64_t id, Bounds bounds);
    void update(uint64_t id, Bounds bounds) { insert(id, bounds); }
    bool remove(uint64_t id);
    std::vector<uint64_t> query(Bounds bounds) const;
    void clear();
    void set_cell_size(int64_t cell_size);
    int64_t cell_size() const noexcept { return cell_size_; }
    size_t size() const noexcept { return entries_.size(); }

private:
    struct Cell {
        int64_t x;
        int64_t y;
        bool operator==(const Cell &other) const noexcept {
            return x == other.x && y == other.y;
        }
    };
    struct CellHash {
        size_t operator()(const Cell &cell) const noexcept;
    };
    struct Entry {
        Bounds bounds;
        std::vector<Cell> cells;
        bool oversized = false;
    };

    int64_t cell_size_;
    size_t max_cells_per_entry_;
    std::unordered_map<uint64_t, Entry> entries_;
    std::unordered_map<Cell, std::vector<uint64_t>, CellHash> cells_;
    std::vector<uint64_t> oversized_;

    int64_t cell_coordinate(int64_t pixel) const noexcept;
    bool covered_cells(Bounds bounds, std::vector<Cell> &result) const;
};

} // namespace pixel_collision
