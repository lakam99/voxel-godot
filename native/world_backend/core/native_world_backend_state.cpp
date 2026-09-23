#include "native_world_backend_state.hpp"
#include "native_terrain_shaping_registry.hpp"

namespace voxel::world_backend {

namespace {
const char *rejection_message(const NativeWorldBackendRejectReason reason) noexcept {
    if (reason == NativeWorldBackendRejectReason::source_identity_mismatch)
        return "native world backend source identity mismatch";
    if (reason == NativeWorldBackendRejectReason::shaping_pin_not_ready)
        return "native world backend shaping pin is not ready";
    if (reason == NativeWorldBackendRejectReason::shaping_pin_source_mismatch)
        return "native world backend shaping pin source mismatch";
    return "native world backend rejected an operation";
}
}

NativeWorldBackendRejected::NativeWorldBackendRejected(const NativeWorldBackendRejectReason reason)
    : std::runtime_error(rejection_message(reason)), reason_(reason) {}

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

WorldDeltaPinnedSnapshot NativeWorldBackendState::pin_deltas() const {
    return deltas_.pin();
}

WorldSourcePin NativeWorldBackendState::pin_effective_page(
    const NativeTerrainPageKey primary_page,
    const std::vector<NativeTerrainShapingPagePin> &shaping_pages) const {
    for (const NativeTerrainShapingPagePin &shaping : shaping_pages) {
        if (shaping.readiness() != NativeTerrainShapingPageReadiness::ready) {
            throw NativeWorldBackendRejected(NativeWorldBackendRejectReason::shaping_pin_not_ready);
        }
        if (!(shaping.snapshot()->definition().physical_content_identity() == source_identity())) {
            throw NativeWorldBackendRejected(NativeWorldBackendRejectReason::shaping_pin_source_mismatch);
        }
    }
    return {definition_, deltas_.pin(), primary_page, shaping_pages};
}

NativeTerrainVolumeV2 NativeWorldBackendState::export_terrain_volume_v2() const {
    // The delta pin captures both sequencing and persistence state before the
    // value is copied, so this cannot mix terrain cells from one revision with
    // section/root metadata from another and does not require page shaping.
    return deltas_.pin().terrain_volume();
}

NativeWorldDeltasV2Payload NativeWorldBackendState::export_world_deltas_v2(
    const NativePlayerBlocksV2Catalog &catalog) const {
    // All three persisted domains are encoded from one immutable WDS pin.
    return encode_native_world_deltas_v2(deltas_.pin(), catalog);
}

WorldDeltaCommitReceipt NativeWorldBackendState::commit(const NativeWorldBackendTransaction &transaction) {
    if (!(transaction.source_identity == source_identity())) {
        throw NativeWorldBackendRejected(NativeWorldBackendRejectReason::source_identity_mismatch);
    }
    return deltas_.commit_typed_cells(transaction.deltas);
}

} // namespace voxel::world_backend
