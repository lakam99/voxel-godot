#include "test_harness.hpp"

#include "../core/native_surface_prop_placement_set.hpp"

#include <array>
#include <cstdint>
#include <limits>

using namespace voxel::world_backend;

namespace {

NativeForageRecipe berry_recipe() {
    return {"berry", "berryBush", "berries", 2, 4, 0.50F,
        NativeForageGrammar::berry, NativeForageNavigationPolicy::blocking};
}

NativeWildlifeStreamInput boar_wildlife() {
    NativeWildlifeStreamInput result;
    result.biome = NativeWildlifeBiomeGroup::other;
    result.presentation.schema_revision = 1U;
    result.presentation.asset_catalog_digest.fill(1U);
    result.presentation.variant = NativeWildlifeVariant::boar;
    result.presentation.asset_id = "boar_idle_walk";
    result.presentation.animation_clip_id = "boar_idle_walk";
    result.presentation.path = NativeWildlifePresentationPath::animated_playable;
    return result;
}

NativeSurfacePropBaselineInput input_for(const NativeSurfacePropAttempt &attempt) {
    NativeSurfacePropBaselineInput result;
    result.classification.ordinal = attempt.ordinal;
    result.classification.cell_x = attempt.cell_x;
    result.classification.cell_z = attempt.cell_z;
    result.classification.source_decision_digest.fill(static_cast<std::uint8_t>(attempt.ordinal + 1U));
    result.classification.admission = NativeSurfacePropAdmission::eligible;
    result.classification.policy.tree_family = NativeSurfacePropTreeCompatibilityFamily::broadleaf_36_draw;
    return result;
}

std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT>
inputs_for(const NativeSurfacePropAttemptStream &attempts) {
    std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> inputs{};
    for (std::size_t index = 0U; index < inputs.size(); ++index) inputs[index] = input_for(attempts.attempts()[index]);
    inputs[0].classification.policy.wildlife_upper = 1.0F; inputs[0].wildlife = boar_wildlife();
    inputs[1].classification.policy.forage_upper = 1.0F; inputs[1].classification.policy.wildlife_upper = 1.0F;
    inputs[1].forage_recipe = berry_recipe();
    inputs[2].classification.policy.rock_upper = 1.0F; inputs[2].classification.policy.tree_upper = 1.0F;
    inputs[2].classification.policy.forage_upper = 1.0F; inputs[2].classification.policy.wildlife_upper = 1.0F;
    inputs[3].classification.policy.tree_upper = 1.0F; inputs[3].classification.policy.forage_upper = 1.0F;
    inputs[3].classification.policy.wildlife_upper = 1.0F;
    inputs[4].classification.policy.tree_upper = 1.0F; inputs[4].classification.policy.forage_upper = 1.0F;
    inputs[4].classification.policy.wildlife_upper = 1.0F;
    inputs[4].classification.policy.tree_family = NativeSurfacePropTreeCompatibilityFamily::conifer_22_draw;
    inputs[5].classification.policy.rock_upper = 1.0F; inputs[5].classification.policy.tree_upper = 1.0F;
    inputs[5].classification.policy.forage_upper = 1.0F; inputs[5].classification.policy.wildlife_upper = 1.0F;
    inputs[5].classification.policy.ore_policy = NativeSurfacePropOrePolicy::eligible;
    inputs[5].classification.policy.iron_upper = 1.0F; inputs[5].classification.policy.copper_upper = 1.0F;
    inputs[6].classification.policy.rock_upper = 1.0F; inputs[6].classification.policy.tree_upper = 1.0F;
    inputs[6].classification.policy.forage_upper = 1.0F; inputs[6].classification.policy.wildlife_upper = 1.0F;
    inputs[6].classification.policy.ore_policy = NativeSurfacePropOrePolicy::eligible;
    inputs[6].classification.policy.copper_upper = 1.0F;
    inputs[7].classification.admission = NativeSurfacePropAdmission::town; inputs[7].classification.policy = {};
    return inputs;
}

NativeSurfacePropAttemptStream attempts() {
    return NativeSurfacePropAttemptStream::create(admit_raw_terrain_seed("placement-set"), -3, 2);
}

NativeSurfacePropSourceReceipt source_receipt() {
    NativeSurfacePropSourceReceipt result;
    result.schema_revision = 1U; result.terrain_revision = 42U; result.terrain_digest.fill(3U);
    result.environment_profile_revision = 7U; result.environment_profile_digest.fill(4U);
    return result;
}

WorldSourceDefinition world_source() {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("placement-set");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("placement-set");
    descriptor.revisions.terrain_generator_revision = 3U;
    descriptor.revisions.lattice_query_revision = 5U;
    return WorldSourceDefinition(std::move(descriptor));
}

std::array<NativeSurfacePropPlacementReceipt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT>
receipts_for(const NativeSurfacePropAttemptStream &attempt_stream, const NativeSurfacePropBaselineStream &baseline) {
    std::array<NativeSurfacePropPlacementReceipt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> receipts{};
    for (std::size_t index = 0U; index < receipts.size(); ++index) {
        const NativeSurfacePropAttempt &attempt = attempt_stream.attempts()[index];
        NativeSurfacePropPlacementReceipt &receipt = receipts[index];
        receipt.ordinal = attempt.ordinal;
        const NativeSurfacePropClassificationOutcome outcome = baseline.entries()[index].outcome;
        if (outcome != NativeSurfacePropClassificationOutcome::skipped_before_prop_roll
            && outcome != NativeSurfacePropClassificationOutcome::no_feature) {
            receipt.presence = NativeSurfacePropPlacementPresence::anchored;
            receipt.solid_cell = {attempt.cell_x, static_cast<std::int32_t>(10 + index), attempt.cell_z};
            receipt.air_cell = {attempt.cell_x, static_cast<std::int32_t>(11 + index), attempt.cell_z};
        }
    }
    return receipts;
}

NativeSurfacePropBaselineStream baseline_for(const NativeSurfacePropAttemptStream &attempt_stream) {
    return NativeSurfacePropBaselineStream::create(attempt_stream, inputs_for(attempt_stream));
}

NativeSurfacePropPlacementSet placement_set(
    const NativeSurfacePropAttemptStream &attempt_stream,
    const NativeSurfacePropBaselineStream &baseline,
    const std::array<NativeSurfacePropPlacementReceipt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &receipts) {
    return NativeSurfacePropPlacementSet::create(attempt_stream, baseline, source_receipt(), world_source(), receipts);
}

} // namespace

VWB_TEST(native_surface_prop_placement_set_binds_all_typed_outcomes_to_lattice_surface_pairs) {
    const NativeSurfacePropAttemptStream source = attempts();
    const NativeSurfacePropBaselineStream baseline = baseline_for(source);
    const auto receipts = receipts_for(source, baseline);
    const NativeSurfacePropPlacementSet set = placement_set(source, baseline, receipts);
    VWB_EXPECT_EQ(source_receipt().terrain_revision, set.source_receipt().terrain_revision);
    VWB_EXPECT_EQ(world_source().physical_content_identity(), set.world_source_identity());
    VWB_EXPECT_EQ(NativeSurfacePropAttemptStream::ATTEMPT_COUNT, set.entries().size());
    VWB_EXPECT(!set.canonical_binary().empty());
    VWB_EXPECT_EQ(sha256(set.canonical_binary()), set.content_digest());
    for (std::size_t index = 0U; index < set.entries().size(); ++index) {
        const NativeSurfacePropPlacementEntry &entry = set.entries()[index];
        const NativeSurfacePropAttempt &attempt = source.attempts()[index];
        VWB_EXPECT_EQ(attempt.ordinal, entry.ordinal); VWB_EXPECT_EQ(attempt.durable_id, entry.durable_id);
        VWB_EXPECT_EQ(attempt.cell_x, entry.cell_x); VWB_EXPECT_EQ(attempt.cell_z, entry.cell_z);
        VWB_EXPECT_EQ(baseline.entries()[index].source_decision_digest, entry.source_decision_digest);
        if (entry.presence == NativeSurfacePropPlacementPresence::anchored) {
            const WorldFloat32Position expected = resolve_world_query(world_source(),
                WorldLatticeQuery{entry.air_cell, WorldQueryIntent::gameplay}).lattice_position;
            VWB_EXPECT_EQ(expected.x, entry.world_anchor.x); VWB_EXPECT_EQ(expected.y, entry.world_anchor.y);
            VWB_EXPECT_EQ(expected.z, entry.world_anchor.z);
        } else {
            VWB_EXPECT_EQ((CellCoord{}), entry.solid_cell); VWB_EXPECT_EQ((CellCoord{}), entry.air_cell);
        }
    }
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::anchored, set.entries()[0].presence);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::anchored, set.entries()[1].presence);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::anchored, set.entries()[2].presence);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::anchored, set.entries()[3].presence);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::anchored, set.entries()[4].presence);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::anchored, set.entries()[5].presence);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::anchored, set.entries()[6].presence);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::absent, set.entries()[7].presence);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::absent, set.entries()[8].presence);
}

VWB_TEST(native_surface_prop_placement_set_is_deterministic_and_tracks_each_source_identity) {
    const NativeSurfacePropAttemptStream source = attempts(); const NativeSurfacePropBaselineStream baseline = baseline_for(source);
    const auto receipts = receipts_for(source, baseline);
    const NativeSurfacePropPlacementSet first = placement_set(source, baseline, receipts);
    const NativeSurfacePropPlacementSet second = placement_set(source, baseline, receipts);
    VWB_EXPECT_EQ(first.canonical_binary(), second.canonical_binary()); VWB_EXPECT_EQ(first.content_digest(), second.content_digest());
    NativeSurfacePropSourceReceipt changed_source = source_receipt(); ++changed_source.terrain_revision;
    const NativeSurfacePropPlacementSet changed_receipt = NativeSurfacePropPlacementSet::create(
        source, baseline, changed_source, world_source(), receipts);
    VWB_EXPECT(first.content_digest() != changed_receipt.content_digest());
    WorldSourceDescriptor changed_descriptor;
    changed_descriptor.raw_terrain_seed = admit_raw_terrain_seed("placement-set");
    changed_descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("placement-set");
    changed_descriptor.constants.cell_size_meters = 1.4;
    const NativeSurfacePropPlacementSet changed_world = NativeSurfacePropPlacementSet::create(
        source, baseline, source_receipt(), WorldSourceDefinition(changed_descriptor), receipts);
    VWB_EXPECT(first.content_digest() != changed_world.content_digest());
}

VWB_TEST(native_surface_prop_placement_set_rejects_unbound_or_incoherent_surface_receipts) {
    const NativeSurfacePropAttemptStream source = attempts(); NativeSurfacePropBaselineStream baseline = baseline_for(source);
    const auto receipts = receipts_for(source, baseline);
    const auto rejects = [&](const NativeSurfacePropBaselineStream &value,
        const NativeSurfacePropSourceReceipt &receipt,
        const std::array<NativeSurfacePropPlacementReceipt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &candidate) {
        VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
            NativeSurfacePropPlacementSet::create(source, value, receipt, world_source(), candidate));
    };
    NativeSurfacePropSourceReceipt bad_source = source_receipt(); bad_source.schema_revision = 0U; rejects(baseline, bad_source, receipts);
    bad_source = source_receipt(); bad_source.terrain_revision = 0U; rejects(baseline, bad_source, receipts);
    bad_source = source_receipt(); bad_source.terrain_digest = {}; rejects(baseline, bad_source, receipts);
    bad_source = source_receipt(); bad_source.environment_profile_revision = 0U; rejects(baseline, bad_source, receipts);
    bad_source = source_receipt(); bad_source.environment_profile_digest = {}; rejects(baseline, bad_source, receipts);
    auto malformed = receipts; malformed[0].ordinal = 1U; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[0].presence = NativeSurfacePropPlacementPresence::absent; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[7].presence = NativeSurfacePropPlacementPresence::anchored; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[7].solid_cell = {1, 0, 0}; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[7].solid_cell = {0, 1, 0}; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[7].solid_cell = {0, 0, 1}; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[7].air_cell = {1, 0, 0}; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[7].air_cell = {0, 1, 0}; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[7].air_cell = {0, 0, 1}; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[0].solid_cell.x++; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[0].solid_cell.z++; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[0].air_cell.x++; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[0].air_cell.z++; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[0].air_cell.y++; rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[0].solid_cell.y = std::numeric_limits<std::int32_t>::max();
    malformed[0].air_cell.y = std::numeric_limits<std::int32_t>::min(); rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[0].presence = static_cast<NativeSurfacePropPlacementPresence>(99); rejects(baseline, source_receipt(), malformed);
    malformed = receipts; malformed[7].presence = static_cast<NativeSurfacePropPlacementPresence>(99); rejects(baseline, source_receipt(), malformed);
    auto &corrupt = const_cast<NativeSurfacePropBaselineEntry &>(baseline.entries()[0]);
    corrupt.source_decision_digest = {}; rejects(baseline, source_receipt(), receipts);
    corrupt.source_decision_digest.fill(1U); corrupt.outcome = static_cast<NativeSurfacePropClassificationOutcome>(99);
    rejects(baseline, source_receipt(), receipts);
}

VWB_TEST(native_surface_prop_placement_set_rejects_every_cross_stream_identity_mismatch) {
    const auto rejects = [](NativeSurfacePropAttemptStream &source, NativeSurfacePropBaselineStream &baseline,
        const std::array<NativeSurfacePropPlacementReceipt, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &receipts) {
        VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
            NativeSurfacePropPlacementSet::create(source, baseline, source_receipt(), world_source(), receipts));
    };
    {
        auto source = attempts(); auto baseline = baseline_for(source); const auto receipts = receipts_for(source, baseline);
        auto &attempt = const_cast<NativeSurfacePropAttempt &>(source.attempts()[0]); attempt.ordinal = 99U;
        rejects(source, baseline, receipts);
    }
    for (const int mutation : {0, 1, 2, 3}) {
        auto source = attempts(); auto baseline = baseline_for(source); const auto receipts = receipts_for(source, baseline);
        auto &entry = const_cast<NativeSurfacePropBaselineEntry &>(baseline.entries()[0]);
        if (mutation == 0) entry.ordinal = 99U;
        else if (mutation == 1) entry.durable_id += "mismatch";
        else if (mutation == 2) ++entry.cell_x;
        else ++entry.cell_z;
        rejects(source, baseline, receipts);
    }
    {
        auto source = attempts(); auto baseline = baseline_for(source); const auto receipts = receipts_for(source, baseline);
        WorldSourceDefinition definition = world_source();
        auto &identity = const_cast<WorldPhysicalContentIdentity &>(definition.physical_content_identity());
        identity.digest = {};
        VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
            NativeSurfacePropPlacementSet::create(source, baseline, source_receipt(), definition, receipts));
    }
}
