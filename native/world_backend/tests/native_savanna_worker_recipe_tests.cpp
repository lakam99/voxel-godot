#include "test_harness.hpp"

#include "../core/native_savanna_worker_recipe.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>

using namespace voxel::world_backend;

namespace {
NativeSavannaWorkerRequest base() {
    NativeSavannaWorkerRequest request;
    request.tree_id="oracle-tree";request.world_seed="oracle-world";request.biome="savanna";
    request.architecture="savanna";request.species_grammar="umbrella_thorn";
    request.genetic_seed=0x53415641;request.growth_stage=0.92;
    request.visual_height=26.0;request.trunk_radius=1.1;request.canopy_radius=8.0;
    request.has_trunk_radius=true;request.has_canopy_radius=true;
    request.canopy_density=0.78;request.age_band="mature";request.age_years=55.0;
    request.render_lod_tier="near";request.presentation="runtime";
    request.world_position={4,5,6};request.world_rotation_y=0.5;
    auto &p=request.biome_parameters;p.version=2;p.architecture="savanna";
    p.height_min=10;p.height_max=30;p.trunk_radius_min=0.5;p.trunk_radius_max=3;
    p.canopy_radius_min=7;p.canopy_radius_max=24;p.canopy_density=0.88;p.wind_response=1.25;
    p.visibility_range=350;p.shadow_range=170;p.exclusion_margin=0.4;
    return request;
}
std::uint32_t branch_hash(const NativeSavannaWorkerRecipe &recipe) {
    std::string text;
    for(const auto &branch:recipe.branches) {if(!text.empty()) text.push_back(',');text+=std::to_string(branch.child_node);}
    return NativeConiferRecipeBuilder::stable_hash(text);
}
std::uint32_t foliage_hash(const NativeSavannaWorkerRecipe &recipe) {
    std::string text;
    for(const auto &anchor:recipe.foliage) {if(!text.empty()) text.push_back(',');
        text+=std::to_string(anchor.source_segment)+":"+std::to_string(anchor.cluster_variant);}
    return NativeConiferRecipeBuilder::stable_hash(text);
}
struct Expected final {
    const char *signature,*topology;std::size_t source_branches,source_foliage,branches,foliage;
    std::uint32_t branch_selection,foliage_selection;
};
void expect(const NativeSavannaWorkerRequest &input,const Expected &expected) {
    const auto recipe=NativeSavannaWorkerRecipeBuilder::build(input);
    VWB_EXPECT(recipe.valid);
    VWB_EXPECT_EQ(std::string(expected.signature),recipe.signature);
    VWB_EXPECT_EQ(std::string(expected.topology),recipe.topology_signature);
    VWB_EXPECT_EQ(expected.source_branches,recipe.source_branch_count);
    VWB_EXPECT_EQ(expected.source_foliage,recipe.source_foliage_count);
    VWB_EXPECT_EQ(expected.branches,recipe.branches.size());
    VWB_EXPECT_EQ(expected.foliage,recipe.foliage.size());
    VWB_EXPECT_EQ(expected.branch_selection,branch_hash(recipe));
    VWB_EXPECT_EQ(expected.foliage_selection,foliage_hash(recipe));
    VWB_EXPECT_EQ(10,NativeSavannaWorkerRecipe::RECIPE_VERSION);
    VWB_EXPECT_EQ(26.0,recipe.height);VWB_EXPECT_EQ(1.1,recipe.trunk_radius);VWB_EXPECT_EQ(8.0,recipe.canopy_radius);
    VWB_EXPECT_EQ(1.1,recipe.collision_trunk_radius);VWB_EXPECT(std::abs(recipe.collision_trunk_height-13.52)<1e-10);
    VWB_EXPECT_EQ(4.0F,recipe.interaction_world_position.x);VWB_EXPECT_EQ(0.5,recipe.interaction_world_rotation_y);
    VWB_EXPECT_EQ(350.0,recipe.render_visibility_range);VWB_EXPECT_EQ(170.0,recipe.render_shadow_range);
    VWB_EXPECT_EQ(1.25,recipe.render_wind_response);
    if(recipe.render_lod_tier=="impostor") {
        VWB_EXPECT_EQ(std::string("distance_impostor"),recipe.crown_habit);
        VWB_EXPECT_EQ(0,recipe.raw_recipe_version);VWB_EXPECT(recipe.methodology.empty());
    } else {
        VWB_EXPECT_EQ(std::string("wide_perforated_irregular_umbrella"),recipe.crown_habit);
        VWB_EXPECT_EQ(std::string("deterministic_raised_fork_allometric_axis_pipe_model"),recipe.methodology);
        VWB_EXPECT_EQ(2,recipe.raw_recipe_version);
        VWB_EXPECT(recipe.continuous_trunk_path && recipe.graph_connected && recipe.foliage_derived_from_fine_segments);
    }
    VWB_EXPECT_EQ(recipe.review,recipe.poc_continuous_wood);
    VWB_EXPECT_EQ(!recipe.review && !recipe.impostor,recipe.runtime_continuous_bole);
}
}

VWB_TEST(native_savanna_worker_matches_direct_godot_runtime_review_and_impostor_oracles) {
    const auto request=base();
    expect(request,{"tree-v10-7711f274","867f7f66",1066,1360,392,579,3848319808U,3006194853U});
    auto default_grammar=request;default_grammar.species_grammar="";
    VWB_EXPECT_EQ(NativeSavannaWorkerRecipeBuilder::build(request).signature,
        NativeSavannaWorkerRecipeBuilder::build(default_grammar).signature);
    const auto near=NativeSavannaWorkerRecipeBuilder::build(request);
    VWB_EXPECT_EQ(392,near.render_branch_budget);VWB_EXPECT_EQ(579,near.render_foliage_budget);
    VWB_EXPECT_EQ(1067,near.raw_node_count);VWB_EXPECT_EQ(6,near.raw_raised_fork_count);
    VWB_EXPECT_EQ(47,near.raw_crown_window_count);VWB_EXPECT_EQ(129,near.raw_viable_axis_bud_count);
    VWB_EXPECT_EQ(127,near.raw_germinated_axis_count);VWB_EXPECT_EQ(306,near.raw_grown_metamer_count);
    VWB_EXPECT_EQ(171,near.raw_pipe_junction_count);VWB_EXPECT_EQ(21,near.raw_occupied_crown_bins);
    VWB_EXPECT(std::abs(double(near.branches.front().end.x)+0.00819)<1e-5);
    VWB_EXPECT(std::abs(double(near.foliage.front().position.x)-2.101158)<1e-5);
    auto mid=request;mid.genetic_seed=-319;mid.growth_stage=0.12;mid.canopy_density=0.20;mid.render_lod_tier="mid";
    expect(mid,{"tree-v10-364fc0f2","732f9670",261,359,166,245,2016505376U,2411010596U});
    auto far=request;far.genetic_seed=-319;far.growth_stage=1.0;far.canopy_density=1.0;far.render_lod_tier="far";
    expect(far,{"tree-v10-8ab0c29d","4b4110ec",1073,1538,97,143,3652440710U,879389787U});
    auto review=request;review.presentation="review";
    expect(review,{"tree-v10-10473f65","867f7f66",1066,1360,1066,1360,1127306391U,124657246U});
    auto impostor=request;impostor.render_lod_tier="impostor";
    expect(impostor,{"tree-v10-4d8ed36e","impostor:oracle-world:oracle-tree:umbrella_thorn",0,0,0,0,2166136261U,2166136261U});
    VWB_EXPECT(NativeSavannaWorkerRecipeBuilder::build(impostor).impostor);
    auto review_impostor=impostor;review_impostor.presentation="review";
    expect(review_impostor,{"tree-v10-cc6cb734","impostor:oracle-world:oracle-tree:umbrella_thorn",0,0,0,0,2166136261U,2166136261U});
}

VWB_TEST(native_savanna_worker_normalizes_dimensions_identity_and_invalid_inputs) {
    auto request=base();request.tree_id="   ";VWB_EXPECT(!NativeSavannaWorkerRecipeBuilder::build(request).valid);
    request=base();request.tree_id="  oracle-tree  ";
    VWB_EXPECT_EQ(std::string("oracle-tree"),NativeSavannaWorkerRecipeBuilder::build(request).tree_id);
    request=base();request.architecture="conifer";
    VWB_EXPECT_THROW(std::invalid_argument,NativeSavannaWorkerRecipeBuilder::build(request));
    request=base();request.species_grammar="norway_spruce";
    VWB_EXPECT_THROW(std::invalid_argument,NativeSavannaWorkerRecipeBuilder::build(request));
    request=base();request.architecture="conifer";request.species_grammar="";
    VWB_EXPECT_THROW(std::invalid_argument,NativeSavannaWorkerRecipeBuilder::build(request));
    request=base();request.growth_stage=std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(std::invalid_argument,NativeSavannaWorkerRecipeBuilder::build(request));
    request=base();request.world_seed=" ";request.render_lod_tier="unknown";request.genetic_seed=0;
    request.visual_height=2;request.trunk_radius=0;request.canopy_radius=0;
    const auto normalized=NativeSavannaWorkerRecipeBuilder::build(request);
    VWB_EXPECT_EQ(std::string("default"),normalized.world_seed);VWB_EXPECT_EQ(std::string("near"),normalized.render_lod_tier);
    VWB_EXPECT_EQ(4.0,normalized.height);VWB_EXPECT_EQ(0.18,normalized.trunk_radius);
    VWB_EXPECT(std::abs(normalized.canopy_radius-0.396)<1e-12);
    VWB_EXPECT(normalized.genetic_seed!=0);
    request=base();request.genetic_seed=0;request.render_lod_tier="impostor";
    for(const std::string seed:{std::string("\x80",1),std::string("\xC3",1),std::string("\xC3\x41",2),
            std::string("\xC0\x80",2),std::string("\xE0\x80\x80",3),std::string("\xF0\x80\x80\x80",4),
            std::string("\xF4\x90\x80\x80",4),std::string("\xED\xA0\x80",3)}) {
        request.world_seed=seed;VWB_EXPECT_THROW(std::invalid_argument,NativeSavannaWorkerRecipeBuilder::build(request));
    }
    request.world_seed="caf\xC3\xA9";VWB_EXPECT(NativeSavannaWorkerRecipeBuilder::build(request).valid);
    request.world_seed="\xE2\x98\x83";VWB_EXPECT(NativeSavannaWorkerRecipeBuilder::build(request).valid);
    request.world_seed="\xF0\x9F\x8C\xB3";VWB_EXPECT(NativeSavannaWorkerRecipeBuilder::build(request).valid);
}
