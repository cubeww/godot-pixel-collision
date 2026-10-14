#include "spatial_hash.h"

#include <algorithm>
#include <stdexcept>
#include <unordered_set>
#include <utility>

namespace pixel_collision {
namespace {

uint64_t mix_bits(uint64_t value) noexcept {
    value ^= value >> 30;
    value *= 0xbf58476d1ce4e5b9ULL;
    value ^= value >> 27;
    value *= 0x94d049bb133111ebULL;
    return value ^ (value >> 31);
}

void erase_id(std::vector<uint64_t> &ids, uint64_t id) {
    const auto found = std::find(ids.begin(), ids.end(), id);
    if (found != ids.end()) {
        *found = ids.back();
        ids.pop_back();
    }
}

} // namespace

SpatialHash::SpatialHash(int64_t cell_size, size_t max_cells_per_entry)
    : cell_size_(cell_size), max_cells_per_entry_(max_cells_per_entry) {
    if (cell_size <= 0) {
        throw std::invalid_argument("Spatial hash cell size must be positive.");
    }
    if (max_cells_per_entry == 0 || max_cells_per_entry > 1024 * 1024) {
        throw std::invalid_argument("Spatial hash cell budget must be between 1 and 1048576.");
    }
}

size_t SpatialHash::CellHash::operator()(const Cell &cell) const noexcept {
    return static_cast<size_t>(mix_bits(static_cast<uint64_t>(cell.x)) ^
                               mix_bits(static_cast<uint64_t>(cell.y) + 0x9e3779b97f4a7c15ULL));
}

int64_t SpatialHash::cell_coordinate(int64_t pixel) const noexcept {
    const int64_t quotient = pixel / cell_size_;
    return pixel % cell_size_ < 0 ? quotient - 1 : quotient;
}

bool SpatialHash::covered_cells(Bounds bounds, std::vector<Cell> &result) const {
    result.clear();
    if (bounds.empty()) { return true; }
    const int64_t left = cell_coordinate(bounds.left);
    const int64_t right = cell_coordinate(bounds.right);
    const int64_t top = cell_coordinate(bounds.top);
    const int64_t bottom = cell_coordinate(bounds.bottom);
    // Unsigned differences avoid signed overflow even across the entire int64 range.
    const uint64_t dx = static_cast<uint64_t>(right) - static_cast<uint64_t>(left);
    const uint64_t dy = static_cast<uint64_t>(bottom) - static_cast<uint64_t>(top);
    if (dx >= max_cells_per_entry_ || dy >= max_cells_per_entry_) { return false; }
    const uint64_t nx = dx + 1;
    const uint64_t ny = dy + 1;
    if (nx > max_cells_per_entry_ / ny) { return false; }
    result.reserve(static_cast<size_t>(nx * ny));
    int64_t y = top;
    while (true) {
        int64_t x = left;
        while (true) {
            result.push_back({x, y});
            if (x == right) { break; }
            ++x;
        }
        if (y == bottom) { break; }
        ++y;
    }
    return true;
}

void SpatialHash::insert(uint64_t id, Bounds bounds) {
    if (bounds.empty()) {
        remove(id);
        return;
    }
    const auto existing = entries_.find(id);
    if (existing != entries_.end()) {
        const Bounds &previous = existing->second.bounds;
        if (previous.left == bounds.left && previous.top == bounds.top &&
            previous.right == bounds.right && previous.bottom == bounds.bottom) {
            return;
        }
        if (!existing->second.oversized) {
            const Cell &first = existing->second.cells.front();
            const Cell &last = existing->second.cells.back();
            if (cell_coordinate(bounds.left) == first.x && cell_coordinate(bounds.top) == first.y &&
                cell_coordinate(bounds.right) == last.x && cell_coordinate(bounds.bottom) == last.y) {
                // Movement inside the same cell rectangle only changes the narrow bounds.
                existing->second.bounds = bounds;
                return;
            }
        }
    }
    Entry entry;
    entry.bounds = bounds;
    entry.oversized = !covered_cells(bounds, entry.cells);
    if (existing != entries_.end() && existing->second.oversized && entry.oversized) {
        existing->second.bounds = bounds;
        return;
    }
    remove(id);
    if (entry.oversized) {
        oversized_.push_back(id);
    } else {
        for (const Cell &cell : entry.cells) { cells_[cell].push_back(id); }
    }
    entries_.emplace(id, std::move(entry));
}

bool SpatialHash::remove(uint64_t id) {
    const auto entry = entries_.find(id);
    if (entry == entries_.end()) { return false; }
    if (entry->second.oversized) {
        erase_id(oversized_, id);
    } else {
        for (const Cell &cell : entry->second.cells) {
            const auto bucket = cells_.find(cell);
            if (bucket == cells_.end()) { continue; }
            erase_id(bucket->second, id);
            if (bucket->second.empty()) { cells_.erase(bucket); }
        }
    }
    entries_.erase(entry);
    return true;
}

std::vector<uint64_t> SpatialHash::query(Bounds bounds) const {
    std::vector<uint64_t> result;
    if (bounds.empty()) { return result; }
    const Cell first{cell_coordinate(bounds.left), cell_coordinate(bounds.top)};
    const Cell last{cell_coordinate(bounds.right), cell_coordinate(bounds.bottom)};
    if (first == last) {
        // A single bucket contains unique IDs, and oversized entries never live in buckets.
        // Small particle queries therefore need neither a cell vector nor a deduplication set.
        const auto append_if_intersecting = [&](uint64_t id) {
            const auto entry = entries_.find(id);
            if (entry != entries_.end() && entry->second.bounds.intersects(bounds)) {
                result.push_back(id);
            }
        };
        const auto bucket = cells_.find(first);
        if (bucket != cells_.end()) {
            for (uint64_t id : bucket->second) { append_if_intersecting(id); }
        }
        for (uint64_t id : oversized_) { append_if_intersecting(id); }
        return result;
    }
    std::vector<Cell> visited_cells;
    if (!covered_cells(bounds, visited_cells)) {
        // A huge query is bounded by the collider count, not by its world area.
        for (const auto &entry : entries_) {
            if (entry.second.bounds.intersects(bounds)) { result.push_back(entry.first); }
        }
        return result;
    }
    std::unordered_set<uint64_t> visited;
    const auto consider = [&](uint64_t id) {
        if (!visited.insert(id).second) { return; }
        const auto entry = entries_.find(id);
        if (entry != entries_.end() && entry->second.bounds.intersects(bounds)) {
            result.push_back(id);
        }
    };
    for (const Cell &cell : visited_cells) {
        const auto bucket = cells_.find(cell);
        if (bucket == cells_.end()) { continue; }
        for (uint64_t id : bucket->second) { consider(id); }
    }
    for (uint64_t id : oversized_) { consider(id); }
    return result;
}

void SpatialHash::clear() {
    entries_.clear();
    cells_.clear();
    oversized_.clear();
}

void SpatialHash::set_cell_size(int64_t cell_size) {
    if (cell_size <= 0) {
        throw std::invalid_argument("Spatial hash cell size must be positive.");
    }
    if (cell_size == cell_size_) { return; }
    SpatialHash rebuilt(cell_size, max_cells_per_entry_);
    for (const auto &entry : entries_) { rebuilt.insert(entry.first, entry.second.bounds); }
    *this = std::move(rebuilt);
}

} // namespace pixel_collision
