#include "test_harness.hpp"
#include "../core/native_conifer_recipe.hpp"

#include <cmath>
#include <limits>
#include <stdexcept>

using namespace voxel::world_backend;

namespace voxel::world_backend {
struct NativeConiferRecipeTestAccess final {
    static NativeConiferRecipe build(std::int64_t seed, double maturity,
        int segment_limit, int foliage_limit) {
        return NativeConiferRecipeBuilder::build_with_limits(seed, maturity,
            segment_limit, foliage_limit);
    }
};
}

// Frozen from direct Godot `native_conifer_recipe_oracle.gd` output, not
// generated from the C++ implementation. Signatures fold every source-order
// branch's quantized endpoints/radii/order and every needle position/order.
VWB_TEST(native_conifer_recipe_matches_direct_godot_mature_oracle) {
    const auto recipe = NativeConiferRecipeBuilder::build(0x4D415448, 0.92);
    VWB_EXPECT_EQ(2, NativeConiferRecipe::RECIPE_VERSION);
    VWB_EXPECT_EQ(std::int64_t(0x4D415448), recipe.seed);
    VWB_EXPECT_EQ(std::string("e190ed0f"), recipe.signature);
    VWB_EXPECT_EQ(std::size_t(640), recipe.branches.size());
    VWB_EXPECT_EQ(std::size_t(850), recipe.foliage.size());
    VWB_EXPECT_EQ(641, recipe.node_count);
    VWB_EXPECT_EQ(14, recipe.whorl_count);
    VWB_EXPECT_EQ(15, recipe.interstitial_spray_count);
    VWB_EXPECT_EQ(205, recipe.support_driven_branchlet_count);
    VWB_EXPECT_EQ(49, recipe.occupied_crown_bins);
    VWB_EXPECT_EQ(45, recipe.segment_counts_by_order[0]);
    VWB_EXPECT_EQ(155, recipe.segment_counts_by_order[1]);
    VWB_EXPECT_EQ(220, recipe.segment_counts_by_order[2]);
    VWB_EXPECT_EQ(220, recipe.segment_counts_by_order[3]);
    VWB_EXPECT_EQ(0, recipe.segment_counts_by_order[4]);
    VWB_EXPECT(std::abs(recipe.height - 52.518834154547) < 1e-9);
    VWB_EXPECT(std::abs(recipe.trunk_radius - 2.06476587650956) < 1e-9);
    VWB_EXPECT(std::abs(recipe.canopy_radius - 14.1796540067937) < 1e-9);
    VWB_EXPECT_EQ(recipe.branches.size() + 1, static_cast<std::size_t>(recipe.node_count));
    VWB_EXPECT_EQ(0, recipe.branches.front().parent_node);
    VWB_EXPECT_EQ(1, recipe.branches.front().child_node);
    VWB_EXPECT(recipe.branches.size() <= 1120 && recipe.foliage.size() <= 1480);
    for (const auto &f : recipe.foliage) {
        VWB_EXPECT(f.source_segment >= 0 && f.source_segment < static_cast<int>(recipe.branches.size()));
        VWB_EXPECT(f.source_order >= 2);
    }
}

VWB_TEST(native_conifer_recipe_matches_direct_godot_young_and_old_oracles) {
    const auto young = NativeConiferRecipeBuilder::build(-319, 0.12);
    const auto again = NativeConiferRecipeBuilder::build(-319, 0.12);
    const auto other_seed = NativeConiferRecipeBuilder::build(320, 0.12);
    const auto old = NativeConiferRecipeBuilder::build(-319, 1.0);
    VWB_EXPECT_EQ(std::string("4824631d"), young.signature);
    VWB_EXPECT_EQ(std::size_t(222), young.branches.size());
    VWB_EXPECT_EQ(std::size_t(264), young.foliage.size());
    VWB_EXPECT_EQ(std::string("d15cd93e"), other_seed.signature);
    VWB_EXPECT_EQ(std::size_t(241), other_seed.branches.size());
    VWB_EXPECT_EQ(std::size_t(294), other_seed.foliage.size());
    VWB_EXPECT_EQ(std::string("f98fed7c"), old.signature);
    VWB_EXPECT_EQ(std::size_t(696), old.branches.size());
    VWB_EXPECT_EQ(std::size_t(930), old.foliage.size());
    VWB_EXPECT_EQ(young.signature, again.signature);
    VWB_EXPECT(young.whorl_count < old.whorl_count);
    VWB_EXPECT(young.height < old.height);
    VWB_EXPECT_EQ(young.signature, NativeConiferRecipeBuilder::build(-319, -1.0).signature);
    VWB_EXPECT_EQ(old.signature, NativeConiferRecipeBuilder::build(-319, 2.0).signature);
    VWB_EXPECT_THROW(std::invalid_argument, NativeConiferRecipeBuilder::build(1, std::numeric_limits<double>::quiet_NaN()));
}

VWB_TEST(native_conifer_stable_hash_matches_known_ascii_fnv) {
    VWB_EXPECT_EQ(std::uint32_t(0x811C9DC5), NativeConiferRecipeBuilder::stable_hash(""));
    VWB_EXPECT_EQ(std::uint32_t(0xE40C292C), NativeConiferRecipeBuilder::stable_hash("a"));
}

VWB_TEST(native_conifer_synthetic_small_caps_exercise_source_limit_retention) {
    // Test-only limits feed the exact build implementation through a private
    // friend seam. Production always uses the frozen 1120/1480 grammar caps;
    // these synthetic graphs are not gameplay or Godot parity evidence.
    const auto before_whorls = NativeConiferRecipeTestAccess::build(81, 0.12, 1, 1);
    VWB_EXPECT_EQ(0, before_whorls.interstitial_spray_count);
    VWB_EXPECT(before_whorls.branches.size() > 1);
    for (int cap = 24; cap <= 600; ++cap) {
        const auto bounded = NativeConiferRecipeTestAccess::build(81, 0.12, cap, 1);
        VWB_EXPECT(bounded.branches.size() >= 24);
        VWB_EXPECT(bounded.foliage.size() <= 1);
    }
    for (int cap = 46; cap <= 150; ++cap) {
        const auto bounded = NativeConiferRecipeTestAccess::build(0x4D415448, 0.92, cap, 1);
        VWB_EXPECT(bounded.foliage.size() <= 1);
    }
    const auto foliage_cap = NativeConiferRecipeTestAccess::build(81, 0.92, 1120, 2);
    VWB_EXPECT_EQ(std::size_t(2), foliage_cap.foliage.size());
}
