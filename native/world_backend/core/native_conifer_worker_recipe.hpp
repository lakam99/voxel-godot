#pragma once

#include "native_conifer_recipe.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace voxel::world_backend {

struct NativeConiferWorkerBiomeParameters final {
    int version = 1;
    std::string architecture;
    double height_min = 0.0, height_max = 0.0;
    double trunk_radius_min = 0.0, trunk_radius_max = 0.0;
    double canopy_radius_min = 0.0, canopy_radius_max = 0.0;
    double canopy_density = 0.78, wind_response = 1.0;
    double visibility_range = 440.0, shadow_range = 220.0;
    double exclusion_margin = 0.0;
};

struct NativeConiferWorkerRequest final {
    std::string tree_id, world_seed = "default", biome = "forest";
    std::string architecture = "conifer", species_grammar = "norway_spruce";
    std::string age_band = "mature", render_lod_tier = "near", presentation = "runtime";
    double growth_stage = 0.58, visual_height = 20.0, trunk_radius = 0.0;
    double canopy_radius = 0.0, canopy_density = 0.78, age_years = 0.0;
    bool has_trunk_radius = false, has_canopy_radius = false;
    std::int64_t genetic_seed = 0;
    NativeConiferWorkerBiomeParameters biome_parameters;
    NativeConiferVec3 world_position;
    double world_rotation_y = 0.0;
};

struct NativeConiferWorkerRecipe final {
    static constexpr int RECIPE_VERSION = 10;
    bool valid = false, review = false, impostor = false;
    std::string tree_id, world_seed, biome, architecture, species_grammar;
    std::string age_band, render_lod_tier, signature, topology_signature;
    double age_years = 0.0, growth_stage = 0.0;
    double height = 0.0, trunk_radius = 0.0, canopy_radius = 0.0, canopy_density = 0.0;
    std::int64_t genetic_seed = 0;
    NativeConiferWorkerBiomeParameters biome_parameters;
    int render_branch_budget = 0, render_foliage_budget = 0;
    double render_visibility_range = 0.0, render_shadow_range = 0.0, render_wind_response = 0.0;
    double collision_trunk_radius = 0.0, collision_trunk_height = 0.0;
    NativeConiferVec3 interaction_world_position;
    double interaction_world_rotation_y = 0.0;
    std::size_t source_branch_count = 0, source_foliage_count = 0;
    std::vector<NativeConiferBranch> branches;
    std::vector<NativeConiferFoliage> foliage;
};

class NativeConiferWorkerRecipeBuilder final {
public:
    static NativeConiferWorkerRecipe build(const NativeConiferWorkerRequest &input);
};

} // namespace voxel::world_backend
