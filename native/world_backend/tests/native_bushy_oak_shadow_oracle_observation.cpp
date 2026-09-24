#include "test_harness.hpp"

#include "../core/native_bushy_oak_shadow.hpp"

#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

NativeBushyOakWorkerShadowRequest worker_request(const int case_index) {
    NativeBushyOakWorkerShadowRequest request;
    request.tree_id = "oracle-oak"; request.world_seed = "oracle-world"; request.biome = "forest";
    request.architecture = "broadleaf"; request.has_architecture = true;
    request.species_grammar = "bushy_oak";
    request.genetic_seed = 0x4f414b42; request.growth_stage = 0.92;
    request.visual_height = 26.0; request.trunk_radius = 1.1; request.canopy_radius = 8.0;
    request.has_trunk_radius = true; request.has_canopy_radius = true;
    request.canopy_density = 0.78; request.has_canopy_density = true;
    request.age_band = "mature"; request.age_years = 55.0;
    request.render_lod_tier = "impostor"; request.presentation = case_index == 1 ? "review" : "runtime";
    request.world_position = {4.0F, 5.0F, 6.0F}; request.world_rotation_y = 0.5;
    auto &parameters = request.biome_parameters;
    parameters.version = 2; parameters.architecture = "broadleaf";
    parameters.height_min = 10.0; parameters.height_max = 43.0;
    parameters.trunk_radius_min = 0.5; parameters.trunk_radius_max = 3.1;
    parameters.canopy_radius_min = 9.0; parameters.canopy_radius_max = 29.0;
    parameters.canopy_density = 0.88; parameters.wind_response = 1.25;
    parameters.visibility_range = 350.0; parameters.shadow_range = 170.0;
    parameters.exclusion_margin = 0.4;
    if (case_index == 2) {
        request.has_architecture = false;
        request.architecture.clear();
        request.has_canopy_density = false;
        parameters.architecture = "  BROADLEAF  ";
        parameters.canopy_density = 0.88;
    } else if (case_index == 3) {
        request.architecture = "   ";
        request.has_canopy_density = false;
        parameters.architecture = "conifer";
        parameters.canopy_density = -1.0;
    } else if (case_index == 4) {
        request.architecture = "broadl\xC3\xA9";
        request.has_canopy_density = false;
        parameters.canopy_density = 4.0;
    } else if (case_index == 5) {
        request.architecture = "conifer";
    } else if (case_index == 6) {
        request.architecture = "savanna";
    }
    return request;
}

NativeBushyOakWorkerShadow scalar_request(
    const std::int64_t seed,
    const double maturity,
    const double density,
    const std::string &tier) {
    NativeBushyOakWorkerShadowRequest request = worker_request(0);
    request.tree_id = "scalar-oak";
    request.genetic_seed = seed;
    request.growth_stage = maturity;
    request.canopy_density = density;
    request.render_lod_tier = tier;
    return NativeBushyOakWorkerShadowBuilder::build(request);
}

bool observation_requested() {
#ifdef _WIN32
    char *value = nullptr;
    std::size_t size = 0U;
    (void)_dupenv_s(&value, &size, "VWB_NATIVE_BUSHY_OAK_SHADOW_ORACLE");
    const bool present = value != nullptr;
    std::free(value);
    return present;
#else
    return std::getenv("VWB_NATIVE_BUSHY_OAK_SHADOW_ORACLE") != nullptr;
#endif
}

void print_vec(const NativeBushyOakVec3 &value) {
    std::cout << '[' << value.x << ',' << value.y << ',' << value.z << ']';
}

void emit_raw(const NativeBushyOakWorkerShadow &shadow) {
    const NativeBushyOakShadowRecipe &recipe = shadow.raw_recipe;
    std::cout << std::setprecision(17)
              << "VWB_NATIVE_BUSHY_OAK_SHADOW_ORACLE:{\"seed\":" << recipe.seed
              << ",\"maturity\":" << recipe.maturity << ",\"signature\":\"\""
              << ",\"height\":" << recipe.height << ",\"trunkRadius\":" << recipe.trunk_radius
              << ",\"canopyRadius\":" << recipe.canopy_radius << ",\"crownBase\":" << recipe.crown_base
              << ",\"crownHeight\":" << recipe.crown_height << ",\"crownPhase\":" << recipe.crown_phase
              << ",\"crownCenter\":";
    print_vec(recipe.crown_center);
    std::cout << ",\"crownRadii\":";
    print_vec(recipe.crown_radii);
    std::cout << ",\"growthProfile\":[" << recipe.growth_profile.attraction_point_count << ','
              << recipe.growth_profile.branch_segment_budget << ','
              << recipe.growth_profile.foliage_cluster_budget << ','
              << recipe.growth_profile.space_colonization_iteration_budget << ','
              << recipe.growth_profile.derived_axis_maximum_growth_seasons << ']'
              << ",\"renderBudgets\":[" << shadow.render_branch_budget << ','
              << shadow.render_foliage_budget << ']'
              << ",\"branchCount\":0,\"foliageCount\":0,\"nodeCount\":0"
              << ",\"segmentCountsByOrder\":[0,0,0,0,0]"
              << ",\"raisedForkCount\":0,\"crownWindowCount\":0,\"viableAxisBudCount\":0"
              << ",\"germinatedAxisCount\":0,\"grownMetamerCount\":0"
              << ",\"pipeModelJunctionCount\":0,\"occupiedCrownBins\":0"
              << ",\"branchSelectionHash\":0,\"foliageSelectionHash\":0"
              << ",\"branchHashCheckpoints\":[],\"foliageHashCheckpoints\":[]}\n";
}

void emit_worker(const int case_index, const NativeBushyOakWorkerShadow &recipe) {
    std::cout << std::setprecision(17)
              << "VWB_NATIVE_BUSHY_OAK_SHADOW_WORKER_ORACLE:{\"caseIndex\":" << case_index
              << ",\"recipeIdentityKey\":\"" << recipe.recipe_identity_key
              << "\",\"requestKey\":\"" << recipe.request_key << '"'
              << ",\"signature\":\"" << recipe.signature << "\",\"topologySignature\":\""
              << recipe.topology_signature << "\",\"sourceBranches\":" << recipe.source_branch_count
              << ",\"sourceFoliage\":" << recipe.source_foliage_count
              << ",\"branches\":0,\"foliage\":0,\"branchSelectionHash\":0,\"foliageSelectionHash\":0"
              << ",\"normalized\":{\"treeId\":\"" << recipe.tree_id << "\",\"worldSeed\":\""
              << recipe.world_seed << "\",\"biome\":\"" << recipe.biome << "\",\"architecture\":\""
              << recipe.architecture << "\",\"speciesGrammar\":\"" << recipe.species_grammar
              << "\",\"ageBand\":\"" << recipe.age_band << "\",\"ageYears\":" << recipe.age_years
              << ",\"growthStage\":" << recipe.growth_stage << ",\"geneticSeed\":" << recipe.genetic_seed
              << ",\"height\":" << recipe.height << ",\"trunkRadius\":" << recipe.trunk_radius
              << ",\"canopyRadius\":" << recipe.canopy_radius << ",\"canopyDensity\":"
              << recipe.canopy_density << '}'
              << ",\"renderTier\":\"" << recipe.render_lod_tier << "\",\"branchBudget\":0"
              << ",\"foliageBudget\":0,\"review\":" << (recipe.review ? "true" : "false")
              << ",\"impostor\":" << (recipe.runtime_impostor ? "true" : "false")
              << ",\"renderPolicy\":{\"visibilityRange\":" << recipe.render_visibility_range
              << ",\"shadowRange\":" << recipe.render_shadow_range << ",\"windResponse\":"
              << recipe.render_wind_response << ",\"shadowPolicy\":\"near_only\",\"lodTier\":\""
              << recipe.render_lod_tier << "\"}"
              << ",\"runtimeContinuousBole\":" << (recipe.runtime_continuous_bole ? "true" : "false")
              << ",\"pocContinuousWood\":" << (recipe.poc_continuous_wood ? "true" : "false")
              << ",\"continuousTrunkPath\":false,\"graphConnected\":false"
              << ",\"foliageDerivedFromFineSegments\":false"
              << ",\"collisionRadius\":" << recipe.collision_trunk_radius
              << ",\"collisionHeight\":" << recipe.collision_trunk_height
              << ",\"interaction\":{\"treeId\":\"" << recipe.tree_id << "\",\"worldPosition\":";
    print_vec(recipe.interaction_world_position);
    std::cout << ",\"worldRotationY\":" << recipe.interaction_world_rotation_y
              << ",\"rootButtressCount\":0}"
              << ",\"crownHabit\":\"distance_impostor\",\"methodology\":\"\""
              << ",\"firstBranch\":{},\"firstFoliage\":{}}\n";
}

} // namespace

std::optional<int> emit_native_bushy_oak_shadow_observations_if_requested() {
    if (!observation_requested()) return std::nullopt;
    emit_raw(scalar_request(0x4f414b42, 0.92, 0.78, "near"));
    emit_raw(scalar_request(-319, 0.12, 0.20, "mid"));
    emit_raw(scalar_request(-319, 1.0, 1.0, "far"));
    for (int case_index = 0; case_index < 7; ++case_index) {
        emit_worker(case_index, NativeBushyOakWorkerShadowBuilder::build(worker_request(case_index)));
    }
    return 0;
}

VWB_TEST(native_bushy_oak_shadow_observation_is_explicitly_topology_free) {
    for (const auto &raw : {
            scalar_request(0x4f414b42, 0.92, 0.78, "near"),
            scalar_request(-319, 0.12, 0.20, "mid"),
            scalar_request(-319, 1.0, 1.0, "far")}) {
        VWB_EXPECT(raw.valid && raw.raw_recipe.valid && !raw.raw_recipe.topology_complete);
        VWB_EXPECT(!raw.topology_complete && !raw.artifact_publishable);
    }
    for (int case_index = 0; case_index < 7; ++case_index) {
        const auto worker = NativeBushyOakWorkerShadowBuilder::build(worker_request(case_index));
        VWB_EXPECT(worker.valid && worker.impostor_tier && worker.topology_complete);
        VWB_EXPECT(!worker.artifact_publishable);
        VWB_EXPECT_EQ(std::size_t(0), worker.source_branch_count);
        VWB_EXPECT_EQ(std::size_t(0), worker.source_foliage_count);
    }
}
