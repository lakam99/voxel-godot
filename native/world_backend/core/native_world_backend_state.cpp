#include "native_world_backend_state.hpp"

namespace voxel::world_backend {

NativeWorldBackendRejected::NativeWorldBackendRejected(const NativeWorldBackendRejectReason reason)
    : std::runtime_error("native world backend source identity mismatch"), reason_(reason) {}

NativeWorldBackendRejectReason NativeWorldBackendRejected::reason() const noexcept {
    return reason_;
}

NativeWorldBackendState::NativeWorldBackendState(
    WorldSourceDefinition definition, const WorldDeltaStoreLimits delta_limits)
    : definition_(std::move(definition)), deltas_(delta_limits) {}

NativeWorldBackendState::NativeWorldBackendState(
    WorldSourceDefinition definition,
    NativeWorldBackendInitialSnapshot initial,
    const WorldDeltaStoreLimits delta_limits)
    : definition_(std::move(definition)),
      deltas_(delta_limits, require_initial_source(definition_, std::move(initial))) {}

WorldDeltaInitialSnapshot NativeWorldBackendState::require_initial_source(
    const WorldSourceDefinition &definition, NativeWorldBackendInitialSnapshot initial) {
    if (!(initial.source_identity == definition.physical_content_identity())) {
        throw NativeWorldBackendRejected(NativeWorldBackendRejectReason::source_identity_mismatch);
    }
    return std::move(initial.deltas);
}

const WorldSourceDefinition &NativeWorldBackendState::definition() const noexcept {
    return definition_;
}

const WorldPhysicalContentIdentity &NativeWorldBackendState::source_identity() const noexcept {
    return definition_.physical_content_identity();
}

std::uint64_t NativeWorldBackendState::terrain_delta_revision() const noexcept {
    return deltas_.revision();
}

WorldSourcePin NativeWorldBackendState::pin() const {
    return {definition_, deltas_.pin()};
}

NativeTerrainVolumeV2 NativeWorldBackendState::export_terrain_volume_v2() const {
    // `pin()` captures both sequencing and persistence state before the value
    // is copied, so this cannot mix terrain cells from one revision with
    // section/root metadata from another.
    return pin().deltas().terrain_volume();
}

WorldDeltaCommitReceipt NativeWorldBackendState::commit(const NativeWorldBackendTransaction &transaction) {
    if (!(transaction.source_identity == source_identity())) {
        throw NativeWorldBackendRejected(NativeWorldBackendRejectReason::source_identity_mismatch);
    }
    return deltas_.commit_typed_cells(transaction.deltas);
}

} // namespace voxel::world_backend
