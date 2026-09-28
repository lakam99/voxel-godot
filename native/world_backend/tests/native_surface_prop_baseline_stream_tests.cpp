#include "test_harness.hpp"

#include "../core/native_surface_prop_baseline_stream.hpp"

using namespace voxel::world_backend;

namespace voxel::world_backend::tests {

struct NativeSurfacePropBaselineStreamTestAccess final {
    static std::size_t compatibility_draw_count(const NativeSurfacePropClassificationOutcome outcome) {
        return NativeSurfacePropBaselineStream::compatibility_draw_count(outcome);
    }
};

} // namespace voxel::world_backend::tests

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
    result.classification.source_decision_digest.fill(1U);
    result.classification.admission = NativeSurfacePropAdmission::eligible;
    result.classification.policy.tree_replay = NativeSurfacePropTreeReplayMode::legacy_36_draw;
    return result;
}

std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT>
inputs_for(const NativeSurfacePropAttemptStream &attempts) {
    std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> inputs{};
    for (std::size_t index = 0U; index < inputs.size(); ++index) {
        inputs[index] = input_for(attempts.attempts()[index]);
    }
    inputs[0].classification.policy.wildlife_upper = 1.0F;
    inputs[0].wildlife = boar_wildlife();
    inputs[1].classification.policy.forage_upper = 1.0F;
    inputs[1].classification.policy.wildlife_upper = 1.0F;
    inputs[1].forage_recipe = berry_recipe();
    inputs[2].classification.policy.rock_upper = 1.0F;
    inputs[2].classification.policy.tree_upper = 1.0F;
    inputs[2].classification.policy.forage_upper = 1.0F;
    inputs[2].classification.policy.wildlife_upper = 1.0F;
    inputs[3].classification.policy.tree_upper = 1.0F;
    inputs[3].classification.policy.forage_upper = 1.0F;
    inputs[3].classification.policy.wildlife_upper = 1.0F;
    inputs[4].classification.policy.tree_upper = 1.0F;
    inputs[4].classification.policy.forage_upper = 1.0F;
    inputs[4].classification.policy.wildlife_upper = 1.0F;
    inputs[4].classification.policy.tree_replay = NativeSurfacePropTreeReplayMode::legacy_22_draw;
    inputs[5].classification.policy.rock_upper = 1.0F;
    inputs[5].classification.policy.tree_upper = 1.0F;
    inputs[5].classification.policy.forage_upper = 1.0F;
    inputs[5].classification.policy.wildlife_upper = 1.0F;
    inputs[5].classification.policy.ore_policy = NativeSurfacePropOrePolicy::eligible;
    inputs[5].classification.policy.iron_upper = 1.0F;
    inputs[5].classification.policy.copper_upper = 1.0F;
    inputs[6].classification.policy.rock_upper = 1.0F;
    inputs[6].classification.policy.tree_upper = 1.0F;
    inputs[6].classification.policy.forage_upper = 1.0F;
    inputs[6].classification.policy.wildlife_upper = 1.0F;
    inputs[6].classification.policy.ore_policy = NativeSurfacePropOrePolicy::eligible;
    inputs[6].classification.policy.copper_upper = 1.0F;
    inputs[7].classification.admission = NativeSurfacePropAdmission::town;
    inputs[7].classification.policy = {};
    return inputs;
}

NativeSurfacePropAttemptStream attempts() {
    return NativeSurfacePropAttemptStream::create(admit_raw_terrain_seed("baseline-stream"), 0, 0);
}

} // namespace

VWB_TEST(native_surface_prop_baseline_stream_replays_every_typed_recipe_family) {
    const NativeSurfacePropAttemptStream source = attempts();
    const NativeSurfacePropBaselineStream stream = NativeSurfacePropBaselineStream::create(source, inputs_for(source));
    const auto &entries = stream.entries();
    VWB_EXPECT_EQ(source.attempts()[0].ordinal, entries[0].ordinal);
    VWB_EXPECT_EQ(source.attempts()[0].cell_x, entries[0].cell_x);
    VWB_EXPECT_EQ(source.attempts()[0].cell_z, entries[0].cell_z);
    VWB_EXPECT_EQ(source.attempts()[0].durable_id, entries[0].durable_id);
    VWB_EXPECT_EQ(inputs_for(source)[0].classification.source_decision_digest, entries[0].source_decision_digest);
    VWB_EXPECT_EQ(NativeSurfacePropAdmission::eligible, entries[0].admission);
    VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::wildlife_recipe, entries[0].outcome);
    VWB_EXPECT(entries[0].wildlife.has_value());
    VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::forage_recipe, entries[1].outcome);
    VWB_EXPECT(entries[1].forage.has_value());
    VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::ordinary_rock, entries[2].outcome);
    VWB_EXPECT_EQ(6U, entries[2].compatibility_draws.size());
    VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::tree_36_draw, entries[3].outcome);
    VWB_EXPECT_EQ(36U, entries[3].compatibility_draws.size());
    VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::tree_22_draw, entries[4].outcome);
    VWB_EXPECT_EQ(22U, entries[4].compatibility_draws.size());
    VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster, entries[5].outcome);
    VWB_EXPECT(entries[5].ore_roll.has_value());
    VWB_EXPECT(entries[5].ore_cluster.has_value());
    VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster, entries[6].outcome);
    VWB_EXPECT(entries[6].ore_cluster.has_value());
    VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::skipped_before_prop_roll, entries[7].outcome);
    VWB_EXPECT(!entries[7].prop_roll.has_value());
    VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::no_feature, entries[8].outcome);
    for (std::size_t index = 0U; index + 1U < entries.size(); ++index) {
        VWB_EXPECT_EQ(entries[index].state_after_recipe, entries[index + 1U].state_before_coordinates);
    }
    VWB_EXPECT_EQ(entries.back().state_after_recipe, stream.final_rng_state());
}

VWB_TEST(native_surface_prop_baseline_stream_is_deterministic_and_rejects_ambiguous_recipe_receipts) {
    const NativeSurfacePropAttemptStream source = attempts();
    const auto inputs = inputs_for(source);
    const NativeSurfacePropBaselineStream first = NativeSurfacePropBaselineStream::create(source, inputs);
    const NativeSurfacePropBaselineStream second = NativeSurfacePropBaselineStream::create(source, inputs);
    VWB_EXPECT_EQ(first.final_rng_state(), second.final_rng_state());
    VWB_EXPECT_EQ(first.entries()[0].state_after_recipe, second.entries()[0].state_after_recipe);

    auto malformed = inputs;
    malformed[1].forage_recipe.reset();
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        NativeSurfacePropBaselineStream::create(source, malformed));
    malformed = inputs;
    malformed[1].wildlife = boar_wildlife();
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        NativeSurfacePropBaselineStream::create(source, malformed));
    malformed = inputs;
    malformed[1].forage_recipe->drop_id = "invalid";
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        NativeSurfacePropBaselineStream::create(source, malformed));
    malformed = inputs;
    malformed[0].forage_recipe = berry_recipe();
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        NativeSurfacePropBaselineStream::create(source, malformed));
    malformed = inputs;
    malformed[0].wildlife.reset();
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        NativeSurfacePropBaselineStream::create(source, malformed));
    malformed = inputs;
    malformed[8].forage_recipe = berry_recipe();
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        NativeSurfacePropBaselineStream::create(source, malformed));
    malformed = inputs;
    malformed[8].wildlife = boar_wildlife();
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        NativeSurfacePropBaselineStream::create(source, malformed));
    malformed = inputs;
    malformed[0].wildlife->presentation.variant = NativeWildlifeVariant::hare;
    malformed[0].wildlife->presentation.asset_id = "hare_idle_walk";
    malformed[0].wildlife->presentation.animation_clip_id = "hare_idle_walk";
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        NativeSurfacePropBaselineStream::create(source, malformed));
    malformed = inputs;
    malformed[0].classification.ordinal = 99U;
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        NativeSurfacePropBaselineStream::create(source, malformed));
}

VWB_TEST(native_surface_prop_baseline_stream_rejects_corrupt_internal_outcome) {
    VWB_EXPECT_THROW(NativeSurfacePropBaselineStreamRejected,
        voxel::world_backend::tests::NativeSurfacePropBaselineStreamTestAccess::compatibility_draw_count(
            static_cast<NativeSurfacePropClassificationOutcome>(0U)));
}
