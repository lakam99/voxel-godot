#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_feature_manifest.hpp"
#include "../core/native_surface_prop_chunk_transition.hpp"

#include <algorithm>
#include <memory>
#include <utility>

using namespace voxel::world_backend;

static_assert(sizeof(NativeSurfacePropChunkTransition) < 4096U,
    "transition witnesses must keep large typed manifests and footprint projections off stack");

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

bool has_channel(const NativeGeneratedFeatureFootprintEntry &entry,
    NativeFeatureFootprintChannel channel) {
    return std::any_of(entry.runs.begin(), entry.runs.end(), [channel](const auto &run) {
        return run.channel == channel;
    });
}

const NativeSurfaceFeatureFootprintShadowRecord *record_with_status(
    const NativeSurfaceFeatureFootprintShadowProjection &projection,
    NativeSurfaceFeatureFootprintShadowStatus status) {
    const auto found = std::find_if(projection.records().begin(), projection.records().end(),
        [status](const auto &record) { return record.status == status; });
    return found == projection.records().end() ? nullptr : &*found;
}

__declspec(noinline) bool rejects_shadow_transition(
    const NativeSurfacePropSourceOrderedStream &source,
    const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog,
    const NativeSurfaceRockAssetCatalog &assets,
    const NativeStructureExclusionSnapshot &structure,
    const NativeWildlifePresentationCatalog &presentation,
    const NativeTreeExclusionHaloCapture &capture,
    const NativeSurfaceFeatureFootprintShadowInputs &invalid,
    const NativeSurfaceFeatureFootprintShadowInputs &fallback) {
    try {
        (void)NativeSurfacePropChunkTransition::create(source, source, terrain, catalog, assets,
            structure, presentation, &capture, &capture, &invalid, &fallback);
    } catch (const NativeSurfaceFeatureFootprintShadowRejected &) {
        return true;
    } catch (...) {
        return false;
    }
    return false;
}

__declspec(noinline) std::unique_ptr<NativeSurfacePropChunkTransition> make_shadow_transition(
    const NativeSurfacePropSourceOrderedStream &source,
    const NativeEffectiveTerrainSource &terrain,
    const NativeBiomeEnvironmentCatalog &catalog,
    const NativeSurfaceRockAssetCatalog &assets,
    const NativeStructureExclusionSnapshot &structure,
    const NativeWildlifePresentationCatalog &presentation,
    const NativeTreeExclusionHaloCapture &capture,
    const NativeSurfaceFeatureFootprintShadowInputs *before_inputs = nullptr,
    const NativeSurfaceFeatureFootprintShadowInputs *after_inputs = nullptr) {
    return std::make_unique<NativeSurfacePropChunkTransition>(
        NativeSurfacePropChunkTransition::create(source, source, terrain, catalog, assets,
            structure, presentation, &capture, &capture, before_inputs, after_inputs));
}

} // namespace

VWB_TEST(native_surface_transition_recomputes_changed_suffix_and_typed_manifests) {
    const auto definition = surface_prop_test_fixture::definition("feature-transition");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    const auto assets = rocks(catalog);
    const auto structure = exclusions();
    const auto presentation = wildlife();
    const auto capture = halo(structure);
    const auto intact_snapshot = NativeFeatureDeltaSnapshot::create({}, {});
    const auto intact = ordered(terrain, catalog, structure, intact_snapshot);
    const auto removed_snapshot = NativeFeatureDeltaSnapshot::create(
        {{intact.attempts()[0].attempt.durable_id}}, {});
    const auto removed = ordered(terrain, catalog, structure, removed_snapshot);
    const auto no_op = NativeSurfacePropChunkTransition::create(intact, intact, terrain,
        catalog, assets, structure, presentation, &capture, &capture);
    VWB_EXPECT(!NativeSurfacePropChunkTransition::CHANNEL_FOOTPRINTS_COMPLETE);
    VWB_EXPECT(!no_op.channel_footprints_complete());
    VWB_EXPECT(no_op.changed_ordinals().empty());
    VWB_EXPECT(no_op.changed_ids().empty());
    VWB_EXPECT(no_op.footprint_shadow_changed_ordinals().empty());
    VWB_EXPECT(!NativeSurfaceFeatureFootprintShadowProjection::CHANNEL_FOOTPRINTS_COMPLETE);
    VWB_EXPECT(!no_op.before_footprint_shadow().channel_footprints_complete());
    VWB_EXPECT_EQ(28U, no_op.before_footprint_shadow().records().size());
    VWB_EXPECT_EQ(terrain.pin().physical_content_identity(),
        no_op.before_footprint_shadow().world_source_identity());
    VWB_EXPECT_EQ(intact.world_generation(), no_op.before_footprint_shadow().world_generation());
    VWB_EXPECT_EQ(no_op.before_manifest().content_digest(),
        no_op.before_footprint_shadow().manifest_digest());
    VWB_EXPECT_EQ(catalog.content_digest(),
        no_op.before_footprint_shadow().environment_catalog_digest());
    VWB_EXPECT_EQ(assets.content_digest(),
        no_op.before_footprint_shadow().rock_asset_catalog_digest());
    VWB_EXPECT(no_op.before_footprint_shadow().wildlife_presentation_catalog_digest()
        != Sha256Digest{});
    VWB_EXPECT_EQ(terrain.pin().physical_content_identity().digest,
        no_op.before_footprint_shadow().partial_exact_catalog_for_diagnostics_only().source_digest());
    VWB_EXPECT_EQ(no_op.before_footprint_shadow().content_digest(),
        no_op.after_footprint_shadow().content_digest());
    for (std::uint32_t ordinal = 0U; ordinal < 28U; ++ordinal) {
        VWB_EXPECT_EQ(ordinal, no_op.before_footprint_shadow().records()[ordinal].ordinal);
        VWB_EXPECT_EQ(intact.attempts()[ordinal].attempt.durable_id,
            no_op.before_footprint_shadow().records()[ordinal].durable_id);
        VWB_EXPECT(no_op.before_footprint_shadow().records()[ordinal].content_digest != Sha256Digest{});
    }
    const auto changed = NativeSurfacePropChunkTransition::create(intact, removed, terrain,
        catalog, assets, structure, presentation, &capture, &capture);
    VWB_EXPECT(!changed.channel_footprints_complete());
    VWB_EXPECT(!changed.changed_ordinals().empty());
    VWB_EXPECT(!changed.footprint_shadow_changed_ordinals().empty());
    VWB_EXPECT_EQ(0U, changed.changed_ordinals().front());
    VWB_EXPECT_EQ(28U, changed.before_manifest().entries().size());
    VWB_EXPECT_EQ(28U, changed.after_manifest().entries().size());
    VWB_EXPECT_EQ(intact.final_rng_state(), changed.before_manifest().final_rng_state());
    VWB_EXPECT_EQ(removed.final_rng_state(), changed.after_manifest().final_rng_state());
    VWB_EXPECT(changed.before_manifest().content_digest() != changed.after_manifest().content_digest());
    VWB_EXPECT(changed.before_footprint_shadow().content_digest()
        != changed.after_footprint_shadow().content_digest());
    VWB_EXPECT(changed.content_digest() != no_op.content_digest());
    VWB_EXPECT(std::find(changed.changed_ids().begin(), changed.changed_ids().end(),
        intact.attempts()[0].attempt.durable_id) != changed.changed_ids().end());
    VWB_EXPECT(std::is_sorted(changed.changed_ids().begin(), changed.changed_ids().end()));
}

VWB_TEST(native_surface_transition_tracks_ore_child_ids_and_rng_suffix) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) profile.rock_base_chance = 1.0;
    const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles);
    const auto assets = rocks(catalog); const auto structure = exclusions();
    const auto capture = halo(structure); const auto presentation = wildlife();
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("transition-ore-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto intact = ordered(terrain, catalog, structure, NativeFeatureDeltaSnapshot::create({}, {}));
        for (std::uint32_t i = 0U; i + 1U < intact.attempts().size(); ++i) {
            if (!intact.attempts()[i].ore_cluster) continue;
            const auto child_id = intact.attempts()[i].attempt.durable_id + ":cluster1";
            const auto filtered = ordered(terrain, catalog, structure,
                NativeFeatureDeltaSnapshot::create({{child_id}}, {}));
            const auto no_op = NativeSurfacePropChunkTransition::create(intact, intact, terrain,
                catalog, assets, structure, presentation, &capture, &capture);
            VWB_EXPECT(no_op.changed_ordinals().empty());
            const auto change = NativeSurfacePropChunkTransition::create(intact, filtered, terrain,
                catalog, assets, structure, presentation, &capture, &capture);
            VWB_EXPECT(std::find(change.changed_ordinals().begin(), change.changed_ordinals().end(), i)
                != change.changed_ordinals().end());
            VWB_EXPECT(std::find(change.changed_ids().begin(), change.changed_ids().end(), child_id)
                != change.changed_ids().end());
            VWB_EXPECT(change.before_manifest().entries()[i].ore->children()[1].present);
            VWB_EXPECT(!change.after_manifest().entries()[i].ore->children()[1].present);
            const auto &before_record = change.before_footprint_shadow().records()[i];
            const auto &after_record = change.after_footprint_shadow().records()[i];
            VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::exact_all_channels,
                before_record.status);
            VWB_EXPECT(std::find(before_record.exact_feature_ids.begin(),
                before_record.exact_feature_ids.end(), child_id) != before_record.exact_feature_ids.end());
            VWB_EXPECT(change.before_footprint_shadow()
                .partial_exact_catalog_for_diagnostics_only().find(child_id) != nullptr);
            VWB_EXPECT(std::find(after_record.exact_feature_ids.begin(),
                after_record.exact_feature_ids.end(), child_id) == after_record.exact_feature_ids.end());
            VWB_EXPECT(change.after_footprint_shadow()
                .partial_exact_catalog_for_diagnostics_only().find(child_id) == nullptr);
            for (const auto &feature_id : before_record.exact_feature_ids) {
                const auto *footprint = change.before_footprint_shadow()
                    .partial_exact_catalog_for_diagnostics_only().find(feature_id);
                VWB_EXPECT(footprint != nullptr);
                VWB_EXPECT_EQ(NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS,
                    footprint->declared_channel_mask);
                VWB_EXPECT(has_channel(*footprint, NativeFeatureFootprintChannel::render));
                VWB_EXPECT(has_channel(*footprint, NativeFeatureFootprintChannel::collision));
                VWB_EXPECT(has_channel(*footprint, NativeFeatureFootprintChannel::navigation));
                VWB_EXPECT(!has_channel(*footprint, NativeFeatureFootprintChannel::terrain_source));
            }
            VWB_EXPECT(intact.final_rng_state() != filtered.final_rng_state());
            found = true; break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_surface_transition_keeps_publication_observations_diagnostic_and_rejects_bad_rock_bindings) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) {
        profile.rock_base_chance = 1.0;
        profile.tree_chance = 0.0;
        profile.forage_chance = 0.0;
        profile.wildlife_chance = 0.0;
    }
    const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles);
    const auto assets = rocks(catalog); const auto structure = exclusions();
    const auto capture = halo(structure); const auto presentation = wildlife();
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition(
            "transition-rock-binding-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto source = ordered(terrain, catalog, structure,
            NativeFeatureDeltaSnapshot::create({}, {}));
        const auto unbound = make_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture);
        const auto &manifest = unbound->before_manifest();
        std::uint32_t rock_ordinal = 28U, non_rock_ordinal = 28U;
        for (std::uint32_t ordinal = 0U; ordinal < 28U; ++ordinal) {
            if (manifest.entries()[ordinal].rock && rock_ordinal == 28U) rock_ordinal = ordinal;
            if (!manifest.entries()[ordinal].rock && non_rock_ordinal == 28U) non_rock_ordinal = ordinal;
        }
        if (rock_ordinal == 28U || non_rock_ordinal == 28U) continue;
        const auto &plan = *manifest.entries()[rock_ordinal].rock;
        VWB_EXPECT_EQ(NativeSurfaceRockVisualIntent::selected_asset, plan.intent());
        VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::incomplete_rock_publication_outcome,
            unbound->before_footprint_shadow().records()[rock_ordinal].status);
        VWB_EXPECT(unbound->before_footprint_shadow()
            .partial_exact_catalog_for_diagnostics_only()
            .find(manifest.entries()[rock_ordinal].placement.durable_id) == nullptr);
        VWB_EXPECT(record_with_status(unbound->before_footprint_shadow(),
            NativeSurfaceFeatureFootprintShadowStatus::incomplete_rock_publication_outcome) != nullptr);
        NativeSurfaceRockImportedBoundsReceipt receipt;
        receipt.asset_catalog_digest = assets.content_digest();
        receipt.glb_digest.fill(0x6aU);
        receipt.asset_id = plan.selection().asset_id;
        receipt.asset_path = plan.selection().asset_path;
        receipt.imported_mesh_bounds = {-0.75, -0.5, -0.625, 0.75, 0.5, 0.625};
        NativeSurfaceRockPublicationShadowBinding selected_binding;
        selected_binding.ordinal = rock_ordinal;
        selected_binding.feature_id = manifest.entries()[rock_ordinal].placement.durable_id;
        selected_binding.rock_definition_digest = plan.definition().content_digest();
        selected_binding.published_visual = NativeSurfaceRockPublishedVisual::selected_import;
        selected_binding.imported_bounds = receipt;
        NativeSurfaceFeatureFootprintShadowInputs selected;
        selected.rock_publications.push_back(selected_binding);
        NativeSurfaceRockPublicationShadowBinding fallback_binding = selected_binding;
        fallback_binding.published_visual = NativeSurfaceRockPublishedVisual::primitive_fallback;
        fallback_binding.imported_bounds.reset();
        NativeSurfaceFeatureFootprintShadowInputs fallback;
        fallback.rock_publications.push_back(fallback_binding);
        const auto selected_repeat = make_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, &selected, &selected);
        VWB_EXPECT(selected_repeat->footprint_shadow_changed_ordinals().empty());
        VWB_EXPECT_EQ(selected_repeat->before_footprint_shadow().content_digest(),
            selected_repeat->after_footprint_shadow().content_digest());
        const auto transition = make_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, &selected, &fallback);
        VWB_EXPECT(transition->ordered_difference().changed_ordinals().empty());
        VWB_EXPECT(transition->changed_ordinals().empty());
        VWB_EXPECT(transition->changed_ids().empty());
        VWB_EXPECT_EQ(1U, transition->footprint_shadow_changed_ordinals().size());
        VWB_EXPECT_EQ(rock_ordinal, transition->footprint_shadow_changed_ordinals().front());
        VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::exact_all_channels,
            transition->before_footprint_shadow().records()[rock_ordinal].status);
        VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::exact_all_channels,
            transition->after_footprint_shadow().records()[rock_ordinal].status);
        VWB_EXPECT(transition->before_footprint_shadow().records()[rock_ordinal].content_digest
            != transition->after_footprint_shadow().records()[rock_ordinal].content_digest);
        VWB_EXPECT(transition->before_footprint_shadow()
            .partial_exact_catalog_for_diagnostics_only().content_digest()
            != transition->after_footprint_shadow()
                .partial_exact_catalog_for_diagnostics_only().content_digest());
        VWB_EXPECT(transition->content_digest() != selected_repeat->content_digest());
        const auto rock_id = manifest.entries()[rock_ordinal].placement.durable_id;
        const auto *selected_entry = transition->before_footprint_shadow()
            .partial_exact_catalog_for_diagnostics_only().find(rock_id);
        const auto *fallback_entry = transition->after_footprint_shadow()
            .partial_exact_catalog_for_diagnostics_only().find(rock_id);
        VWB_EXPECT(selected_entry != nullptr && fallback_entry != nullptr);
        for (const auto *entry : {selected_entry, fallback_entry}) {
            VWB_EXPECT_EQ(NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS, entry->declared_channel_mask);
            VWB_EXPECT(has_channel(*entry, NativeFeatureFootprintChannel::render));
            VWB_EXPECT(has_channel(*entry, NativeFeatureFootprintChannel::collision));
            VWB_EXPECT(has_channel(*entry, NativeFeatureFootprintChannel::navigation));
            VWB_EXPECT(!has_channel(*entry, NativeFeatureFootprintChannel::terrain_source));
        }

        NativeSurfaceFeatureFootprintShadowInputs stale = selected;
        stale.rock_publications.front().imported_bounds->asset_catalog_digest[0] ^= 0x01U;
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, stale, fallback));
        NativeSurfaceFeatureFootprintShadowInputs mismatched = selected;
        mismatched.rock_publications.front().imported_bounds->asset_id += "-stale";
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, mismatched, fallback));
        NativeSurfaceFeatureFootprintShadowInputs wrong_feature = selected;
        wrong_feature.rock_publications.front().feature_id += "-stale";
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, wrong_feature, fallback));
        NativeSurfaceFeatureFootprintShadowInputs empty_feature = selected;
        empty_feature.rock_publications.front().feature_id.clear();
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, empty_feature, fallback));
        NativeSurfaceFeatureFootprintShadowInputs long_feature = selected;
        long_feature.rock_publications.front().feature_id.assign(1025U, 'f');
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, long_feature, fallback));
        NativeSurfaceFeatureFootprintShadowInputs long_asset_id = selected;
        long_asset_id.rock_publications.front().imported_bounds->asset_id.assign(1025U, 'a');
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, long_asset_id, fallback));
        NativeSurfaceFeatureFootprintShadowInputs long_asset_path = selected;
        long_asset_path.rock_publications.front().imported_bounds->asset_path.assign(1025U, 'p');
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, long_asset_path, fallback));
        NativeSurfaceFeatureFootprintShadowInputs wrong_definition = selected;
        wrong_definition.rock_publications.front().rock_definition_digest[0] ^= 0x01U;
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, wrong_definition, fallback));
        NativeSurfaceFeatureFootprintShadowInputs missing_receipt;
        auto missing_binding = selected_binding;
        missing_binding.imported_bounds.reset();
        missing_receipt.rock_publications.push_back(missing_binding);
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, missing_receipt, fallback));
        NativeSurfaceFeatureFootprintShadowInputs fallback_with_receipt;
        auto fallback_receipt_binding = fallback_binding;
        fallback_receipt_binding.imported_bounds = receipt;
        fallback_with_receipt.rock_publications.push_back(fallback_receipt_binding);
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, fallback_with_receipt, fallback));
        NativeSurfaceFeatureFootprintShadowInputs duplicate = selected;
        duplicate.rock_publications.push_back(selected.rock_publications.front());
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, duplicate, fallback));
        NativeSurfaceFeatureFootprintShadowInputs out_of_range;
        auto out_of_range_binding = fallback_binding;
        out_of_range_binding.ordinal = 28U;
        out_of_range.rock_publications.push_back(out_of_range_binding);
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, out_of_range, fallback));
        NativeSurfaceFeatureFootprintShadowInputs non_rock;
        auto non_rock_binding = fallback_binding;
        non_rock_binding.ordinal = non_rock_ordinal;
        non_rock.rock_publications.push_back(non_rock_binding);
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, non_rock, fallback));
        NativeSurfaceFeatureFootprintShadowInputs excessive;
        for (std::uint32_t ordinal = 0U; ordinal < 29U; ++ordinal) {
            auto excessive_binding = fallback_binding;
            excessive_binding.ordinal = ordinal;
            excessive.rock_publications.push_back(excessive_binding);
        }
        VWB_EXPECT(rejects_shadow_transition(source, terrain, catalog, assets,
            structure, presentation, capture, excessive, fallback));
        found = true;
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_surface_transition_records_all_tombstoned_ore_children_as_exact_absence) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) profile.rock_base_chance = 1.0;
    const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles);
    const auto assets = rocks(catalog); const auto structure = exclusions();
    const auto capture = halo(structure); const auto presentation = wildlife();
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition(
            "transition-empty-ore-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto source = ordered(terrain, catalog, structure,
            NativeFeatureDeltaSnapshot::create({}, {}));
        for (std::uint32_t ordinal = 0U; ordinal < 28U; ++ordinal) {
            if (!source.attempts()[ordinal].ore_cluster) continue;
            std::vector<std::string> removed_ids;
            std::vector<NativeFeatureTombstone> tombstones;
            for (const auto &child : source.attempts()[ordinal].ore_cluster->children()) {
                removed_ids.push_back(child.durable_id);
                tombstones.push_back({child.durable_id});
            }
            const auto removed = ordered(terrain, catalog, structure,
                NativeFeatureDeltaSnapshot::create(std::move(tombstones), {}));
            const auto transition = NativeSurfacePropChunkTransition::create(source, removed, terrain,
                catalog, assets, structure, presentation, &capture, &capture);
            const auto &record = transition.after_footprint_shadow().records()[ordinal];
            VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::exact_absent, record.status);
            VWB_EXPECT(record.exact_feature_ids.empty());
            for (const auto &id : removed_ids) {
                VWB_EXPECT(transition.after_footprint_shadow()
                    .partial_exact_catalog_for_diagnostics_only().find(id) == nullptr);
            }
            found = true;
            break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_surface_transition_tracks_tree_halo_without_ordered_change) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) {
        profile.rock_base_chance = 0.0; profile.tree_chance = 1.0;
    }
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
    const auto clear = halo(structure);
    const auto &candidate = placement.entries()[ordinal];
    const auto blocked = halo(structure, {{"transition-natural",
        {candidate.cell_x - 2, candidate.cell_z, candidate.cell_x - 2, candidate.cell_z}}});
    const auto change = NativeSurfacePropChunkTransition::create(source, source, terrain,
        catalog, assets, structure, wildlife(), &clear, &blocked);
    VWB_EXPECT(change.ordered_difference().changed_ordinals().empty());
    VWB_EXPECT(std::find(change.changed_ordinals().begin(), change.changed_ordinals().end(), ordinal)
        != change.changed_ordinals().end());
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::present,
        change.before_manifest().entries()[ordinal].tree_presence->presence);
    VWB_EXPECT_EQ(NativeSurfaceTreePresence::absent,
        change.after_manifest().entries()[ordinal].tree_presence->presence);
    VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::incomplete_tree_geometry,
        change.before_footprint_shadow().records()[ordinal].status);
    VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::exact_absent,
        change.after_footprint_shadow().records()[ordinal].status);
    VWB_EXPECT(change.after_footprint_shadow().partial_exact_catalog_for_diagnostics_only()
        .find(candidate.durable_id) == nullptr);
    VWB_EXPECT(change.before_footprint_shadow().incomplete_record_count()
        > change.after_footprint_shadow().incomplete_record_count());
    VWB_EXPECT(std::find(change.changed_ids().begin(), change.changed_ids().end(), candidate.durable_id)
        != change.changed_ids().end());
}

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
        const auto transition = NativeSurfacePropChunkTransition::create(source, source, terrain,
            catalog, assets, structure, wildlife(), nullptr, nullptr);
        bool found = false;
        std::size_t expected_incomplete = 0U;
        for (std::uint32_t ordinal = 0U; ordinal < manifest.entries().size(); ++ordinal) {
            const auto &entry = manifest.entries()[ordinal];
            const auto &record = transition.before_footprint_shadow().records()[ordinal];
            if (forage_mode && entry.forage) {
                found = true;
                VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::exact_all_channels,
                    record.status);
                VWB_EXPECT_EQ(1U, record.exact_feature_ids.size());
                const auto *footprint = transition.before_footprint_shadow()
                    .partial_exact_catalog_for_diagnostics_only().find(record.exact_feature_ids.front());
                VWB_EXPECT(footprint != nullptr);
                VWB_EXPECT_EQ(NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS,
                    footprint->declared_channel_mask);
                VWB_EXPECT(has_channel(*footprint, NativeFeatureFootprintChannel::render));
                VWB_EXPECT(has_channel(*footprint, NativeFeatureFootprintChannel::collision));
                VWB_EXPECT_EQ(entry.forage->navigation_blocker(),
                    has_channel(*footprint, NativeFeatureFootprintChannel::navigation));
                VWB_EXPECT(!has_channel(*footprint, NativeFeatureFootprintChannel::terrain_source));
            }
            if (!forage_mode && entry.wildlife) {
                found = true;
                ++expected_incomplete;
                VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::incomplete_wildlife_motion_policy,
                    record.status);
                VWB_EXPECT(record.exact_feature_ids.empty());
                VWB_EXPECT(transition.before_footprint_shadow()
                    .partial_exact_catalog_for_diagnostics_only()
                    .find(entry.placement.durable_id) == nullptr);
            }
        }
        VWB_EXPECT(found);
        VWB_EXPECT_EQ(expected_incomplete,
            transition.before_footprint_shadow().incomplete_record_count());
    }
}

VWB_TEST(native_surface_footprint_shadow_declares_empty_nonblocking_navigation_exactly) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) {
        profile.rock_base_chance = 0.0;
        profile.tree_chance = 0.0;
        profile.forage_chance = 1.0;
        profile.wildlife_chance = 0.0;
        profile.forage_material = "aloePatch";
        profile.forage_drop = "aloe";
        profile.forage_drop_min = 1;
        profile.forage_drop_max = 3;
        profile.forage_radius = 0.5;
    }
    const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles);
    const auto assets = rocks(catalog); const auto structure = exclusions();
    const auto definition = surface_prop_test_fixture::definition("footprint-nonblocking-forage");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto source = ordered(terrain, catalog, structure,
        NativeFeatureDeltaSnapshot::create({}, {}));
    const auto transition = NativeSurfacePropChunkTransition::create(source, source, terrain,
        catalog, assets, structure, wildlife(), nullptr, nullptr);
    bool found = false;
    for (std::uint32_t ordinal = 0U; ordinal < 28U; ++ordinal) {
        const auto &manifest_entry = transition.before_manifest().entries()[ordinal];
        if (!manifest_entry.forage) continue;
        VWB_EXPECT(!manifest_entry.forage->navigation_blocker());
        const auto &record = transition.before_footprint_shadow().records()[ordinal];
        VWB_EXPECT_EQ(NativeSurfaceFeatureFootprintShadowStatus::exact_all_channels, record.status);
        VWB_EXPECT_EQ(1U, record.exact_feature_ids.size());
        const auto *footprint = transition.before_footprint_shadow()
            .partial_exact_catalog_for_diagnostics_only().find(record.exact_feature_ids.front());
        VWB_EXPECT(footprint != nullptr);
        VWB_EXPECT_EQ(NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS, footprint->declared_channel_mask);
        VWB_EXPECT(has_channel(*footprint, NativeFeatureFootprintChannel::render));
        VWB_EXPECT(has_channel(*footprint, NativeFeatureFootprintChannel::collision));
        VWB_EXPECT(!has_channel(*footprint, NativeFeatureFootprintChannel::navigation));
        VWB_EXPECT(!has_channel(*footprint, NativeFeatureFootprintChannel::terrain_source));
        found = true;
    }
    VWB_EXPECT(found);
    VWB_EXPECT_EQ(0U, transition.before_footprint_shadow().incomplete_record_count());
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
