#pragma once

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
    WorldSourcePin pin() const;
    // Captures one immutable pin internally and exports only its terrain
    // persistence value.  Save orchestration must not combine this with
    // records read from a later mutable state.
    NativeTerrainVolumeV2 export_terrain_volume_v2() const;
    WorldDeltaCommitReceipt commit(const NativeWorldBackendTransaction &transaction);

private:
    static WorldDeltaInitialSnapshot require_initial_source(
        const WorldSourceDefinition &definition, NativeWorldBackendInitialSnapshot initial);
    WorldSourceDefinition definition_;
    WorldDeltaStore deltas_;
};

} // namespace voxel::world_backend
