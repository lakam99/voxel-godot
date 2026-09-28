#pragma once

#include "native_surface_prop_placement_set.hpp"
#include "native_tree_definition.hpp"

#include <array>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// Exact profile facts consumed by TreeEcologySampler and
// TreeRuntimeRequestBuilder. The adapter snapshots this immutable data from
// BiomeEnvironmentProfile; it does not send a precomputed tree request back
// into core.
struct NativeSurfaceTreeEcologyProfile final {
    std::uint32_t schema_revision = 0U;
    std::uint32_t profile_revision = 0U;
    Sha256Digest source_profile_digest{};
    // source_biome is the sampled surface identity. profile_id separately
    // retains the catalog resource selected for it, including explicit default
    // fallback when that is ever needed.
    std::string source_biome;
    std::string profile_id;
    std::vector<std::string> tree_families;
    double tree_scale = 1.0;
    double height_min = 0.0;
    double height_max = 0.0;
    double trunk_radius_min = 0.0;
    double trunk_radius_max = 0.0;
    double canopy_radius_min = 0.0;
    double canopy_radius_max = 0.0;
    double canopy_density = 0.0;
    double wind_response = 1.0;
    double visibility_range = 260.0;
    double shadow_range = 180.0;
    double exclusion_margin = 0.0;
    double age_min_years = 0.0;
    double age_typical_years = 0.0;
    double age_max_years = 0.0;
    double maturity_cell_scale = 8.0;
    double maturity_influence = 0.0;
    double local_age_span = 0.05;
    double age_distribution_skew = 0.2;
    std::array<double, 4U> age_band_thresholds{};
    double height_growth_exponent = 0.25;
    double girth_growth_exponent = 0.25;
    double crown_growth_exponent = 0.25;
};

class NativeSurfaceTreeDefinitionComposerRejected final : public std::invalid_argument {
public:
    NativeSurfaceTreeDefinitionComposerRejected();
};

// Composes the production natural-tree definition from one SPP1 anchor and the
// same source-bound baseline entry that consumed the legacy shared-PCG draws.
// It owns ecology and the one physical trunk declaration; branch/crown visual
// topology remains a later native recipe stage and cannot invent collision.
class NativeSurfaceTreeDefinitionComposer final {
public:
    static constexpr std::uint32_t PRODUCER_REVISION = 2U;

    static NativeTreeDefinition create(
        const NativeSurfacePropPlacementSet &placement_set,
        const NativeSurfacePropBaselineStream &baseline,
        std::uint32_t ordinal,
        const WorldSourceDefinition &world_source,
        const NativeSurfaceTreeEcologyProfile &profile);
};

// Shared, independently validating recipe authority for legacy STR2 and the
// source-ordered bridge. Callers own distinct provenance digests.
NativeTreeDefinition compose_native_surface_tree_recipe(
    const NativeSurfacePropPlacementEntry &placement,
    const std::vector<float> &compatibility_draws,
    const WorldSourceDefinition &world_source,
    const NativeSurfaceTreeEcologyProfile &profile,
    const Sha256Digest &source_recipe_digest,
    const std::string &producer_key,
    std::uint32_t producer_revision);

} // namespace voxel::world_backend
