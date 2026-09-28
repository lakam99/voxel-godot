#pragma once

#include "native_world_deltas_v2_codec.hpp"
#include "world_source.hpp"

#include <cstdint>
#include <stdexcept>

namespace voxel::world_backend {

// A typed write request binds a canonical typed-cell transaction to the
// immutable physical world source it was prepared against.  Request ownership
// (cancellation, caller generation, and publication routing) is deliberately
// absent: it belongs to WorldSourceRequestScope beside a pin, not in durable
// content identity or a terrain edit.
struct NativeWorldBackendTransaction {
    WorldPhysicalContentIdentity source_identity;
    WorldTypedCellTransaction deltas;
};

// The source identity is explicit because terrainVolume does not serialize a
// seed.  This constructor-time checkpoint is therefore bound to the selected
// generated world before it becomes observable through a pin.
struct NativeWorldBackendInitialSnapshot {
    WorldPhysicalContentIdentity source_identity;
    WorldDeltaInitialSnapshot deltas;
};

enum class NativeWorldBackendRejectReason : std::uint8_t {
    source_identity_mismatch = 1,
    shaping_pin_not_ready = 2,
    shaping_pin_source_mismatch = 3,
};

class NativeWorldBackendRejected final : public std::runtime_error {
public:
    explicit NativeWorldBackendRejected(NativeWorldBackendRejectReason reason);
    NativeWorldBackendRejectReason reason() const noexcept;

private:
    NativeWorldBackendRejectReason reason_;
};

// The state owner is intentionally thread-free for this slice.  It combines
// one immutable generated-world definition with durable typed deltas, while
// leaving generation, GDScript binding, navigation, and request authority to
// their owning layers. Pins receive a copy of the immutable definition and a
// delta-store snapshot, so no later commit can alter a published pin.
class NativeWorldBackendState final {
public:
    explicit NativeWorldBackendState(
        WorldSourceDefinition definition,
        WorldDeltaStoreLimits delta_limits = {});
    NativeWorldBackendState(
        WorldSourceDefinition definition,
        NativeWorldBackendInitialSnapshot initial,
        WorldDeltaStoreLimits delta_limits = {});
    NativeWorldBackendState(const NativeWorldBackendState &) = delete;
    NativeWorldBackendState(NativeWorldBackendState &&) = delete;
    NativeWorldBackendState &operator=(const NativeWorldBackendState &) = delete;
    NativeWorldBackendState &operator=(NativeWorldBackendState &&) = delete;

    const WorldSourceDefinition &definition() const noexcept;
    const WorldPhysicalContentIdentity &source_identity() const noexcept;
    std::uint64_t terrain_delta_revision() const noexcept;
    const Sha256Digest &terrain_delta_content_digest() const noexcept;
    BorrowedTypedProjectionCursor::Step advance_borrowed_typed_projection(
        BorrowedTypedProjectionCursor &cursor, WorldDeltaHorizontalBounds bounds,
        std::uint64_t source_token, std::uint32_t offered_ops) const noexcept;
    BorrowedTypedCellCursor::Step advance_borrowed_typed_cell(
        BorrowedTypedCellCursor &cursor, CellCoord cell,
        std::uint64_t source_token, std::uint32_t offered_ops) const noexcept;
    std::optional<BorrowedTypedCellHeader> borrowed_typed_cell_header(
        const BorrowedTypedCellCursor &cursor, std::uint64_t source_token) const noexcept;
    bool bind_source_mutation_fence(WorldSourceMutationFence *fence) noexcept;
    // One immutable snapshot for a composite multi-page admission. Callers
    // must serialize this with registry/town-owner mutation and recheck before
    // publication; this accessor is not a cross-authority transaction.
    WorldDeltaPinnedSnapshot pin_deltas() const;
    WorldSourcePin pin_effective_page(
        NativeTerrainPageKey primary_page,
        const std::vector<NativeTerrainShapingPagePin> &shaping_pages) const;
    // Save export is intentionally independent from production page shaping.
    // It captures one immutable delta pin and exports only its terrain value.
    NativeTerrainVolumeV2 export_terrain_volume_v2() const;
    NativeWorldDeltasV2Payload export_world_deltas_v2(
        const NativePlayerBlocksV2Catalog &catalog) const;
    WorldDeltaCommitReceipt commit(const NativeWorldBackendTransaction &transaction);

private:
    static WorldDeltaInitialSnapshot require_initial_source(
        const WorldSourceDefinition &definition, NativeWorldBackendInitialSnapshot initial);
    WorldSourceDefinition definition_;
    WorldDeltaStore deltas_;
};

} // namespace voxel::world_backend
