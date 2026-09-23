#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_prop_ordered_placement.hpp"

#include <limits>

using namespace voxel::world_backend;

namespace {

Sha256Digest world_digest() { Sha256Digest d{}; d[0] = 19U; return d; }

NativeStructureExclusionSnapshot exclusions() {
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent;
    absent.source_key = "world:0,0";
    return NativeStructureExclusionSnapshot::create(world_digest(), 1U, {}, {}, {absent}, {{0,0,true}});
}

NativeWildlifePresentationReceipt presentation(NativeWildlifeVariant variant, const char *asset) {
    NativeWildlifePresentationReceipt r;
    r.schema_revision = 1U; r.asset_catalog_digest.fill(1U);
    r.variant = variant; r.path = NativeWildlifePresentationPath::animated_playable;
    r.asset_id = asset; r.animation_clip_id = asset;
    return r;
}

NativeWildlifePresentationCatalog wildlife() {
    return NativeWildlifePresentationCatalog::create({
        presentation(NativeWildlifeVariant::boar, "boar_idle_walk"),
        presentation(NativeWildlifeVariant::deer, "deer_idle_walk"),
        presentation(NativeWildlifeVariant::hare, "hare_idle_walk")});
}

NativeSurfacePropSourceOrderedStream stream(const NativeEffectiveTerrainSource &terrain,
    const NativeFeatureDeltaSnapshot &removed) {
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        0, 0, world_digest(), 1U, terrain,
        NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles()),
        exclusions(), removed, wildlife());
}

void expect_position(const WorldFloat32Position &expected, const WorldFloat32Position &actual) {
    VWB_EXPECT_EQ(expected.x, actual.x);
    VWB_EXPECT_EQ(expected.y, actual.y);
    VWB_EXPECT_EQ(expected.z, actual.z);
}

} // namespace

VWB_TEST(native_ordered_placement_outcome_policy_is_complete_and_rejects_unknown_values) {
    VWB_EXPECT(!native_surface_prop_outcome_has_placement(
        NativeSurfacePropClassificationOutcome::skipped_before_prop_roll));
    VWB_EXPECT(!native_surface_prop_outcome_has_placement(
        NativeSurfacePropClassificationOutcome::no_feature));
    for (const auto outcome : {
        NativeSurfacePropClassificationOutcome::ordinary_rock,
        NativeSurfacePropClassificationOutcome::tree_36_draw,
        NativeSurfacePropClassificationOutcome::tree_22_draw,
        NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster,
        NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster,
        NativeSurfacePropClassificationOutcome::forage_recipe,
        NativeSurfacePropClassificationOutcome::wildlife_recipe}) {
        VWB_EXPECT(native_surface_prop_outcome_has_placement(outcome));
    }
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected,
        native_surface_prop_outcome_has_placement(
            static_cast<NativeSurfacePropClassificationOutcome>(255)));
}

VWB_TEST(native_ordered_placement_chunk_floor_handles_signed_boundaries) {
    VWB_EXPECT_EQ(0, native_surface_prop_ordered_chunk_for_cell(0));
    VWB_EXPECT_EQ(-1, native_surface_prop_ordered_chunk_for_cell(-1));
    VWB_EXPECT_EQ(-1, native_surface_prop_ordered_chunk_for_cell(-28));
    VWB_EXPECT_EQ(-2, native_surface_prop_ordered_chunk_for_cell(-29));
    VWB_EXPECT_EQ(-76695845,
        native_surface_prop_ordered_chunk_for_cell(std::numeric_limits<std::int32_t>::min()));
    VWB_EXPECT_EQ(76695844,
        native_surface_prop_ordered_chunk_for_cell(std::numeric_limits<std::int32_t>::max()));
}

VWB_TEST(native_ordered_placement_preserves_28_source_entries_and_float32_frames) {
    const auto definition = surface_prop_test_fixture::definition("ordered-placement");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto ordered = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}));
    VWB_EXPECT_EQ(0, ordered.chunk_x());
    VWB_EXPECT_EQ(0, ordered.chunk_z());
    VWB_EXPECT_EQ(world_digest(), ordered.world_digest());
    VWB_EXPECT_EQ(1U, ordered.world_generation());
    VWB_EXPECT(ordered.source_receipt().matches_pin(terrain.pin()));
    VWB_EXPECT_EQ(exclusions().content_digest(), ordered.exclusion_digest());
    const auto set = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    const auto repeat = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    VWB_EXPECT_EQ(28U, set.entries().size());
    VWB_EXPECT_EQ(set.content_digest(), repeat.content_digest());
    VWB_EXPECT_EQ(sha256(set.canonical_binary()), set.content_digest());
    VWB_EXPECT_EQ(static_cast<std::uint8_t>('O'), set.canonical_binary()[2]);
    VWB_EXPECT_EQ(ordered.final_rng_state(), set.final_rng_state());
    VWB_EXPECT_EQ(terrain.pin().physical_content_identity(), set.world_source_identity());
    VWB_EXPECT_EQ(terrain.pin().definition().physical_content_identity(), set.definition_source_identity());
    VWB_EXPECT_EQ(terrain.pin().terrain_delta_revision(), set.terrain_delta_revision());
    VWB_EXPECT_EQ(terrain.pin().shaping_registry_revision(), set.shaping_registry_revision());
    for (std::size_t i = 0; i < set.entries().size(); ++i) {
        const auto &e = set.entries()[i];
        const auto &s = ordered.attempts()[i];
        VWB_EXPECT_EQ(s.attempt.durable_id, e.durable_id);
        VWB_EXPECT_EQ(s.outcome, e.outcome);
        const bool anchored = e.presence == NativeSurfacePropPlacementPresence::anchored;
        const auto frame = resolve_native_surface_prop_chunk_frame(e.chunk_x, e.chunk_z,
            e.cell_x, e.cell_z, definition.constants().cell_size_meters,
            anchored ? s.source->surface.world_anchor_y : 0.0F);
        expect_position(frame.chunk_origin, e.chunk_origin);
        expect_position(frame.local_position, e.local_position);
        if (anchored) {
            expect_position(frame.world_anchor, e.world_anchor);
            VWB_EXPECT_EQ(s.source->surface.height_meters, e.source_height_meters);
        } else expect_position(WorldFloat32Position{}, e.world_anchor);
    }
}

VWB_TEST(native_ordered_placement_tombstone_is_absent_and_changes_ordered_digest) {
    const auto definition = surface_prop_test_fixture::definition("ordered-placement-tombstone");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto intact = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}));
    const auto removed = stream(terrain, NativeFeatureDeltaSnapshot::create(
        {{intact.attempts()[0].attempt.durable_id}}, {}));
    const auto first = NativeSurfacePropOrderedPlacement::create(intact, terrain);
    const auto second = NativeSurfacePropOrderedPlacement::create(removed, terrain);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::absent, second.entries()[0].presence);
    VWB_EXPECT_EQ(Sha256Digest{}, second.entries()[0].source_decision_digest);
    expect_position(WorldFloat32Position{}, second.entries()[0].world_anchor);
    VWB_EXPECT(first.content_digest() != second.content_digest());
    VWB_EXPECT(first.entries()[1].durable_id != second.entries()[1].durable_id);
}

VWB_TEST(native_ordered_placement_rejects_stale_pinned_surface_facts) {
    bool covered = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !covered; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-pin-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto ordered = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}));
        bool has_anchor = false;
        for (const auto &attempt : ordered.attempts()) {
            if (attempt.source.has_value() && attempt.source->has_surface
                && attempt.source->surface.found
                && attempt.outcome != NativeSurfacePropClassificationOutcome::no_feature
                && attempt.outcome != NativeSurfacePropClassificationOutcome::skipped_before_prop_roll) {
                has_anchor = true;
                break;
            }
        }
        if (!has_anchor) continue;
        const auto different_definition = surface_prop_test_fixture::definition("stale-pin");
        const NativeEffectiveTerrainSource stale(surface_prop_test_fixture::ready_pin(
            different_definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected,
            NativeSurfacePropOrderedPlacement::create(ordered, stale));
        covered = true;
    }
    VWB_EXPECT(covered);
}

VWB_TEST(native_ordered_placement_entry_rejects_mutated_capture_facts) {
    const auto definition = surface_prop_test_fixture::definition("ordered-entry-validation");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto ordered = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}));
    const auto &pin = terrain.pin();
    const auto valid = ordered.attempts()[0];
    const auto check = [&](const NativeSurfacePropOrderedAttempt &entry,
        std::uint32_t ordinal = 0U, std::int32_t chunk_x = 0, std::int32_t chunk_z = 0,
        std::optional<std::uint64_t> prior = std::nullopt) {
        return resolve_native_surface_prop_ordered_placement_entry(entry, ordinal, chunk_x, chunk_z, pin, prior);
    };
    static_cast<void>(check(valid));
    auto changed = valid;
    changed.attempt.ordinal = 1U;
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected, check(changed));
    changed = valid; changed.attempt.durable_id.clear();
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected, check(changed));
    changed = valid; changed.attempt.cell_x = 10000;
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected, check(changed));
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected, check(valid, 0U, 1));
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected, check(valid, 0U, 0, 1));
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected,
        check(valid, 0U, 0, 0, valid.state_before_coordinates + 1U));
    changed = valid; changed.parent_tombstoned = true;
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected, check(changed));
    changed = valid; changed.parent_tombstoned = true; changed.source.reset();
    changed.outcome = NativeSurfacePropClassificationOutcome::ordinary_rock;
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected, check(changed));
    changed = valid; changed.source.reset();
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected, check(changed));
    changed = valid; changed.source->classification.source_decision_digest = {};
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected, check(changed));

    bool found_physical = false;
    for (const auto &source : ordered.attempts()) {
        if (!native_surface_prop_outcome_has_placement(source.outcome)) continue;
        found_physical = true;
        const auto ordinal = source.attempt.ordinal;
        const auto reject_mutation = [&](const NativeSurfacePropOrderedAttempt &entry) {
            VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected,
                resolve_native_surface_prop_ordered_placement_entry(entry, ordinal, 0, 0, pin, std::nullopt));
        };
        changed = source; changed.source->has_surface = false; reject_mutation(changed);
        changed = source; changed.source->surface.found = false; reject_mutation(changed);
        changed = source; changed.source->surface.physical_content_identity = {};
        reject_mutation(changed);
        changed = source; ++changed.source->surface.terrain_delta_revision; reject_mutation(changed);
        changed = source; ++changed.source->surface.shaping_registry_revision; reject_mutation(changed);
        changed = source; changed.source->surface.height_meters = std::numeric_limits<double>::infinity();
        reject_mutation(changed);
        changed = source; changed.source->surface.world_anchor_y = std::numeric_limits<float>::infinity();
        reject_mutation(changed);
        changed = source; changed.parent_tombstoned = true; reject_mutation(changed);
        break;
    }
    VWB_EXPECT(found_physical);
}

VWB_TEST(native_ordered_placement_rejects_stale_pin_even_without_any_surface_sample) {
    const auto definition = surface_prop_test_fixture::definition("ordered-fully-excluded");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent;
    absent.source_key = "world:0,0";
    const auto blocked = NativeStructureExclusionSnapshot::create(world_digest(), 1U,
        {{"all-natural-props", {0, 0, 27, 27}}}, {}, {absent}, {{0, 0, true}});
    const auto ordered = NativeSurfacePropSourceOrderedStream::create(
        definition.raw_terrain_seed(), 0, 0, world_digest(), 1U, terrain,
        NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles()),
        blocked, NativeFeatureDeltaSnapshot::create({}, {}), wildlife());
    for (const auto &attempt : ordered.attempts()) {
        VWB_EXPECT(attempt.source.has_value());
        VWB_EXPECT(!attempt.source->has_surface);
    }
    const auto correct = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    for (const auto &entry : correct.entries())
        VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::absent, entry.presence);
    const auto stale_definition = surface_prop_test_fixture::definition("stale-fully-excluded");
    const NativeEffectiveTerrainSource stale(surface_prop_test_fixture::ready_pin(
        stale_definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    VWB_EXPECT_THROW(NativeSurfacePropOrderedPlacementRejected,
        NativeSurfacePropOrderedPlacement::create(ordered, stale));
}

VWB_TEST(native_ordered_placement_binds_world_generation_without_changing_seeded_coordinates) {
    const auto definition = surface_prop_test_fixture::definition("ordered-world-generation");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto first = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}));
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent;
    absent.source_key = "world:0,0";
    const auto second_exclusions = NativeStructureExclusionSnapshot::create(
        world_digest(), 2U, {}, {}, {absent}, {{0, 0, true}});
    const auto second = NativeSurfacePropSourceOrderedStream::create(
        definition.raw_terrain_seed(), 0, 0, world_digest(), 2U, terrain,
        NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles()),
        second_exclusions, NativeFeatureDeltaSnapshot::create({}, {}), wildlife());
    VWB_EXPECT_EQ(first.rng_seed(), second.rng_seed());
    VWB_EXPECT_EQ(first.final_rng_state(), second.final_rng_state());
    for (std::size_t i = 0; i < first.attempts().size(); ++i)
        VWB_EXPECT_EQ(first.attempts()[i].attempt.durable_id, second.attempts()[i].attempt.durable_id);
    VWB_EXPECT(NativeSurfacePropOrderedPlacement::create(first, terrain).content_digest()
        != NativeSurfacePropOrderedPlacement::create(second, terrain).content_digest());
}
