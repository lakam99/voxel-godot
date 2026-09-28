#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_forage_ordered_definition.hpp"
#include "../core/native_surface_forage_footprint.hpp"
#include "../core/sha256.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

using namespace voxel::world_backend;

namespace {
Sha256Digest world_digest() { Sha256Digest value{}; value[0] = 79U; return value; }

NativeStructureExclusionSnapshot exclusions(Sha256Digest digest = world_digest()) {
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent; absent.source_key = "world:0,0";
    return NativeStructureExclusionSnapshot::create(digest, 1U, {}, {}, {absent}, {{0,0,true}});
}

NativeWildlifePresentationReceipt animal(NativeWildlifeVariant variant, const char *asset) {
    NativeWildlifePresentationReceipt result;
    result.schema_revision = 1U; result.asset_catalog_digest.fill(1U);
    result.variant = variant; result.path = NativeWildlifePresentationPath::animated_playable;
    result.asset_id = asset; result.animation_clip_id = asset; return result;
}

NativeWildlifePresentationCatalog wildlife() {
    return NativeWildlifePresentationCatalog::create({
        animal(NativeWildlifeVariant::boar, "boar_idle_walk"), animal(NativeWildlifeVariant::deer, "deer_idle_walk"),
        animal(NativeWildlifeVariant::hare, "hare_idle_walk")});
}

std::vector<NativeBiomeEnvironmentProfile> profiles(NativeForageGrammar grammar) {
    auto values = tests::godot_oracle_environment_profiles();
    for (auto &profile : values) {
        profile.rock_base_chance = 0.0;
        profile.tree_chance = 0.0;
        profile.forage_chance = 1.0;
        profile.wildlife_chance = 0.0;
        switch (grammar) {
            case NativeForageGrammar::berry:
                profile.forage_material = "berryBush"; profile.forage_drop = "berries";
                profile.forage_drop_min = 2; profile.forage_drop_max = 4; profile.forage_radius = 0.56; break;
            case NativeForageGrammar::aloe:
                profile.forage_material = "aloePatch"; profile.forage_drop = "aloe";
                profile.forage_drop_min = 1; profile.forage_drop_max = 3; profile.forage_radius = 0.48; break;
            case NativeForageGrammar::mushroom:
                profile.forage_material = "mushroomCluster"; profile.forage_drop = "mirecap";
                profile.forage_drop_min = 1; profile.forage_drop_max = 3; profile.forage_radius = 0.50; break;
            case NativeForageGrammar::frost_herb:
                profile.forage_material = "frostHerbPatch"; profile.forage_drop = "frostHerb";
                profile.forage_drop_min = 1; profile.forage_drop_max = 2; profile.forage_radius = 0.48; break;
        }
    }
    return values;
}

std::uint32_t forage_ordinal(const NativeSurfacePropSourceOrderedStream &stream) {
    for (std::uint32_t index = 0U; index < stream.attempts().size(); ++index)
        if (stream.attempts()[index].outcome == NativeSurfacePropClassificationOutcome::forage_recipe) return index;
    throw std::runtime_error("no forage attempt");
}

struct GeometryWriter {
    std::vector<std::uint8_t> bytes;
    void u8(std::uint8_t v) { bytes.push_back(v); }
    void u32(std::uint32_t v) { for (int s=24;s>=0;s-=8) u8(static_cast<std::uint8_t>(v>>s)); }
    void u64(std::uint64_t v) { for (int s=56;s>=0;s-=8) u8(static_cast<std::uint8_t>(v>>s)); }
    void text(const std::string &v) { u32(static_cast<std::uint32_t>(v.size())); bytes.insert(bytes.end(),v.begin(),v.end()); }
    void f32(float v) { std::uint32_t bits; std::memcpy(&bits,&v,sizeof(bits)); u32(bits); }
    void vec(const NativeForageVec3 &v) { f32(v.x); f32(v.y); f32(v.z); }
};

std::string geometry_digest(const NativeForageDecodedGeometry &geometry,
    const NativeForageStream &stream) {
    GeometryWriter writer;
    writer.f32(geometry.rotation_y); writer.f32(geometry.collider_radius);
    writer.f32(geometry.collider_center_y); writer.u8(geometry.navigation_blocker ? 1U : 0U);
    writer.u64(static_cast<std::uint64_t>(stream.drop_count)); writer.u64(stream.state_after);
    writer.u32(static_cast<std::uint32_t>(geometry.meshes.size()));
    for (const auto &mesh : geometry.meshes) {
        writer.u8(static_cast<std::uint8_t>(mesh.kind)); writer.text(mesh.material_id);
        writer.vec(mesh.position); writer.vec(mesh.rotation); writer.vec(mesh.scale);
        writer.f32(mesh.radius); writer.f32(mesh.height); writer.f32(mesh.top_radius); writer.f32(mesh.bottom_radius);
        writer.u32(static_cast<std::uint32_t>(mesh.radial_segments)); writer.u32(static_cast<std::uint32_t>(mesh.rings));
    }
    return sha256_hex(sha256(writer.bytes));
}
} // namespace

VWB_TEST(native_forage_decoder_matches_four_direct_godot_construction_geometry_goldens) {
    // Reproduce these independently from the direct Godot report with
    // `node tools/derive-n4-forage-geometry-goldens.mjs <report.json>`.
    // The bridge serializes every field represented in the decoded native
    // geometry, plus drop count and final RNG state, in the fixed-width byte
    // format below. Body placement/metadata are separately asserted by the
    // Godot oracle and ordered-placement contracts, not this decoder hash.
    struct Case { const char *biome; std::uint64_t seed; const char *golden; };
    const Case cases[] = {
        {"plains",17U,"41be27a59ec1dd3c15fde4b8de248b2e750d2f48f7f21312f77b71dd59920a37"},
        {"desert",29U,"d5a011b860b8894e1c30d290f7c3ddb7bfd23ba4080bee0945d6f89aefdb5868"},
        {"swamp",41U,"829b0e82db0f397a3a68eb90181663736154212b260cfe991bd41f91f8b3e295"},
        {"snow",53U,"b1f55799e0ea9c92bad701db4a1e36cc03ce04495fee237ee25a66d061de1579"},
    };
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    for (const auto &case_ : cases) {
        const auto &profile = catalog.profile_for_biome(case_.biome);
        NativeForageRecipe recipe;
        recipe.recipe_id = profile.biome_id + ":" + profile.forage_material;
        recipe.material_id = profile.forage_material; recipe.drop_id = profile.forage_drop;
        recipe.drop_min = profile.forage_drop_min; recipe.drop_max = profile.forage_drop_max;
        recipe.collider_radius = static_cast<float>(profile.forage_radius);
        if (recipe.material_id == "berryBush") recipe.grammar = NativeForageGrammar::berry;
        else if (recipe.material_id == "aloePatch") recipe.grammar = NativeForageGrammar::aloe;
        else if (recipe.material_id == "mushroomCluster") recipe.grammar = NativeForageGrammar::mushroom;
        else recipe.grammar = NativeForageGrammar::frost_herb;
        recipe.navigation = recipe.grammar == NativeForageGrammar::berry
            ? NativeForageNavigationPolicy::blocking : NativeForageNavigationPolicy::nonblocking;
        GodotPcg32 rng(case_.seed);
        const auto stream = NativeForageStreamBuilder::create(recipe, rng);
        const auto geometry = decode_native_forage_geometry(recipe, stream);
        const auto actual = geometry_digest(geometry, stream);
        if (actual != case_.golden) tests::fail("forage geometry parity", __FILE__, __LINE__,
            std::string(case_.biome) + " expected=" + case_.golden + " actual=" + actual);
    }
}

VWB_TEST(native_forage_decoder_rejects_malformed_capture_without_consuming_rng) {
    const auto profile_catalog = NativeBiomeEnvironmentCatalog::create(
        tests::godot_oracle_environment_profiles());
    auto unknown_profile = profile_catalog.profile_for_biome("plains");
    unknown_profile.forage_material = "unknownForage";
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        native_forage_recipe_for_environment_profile(unknown_profile));
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        native_forage_expected_draw_count(static_cast<NativeForageGrammar>(99)));
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    const auto &profile = catalog.profile_for_biome("plains");
    NativeForageRecipe recipe{profile.biome_id + ":" + profile.forage_material,
        profile.forage_material, profile.forage_drop, profile.forage_drop_min,
        profile.forage_drop_max, static_cast<float>(profile.forage_radius),
        NativeForageGrammar::berry, NativeForageNavigationPolicy::blocking};
    GodotPcg32 rng(17U);
    const auto original = NativeForageStreamBuilder::create(recipe, rng);
    const auto state = rng.state();
    auto bad_recipe = recipe; bad_recipe.material_id = "wrong";
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(bad_recipe, original));
    auto bad = original; bad.recipe.recipe_id = "wrong";
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; bad.recipe.material_id = "wrong";
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; bad.recipe.drop_id = "wrong";
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; ++bad.recipe.drop_min;
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; ++bad.recipe.drop_max;
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; bad.recipe.collider_radius += 0.01F;
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; bad.recipe.grammar = NativeForageGrammar::aloe;
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; bad.recipe.navigation = NativeForageNavigationPolicy::nonblocking;
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; bad.float_draws.pop_back();
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; bad.drop_count = recipe.drop_min - 1;
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    bad = original; bad.drop_count = recipe.drop_max + 1;
    VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
        decode_native_forage_geometry(recipe, bad));
    for (float value : {std::numeric_limits<float>::quiet_NaN(), -0.1F, 1.0F}) {
        bad = original; bad.float_draws[0] = value;
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            decode_native_forage_geometry(recipe, bad));
    }
    VWB_EXPECT_EQ(state, rng.state());
}

VWB_TEST(native_ordered_forage_definition_projects_all_four_grammars_and_separate_nav_channel) {
    for (const auto grammar : {NativeForageGrammar::berry, NativeForageGrammar::aloe,
        NativeForageGrammar::mushroom, NativeForageGrammar::frost_herb}) {
        const auto definition = surface_prop_test_fixture::definition("forage-definition");
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles(grammar));
        const auto ordered = NativeSurfacePropSourceOrderedStream::create(
            terrain.pin().definition().raw_terrain_seed(), 0, 0, world_digest(), 1U,
            terrain, catalog, exclusions(), NativeFeatureDeltaSnapshot::create({}, {}), wildlife());
        const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
        const auto ordinal = forage_ordinal(ordered);
        const auto source_attempt = ordered.attempts()[ordinal];
        const auto source_placement = placements.entries()[ordinal];
        validate_native_forage_attempt_placement(source_attempt, source_placement);
        auto invalid_attempt = source_attempt;
        invalid_attempt.outcome = NativeSurfacePropClassificationOutcome::ordinary_rock;
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            validate_native_forage_attempt_placement(invalid_attempt, source_placement));
        invalid_attempt = source_attempt; invalid_attempt.forage.reset();
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            validate_native_forage_attempt_placement(invalid_attempt, source_placement));
        auto invalid_placement = source_placement;
        invalid_placement.presence = NativeSurfacePropPlacementPresence::absent;
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            validate_native_forage_attempt_placement(source_attempt, invalid_placement));
        invalid_placement = source_placement; invalid_placement.durable_id += ":wrong";
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            validate_native_forage_attempt_placement(source_attempt, invalid_placement));
        VWB_EXPECT_EQ(source_attempt.forage->float_draws.size(),
            native_forage_expected_draw_count(grammar));
        const auto projected = NativeSurfaceForageOrderedDefinition::create(ordered, placements, ordinal, terrain, catalog);
        const auto repeat = NativeSurfaceForageOrderedDefinition::create(ordered, placements, ordinal, terrain, catalog);
        const auto expected_count = grammar == NativeForageGrammar::berry || grammar == NativeForageGrammar::mushroom ? 8U
            : grammar == NativeForageGrammar::aloe ? 6U : 5U;
        VWB_EXPECT_EQ(grammar, projected.recipe().grammar);
        VWB_EXPECT_EQ(std::string(NativeSurfacePropSourceDecisionResolver::biome_name(
            placements.entries()[ordinal].biome)) + ":" + projected.recipe().material_id,
            projected.recipe().recipe_id);
        VWB_EXPECT_EQ(expected_count, projected.meshes().size());
        VWB_EXPECT(projected.physical_collider_present());
        VWB_EXPECT_EQ(grammar == NativeForageGrammar::berry, projected.navigation_blocker());
        VWB_EXPECT_EQ(projected.collider_radius() * 0.45F, projected.collider_center_y());
        VWB_EXPECT_EQ(ordered.attempts()[ordinal].forage->drop_count, projected.drop_count());
        VWB_EXPECT_EQ(placements.entries()[ordinal].world_anchor.x, projected.placement().world_anchor.x);
        VWB_EXPECT(projected.rotation_y() >= 0.0F && projected.rotation_y() < 6.283186F);
        VWB_EXPECT_EQ(projected.content_digest(), repeat.content_digest());
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            NativeSurfaceForageOrderedDefinition::create(ordered, placements, 28U, terrain, catalog));
        const NativeEffectiveTerrainSource stale(surface_prop_test_fixture::ready_pin(
            surface_prop_test_fixture::definition("forage-stale-pin"), {0,0},
            surface_prop_test_fixture::empty_deltas()));
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            NativeSurfaceForageOrderedDefinition::create(ordered, placements, ordinal, stale, catalog));
        const auto changed_catalog = NativeBiomeEnvironmentCatalog::create(profiles(
            grammar == NativeForageGrammar::berry ? NativeForageGrammar::aloe : NativeForageGrammar::berry));
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            NativeSurfaceForageOrderedDefinition::create(ordered, placements, ordinal, terrain, changed_catalog));
        const auto tombstones = NativeFeatureDeltaSnapshot::create({{ordered.attempts()[ordinal].attempt.durable_id}}, {});
        const auto removed_ordered = NativeSurfacePropSourceOrderedStream::create(
            terrain.pin().definition().raw_terrain_seed(), 0, 0, world_digest(), 1U,
            terrain, catalog, exclusions(), tombstones, wildlife());
        const auto removed_placements = NativeSurfacePropOrderedPlacement::create(removed_ordered, terrain);
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            NativeSurfaceForageOrderedDefinition::create(ordered, removed_placements, ordinal, terrain, catalog));
        auto other_world = world_digest(); other_world[0] ^= 1U;
        const auto rebound_ordered = NativeSurfacePropSourceOrderedStream::create(
            terrain.pin().definition().raw_terrain_seed(), 0, 0, other_world, 1U,
            terrain, catalog, exclusions(other_world), NativeFeatureDeltaSnapshot::create({}, {}), wildlife());
        const auto rebound_placements = NativeSurfacePropOrderedPlacement::create(rebound_ordered, terrain);
        VWB_EXPECT_EQ(ordered.final_rng_state(), rebound_ordered.final_rng_state());
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            NativeSurfaceForageOrderedDefinition::create(ordered, rebound_placements, ordinal, terrain, catalog));
    }
}

VWB_TEST(native_forage_footprint_contains_every_direct_godot_child_aabb_cell) {
    // Independent transformed mesh.get_aabb() and sphere-shape world AABBs from
    // N4ForageConstructionOracle.gd, source-matched report SHA-256
    // 1cfa4d6eb760ed3c4b7a7b0db0d34441675989380f8e13e4ae01de4382449507.
    // Each range is floor(world AABB min/max / 1.35), inclusive. The preceding
    // decoder golden fixes every mesh transform, dimension, and draw for these seeds.
    struct Range { int x0,y0,z0,x1,y1,z1; bool collider = false; };
    struct Case { const char *biome; std::uint64_t seed; NativeForageVec3 anchor;
        std::vector<Range> bounds; };
    const Case cases[] = {
        {"plains",17U,{4.050000190734863F,18.25F,35.099998474121094F},
            {{2,13,25,3,13,26},{3,13,25,3,13,25},{3,13,25,3,13,26},
             {2,13,26,3,13,26},{3,13,25,3,13,26},{3,13,26,3,13,26},
             {3,13,26,3,13,26},{2,13,25,2,13,26},{2,13,25,3,14,26,true}}},
        {"desert",29U,{-33.75F,18.25F,35.099998474121094F},
            {{-26,13,25,-25,13,26},{-26,13,25,-25,13,26},
             {-26,13,25,-25,13,26},{-26,13,25,-25,13,26},
             {-26,13,25,-25,13,26},{-26,13,25,-25,13,26},
             {-26,13,25,-25,14,26,true}}},
        {"swamp",41U,{-71.54999542236328F,18.25F,-2.700000762939453F},
            {{-54,13,-2,-54,13,-2},{-54,13,-3,-53,13,-2},
             {-53,13,-3,-53,13,-3},{-54,13,-3,-53,13,-3},
             {-54,13,-2,-54,13,-2},{-54,13,-3,-54,13,-2},
             {-53,13,-3,-53,13,-3},{-54,13,-3,-53,13,-2},
             {-54,13,-3,-53,14,-2,true}}},
        {"snow",53U,{344.25F,18.25F,-229.5F},
            {{254,13,-171,254,13,-170},{254,13,-171,254,13,-170},
             {254,13,-170,255,13,-170},{254,13,-170,254,13,-170},
             {254,13,-170,255,13,-170},{254,13,-171,255,14,-170,true}}},
    };
    const auto catalog = NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
    for (const auto &case_ : cases) {
        const auto &profile = catalog.profile_for_biome(case_.biome);
        const auto recipe = native_forage_recipe_for_environment_profile(profile);
        GodotPcg32 rng(case_.seed);
        const auto stream = NativeForageStreamBuilder::create(recipe, rng);
        const auto geometry = decode_native_forage_geometry(recipe, stream);
        VWB_EXPECT_EQ(case_.bounds.size(), geometry.meshes.size() + 1U);
        const auto runs = native_surface_forage_geometry_runs(geometry, case_.anchor, 1.35);
        for (const auto &bound : case_.bounds) {
            const auto channel = bound.collider ? NativeFeatureFootprintChannel::collision
                : NativeFeatureFootprintChannel::render;
            for (int z=bound.z0; z<=bound.z1; ++z)
                for (int y=bound.y0; y<=bound.y1; ++y)
                    for (int x=bound.x0; x<=bound.x1; ++x) {
                        const bool covered = std::any_of(runs.begin(), runs.end(), [&](const auto &run) {
                            return run.channel == channel && run.first.z == z && run.first.y == y
                                && run.first.x <= x && x <= run.last_x_inclusive;
                        });
                        if (!covered) tests::fail("direct Godot AABB cell absent from native forage footprint",
                            __FILE__, __LINE__, std::string(case_.biome) + " cell="
                                + std::to_string(x) + "," + std::to_string(y) + "," + std::to_string(z));
                    }
        }
    }
}

VWB_TEST(native_ordered_forage_footprints_follow_four_grammars_and_nav_policy) {
    for (const auto grammar : {NativeForageGrammar::berry, NativeForageGrammar::aloe,
            NativeForageGrammar::mushroom, NativeForageGrammar::frost_herb}) {
        const auto definition = surface_prop_test_fixture::definition("forage-definition");
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto catalog = NativeBiomeEnvironmentCatalog::create(profiles(grammar));
        const auto ordered = NativeSurfacePropSourceOrderedStream::create(
            terrain.pin().definition().raw_terrain_seed(), 0, 0, world_digest(), 1U,
            terrain, catalog, exclusions(), NativeFeatureDeltaSnapshot::create({}, {}), wildlife());
        const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
        const auto ordinal = forage_ordinal(ordered);
        const auto forage = NativeSurfaceForageOrderedDefinition::create(
            ordered, placements, ordinal, terrain, catalog);
        const auto footprints = compose_native_surface_forage_footprint(
            ordered, placements, ordinal, terrain, catalog);
        const auto repeated = compose_native_surface_forage_footprint(
            ordered, placements, ordinal, terrain, catalog);
        VWB_EXPECT_EQ(footprints.content_digest(), repeated.content_digest());
        VWB_EXPECT_EQ(1U, footprints.entries().size());
        const auto *entry = footprints.find(forage.placement().durable_id);
        VWB_EXPECT(entry != nullptr);
        VWB_EXPECT_EQ(forage.content_digest(), entry->generated_definition_digest);
        VWB_EXPECT_EQ(terrain.pin().physical_content_identity().digest, footprints.source_digest());
        VWB_EXPECT_EQ(NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS, entry->declared_channel_mask);
        const double cell_size = terrain.pin().definition().constants().cell_size_meters;
        const auto covered = [&](NativeFeatureFootprintChannel channel, double x, double y, double z) {
            const auto cx = static_cast<std::int32_t>(std::floor(x / cell_size));
            const auto cy = static_cast<std::int32_t>(std::floor(y / cell_size));
            const auto cz = static_cast<std::int32_t>(std::floor(z / cell_size));
            for (const auto &run : entry->runs)
                if (run.channel == channel && run.first.y == cy && run.first.z == cz
                    && run.first.x <= cx && cx <= run.last_x_inclusive) return true;
            return false;
        };
        const auto &anchor = forage.placement().world_anchor;
        const double cr = forage.collider_radius();
        VWB_EXPECT(covered(NativeFeatureFootprintChannel::collision,
            anchor.x - cr, anchor.y + forage.collider_center_y(), anchor.z));
        VWB_EXPECT(covered(NativeFeatureFootprintChannel::collision,
            anchor.x, anchor.y + forage.collider_center_y() + cr, anchor.z));
        VWB_EXPECT_EQ(forage.navigation_blocker(),
            covered(NativeFeatureFootprintChannel::navigation,
                anchor.x + cr, anchor.y + forage.collider_center_y(), anchor.z));
        for (const auto &mesh : forage.meshes()) {
            const double c = std::cos(forage.rotation_y()), s = std::sin(forage.rotation_y());
            const double mx = anchor.x + c * mesh.position.x - s * mesh.position.z;
            const double mz = anchor.z + s * mesh.position.x + c * mesh.position.z;
            const double horizontal = mesh.kind == NativeForageMeshKind::sphere
                ? mesh.radius : std::max(mesh.top_radius, mesh.bottom_radius);
            VWB_EXPECT(covered(NativeFeatureFootprintChannel::render,
                mx + horizontal * mesh.scale.x, anchor.y + mesh.position.y, mz));
            VWB_EXPECT(covered(NativeFeatureFootprintChannel::render,
                mx, anchor.y + mesh.position.y + mesh.height * mesh.scale.y * 0.5, mz));
        }
        for (const auto &run : entry->runs)
            VWB_EXPECT(run.channel != NativeFeatureFootprintChannel::terrain_source);
        VWB_EXPECT_THROW(NativeSurfaceForageOrderedDefinitionRejected,
            compose_native_surface_forage_footprint(ordered, placements, 28U, terrain, catalog));
    }
}
