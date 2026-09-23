#pragma once

#include "native_effective_voxel_block.hpp"
#include "native_terrain_shaping_registry.hpp"

namespace voxel::world_backend {

// The caller must capture `deltas` once and all shaping pins from one registry
// generation. This pure-core admission verifies that supplied provenance, but
// cannot itself make two independently supplied authorities atomic.
NativeEffectiveVoxelBlock encode_native_multi_page_voxel_block(
    const WorldSourceDefinition &definition,
    const WorldDeltaPinnedSnapshot &deltas,
    const std::vector<NativeTerrainShapingPagePin> &shaping_pages,
    const NativeEffectiveVoxelBlockRequest &request,
    const std::function<bool()> &should_cancel = {});

} // namespace voxel::world_backend
