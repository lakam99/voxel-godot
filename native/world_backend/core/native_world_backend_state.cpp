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

WorldDeltaCommitReceipt NativeWorldBackendState::commit(const NativeWorldBackendTransaction &transaction) {
    if (!(transaction.source_identity == source_identity())) {
        throw NativeWorldBackendRejected(NativeWorldBackendRejectReason::source_identity_mismatch);
    }
    return deltas_.commit(transaction.deltas);
}

} // namespace voxel::world_backend
