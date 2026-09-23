#pragma once

#include "native_multi_page_voxel_block.hpp"

namespace voxel::world_backend {

// A complete, immutable worker input. Capture on the authority thread, then
// move the job to a worker; encode reads only these owned values.
class NativeCapturedVoxelEncodeJob final {
public:
    NativeCapturedVoxelEncodeJob(
        WorldSourceDefinition definition,
        WorldDeltaPinnedSnapshot deltas,
        std::vector<NativeTerrainShapingPagePin> shaping_pages,
        NativeEffectiveVoxelBlockRequest request);

    NativeEffectiveVoxelBlock encode() const;

private:
    const WorldSourceDefinition definition_;
    const WorldDeltaPinnedSnapshot deltas_;
    const std::vector<NativeTerrainShapingPagePin> shaping_pages_;
    const NativeEffectiveVoxelBlockRequest request_;
};

} // namespace voxel::world_backend
