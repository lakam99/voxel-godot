#include "test_harness.hpp"

#include "../core/godot_pcg_compat.hpp"
#include "../core/native_detail_ordered_plan.hpp"
#include "../core/legacy_seed_hash.hpp"

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

std::uint32_t detail_seed(const std::string &text, std::int32_t cx, std::int32_t cz) {
    const auto admitted = admit_raw_terrain_seed(text);
    std::vector<std::uint32_t> key = admitted.code_points;
    const std::string suffix = ":details:" + std::to_string(cx) + "," + std::to_string(cz);
    for (unsigned char byte : suffix) key.push_back(byte);
    return legacy_seed_hash(key);
}

std::vector<NativeDetailAttemptFacts> blocked_facts(const std::string &seed, std::int32_t cx,
    std::int32_t cz) {
    GodotPcg32 rng(detail_seed(seed, cx, cz));
    std::vector<NativeDetailAttemptFacts> result;
    for (std::uint32_t ordinal = 0; ordinal < 8U; ++ordinal) {
        NativeDetailAttemptFacts fact;
        fact.ordinal = ordinal;
        fact.cell_x = cx * 28 + 1 + static_cast<std::int32_t>(rng.randi_range(0, 26));
        fact.cell_z = cz * 28 + 1 + static_cast<std::int32_t>(rng.randi_range(0, 26));
        fact.blocked = true;
        result.push_back(std::move(fact));
    }
    return result;
}

} // namespace

VWB_TEST(native_detail_ordered_plan_advances_separate_rng_across_blocked_attempts) {
    const auto seed = admit_raw_terrain_seed("atlas-1492");
    const NativeDetailQuality quality{1.0, 8};
    const auto facts = blocked_facts(seed.utf8, -1, 2);
    const auto plan = NativeDetailOrderedPlan::create(seed, -1, 2, quality, facts);
    VWB_EXPECT_EQ(8U, plan.attempts().size());
    GodotPcg32 expected(detail_seed(seed.utf8, -1, 2));
    for (std::size_t ordinal = 0; ordinal < facts.size(); ++ordinal) {
        const auto &row = plan.attempts()[ordinal];
        VWB_EXPECT_EQ(ordinal, row.ordinal);
        VWB_EXPECT_EQ(expected.state(), row.state_before_coordinates);
        VWB_EXPECT_EQ(facts[ordinal].cell_x, row.cell_x);
        VWB_EXPECT_EQ(facts[ordinal].cell_z, row.cell_z);
        static_cast<void>(expected.randi_range(0, 26));
        static_cast<void>(expected.randi_range(0, 26));
        VWB_EXPECT_EQ(expected.state(), row.state_after_coordinates);
        VWB_EXPECT_EQ(expected.state(), row.state_after_attempt);
        VWB_EXPECT(row.transforms.empty());
    }
    VWB_EXPECT_EQ(expected.state(), plan.final_rng_state());
}

VWB_TEST(native_detail_ordered_plan_rejects_stale_or_incomplete_value_facts) {
    const auto seed = admit_raw_terrain_seed("atlas-1492");
    auto facts = blocked_facts(seed.utf8, 0, 0);
    facts[2].cell_x += 1;
    VWB_EXPECT_THROW(NativeDetailOrderedPlanRejected,
        NativeDetailOrderedPlan::create(seed, 0, 0, {1.0, 8}, facts));
    facts = blocked_facts(seed.utf8, 0, 0);
    facts.pop_back();
    VWB_EXPECT_THROW(NativeDetailOrderedPlanRejected,
        NativeDetailOrderedPlan::create(seed, 0, 0, {1.0, 8}, facts));
    facts = blocked_facts(seed.utf8, 0, 0);
    facts[0].blocked = false;
    facts[0].surface_found = true;
    facts[0].surface_height = 25.0;
    facts[0].biome = "forest";
    VWB_EXPECT_THROW(NativeDetailOrderedPlanRejected,
        NativeDetailOrderedPlan::create(seed, 0, 0, {1.0, 8}, facts));
}

VWB_TEST(native_detail_ordered_plan_accepts_disabled_quality_without_sampling) {
    const auto plan = NativeDetailOrderedPlan::create(admit_raw_terrain_seed("atlas-1492"),
        0, 0, {0.0, 72}, {});
    VWB_EXPECT(plan.attempts().empty());
}
