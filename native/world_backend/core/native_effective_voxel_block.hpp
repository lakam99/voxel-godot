#pragma once

#include "native_effective_terrain_source.hpp"

#include <cstdint>
#include <vector>

namespace voxel::world_backend {

struct NativeEffectiveVoxelBlockRequest {
    CellCoord origin;
    CellCoord size;
    std::uint32_t lod = 0;
};

// Exactly one VoxelBuffer data block, in its native [z][x][y] byte layout.
// The caller must check the pin revision/identity again before publication.
struct NativeEffectiveVoxelBlock {
    CellCoord origin;
    CellCoord size;
    std::uint32_t lod = 0;
    WorldPhysicalContentIdentity pin_identity;
    std::uint64_t terrain_delta_revision = 0;
    std::uint64_t shaping_registry_revision = 0;
    std::vector<std::uint8_t> sdf16_le;
    std::vector<std::uint8_t> indices8;
    std::vector<std::uint8_t> data5_8;
};

// Matches VoxelTerrainGenerator.MATERIAL_IDS, including its lava fallback.
std::uint8_t native_voxel_material_channel_id(TerrainMaterialId material);

NativeEffectiveVoxelBlock encode_native_effective_voxel_block(
    const NativeEffectiveTerrainSource &source,
    const NativeEffectiveVoxelBlockRequest &request);

} // namespace voxel::world_backend
