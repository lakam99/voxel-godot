#include "test_harness.hpp"
#include "../core/native_ore_cluster_stream.hpp"
using namespace voxel::world_backend;
VWB_TEST(native_ore_cluster_stream_preserves_all_child_draws_without_tombstone_shortcuts) {
    GodotPcg32 rng(177U); const auto stream = NativeOreClusterStream::create("seed:1,2:3", NativeOreKind::iron, rng);
    VWB_EXPECT_EQ(std::string("seed:1,2:3"), stream.children()[0].durable_id);
    VWB_EXPECT_EQ(std::string("seed:1,2:3:cluster1"), stream.children()[1].durable_id);
    VWB_EXPECT_EQ(47U, stream.children()[0].float_draws.size()); VWB_EXPECT_EQ(48U, stream.children()[1].float_draws.size());
    VWB_EXPECT(stream.children()[0].state_before != stream.children()[0].state_after);
    VWB_EXPECT_EQ(stream.children()[0].state_after, stream.children()[1].state_before);
    VWB_EXPECT_EQ(stream.children()[1].state_after, stream.final_rng_state());
    VWB_EXPECT(stream.children()[0].drop_count >= 1 && stream.children()[0].drop_count <= 2);
}
VWB_TEST(native_ore_cluster_stream_distinguishes_kind_range_and_rejects_invalid_admission) {
    GodotPcg32 copper_rng(177U); const auto copper = NativeOreClusterStream::create("id", NativeOreKind::copper, copper_rng);
    VWB_EXPECT(copper.children()[0].drop_count >= 1 && copper.children()[0].drop_count <= 3);
    GodotPcg32 bad_rng(1U);
    VWB_EXPECT_THROW(NativeOreClusterStreamRejected, NativeOreClusterStream::create("", NativeOreKind::iron, bad_rng));
    VWB_EXPECT_THROW(NativeOreClusterStreamRejected, NativeOreClusterStream::create("id", static_cast<NativeOreKind>(99), bad_rng));
}
VWB_TEST(native_ore_cluster_stream_checks_each_child_tombstone_before_recipe_draws) {
    // Child zero has the parent ID. The live caller rejects that tombstone
    // before entering make_ore_cluster; first/both cases here exercise only
    // this helper's gate. Child one is the reachable within-cluster deletion.
    const auto make_removed = [](const bool first, const bool second) {
        std::vector<NativeFeatureTombstone> ids;
        if (first) ids.push_back({"ore"});
        if (second) ids.push_back({"ore:cluster1"});
        return NativeFeatureDeltaSnapshot::create(std::move(ids), {});
    };
    GodotPcg32 intact_rng(177U);
    const auto intact = NativeOreClusterStream::create("ore", NativeOreKind::iron, make_removed(false, false), intact_rng);
    GodotPcg32 legacy_rng(177U);
    const auto legacy = NativeOreClusterStream::create("ore", NativeOreKind::iron, legacy_rng);
    VWB_EXPECT_EQ(legacy.final_rng_state(), intact.final_rng_state());
    GodotPcg32 first_rng(177U);
    const auto first = NativeOreClusterStream::create("ore", NativeOreKind::iron, make_removed(true, false), first_rng);
    GodotPcg32 second_rng(177U);
    const auto second = NativeOreClusterStream::create("ore", NativeOreKind::iron, make_removed(false, true), second_rng);
    GodotPcg32 both_rng(177U);
    const auto both = NativeOreClusterStream::create("ore", NativeOreKind::iron, make_removed(true, true), both_rng);
    VWB_EXPECT(!intact.children()[0].skipped_by_tombstone && !intact.children()[1].skipped_by_tombstone);
    VWB_EXPECT(first.children()[0].skipped_by_tombstone && !first.children()[1].skipped_by_tombstone);
    VWB_EXPECT(!second.children()[0].skipped_by_tombstone && second.children()[1].skipped_by_tombstone);
    VWB_EXPECT(both.children()[0].skipped_by_tombstone && both.children()[1].skipped_by_tombstone);
    VWB_EXPECT_EQ(0U, first.children()[0].float_draws.size());
    VWB_EXPECT_EQ(0U, second.children()[1].float_draws.size());
    VWB_EXPECT_EQ(first.children()[0].state_before, first.children()[0].state_after);
    VWB_EXPECT_EQ(second.children()[1].state_before, second.children()[1].state_after);
    VWB_EXPECT_EQ(both.children()[0].state_before, both.final_rng_state());
    VWB_EXPECT_EQ(intact.children()[0].state_after, second.final_rng_state());
    VWB_EXPECT_EQ(first.children()[0].state_after, first.children()[1].state_before);
    VWB_EXPECT(first.final_rng_state() != intact.final_rng_state());
    VWB_EXPECT(second.final_rng_state() != intact.final_rng_state());
    VWB_EXPECT(first.final_rng_state() != second.final_rng_state());
    GodotPcg32 unrelated_rng(177U);
    const auto unrelated = NativeOreClusterStream::create("ore", NativeOreKind::iron,
        NativeFeatureDeltaSnapshot::create({{"other"}}, {}), unrelated_rng);
    VWB_EXPECT_EQ(intact.final_rng_state(), unrelated.final_rng_state());
}
