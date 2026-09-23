#pragma once

#include "native_biome_environment_catalog.hpp"
#include "native_effective_terrain_source.hpp"
#include "native_feature_delta.hpp"
#include "native_forage_stream.hpp"
#include "native_ore_cluster_stream.hpp"
#include "native_structure_exclusion_snapshot.hpp"
#include "native_surface_prop_classifier.hpp"
#include "native_surface_prop_source_decision_resolver.hpp"
#include "native_surface_prop_rng_trace.hpp"
#include "native_wildlife_stream.hpp"

#include <array>
#include <optional>
#include <stdexcept>
#include <vector>

namespace voxel::world_backend {

class NativeSurfacePropSourceOrderedStreamRejected final : public std::invalid_argument {
public:
    NativeSurfacePropSourceOrderedStreamRejected();
};

// Pure source-order policy helpers used by the stream and its contract tests.
NativeWildlifeBiomeGroup native_surface_prop_wildlife_group(const std::string &biome) noexcept;
std::size_t native_surface_prop_compatibility_draw_count(NativeSurfacePropClassificationOutcome outcome);

// A source-order RNG and decision witness, not a placement/publication manifest.
// In particular, a tree's shared-PCG compatibility draws do not yet describe
// its complete native visual grammar or collision publication.
struct NativeSurfacePropOrderedAttempt final {
    NativeSurfacePropAttempt attempt;
    bool parent_tombstoned = false;
    std::optional<NativeSurfacePropResolvedDecision> source;
    NativeSurfacePropClassificationOutcome outcome =
        NativeSurfacePropClassificationOutcome::skipped_before_prop_roll;
    std::uint64_t state_before_coordinates = 0U;
    std::uint64_t state_after_coordinates = 0U;
    std::uint64_t state_after_classification = 0U;
    std::uint64_t state_after_recipe = 0U;
    std::optional<float> prop_roll;
    std::optional<float> ore_roll;
    std::vector<float> compatibility_draws;
    std::optional<NativeOreClusterStream> ore_cluster;
    std::optional<NativeForageStream> forage;
    std::optional<NativeWildlifeStream> wildlife;
};

class NativeSurfacePropSourceOrderedStream final {
public:
    static NativeSurfacePropSourceOrderedStream create(
        const AdmittedTerrainSeed &seed, std::int32_t chunk_x, std::int32_t chunk_z,
        const Sha256Digest &expected_world_digest, std::uint64_t expected_world_generation,
        const NativeEffectiveTerrainSource &terrain,
        const NativeBiomeEnvironmentCatalog &catalog,
        const NativeStructureExclusionSnapshot &exclusions,
        const NativeFeatureDeltaSnapshot &removed_props,
        const NativeWildlifePresentationCatalog &wildlife_presentations);

    std::uint32_t rng_seed() const noexcept;
    std::uint64_t final_rng_state() const noexcept;
    std::int32_t chunk_x() const noexcept;
    std::int32_t chunk_z() const noexcept;
    const Sha256Digest &world_digest() const noexcept;
    std::uint64_t world_generation() const noexcept;
    const NativeSurfacePropSourceReceipt &source_receipt() const noexcept;
    const Sha256Digest &exclusion_digest() const noexcept;
    const std::array<NativeSurfacePropOrderedAttempt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
    attempts() const noexcept;

private:
    NativeSurfacePropSourceOrderedStream(std::uint32_t rng_seed, std::uint64_t final_rng_state,
        std::int32_t chunk_x, std::int32_t chunk_z, Sha256Digest world_digest,
        std::uint64_t world_generation, NativeSurfacePropSourceReceipt source_receipt,
        Sha256Digest exclusion_digest,
        std::array<NativeSurfacePropOrderedAttempt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> attempts) noexcept;

    std::uint32_t rng_seed_ = 0U;
    std::uint64_t final_rng_state_ = 0U;
    std::int32_t chunk_x_ = 0;
    std::int32_t chunk_z_ = 0;
    Sha256Digest world_digest_{};
    std::uint64_t world_generation_ = 0U;
    NativeSurfacePropSourceReceipt source_receipt_{};
    Sha256Digest exclusion_digest_{};
    std::array<NativeSurfacePropOrderedAttempt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> attempts_{};
};

} // namespace voxel::world_backend
