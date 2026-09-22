#include "native_surface_prop_baseline_stream.hpp"

#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() { throw NativeSurfacePropBaselineStreamRejected(); }

bool needs_ore_roll(const NativeSurfacePropBaselineInput &input, const float prop_roll) {
    // compose only reaches this helper after consuming an eligible prop roll.
    // Keeping that precondition at the call site avoids duplicating admission
    // authority and makes this predicate solely about the rock/ore policy.
    return prop_roll < input.classification.policy.rock_upper
        && input.classification.policy.ore_policy == NativeSurfacePropOrePolicy::eligible;
}

void validate_recipe_presence(const NativeSurfacePropBaselineInput &input,
    const NativeSurfacePropClassificationOutcome outcome) {
    const bool forage = input.forage_recipe.has_value();
    const bool wildlife = input.wildlife.has_value();
    if (outcome == NativeSurfacePropClassificationOutcome::forage_recipe) {
        if (!forage || wildlife) reject();
        return;
    }
    if (outcome == NativeSurfacePropClassificationOutcome::wildlife_recipe) {
        if (forage || !wildlife) reject();
        return;
    }
    if (forage || wildlife) reject();
}

} // namespace

NativeSurfacePropBaselineStream::ComposedBaseline NativeSurfacePropBaselineStream::compose(
    const NativeSurfacePropAttemptStream &attempts,
    const std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &inputs,
    GodotPcg32 &rng) {
    std::array<NativeSurfacePropBaselineEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries{};
    for (std::size_t index = 0U; index < entries.size(); ++index) {
        const NativeSurfacePropBaselineInput &input = inputs[index];
        NativeSurfacePropBaselineEntry entry;
        const NativeSurfacePropAttempt &attempt = attempts.attempts()[index];
        entry.ordinal = attempt.ordinal;
        entry.cell_x = attempt.cell_x;
        entry.cell_z = attempt.cell_z;
        entry.durable_id = attempt.durable_id;
        entry.source_decision_digest = input.classification.source_decision_digest;
        entry.admission = input.classification.admission;
        entry.state_before_coordinates = rng.state();
        static_cast<void>(rng.randi_range(0, NativeSurfacePropAttemptStream::CHUNK_CELLS - 4));
        static_cast<void>(rng.randi_range(0, NativeSurfacePropAttemptStream::CHUNK_CELLS - 4));
        entry.state_after_coordinates = rng.state();
        float prop_roll = 0.0F;
        float ore_roll = 0.0F;
        bool has_ore_roll = false;
        if (input.classification.admission == NativeSurfacePropAdmission::eligible) {
            prop_roll = rng.randf();
            entry.prop_roll = prop_roll;
            if (needs_ore_roll(input, prop_roll)) {
                ore_roll = rng.randf();
                has_ore_roll = true;
                entry.ore_roll = ore_roll;
            }
        }
        const NativeSurfacePropClassification classification = NativeSurfacePropClassifier::classify(
            input.classification, attempt, prop_roll, has_ore_roll, ore_roll);
        entry.outcome = classification.outcome;
        entry.state_after_classification = rng.state();
        validate_recipe_presence(input, entry.outcome);
        const std::size_t compatibility = compatibility_draw_count(entry.outcome);
        entry.compatibility_draws.reserve(compatibility);
        for (std::size_t draw = 0U; draw < compatibility; ++draw) {
            entry.compatibility_draws.push_back(rng.randf());
        }
        if (entry.outcome == NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster) {
            entry.ore_cluster = NativeOreClusterStream::create(attempt.durable_id, NativeOreKind::iron, rng);
        }
        if (entry.outcome == NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster) {
            entry.ore_cluster = NativeOreClusterStream::create(attempt.durable_id, NativeOreKind::copper, rng);
        }
        if (entry.outcome == NativeSurfacePropClassificationOutcome::forage_recipe) {
            entry.forage = NativeForageStreamBuilder::create(*input.forage_recipe, rng);
        }
        if (entry.outcome == NativeSurfacePropClassificationOutcome::wildlife_recipe) {
            entry.wildlife = NativeWildlifeStreamBuilder::create(*input.wildlife, rng);
        }
        entry.state_after_recipe = rng.state();
        entries[index] = std::move(entry);
    }
    return {std::move(entries), rng.state()};
}

NativeSurfacePropBaselineStreamRejected::NativeSurfacePropBaselineStreamRejected()
    : std::invalid_argument("invalid native surface-prop baseline stream") {}

std::size_t NativeSurfacePropBaselineStream::compatibility_draw_count(
    const NativeSurfacePropClassificationOutcome outcome) {
    switch (outcome) {
    case NativeSurfacePropClassificationOutcome::ordinary_rock: return 6U;
    case NativeSurfacePropClassificationOutcome::tree_36_draw: return 36U;
    case NativeSurfacePropClassificationOutcome::tree_22_draw: return 22U;
    case NativeSurfacePropClassificationOutcome::skipped_before_prop_roll:
    case NativeSurfacePropClassificationOutcome::no_feature:
    case NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster:
    case NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster:
    case NativeSurfacePropClassificationOutcome::forage_recipe:
    case NativeSurfacePropClassificationOutcome::wildlife_recipe:
        return 0U;
    }
    reject();
}

NativeSurfacePropBaselineStream::NativeSurfacePropBaselineStream(
    std::array<NativeSurfacePropBaselineEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> entries,
    const std::uint64_t final_rng_state) noexcept
    : entries_(std::move(entries)), final_rng_state_(final_rng_state) {}

NativeSurfacePropBaselineStream NativeSurfacePropBaselineStream::create(
    const NativeSurfacePropAttemptStream &attempts,
    const std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &inputs) {
    try {
        GodotPcg32 preview(attempts.rng_seed());
        static_cast<void>(compose(attempts, inputs, preview));
        GodotPcg32 rng(attempts.rng_seed());
        ComposedBaseline composed = compose(attempts, inputs, rng);
        return NativeSurfacePropBaselineStream(std::move(composed.entries), composed.final_rng_state);
    } catch (const NativeSurfacePropClassifierRejected &) {
        reject();
    } catch (const NativeForageStreamRejected &) {
        reject();
    } catch (const NativeWildlifeStreamRejected &) {
        reject();
    }
}

const std::array<NativeSurfacePropBaselineEntry, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> &
NativeSurfacePropBaselineStream::entries() const noexcept { return entries_; }
std::uint64_t NativeSurfacePropBaselineStream::final_rng_state() const noexcept { return final_rng_state_; }

} // namespace voxel::world_backend
