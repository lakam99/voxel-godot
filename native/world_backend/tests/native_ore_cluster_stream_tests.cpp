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
