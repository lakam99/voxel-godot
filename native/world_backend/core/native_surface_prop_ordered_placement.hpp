#pragma once

#include "native_surface_prop_placement_set.hpp"
#include "native_surface_prop_source_ordered_stream.hpp"

namespace voxel::world_backend {

class NativeSurfacePropOrderedPlacementRejected final : public std::invalid_argument {
public:
    NativeSurfacePropOrderedPlacementRejected();
};

// Production placement policy for the classifier's complete outcome enum.
// Invalid values reject instead of silently creating a physical blocker.
bool native_surface_prop_outcome_has_placement(NativeSurfacePropClassificationOutcome outcome);

// Floor-divides a signed cell coordinate without overflowing at INT_MIN.
std::int32_t native_surface_prop_ordered_chunk_for_cell(std::int32_t cell) noexcept;

// Validates one captured attempt against its immutable source pin and yields
// its placement facts. Exposed for focused contract tests; create uses it.
NativeSurfacePropPlacementEntry resolve_native_surface_prop_ordered_placement_entry(
    const NativeSurfacePropOrderedAttempt &source, std::uint32_t expected_ordinal,
    std::int32_t expected_chunk_x, std::int32_t expected_chunk_z,
    const WorldSourcePin &pin, std::optional<std::uint64_t> previous_rng_state);

// SPO1 consumes the completed source-order witness. It never samples terrain
// or advances RNG, and is separate from the precomputed-attempt SPP4 shadow.
class NativeSurfacePropOrderedPlacement final {
public:
    static constexpr std::uint32_t SCHEMA_REVISION = 1U;

    static NativeSurfacePropOrderedPlacement create(
        const NativeSurfacePropSourceOrderedStream &ordered,
        const NativeEffectiveTerrainSource &terrain);

    const WorldPhysicalContentIdentity &world_source_identity() const noexcept;
    const WorldPhysicalContentIdentity &definition_source_identity() const noexcept;
    std::uint64_t terrain_delta_revision() const noexcept;
    std::uint64_t shaping_registry_revision() const noexcept;
    std::uint64_t final_rng_state() const noexcept;
    const std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
    entries() const noexcept;
    const std::vector<std::uint8_t> &canonical_binary() const noexcept;
    const Sha256Digest &content_digest() const noexcept;

private:
    WorldPhysicalContentIdentity world_source_identity_{};
    WorldPhysicalContentIdentity definition_source_identity_{};
    std::uint64_t terrain_delta_revision_ = 0U;
    std::uint64_t shaping_registry_revision_ = 0U;
    std::uint64_t final_rng_state_ = 0U;
    std::array<NativeSurfacePropPlacementEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries_{};
    std::vector<std::uint8_t> canonical_binary_;
    Sha256Digest content_digest_{};
};

} // namespace voxel::world_backend
