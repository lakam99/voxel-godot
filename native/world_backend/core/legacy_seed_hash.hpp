#pragma once

#include <cstdint>
#include <vector>

namespace voxel::world_backend {

bool is_unicode_scalar(std::uint32_t code_point) noexcept;
std::uint32_t legacy_seed_hash(const std::vector<std::uint32_t> &code_points);

} // namespace voxel::world_backend
