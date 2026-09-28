#pragma once

#include "native_effective_terrain_source.hpp"

#include <cstdint>
#include <functional>
#include <stdexcept>
#include <vector>

namespace voxel::world_backend {

struct NativeEffectiveVoxelBlockRequest {
    CellCoord origin;
    CellCoord size;
    std::uint32_t lod = 0;
};

class NativeVoxelEncodeCancelled final : public std::runtime_error {
public:
    NativeVoxelEncodeCancelled() : std::runtime_error("native voxel encode cancelled") {}
};

// Exactly one VoxelBuffer data block, in its native [z][x][y] byte layout.
// The caller must check the pin revision/identity again before publication.
struct NativeEffectiveVoxelBlock {
    CellCoord origin;
    CellCoord size;
    std::uint32_t lod = 0;
    WorldPhysicalContentIdentity pin_identity;
    // Conservative page-local source-content identity, separate from the
    // global revision-bearing transport/freshness pin. It may invalidate on
    // an edit elsewhere in a dependency page; it is not a byte-content hash.
    // Never use this alone to admit publication.
    WorldPhysicalContentIdentity block_content_identity;
    std::uint64_t terrain_delta_revision = 0;
    std::uint64_t shaping_registry_revision = 0;
    std::vector<std::uint8_t> sdf16_le;
    std::vector<std::uint8_t> indices8;
    std::vector<std::uint8_t> data5_8;
};

// Matches VoxelTerrainGenerator.MATERIAL_IDS, including its lava fallback.
std::uint8_t native_voxel_material_channel_id(TerrainMaterialId material);

// Call only after block bounds and ordered source-pin dependencies are
// admitted. Global delta/registry sequence numbers are deliberately absent.
WorldPhysicalContentIdentity native_voxel_block_content_identity(
    const WorldPhysicalContentIdentity &source_identity,
    const NativeEffectiveVoxelBlockRequest &request,
    const std::vector<WorldPhysicalContentIdentity> &ordered_page_identities);

NativeEffectiveVoxelBlock encode_native_effective_voxel_block(
    const NativeEffectiveTerrainSource &source,
    const NativeEffectiveVoxelBlockRequest &request,
    const std::function<bool()> &should_cancel = {});

} // namespace voxel::world_backend
