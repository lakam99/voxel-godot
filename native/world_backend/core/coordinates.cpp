#include "coordinates.hpp"

#include <limits>

namespace voxel::world_backend {

bool CellCoord::operator==(const CellCoord &other) const noexcept {
    return x == other.x && y == other.y && z == other.z;
}

bool SectionAddress::operator==(const SectionAddress &other) const noexcept {
    return section == other.section && local == other.local;
}

std::optional<std::int32_t> floor_divide(const std::int32_t value, const std::int32_t positive_divisor) noexcept {
    if (positive_divisor <= 0) {
        return std::nullopt;
    }
    const std::int32_t quotient = value / positive_divisor;
    const std::int32_t remainder = value % positive_divisor;
    return remainder < 0 ? quotient - 1 : quotient;
}

std::optional<std::int32_t> euclidean_modulo(const std::int32_t value, const std::int32_t positive_divisor) noexcept {
    if (positive_divisor <= 0) {
        return std::nullopt;
    }
    const std::int32_t remainder = value % positive_divisor;
    return remainder < 0 ? remainder + positive_divisor : remainder;
}

std::optional<std::int32_t> checked_add(const std::int32_t left, const std::int32_t right) noexcept {
    const std::int64_t value = static_cast<std::int64_t>(left) + static_cast<std::int64_t>(right);
    if (value < std::numeric_limits<std::int32_t>::min() || value > std::numeric_limits<std::int32_t>::max()) {
        return std::nullopt;
    }
    return static_cast<std::int32_t>(value);
}

std::optional<std::int32_t> checked_multiply(const std::int32_t left, const std::int32_t right) noexcept {
    const std::int64_t value = static_cast<std::int64_t>(left) * static_cast<std::int64_t>(right);
    if (value < std::numeric_limits<std::int32_t>::min() || value > std::numeric_limits<std::int32_t>::max()) {
        return std::nullopt;
    }
    return static_cast<std::int32_t>(value);
}

std::optional<SectionAddress> split_cell(const CellCoord &cell, const std::int32_t section_size) noexcept {
    // One shared divisor controls all six calculations, so validate it once
    // rather than implying that later optional results can fail independently.
    if (section_size <= 0) {
        return std::nullopt;
    }
    return SectionAddress{
        {*floor_divide(cell.x, section_size), *floor_divide(cell.y, section_size), *floor_divide(cell.z, section_size)},
        {*euclidean_modulo(cell.x, section_size), *euclidean_modulo(cell.y, section_size), *euclidean_modulo(cell.z, section_size)},
    };
}

std::optional<CellCoord> section_origin(const CellCoord &section, const std::int32_t section_size) noexcept {
    if (section_size <= 0) {
        return std::nullopt;
    }
    const auto x = checked_multiply(section.x, section_size);
    const auto y = checked_multiply(section.y, section_size);
    const auto z = checked_multiply(section.z, section_size);
    if (!x || !y || !z) {
        return std::nullopt;
    }
    return CellCoord{*x, *y, *z};
}

} // namespace voxel::world_backend
