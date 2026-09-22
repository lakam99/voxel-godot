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

} // namespace

NativeWildlifeStreamRejected::NativeWildlifeStreamRejected()
    : std::invalid_argument("invalid native wildlife stream") {}

NativeWildlifeStream NativeWildlifeStreamBuilder::create(
    const NativeWildlifeStreamInput &input, GodotPcg32 &rng) {
    const NativeWildlifePresentationReceipt presentation = admitted_presentation(input.presentation);
    const NativeWildlifeVariant variant = expected_variant(input.biome, rng);
    if (presentation.variant != variant) throw NativeWildlifeStreamRejected();

    NativeWildlifeStream result;
    result.recipe = NativeWildlifeRecipeCatalog::resolve(variant);
    result.presentation = presentation;
    result.cold = input.biome == NativeWildlifeBiomeGroup::cold;
    result.state_before = rng.state();
    result.profile_roll = rng.randf();
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

} // namespace voxel::world_backend
