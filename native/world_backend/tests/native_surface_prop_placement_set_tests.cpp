#include "test_harness.hpp"

#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_prop_placement_set.hpp"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
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

NativeSurfacePropAttemptStream attempts(const std::int32_t chunk_x = -3, const std::int32_t chunk_z = 2) {
    return NativeSurfacePropAttemptStream::create(admit_raw_terrain_seed("placement-set"), chunk_x, chunk_z);
}

std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT>
inputs_for(const NativeSurfacePropAttemptStream &attempts) {
    std::array<NativeSurfacePropBaselineInput, NativeSurfacePropAttemptStream::ATTEMPT_COUNT> inputs{};
    for (std::size_t i = 0; i < inputs.size(); ++i) {
        auto &classification = inputs[i].classification;
        classification.ordinal = attempts.attempts()[i].ordinal;
        classification.cell_x = attempts.attempts()[i].cell_x;
        classification.cell_z = attempts.attempts()[i].cell_z;
        classification.source_decision_digest.fill(static_cast<std::uint8_t>(i + 1U));
        classification.admission = NativeSurfacePropAdmission::eligible;
        classification.policy.tree_replay = NativeSurfacePropTreeReplayMode::legacy_36_draw;
    }
    inputs[0].classification.policy.wildlife_upper = 1.0F; inputs[0].wildlife = boar_wildlife();
    inputs[1].classification.policy.forage_upper = 1.0F; inputs[1].classification.policy.wildlife_upper = 1.0F;
    inputs[1].forage_recipe = berry_recipe();
    inputs[2].classification.policy.rock_upper = 1.0F; inputs[2].classification.policy.tree_upper = 1.0F;
    inputs[2].classification.policy.forage_upper = 1.0F; inputs[2].classification.policy.wildlife_upper = 1.0F;
    inputs[3].classification.policy.tree_upper = 1.0F; inputs[3].classification.policy.forage_upper = 1.0F;
    inputs[3].classification.policy.wildlife_upper = 1.0F;
    inputs[4].classification.policy.tree_upper = 1.0F; inputs[4].classification.policy.forage_upper = 1.0F;
    inputs[4].classification.policy.wildlife_upper = 1.0F;
    inputs[4].classification.policy.tree_replay = NativeSurfacePropTreeReplayMode::legacy_22_draw;
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

NativeSurfacePropBaselineStream baseline_for(const NativeSurfacePropAttemptStream &attempts) {
    return NativeSurfacePropBaselineStream::create(attempts, inputs_for(attempts));
}

NativeEffectiveTerrainSource terrain_for(const WorldSourceDefinition &definition,
    const WorldDeltaPinnedSnapshot &deltas = surface_prop_test_fixture::empty_deltas(),
    const NativeTerrainPageKey page = {-1, 0}) {
    return NativeEffectiveTerrainSource(surface_prop_test_fixture::ready_pin(definition, page, deltas));
}

WorldDeltaPinnedSnapshot raised_surface(const CellCoord cell) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = TerrainMaterialId::stone;
    input.biome = TerrainBiomeId::plains;
    input.solid = true;
    input.density = 0.7;
    input.block_id = NativeBlockIdentity::create("stone");
    input.edit_reason = "placement-test";
    input.generated = false;
    input.edited = true;
    input.metadata = NativeValue::object({{"source", NativeValue::string("placement-test")}});
    const NativeCellState state = make_native_cell_state(input, NativeCellStateNamespace::durable_terrain);
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "placement:raised-surface";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({{
        NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable,
        state,
    }});
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot flooded_raised_surface(const CellCoord cell) {
    NativeCellStateInput solid;
    solid.cell = cell;
    solid.material = TerrainMaterialId::stone;
    solid.biome = TerrainBiomeId::plains;
    solid.solid = true;
    solid.density = 0.7;
    solid.block_id = NativeBlockIdentity::create("stone");
    solid.edit_reason = "placement-test";
    solid.generated = false;
    solid.edited = true;
    solid.metadata = NativeValue::object({{"source", NativeValue::string("placement-test")}});
    NativeCellStateInput fluid = solid;
    fluid.cell.y += 1;
    fluid.material = TerrainMaterialId::water;
    fluid.solid = false;
    fluid.density = 0.0;
    fluid.fluid = TerrainFluidId::water;
    fluid.block_id = NativeBlockIdentity::create("water");
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "placement:flooded-surface";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({
        {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
            make_native_cell_state(solid, NativeCellStateNamespace::durable_terrain)},
        {NativeCellStateNamespace::durable_terrain, NativeTypedWorldStatePersistence::durable,
            make_native_cell_state(fluid, NativeCellStateNamespace::durable_terrain)},
    });
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

std::uint32_t bits(float value) {
    std::uint32_t result = 0U;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}

} // namespace

VWB_TEST(native_surface_prop_placement_spp2_binds_all_typed_outcomes_to_pinned_continuous_source) {
    const auto attempt_stream = attempts();
    const auto baseline = baseline_for(attempt_stream);
    const auto definition = surface_prop_test_fixture::definition();
    const auto terrain = terrain_for(definition);
    const auto receipt = surface_prop_test_fixture::receipt(terrain.pin());
    const auto set = NativeSurfacePropPlacementSet::create(attempt_stream, baseline, receipt, terrain);
    VWB_EXPECT_EQ(4U, NativeSurfacePropPlacementSet::SCHEMA_REVISION);
    VWB_EXPECT_EQ(terrain.pin().physical_content_identity(), set.world_source_identity());
    VWB_EXPECT_EQ(receipt.effective_source_digest, set.source_receipt().effective_source_digest);
    VWB_EXPECT_EQ(terrain.pin().definition().physical_content_identity(), set.definition_source_identity());
    VWB_EXPECT_EQ(terrain.pin().terrain_delta_revision(), set.terrain_delta_revision());
    VWB_EXPECT_EQ(terrain.pin().shaping_registry_revision(), set.shaping_registry_revision());
    VWB_EXPECT_EQ(sha256(set.canonical_binary()), set.content_digest());
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('4'), set.canonical_binary()[3]);
    bool saw_non_lattice = false;
    for (std::size_t i = 0; i < set.entries().size(); ++i) {
        const auto &entry = set.entries()[i];
        const auto &attempt = attempt_stream.attempts()[i];
        VWB_EXPECT_EQ(attempt.ordinal, entry.ordinal);
        VWB_EXPECT_EQ(attempt.durable_id, entry.durable_id);
        VWB_EXPECT_EQ(attempt.cell_x, entry.cell_x);
        VWB_EXPECT_EQ(attempt.cell_z, entry.cell_z);
        VWB_EXPECT_EQ(baseline.entries()[i].source_decision_digest, entry.source_decision_digest);
        if (i < 7U) {
            const auto facts = terrain.sample_surface_prop_spawn({attempt.cell_x, attempt.cell_z, WorldQueryIntent::gameplay});
            VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::anchored, entry.presence);
            VWB_EXPECT_EQ(facts.mode, entry.mode);
            VWB_EXPECT_EQ(facts.height_meters, entry.source_height_meters);
            VWB_EXPECT_EQ(bits(facts.world_anchor_y), bits(entry.world_anchor.y));
            VWB_EXPECT_EQ(facts.biome, entry.biome);
            VWB_EXPECT_EQ(facts.material, entry.material);
            VWB_EXPECT_EQ(facts.solid_cell, entry.solid_cell);
            VWB_EXPECT_EQ(facts.air_cell, entry.air_cell);
            if (entry.source_height_meters != static_cast<double>(entry.air_cell.y) * definition.constants().cell_size_meters)
                saw_non_lattice = true;
        } else {
            VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::absent, entry.presence);
            VWB_EXPECT_EQ((CellCoord{}), entry.solid_cell);
            VWB_EXPECT_EQ((CellCoord{}), entry.air_cell);
        }
    }
    VWB_EXPECT(saw_non_lattice);
}

VWB_TEST(native_surface_prop_placement_spp2_rejects_corrupt_attempt_and_classification_receipts) {
    const auto original_attempts = attempts();
    const auto original_baseline = baseline_for(original_attempts);
    const auto terrain = terrain_for(surface_prop_test_fixture::definition());
    const auto receipt = surface_prop_test_fixture::receipt(terrain.pin());
    auto reject_attempt = [&](auto change) {
        auto changed = original_attempts;
        change(const_cast<NativeSurfacePropAttempt &>(changed.attempts()[1]));
        VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
            NativeSurfacePropPlacementSet::create(changed, original_baseline, receipt, terrain));
    };
    reject_attempt([](NativeSurfacePropAttempt &attempt) { attempt.cell_x += 28; });
    reject_attempt([](NativeSurfacePropAttempt &attempt) { attempt.cell_z -= 28; });
    reject_attempt([](NativeSurfacePropAttempt &attempt) { ++attempt.ordinal; });
    auto reject_baseline = [&](auto change) {
        auto changed = original_baseline;
        change(const_cast<NativeSurfacePropBaselineEntry &>(changed.entries()[1]));
        VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
            NativeSurfacePropPlacementSet::create(original_attempts, changed, receipt, terrain));
    };
    reject_baseline([](NativeSurfacePropBaselineEntry &entry) { ++entry.ordinal; });
    reject_baseline([](NativeSurfacePropBaselineEntry &entry) { entry.durable_id += ":corrupt"; });
    reject_baseline([](NativeSurfacePropBaselineEntry &entry) { ++entry.cell_x; });
    reject_baseline([](NativeSurfacePropBaselineEntry &entry) { ++entry.cell_z; });
    reject_baseline([](NativeSurfacePropBaselineEntry &entry) {
        entry.outcome = static_cast<NativeSurfacePropClassificationOutcome>(255U);
    });
}

VWB_TEST(native_surface_prop_chunk_frame_rejects_invalid_size_anchor_margin_and_overflow) {
    const auto reject_frame = [](std::int32_t cx, std::int32_t cz, std::int32_t x, std::int32_t z,
                                 double size, float y) {
        VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
            resolve_native_surface_prop_chunk_frame(cx, cz, x, z, size, y));
    };
    reject_frame(1, 1, 30, 30, 0.0, 1.0F);
    reject_frame(1, 1, 30, 30, -1.0, 1.0F);
    reject_frame(1, 1, 30, 30, std::numeric_limits<double>::quiet_NaN(), 1.0F);
    reject_frame(1, 1, 30, 30, 1.35, std::numeric_limits<float>::infinity());
    reject_frame(1, 1, 28, 30, 1.35, 1.0F);
    reject_frame(1, 1, 55, 30, 1.35, 1.0F);
    reject_frame(1, 1, 30, 28, 1.35, 1.0F);
    reject_frame(1, 1, 30, 55, 1.35, 1.0F);
    reject_frame(1, 1, 27, 30, 1.35, 1.0F);
    reject_frame(1, 1, 30, 27, 1.35, 1.0F);
    reject_frame(1, 1, 30, 30, 1.0e40, 1.0F);
    // Distinguish overflow at each float32 boundary: chunk origin, local
    // position, and their world-transform sum, in both horizontal axes.
    reject_frame(1, 0, 30, 2, 1.0e40, 1.0F);
    reject_frame(0, 1, 2, 30, 1.0e40, 1.0F);
    reject_frame(0, 0, 26, 2, 1.0e38, 1.0F);
    reject_frame(0, 0, 2, 26, 1.0e38, 1.0F);
    reject_frame(1, 0, 54, 2, 1.0e37, 1.0F);
    reject_frame(0, 1, 2, 54, 1.0e37, 1.0F);
}

VWB_TEST(native_surface_prop_placement_spp2_rejects_source_mismatch_and_wrong_page) {
    const auto attempt_stream = attempts();
    auto baseline = baseline_for(attempt_stream);
    const auto terrain = terrain_for(surface_prop_test_fixture::definition());
    const auto receipt = surface_prop_test_fixture::receipt(terrain.pin());
    auto changed = receipt; changed.effective_source_digest[0] ^= 1U;
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        NativeSurfacePropPlacementSet::create(attempt_stream, baseline, changed, terrain));
    changed = receipt; ++changed.terrain_delta_revision;
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        NativeSurfacePropPlacementSet::create(attempt_stream, baseline, changed, terrain));
    changed = receipt; ++changed.shaping_registry_revision;
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        NativeSurfacePropPlacementSet::create(attempt_stream, baseline, changed, terrain));
    changed = receipt; changed.environment_profile_digest = {};
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        NativeSurfacePropPlacementSet::create(attempt_stream, baseline, changed, terrain));
    const auto wrong_page = NativeEffectiveTerrainSource(surface_prop_test_fixture::ready_pin(
        surface_prop_test_fixture::definition(), {0, 0}, surface_prop_test_fixture::empty_deltas()));
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        NativeSurfacePropPlacementSet::create(attempt_stream, baseline,
            surface_prop_test_fixture::receipt(wrong_page.pin()), wrong_page));
    auto &corrupt = const_cast<NativeSurfacePropBaselineEntry &>(baseline.entries()[0]);
    corrupt.source_decision_digest = {};
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        NativeSurfacePropPlacementSet::create(attempt_stream, baseline, receipt, terrain));
}

VWB_TEST(native_surface_prop_placement_spp2_uses_edited_top_face_not_generated_height) {
    const auto attempt_stream = attempts();
    const auto baseline = baseline_for(attempt_stream);
    const auto definition = surface_prop_test_fixture::definition();
    const auto generated = terrain_for(definition);
    const auto &candidate = attempt_stream.attempts()[0];
    const auto old_surface = generated.sample_surface_prop_spawn(
        {candidate.cell_x, candidate.cell_z, WorldQueryIntent::gameplay});
    const auto cell_size = definition.constants().cell_size_meters;
    const auto raised_y = static_cast<std::int32_t>(std::ceil(old_surface.height_meters / cell_size)) + 3;
    const auto edited = terrain_for(definition, raised_surface({candidate.cell_x, raised_y, candidate.cell_z}));
    const auto facts = edited.sample_surface_prop_spawn(
        {candidate.cell_x, candidate.cell_z, WorldQueryIntent::gameplay});
    VWB_EXPECT(facts.found);
    VWB_EXPECT_EQ(NativeSurfacePropSpawnMode::terrain_volume_projection, facts.mode);
    VWB_EXPECT_EQ(static_cast<double>(raised_y + 1) * cell_size, facts.height_meters);
    const auto set = NativeSurfacePropPlacementSet::create(
        attempt_stream, baseline, surface_prop_test_fixture::receipt(edited.pin()), edited);
    VWB_EXPECT_EQ(facts.height_meters, set.entries()[0].source_height_meters);
    VWB_EXPECT_EQ(bits(facts.world_anchor_y), bits(set.entries()[0].world_anchor.y));
    VWB_EXPECT(set.entries()[0].source_height_meters != old_surface.height_meters);
}

VWB_TEST(native_surface_prop_placement_spp2_rejects_flooded_support) {
    const auto attempt_stream = attempts();
    const auto baseline = baseline_for(attempt_stream);
    const auto definition = surface_prop_test_fixture::definition();
    const auto generated = terrain_for(definition);
    const auto &candidate = attempt_stream.attempts()[0];
    const auto old_surface = generated.sample_surface_prop_spawn(
        {candidate.cell_x, candidate.cell_z, WorldQueryIntent::gameplay});
    const auto cell_size = definition.constants().cell_size_meters;
    const auto raised_y = static_cast<std::int32_t>(std::ceil(old_surface.height_meters / cell_size)) + 3;
    const auto flooded = terrain_for(definition,
        flooded_raised_surface({candidate.cell_x, raised_y, candidate.cell_z}));
    const auto facts = flooded.sample_surface_prop_spawn(
        {candidate.cell_x, candidate.cell_z, WorldQueryIntent::gameplay});
    VWB_EXPECT(!facts.found);
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        NativeSurfacePropPlacementSet::create(attempt_stream, baseline,
            surface_prop_test_fixture::receipt(flooded.pin()), flooded));
}

VWB_TEST(native_surface_prop_placement_spp2_translates_terrain_query_domain_failure) {
    // Source admission currently permits finite but very large maximum surface
    // bounds. An edited-column projection must reject a scan top beyond the
    // int32 lattice, and placement must report its own rejection type.
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("placement-set");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("placement-set");
    descriptor.revisions.terrain_generator_revision = 8U;
    descriptor.revisions.lattice_query_revision = 6U;
    descriptor.revisions.cell_center_query_revision = 7U;
    descriptor.revisions.surface_column_query_revision = 8U;
    descriptor.constants.maximum_surface_meters = 1.0e300;
    const WorldSourceDefinition definition(std::move(descriptor));
    const auto attempt_stream = attempts();
    const auto baseline = baseline_for(attempt_stream);
    const auto &candidate = attempt_stream.attempts()[0];
    const auto edited = terrain_for(definition,
        raised_surface({candidate.cell_x, 20, candidate.cell_z}));
    VWB_EXPECT_THROW(std::invalid_argument, edited.sample_surface_prop_spawn(
        {candidate.cell_x, candidate.cell_z, WorldQueryIntent::gameplay}));
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        NativeSurfacePropPlacementSet::create(attempt_stream, baseline,
            surface_prop_test_fixture::receipt(edited.pin()), edited));
}

VWB_TEST(native_surface_prop_placement_spp2_is_deterministic_without_tombstone_input) {
    const auto attempt_stream = attempts();
    const auto baseline = baseline_for(attempt_stream);
    const auto terrain = terrain_for(surface_prop_test_fixture::definition());
    const auto receipt = surface_prop_test_fixture::receipt(terrain.pin());
    const auto first = NativeSurfacePropPlacementSet::create(attempt_stream, baseline, receipt, terrain);
    const auto second = NativeSurfacePropPlacementSet::create(attempt_stream, baseline, receipt, terrain);
    VWB_EXPECT_EQ(first.canonical_binary(), second.canonical_binary());
    VWB_EXPECT_EQ(first.content_digest(), second.content_digest());
    auto different_profile = receipt; ++different_profile.environment_profile_revision;
    const auto third = NativeSurfacePropPlacementSet::create(attempt_stream, baseline, different_profile, terrain);
    VWB_EXPECT(first.content_digest() != third.content_digest());
}

VWB_TEST(native_surface_prop_placement_spp2_preserves_positive_and_negative_chunk_local_frames) {
    const auto definition = surface_prop_test_fixture::definition();
    for (const std::int32_t chunk : {1, -1}) {
        const auto attempt_stream = attempts(chunk, chunk);
        const auto baseline = baseline_for(attempt_stream);
        const auto terrain = terrain_for(definition, surface_prop_test_fixture::empty_deltas(),
            {chunk < 0 ? -1 : 0, chunk < 0 ? -1 : 0});
        const auto set = NativeSurfacePropPlacementSet::create(
            attempt_stream, baseline, surface_prop_test_fixture::receipt(terrain.pin()), terrain);
        for (std::size_t i = 0; i < set.entries().size(); ++i) {
            const auto &entry = set.entries()[i];
            VWB_EXPECT_EQ(chunk, entry.chunk_x);
            VWB_EXPECT_EQ(chunk, entry.chunk_z);
            const auto offset_x = entry.cell_x - chunk * NativeSurfacePropAttemptStream::CHUNK_CELLS;
            const auto offset_z = entry.cell_z - chunk * NativeSurfacePropAttemptStream::CHUNK_CELLS;
            const float origin = static_cast<float>(static_cast<double>(chunk * 28) * 1.35);
            const float local_x = static_cast<float>(static_cast<double>(offset_x) * 1.35);
            const float local_z = static_cast<float>(static_cast<double>(offset_z) * 1.35);
            VWB_EXPECT_EQ(bits(origin), bits(entry.chunk_origin.x));
            VWB_EXPECT_EQ(bits(origin), bits(entry.chunk_origin.z));
            VWB_EXPECT_EQ(bits(local_x), bits(entry.local_position.x));
            VWB_EXPECT_EQ(bits(local_z), bits(entry.local_position.z));
            if (entry.presence == NativeSurfacePropPlacementPresence::anchored) {
                VWB_EXPECT_EQ(bits(static_cast<float>(static_cast<double>(origin) + local_x)),
                    bits(entry.world_anchor.x));
                VWB_EXPECT_EQ(bits(static_cast<float>(static_cast<double>(origin) + local_z)),
                    bits(entry.world_anchor.z));
                VWB_EXPECT_EQ(bits(entry.local_position.y), bits(entry.world_anchor.y));
            }
        }
    }
}

VWB_TEST(native_surface_prop_placement_spp2_matches_direct_godot_chunk_transform_bits) {
    // Frozen from SurfacePropChunkTransformContractRunner.gd, which installs
    // real Node3D chunk/child transforms in Godot 4.6.1. The direct x*CELL
    // result differs by one or more bits at the positive and negative seams.
    struct Case {
        std::int32_t chunk_x, chunk_z, local_x, local_z;
        std::uint32_t origin_x, origin_z, local_x_bits, local_z_bits, world_x, world_z;
    };
    constexpr std::array<Case, 6> cases{{
        {1, 1, 2, 26, 1108816691U, 1108816691U, 1076677837U, 1108108902U, 1109524480U, 1116851404U},
        {1, 1, 26, 2, 1108816691U, 1108816691U, 1108108902U, 1076677837U, 1116851404U, 1109524480U},
        {-1, -1, 2, 26, 3256300339U, 3256300339U, 1076677837U, 1108108902U, 3255592550U, 3224161488U},
        {-1, -1, 26, 2, 3256300339U, 3256300339U, 1108108902U, 1076677837U, 3224161488U, 3255592550U},
        {127, -127, 26, 2, 1167459533U, 3314943181U, 1108108902U, 1076677837U, 1167531418U, 3314937651U},
        {1000000, -1000000, 2, 26, 1276129808U, 3423613456U, 1076677837U, 1108108902U, 1276129809U, 3423613447U},
    }};
    for (const Case &candidate : cases) {
        const std::int32_t cell_x = candidate.chunk_x * 28 + candidate.local_x;
        const std::int32_t cell_z = candidate.chunk_z * 28 + candidate.local_z;
        const auto frame = resolve_native_surface_prop_chunk_frame(
            candidate.chunk_x, candidate.chunk_z, cell_x, cell_z, 1.35, 17.125F);
        VWB_EXPECT_EQ(candidate.origin_x, bits(frame.chunk_origin.x));
        VWB_EXPECT_EQ(candidate.origin_z, bits(frame.chunk_origin.z));
        VWB_EXPECT_EQ(candidate.local_x_bits, bits(frame.local_position.x));
        VWB_EXPECT_EQ(candidate.local_z_bits, bits(frame.local_position.z));
        VWB_EXPECT_EQ(candidate.world_x, bits(frame.world_anchor.x));
        VWB_EXPECT_EQ(candidate.world_z, bits(frame.world_anchor.z));
        VWB_EXPECT_EQ(bits(17.125F), bits(frame.world_anchor.y));
    }
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        resolve_native_surface_prop_chunk_frame(1, 1, 28, 30, 1.35, 17.125F));
    VWB_EXPECT_THROW(NativeSurfacePropPlacementSetRejected,
        resolve_native_surface_prop_chunk_frame(1, 1, 30, 55, 1.35, 17.125F));
}
