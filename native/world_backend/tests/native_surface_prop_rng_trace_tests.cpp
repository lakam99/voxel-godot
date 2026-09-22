#include "test_harness.hpp"

#include "../core/native_surface_prop_rng_trace.hpp"
#include "../core/native_terrain_shaping_registry.hpp"

#include <algorithm>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

NativeSurfacePropAttemptStream stream() {
    return NativeSurfacePropAttemptStream::create(admit_raw_terrain_seed("atlas-1492"), 0, 0);
}

NativeSurfacePropSourceReceipt source_receipt() {
    NativeSurfacePropSourceReceipt result;
    result.effective_source_digest.fill(1U);
    result.terrain_delta_revision = 41U;
    result.shaping_registry_revision = 17U;
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

WorldSourcePin admitted_pin() {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    descriptor.revisions.terrain_generator_revision = 8U;
    descriptor.revisions.lattice_query_revision = 6U;
    descriptor.revisions.cell_center_query_revision = 7U;
    descriptor.revisions.surface_column_query_revision = 8U;
    WorldSourceDefinition definition(std::move(descriptor));
    NativeSiteSourcePolicy policy;
    policy.engine_version_utf8 = "4.6.1.stable.official.14d19694e";
    policy.ordinary_region_cells = 140;
    policy.ordinary_spawn_chance = 0.08;
    NativeTerrainShapingRegistry registry(definition, policy);
    const NativeTerrainPageKey page{0, 0};
    const auto dependencies = world_effective_shaping_dependencies(definition, page);
    std::vector<NativeSiteSourceRegionKey> unresolved;
    for (const auto dependency : dependencies) {
        for (const auto region : registry.pin_page(dependency).unresolved_dependencies()) {
            if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end()) unresolved.push_back(region);
        }
    }
    NativeTerrainShapingRegistryBatch batch;
    batch.expected_revision = registry.revision();
    for (const auto region : unresolved) {
        NativeSiteSourceResolution resolution;
        resolution.region = region;
        resolution.kind = NativeSiteSourceResolutionKind::absent;
        resolution.request_identity = registry.source_request_identity(region);
        resolution.worker_source_key.assign(64, 'a');
        resolution.reason_code = "ordinary_structure_overlap";
        batch.resolutions.push_back(std::move(resolution));
    }
    if (!batch.resolutions.empty()) (void)registry.apply(batch);
    std::vector<NativeTerrainShapingPagePin> shaping;
    for (const auto dependency : dependencies) shaping.push_back(registry.pin_page(dependency));
    WorldDeltaStore deltas;
    return WorldSourcePin(definition, deltas.pin(), page, shaping);
}

} // namespace

VWB_TEST(native_surface_prop_rng_trace_replays_every_coordinate_and_no_feature_roll) {
    const NativeSurfacePropAttemptStream source = stream();
    const NativeSurfacePropRngTrace trace = NativeSurfacePropRngTrace::create(source, source_receipt(), receipts(source));
    VWB_EXPECT_EQ(41U, trace.source_receipt().terrain_delta_revision);
    VWB_EXPECT_EQ(17U, trace.source_receipt().shaping_registry_revision);
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
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('2'), trace.canonical_binary()[3]);
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
    ++changed_source.terrain_delta_revision;
    VWB_EXPECT(baseline.content_digest()
        != NativeSurfacePropRngTrace::create(source, changed_source, receipts(source)).content_digest());
    changed_source = source_receipt(); ++changed_source.shaping_registry_revision;
    VWB_EXPECT(baseline.content_digest()
        != NativeSurfacePropRngTrace::create(source, changed_source, receipts(source)).content_digest());
    changed_source = source_receipt(); changed_source.effective_source_digest[0] ^= 1U;
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
    malformed = source_receipt(); malformed.schema_revision = 1U;
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, malformed, receipts(source)));
    malformed = source_receipt(); malformed.effective_source_digest = {};
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, malformed, receipts(source)));
    malformed = source_receipt(); malformed.environment_profile_revision = 0U;
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, malformed, receipts(source)));
    malformed = source_receipt(); malformed.environment_profile_digest = {};
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected, NativeSurfacePropRngTrace::create(source, malformed, receipts(source)));
}

VWB_TEST(native_surface_prop_rng_trace_source_receipt_is_bound_to_one_admitted_pin_and_catalog) {
    const WorldSourcePin pin = admitted_pin();
    Sha256Digest catalog{}; catalog.fill(0x5aU);
    const auto receipt = NativeSurfacePropSourceReceipt::from_pin(pin, 3U, catalog);
    VWB_EXPECT_EQ(NativeSurfacePropSourceReceipt::SCHEMA_REVISION, receipt.schema_revision);
    VWB_EXPECT_EQ(pin.physical_content_identity().digest, receipt.effective_source_digest);
    VWB_EXPECT_EQ(pin.terrain_delta_revision(), receipt.terrain_delta_revision);
    VWB_EXPECT_EQ(pin.shaping_registry_revision(), receipt.shaping_registry_revision);
    VWB_EXPECT_EQ(3U, receipt.environment_profile_revision);
    VWB_EXPECT_EQ(catalog, receipt.environment_profile_digest);
    VWB_EXPECT(receipt.matches_pin(pin));
    auto changed = receipt; ++changed.terrain_delta_revision;
    VWB_EXPECT(!changed.matches_pin(pin));
    changed = receipt; ++changed.shaping_registry_revision;
    VWB_EXPECT(!changed.matches_pin(pin));
    changed = receipt; changed.effective_source_digest[0] ^= 1U;
    VWB_EXPECT(!changed.matches_pin(pin));
    changed = receipt; changed.environment_profile_digest = {};
    VWB_EXPECT(!changed.matches_pin(pin));
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected,
        NativeSurfacePropSourceReceipt::from_pin(pin, 0U, catalog));
    VWB_EXPECT_THROW(NativeSurfacePropRngTraceRejected,
        NativeSurfacePropSourceReceipt::from_pin(pin, 3U, {}));
    const auto source = stream();
    const auto trace = NativeSurfacePropRngTrace::create(source, receipt, receipts(source));
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('2'), trace.canonical_binary()[3]);
}
