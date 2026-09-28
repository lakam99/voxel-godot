#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/legacy_seed_hash.hpp"
#include "../core/native_underground_prop_stream.hpp"

#include <limits>

using namespace voxel::world_backend;

namespace {

NativeBiomeEnvironmentCatalog environment() {
    return NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
}

NativeSurfaceRockAssetCatalog rocks(const NativeBiomeEnvironmentCatalog &biomes) {
    NativeSurfaceRockAssetRecord rock;
    rock.id = "rock_01";
    rock.family = "rock";
    rock.path = "assets/visual/generated/environment/rock_01.glb";
    rock.size_x = 1.4591;
    rock.size_y = 0.9246;
    rock.size_z = 0.5640;
    return NativeSurfaceRockAssetCatalog::create({rock}, biomes);
}

NativeUndergroundPropStream stream_for(
    const NativeEffectiveTerrainSource &terrain,
    const NativeFeatureDeltaSnapshot &removed = NativeFeatureDeltaSnapshot::create({}, {})) {
    const auto biomes = environment();
    const auto scan = NativeUndergroundFloorScan::create(
        terrain.pin().definition().raw_terrain_seed(), 0, 0, terrain);
    return NativeUndergroundPropStream::create(
        terrain.pin().definition().raw_terrain_seed(), scan, terrain,
        biomes, rocks(biomes), removed);
}

NativeCellState edited_air(const CellCoord cell) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = TerrainMaterialId::air;
    input.biome = TerrainBiomeId::underground_air;
    input.solid = false;
    input.density = -1.35;
    input.fluid = TerrainFluidId::none;
    input.block_id = NativeBlockIdentity::create("terrain.air.edited");
    input.edit_reason = "n4-underground-floor-gap";
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input);
}

} // namespace

VWB_TEST(native_underground_prop_hashes_match_the_pinned_godot_hash_contract) {
    const auto seed = admit_raw_terrain_seed("atlas-1492");
    std::vector<std::uint32_t> rng_key = seed.code_points;
    for (const unsigned char byte : std::string(":underground-props:-2,3"))
        rng_key.push_back(byte);
    VWB_EXPECT_EQ(legacy_seed_hash(rng_key),
        native_underground_prop_chunk_rng_seed(seed, -2, 3));
    const CellCoord cell{-51, -27, 84};
    std::vector<std::uint32_t> candidate_key = seed.code_points;
    for (const unsigned char byte : std::string(":underground-prop-candidate:-51,-27,84"))
        candidate_key.push_back(byte);
    VWB_EXPECT_EQ(static_cast<double>(legacy_seed_hash(candidate_key) % 100000U) / 100000.0,
        native_underground_prop_candidate_roll(seed, cell));

    const auto unicode = admit_raw_terrain_seed("世界🌲");
    VWB_EXPECT(native_underground_prop_chunk_rng_seed(unicode, 0, 0)
        != native_underground_prop_chunk_rng_seed(seed, 0, 0));
    auto forged = seed;
    forged.admitted = false;
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        native_underground_prop_chunk_rng_seed(forged, 0, 0));
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        native_underground_prop_candidate_roll(forged, cell));
}

VWB_TEST(native_underground_floor_scan_is_exactly_ordered_bounded_and_source_bound) {
    const auto definition = surface_prop_test_fixture::definition("underground-scan");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto first = NativeUndergroundFloorScan::create(
        definition.raw_terrain_seed(), 0, 0, terrain);
    const auto repeat = NativeUndergroundFloorScan::create(
        definition.raw_terrain_seed(), 0, 0, terrain);
    VWB_EXPECT_EQ(first.content_digest(), repeat.content_digest());
    VWB_EXPECT_EQ(0, first.chunk_x());
    VWB_EXPECT_EQ(0, first.chunk_z());
    VWB_EXPECT_EQ(28U * 28U, first.scanned_columns());
    VWB_EXPECT(first.scanned_cells() >= first.scanned_columns());
    VWB_EXPECT_EQ(static_cast<std::size_t>(NativeUndergroundFloorScan::MAX_CANDIDATES),
        first.candidates().size());
    VWB_EXPECT_EQ(terrain.pin().physical_content_identity(), first.source_identity());
    VWB_EXPECT_EQ(terrain.pin().definition().physical_content_identity(),
        first.definition_identity());
    VWB_EXPECT_EQ(terrain.pin().terrain_delta_revision(), first.terrain_delta_revision());
    VWB_EXPECT_EQ(terrain.pin().shaping_registry_revision(), first.shaping_registry_revision());
    VWB_EXPECT_EQ(terrain.pin().shaping_registry_content_identity().digest,
        first.shaping_registry_identity());
    std::int32_t previous = -1;
    for (std::size_t index = 0U; index < first.candidates().size(); ++index) {
        const auto &candidate = first.candidates()[index];
        VWB_EXPECT_EQ(static_cast<std::uint32_t>(index), candidate.ordinal);
        VWB_EXPECT_EQ(candidate.floor_cell.y + 1, candidate.air_cell.y);
        VWB_EXPECT_EQ(candidate.floor_cell.x, candidate.air_cell.x);
        VWB_EXPECT_EQ(candidate.floor_cell.z, candidate.air_cell.z);
        VWB_EXPECT(candidate.candidate_roll <= 0.18);
        const std::int32_t ordered = candidate.floor_cell.z * 28 + candidate.floor_cell.x;
        VWB_EXPECT(ordered > previous);
        previous = ordered;
    }

    const auto other = surface_prop_test_fixture::definition("underground-other");
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundFloorScan::create(other.raw_terrain_seed(), 0, 0, terrain));
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(), 10, 0, terrain));
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(), -1, 0, terrain));
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(), 0, -1, terrain));
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(), 0, 10, terrain));
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(),
            std::numeric_limits<std::int32_t>::max(), 0, terrain));
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(),
            std::numeric_limits<std::int32_t>::min(), 0, terrain));
}

VWB_TEST(native_underground_floor_scan_and_stream_obey_cancellation_boundaries) {
    const auto definition = surface_prop_test_fixture::definition("underground-cancel");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    std::size_t checks = 0U;
    VWB_EXPECT_THROW(NativeUndergroundPropCancelled,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(), 0, 0, terrain,
            [&checks]() { return ++checks == 1U; }));
    checks = 0U;
    VWB_EXPECT_THROW(NativeUndergroundPropCancelled,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(), 0, 0, terrain,
            [&checks]() { return ++checks == 2U; }));
    checks = 0U;
    VWB_EXPECT_THROW(NativeUndergroundPropCancelled,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(), 0, 0, terrain,
            [&checks]() { return ++checks == 3U; }));
    checks = 0U;
    const auto scan = NativeUndergroundFloorScan::create(
        definition.raw_terrain_seed(), 0, 0, terrain,
        [&checks]() { ++checks; return false; });
    VWB_EXPECT(checks > 2U);
    const std::size_t scan_checks = checks;
    checks = 0U;
    VWB_EXPECT_THROW(NativeUndergroundPropCancelled,
        NativeUndergroundFloorScan::create(definition.raw_terrain_seed(), 0, 0, terrain,
            [&checks, scan_checks]() { return ++checks == scan_checks; }));

    const auto biomes = environment();
    const auto catalog = rocks(biomes);
    const auto removed = NativeFeatureDeltaSnapshot::create({}, {});
    checks = 0U;
    VWB_EXPECT_THROW(NativeUndergroundPropCancelled,
        NativeUndergroundPropStream::create(definition.raw_terrain_seed(), scan, terrain,
            biomes, catalog, removed, [&checks]() { return ++checks == 1U; }));
    checks = 0U;
    VWB_EXPECT_THROW(NativeUndergroundPropCancelled,
        NativeUndergroundPropStream::create(definition.raw_terrain_seed(), scan, terrain,
            biomes, catalog, removed, [&checks]() { return ++checks == 2U; }));
    checks = 0U;
    const auto stream = NativeUndergroundPropStream::create(
        definition.raw_terrain_seed(), scan, terrain, biomes, catalog, removed,
        [&checks]() { ++checks; return false; });
    VWB_EXPECT_EQ(scan.candidates().size() + 2U, checks);
    VWB_EXPECT_EQ(scan.candidates().size(), stream.attempts().size());
    const std::size_t stream_checks = checks;
    checks = 0U;
    VWB_EXPECT_THROW(NativeUndergroundPropCancelled,
        NativeUndergroundPropStream::create(definition.raw_terrain_seed(), scan, terrain,
            biomes, catalog, removed,
            [&checks, stream_checks]() { return ++checks == stream_checks; }));
}

VWB_TEST(native_underground_prop_stream_is_immutable_nonpublishing_and_replays_every_recipe) {
    bool saw_iron = false;
    bool saw_copper = false;
    bool saw_rock = false;
    bool saw_forage = false;
    bool saw_none = false;
    bool saw_deep = false;
    for (std::uint32_t index = 0U; index < 24U
            && !(saw_iron && saw_copper && saw_rock && saw_forage && saw_none && saw_deep);
            ++index) {
        const auto definition = surface_prop_test_fixture::definition(
            "underground-recipes-" + std::to_string(index));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto scan = NativeUndergroundFloorScan::create(
            definition.raw_terrain_seed(), 0, 0, terrain);
        const auto biomes = environment();
        const auto catalog = rocks(biomes);
        const auto removed = NativeFeatureDeltaSnapshot::create({}, {});
        const auto stream = NativeUndergroundPropStream::create(
            definition.raw_terrain_seed(), scan, terrain, biomes, catalog, removed);
        const auto repeat = NativeUndergroundPropStream::create(
            definition.raw_terrain_seed(), scan, terrain, biomes, catalog, removed);
        VWB_EXPECT_EQ(stream.content_digest(), repeat.content_digest());
        VWB_EXPECT_EQ(native_underground_prop_chunk_rng_seed(
            definition.raw_terrain_seed(), 0, 0), stream.rng_seed());
        VWB_EXPECT_EQ(stream.final_rng_state(), repeat.final_rng_state());
        VWB_EXPECT_EQ(scan.content_digest(), stream.scan_digest());
        VWB_EXPECT_EQ(removed.canonical_binary().empty(), false);
        VWB_EXPECT_EQ(sha256(removed.canonical_binary()), stream.removed_props_digest());
        VWB_EXPECT_EQ(biomes.content_digest(), stream.biome_catalog_digest());
        VWB_EXPECT_EQ(catalog.content_digest(), stream.rock_catalog_digest());
        VWB_EXPECT_EQ(stream.transition_contract_digest(), repeat.transition_contract_digest());
        VWB_EXPECT(!stream.publishable());
        VWB_EXPECT(!stream.channel_footprints_complete());
        for (std::size_t attempt_index = 0U; attempt_index < stream.attempts().size(); ++attempt_index) {
            const auto &attempt = stream.attempts()[attempt_index];
            VWB_EXPECT_EQ(static_cast<std::uint32_t>(attempt_index), attempt.ordinal);
            VWB_EXPECT_EQ(attempt.candidate, scan.candidates()[attempt_index]);
            VWB_EXPECT(!attempt.parent_tombstoned);
            VWB_EXPECT(attempt.selection_roll.has_value());
            VWB_EXPECT(!attempt.content_digest.empty());
            switch (attempt.outcome) {
            case NativeUndergroundPropOutcome::iron_ore:
                saw_iron = true; VWB_EXPECT(attempt.ore.has_value());
                VWB_EXPECT_EQ(NativeOreKind::iron, *attempt.ore_kind); break;
            case NativeUndergroundPropOutcome::copper_ore:
                saw_copper = true; VWB_EXPECT(attempt.ore.has_value());
                VWB_EXPECT_EQ(NativeOreKind::copper, *attempt.ore_kind); break;
            case NativeUndergroundPropOutcome::rock:
                saw_rock = true; VWB_EXPECT(attempt.rock.has_value());
                VWB_EXPECT_EQ(attempt.durable_id,
                    attempt.rock->definition.input().durable_feature_id); break;
            case NativeUndergroundPropOutcome::forage:
                saw_forage = true; VWB_EXPECT(attempt.forage.has_value());
                VWB_EXPECT(attempt.forage->recipe.recipe_id.rfind("swamp:", 0U) == 0U); break;
            case NativeUndergroundPropOutcome::no_feature:
                saw_none = true; break;
            case NativeUndergroundPropOutcome::tombstoned:
                VWB_EXPECT(false); break;
            }
            if (attempt.deep_iron_roll) saw_deep = true;
        }
    }
    VWB_EXPECT(saw_iron);
    VWB_EXPECT(saw_copper);
    VWB_EXPECT(saw_rock);
    VWB_EXPECT(saw_forage);
    VWB_EXPECT(saw_none);
    VWB_EXPECT(saw_deep);
}

VWB_TEST(native_underground_scan_rejects_an_edited_air_gap_as_a_floor) {
    const auto definition = surface_prop_test_fixture::definition("underground-air-gap");
    const NativeEffectiveTerrainSource baseline(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto before = NativeUndergroundFloorScan::create(
        definition.raw_terrain_seed(), 0, 0, baseline);
    VWB_EXPECT(!before.candidates().empty());

    WorldDeltaStore store;
    WorldTypedCellTransaction transaction;
    transaction.transaction_id = "n4:air-gap";
    transaction.expected_revision = 0U;
    transaction.operations.push_back({NativeCellStateNamespace::durable_terrain,
        before.candidates().front().floor_cell, WorldTypedCellOperationKind::set,
        edited_air(before.candidates().front().floor_cell)});
    VWB_EXPECT_EQ(WorldDeltaCommitStatus::committed,
        store.commit_typed_cells(transaction).status);
    const NativeEffectiveTerrainSource edited(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, store.pin()));
    const auto after = NativeUndergroundFloorScan::create(
        definition.raw_terrain_seed(), 0, 0, edited);
    VWB_EXPECT(before.content_digest() != after.content_digest());
    VWB_EXPECT(after.scanned_cells() > before.scanned_cells());
}

VWB_TEST(native_underground_rock_recipe_supports_the_primitive_fallback_contract) {
    bool saw_primitive = false;
    for (std::uint32_t index = 0U; index < 24U && !saw_primitive; ++index) {
        const auto definition = surface_prop_test_fixture::definition(
            "underground-primitive-" + std::to_string(index));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto scan = NativeUndergroundFloorScan::create(
            definition.raw_terrain_seed(), 0, 0, terrain);
        const auto biomes = environment();
        NativeSurfaceRockAssetRecord unrelated;
        unrelated.id = "unrelated_01";
        unrelated.family = "not_a_rock_family";
        unrelated.path = "assets/visual/generated/environment/unrelated_01.glb";
        unrelated.size_x = 1.0;
        unrelated.size_y = 1.0;
        unrelated.size_z = 1.0;
        const auto no_rock_family = NativeSurfaceRockAssetCatalog::create(
            {unrelated}, biomes);
        const auto stream = NativeUndergroundPropStream::create(
            definition.raw_terrain_seed(), scan, terrain, biomes, no_rock_family,
            NativeFeatureDeltaSnapshot::create({}, {}));
        for (const auto &attempt : stream.attempts()) {
            if (!attempt.rock) continue;
            saw_primitive = true;
            VWB_EXPECT(attempt.rock->selection.asset_id.empty());
            VWB_EXPECT_EQ(NativeSurfaceRockVisualIntent::primitive_required,
                attempt.rock->visual_intent);
        }
    }
    VWB_EXPECT(saw_primitive);
}

VWB_TEST(native_underground_parent_tombstone_preserves_root_gate_and_reports_transition) {
    const auto definition = surface_prop_test_fixture::definition("underground-tombstone");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto intact = stream_for(terrain);
    VWB_EXPECT(!intact.attempts().empty());
    const std::string first_id = intact.attempts().front().durable_id;
    const auto removed = NativeFeatureDeltaSnapshot::create({{first_id}}, {});
    const auto filtered = stream_for(terrain, removed);
    VWB_EXPECT(filtered.attempts().front().parent_tombstoned);
    VWB_EXPECT_EQ(NativeUndergroundPropOutcome::tombstoned,
        filtered.attempts().front().outcome);
    VWB_EXPECT(!filtered.attempts().front().selection_roll.has_value());
    VWB_EXPECT_EQ(filtered.attempts().front().state_before,
        filtered.attempts().front().state_after_recipe);
    VWB_EXPECT(intact.final_rng_state() != filtered.final_rng_state());
    const auto transition = NativeUndergroundPropTransition::create(intact, filtered);
    VWB_EXPECT(!transition.changed().empty());
    VWB_EXPECT_EQ(0U, transition.changed().front().ordinal);
    VWB_EXPECT_EQ(first_id, transition.changed().front().before_durable_id);
    VWB_EXPECT_EQ(first_id, transition.changed().front().after_durable_id);
    VWB_EXPECT_EQ(NativeUndergroundPropOutcome::tombstoned,
        transition.changed().front().after_outcome);
    VWB_EXPECT(!transition.publishable());
    VWB_EXPECT(!transition.channel_footprints_complete());
    const auto unchanged = NativeUndergroundPropTransition::create(intact, intact);
    VWB_EXPECT(unchanged.changed().empty());
    VWB_EXPECT(unchanged.content_digest() != transition.content_digest());
    const auto unrelated = stream_for(terrain,
        NativeFeatureDeltaSnapshot::create({{"unrelated"}}, {}));
    const auto unrelated_transition = NativeUndergroundPropTransition::create(intact, unrelated);
    VWB_EXPECT(unrelated_transition.changed().empty());
    VWB_EXPECT(unrelated_transition.content_digest() != unchanged.content_digest());
}

VWB_TEST(native_underground_prop_stream_rejects_mismatched_source_and_catalog_receipts) {
    const auto definition = surface_prop_test_fixture::definition("underground-reject");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto scan = NativeUndergroundFloorScan::create(
        definition.raw_terrain_seed(), 0, 0, terrain);
    const auto biomes = environment();
    const auto catalog = rocks(biomes);
    const auto removed = NativeFeatureDeltaSnapshot::create({}, {});
    const auto other_definition = surface_prop_test_fixture::definition("underground-other");
    auto forged = definition.raw_terrain_seed();
    forged.admitted = false;
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundFloorScan::create(forged, 0, 0, terrain));
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundPropStream::create(forged, scan, terrain,
            biomes, catalog, removed));
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundPropStream::create(other_definition.raw_terrain_seed(), scan,
            terrain, biomes, catalog, removed));

    auto changed_profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : changed_profiles)
        if (profile.biome_id == "swamp") profile.rock_scale += 0.01;
    const auto changed_biomes = NativeBiomeEnvironmentCatalog::create(changed_profiles);
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundPropStream::create(definition.raw_terrain_seed(), scan,
            terrain, changed_biomes, catalog, removed));

    const auto other = surface_prop_test_fixture::definition("underground-other-pin");
    const NativeEffectiveTerrainSource other_terrain(surface_prop_test_fixture::ready_pin(
        other, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto other_scan = NativeUndergroundFloorScan::create(
        other.raw_terrain_seed(), 0, 0, other_terrain);
    const auto other_stream = stream_for(other_terrain);
    const auto intact = stream_for(terrain);
    VWB_EXPECT_THROW(NativeUndergroundPropRejected,
        NativeUndergroundPropTransition::create(intact, other_stream));
    VWB_EXPECT(other_scan.content_digest() != scan.content_digest());

    NativeUndergroundFloorCandidate left{};
    NativeUndergroundFloorCandidate right{};
    VWB_EXPECT(left == right);
    right.ordinal = 1U; VWB_EXPECT(!(left == right)); right = left;
    right.floor_cell.x = 1; VWB_EXPECT(!(left == right)); right = left;
    right.air_cell.y = 1; VWB_EXPECT(!(left == right)); right = left;
    right.material = TerrainMaterialId::stone; VWB_EXPECT(!(left == right)); right = left;
    right.candidate_roll = 0.1; VWB_EXPECT(!(left == right));
}
