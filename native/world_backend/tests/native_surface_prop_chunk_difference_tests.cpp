#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_prop_chunk_difference.hpp"

using namespace voxel::world_backend;

namespace {

Sha256Digest world_digest(std::uint8_t marker = 67U) {
    Sha256Digest d{}; d[0] = marker; return d;
}

NativeStructureExclusionSnapshot exclusions(const Sha256Digest &world, std::int32_t chunk_x = 0,
    std::int32_t chunk_z = 0, std::uint64_t generation = 1U, const std::string &key = "world:0,0") {
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent;
    absent.source_key = key;
    return NativeStructureExclusionSnapshot::create(world, generation, {}, {}, {absent},
        {{chunk_x * 28,chunk_z * 28,true}});
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

NativeBiomeEnvironmentCatalog catalog(bool force_rock = false) {
    auto p = tests::godot_oracle_environment_profiles();
    if (force_rock) for (auto &row : p) row.rock_base_chance = 1.0;
    return NativeBiomeEnvironmentCatalog::create(std::move(p));
}

NativeSurfacePropSourceOrderedStream stream(const NativeEffectiveTerrainSource &terrain,
    const NativeFeatureDeltaSnapshot &removed, bool force_rock = false,
    std::uint8_t world_marker = 67U, std::int32_t chunk_x = 0,
    std::int32_t chunk_z = 0, std::uint64_t generation = 1U,
    const std::string &exclusion_key = "world:0,0") {
    const auto world = world_digest(world_marker);
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        chunk_x, chunk_z, world, generation, terrain, catalog(force_rock),
        exclusions(world, chunk_x, chunk_z, generation, exclusion_key), removed, wildlife());
}

NativeSurfacePropSourceOrderedStream stream_for_family(const NativeEffectiveTerrainSource &terrain,
    bool forage) {
    auto p = tests::godot_oracle_environment_profiles();
    for (auto &profile : p) {
        profile.rock_base_chance = 0.0;
        profile.tree_chance = 0.0;
        profile.forage_chance = forage ? 1.0 : 0.0;
        profile.wildlife_chance = forage ? 0.0 : 1.0;
    }
    const auto world = world_digest();
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        0, 0, world, 1U, terrain, NativeBiomeEnvironmentCatalog::create(std::move(p)),
        exclusions(world), NativeFeatureDeltaSnapshot::create({}, {}), wildlife());
}

NativeSurfacePropOrderedPlacement placement(const NativeSurfacePropSourceOrderedStream &s,
    const NativeEffectiveTerrainSource &terrain) {
    return NativeSurfacePropOrderedPlacement::create(s, terrain);
}

} // namespace

VWB_TEST(native_chunk_difference_parent_tombstone_restore_and_noop) {
    // This admitted terrain/catalog fixture is synthetic. The direct Godot
    // v4 parent oracle's all-28 final IDs are atlas-1492:21,15:27 intact and
    // atlas-1492:6,5:27 removed; this test proves the witness contract, not
    // equality to those separate source-input vectors.
    const auto definition = surface_prop_test_fixture::definition("chunk-diff-parent");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto intact = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}), true);
    const auto removed = stream(terrain, NativeFeatureDeltaSnapshot::create(
        {{intact.attempts()[0].attempt.durable_id}}, {}), true);
    const auto intact_set = placement(intact, terrain);
    const auto removed_set = placement(removed, terrain);
    const auto no_op = NativeSurfacePropChunkDifference::create(intact, intact_set, intact, intact_set, terrain);
    VWB_EXPECT(no_op.changed_ordinals().empty());
    VWB_EXPECT(!no_op.channel_footprints_complete());
    VWB_EXPECT(!NativeSurfacePropChunkDifference::CHANNEL_FOOTPRINTS_COMPLETE);
    VWB_EXPECT_EQ(intact.final_rng_state(), no_op.before_final_rng_state());
    VWB_EXPECT_EQ(intact.final_rng_state(), no_op.after_final_rng_state());
    const auto difference = NativeSurfacePropChunkDifference::create(
        intact, intact_set, removed, removed_set, terrain);
    VWB_EXPECT_EQ(0, difference.chunk_x()); VWB_EXPECT_EQ(0, difference.chunk_z());
    VWB_EXPECT_EQ(world_digest(), difference.world_digest());
    VWB_EXPECT_EQ(1U, difference.world_generation());
    VWB_EXPECT_EQ(terrain.pin().physical_content_identity(), difference.world_source_identity());
    VWB_EXPECT(!difference.changed_ordinals().empty());
    VWB_EXPECT_EQ(0U, difference.changed_ordinals()[0].ordinal);
    VWB_EXPECT_EQ(intact.attempts()[0].attempt.durable_id,
        difference.changed_ordinals()[0].before.durable_id);
    VWB_EXPECT_EQ(removed.attempts()[0].attempt.durable_id,
        difference.changed_ordinals()[0].after.durable_id);
    VWB_EXPECT(difference.changed_ordinals()[0].after.parent_tombstoned);
    VWB_EXPECT_EQ(NativeSurfacePropPlacementPresence::absent,
        difference.changed_ordinals()[0].after.presence);
    VWB_EXPECT(intact.final_rng_state() != removed.final_rng_state());
    VWB_EXPECT(intact.attempts()[1].attempt.durable_id != removed.attempts()[1].attempt.durable_id);
    VWB_EXPECT_EQ(27U, difference.changed_ordinals().back().ordinal);
    VWB_EXPECT(difference.content_digest() != no_op.content_digest());
    const auto restored = NativeSurfacePropChunkDifference::create(
        removed, removed_set, intact, intact_set, terrain);
    VWB_EXPECT_EQ(difference.changed_ordinals().size(), restored.changed_ordinals().size());
    VWB_EXPECT_EQ(difference.changed_ordinals()[0].before.durable_id,
        restored.changed_ordinals()[0].after.durable_id);
    VWB_EXPECT_EQ(difference.before_final_rng_state(), restored.after_final_rng_state());
    VWB_EXPECT(difference.content_digest() != restored.content_digest());
}

VWB_TEST(native_chunk_difference_ore_child_tombstone_changes_recipe_and_suffix) {
    // The direct Godot v5 oracle shifts attempt 1 from atlas-1492:16,10:1
    // to atlas-1492:24,23:1 and attempt 27 from atlas-1492:22,3:27 to
    // atlas-1492:9,19:27, with signed final states -1028004439998731049
    // and -814739496189227464. This synthetic admitted-source test proves that
    // the witness captures the same kind of changed suffix, not those IDs.
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("chunk-diff-ore-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto intact = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}), true);
        for (std::size_t i = 0U; i + 1U < intact.attempts().size(); ++i) {
            if (!intact.attempts()[i].ore_cluster) continue;
            const auto child_id = intact.attempts()[i].attempt.durable_id + ":cluster1";
            const auto removed = stream(terrain, NativeFeatureDeltaSnapshot::create({{child_id}}, {}), true);
            const auto difference = NativeSurfacePropChunkDifference::create(
                intact, placement(intact, terrain), removed, placement(removed, terrain), terrain);
            VWB_EXPECT_EQ(i, difference.changed_ordinals()[0].ordinal);
            VWB_EXPECT_EQ(difference.changed_ordinals()[0].before.durable_id,
                difference.changed_ordinals()[0].after.durable_id);
            VWB_EXPECT(difference.changed_ordinals()[0].before.source_attempt_digest
                != difference.changed_ordinals()[0].after.source_attempt_digest);
            VWB_EXPECT(difference.changed_ordinals()[0].before.state_after_recipe
                != difference.changed_ordinals()[0].after.state_after_recipe);
            VWB_EXPECT(intact.attempts()[i + 1U].attempt.durable_id
                != removed.attempts()[i + 1U].attempt.durable_id);
            VWB_EXPECT(intact.final_rng_state() != removed.final_rng_state());
            found = true;
            break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_chunk_difference_rejects_torn_world_chunk_source_and_placement) {
    const auto definition = surface_prop_test_fixture::definition("chunk-diff-reject");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto base = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}));
    const auto base_set = placement(base, terrain);
    const auto other_world = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}), false, 68U);
    VWB_EXPECT_THROW(NativeSurfacePropChunkDifferenceRejected,
        NativeSurfacePropChunkDifference::create(base, base_set, other_world,
            placement(other_world, terrain), terrain));
    const auto other_chunk = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}), false, 67U, 1);
    VWB_EXPECT_THROW(NativeSurfacePropChunkDifferenceRejected,
        NativeSurfacePropChunkDifference::create(base, base_set, other_chunk,
            placement(other_chunk, terrain), terrain));
    const auto other_z = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}), false, 67U, 0, 1);
    VWB_EXPECT_THROW(NativeSurfacePropChunkDifferenceRejected,
        NativeSurfacePropChunkDifference::create(base, base_set, other_z,
            placement(other_z, terrain), terrain));
    const auto other_generation = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}),
        false, 67U, 0, 0, 2U);
    VWB_EXPECT_THROW(NativeSurfacePropChunkDifferenceRejected,
        NativeSurfacePropChunkDifference::create(base, base_set, other_generation,
            placement(other_generation, terrain), terrain));
    const auto other_exclusion = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}),
        false, 67U, 0, 0, 1U, "world:0,0:alternate");
    VWB_EXPECT_THROW(NativeSurfacePropChunkDifferenceRejected,
        NativeSurfacePropChunkDifference::create(base, base_set, other_exclusion,
            placement(other_exclusion, terrain), terrain));
    const auto other_profile = stream(terrain, NativeFeatureDeltaSnapshot::create({}, {}), true);
    VWB_EXPECT_THROW(NativeSurfacePropChunkDifferenceRejected,
        NativeSurfacePropChunkDifference::create(base, base_set, other_profile,
            placement(other_profile, terrain), terrain));
    const auto alternate_definition = surface_prop_test_fixture::definition("chunk-diff-stale");
    const NativeEffectiveTerrainSource stale(surface_prop_test_fixture::ready_pin(
        alternate_definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    VWB_EXPECT_THROW(NativeSurfacePropChunkDifferenceRejected,
        NativeSurfacePropChunkDifference::create(base, base_set, base, base_set, stale));
    const auto removed = stream(terrain, NativeFeatureDeltaSnapshot::create(
        {{base.attempts()[0].attempt.durable_id}}, {}));
    VWB_EXPECT_THROW(NativeSurfacePropChunkDifferenceRejected,
        NativeSurfacePropChunkDifference::create(base, placement(removed, terrain),
            base, base_set, terrain));
}

VWB_TEST(native_chunk_difference_receipt_equality_checks_every_source_pin) {
    NativeSurfacePropSourceReceipt base;
    base.schema_revision = 4U; base.effective_source_digest.fill(1U);
    base.terrain_delta_revision = 5U; base.shaping_registry_revision = 6U;
    base.environment_profile_revision = 7U; base.environment_profile_digest.fill(2U);
    VWB_EXPECT(native_surface_prop_source_receipts_match(base, base));
    auto changed = base; changed.schema_revision += 1U;
    VWB_EXPECT(!native_surface_prop_source_receipts_match(base, changed));
    changed = base; changed.effective_source_digest[0] += 1U;
    VWB_EXPECT(!native_surface_prop_source_receipts_match(base, changed));
    changed = base; changed.terrain_delta_revision += 1U;
    VWB_EXPECT(!native_surface_prop_source_receipts_match(base, changed));
    changed = base; changed.shaping_registry_revision += 1U;
    VWB_EXPECT(!native_surface_prop_source_receipts_match(base, changed));
    changed = base; changed.environment_profile_revision += 1U;
    VWB_EXPECT(!native_surface_prop_source_receipts_match(base, changed));
    changed = base; changed.environment_profile_digest[0] += 1U;
    VWB_EXPECT(!native_surface_prop_source_receipts_match(base, changed));
}

VWB_TEST(native_chunk_difference_canonicalizes_forage_and_wildlife_attempt_facts) {
    const auto definition = surface_prop_test_fixture::definition("chunk-diff-families");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto forage = stream_for_family(terrain, true);
    const auto wildlife_stream = stream_for_family(terrain, false);
    bool saw_forage = false;
    bool saw_wildlife = false;
    for (const auto &a : forage.attempts()) if (a.forage) saw_forage = true;
    for (const auto &a : wildlife_stream.attempts()) if (a.wildlife) saw_wildlife = true;
    VWB_EXPECT(saw_forage); VWB_EXPECT(saw_wildlife);
    const auto forage_set = placement(forage, terrain);
    const auto wildlife_set = placement(wildlife_stream, terrain);
    const auto forage_noop = NativeSurfacePropChunkDifference::create(
        forage, forage_set, forage, forage_set, terrain);
    const auto wildlife_noop = NativeSurfacePropChunkDifference::create(
        wildlife_stream, wildlife_set, wildlife_stream, wildlife_set, terrain);
    VWB_EXPECT(forage_noop.changed_ordinals().empty());
    VWB_EXPECT(wildlife_noop.changed_ordinals().empty());
    VWB_EXPECT(forage_noop.content_digest() != wildlife_noop.content_digest());
    for (const auto &attempt : wildlife_stream.attempts()) {
        if (!attempt.wildlife) continue;
        auto changed = attempt;
        changed.wildlife->cold = !changed.wildlife->cold;
        VWB_EXPECT(native_surface_prop_ordered_attempt_digest(attempt)
            != native_surface_prop_ordered_attempt_digest(changed));
        break;
    }
    for (const auto &attempt : forage.attempts()) {
        if (!attempt.source || !attempt.source->has_surface) continue;
        auto changed = attempt;
        changed.source->has_surface = false;
        VWB_EXPECT(native_surface_prop_ordered_attempt_digest(attempt)
            != native_surface_prop_ordered_attempt_digest(changed));
        changed = attempt;
        changed.source->surface.found = false;
        VWB_EXPECT(native_surface_prop_ordered_attempt_digest(attempt)
            != native_surface_prop_ordered_attempt_digest(changed));
        break;
    }
}
