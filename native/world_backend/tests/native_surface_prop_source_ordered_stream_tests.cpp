#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_prop_source_ordered_stream.hpp"

#include <utility>

using namespace voxel::world_backend;

namespace {

Sha256Digest world_digest() { Sha256Digest digest{}; digest[0] = 17U; return digest; }

NativeStructureExclusionSnapshot exclusions(bool complete = true) {
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent;
    absent.source_key = "world:0,0";
    return NativeStructureExclusionSnapshot::create(world_digest(), 1U, {}, {},
        complete ? std::vector<CitadelExclusionSource>{absent} : std::vector<CitadelExclusionSource>{},
        {{0,0,true}});
}

NativeWildlifePresentationReceipt presentation(NativeWildlifeVariant variant, const char *asset) {
    NativeWildlifePresentationReceipt receipt;
    receipt.schema_revision = 1U;
    receipt.asset_catalog_digest.fill(1U);
    receipt.variant = variant;
    receipt.path = NativeWildlifePresentationPath::animated_playable;
    receipt.asset_id = asset;
    receipt.animation_clip_id = asset;
    return receipt;
}

NativeWildlifePresentationCatalog wildlife_catalog() {
    return NativeWildlifePresentationCatalog::create({
        presentation(NativeWildlifeVariant::boar, "boar_idle_walk"),
        presentation(NativeWildlifeVariant::deer, "deer_idle_walk"),
        presentation(NativeWildlifeVariant::hare, "hare_idle_walk")});
}

NativeSurfacePropSourceOrderedStream run(const NativeEffectiveTerrainSource &terrain,
    const NativeFeatureDeltaSnapshot &removed, const NativeStructureExclusionSnapshot &structure) {
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        0, 0, world_digest(), 1U, terrain,
        NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles()),
        structure, removed, wildlife_catalog());
}

NativeSurfacePropSourceOrderedStream run_with_catalog(const NativeEffectiveTerrainSource &terrain,
    const NativeFeatureDeltaSnapshot &removed, const NativeBiomeEnvironmentCatalog &catalog) {
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        0, 0, world_digest(), 1U, terrain, catalog, exclusions(), removed, wildlife_catalog());
}

} // namespace

VWB_TEST(native_source_ordered_prop_stream_policy_helper_contract) {
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::cold, native_surface_prop_wildlife_group("snow"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::cold, native_surface_prop_wildlife_group("tundra"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::cold, native_surface_prop_wildlife_group("alpine"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::cold, native_surface_prop_wildlife_group("taiga"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::forest_or_plains,
        native_surface_prop_wildlife_group("forest"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::forest_or_plains,
        native_surface_prop_wildlife_group("plains"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::dry, native_surface_prop_wildlife_group("savanna"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::dry, native_surface_prop_wildlife_group("desert"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::dry, native_surface_prop_wildlife_group("beach"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::swamp, native_surface_prop_wildlife_group("swamp"));
    VWB_EXPECT_EQ(NativeWildlifeBiomeGroup::other, native_surface_prop_wildlife_group("ocean"));
    VWB_EXPECT_EQ(6U, native_surface_prop_compatibility_draw_count(
        NativeSurfacePropClassificationOutcome::ordinary_rock));
    VWB_EXPECT_EQ(36U, native_surface_prop_compatibility_draw_count(
        NativeSurfacePropClassificationOutcome::tree_36_draw));
    VWB_EXPECT_EQ(22U, native_surface_prop_compatibility_draw_count(
        NativeSurfacePropClassificationOutcome::tree_22_draw));
    for (const auto outcome : {NativeSurfacePropClassificationOutcome::skipped_before_prop_roll,
        NativeSurfacePropClassificationOutcome::no_feature,
        NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster,
        NativeSurfacePropClassificationOutcome::unported_copper_ore_cluster,
        NativeSurfacePropClassificationOutcome::forage_recipe,
        NativeSurfacePropClassificationOutcome::wildlife_recipe})
        VWB_EXPECT_EQ(0U, native_surface_prop_compatibility_draw_count(outcome));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        native_surface_prop_compatibility_draw_count(
            static_cast<NativeSurfacePropClassificationOutcome>(0U)));
}

VWB_TEST(native_source_ordered_prop_stream_checks_cancellation_between_attempts) {
    const auto definition = surface_prop_test_fixture::definition("ordered-props-cancel");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    const auto structure = exclusions();
    const auto removed = NativeFeatureDeltaSnapshot::create({}, {});
    std::size_t checks = 0U;
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamCancelled,
        NativeSurfacePropSourceOrderedStream::create(
            terrain.pin().definition().raw_terrain_seed(), 0, 0, world_digest(), 1U,
            terrain, catalog, structure, removed, wildlife_catalog(), [&checks]() {
                return ++checks >= 3U;
            }));
    VWB_EXPECT_EQ(3U, checks);
}

VWB_TEST(native_source_ordered_prop_stream_checks_cancellation_before_and_after_attempts) {
    const auto definition = surface_prop_test_fixture::definition("ordered-props-cancel-boundaries");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    const auto structure = exclusions();
    const auto removed = NativeFeatureDeltaSnapshot::create({}, {});
    const auto wildlife = wildlife_catalog();
    std::size_t checks = 0U;
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamCancelled,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(),
            0, 0, world_digest(), 1U, terrain, catalog, structure, removed, wildlife,
            [&checks]() { return ++checks == 1U; }));
    VWB_EXPECT_EQ(1U, checks);
    checks = 0U;
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamCancelled,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(),
            0, 0, world_digest(), 1U, terrain, catalog, structure, removed, wildlife,
            [&checks]() { return ++checks == NativeSurfacePropAttemptStream::ATTEMPT_COUNT + 2U; }));
    VWB_EXPECT_EQ(NativeSurfacePropAttemptStream::ATTEMPT_COUNT + 2U, checks);

    checks = 0U;
    const auto completed = NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(),
        0, 0, world_digest(), 1U, terrain, catalog, structure, removed, wildlife,
        [&checks]() { ++checks; return false; });
    VWB_EXPECT_EQ(NativeSurfacePropAttemptStream::ATTEMPT_COUNT, completed.attempts().size());
    VWB_EXPECT_EQ(NativeSurfacePropAttemptStream::ATTEMPT_COUNT + 2U, checks);
}

VWB_TEST(native_source_ordered_prop_stream_interleaves_all_28_attempts_and_parent_tombstone) {
    const auto definition = surface_prop_test_fixture::definition("ordered-props");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto structure = exclusions();
    const auto intact = run(terrain, NativeFeatureDeltaSnapshot::create({}, {}), structure);
    const auto repeat = run(terrain, NativeFeatureDeltaSnapshot::create({}, {}), exclusions());
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    VWB_EXPECT_EQ(0, intact.chunk_x());
    VWB_EXPECT_EQ(0, intact.chunk_z());
    VWB_EXPECT_EQ(world_digest(), intact.world_digest());
    VWB_EXPECT_EQ(1U, intact.world_generation());
    VWB_EXPECT(intact.source_receipt().matches_pin(terrain.pin()));
    VWB_EXPECT_EQ(NativeBiomeEnvironmentCatalog::SCHEMA_REVISION,
        intact.source_receipt().environment_profile_revision);
    VWB_EXPECT_EQ(catalog.content_digest(), intact.source_receipt().environment_profile_digest);
    VWB_EXPECT_EQ(structure.content_digest(), intact.exclusion_digest());
    VWB_EXPECT_EQ(intact.final_rng_state(), repeat.final_rng_state());
    for (std::size_t i = 0; i < intact.attempts().size(); ++i) {
        VWB_EXPECT_EQ(intact.attempts()[i].attempt, repeat.attempts()[i].attempt);
        VWB_EXPECT_EQ(intact.attempts()[i].state_after_recipe, repeat.attempts()[i].state_after_recipe);
    }
    VWB_EXPECT_EQ(28U, intact.attempts().size());
    VWB_EXPECT(intact.attempts()[0].state_after_recipe != intact.attempts()[0].state_after_coordinates);
    GodotPcg32 replay(intact.rng_seed());
    VWB_EXPECT_EQ(replay.state(), intact.attempts()[0].state_before_coordinates);
    for (std::uint32_t ordinal = 0U; ordinal < 28U; ++ordinal) {
        const auto &entry = intact.attempts()[ordinal];
        VWB_EXPECT_EQ(ordinal, entry.attempt.ordinal);
        VWB_EXPECT_EQ(replay.state(), entry.state_before_coordinates);
        VWB_EXPECT_EQ(2 + replay.randi_range(0,24), entry.attempt.cell_x);
        VWB_EXPECT_EQ(2 + replay.randi_range(0,24), entry.attempt.cell_z);
        VWB_EXPECT_EQ(replay.state(), entry.state_after_coordinates);
        VWB_EXPECT(!entry.parent_tombstoned);
        VWB_EXPECT(entry.source.has_value());
        if (entry.source->has_surface)
            VWB_EXPECT_EQ(terrain.pin().physical_content_identity().digest,
                entry.source->surface.physical_content_identity.digest);
        replay.set_state(entry.state_after_recipe);
    }
    VWB_EXPECT_EQ(replay.state(), intact.final_rng_state());

    const auto first_id = intact.attempts()[0].attempt.durable_id;
    const auto removed = NativeFeatureDeltaSnapshot::create({{first_id}}, {});
    const auto filtered = run(terrain, removed, exclusions());
    VWB_EXPECT_EQ(first_id, filtered.attempts()[0].attempt.durable_id);
    VWB_EXPECT(filtered.attempts()[0].parent_tombstoned);
    VWB_EXPECT(!filtered.attempts()[0].source.has_value());
    VWB_EXPECT_EQ(filtered.attempts()[0].state_after_coordinates,
        filtered.attempts()[0].state_after_classification);
    VWB_EXPECT_EQ(filtered.attempts()[0].state_after_coordinates,
        filtered.attempts()[0].state_after_recipe);
    VWB_EXPECT_EQ(filtered.attempts()[0].state_after_recipe,
        filtered.attempts()[1].state_before_coordinates);
    VWB_EXPECT(intact.attempts()[1].attempt.durable_id != filtered.attempts()[1].attempt.durable_id);
    VWB_EXPECT(intact.final_rng_state() != filtered.final_rng_state());
}

VWB_TEST(native_source_ordered_prop_stream_child_tombstone_shifts_later_coordinates) {
    // Synthetic high-rock policy forces the real resolver/classifier/ore
    // sequence without exposing caller-authored decisions in production.
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) profile.rock_base_chance = 1.0;
    const auto catalog = NativeBiomeEnvironmentCatalog::create(std::move(profiles));
    bool proved = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !proved; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-ore-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto intact = run_with_catalog(terrain, NativeFeatureDeltaSnapshot::create({}, {}), catalog);
        for (std::size_t ore_ordinal = 0U; ore_ordinal + 1U < intact.attempts().size(); ++ore_ordinal) {
            if (!intact.attempts()[ore_ordinal].ore_cluster.has_value()) continue;
            const auto child_id = intact.attempts()[ore_ordinal].attempt.durable_id + ":cluster1";
            const auto removed = NativeFeatureDeltaSnapshot::create({{child_id}}, {});
            const auto filtered = run_with_catalog(terrain, removed, catalog);
            VWB_EXPECT(filtered.attempts()[ore_ordinal].ore_cluster.has_value());
            VWB_EXPECT(filtered.attempts()[ore_ordinal].ore_cluster->children()[1].skipped_by_tombstone);
            VWB_EXPECT_EQ(filtered.attempts()[ore_ordinal].ore_cluster->children()[1].state_before,
                filtered.attempts()[ore_ordinal].ore_cluster->children()[1].state_after);
            VWB_EXPECT(intact.attempts()[ore_ordinal + 1U].attempt.durable_id
                != filtered.attempts()[ore_ordinal + 1U].attempt.durable_id);
            VWB_EXPECT(intact.final_rng_state() != filtered.final_rng_state());
            proved = true;
            break;
        }
    }
    VWB_EXPECT(proved);
}

VWB_TEST(native_source_ordered_prop_stream_requires_matching_pinned_seed_and_complete_admission) {
    const auto definition = surface_prop_test_fixture::definition("ordered-props");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    const auto removed = NativeFeatureDeltaSnapshot::create({}, {});
    const auto wildlife = wildlife_catalog();
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(admit_raw_terrain_seed("other"), 0, 0,
            world_digest(), 1U, terrain, catalog, exclusions(), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 0,
            world_digest(), 1U, terrain, catalog, exclusions(false), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 0,
            world_digest(), 2U, terrain, catalog, exclusions(), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 10, 0,
            world_digest(), 1U, terrain, catalog, exclusions(), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 0,
            {}, 1U, terrain, catalog, exclusions(), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 0,
            world_digest(), 0U, terrain, catalog, exclusions(), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 0,
            world_digest(), 1U, terrain, catalog,
            NativeStructureExclusionSnapshot::create(world_digest(), 1U, {}, {},
                {{0,0,CitadelSourceStatus::pending,"pending",""}}, {{0,0,true}}), removed, wildlife));
    Sha256Digest other_world = world_digest();
    other_world[0] = 18U;
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 0,
            other_world, 1U, terrain, catalog, exclusions(), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 0,
            world_digest(), 3U, terrain, catalog, exclusions(), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), -1, 0,
            world_digest(), 1U, terrain, catalog, exclusions(), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, -1,
            world_digest(), 1U, terrain, catalog, exclusions(), removed, wildlife));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 10,
            world_digest(), 1U, terrain, catalog, exclusions(), removed, wildlife));
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent;
    absent.source_key = "world:0,0";
    const auto wrong_bounds = NativeStructureExclusionSnapshot::create(world_digest(), 1U,
        {}, {}, {absent}, {{28,0,true}});
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 0,
            world_digest(), 1U, terrain, catalog, wrong_bounds, removed, wildlife));
    const auto wrong_z_bounds = NativeStructureExclusionSnapshot::create(world_digest(), 1U,
        {}, {}, {absent}, {{0,28,true}});
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        NativeSurfacePropSourceOrderedStream::create(definition.raw_terrain_seed(), 0, 0,
            world_digest(), 1U, terrain, catalog, wrong_z_bounds, removed, wildlife));
}

VWB_TEST(native_source_ordered_prop_stream_rejects_unadmitted_forage_recipe) {
    const auto definition = surface_prop_test_fixture::definition("ordered-bad-forage");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) {
        profile.rock_base_chance = 0.0;
        profile.tree_chance = 0.0;
        profile.forage_chance = 1.0;
        profile.wildlife_chance = 0.0;
        profile.forage_material = "unsupportedForage";
    }
    const auto catalog = NativeBiomeEnvironmentCatalog::create(std::move(profiles));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        run_with_catalog(terrain, NativeFeatureDeltaSnapshot::create({}, {}), catalog));
}

VWB_TEST(native_source_ordered_prop_stream_converts_invalid_forage_receipt) {
    const auto definition = surface_prop_test_fixture::definition("ordered-bad-drop");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) {
        profile.rock_base_chance = 0.0;
        profile.tree_chance = 0.0;
        profile.forage_chance = 1.0;
        profile.wildlife_chance = 0.0;
        profile.forage_material = "berryBush";
        profile.forage_drop = "invalidDrop";
    }
    const auto catalog = NativeBiomeEnvironmentCatalog::create(std::move(profiles));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        run_with_catalog(terrain, NativeFeatureDeltaSnapshot::create({}, {}), catalog));
}

VWB_TEST(native_source_ordered_prop_stream_skips_structure_blocked_attempts) {
    const auto definition = surface_prop_test_fixture::definition("ordered-blocked");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto blocked = NativeStructureExclusionSnapshot::create(world_digest(), 1U,
        {{"blocked", {0,0,27,27}}}, {}, {{0,0,CitadelSourceStatus::absent,"","world:0,0"}}, {{0,0,true}});
    const auto stream = run(terrain, NativeFeatureDeltaSnapshot::create({}, {}), blocked);
    for (const auto &entry : stream.attempts()) {
        VWB_EXPECT_EQ(NativeSurfacePropClassificationOutcome::skipped_before_prop_roll, entry.outcome);
        VWB_EXPECT(!entry.prop_roll.has_value());
        VWB_EXPECT_EQ(entry.state_after_coordinates, entry.state_after_recipe);
    }
    auto unrequested = CitadelExclusionSource{};
    unrequested.status = CitadelSourceStatus::absent;
    unrequested.reason = "source_not_requested";
    const auto admitted_irrelevant = NativeStructureExclusionSnapshot::create(world_digest(), 1U,
        {{"blocked", {0,0,27,27}}}, {}, {unrequested}, {{0,0,true}});
    VWB_EXPECT(admitted_irrelevant.query(10, 10).blocked);
    VWB_EXPECT(admitted_irrelevant.covers_decided_regions(0, 0, 27, 27));
    VWB_EXPECT_EQ(28U, run(terrain, NativeFeatureDeltaSnapshot::create({}, {}), admitted_irrelevant).attempts().size());
    unrequested.status = CitadelSourceStatus::pending;
    unrequested.reason = "preparing_citadel_terrain";
    const auto masked_pending = NativeStructureExclusionSnapshot::create(world_digest(), 1U,
        {{"blocked", {0,0,27,27}}}, {}, {unrequested}, {{0,0,true}});
    VWB_EXPECT(!masked_pending.covers_decided_regions(0, 0, 27, 27));
    VWB_EXPECT_THROW(NativeSurfacePropSourceOrderedStreamRejected,
        run(terrain, NativeFeatureDeltaSnapshot::create({}, {}), masked_pending));
}

VWB_TEST(native_source_ordered_prop_stream_replays_forage_and_wildlife_recipes) {
    const auto definition = surface_prop_test_fixture::definition("ordered-recipes");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto removed = NativeFeatureDeltaSnapshot::create({}, {});
    for (const char *material : {"berryBush", "aloePatch", "mushroomCluster", "frostHerbPatch"}) {
        auto profiles = tests::godot_oracle_environment_profiles();
        for (auto &profile : profiles) {
            profile.rock_base_chance = 0.0;
            profile.tree_chance = 0.0;
            profile.forage_chance = 1.0;
            profile.wildlife_chance = 0.0;
            profile.forage_material = material;
            profile.forage_drop = std::string(material) == "berryBush" ? "berries"
                : std::string(material) == "aloePatch" ? "aloe"
                : std::string(material) == "mushroomCluster" ? "mirecap" : "frostHerb";
        }
        const auto stream = run_with_catalog(terrain, removed,
            NativeBiomeEnvironmentCatalog::create(std::move(profiles)));
        bool found = false;
        for (const auto &entry : stream.attempts()) {
            if (entry.outcome != NativeSurfacePropClassificationOutcome::forage_recipe) continue;
            VWB_EXPECT(entry.forage.has_value());
            VWB_EXPECT(entry.source->has_surface);
            VWB_EXPECT_EQ(material, entry.forage->recipe.material_id);
            found = true;
        }
        VWB_EXPECT(found);
    }
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) {
        profile.rock_base_chance = 0.0;
        profile.tree_chance = 0.0;
        profile.forage_chance = 0.0;
        profile.wildlife_chance = 1.0;
    }
    const auto stream = run_with_catalog(terrain, removed,
        NativeBiomeEnvironmentCatalog::create(std::move(profiles)));
    bool found = false;
    for (const auto &entry : stream.attempts()) {
        if (entry.outcome != NativeSurfacePropClassificationOutcome::wildlife_recipe) continue;
        VWB_EXPECT(entry.wildlife.has_value());
        VWB_EXPECT(entry.source->has_surface);
        found = true;
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_source_ordered_prop_stream_replays_both_tree_grammars) {
    const auto definition = surface_prop_test_fixture::definition("ordered-trees");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) {
        profile.rock_base_chance = 0.0;
        profile.tree_chance = 1.0;
        profile.forage_chance = 0.0;
        profile.wildlife_chance = 0.0;
    }
    const auto stream = run_with_catalog(terrain, NativeFeatureDeltaSnapshot::create({}, {}),
        NativeBiomeEnvironmentCatalog::create(std::move(profiles)));
    bool long_tree = false;
    bool short_tree = false;
    for (const auto &entry : stream.attempts()) {
        if (entry.outcome == NativeSurfacePropClassificationOutcome::tree_36_draw) {
            VWB_EXPECT_EQ(36U, entry.compatibility_draws.size());
            long_tree = true;
        }
        if (entry.outcome == NativeSurfacePropClassificationOutcome::tree_22_draw) {
            VWB_EXPECT_EQ(22U, entry.compatibility_draws.size());
            short_tree = true;
        }
    }
    VWB_EXPECT(long_tree || short_tree);
}

VWB_TEST(native_source_ordered_prop_stream_builds_iron_ore_children) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) profile.rock_base_chance = 1.0;
    const auto catalog = NativeBiomeEnvironmentCatalog::create(std::move(profiles));
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 256U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-iron-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto stream = run_with_catalog(terrain, NativeFeatureDeltaSnapshot::create({}, {}), catalog);
        for (const auto &entry : stream.attempts()) {
            if (entry.outcome != NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster) continue;
            VWB_EXPECT(entry.ore_cluster.has_value());
            VWB_EXPECT(!entry.ore_cluster->children().empty());
            found = true;
            break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_source_ordered_prop_stream_uses_swamp_wildlife_policy) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) {
        profile.rock_base_chance = 0.0;
        profile.tree_chance = 0.0;
        profile.forage_chance = 0.0;
        profile.wildlife_chance = 1.0;
    }
    const auto catalog = NativeBiomeEnvironmentCatalog::create(std::move(profiles));
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 256U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-swamp-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto stream = run_with_catalog(terrain, NativeFeatureDeltaSnapshot::create({}, {}), catalog);
        for (const auto &entry : stream.attempts()) {
            if (entry.outcome != NativeSurfacePropClassificationOutcome::wildlife_recipe
                || entry.source->biome_id != "swamp") continue;
            VWB_EXPECT(entry.wildlife.has_value());
            VWB_EXPECT(entry.wildlife->recipe.variant == NativeWildlifeVariant::boar
                || entry.wildlife->recipe.variant == NativeWildlifeVariant::hare);
            found = true;
            break;
        }
    }
    VWB_EXPECT(found);
}
