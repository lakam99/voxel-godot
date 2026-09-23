#pragma once

#include "native_surface_prop_ordered_placement.hpp"

#include <vector>

namespace voxel::world_backend {

struct NativeSurfacePropChunkAttemptSnapshot final {
    std::uint32_t ordinal = 0U;
    std::string durable_id;
    NativeSurfacePropClassificationOutcome outcome = NativeSurfacePropClassificationOutcome::skipped_before_prop_roll;
    bool parent_tombstoned = false;
    NativeSurfacePropPlacementPresence presence = NativeSurfacePropPlacementPresence::absent;
    WorldFloat32Position world_anchor{};
    Sha256Digest source_decision_digest{};
    Sha256Digest source_attempt_digest{};
    std::uint64_t state_before_coordinates = 0U;
    std::uint64_t state_after_coordinates = 0U;
    std::uint64_t state_after_classification = 0U;
    std::uint64_t state_after_recipe = 0U;
};

struct NativeSurfacePropOrdinalDifference final {
    std::uint32_t ordinal = 0U;
    NativeSurfacePropChunkAttemptSnapshot before;
    NativeSurfacePropChunkAttemptSnapshot after;
};

class NativeSurfacePropChunkDifferenceRejected final : public std::invalid_argument {
public:
    NativeSurfacePropChunkDifferenceRejected();
};

bool native_surface_prop_source_receipts_match(
    const NativeSurfacePropSourceReceipt &a, const NativeSurfacePropSourceReceipt &b) noexcept;

Sha256Digest native_surface_prop_ordered_attempt_digest(const NativeSurfacePropOrderedAttempt &attempt);

// Pure shadow witness of the changed source-order suffix. It is not a
// footprint catalog or a WorldDeltaStore admission.
class NativeSurfacePropChunkDifference final {
public:
    static NativeSurfacePropChunkDifference create(
        const NativeSurfacePropSourceOrderedStream &before,
        const NativeSurfacePropOrderedPlacement &before_placements,
        const NativeSurfacePropSourceOrderedStream &after,
        const NativeSurfacePropOrderedPlacement &after_placements,
        const NativeEffectiveTerrainSource &terrain);

    static constexpr bool CHANNEL_FOOTPRINTS_COMPLETE = false;
    bool channel_footprints_complete() const noexcept;
    std::int32_t chunk_x() const noexcept;
    std::int32_t chunk_z() const noexcept;
    const Sha256Digest &world_digest() const noexcept;
    std::uint64_t world_generation() const noexcept;
    const WorldPhysicalContentIdentity &world_source_identity() const noexcept;
    const Sha256Digest &content_digest() const noexcept;
    std::uint64_t before_final_rng_state() const noexcept;
    std::uint64_t after_final_rng_state() const noexcept;
    const std::vector<NativeSurfacePropOrdinalDifference> &changed_ordinals() const noexcept;

private:
    Sha256Digest world_digest_{};
    std::uint64_t world_generation_ = 0U;
    WorldPhysicalContentIdentity world_source_identity_{};
    Sha256Digest content_digest_{};
    std::int32_t chunk_x_ = 0;
    std::int32_t chunk_z_ = 0;
    std::uint64_t before_final_rng_state_ = 0U;
    std::uint64_t after_final_rng_state_ = 0U;
    std::vector<NativeSurfacePropOrdinalDifference> changed_ordinals_;
};

} // namespace voxel::world_backend
