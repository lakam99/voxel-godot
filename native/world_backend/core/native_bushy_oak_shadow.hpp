#pragma once

#include "native_conifer_recipe.hpp"
#include "native_conifer_worker_recipe.hpp"

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>

namespace voxel::world_backend {

// This is the exact scalar/request boundary of the live bushy-oak grammar, not
// a replacement topology generator. The active GDScript grammar still owns its
// seasonal SCA/pipe graph until branches and foliage can be cross-attested.
using NativeBushyOakVec3 = NativeConiferVec3;
using NativeBushyOakBiomeParameters = NativeConiferWorkerBiomeParameters;

struct NativeBushyOakGrowthProfile final {
    int attraction_point_count = 900;
    int branch_segment_budget = 1600;
    int foliage_cluster_budget = 1250;
    int space_colonization_iteration_budget = 15;
    int derived_axis_maximum_growth_seasons = 4;
};

struct NativeBushyOakShadowRecipe final {
    static constexpr int RECIPE_VERSION = 21;
    static constexpr int MAX_BRANCH_SEGMENTS = 1800;
    static constexpr int MAX_FOLIAGE_CLUSTERS = 1600;

    bool valid = false;
    bool topology_complete = false;
    std::int64_t seed = 0;
    double maturity = 0.0;
    double normalized_growth = 0.0;
    double height = 0.0;
    double trunk_radius = 0.0;
    double canopy_radius = 0.0;
    double crown_base = 0.0;
    double crown_height = 0.0;
    double crown_phase = 0.0;
    NativeBushyOakVec3 crown_center;
    NativeBushyOakVec3 crown_radii;
    NativeBushyOakGrowthProfile growth_profile;
};

class NativeBushyOakShadowRejected final : public std::invalid_argument {
public:
    NativeBushyOakShadowRejected();
};

class NativeBushyOakShadowRecipeBuilder final {
public:
    static NativeBushyOakGrowthProfile review_growth_profile() noexcept;
    static NativeBushyOakShadowRecipe build(
        std::int64_t seed,
        double maturity,
        NativeBushyOakGrowthProfile growth_profile = review_growth_profile());
};

struct NativeBushyOakWorkerShadowRequest final {
    std::string tree_id;
    std::string world_seed = "default";
    std::string biome = "forest";
    std::string architecture = "broadleaf";
    std::string species_grammar = "bushy_oak";
    std::string age_band = "mature";
    std::string render_lod_tier = "near";
    std::string presentation = "runtime";
    double growth_stage = 0.58;
    double visual_height = 20.0;
    double trunk_radius = 0.0;
    double canopy_radius = 0.0;
    double canopy_density = 0.78;
    double age_years = 0.0;
    bool has_architecture = false;
    bool has_trunk_radius = false;
    bool has_canopy_radius = false;
    bool has_canopy_density = false;
    std::int64_t genetic_seed = 0;
    NativeBushyOakBiomeParameters biome_parameters;
    NativeBushyOakVec3 world_position;
    double world_rotation_y = 0.0;
};

enum class NativeBushyOakWorkerShadowStatus : std::uint8_t {
    topology_pending = 1,
    exact_impostor_shadow = 2,
};

struct NativeBushyOakDefinitionDimensions final {
    double height = 0.0;
    double trunk_radius = 0.0;
    double canopy_radius = 0.0;
    double collision_trunk_radius = 0.0;
    double collision_trunk_height = 0.0;
};

struct NativeBushyOakWorkerShadow final {
    static constexpr int RECIPE_VERSION = 10;

    bool valid = false;
    bool review = false;
    bool impostor_tier = false;
    bool has_runtime_lod_policy = false;
    bool runtime_impostor = false;
    bool runtime_continuous_bole = false;
    bool poc_continuous_wood = false;
    bool grammar_invoked = false;
    bool topology_complete = false;
    bool artifact_publishable = false;
    NativeBushyOakWorkerShadowStatus status = NativeBushyOakWorkerShadowStatus::topology_pending;
    std::string tree_id;
    std::string world_seed;
    std::string biome;
    std::string architecture;
    std::string species_grammar;
    std::string age_band;
    std::string render_lod_tier;
    std::string presentation;
    std::string request_key;
    std::string recipe_identity_key;
    std::string signature;
    std::string topology_signature;
    double age_years = 0.0;
    double growth_stage = 0.0;
    double height = 0.0;
    double trunk_radius = 0.0;
    double canopy_radius = 0.0;
    double canopy_density = 0.0;
    std::int64_t genetic_seed = 0;
    NativeBushyOakBiomeParameters biome_parameters;
    NativeBushyOakVec3 interaction_world_position;
    double interaction_world_rotation_y = 0.0;
    int render_branch_budget = 0;
    int render_foliage_budget = 0;
    double render_visibility_range = 0.0;
    double render_shadow_range = 0.0;
    double render_wind_response = 0.0;
    double collision_trunk_radius = 0.0;
    double collision_trunk_height = 0.0;
    std::size_t source_branch_count = 0U;
    std::size_t source_foliage_count = 0U;
    NativeBushyOakGrowthProfile growth_profile;
    NativeBushyOakShadowRecipe raw_recipe;
};

class NativeBushyOakWorkerShadowBuilder final {
public:
    // Deliberately stricter than the dynamically typed service boundary: a
    // canonical native request admits only finite numeric inputs. This prevents
    // NaN/Inf from entering an immutable identity or collision artifact.
    static constexpr bool FINITE_NUMERIC_INPUTS_REQUIRED = true;
    static NativeBushyOakWorkerShadow build(const NativeBushyOakWorkerShadowRequest &input);

    // Reproduces TreeSpawnService.runtime_recipe_signature only after an exact
    // topology compiler supplies both missing source facts.
    static std::string finalize_signature(
        const NativeBushyOakWorkerShadow &shadow,
        const std::string &topology_signature,
        std::size_t branch_count);

    // Future artifact wiring must use this strict equality gate. No worker
    // normalization floor may silently change definition-owned collision.
    static void validate_definition_dimensions(
        const NativeBushyOakWorkerShadow &shadow,
        const NativeBushyOakDefinitionDimensions &definition);
};

} // namespace voxel::world_backend
