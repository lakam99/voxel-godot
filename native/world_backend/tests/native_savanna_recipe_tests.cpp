#include "test_harness.hpp"

#include "../core/native_savanna_recipe.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>

using namespace voxel::world_backend;

namespace {
void expect_germinated_axes_within_span_cap(const NativeSavannaRecipe &recipe) {
    VWB_EXPECT(recipe.grown_metamer_count>=0);
    const std::size_t first=recipe.branches.size()-static_cast<std::size_t>(recipe.grown_metamer_count);
    const double cap=recipe.canopy_radius*1.08+0.00002; // explicit float-coordinate tolerance
    for(std::size_t index=first;index<recipe.branches.size();++index) {
        const auto &end=recipe.branches[index].end;
        const double x=double(end.x)-double(recipe.crown_center.x);
        const double z=double(end.z)-double(recipe.crown_center.z);
        VWB_EXPECT(std::hypot(x,z)<=cap);
    }
}
}

namespace voxel::world_backend {
struct NativeSavannaRecipeTestAccess final {
    static NativeSavannaRecipe build(std::int64_t seed,double maturity,int segments,int scaffold,int foliage) {
        return NativeSavannaRecipeBuilder::build_with_limits(seed,maturity,segments,scaffold,foliage);
    }
    static NativeSavannaRecipe boundary_fixture(std::int64_t seed) {
        return NativeSavannaRecipeBuilder::build_boundary_guard_fixture_for_test(seed);
    }
};
}

VWB_TEST(native_savanna_recipe_matches_direct_godot_mature_oracle) {
    const auto recipe=NativeSavannaRecipeBuilder::build(0x53415641,0.92);
    VWB_EXPECT_EQ(2,NativeSavannaRecipe::RECIPE_VERSION);
    VWB_EXPECT_EQ(std::int64_t(0x53415641),recipe.seed);
    VWB_EXPECT_EQ(std::string("867f7f66"),recipe.signature);
    VWB_EXPECT_EQ(std::size_t(1066),recipe.branches.size());
    VWB_EXPECT_EQ(std::size_t(1360),recipe.foliage.size());
    VWB_EXPECT_EQ(1067,recipe.node_count);
    VWB_EXPECT_EQ(6,recipe.raised_fork_count);
    VWB_EXPECT_EQ(47,recipe.crown_window_count);
    VWB_EXPECT_EQ(129,recipe.viable_axis_bud_count);
    VWB_EXPECT_EQ(127,recipe.germinated_axis_count);
    VWB_EXPECT_EQ(306,recipe.grown_metamer_count);
    VWB_EXPECT_EQ(171,recipe.pipe_junction_count);
    VWB_EXPECT_EQ(21,recipe.occupied_crown_bins);
    VWB_EXPECT_EQ(10,recipe.segment_counts_by_order[0]);
    VWB_EXPECT_EQ(21,recipe.segment_counts_by_order[1]);
    VWB_EXPECT_EQ(285,recipe.segment_counts_by_order[2]);
    VWB_EXPECT_EQ(465,recipe.segment_counts_by_order[3]);
    VWB_EXPECT_EQ(285,recipe.segment_counts_by_order[4]);
    VWB_EXPECT(std::abs(recipe.height-29.2724245950038)<1e-9);
    VWB_EXPECT(std::abs(recipe.trunk_radius-2.4638139384057)<1e-9);
    VWB_EXPECT(std::abs(recipe.canopy_radius-23.3298939496764)<1e-9);
    VWB_EXPECT(std::abs(double(recipe.branches.front().end.x)+0.023883)<1e-5);
    VWB_EXPECT(std::abs(double(recipe.branches.front().end.y)-0.874626)<1e-5);
    VWB_EXPECT_EQ(1,recipe.foliage.front().cluster_variant);
    VWB_EXPECT_EQ(194,recipe.foliage.front().source_segment);
    VWB_EXPECT_EQ(4,recipe.foliage.front().source_order);
    VWB_EXPECT(recipe.branches.size()<=1120 && recipe.foliage.size()<=1540);
    expect_germinated_axes_within_span_cap(recipe);
}

VWB_TEST(native_savanna_recipe_matches_direct_godot_age_and_seed_oracles) {
    const auto young=NativeSavannaRecipeBuilder::build(-319,0.12);
    const auto repeated=NativeSavannaRecipeBuilder::build(-319,0.12);
    const auto other=NativeSavannaRecipeBuilder::build(320,0.12);
    const auto old=NativeSavannaRecipeBuilder::build(-319,1.0);
    VWB_EXPECT_EQ(std::string("732f9670"),young.signature);
    VWB_EXPECT_EQ(std::size_t(261),young.branches.size());
    VWB_EXPECT_EQ(std::size_t(359),young.foliage.size());
    VWB_EXPECT_EQ(std::string("f322c90d"),other.signature);
    VWB_EXPECT_EQ(std::size_t(370),other.branches.size());
    VWB_EXPECT_EQ(std::size_t(426),other.foliage.size());
    VWB_EXPECT_EQ(std::string("4b4110ec"),old.signature);
    VWB_EXPECT_EQ(std::size_t(1073),old.branches.size());
    VWB_EXPECT_EQ(std::size_t(1538),old.foliage.size());
    expect_germinated_axes_within_span_cap(young);
    expect_germinated_axes_within_span_cap(other);
    expect_germinated_axes_within_span_cap(old);
    VWB_EXPECT_EQ(young.signature,repeated.signature);
    VWB_EXPECT(young.height<old.height);
    VWB_EXPECT_EQ(young.signature,NativeSavannaRecipeBuilder::build(-319,-1.0).signature);
    VWB_EXPECT_EQ(old.signature,NativeSavannaRecipeBuilder::build(-319,2.0).signature);
    VWB_EXPECT_THROW(std::invalid_argument,NativeSavannaRecipeBuilder::build(
        1,std::numeric_limits<double>::quiet_NaN()));
}

VWB_TEST(native_savanna_recipe_test_limits_cover_bounded_growth_and_foliage) {
    const auto scaffold=NativeSavannaRecipeTestAccess::build(81,0.12,1120,1,1);
    VWB_EXPECT(scaffold.branches.size()>=7);
    VWB_EXPECT(scaffold.foliage.size()<=1);
    for(int cap=8;cap<=80;++cap) {
        const auto bounded=NativeSavannaRecipeTestAccess::build(81,0.12,cap,760,1);
        VWB_EXPECT(bounded.branches.size()>=7);
        VWB_EXPECT(bounded.foliage.size()<=1);
    }
    const auto foliage=NativeSavannaRecipeTestAccess::build(81,0.92,1120,760,2);
    VWB_EXPECT_EQ(std::size_t(2),foliage.foliage.size());
    for(int scaffold_cap:{8,9}) {
        const auto bounded=NativeSavannaRecipeTestAccess::build(81,0.12,1120,scaffold_cap,1);
        VWB_EXPECT(bounded.branches.size()>=7);
    }
    for(int segment_cap=761;segment_cap<=764;++segment_cap) {
        const auto bounded=NativeSavannaRecipeTestAccess::build(0x53415641,0.92,segment_cap,760,1);
        VWB_EXPECT(bounded.branches.size()<=static_cast<std::size_t>(segment_cap));
    }
    const auto boundary=NativeSavannaRecipeTestAccess::boundary_fixture(81);
    VWB_EXPECT_EQ(0,boundary.grown_metamer_count);
    VWB_EXPECT_EQ(std::size_t(1),boundary.branches.size());
}
