#pragma once

#include "native_biome_environment_catalog.hpp"
#include "native_effective_terrain_source.hpp"
#include "native_structure_exclusion_snapshot.hpp"
#include "native_surface_prop_classifier.hpp"

namespace voxel::world_backend {

class NativeSurfacePropSourceDecisionRejected final : public std::invalid_argument {
public:
    NativeSurfacePropSourceDecisionRejected();
};

struct NativeSurfacePropResolvedDecision final {
    NativeSurfacePropClassificationInput classification;
    // Present only after exclusion permits a terrain query. The producer may
    // use these exact facts for recipes and placement without resampling.
    bool has_surface = false;
    NativeSurfacePropSpawnFacts surface;
    std::string biome_id;
};

// Resolves one already-drawn attempt against immutable, admitted sources.
// Removed-root tombstones belong to the source-ordered producer before this
// call; this resolver consumes no RNG and never trusts a caller-supplied
// classification digest or placement cutoff.
class NativeSurfacePropSourceDecisionResolver final {
public:
    static const char *biome_name(TerrainBiomeId biome);
    static void require_finite_surface_height(double height_meters);
    static NativeSurfacePropResolvedDecision resolve(
        const NativeSurfacePropAttempt &attempt,
        const NativeEffectiveTerrainSource &terrain,
        const NativeBiomeEnvironmentCatalog &catalog,
        const NativeStructureExclusionSnapshot &exclusions,
        const Sha256Digest &expected_world_digest,
        std::uint64_t expected_world_generation);
};

} // namespace voxel::world_backend
