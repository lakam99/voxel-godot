#include "native_surface_prop_classifier.hpp"

#include <cmath>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfacePropClassifierRejected(); }

bool zero_digest(const Sha256Digest &digest) noexcept {
    for (const std::uint8_t byte : digest) if (byte != 0U) return false;
    return true;
}

bool valid_roll(const float value) noexcept {
    return std::isfinite(value) && value >= 0.0F && value < 1.0F;
}

bool valid_cutoff(const double value) noexcept {
    return std::isfinite(value) && value >= 0.0;
}

bool valid_admission(const NativeSurfacePropAdmission value) noexcept {
    return value == NativeSurfacePropAdmission::structure_blocked
        || value == NativeSurfacePropAdmission::surface_unavailable
        || value == NativeSurfacePropAdmission::surface_ineligible
        || value == NativeSurfacePropAdmission::town
        || value == NativeSurfacePropAdmission::eligible;
}

bool valid_tree_replay(const NativeSurfacePropTreeReplayMode value) noexcept {
    return value == NativeSurfacePropTreeReplayMode::none
        || value == NativeSurfacePropTreeReplayMode::legacy_36_draw
        || value == NativeSurfacePropTreeReplayMode::legacy_22_draw;
}

bool valid_ore_policy(const NativeSurfacePropOrePolicy value) noexcept {
    return value == NativeSurfacePropOrePolicy::none || value == NativeSurfacePropOrePolicy::eligible;
}

bool policy_is_empty(const NativeSurfacePropPlacementPolicy &policy) noexcept {
    return policy.rock_upper == 0.0 && policy.tree_upper == 0.0
        && policy.forage_upper == 0.0 && policy.wildlife_upper == 0.0
        && policy.tree_replay == NativeSurfacePropTreeReplayMode::none
        && policy.ore_policy == NativeSurfacePropOrePolicy::none
        && policy.iron_upper == 0.0 && policy.copper_upper == 0.0;
}

void validate_input(const NativeSurfacePropClassificationInput &input, const NativeSurfacePropAttempt &attempt) {
    if (input.ordinal != attempt.ordinal || input.cell_x != attempt.cell_x || input.cell_z != attempt.cell_z
        || attempt.durable_id.empty() || zero_digest(input.source_decision_digest)
        || !valid_admission(input.admission) || !valid_tree_replay(input.policy.tree_replay)
        || !valid_ore_policy(input.policy.ore_policy)) reject();
    if (input.admission != NativeSurfacePropAdmission::eligible) {
        if (!policy_is_empty(input.policy)) reject();
        return;
    }
    const NativeSurfacePropPlacementPolicy &policy = input.policy;
    if (!valid_cutoff(policy.rock_upper) || !valid_cutoff(policy.tree_upper)
        || !valid_cutoff(policy.forage_upper) || !valid_cutoff(policy.wildlife_upper)
        || policy.rock_upper > policy.tree_upper || policy.tree_upper > policy.forage_upper
        || policy.forage_upper > policy.wildlife_upper
        || policy.tree_replay == NativeSurfacePropTreeReplayMode::none) reject();
    if (policy.ore_policy == NativeSurfacePropOrePolicy::none) {
        if (policy.iron_upper != 0.0 || policy.copper_upper != 0.0) reject();
        return;
    }
    if (!valid_cutoff(policy.iron_upper) || !valid_cutoff(policy.copper_upper)
        || policy.iron_upper > policy.copper_upper) reject();
}

NativeSurfacePropClassification result(const NativeSurfacePropClassificationOutcome outcome,
    const bool consumes_prop_roll, const bool consumes_ore_roll = false) noexcept {
    return {outcome, consumes_prop_roll, consumes_ore_roll};
}

} // namespace

NativeSurfacePropClassifierRejected::NativeSurfacePropClassifierRejected()
    : std::invalid_argument("invalid native surface-prop classification receipt") {}

NativeSurfacePropClassification NativeSurfacePropClassifier::classify(
    const NativeSurfacePropClassificationInput &input, const NativeSurfacePropAttempt &attempt,
    const float prop_roll, const bool has_ore_roll, const float ore_roll) {
    validate_input(input, attempt);
    if (input.admission != NativeSurfacePropAdmission::eligible) {
        if (has_ore_roll) reject();
        return result(NativeSurfacePropClassificationOutcome::skipped_before_prop_roll, false);
    }
    if (!valid_roll(prop_roll)) reject();
    const NativeSurfacePropPlacementPolicy &policy = input.policy;
    if (prop_roll < policy.rock_upper) {
        if (policy.ore_policy == NativeSurfacePropOrePolicy::none) {
            if (has_ore_roll) reject();
            return result(NativeSurfacePropClassificationOutcome::ordinary_rock, true);
        }
        if (!has_ore_roll || !valid_roll(ore_roll)) reject();
        if (ore_roll < policy.iron_upper) {
            return result(NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster, true, true);
        }
        if (ore_roll < policy.copper_upper) {
            return result(NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster, true, true);
        }
        return result(NativeSurfacePropClassificationOutcome::ordinary_rock, true, true);
    }
    if (has_ore_roll) reject();
    if (prop_roll < policy.tree_upper) {
        return policy.tree_replay == NativeSurfacePropTreeReplayMode::legacy_36_draw
            ? result(NativeSurfacePropClassificationOutcome::tree_36_draw, true)
            : result(NativeSurfacePropClassificationOutcome::tree_22_draw, true);
    }
    if (prop_roll < policy.forage_upper) return result(NativeSurfacePropClassificationOutcome::forage_recipe, true);
    if (prop_roll < policy.wildlife_upper) return result(NativeSurfacePropClassificationOutcome::wildlife_recipe, true);
    return result(NativeSurfacePropClassificationOutcome::no_feature, true);
}

} // namespace voxel::world_backend
