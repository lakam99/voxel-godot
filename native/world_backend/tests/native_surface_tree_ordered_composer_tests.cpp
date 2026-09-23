#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_tree_ordered_composer.hpp"
#include "../core/native_surface_tree_presence.hpp"

#include <utility>
#include <cstring>
#include <limits>

using namespace voxel::world_backend;

namespace {

Sha256Digest world_digest() { Sha256Digest d{}; d[0] = 71U; return d; }

NativeStructureExclusionSnapshot exclusions() {
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent; absent.source_key = "world:0,0";
    return NativeStructureExclusionSnapshot::create(world_digest(), 1U, {}, {}, {absent}, {{0,0,true}});
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

NativeSurfacePropSourceOrderedStream ordered(const NativeEffectiveTerrainSource &terrain,
    const NativeFeatureDeltaSnapshot &removed = NativeFeatureDeltaSnapshot::create({}, {})) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &p : profiles) { p.rock_base_chance = 0.0; p.tree_chance = 1.0; }
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        0, 0, world_digest(), 1U, terrain, NativeBiomeEnvironmentCatalog::create(std::move(profiles)),
        exclusions(), removed, wildlife());
}

NativeSurfaceTreeEcologyProfile profile(const std::string &biome) {
    NativeSurfaceTreeEcologyProfile p;
    p.schema_revision = 1U; p.profile_revision = 1U; p.source_profile_digest.fill(8U);
    p.source_biome = biome; p.profile_id = biome; p.tree_families = {"ecological_broadleaf_tree"};
    p.tree_scale = 1.0; p.height_min = 18.0; p.height_max = 82.0;
    p.trunk_radius_min = 0.55; p.trunk_radius_max = 7.2;
    p.canopy_radius_min = 6.0; p.canopy_radius_max = 34.0;
    p.canopy_density = 0.82; p.wind_response = 1.15; p.visibility_range = 340.0;
    p.shadow_range = 210.0; p.exclusion_margin = 0.45;
    p.age_min_years = 30.0; p.age_typical_years = 170.0; p.age_max_years = 380.0;
    p.maturity_cell_scale = 220.0; p.maturity_influence = 0.82; p.local_age_span = 0.34;
    p.age_distribution_skew = 0.72; p.age_band_thresholds = {0.10, 0.27, 0.55, 0.82};
    p.height_growth_exponent = 0.62; p.girth_growth_exponent = 0.82; p.crown_growth_exponent = 0.58;
    return p;
}

bool is_tree(NativeSurfacePropClassificationOutcome outcome) {
    return outcome == NativeSurfacePropClassificationOutcome::tree_22_draw
        || outcome == NativeSurfacePropClassificationOutcome::tree_36_draw;
}

std::uint32_t bits(float v) { std::uint32_t b; std::memcpy(&b, &v, sizeof(b)); return b; }

NativeSurfaceTreeEcologyProfile oracle_profile(const std::string &biome) {
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    const auto &p = catalog.profile_for_biome(biome);
    NativeSurfaceTreeEcologyProfile out;
    out.schema_revision = 1U; out.profile_revision = 1U;
    out.source_profile_digest = catalog.profile_digest(biome);
    out.source_biome = biome; out.profile_id = p.biome_id;
    out.tree_families = p.tree_families; out.tree_scale = p.tree_scale;
    out.height_min = p.tree_height_min; out.height_max = p.tree_height_max;
    out.trunk_radius_min = p.trunk_radius_min; out.trunk_radius_max = p.trunk_radius_max;
    out.canopy_radius_min = p.crown_radius_min; out.canopy_radius_max = p.crown_radius_max;
    out.canopy_density = p.canopy_density; out.wind_response = p.wind_response;
    out.visibility_range = p.tree_visibility_range; out.shadow_range = p.tree_shadow_range;
    out.exclusion_margin = p.natural_prop_exclusion_margin;
    out.age_min_years = p.tree_age_min_years; out.age_typical_years = p.tree_age_typical_years;
    out.age_max_years = p.tree_age_max_years; out.maturity_cell_scale = p.tree_maturity_cell_scale;
    out.maturity_influence = p.tree_maturity_influence; out.local_age_span = p.tree_local_age_span;
    out.age_distribution_skew = p.tree_age_distribution_skew;
    for (std::size_t i = 0U; i < 4U; ++i) out.age_band_thresholds[i] = p.tree_age_band_thresholds[i];
    out.height_growth_exponent = p.tree_height_growth_exponent;
    out.girth_growth_exponent = p.tree_girth_growth_exponent;
    out.crown_growth_exponent = p.tree_crown_growth_exponent;
    return out;
}

} // namespace

VWB_TEST(native_tree_shared_recipe_matches_direct_godot_make_tree_oracle) {
    // Direct engine report: artifacts/native-world-backend/n4-tree-construction-oracle.json.
    // This checks construction only, not ordered-stream admission or gameplay.
    struct Case { const char *biome; std::uint64_t seed; const char *id;
        std::int32_t x, z; std::uint32_t origin_x, origin_z, world_x, world_z;
        std::uint64_t before, after; std::uint32_t yaw, radius, height, center; std::size_t draws; };
    const std::array<Case, 2> cases{{
        {"taiga", 0U, "tree-order-oracle:-2,58:0", -2, 58,
            3256300339U,1117205299U,3224161488U,1117559193U,
            static_cast<std::uint64_t>(-8330585842245805678LL),
            static_cast<std::uint64_t>(-1430911683091090770LL),
            1067625786U,1074872112U,1114989569U,1106600961U,22U},
        {"plains", 4294967295ULL, "tree-order-oracle:-30,-26:0", -30, -26,
            3264688947U,3256300339U,3257008128U,3255592550U,
            static_cast<std::uint64_t>(-9176265316429931931LL),7838767313688009837ULL,
            1072876242U,1052884971U,1082327024U,1073938416U,36U}
    }};
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("tree-order-oracle");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("tree-order-oracle");
    descriptor.revisions.terrain_generator_revision = 3U; descriptor.revisions.lattice_query_revision = 5U;
    const WorldSourceDefinition source(std::move(descriptor));
    for (const auto &c : cases) {
        GodotPcg32 rng(c.seed);
        VWB_EXPECT_EQ(c.before, rng.state());
        std::vector<float> draws;
        for (std::size_t i = 0U; i < c.draws; ++i) draws.push_back(rng.randf());
        VWB_EXPECT_EQ(c.after, rng.state());
        NativeSurfacePropPlacementEntry placement;
        placement.presence = NativeSurfacePropPlacementPresence::anchored;
        placement.outcome = c.draws == 22U ? NativeSurfacePropClassificationOutcome::tree_22_draw
            : NativeSurfacePropClassificationOutcome::tree_36_draw;
        placement.durable_id = c.id; placement.cell_x = c.x; placement.cell_z = c.z;
        placement.local_position = {35.1F, 24.3F, 2.7F};
        placement.chunk_origin = {static_cast<float>(-37.8 * (c.draws == 22U ? 1 : 2)), 0.0F,
            static_cast<float>(75.6 * (c.draws == 22U ? 1 : -0.5))};
        placement.world_anchor = {placement.chunk_origin.x + placement.local_position.x,
            placement.local_position.y, placement.chunk_origin.z + placement.local_position.z};
        VWB_EXPECT_EQ(c.origin_x, bits(placement.chunk_origin.x));
        VWB_EXPECT_EQ(c.origin_z, bits(placement.chunk_origin.z));
        VWB_EXPECT_EQ(c.world_x, bits(placement.world_anchor.x));
        VWB_EXPECT_EQ(c.world_z, bits(placement.world_anchor.z));
        Sha256Digest receipt{}; receipt[0] = 1U;
        const auto tree = compose_native_surface_tree_recipe(placement, draws, source,
            oracle_profile(c.biome), receipt, "native_surface_tree_ordered_recipe", 1U);
        VWB_EXPECT_EQ(c.yaw, bits(static_cast<float>(tree.input().rotation_y)));
        VWB_EXPECT_EQ(c.radius, bits(tree.trunk_cylinder().radius));
        VWB_EXPECT_EQ(c.height, bits(tree.trunk_cylinder().height));
        VWB_EXPECT_EQ(c.center, bits(tree.trunk_cylinder().center_y));
    }
}

VWB_TEST(native_ordered_tree_binds_captured_draws_source_biome_frame_and_trunk) {
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-tree-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto stream = ordered(terrain);
        const auto placements = NativeSurfacePropOrderedPlacement::create(stream, terrain);
        for (std::uint32_t i = 0U; i < stream.attempts().size(); ++i) {
            const auto &attempt = stream.attempts()[i];
            if (!is_tree(attempt.outcome)) continue;
            const auto p = profile(attempt.source->biome_id);
            const auto tree = NativeSurfaceTreeOrderedComposer::create(stream, placements, i, terrain, p);
            const auto &input = tree.input(); const auto &entry = placements.entries()[i];
            VWB_EXPECT_EQ(std::string("native_surface_tree_ordered_recipe"), input.producer_key);
            VWB_EXPECT_EQ(entry.durable_id, input.durable_feature_id);
            VWB_EXPECT_EQ(p.source_biome, input.biome);
            VWB_EXPECT_EQ(static_cast<double>(entry.world_anchor.x), input.position.x);
            VWB_EXPECT_EQ(static_cast<double>(entry.world_anchor.y), input.position.y);
            VWB_EXPECT_EQ(static_cast<double>(entry.world_anchor.z), input.position.z);
            VWB_EXPECT_EQ(static_cast<double>(attempt.compatibility_draws[0]) * 6.283185307179586476925286766559,
                input.rotation_y);
            VWB_EXPECT_EQ(static_cast<float>(input.trunk_radius), tree.trunk_cylinder().radius);
            VWB_EXPECT_EQ(static_cast<float>(input.collision_height), tree.trunk_cylinder().height);
            VWB_EXPECT_EQ(tree.trunk_cylinder().height * 0.5F, tree.trunk_cylinder().center_y);
            VWB_EXPECT_EQ(attempt.outcome == NativeSurfacePropClassificationOutcome::tree_22_draw ? 22U : 36U,
                attempt.compatibility_draws.size());
            VWB_EXPECT_EQ(tree.content_digest(), NativeSurfaceTreeOrderedComposer::create(
                stream, placements, i, terrain, p).content_digest());
            auto other_profile = p; other_profile.source_profile_digest[0] ^= 1U;
            // A biome-matching but unadmitted caller profile is still accepted:
            // catalog-generation admission belongs to the later adapter.
            VWB_EXPECT(tree.content_digest() != NativeSurfaceTreeOrderedComposer::create(
                stream, placements, i, terrain, other_profile).content_digest());
            auto bad = p; bad.source_biome = "not-source-biome";
            VWB_EXPECT_THROW(NativeSurfaceTreeOrderedComposerRejected,
                NativeSurfaceTreeOrderedComposer::create(stream, placements, i, terrain, bad));
            bad = p; bad.age_band_thresholds = {0.1, 0.1, 0.5, 0.8};
            VWB_EXPECT_THROW(NativeSurfaceTreeOrderedComposerRejected,
                NativeSurfaceTreeOrderedComposer::create(stream, placements, i, terrain, bad));
            VWB_EXPECT_THROW(NativeSurfaceTreeOrderedComposerRejected,
                NativeSurfaceTreeOrderedComposer::create(stream, placements, 28U, terrain, p));
            const auto stale_definition = surface_prop_test_fixture::definition("ordered-tree-stale");
            const NativeEffectiveTerrainSource stale(surface_prop_test_fixture::ready_pin(
                stale_definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
            VWB_EXPECT_THROW(NativeSurfaceTreeOrderedComposerRejected,
                NativeSurfaceTreeOrderedComposer::create(stream, placements, i, stale, p));
            found = true; break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_ordered_tree_parent_tombstone_shifts_later_attempts_and_rejects_torn_placement) {
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-tree-tombstone-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto before = ordered(terrain);
        const auto after = ordered(terrain, NativeFeatureDeltaSnapshot::create({{before.attempts()[0].attempt.durable_id}}, {}));
        const auto before_set = NativeSurfacePropOrderedPlacement::create(before, terrain);
        const auto after_set = NativeSurfacePropOrderedPlacement::create(after, terrain);
        const auto &removed_profile = profile("plains");
        VWB_EXPECT_THROW(NativeSurfaceTreeOrderedComposerRejected,
            NativeSurfaceTreeOrderedComposer::create(after, after_set, 0U, terrain, removed_profile));
        VWB_EXPECT(after.attempts()[0].parent_tombstoned);
        VWB_EXPECT(before.final_rng_state() != after.final_rng_state());
        for (std::uint32_t i = 1U; i < after.attempts().size(); ++i) {
            if (!is_tree(after.attempts()[i].outcome)) continue;
            const auto p = profile(after.attempts()[i].source->biome_id);
            const auto tree = NativeSurfaceTreeOrderedComposer::create(after, after_set, i, terrain, p);
            VWB_EXPECT_EQ(after_set.entries()[i].durable_id, tree.input().durable_feature_id);
            VWB_EXPECT_THROW(NativeSurfaceTreeOrderedComposerRejected,
                NativeSurfaceTreeOrderedComposer::create(after, before_set, i, terrain, p));
            found = true; break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_ordered_tree_observes_both_legacy_22_and_36_draw_modes) {
    bool found_22 = false, found_36 = false;
    for (std::uint32_t candidate = 0U; candidate < 192U && (!found_22 || !found_36); ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-tree-draw-modes-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto stream = ordered(terrain);
        const auto placements = NativeSurfacePropOrderedPlacement::create(stream, terrain);
        for (std::uint32_t i = 0U; i < stream.attempts().size(); ++i) {
            const auto &attempt = stream.attempts()[i];
            if (!is_tree(attempt.outcome)) continue;
            const auto tree = NativeSurfaceTreeOrderedComposer::create(
                stream, placements, i, terrain, profile(attempt.source->biome_id));
            VWB_EXPECT_EQ(attempt.compatibility_draws.size(),
                attempt.outcome == NativeSurfacePropClassificationOutcome::tree_22_draw ? 22U : 36U);
            VWB_EXPECT_EQ(placements.entries()[i].durable_id, tree.input().durable_feature_id);
            found_22 |= attempt.outcome == NativeSurfacePropClassificationOutcome::tree_22_draw;
            found_36 |= attempt.outcome == NativeSurfacePropClassificationOutcome::tree_36_draw;
        }
    }
    VWB_EXPECT(found_22 && found_36);
}

VWB_TEST(native_ordered_tree_rejects_torn_optional_receipts) {
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-tree-optionals-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto stream = ordered(terrain);
        for (const auto &source_attempt : stream.attempts()) {
            if (!is_tree(source_attempt.outcome)) continue;
            auto attempt = source_attempt;
            validate_native_surface_tree_ordered_receipts(attempt);
            attempt.source.reset();
            VWB_EXPECT_THROW(NativeSurfaceTreeOrderedComposerRejected,
                validate_native_surface_tree_ordered_receipts(attempt));
            attempt = source_attempt; attempt.prop_roll.reset();
            VWB_EXPECT_THROW(NativeSurfaceTreeOrderedComposerRejected,
                validate_native_surface_tree_ordered_receipts(attempt));
            found = true; break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_ordered_tree_rejects_non_tree_attempt_after_source_resolution) {
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 96U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ordered-tree-non-tree-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto stream = ordered(terrain);
        const auto placements = NativeSurfacePropOrderedPlacement::create(stream, terrain);
        for (std::uint32_t i = 0U; i < stream.attempts().size(); ++i) {
            const auto &attempt = stream.attempts()[i];
            if (is_tree(attempt.outcome) || !attempt.source || !attempt.prop_roll) continue;
            VWB_EXPECT_THROW(NativeSurfaceTreeOrderedComposerRejected,
                NativeSurfaceTreeOrderedComposer::create(stream, placements, i, terrain,
                    profile(attempt.source->biome_id)));
            found = true; break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_tree_shared_recipe_validates_independent_external_inputs) {
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("tree-helper-validation-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto stream = ordered(terrain);
        const auto placements = NativeSurfacePropOrderedPlacement::create(stream, terrain);
        for (std::uint32_t i = 0U; i < stream.attempts().size(); ++i) {
            const auto &attempt = stream.attempts()[i];
            if (!is_tree(attempt.outcome)) continue;
            auto entry = placements.entries()[i]; auto draws = attempt.compatibility_draws;
            const auto p = profile(attempt.source->biome_id);
            Sha256Digest digest{}; digest[0] = 1U;
            const auto reject = [&](const NativeSurfacePropPlacementEntry &e,
                const std::vector<float> &d, const Sha256Digest &source_digest,
                const std::string &producer, std::uint32_t revision) {
                VWB_EXPECT_THROW(NativeSurfaceTreeDefinitionComposerRejected,
                    compose_native_surface_tree_recipe(e, d, terrain.pin().definition(), p,
                        source_digest, producer, revision));
            };
            reject(entry, draws, digest, "tree", 0U);
            reject(entry, draws, {}, "tree", 1U);
            reject(entry, draws, digest, "", 1U);
            entry.presence = NativeSurfacePropPlacementPresence::absent;
            reject(entry, draws, digest, "tree", 1U);
            entry = placements.entries()[i]; entry.outcome = NativeSurfacePropClassificationOutcome::ordinary_rock;
            reject(entry, draws, digest, "tree", 1U);
            entry = placements.entries()[i]; draws.pop_back();
            reject(entry, draws, digest, "tree", 1U);
            draws = attempt.compatibility_draws; draws[0] = std::numeric_limits<float>::infinity();
            reject(entry, draws, digest, "tree", 1U);
            draws[0] = -0.01F; reject(entry, draws, digest, "tree", 1U);
            draws[0] = 1.0F; reject(entry, draws, digest, "tree", 1U);
            found = true; break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_ordered_tree_post_draw_presence_binds_halo_and_stable_recipe) {
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("tree-presence-bound-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto stream = ordered(terrain);
        const auto placements = NativeSurfacePropOrderedPlacement::create(stream, terrain);
        for (std::uint32_t i = 0U; i < stream.attempts().size(); ++i) {
            const auto &attempt = stream.attempts()[i];
            if (!is_tree(attempt.outcome)) continue;
            const auto p = profile(attempt.source->biome_id);
            const auto tree = NativeSurfaceTreeOrderedComposer::create(stream, placements, i, terrain, p);
            const auto &entry = placements.entries()[i];
            const auto radius = tree.input().canopy_radius + tree.input().exclusion_margin;
            const auto margin = static_cast<std::int32_t>(std::ceil(radius / 1.35));
            const StructureExclusionRect coverage{entry.cell_x - margin, entry.cell_z - margin,
                entry.cell_x + margin, entry.cell_z + margin};
            std::vector<CitadelExclusionSource> regions;
            for (std::int32_t z = -1; z <= 0; ++z) for (std::int32_t x = -1; x <= 0; ++x) {
                CitadelExclusionSource c;
                c.region_x = x; c.region_z = z; c.status = CitadelSourceStatus::absent;
                c.source_key = "world:" + std::to_string(x) + "," + std::to_string(z);
                regions.push_back(c);
            }
            const auto clear_halo = NativeTreeExclusionHaloCapture::create(
                stream.world_digest(), stream.world_generation(), stream.exclusion_digest(),
                coverage, {}, {}, regions);
            const auto clear = compose_native_surface_tree_presence(
                stream, placements, i, terrain, p, clear_halo);
            VWB_EXPECT_EQ(NativeSurfaceTreePresence::present, clear.presence);
            VWB_EXPECT_EQ(tree.content_digest(), clear.tree_definition_digest);
            const auto blocker_halo = NativeTreeExclusionHaloCapture::create(
                stream.world_digest(), stream.world_generation(), stream.exclusion_digest(), coverage,
                {}, {{"edge-building", {entry.cell_x + margin, entry.cell_z,
                    entry.cell_x + margin, entry.cell_z}}}, regions);
            const auto blocked = compose_native_surface_tree_presence(
                stream, placements, i, terrain, p, blocker_halo);
            VWB_EXPECT_EQ(NativeSurfaceTreePresence::absent, blocked.presence);
            VWB_EXPECT_EQ(tree.content_digest(), blocked.tree_definition_digest);
            VWB_EXPECT(clear.content_digest != blocked.content_digest);
            auto stale_halo = NativeTreeExclusionHaloCapture::create(
                stream.world_digest(), stream.world_generation() + 1U, stream.exclusion_digest(),
                coverage, {}, {}, regions);
            VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
                compose_native_surface_tree_presence(stream, placements, i, terrain, p, stale_halo));
            auto other_world = stream.world_digest(); other_world[0] ^= 1U;
            stale_halo = NativeTreeExclusionHaloCapture::create(
                other_world, stream.world_generation(), stream.exclusion_digest(),
                coverage, {}, {}, regions);
            VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
                compose_native_surface_tree_presence(stream, placements, i, terrain, p, stale_halo));
            auto other_exclusion = stream.exclusion_digest(); other_exclusion[0] ^= 1U;
            stale_halo = NativeTreeExclusionHaloCapture::create(
                stream.world_digest(), stream.world_generation(), other_exclusion,
                coverage, {}, {}, regions);
            VWB_EXPECT_THROW(NativeSurfaceTreePresenceRejected,
                compose_native_surface_tree_presence(stream, placements, i, terrain, p, stale_halo));
            found = true; break;
        }
    }
    VWB_EXPECT(found);
}
