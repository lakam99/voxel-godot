#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_feature_manifest.hpp"

using namespace voxel::world_backend;

namespace {

Sha256Digest world_digest() { Sha256Digest d{}; d[0] = 93U; return d; }

CitadelExclusionSource absent(std::int32_t x, std::int32_t z) {
    CitadelExclusionSource c;
    c.region_x = x; c.region_z = z; c.status = CitadelSourceStatus::absent;
    c.source_key = "world:" + std::to_string(x) + "," + std::to_string(z);
    return c;
}

NativeStructureExclusionSnapshot exclusions(Sha256Digest digest = world_digest()) {
    return NativeStructureExclusionSnapshot::create(digest, 1U, {}, {}, {absent(0,0)}, {{0,0,true}});
}

NativeTreeExclusionHaloCapture halo(const NativeStructureExclusionSnapshot &center,
    std::vector<StructureExclusionRecord> natural = {}) {
    return NativeTreeExclusionHaloCapture::create(center.world_digest(), center.world_generation(),
        center.content_digest(), {-100,-100,130,130}, std::move(natural), {},
        {absent(-1,-1), absent(0,-1), absent(-1,0), absent(0,0)});
}

NativeWildlifePresentationReceipt animal(NativeWildlifeVariant variant, const char *asset) {
    NativeWildlifePresentationReceipt r;
    r.schema_revision = 1U; r.asset_catalog_digest.fill(1U);
    r.variant = variant; r.path = NativeWildlifePresentationPath::animated_playable;
    r.asset_id = asset; r.animation_clip_id = asset;
    return r;
}

NativeWildlifePresentationCatalog wildlife() {
    return NativeWildlifePresentationCatalog::create({
        animal(NativeWildlifeVariant::boar, "boar_idle_walk"),
        animal(NativeWildlifeVariant::deer, "deer_idle_walk"),
        animal(NativeWildlifeVariant::hare, "hare_idle_walk")});
}

NativeSurfaceRockAssetCatalog rocks(const NativeBiomeEnvironmentCatalog &catalog) {
    NativeSurfaceRockAssetRecord record;
    record.id = "rock_01"; record.family = "rock"; record.path = "res://rock_01.glb";
    return NativeSurfaceRockAssetCatalog::create({record}, catalog);
}

NativeSurfacePropSourceOrderedStream ordered(const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog, const NativeStructureExclusionSnapshot &structure,
    const NativeFeatureDeltaSnapshot &removed, std::int32_t chunk_x = 0, std::int32_t chunk_z = 0) {
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        chunk_x, chunk_z, structure.world_digest(), structure.world_generation(), terrain,
        catalog, structure, removed, wildlife());
}

NativeSurfaceFeatureManifest compose(const NativeSurfacePropSourceOrderedStream &source,
    const NativeSurfacePropOrderedPlacement &placement, const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog, const NativeSurfaceRockAssetCatalog &assets,
    const NativeStructureExclusionSnapshot &structure, const NativeTreeExclusionHaloCapture *capture) {
    return NativeSurfaceFeatureManifest::create(source, placement, terrain, catalog, assets,
        structure, wildlife(), capture);
}

} // namespace

VWB_TEST(native_surface_feature_manifest_composes_all_attempts_and_detects_stale_inputs) {
    const auto definition = surface_prop_test_fixture::definition("feature-manifest");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    const auto assets = rocks(catalog);
    const auto structure = exclusions();
    const auto source = ordered(terrain, catalog, structure, NativeFeatureDeltaSnapshot::create({}, {}));
    const auto placement = NativeSurfacePropOrderedPlacement::create(source, terrain);
    const auto capture = halo(structure);
    const auto manifest = compose(source, placement, terrain, catalog, assets, structure, &capture);
    const auto repeat = compose(source, placement, terrain, catalog, assets, structure, &capture);
    VWB_EXPECT_EQ(manifest.content_digest(), repeat.content_digest());
    VWB_EXPECT_EQ(source.final_rng_state(), manifest.final_rng_state());
    VWB_EXPECT_EQ(source.world_digest(), manifest.world_digest());
    VWB_EXPECT_EQ(source.world_generation(), manifest.world_generation());
    VWB_EXPECT_EQ(source.chunk_x(), manifest.chunk_x());
    VWB_EXPECT_EQ(source.chunk_z(), manifest.chunk_z());
    VWB_EXPECT_EQ(placement.content_digest(), manifest.placement_digest());
    VWB_EXPECT_EQ(structure.content_digest(), manifest.exclusion_digest());
    VWB_EXPECT(!manifest.canonical_binary().empty());
    VWB_EXPECT_EQ(28U, manifest.entries().size());
    for (std::uint32_t i = 0; i < 28U; ++i) {
        const auto &entry = manifest.entries()[i];
        const auto &attempt = source.attempts()[i];
        VWB_EXPECT_EQ(i, entry.placement.ordinal);
        VWB_EXPECT_EQ(attempt.attempt.durable_id, entry.placement.durable_id);
        VWB_EXPECT_EQ(attempt.state_after_recipe, entry.state_after_recipe);
        VWB_EXPECT_EQ(attempt.parent_tombstoned, entry.parent_tombstoned);
        VWB_EXPECT_EQ(attempt.outcome == NativeSurfacePropClassificationOutcome::ordinary_rock,
            entry.rock.has_value());
        VWB_EXPECT_EQ(attempt.ore_cluster.has_value(), entry.ore.has_value());
        VWB_EXPECT_EQ(attempt.forage.has_value(), entry.forage.has_value());
        VWB_EXPECT_EQ(attempt.wildlife.has_value(), entry.wildlife.has_value());
        VWB_EXPECT_EQ(attempt.outcome == NativeSurfacePropClassificationOutcome::tree_22_draw
            || attempt.outcome == NativeSurfacePropClassificationOutcome::tree_36_draw,
            entry.tree.has_value());
        VWB_EXPECT_EQ(entry.tree.has_value(), entry.tree_presence.has_value());
    }
    auto changed_profiles = tests::godot_oracle_environment_profiles();
    changed_profiles[0].rock_base_chance = 0.123;
    const auto stale_catalog = NativeBiomeEnvironmentCatalog::create(changed_profiles);
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, terrain, stale_catalog, assets, structure, &capture));
    const auto stale_assets = rocks(stale_catalog);
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, terrain, catalog, stale_assets, structure, &capture));
    const auto stale_structure = exclusions([] { auto d = world_digest(); d[0] = 94U; return d; }());
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, terrain, catalog, assets, stale_structure, &capture));
    const auto changed_exclusions = NativeStructureExclusionSnapshot::create(world_digest(), 1U,
        {{"new-natural-source", {20,20,21,21}}}, {}, {absent(0,0)}, {{0,0,true}});
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, terrain, catalog, assets, changed_exclusions, &capture));
    const auto stale_generation = NativeStructureExclusionSnapshot::create(world_digest(), 2U,
        {}, {}, {absent(0,0)}, {{0,0,true}});
    VWB_EXPECT_EQ(structure.content_digest(), stale_generation.content_digest());
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, terrain, catalog, assets, stale_generation, &capture));
    const auto wrong_definition = surface_prop_test_fixture::definition("feature-manifest-wrong-source");
    const NativeEffectiveTerrainSource wrong_terrain(surface_prop_test_fixture::ready_pin(
        wrong_definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, wrong_terrain, catalog, assets, structure, &capture));
    const auto stale_halo = NativeTreeExclusionHaloCapture::create(world_digest(), 2U,
        structure.content_digest(), {-100,-100,130,130}, {}, {},
        {absent(-1,-1), absent(0,-1), absent(-1,0), absent(0,0)});
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, terrain, catalog, assets, structure, &stale_halo));
    auto wrong_world = world_digest(); wrong_world[0] ^= 0x01U;
    const auto wrong_world_halo = NativeTreeExclusionHaloCapture::create(wrong_world, 1U,
        structure.content_digest(), {-100,-100,130,130}, {}, {},
        {absent(-1,-1), absent(0,-1), absent(-1,0), absent(0,0)});
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, terrain, catalog, assets, structure, &wrong_world_halo));
    auto wrong_center = structure.content_digest(); wrong_center[0] ^= 0x01U;
    const auto stale_center_halo = NativeTreeExclusionHaloCapture::create(world_digest(), 1U,
        wrong_center, {-100,-100,130,130}, {}, {},
        {absent(-1,-1), absent(0,-1), absent(-1,0), absent(0,0)});
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, terrain, catalog, assets, structure, &stale_center_halo));
    const auto filtered = ordered(terrain, catalog, structure,
        NativeFeatureDeltaSnapshot::create({{source.attempts()[0].attempt.durable_id}}, {}));
    const auto stale_placement = NativeSurfacePropOrderedPlacement::create(filtered, terrain);
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, stale_placement, terrain, catalog, assets, structure, &capture));
}

VWB_TEST(native_surface_feature_manifest_preserves_root_tombstone_rng_suffix) {
    const auto definition = surface_prop_test_fixture::definition("feature-manifest-root");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    const auto assets = rocks(catalog); const auto structure = exclusions(); const auto capture = halo(structure);
    const auto intact = ordered(terrain, catalog, structure, NativeFeatureDeltaSnapshot::create({}, {}));
    const auto removed = NativeFeatureDeltaSnapshot::create({{intact.attempts()[0].attempt.durable_id}}, {});
    const auto filtered = ordered(terrain, catalog, structure, removed);
    const auto placement = NativeSurfacePropOrderedPlacement::create(filtered, terrain);
    const auto manifest = compose(filtered, placement, terrain, catalog, assets, structure, &capture);
    VWB_EXPECT(manifest.entries()[0].parent_tombstoned);
    VWB_EXPECT_EQ(filtered.attempts()[0].state_after_coordinates, manifest.entries()[0].state_after_recipe);
    VWB_EXPECT_EQ(filtered.attempts()[1].state_before_coordinates, manifest.entries()[0].state_after_recipe);
    VWB_EXPECT_EQ(filtered.final_rng_state(), manifest.final_rng_state());
    VWB_EXPECT(intact.final_rng_state() != filtered.final_rng_state());
}

VWB_TEST(native_surface_feature_manifest_preserves_ore_child_tombstone_rng_suffix) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) profile.rock_base_chance = 1.0;
    const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles);
    const auto assets = rocks(catalog); const auto structure = exclusions(); const auto capture = halo(structure);
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("feature-ore-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto intact = ordered(terrain, catalog, structure, NativeFeatureDeltaSnapshot::create({}, {}));
        for (std::size_t i = 0U; i + 1U < intact.attempts().size(); ++i) {
            if (!intact.attempts()[i].ore_cluster) continue;
            const auto child_id = intact.attempts()[i].attempt.durable_id + ":cluster1";
            const auto filtered = ordered(terrain, catalog, structure,
                NativeFeatureDeltaSnapshot::create({{child_id}}, {}));
            const auto placement = NativeSurfacePropOrderedPlacement::create(filtered, terrain);
            const auto manifest = compose(filtered, placement, terrain, catalog, assets, structure, &capture);
            VWB_EXPECT(manifest.entries()[i].ore.has_value());
            VWB_EXPECT(!manifest.entries()[i].ore->children()[1].present);
            VWB_EXPECT_EQ(filtered.attempts()[i].ore_cluster->children()[1].state_before,
                filtered.attempts()[i].ore_cluster->children()[1].state_after);
            VWB_EXPECT_EQ(filtered.final_rng_state(), manifest.final_rng_state());
            VWB_EXPECT(intact.final_rng_state() != filtered.final_rng_state());
            VWB_EXPECT(intact.attempts()[i + 1U].attempt.durable_id
                != filtered.attempts()[i + 1U].attempt.durable_id);
            found = true; break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_surface_feature_manifest_composes_iron_ore_case) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) profile.rock_base_chance = 1.0;
    const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles);
    const auto assets = rocks(catalog); const auto structure = exclusions(); const auto capture = halo(structure);
    bool found_iron = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found_iron; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-ore-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto source = ordered(terrain, catalog, structure, NativeFeatureDeltaSnapshot::create({}, {}));
        for (std::uint32_t i = 0U; i < 28U; ++i) {
            if (source.attempts()[i].outcome != NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster)
                continue;
            const auto placement = NativeSurfacePropOrderedPlacement::create(source, terrain);
            const auto manifest = compose(source, placement, terrain, catalog, assets, structure, &capture);
            VWB_EXPECT(manifest.entries()[i].ore.has_value());
            VWB_EXPECT_EQ(NativeOreKind::iron, manifest.entries()[i].ore->kind());
            found_iron = true; break;
        }
    }
    VWB_EXPECT(found_iron);
}

VWB_TEST(native_surface_feature_manifest_requires_tree_halo_and_records_blocked_presence) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &p : profiles) { p.rock_base_chance = 0.0; p.tree_chance = 1.0; }
    const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles);
    const auto assets = rocks(catalog); const auto structure = exclusions();
    const auto definition = surface_prop_test_fixture::definition("feature-tree");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto source = ordered(terrain, catalog, structure, NativeFeatureDeltaSnapshot::create({}, {}));
    const auto placement = NativeSurfacePropOrderedPlacement::create(source, terrain);
    std::uint32_t ordinal = 28U;
    for (std::uint32_t i = 0U; i < 28U; ++i)
        if (source.attempts()[i].outcome == NativeSurfacePropClassificationOutcome::tree_22_draw
            || source.attempts()[i].outcome == NativeSurfacePropClassificationOutcome::tree_36_draw) {
            ordinal = i; break;
        }
    VWB_EXPECT(ordinal < 28U);
    VWB_EXPECT_THROW(NativeSurfaceFeatureManifestRejected,
        compose(source, placement, terrain, catalog, assets, structure, nullptr));
    const auto clear = halo(structure);
    const auto clear_manifest = compose(source, placement, terrain, catalog, assets, structure, &clear);
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::present,
        clear_manifest.entries()[ordinal].tree_presence->presence);
    const auto &candidate = placement.entries()[ordinal];
    const auto blocked = halo(structure, {{"outside-chunk-natural",
        {candidate.cell_x - 2, candidate.cell_z, candidate.cell_x - 2, candidate.cell_z}}});
    const auto blocked_manifest = compose(source, placement, terrain, catalog, assets, structure, &blocked);
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::absent,
        blocked_manifest.entries()[ordinal].tree_presence->presence);
    VWB_EXPECT_EQ(StructureExclusionKind::natural,
        blocked_manifest.entries()[ordinal].tree_presence->blocker_kind);
    VWB_EXPECT_EQ(std::string("outside-chunk-natural"),
        blocked_manifest.entries()[ordinal].tree_presence->blocker_id);
    VWB_EXPECT(clear_manifest.content_digest() != blocked_manifest.content_digest());
    const auto missing_region = NativeTreeExclusionHaloCapture::create(world_digest(), 1U,
        structure.content_digest(), {-100,-100,130,130}, {}, {}, {absent(0,0)});
    VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
        compose(source, placement, terrain, catalog, assets, structure, &missing_region));
}

VWB_TEST(native_surface_feature_manifest_composes_forage_and_wildlife_receipts) {
    const auto definition = surface_prop_test_fixture::definition("ordered-recipes");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto structure = exclusions();
    for (const bool forage_mode : {true, false}) {
        auto profiles = tests::godot_oracle_environment_profiles();
        for (auto &profile : profiles) {
            profile.rock_base_chance = 0.0; profile.tree_chance = 0.0;
            profile.forage_chance = forage_mode ? 1.0 : 0.0;
            profile.wildlife_chance = forage_mode ? 0.0 : 1.0;
        }
        const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles);
        const auto assets = rocks(catalog);
        const auto source = ordered(terrain, catalog, structure, NativeFeatureDeltaSnapshot::create({}, {}));
        const auto placement = NativeSurfacePropOrderedPlacement::create(source, terrain);
        const auto manifest = compose(source, placement, terrain, catalog, assets, structure, nullptr);
        bool found = false;
        for (const auto &entry : manifest.entries()) {
            if (forage_mode && entry.forage) found = true;
            if (!forage_mode && entry.wildlife) found = true;
        }
        VWB_EXPECT(found);
    }
}

VWB_TEST(native_surface_feature_manifest_keeps_negative_chunk_identity) {
    const auto definition = surface_prop_test_fixture::definition("feature-negative-chunk");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {-1,-1}, surface_prop_test_fixture::empty_deltas()));
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    const auto assets = rocks(catalog);
    const auto structure = NativeStructureExclusionSnapshot::create(world_digest(), 1U,
        {}, {}, {absent(-1,-1)}, {{-28,-28,true}});
    const auto capture = NativeTreeExclusionHaloCapture::create(world_digest(), 1U,
        structure.content_digest(), {-130,-130,100,100}, {}, {},
        {absent(-1,-1), absent(0,-1), absent(-1,0), absent(0,0)});
    const auto source = ordered(terrain, catalog, structure,
        NativeFeatureDeltaSnapshot::create({}, {}), -1, -1);
    const auto placement = NativeSurfacePropOrderedPlacement::create(source, terrain);
    const auto manifest = compose(source, placement, terrain, catalog, assets, structure, &capture);
    VWB_EXPECT_EQ(-1, manifest.chunk_x()); VWB_EXPECT_EQ(-1, manifest.chunk_z());
    VWB_EXPECT_EQ(28U, manifest.entries().size());
    for (const auto &entry : manifest.entries()) {
        VWB_EXPECT_EQ(-1, entry.placement.chunk_x);
        VWB_EXPECT_EQ(-1, entry.placement.chunk_z);
        VWB_EXPECT(entry.placement.cell_x < 0 && entry.placement.cell_z < 0);
    }
    VWB_EXPECT_EQ(manifest.content_digest(),
        compose(source, placement, terrain, catalog, assets, structure, &capture).content_digest());
}
