#include "test_harness.hpp"

#include "../core/native_surface_prop_rng_trace.hpp"

#include <string>
#include <vector>

using namespace voxel::world_backend;

namespace {

NativeSurfacePropAttemptStream stream() {
    return NativeSurfacePropAttemptStream::create(admit_raw_terrain_seed("atlas-1492"), 0, 0);
}

NativeSurfacePropSourceReceipt source_receipt() {
    NativeSurfacePropSourceReceipt result;
    result.schema_revision = 1U;
    result.terrain_revision = 41U;
    result.terrain_digest.fill(1U);
    result.environment_profile_revision = 3U;
    result.environment_profile_digest.fill(2U);
    return result;
}

std::vector<NativeSurfacePropReplayReceipt> receipts(
    const NativeSurfacePropAttemptStream &source,
    const NativeSurfacePropReplayDisposition disposition = NativeSurfacePropReplayDisposition::no_feature) {
    std::vector<NativeSurfacePropReplayReceipt> result;
    result.reserve(source.attempts().size());
    for (const NativeSurfacePropAttempt &attempt : source.attempts()) {
        result.push_back({attempt.ordinal, attempt.durable_id, disposition});
    }
    return result;
}

} // namespace

VWB_TEST(native_surface_prop_rng_trace_replays_every_coordinate_and_no_feature_roll) {
    const NativeSurfacePropAttemptStream source = stream();
    const NativeSurfacePropRngTrace trace = NativeSurfacePropRngTrace::create(source, source_receipt(), receipts(source));
    VWB_EXPECT_EQ(41U, trace.source_receipt().terrain_revision);
    VWB_EXPECT_EQ(3U, trace.source_receipt().environment_profile_revision);
    VWB_EXPECT_EQ(source.attempts().size(), trace.entries().size());
    for (std::size_t index = 0U; index < trace.entries().size(); ++index) {
        const NativeSurfacePropRngTraceEntry &entry = trace.entries()[index];
        VWB_EXPECT_EQ(index, static_cast<std::size_t>(entry.ordinal));
        VWB_EXPECT_EQ(NativeSurfacePropReplayDisposition::no_feature, entry.disposition);
        VWB_EXPECT(entry.state_before_coordinates != entry.state_after_coordinates);
        VWB_EXPECT(entry.has_prop_roll);
        VWB_EXPECT(entry.prop_roll >= 0.0F && entry.prop_roll < 1.0F);
        VWB_EXPECT(entry.recipe_draws.empty());
        VWB_EXPECT(entry.state_after_coordinates != entry.state_after_recipe);
    }
    VWB_EXPECT(trace.final_rng_state() != source.final_rng_state());
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('S'), trace.canonical_binary()[0]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('P'), trace.canonical_binary()[1]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('T'), trace.canonical_binary()[2]);
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('1'), trace.canonical_binary()[3]);
}

VWB_TEST(native_surface_prop_rng_trace_preserves_exact_class_compatibility_draw_counts) {
    const NativeSurfacePropAttemptStream source = stream();
    std::vector<NativeSurfacePropReplayReceipt> input = receipts(source);
    input[0].disposition = NativeSurfacePropReplayDisposition::skipped_before_prop_roll;
    input[1].disposition = NativeSurfacePropReplayDisposition::ordinary_rock;
    input[2].disposition = NativeSurfacePropReplayDisposition::broadleaf_tree;
    input[3].disposition = NativeSurfacePropReplayDisposition::conifer_tree;
    const NativeSurfacePropRngTrace trace = NativeSurfacePropRngTrace::create(source, source_receipt(), input);
    VWB_EXPECT(!trace.entries()[0].has_prop_roll);
    VWB_EXPECT_EQ(NativeSurfacePropReplayDisposition::skipped_before_prop_roll, trace.entries()[0].disposition);
    VWB_EXPECT(trace.entries()[0].recipe_draws.empty());
    VWB_EXPECT_EQ(6U, trace.entries()[1].recipe_draws.size());
    VWB_EXPECT_EQ(36U, trace.entries()[2].recipe_draws.size());
    VWB_EXPECT_EQ(22U, trace.entries()[3].recipe_draws.size());
    VWB_EXPECT(trace.entries()[1].state_after_recipe != trace.entries()[1].state_after_coordinates);
    VWB_EXPECT(trace.entries()[2].state_after_recipe != trace.entries()[2].state_after_coordinates);
    VWB_EXPECT(trace.entries()[3].state_after_recipe != trace.entries()[3].state_after_coordinates);
    VWB_EXPECT(trace.final_rng_state() != NativeSurfacePropRngTrace::create(source, source_receipt(), receipts(source)).final_rng_state());
    const NativeSurfacePropRngTrace baseline = NativeSurfacePropRngTrace::create(source, source_receipt(), receipts(source));
    VWB_EXPECT(trace.content_digest() != baseline.content_digest());
    NativeSurfacePropSourceReceipt changed_source = source_receipt();
    ++changed_source.terrain_revision;
    VWB_EXPECT(baseline.content_digest()
        != NativeSurfacePropRngTrace::create(source, changed_source, receipts(source)).content_digest());
}

VWB_TEST(native_surface_prop_rng_trace_rejects_incomplete_unbound_and_unknown_receipts) {
    const NativeSurfacePropAttemptStream source = stream();
    std::vector<NativeSurfacePropReplayReceipt> input = receipts(source);
    input.pop_back();
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, source_receipt(), input));
    input = receipts(source); input[4].ordinal = 7U;
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, source_receipt(), input));
    input = receipts(source); input[4].durable_id += ":wrong";
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, source_receipt(), input));
    input = receipts(source); input[4].disposition = static_cast<NativeSurfacePropReplayDisposition>(99);
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, source_receipt(), input));

    NativeSurfacePropSourceReceipt malformed = source_receipt(); malformed.schema_revision = 0U;
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, malformed, receipts(source)));
    malformed = source_receipt(); malformed.terrain_revision = 0U;
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, malformed, receipts(source)));
    malformed = source_receipt(); malformed.terrain_digest = {};
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, malformed, receipts(source)));
    malformed = source_receipt(); malformed.environment_profile_revision = 0U;
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, malformed, receipts(source)));
    malformed = source_receipt(); malformed.environment_profile_digest = {};
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, malformed, receipts(source)));
}
