#include "test_harness.hpp"

#include "../core/native_bushy_oak_shadow.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <string>

using namespace voxel::world_backend;

namespace {

NativeBushyOakWorkerShadowRequest base_request() {
    NativeBushyOakWorkerShadowRequest request;
    request.tree_id = "oracle-oak";
    request.world_seed = "oracle-world";
    request.biome = "forest";
    request.architecture = "broadleaf";
    request.has_architecture = true;
    request.species_grammar = "bushy_oak";
    request.genetic_seed = 0x4f414b42;
    request.growth_stage = 0.92;
    request.visual_height = 26.0;
    request.trunk_radius = 1.1;
    request.canopy_radius = 8.0;
    request.has_trunk_radius = true;
    request.has_canopy_radius = true;
    request.canopy_density = 0.78;
    request.has_canopy_density = true;
    request.age_band = "mature";
    request.age_years = 55.0;
    request.render_lod_tier = "near";
    request.presentation = "runtime";
    request.world_position = {4.0F, 5.0F, 6.0F};
    request.world_rotation_y = 0.5;
    request.biome_parameters.version = 2;
    request.biome_parameters.architecture = "broadleaf";
    request.biome_parameters.height_min = 10.0;
    request.biome_parameters.height_max = 43.0;
    request.biome_parameters.trunk_radius_min = 0.5;
    request.biome_parameters.trunk_radius_max = 3.1;
    request.biome_parameters.canopy_radius_min = 9.0;
    request.biome_parameters.canopy_radius_max = 29.0;
    request.biome_parameters.canopy_density = 0.88;
    request.biome_parameters.wind_response = 1.25;
    request.biome_parameters.visibility_range = 350.0;
    request.biome_parameters.shadow_range = 170.0;
    request.biome_parameters.exclusion_margin = 0.4;
    return request;
}

void expect_profile(
    const NativeBushyOakGrowthProfile &profile,
    const int attraction,
    const int branches,
    const int foliage,
    const int iterations,
    const int seasons) {
    VWB_EXPECT_EQ(attraction, profile.attraction_point_count);
    VWB_EXPECT_EQ(branches, profile.branch_segment_budget);
    VWB_EXPECT_EQ(foliage, profile.foliage_cluster_budget);
    VWB_EXPECT_EQ(iterations, profile.space_colonization_iteration_budget);
    VWB_EXPECT_EQ(seasons, profile.derived_axis_maximum_growth_seasons);
}

} // namespace

VWB_TEST(native_bushy_oak_shadow_matches_direct_godot_far_envelope_rng_and_limits) {
    const NativeBushyOakGrowthProfile profile{96, 144, 176, 4, 1};
    const NativeBushyOakShadowRecipe recipe = NativeBushyOakShadowRecipeBuilder::build(-319, 1.0, profile);
    VWB_EXPECT(recipe.valid);
    VWB_EXPECT(!recipe.topology_complete);
    VWB_EXPECT_EQ(21, NativeBushyOakShadowRecipe::RECIPE_VERSION);
    VWB_EXPECT_EQ(1800, NativeBushyOakShadowRecipe::MAX_BRANCH_SEGMENTS);
    VWB_EXPECT_EQ(1600, NativeBushyOakShadowRecipe::MAX_FOLIAGE_CLUSTERS);
    VWB_EXPECT_EQ(std::int64_t(-319), recipe.seed);
    VWB_EXPECT_EQ(1.0, recipe.maturity);
    VWB_EXPECT_EQ(1.0, recipe.normalized_growth);
    VWB_EXPECT_EQ(43.0, recipe.height);
    VWB_EXPECT(std::abs(recipe.trunk_radius - 3.1) < 1e-12);
    VWB_EXPECT_EQ(29.0, recipe.canopy_radius);
    VWB_EXPECT_EQ(11.6, recipe.crown_base);
    VWB_EXPECT_EQ(32.5, recipe.crown_height);
    VWB_EXPECT(std::abs(double(recipe.crown_center.y) - 26.225) < 0.00001);
    VWB_EXPECT(std::abs(double(recipe.crown_radii.y) - 17.55) < 0.00001);
    VWB_EXPECT(std::abs(double(recipe.crown_radii.z) - 26.68) < 0.00001);
    VWB_EXPECT(std::abs(recipe.crown_phase - 0.782016786252375) < 1e-12);
    expect_profile(recipe.growth_profile, 96, 144, 176, 4, 1);

    const auto young = NativeBushyOakShadowRecipeBuilder::build(-319, -2.0);
    const auto old = NativeBushyOakShadowRecipeBuilder::build(-319, 2.0);
    VWB_EXPECT_EQ(0.12, young.maturity);
    VWB_EXPECT_EQ(1.0, old.maturity);
    expect_profile(NativeBushyOakShadowRecipeBuilder::review_growth_profile(), 900, 1600, 1250, 15, 4);
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected, NativeBushyOakShadowRecipeBuilder::build(
        1, std::numeric_limits<double>::quiet_NaN()));

    for (int field = 0; field < 5; ++field) {
        NativeBushyOakGrowthProfile invalid = profile;
        if (field == 0) invalid.attraction_point_count = 0;
        if (field == 1) invalid.branch_segment_budget = 0;
        if (field == 2) invalid.foliage_cluster_budget = 0;
        if (field == 3) invalid.space_colonization_iteration_budget = 0;
        if (field == 4) invalid.derived_axis_maximum_growth_seasons = 0;
        VWB_EXPECT_THROW(NativeBushyOakShadowRejected,
            NativeBushyOakShadowRecipeBuilder::build(1, 0.5, invalid));
    }
}

VWB_TEST(native_bushy_oak_worker_shadow_matches_direct_service_profiles_and_signatures) {
    const auto near = NativeBushyOakWorkerShadowBuilder::build(base_request());
    VWB_EXPECT(near.valid && near.grammar_invoked);
    VWB_EXPECT(!near.review && !near.impostor_tier);
    VWB_EXPECT(near.has_runtime_lod_policy && !near.runtime_impostor);
    VWB_EXPECT(near.runtime_continuous_bole && !near.poc_continuous_wood);
    VWB_EXPECT(!near.topology_complete && !near.artifact_publishable);
    VWB_EXPECT_EQ(std::size_t(0), near.source_branch_count);
    VWB_EXPECT_EQ(std::size_t(0), near.source_foliage_count);
    VWB_EXPECT_EQ(NativeBushyOakWorkerShadowStatus::topology_pending, near.status);
    VWB_EXPECT_EQ(std::string("broadleaf"), near.architecture);
    VWB_EXPECT_EQ(std::string("bushy_oak"), near.species_grammar);
    VWB_EXPECT_EQ(std::string("near"), near.render_lod_tier);
    VWB_EXPECT(near.signature.empty() && near.topology_signature.empty());
    VWB_EXPECT_EQ(392, near.render_branch_budget);
    VWB_EXPECT_EQ(579, near.render_foliage_budget);
    expect_profile(near.growth_profile, 598, 616, 807, 17, 4);
    VWB_EXPECT_EQ(350.0, near.render_visibility_range);
    VWB_EXPECT_EQ(170.0, near.render_shadow_range);
    VWB_EXPECT_EQ(1.25, near.render_wind_response);
    VWB_EXPECT_EQ(1.1, near.collision_trunk_radius);
    VWB_EXPECT(std::abs(near.collision_trunk_height - 11.96) < 1e-12);
    VWB_EXPECT_EQ(4.0F, near.interaction_world_position.x);
    VWB_EXPECT_EQ(0.5, near.interaction_world_rotation_y);
    VWB_EXPECT_EQ(std::string("runtime:oracle-world:oracle-oak:forest:broadleaf:bushy_oak:0.92000:26.000:1.100:8.000:0.780:1329679170:2:broadleaf:10.00:43.00:0.500:3.100:9.000:29.000:0.880:1.250:350.0:170.0"), near.recipe_identity_key);
    VWB_EXPECT_EQ(near.recipe_identity_key + ":near", near.request_key);

    auto mid_request = base_request();
    mid_request.growth_stage = 0.12;
    mid_request.canopy_density = 0.20;
    mid_request.render_lod_tier = " mid ";
    const auto mid = NativeBushyOakWorkerShadowBuilder::build(mid_request);
    VWB_EXPECT_EQ(166, mid.render_branch_budget);
    VWB_EXPECT_EQ(245, mid.render_foliage_budget);
    expect_profile(mid.growth_profile, 96, 185, 251, 4, 1);

    auto far_request = base_request();
    far_request.genetic_seed = -319;
    far_request.growth_stage = 1.0;
    far_request.canopy_density = 1.0;
    far_request.render_lod_tier = "far";
    const auto far = NativeBushyOakWorkerShadowBuilder::build(far_request);
    VWB_EXPECT_EQ(97, far.render_branch_budget);
    VWB_EXPECT_EQ(143, far.render_foliage_budget);
    expect_profile(far.growth_profile, 96, 144, 176, 4, 1);
    VWB_EXPECT_EQ(std::string("tree-v10-6065e4c2"),
        NativeBushyOakWorkerShadowBuilder::finalize_signature(far, "2e8d31bb", 76U));

    auto review_request = base_request();
    review_request.presentation = "review";
    const auto review = NativeBushyOakWorkerShadowBuilder::build(review_request);
    VWB_EXPECT(review.review && review.grammar_invoked);
    VWB_EXPECT(!review.impostor_tier && !review.has_runtime_lod_policy);
    VWB_EXPECT(!review.runtime_impostor && !review.runtime_continuous_bole);
    VWB_EXPECT(review.poc_continuous_wood);
    VWB_EXPECT(review.signature.empty() && review.topology_signature.empty());
    VWB_EXPECT_EQ(0, review.render_branch_budget);
    VWB_EXPECT_EQ(0, review.render_foliage_budget);
    expect_profile(review.growth_profile, 900, 1600, 1250, 15, 4);

    auto impostor_request = base_request();
    impostor_request.render_lod_tier = "impostor";
    const auto impostor = NativeBushyOakWorkerShadowBuilder::build(impostor_request);
    VWB_EXPECT(impostor.valid && impostor.impostor_tier && impostor.topology_complete);
    VWB_EXPECT(impostor.has_runtime_lod_policy && impostor.runtime_impostor);
    VWB_EXPECT(!impostor.runtime_continuous_bole && !impostor.poc_continuous_wood);
    VWB_EXPECT(!impostor.grammar_invoked && !impostor.raw_recipe.valid && !impostor.artifact_publishable);
    VWB_EXPECT_EQ(std::size_t(0), impostor.source_branch_count);
    VWB_EXPECT_EQ(std::size_t(0), impostor.source_foliage_count);
    VWB_EXPECT_EQ(NativeBushyOakWorkerShadowStatus::exact_impostor_shadow, impostor.status);
    VWB_EXPECT_EQ(std::string("impostor:oracle-world:oracle-oak:bushy_oak"), impostor.topology_signature);
    VWB_EXPECT_EQ(std::string("tree-v10-ada1a6f6"), impostor.signature);

    auto review_impostor_request = impostor_request;
    review_impostor_request.presentation = "review";
    const auto review_impostor = NativeBushyOakWorkerShadowBuilder::build(review_impostor_request);
    VWB_EXPECT(review_impostor.review && review_impostor.impostor_tier);
    VWB_EXPECT(!review_impostor.has_runtime_lod_policy && !review_impostor.runtime_impostor);
    VWB_EXPECT(!review_impostor.runtime_continuous_bole && review_impostor.poc_continuous_wood);
    VWB_EXPECT_EQ(std::string("tree-v10-830238ec"), review_impostor.signature);
}

VWB_TEST(native_bushy_oak_worker_shadow_normalizes_dimensions_and_rejects_invalid_input) {
    VWB_EXPECT(NativeBushyOakWorkerShadowBuilder::FINITE_NUMERIC_INPUTS_REQUIRED);
    auto request = base_request();
    request.tree_id = "   ";
    VWB_EXPECT(!NativeBushyOakWorkerShadowBuilder::build(request).valid);

    request = base_request();
    request.tree_id = "  oracle-oak  ";
    request.world_seed = " ";
    request.biome = "  FOREST  ";
    request.architecture = "  BROADLEAF  ";
    request.species_grammar = "  ROUNDED_BROADLEAF  ";
    request.render_lod_tier = "unknown";
    request.genetic_seed = 0;
    request.growth_stage = -1.0;
    request.visual_height = 2.0;
    request.has_trunk_radius = false;
    request.has_canopy_radius = false;
    request.canopy_density = -1.0;
    request.biome_parameters.version = 0;
    request.biome_parameters.architecture = "  BROADLEAF  ";
    request.biome_parameters.height_min = -1.0;
    request.biome_parameters.height_max = -2.0;
    request.biome_parameters.trunk_radius_min = -3.0;
    request.biome_parameters.trunk_radius_max = -4.0;
    request.biome_parameters.canopy_radius_min = -5.0;
    request.biome_parameters.canopy_radius_max = -6.0;
    request.biome_parameters.canopy_density = -1.0;
    request.biome_parameters.wind_response = 3.0;
    request.biome_parameters.visibility_range = 1.0;
    request.biome_parameters.shadow_range = 1.0;
    request.biome_parameters.exclusion_margin = -1.0;
    const auto normalized = NativeBushyOakWorkerShadowBuilder::build(request);
    VWB_EXPECT_EQ(std::string("oracle-oak"), normalized.tree_id);
    VWB_EXPECT_EQ(std::string("default"), normalized.world_seed);
    VWB_EXPECT_EQ(std::string("forest"), normalized.biome);
    VWB_EXPECT_EQ(std::string("broadleaf"), normalized.architecture);
    VWB_EXPECT_EQ(std::string("bushy_oak"), normalized.species_grammar);
    VWB_EXPECT_EQ(std::string("near"), normalized.render_lod_tier);
    VWB_EXPECT_EQ(0.12, normalized.growth_stage);
    VWB_EXPECT_EQ(4.0, normalized.height);
    VWB_EXPECT_EQ(0.18, normalized.trunk_radius);
    VWB_EXPECT(std::abs(normalized.canopy_radius - 1.36) < 1e-12);
    VWB_EXPECT_EQ(0.20, normalized.canopy_density);
    VWB_EXPECT(normalized.genetic_seed != 0);
    VWB_EXPECT_EQ(1, normalized.biome_parameters.version);
    VWB_EXPECT_EQ(std::string("broadleaf"), normalized.biome_parameters.architecture);
    VWB_EXPECT_EQ(0.0, normalized.biome_parameters.height_min);
    VWB_EXPECT_EQ(0.0, normalized.biome_parameters.height_max);
    VWB_EXPECT_EQ(0.0, normalized.biome_parameters.trunk_radius_min);
    VWB_EXPECT_EQ(0.0, normalized.biome_parameters.trunk_radius_max);
    VWB_EXPECT_EQ(0.0, normalized.biome_parameters.canopy_radius_min);
    VWB_EXPECT_EQ(0.0, normalized.biome_parameters.canopy_radius_max);
    VWB_EXPECT_EQ(0.20, normalized.biome_parameters.canopy_density);
    VWB_EXPECT_EQ(2.0, normalized.biome_parameters.wind_response);
    VWB_EXPECT_EQ(32.0, normalized.biome_parameters.visibility_range);
    VWB_EXPECT_EQ(16.0, normalized.biome_parameters.shadow_range);
    VWB_EXPECT_EQ(0.0, normalized.biome_parameters.exclusion_margin);

    request = base_request();
    request.has_architecture = false;
    request.architecture = "ignored-when-absent";
    request.has_canopy_density = false;
    request.canopy_density = std::numeric_limits<double>::quiet_NaN();
    request.biome_parameters.architecture = "  BROADLEAF  ";
    request.biome_parameters.canopy_density = 0.88;
    const auto omitted = NativeBushyOakWorkerShadowBuilder::build(request);
    VWB_EXPECT_EQ(std::string("broadleaf"), omitted.architecture);
    VWB_EXPECT_EQ(0.88, omitted.canopy_density);

    request = base_request();
    request.architecture = "   ";
    request.has_canopy_density = false;
    request.biome_parameters.architecture = "conifer";
    request.biome_parameters.canopy_density = -1.0;
    const auto explicit_empty = NativeBushyOakWorkerShadowBuilder::build(request);
    VWB_EXPECT_EQ(std::string("broadleaf"), explicit_empty.architecture);
    VWB_EXPECT_EQ(0.20, explicit_empty.canopy_density);

    request = base_request();
    request.architecture = "unknown-family";
    request.has_canopy_density = false;
    request.biome_parameters.canopy_density = 4.0;
    const auto unknown = NativeBushyOakWorkerShadowBuilder::build(request);
    VWB_EXPECT_EQ(std::string("broadleaf"), unknown.architecture);
    VWB_EXPECT_EQ(1.0, unknown.canopy_density);

    request = base_request(); request.species_grammar = "";
    VWB_EXPECT_EQ(std::string("bushy_oak"),
        NativeBushyOakWorkerShadowBuilder::build(request).species_grammar);
    request.architecture = "savanna";
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.has_architecture = false;
    request.biome_parameters.architecture = "conifer";
    const auto explicit_oak_on_conifer = NativeBushyOakWorkerShadowBuilder::build(request);
    VWB_EXPECT_EQ(std::string("conifer"), explicit_oak_on_conifer.architecture);
    VWB_EXPECT(std::abs(explicit_oak_on_conifer.collision_trunk_height - 21.32) < 1e-12);
    request.species_grammar = "";
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.architecture = "savanna";
    const auto explicit_oak_on_savanna = NativeBushyOakWorkerShadowBuilder::build(request);
    VWB_EXPECT_EQ(std::string("savanna"), explicit_oak_on_savanna.architecture);
    VWB_EXPECT(std::abs(explicit_oak_on_savanna.collision_trunk_height - 13.52) < 1e-12);
    request = base_request(); request.species_grammar = "norway_spruce";
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.architecture = "broadl\xC3\xA9";
    VWB_EXPECT_EQ(std::string("broadleaf"),
        NativeBushyOakWorkerShadowBuilder::build(request).architecture);
    request = base_request(); request.render_lod_tier = "f\xC3\xA1r";
    VWB_EXPECT_EQ(std::string("near"),
        NativeBushyOakWorkerShadowBuilder::build(request).render_lod_tier);
    request = base_request(); request.biome = "For\xC3\xAAt";
    VWB_EXPECT_EQ(std::string("for\xC3\xAAt"),
        NativeBushyOakWorkerShadowBuilder::build(request).biome);
    request = base_request(); request.biome = std::string("\xC3", 1);
    VWB_EXPECT_THROW(std::invalid_argument, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.growth_stage = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.canopy_density = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.world_position.z = std::numeric_limits<float>::infinity();
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.trunk_radius = std::numeric_limits<double>::max();
    request.has_trunk_radius = true; request.has_canopy_radius = false;
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.biome_parameters.height_min = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.render_lod_tier = "impostor";
    request.biome_parameters.height_min = std::numeric_limits<double>::max();
    request.biome_parameters.height_max = std::numeric_limits<double>::max();
    request.biome_parameters.trunk_radius_min = std::numeric_limits<double>::max();
    request.biome_parameters.trunk_radius_max = std::numeric_limits<double>::max();
    request.biome_parameters.canopy_radius_min = std::numeric_limits<double>::max();
    request.biome_parameters.canopy_radius_max = std::numeric_limits<double>::max();
    request.biome_parameters.visibility_range = std::numeric_limits<double>::max();
    request.biome_parameters.shadow_range = std::numeric_limits<double>::max();
    VWB_EXPECT_THROW(std::invalid_argument, NativeBushyOakWorkerShadowBuilder::build(request));

    request = base_request(); request.render_lod_tier = "impostor";
    request.tree_id = std::string(256, 'a');
    VWB_EXPECT(NativeBushyOakWorkerShadowBuilder::build(request).valid);
    request.tree_id.push_back('a');
    VWB_EXPECT_THROW(std::invalid_argument, NativeBushyOakWorkerShadowBuilder::build(request));
    request = base_request(); request.render_lod_tier = "impostor";
    request.tree_id = std::string(256, 'a'); request.world_seed = std::string(256, 'b');
    request.biome = std::string(256, 'c'); request.age_band = std::string(256, 'd');
    request.presentation = "e";
    VWB_EXPECT_THROW(std::invalid_argument, NativeBushyOakWorkerShadowBuilder::build(request));

    request = base_request(); request.genetic_seed = 0; request.render_lod_tier = "impostor";
    for (const std::string &value : {std::string("\x80", 1), std::string("\xC3", 1),
            std::string("\xC3\x41", 2), std::string("\xC0\x80", 2),
            std::string("\xE0\x80\x80", 3), std::string("\xF0\x80\x80\x80", 4),
            std::string("\xF4\x90\x80\x80", 4), std::string("\xED\xA0\x80", 3)}) {
        request.world_seed = value;
        VWB_EXPECT_THROW(std::invalid_argument, NativeBushyOakWorkerShadowBuilder::build(request));
    }
    for (const std::string &value : {std::string("caf\xC3\xA9"), std::string("\xE2\x98\x83"),
            std::string("\xF0\x9F\x8C\xB3")}) {
        request.world_seed = value;
        VWB_EXPECT(NativeBushyOakWorkerShadowBuilder::build(request).valid);
    }

    const auto source = NativeBushyOakWorkerShadowBuilder::build(base_request());
    const NativeBushyOakDefinitionDimensions exact{26.0, 1.1, 8.0, 1.1, 11.96};
    NativeBushyOakWorkerShadowBuilder::validate_definition_dimensions(source, exact);
    for (int field = 0; field < 5; ++field) {
        NativeBushyOakDefinitionDimensions changed = exact;
        if (field == 0) changed.height += 0.5;
        if (field == 1) changed.trunk_radius += 0.5;
        if (field == 2) changed.canopy_radius += 0.5;
        if (field == 3) changed.collision_trunk_radius += 0.5;
        if (field == 4) changed.collision_trunk_height += 0.5;
        VWB_EXPECT_THROW(NativeBushyOakShadowRejected,
            NativeBushyOakWorkerShadowBuilder::validate_definition_dimensions(source, changed));
    }
    NativeBushyOakDefinitionDimensions non_finite = exact;
    non_finite.height = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected,
        NativeBushyOakWorkerShadowBuilder::validate_definition_dimensions(source, non_finite));
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected,
        NativeBushyOakWorkerShadowBuilder::validate_definition_dimensions({}, {}));
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected,
        NativeBushyOakWorkerShadowBuilder::finalize_signature({}, "fixture", 1U));
    VWB_EXPECT_THROW(NativeBushyOakShadowRejected,
        NativeBushyOakWorkerShadowBuilder::finalize_signature(source, "", 1U));
    VWB_EXPECT_THROW(std::invalid_argument,
        NativeBushyOakWorkerShadowBuilder::finalize_signature(source, std::string(257, 'x'), 1U));
}
