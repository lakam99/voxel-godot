#include "native_captured_voxel_encode_job.hpp"

#include <utility>

namespace voxel::world_backend {

NativeCapturedVoxelEncodeJob::NativeCapturedVoxelEncodeJob(
    WorldSourceDefinition definition,
    WorldDeltaPinnedSnapshot deltas,
    std::vector<NativeTerrainShapingPagePin> shaping_pages,
    NativeEffectiveVoxelBlockRequest request)
    : definition_(std::move(definition)), deltas_(std::move(deltas)),
      shaping_pages_(std::move(shaping_pages)), request_(request) {}

NativeEffectiveVoxelBlock NativeCapturedVoxelEncodeJob::encode(const std::function<bool()> &should_cancel) const {
    return encode_native_multi_page_voxel_block(definition_, deltas_, shaping_pages_, request_, should_cancel);
}

} // namespace voxel::world_backend
