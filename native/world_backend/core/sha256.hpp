#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace voxel::world_backend {

using Sha256Digest = std::array<std::uint8_t, 32>;

Sha256Digest sha256(const std::uint8_t *data, std::size_t size);
Sha256Digest sha256(const std::vector<std::uint8_t> &bytes);
std::string sha256_hex(const Sha256Digest &digest);

} // namespace voxel::world_backend
