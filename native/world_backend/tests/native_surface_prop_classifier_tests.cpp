#include "test_harness.hpp"

#include "../core/native_surface_prop_classifier.hpp"

#include <limits>

using namespace voxel::world_backend;

namespace {

NativeSurfacePropAttempt attempt() {
    return NativeSurfacePropAttempt{7U, -12, 29, "seed:-12,29:7"};
}

NativeSurfacePropClassificationInput input() {
    NativeSurfacePropClassificationInput result;
    result.ordinal = 7U;
    result.cell_x = -12;
    result.cell_z = 29;
    result.source_decision_digest.fill(7U);
    result.admission = NativeSurfacePropAdmission::eligible;
    result.policy.rock_upper = 0.10F;
    result.policy.tree_upper = 0.30F;
    result.policy.forage_upper = 0.50F;
    result.policy.wildlife_upper = 0.70F;
    result.policy.tree_replay = NativeSurfacePropTreeReplayMode::legacy_36_draw;
    return result;
}

void expect_outcome(const NativeSurfacePropClassificationOutcome expected,
    const NativeSurfacePropClassification &actual, const bool prop = true, const bool ore = false) {
    VWB_EXPECT_EQ(expected, actual.outcome);
    VWB_EXPECT_EQ(prop, actual.consumes_prop_roll);
    VWB_EXPECT_EQ(ore, actual.consumes_ore_roll);
}

} // namespace

VWB_TEST(native_surface_prop_classifier_respects_authoritative_admission_before_the_prop_roll) {
    for (const NativeSurfacePropAdmission admission : {
            NativeSurfacePropAdmission::structure_blocked,
            NativeSurfacePropAdmission::surface_unavailable,
            NativeSurfacePropAdmission::surface_ineligible,
            NativeSurfacePropAdmission::town}) {
        NativeSurfacePropClassificationInput receipt = input();
        receipt.admission = admission;
        receipt.policy = {};
        expect_outcome(NativeSurfacePropClassificationOutcome::skipped_before_prop_roll,
            NativeSurfacePropClassifier::classify(receipt, attempt(), 0.99F), false);
    }
}

VWB_TEST(native_surface_prop_classifier_uses_strict_cumulative_source_cutoffs_without_recomputing_them) {
    const NativeSurfacePropClassificationInput receipt = input();
    expect_outcome(NativeSurfacePropClassificationOutcome::ordinary_rock,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.099F));
    expect_outcome(NativeSurfacePropClassificationOutcome::tree_36_draw,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.10F));
    expect_outcome(NativeSurfacePropClassificationOutcome::forage_recipe,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.30F));
    expect_outcome(NativeSurfacePropClassificationOutcome::wildlife_recipe,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.50F));
    expect_outcome(NativeSurfacePropClassificationOutcome::no_feature,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.70F));
    NativeSurfacePropClassificationInput saturated = receipt;
    saturated.policy.wildlife_upper = 1.4F;
    expect_outcome(NativeSurfacePropClassificationOutcome::wildlife_recipe,
        NativeSurfacePropClassifier::classify(saturated, attempt(), 0.99F));
    saturated.policy.tree_replay = NativeSurfacePropTreeReplayMode::legacy_22_draw;
    expect_outcome(NativeSurfacePropClassificationOutcome::tree_22_draw,
        NativeSurfacePropClassifier::classify(saturated, attempt(), 0.10F));
}

VWB_TEST(native_surface_prop_classifier_models_the_live_ore_roll_as_a_separate_unported_recipe_boundary) {
    NativeSurfacePropClassificationInput receipt = input();
    receipt.policy.ore_policy = NativeSurfacePropOrePolicy::eligible;
    receipt.policy.iron_upper = 0.25F;
    receipt.policy.copper_upper = 0.60F;
    expect_outcome(NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.01F, true, 0.249F), true, true);
    expect_outcome(NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.01F, true, 0.25F), true, true);
    expect_outcome(NativeSurfacePropClassificationOutcome::ordinary_rock,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.01F, true, 0.60F), true, true);
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.01F));
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(input(), attempt(), 0.01F, true, 0.2F));
}

VWB_TEST(native_surface_prop_classifier_rejects_unbound_noncanonical_or_nonfinite_receipts) {
    NativeSurfacePropClassificationInput receipt = input();
    receipt.ordinal = 8U;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.cell_z = 30;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.source_decision_digest = {};
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.tree_upper = 0.05F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.tree_replay = NativeSurfacePropTreeReplayMode::none;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.ore_policy = NativeSurfacePropOrePolicy::none; receipt.policy.iron_upper = 0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.ore_policy = NativeSurfacePropOrePolicy::eligible; receipt.policy.iron_upper = 0.7F; receipt.policy.copper_upper = 0.6F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.rock_upper = std::numeric_limits<float>::infinity();
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input();
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), std::numeric_limits<float>::quiet_NaN()));
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F, true, std::numeric_limits<float>::infinity()));
}

VWB_TEST(native_surface_prop_classifier_exhaustively_rejects_receipt_and_roll_boundary_alternatives) {
    NativeSurfacePropClassificationInput receipt = input();
    NativeSurfacePropAttempt unbound = attempt(); unbound.cell_x = -11;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, unbound, 0.2F));
    unbound = attempt(); unbound.durable_id.clear();
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, unbound, 0.2F));
    receipt = input(); receipt.admission = static_cast<NativeSurfacePropAdmission>(99); receipt.policy = {};
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.tree_replay = static_cast<NativeSurfacePropTreeReplayMode>(99);
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.ore_policy = static_cast<NativeSurfacePropOrePolicy>(99);
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));

    receipt = input(); receipt.admission = NativeSurfacePropAdmission::town; receipt.policy = {}; receipt.policy.rock_upper = 0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.admission = NativeSurfacePropAdmission::town; receipt.policy = {}; receipt.policy.tree_upper = 0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.admission = NativeSurfacePropAdmission::town; receipt.policy = {}; receipt.policy.forage_upper = 0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.admission = NativeSurfacePropAdmission::town; receipt.policy = {}; receipt.policy.wildlife_upper = 0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.admission = NativeSurfacePropAdmission::town; receipt.policy = {};
    receipt.policy.tree_replay = NativeSurfacePropTreeReplayMode::legacy_36_draw;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.admission = NativeSurfacePropAdmission::town; receipt.policy = {};
    receipt.policy.ore_policy = NativeSurfacePropOrePolicy::eligible;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.admission = NativeSurfacePropAdmission::town; receipt.policy = {}; receipt.policy.iron_upper = 0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.admission = NativeSurfacePropAdmission::town; receipt.policy = {}; receipt.policy.copper_upper = 0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));

    receipt = input(); receipt.policy.rock_upper = -0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.tree_upper = -0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.forage_upper = -0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.wildlife_upper = -0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.forage_upper = 0.2F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.wildlife_upper = 0.4F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.copper_upper = 0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.ore_policy = NativeSurfacePropOrePolicy::eligible;
    receipt.policy.iron_upper = -0.1F; receipt.policy.copper_upper = 0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.ore_policy = NativeSurfacePropOrePolicy::eligible;
    receipt.policy.copper_upper = -0.1F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F));
    receipt = input(); receipt.policy.ore_policy = NativeSurfacePropOrePolicy::eligible;
    receipt.policy.iron_upper = 0.1F; receipt.policy.copper_upper = 0.2F;
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.01F, true, std::numeric_limits<float>::infinity()));

    receipt = input(); receipt.admission = NativeSurfacePropAdmission::town; receipt.policy = {};
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(receipt, attempt(), 0.2F, true, 0.2F));
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(input(), attempt(), -0.1F));
    VWB_EXPECT_THROW(NativeSurfacePropClassifierRejected,
        NativeSurfacePropClassifier::classify(input(), attempt(), 1.0F));
}
