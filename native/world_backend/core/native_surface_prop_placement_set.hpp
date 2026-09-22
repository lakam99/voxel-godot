#pragma once

#include "native_surface_prop_baseline_stream.hpp"
#include "native_surface_prop_rng_trace.hpp"
#include "world_source.hpp"

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// This receipt carries only the authoritative surface pair needed to give a
// selected feature a physical anchor. It deliberately contains no renderer,
// collider, asset, or tombstone decision: those belong to later definition and
// publication owners.
enum class NativeSurfacePropPlacementPresence : std::uint8_t {
    absent = 1,
    anchored = 2,
};

struct NativeSurfacePropPlacementReceipt final {
    std::uint32_t ordinal = 0U;
    NativeSurfacePropPlacementPresence presence = NativeSurfacePropPlacementPresence::absent;
    CellCoord solid_cell{};
    CellCoord air_cell{};
};

struct NativeSurfacePropPlacementEntry final {
    std::uint32_t ordinal = 0U;
    std::string durable_id;
    std::int32_t cell_x = 0;
    std::int32_t cell_z = 0;
    Sha256Digest source_decision_digest{};
    NativeSurfacePropClassificationOutcome outcome = NativeSurfacePropClassificationOutcome::no_feature;
    NativeSurfacePropPlacementPresence presence = NativeSurfacePropPlacementPresence::absent;
    CellCoord solid_cell{};
    CellCoord air_cell{};
    WorldFloat32Position world_anchor{};
};

class NativeSurfacePropPlacementSetRejected final : public std::invalid_argument {
public:
    NativeSurfacePropPlacementSetRejected();
};

// Immutable, source-bound placement witness for one full surface-prop attempt
// stream. "SPP1" uses the same lattice location as the legacy source's
// chunk-local prop position after converting it into a canonical world anchor:
// (cell_x * CELL, air_cell_y * CELL, cell_z * CELL). It is neither a terrain
// sampler nor a feature footprint catalog.
class NativeSurfacePropPlacementSet final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;

    static NativeSurfacePropPlacementSet create(
        const NativeSurfacePropAttemptStream &attempts,
        const NativeSurfacePropBaselineStream &baseline,
        NativeSurfacePropSourceReceipt source_receipt,
        const WorldSourceDefinition &world_source,
        const std::array<NativeSurfacePropPlacementReceipt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &receipts);

    const NativeSurfacePropSourceReceipt &source_receipt() const noexcept;
    const WorldPhysicalContentIdentity &world_source_identity() const noexcept;
    const std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
    entries() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

private:
    NativeSurfacePropPlacementSet(
        NativeSurfacePropSourceReceipt source_receipt,
        WorldPhysicalContentIdentity world_source_identity,
        std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
        std::vector<std::uint8_t> canonical_binary, Sha256Digest content_digest) noexcept;

    NativeSurfacePropSourceReceipt source_receipt_{};
    WorldPhysicalContentIdentity world_source_identity_{};
    std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries_{};
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
