#pragma once

#include <cstdint>
#include <optional>

namespace voxel::world_backend {

struct CellCoord {
    std::int32_t x = 0;
    std::int32_t y = 0;
    std::int32_t z = 0;

    bool operator==(const CellCoord &other) const noexcept;
};

struct SectionAddress {
    CellCoord section;
    CellCoord local;

    bool operator==(const SectionAddress &other) const noexcept;
};

std::optional<std::int32_t> floor_divide(std::int32_t value, std::int32_t positive_divisor) noexcept;
std::optional<std::int32_t> euclidean_modulo(std::int32_t value, std::int32_t positive_divisor) noexcept;
std::optional<std::int32_t> checked_add(std::int32_t left, std::int32_t right) noexcept;
std::optional<std::int32_t> checked_multiply(std::int32_t left, std::int32_t right) noexcept;
std::optional<SectionAddress> split_cell(const CellCoord &cell, std::int32_t section_size) noexcept;
std::optional<CellCoord> section_origin(const CellCoord &section, std::int32_t section_size) noexcept;

} // namespace voxel::world_backend
