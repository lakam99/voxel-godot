#include "test_harness.hpp"

#include "../core/native_wildlife_stream.hpp"

#include <utility>

using namespace voxel::world_backend;

namespace {

NativeWildlifePresentationReceipt presentation(
    const NativeWildlifeVariant variant, const NativeWildlifePresentationPath path) {
    NativeWildlifePresentationReceipt result;
    result.schema_revision = 1U;
    result.asset_catalog_digest.fill(1U);
    result.variant = variant;
    result.path = path;
    switch (variant) {
    case NativeWildlifeVariant::boar:
        result.asset_id = "boar_idle_walk";
        result.animation_clip_id = "boar_idle_walk";
        break;
    case NativeWildlifeVariant::deer:
        result.asset_id = "deer_idle_walk";
        result.animation_clip_id = "deer_idle_walk";
        break;
    case NativeWildlifeVariant::hare:
        result.asset_id = "hare_idle_walk";
        result.animation_clip_id = "hare_idle_walk";
        break;
    }
    return result;
}

NativeWildlifeStreamInput input(
    const NativeWildlifeBiomeGroup biome, const NativeWildlifeVariant variant,
    const NativeWildlifePresentationPath path) {
    NativeWildlifeStreamInput result;
    result.biome = biome;
    result.presentation = presentation(variant, path);
    return result;
}

} // namespace

VWB_TEST(native_wildlife_stream_replays_the_complete_typed_source_sequence) {
    GodotPcg32 rng(1U);
    rng.set_state(0U);
    const NativeWildlifeStreamInput source = input(
        NativeWildlifeBiomeGroup::forest_or_plains, NativeWildlifeVariant::deer,
        NativeWildlifePresentationPath::animated_playable);
    const NativeWildlifeStream generated = NativeWildlifeStreamBuilder::create(source, rng);
    VWB_EXPECT(generated.recipe.variant == NativeWildlifeVariant::deer);
    VWB_EXPECT(generated.presentation.path == NativeWildlifePresentationPath::animated_playable);
    VWB_EXPECT(!generated.cold);
    VWB_EXPECT_EQ(0U, generated.state_before);
    VWB_EXPECT_EQ(0.0F, generated.profile_roll);

    GodotPcg32 replay(1U);
    replay.set_state(0U);
    VWB_EXPECT_EQ(generated.profile_roll, replay.randf());
    VWB_EXPECT_EQ(generated.yaw_roll, replay.randf());
    VWB_EXPECT_EQ(generated.primary_drop_count,
        replay.randi_range(generated.recipe.primary_drop_min, generated.recipe.primary_drop_max));
    VWB_EXPECT_EQ(generated.extra_drop_count,
        replay.randi_range(generated.recipe.extra_drop_min, generated.recipe.extra_drop_max));
    VWB_EXPECT_EQ(generated.presentation_first_roll, replay.randf());
    VWB_EXPECT_EQ(generated.presentation_second_roll, replay.randf());
    VWB_EXPECT_EQ(generated.direction_roll, replay.randf());
    VWB_EXPECT_EQ(generated.timer_roll, replay.randf());
    VWB_EXPECT_EQ(generated.speed_roll, replay.randf());
    VWB_EXPECT_EQ(generated.state_after, replay.state());
    VWB_EXPECT_EQ(generated.state_after, rng.state());
}

VWB_TEST(native_wildlife_stream_selects_all_current_biome_group_variants) {
    for (const auto entry : {
             std::pair{NativeWildlifeBiomeGroup::cold, NativeWildlifeVariant::hare},
             std::pair{NativeWildlifeBiomeGroup::forest_or_plains, NativeWildlifeVariant::deer},
             std::pair{NativeWildlifeBiomeGroup::dry, NativeWildlifeVariant::hare},
             std::pair{NativeWildlifeBiomeGroup::swamp, NativeWildlifeVariant::boar},
             std::pair{NativeWildlifeBiomeGroup::other, NativeWildlifeVariant::boar},
         }) {
        GodotPcg32 rng(1U);
        rng.set_state(0U);
        const NativeWildlifeStream generated = NativeWildlifeStreamBuilder::create(
            input(entry.first, entry.second, NativeWildlifePresentationPath::procedural_fallback), rng);
        VWB_EXPECT_EQ(entry.second, generated.recipe.variant);
        VWB_EXPECT_EQ(entry.first == NativeWildlifeBiomeGroup::cold, generated.cold);
    }
}

VWB_TEST(native_wildlife_stream_rejects_invalid_or_mismatched_source_without_mutating_rng) {
    GodotPcg32 rng(1U);
    rng.set_state(0U);
    const std::uint64_t state = rng.state();
    NativeWildlifeStreamInput malformed = input(
        NativeWildlifeBiomeGroup::cold, NativeWildlifeVariant::deer,
        NativeWildlifePresentationPath::animated_playable);
    VWB_EXPECT_THROW(NativeWildlifeStreamRejected, NativeWildlifeStreamBuilder::create(malformed, rng));
    VWB_EXPECT_EQ(state, rng.state());
    malformed = input(NativeWildlifeBiomeGroup::cold, NativeWildlifeVariant::hare,
        NativeWildlifePresentationPath::animated_playable);
    malformed.presentation.asset_catalog_digest = {};
    VWB_EXPECT_THROW(NativeWildlifeStreamRejected, NativeWildlifeStreamBuilder::create(malformed, rng));
    VWB_EXPECT_EQ(state, rng.state());
    malformed = input(static_cast<NativeWildlifeBiomeGroup>(99), NativeWildlifeVariant::boar,
        NativeWildlifePresentationPath::procedural_fallback);
    VWB_EXPECT_THROW(NativeWildlifeStreamRejected, NativeWildlifeStreamBuilder::create(malformed, rng));
    VWB_EXPECT_EQ(state, rng.state());
}
