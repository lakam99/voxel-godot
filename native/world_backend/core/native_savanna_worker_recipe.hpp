#pragma once

#include "native_conifer_worker_recipe.hpp"
#include "native_savanna_recipe.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace voxel::world_backend {

using NativeSavannaWorkerBiomeParameters = NativeConiferWorkerBiomeParameters;

struct NativeSavannaWorkerRequest final {
    std::string tree_id, world_seed = "default", biome = "savanna";
    std::string architecture = "savanna", species_grammar = "umbrella_thorn";
    std::string age_band = "mature", render_lod_tier = "near", presentation = "runtime";
    double growth_stage = 0.58, visual_height = 20.0, trunk_radius = 0.0;
    double canopy_radius = 0.0, canopy_density = 0.78, age_years = 0.0;
    bool has_trunk_radius = false, has_canopy_radius = false;
    std::int64_t genetic_seed = 0;
    NativeSavannaWorkerBiomeParameters biome_parameters;
    NativeSavannaVec3 world_position;
    double world_rotation_y = 0.0;
};

struct NativeSavannaWorkerRecipe final {
    static constexpr int RECIPE_VERSION = 10;
    bool valid = false, review = false, impostor = false;
    bool runtime_continuous_bole = false, poc_continuous_wood = false;
    bool continuous_trunk_path = false, graph_connected = false;
    bool foliage_derived_from_fine_segments = false;
    std::string crown_habit, methodology;
    std::string tree_id, world_seed, biome, architecture, species_grammar;
    std::string age_band, render_lod_tier, signature, topology_signature;
    double age_years = 0.0, growth_stage = 0.0;
    double height = 0.0, trunk_radius = 0.0, canopy_radius = 0.0, canopy_density = 0.0;
    std::int64_t genetic_seed = 0;
    NativeSavannaWorkerBiomeParameters biome_parameters;
    int render_branch_budget = 0, render_foliage_budget = 0;
    double render_visibility_range = 0.0, render_shadow_range = 0.0, render_wind_response = 0.0;
    double collision_trunk_radius = 0.0, collision_trunk_height = 0.0;
    NativeSavannaVec3 interaction_world_position;
    double interaction_world_rotation_y = 0.0;
    std::size_t source_branch_count = 0, source_foliage_count = 0;
    int runtime_recipe_pass_count = 1, runtime_foliage_supplement_count = 0;
    int raw_recipe_version = 0, raw_node_count = 0, raw_raised_fork_count = 0;
    int raw_crown_window_count = 0, raw_viable_axis_bud_count = 0;
    int raw_germinated_axis_count = 0, raw_grown_metamer_count = 0;
    int raw_pipe_junction_count = 0, raw_occupied_crown_bins = 0;
    std::array<int, 5> raw_segment_counts_by_order{};
    double raw_maturity = 0.0, raw_crown_base = 0.0, raw_crown_height = 0.0;
    double raw_girth_eligible_length = 0.0, raw_girth_weighted_bud_charge = 0.0;
    double raw_mean_lateral_scaffold_pitch = 0.0, raw_maximum_major_wood_reach = 0.0;
    double raw_pipe_max_relative_error = 0.0;
    NativeSavannaVec3 raw_crown_center, raw_crown_radii;
    std::vector<NativeSavannaBranch> branches;
    std::vector<NativeSavannaFoliage> foliage;
};

class NativeSavannaWorkerRecipeBuilder final {
public:
    // Internal pure-core compiler entry point. Direct requests are admitted
    // through the same UTF-8 and bounded-identity contract as artifacts.
    static NativeSavannaWorkerRecipe build(const NativeSavannaWorkerRequest &input);
};

} // namespace voxel::world_backend
