#include "native_wildlife_stream.hpp"

namespace voxel::world_backend {
namespace {

NativeWildlifePresentationReceipt admitted_presentation(const NativeWildlifePresentationReceipt &value) {
    try {
        return NativeWildlifePresentationReceiptValidator::admit(value);
    } catch (const NativeWildlifePresentationReceiptRejected &) {
        throw NativeWildlifeStreamRejected();
    }
}

NativeWildlifeVariant expected_variant(
    const NativeWildlifeBiomeGroup biome, const GodotPcg32 &rng) {
    try {
        GodotPcg32 preview = rng;
        return NativeWildlifeProfileSelector::select(biome, preview.randf());
    } catch (const NativeWildlifeRecipeRejected &) {
        throw NativeWildlifeStreamRejected();
    }
}

NativeWildlifeStream finish_stream(
    const NativeWildlifeBiomeGroup biome, const NativeWildlifeVariant variant,
    const NativeWildlifePresentationReceipt &presentation, const std::uint64_t state_before,
    const float profile_roll, GodotPcg32 &rng) {
    NativeWildlifeStream result;
    result.recipe = NativeWildlifeRecipeCatalog::resolve(variant);
    result.presentation = presentation;
    result.cold = biome == NativeWildlifeBiomeGroup::cold;
    result.state_before = state_before;
    result.profile_roll = profile_roll;
    result.yaw_roll = rng.randf();
    result.primary_drop_count = rng.randi_range(result.recipe.primary_drop_min, result.recipe.primary_drop_max);
    result.extra_drop_count = rng.randi_range(result.recipe.extra_drop_min, result.recipe.extra_drop_max);
    result.presentation_first_roll = rng.randf();
    result.presentation_second_roll = rng.randf();
    result.direction_roll = rng.randf();
    result.timer_roll = rng.randf();
    result.speed_roll = rng.randf();
    result.state_after = rng.state();
    return result;
}

} // namespace

NativeWildlifeStreamRejected::NativeWildlifeStreamRejected()
    : std::invalid_argument("invalid native wildlife stream") {}

NativeWildlifeStream NativeWildlifeStreamBuilder::create(
    const NativeWildlifeStreamInput &input, GodotPcg32 &rng) {
    const NativeWildlifePresentationReceipt presentation = admitted_presentation(input.presentation);
    const NativeWildlifeVariant variant = expected_variant(input.biome, rng);
    if (presentation.variant != variant) throw NativeWildlifeStreamRejected();

    const std::uint64_t state_before = rng.state();
    const float profile_roll = rng.randf();
    return finish_stream(input.biome, variant, presentation, state_before, profile_roll, rng);
}

NativeWildlifeStream NativeWildlifeStreamBuilder::create(
    const NativeWildlifeBiomeGroup biome, const NativeWildlifePresentationCatalog &catalog, GodotPcg32 &rng) {
    // Resolve against a local copy so a bad source receipt cannot consume the
    // caller's shared stream. The admitted catalog is immutable thereafter.
    GodotPcg32 pending = rng;
    const std::uint64_t state_before = pending.state();
    const float profile_roll = pending.randf();
    NativeWildlifeVariant variant;
    try {
        variant = NativeWildlifeProfileSelector::select(biome, profile_roll);
    } catch (const NativeWildlifeRecipeRejected &) {
        throw NativeWildlifeStreamRejected();
    }
    const NativeWildlifePresentationReceipt presentation = catalog.resolve(variant);
    NativeWildlifeStream result = finish_stream(biome, variant, presentation, state_before, profile_roll, pending);
    rng = pending;
    return result;
}

} // namespace voxel::world_backend
