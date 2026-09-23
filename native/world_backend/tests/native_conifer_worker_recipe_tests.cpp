#include "test_harness.hpp"
#include "../core/native_conifer_worker_recipe.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>

using namespace voxel::world_backend;

namespace {
NativeConiferWorkerRequest base() {
    NativeConiferWorkerRequest r;
    r.tree_id="oracle-tree";r.world_seed="oracle-world";r.biome="taiga";
    r.architecture="conifer";r.species_grammar="norway_spruce";
    r.genetic_seed=0x4D415448;r.growth_stage=0.92;
    r.visual_height=26;r.trunk_radius=1.1;r.canopy_radius=8;
    r.has_trunk_radius=true;r.has_canopy_radius=true;
    r.canopy_density=0.78;r.age_band="mature";r.age_years=55;
    r.render_lod_tier="near";r.presentation="runtime";
    r.world_position={4,5,6};r.world_rotation_y=0.5;
    auto &p=r.biome_parameters;
    p.version=2;p.architecture="conifer";p.height_min=18;p.height_max=60;
    p.trunk_radius_min=0.5;p.trunk_radius_max=3;p.canopy_radius_min=4;p.canopy_radius_max=18;
    p.canopy_density=0.88;p.wind_response=1.25;p.visibility_range=350;
    p.shadow_range=170;p.exclusion_margin=0.4;
    return r;
}
std::uint32_t branch_hash(const NativeConiferWorkerRecipe &r) {
    std::string value;
    for (const auto &b:r.branches) {if(!value.empty())value.push_back(',');value+=std::to_string(b.child_node);}
    return NativeConiferRecipeBuilder::stable_hash(value);
}
std::uint32_t foliage_hash(const NativeConiferWorkerRecipe &r) {
    std::string value;
    for (const auto &f:r.foliage) {if(!value.empty())value.push_back(',');value+=std::to_string(f.source_segment)+":"+std::to_string(f.cluster_variant);}
    return NativeConiferRecipeBuilder::stable_hash(value);
}
struct Expected {const char *signature,*topology;std::size_t source_b,source_f,branch,foliage;std::uint32_t bh,fh;};
void expect(const NativeConiferWorkerRequest &input,const Expected &e) {
    const auto r=NativeConiferWorkerRecipeBuilder::build(input);
    VWB_EXPECT(r.valid);
    VWB_EXPECT_EQ(std::string(e.signature),r.signature);
    VWB_EXPECT_EQ(std::string(e.topology),r.topology_signature);
    VWB_EXPECT_EQ(e.source_b,r.source_branch_count);
    VWB_EXPECT_EQ(e.source_f,r.source_foliage_count);
    VWB_EXPECT_EQ(e.branch,r.branches.size());
    VWB_EXPECT_EQ(e.foliage,r.foliage.size());
    VWB_EXPECT_EQ(e.bh,branch_hash(r));
    VWB_EXPECT_EQ(e.fh,foliage_hash(r));
    VWB_EXPECT_EQ(10,NativeConiferWorkerRecipe::RECIPE_VERSION);
    VWB_EXPECT_EQ(26.0,r.height);
    VWB_EXPECT_EQ(1.1,r.trunk_radius);
    VWB_EXPECT_EQ(8.0,r.canopy_radius);
    VWB_EXPECT_EQ(1.1,r.collision_trunk_radius);
    VWB_EXPECT(std::abs(r.collision_trunk_height-21.32)<1e-10);
    VWB_EXPECT_EQ(4.0F,r.interaction_world_position.x);
    VWB_EXPECT_EQ(0.5,r.interaction_world_rotation_y);
    VWB_EXPECT_EQ(350.0,r.render_visibility_range);
    VWB_EXPECT_EQ(170.0,r.render_shadow_range);
    VWB_EXPECT_EQ(1.25,r.render_wind_response);
}
}

VWB_TEST(native_conifer_worker_matches_direct_godot_runtime_review_and_impostor_oracles) {
    const auto r=base();
    expect(r,{"tree-v10-2b48259c","e190ed0f",640,850,390,579,687266255U,1325597174U});
    auto default_grammar=r;
    default_grammar.species_grammar="";
    VWB_EXPECT_EQ(NativeConiferWorkerRecipeBuilder::build(r).signature,
        NativeConiferWorkerRecipeBuilder::build(default_grammar).signature);
    default_grammar.architecture="savanna";
    bool rejected_nonconifer_default=false;
    try { (void)NativeConiferWorkerRecipeBuilder::build(default_grammar); }
    catch (const std::invalid_argument &) { rejected_nonconifer_default=true; }
    VWB_EXPECT(rejected_nonconifer_default);
    const auto near=NativeConiferWorkerRecipeBuilder::build(r);
    VWB_EXPECT_EQ(392,near.render_branch_budget);
    VWB_EXPECT_EQ(579,near.render_foliage_budget);
    VWB_EXPECT(std::abs(double(near.branches.front().end.x)-0.000194541411474347)<1e-9);
    VWB_EXPECT(std::abs(double(near.branches.front().end.y)-0.577777743339539)<1e-6);
    VWB_EXPECT(std::abs(near.branches.front().radius_start-1.364)<1e-9);
    VWB_EXPECT(std::abs(near.branches.front().wind_weight-0.0277777761220932)<1e-6);
    VWB_EXPECT(std::abs(double(near.foliage.front().position.x)+0.189013212919235)<1e-6);
    VWB_EXPECT(std::abs(double(near.foliage.front().position.y)-2.67899799346924)<1e-6);
    VWB_EXPECT(std::abs(double(near.foliage.front().scale.x)-1.00293910503387)<1e-6);
    VWB_EXPECT_EQ(0.2,near.foliage.front().wind_weight);
    auto mid=r;mid.genetic_seed=-319;mid.growth_stage=0.12;mid.canopy_density=0.20;mid.render_lod_tier="mid";
    expect(mid,{"tree-v10-4c9b0660","4824631d",222,264,166,245,1773086919U,2947440758U});
    auto far=r;far.genetic_seed=-319;far.growth_stage=1.0;far.canopy_density=1.0;far.render_lod_tier="far";
    expect(far,{"tree-v10-1f44cff9","f98fed7c",696,930,97,143,2189217266U,3246800653U});
    auto review=r;review.presentation="review";
    expect(review,{"tree-v10-849cc178","e190ed0f",640,850,640,850,3408954819U,1596307897U});
    const auto review_value=NativeConiferWorkerRecipeBuilder::build(review);
    VWB_EXPECT(review_value.review && !review_value.impostor);
    VWB_EXPECT_EQ(0,review_value.render_branch_budget);
    auto impostor=r;impostor.render_lod_tier="impostor";
    expect(impostor,{"tree-v10-2ad22efd","impostor:oracle-world:oracle-tree:norway_spruce",0,0,0,0,2166136261U,2166136261U});
    VWB_EXPECT(NativeConiferWorkerRecipeBuilder::build(impostor).impostor);
    auto review_impostor=impostor;review_impostor.presentation="review";
    expect(review_impostor,{"tree-v10-c1259613","impostor:oracle-world:oracle-tree:norway_spruce",0,0,0,0,2166136261U,2166136261U});
}

VWB_TEST(native_conifer_worker_matches_direct_godot_unicode_fallback_and_dimension_clamps) {
    auto r=base();r.genetic_seed=0;r.tree_id=" fallback-tree ";r.world_seed="caf\xC3\xA9";
    r.visual_height=2;r.trunk_radius=0;r.canopy_radius=0;r.has_trunk_radius=true;r.has_canopy_radius=true;
    r.canopy_density=0.05;r.render_lod_tier=" MID ";
    const auto value=NativeConiferWorkerRecipeBuilder::build(r);
    VWB_EXPECT(value.valid);
    VWB_EXPECT_EQ(std::string("tree-v10-7a4b6ac1"),value.signature);
    VWB_EXPECT_EQ(std::string("59d16c41"),value.topology_signature);
    VWB_EXPECT_EQ(std::size_t(910),value.source_branch_count);
    VWB_EXPECT_EQ(std::size_t(1274),value.source_foliage_count);
    VWB_EXPECT_EQ(std::size_t(166),value.branches.size());
    VWB_EXPECT_EQ(std::size_t(245),value.foliage.size());
    VWB_EXPECT_EQ(std::uint32_t(4142433393U),branch_hash(value));
    VWB_EXPECT_EQ(std::uint32_t(1720954754U),foliage_hash(value));
    VWB_EXPECT_EQ(std::string("fallback-tree"),value.tree_id);
    VWB_EXPECT_EQ(std::string("mid"),value.render_lod_tier);
    VWB_EXPECT_EQ(std::int64_t(2576194997LL),value.genetic_seed);
    VWB_EXPECT_EQ(4.0,value.height);
    VWB_EXPECT_EQ(0.18,value.trunk_radius);
    VWB_EXPECT(std::abs(value.canopy_radius-0.396)<1e-12);
    VWB_EXPECT_EQ(0.2,value.canopy_density);
    VWB_EXPECT(std::abs(double(value.branches.front().end.y)-0.0888888835906982)<1e-6);
    VWB_EXPECT(std::abs(double(value.foliage.front().position.y)-0.372757703065872)<1e-6);
}

VWB_TEST(native_conifer_worker_rejects_invalid_inputs_and_empty_identity) {
    auto r=base();r.tree_id="   ";
    VWB_EXPECT(!NativeConiferWorkerRecipeBuilder::build(r).valid);
    r=base();r.architecture="savanna";
    VWB_EXPECT_THROW(std::invalid_argument,NativeConiferWorkerRecipeBuilder::build(r));
    r=base();r.species_grammar="umbrella_thorn";
    VWB_EXPECT_THROW(std::invalid_argument,NativeConiferWorkerRecipeBuilder::build(r));
    r=base();r.growth_stage=std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(std::invalid_argument,NativeConiferWorkerRecipeBuilder::build(r));
    r=base();r.world_seed="\xC3";
    VWB_EXPECT_THROW(std::invalid_argument,NativeConiferWorkerRecipeBuilder::build(r));
    r=base();r.world_seed=" ";r.render_lod_tier="unknown";r.genetic_seed=0;
    VWB_EXPECT_EQ(std::string("default"),NativeConiferWorkerRecipeBuilder::build(r).world_seed);
    VWB_EXPECT_EQ(std::string("near"),NativeConiferWorkerRecipeBuilder::build(r).render_lod_tier);
}

VWB_TEST(native_conifer_worker_rejects_malformed_utf8_identity_and_accepts_unicode_scalars) {
    auto r=base();r.genetic_seed=0;r.render_lod_tier="impostor";
    for (const std::string seed:{
            std::string("\x80",1),std::string("\xC3",1),std::string("\xC3\x41",2),
            std::string("\xC0\x80",2),std::string("\xE0\x80\x80",3),
            std::string("\xF0\x80\x80\x80",4),std::string("\xF4\x90\x80\x80",4),
            std::string("\xED\xA0\x80",3)}) {
        r.world_seed=seed;
        VWB_EXPECT_THROW(std::invalid_argument,NativeConiferWorkerRecipeBuilder::build(r));
    }
    r.world_seed="caf\xC3\xA9";
    VWB_EXPECT(NativeConiferWorkerRecipeBuilder::build(r).valid);
    r.world_seed="\xE2\x98\x83";
    VWB_EXPECT(NativeConiferWorkerRecipeBuilder::build(r).valid);
    r.world_seed="\xF0\x9F\x8C\xB2";
    VWB_EXPECT(NativeConiferWorkerRecipeBuilder::build(r).valid);
}
