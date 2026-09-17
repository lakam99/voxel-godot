#include "legacy_seed_hash.hpp"

#include <stdexcept>

namespace voxel::world_backend {

bool is_unicode_scalar(const std::uint32_t code_point) noexcept {
    return code_point <= 0x10ffffU && !(code_point >= 0xd800U && code_point <= 0xdfffU);
}

std::uint32_t legacy_seed_hash(const std::vector<std::uint32_t> &code_points) {
    std::uint32_t hash = 2166136261U;
    for (const std::uint32_t code_point : code_points) {
        if (!is_unicode_scalar(code_point)) {
            throw std::invalid_argument("seed contains an invalid Unicode scalar value");
        }
        hash ^= code_point;
        hash *= 16777619U;
    }
    return hash;
}

} // namespace voxel::world_backend
