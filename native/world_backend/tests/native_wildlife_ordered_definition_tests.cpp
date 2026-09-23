#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_wildlife_ordered_definition.hpp"

#include <cmath>
#include <cstring>
#include <string>

using namespace voxel::world_backend;

namespace {
Sha256Digest world_digest() { Sha256Digest d{}; d[0] = 83U; return d; }
std::uint32_t float_bits(float value) {
    std::uint32_t bits = 0U;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}
NativeStructureExclusionSnapshot exclusions() {
    CitadelExclusionSource absent;
    absent.status = CitadelSourceStatus::absent; absent.source_key = "world:0,0";
    return NativeStructureExclusionSnapshot::create(world_digest(), 1U, {}, {}, {absent}, {{0,0,true}});
}
NativeWildlifePresentationReceipt animal(NativeWildlifeVariant variant, const char *asset,
    NativeWildlifePresentationPath path) {
    NativeWildlifePresentationReceipt r;
    r.schema_revision = 1U; r.asset_catalog_digest.fill(1U);
    r.variant = variant; r.asset_id = asset; r.animation_clip_id = asset; r.path = path;
    return r;
}
NativeWildlifePresentationCatalog wildlife(NativeWildlifePresentationPath path) {
    return NativeWildlifePresentationCatalog::create({
        animal(NativeWildlifeVariant::boar, "boar_idle_walk", path),
        animal(NativeWildlifeVariant::deer, "deer_idle_walk", path),
        animal(NativeWildlifeVariant::hare, "hare_idle_walk", path)});
}
NativeBiomeEnvironmentCatalog catalog() {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &p : profiles) {
        p.rock_base_chance = 0.0; p.tree_chance = 0.0;
        p.forage_chance = 0.0; p.wildlife_chance = 1.0;
    }
    return NativeBiomeEnvironmentCatalog::create(profiles);
}
std::uint32_t wildlife_ordinal(const NativeSurfacePropSourceOrderedStream &ordered) {
    for (std::uint32_t i = 0; i < ordered.attempts().size(); ++i)
        if (ordered.attempts()[i].outcome == NativeSurfacePropClassificationOutcome::wildlife_recipe) return i;
    throw std::runtime_error("no wildlife attempt");
}
std::string geometry_digest(const NativeWildlifeDecodedConstruction &g) {
    std::string text;
    auto part = [&](const std::string &value) {
        if (!text.empty()) text += '|';
        text += value;
    };
    auto number = [&](std::uint32_t value) { part(std::to_string(value)); };
    auto bits = [&](float value) { number(float_bits(value)); };
    auto vec = [&](NativeWildlifeVec3 value) { bits(value.x); bits(value.y); bits(value.z); };
    part("BoxShape3D"); number(0U); // collision disabled == false
    vec(g.collider_center); vec(g.collider_size);
    vec(g.visual_scale); vec(g.visual_rotation);
    number(static_cast<std::uint32_t>(g.procedural_meshes.size()));
    for (const auto &m : g.procedural_meshes) {
        part(m.kind == NativeWildlifeMeshKind::sphere ? "SphereMesh" : "CylinderMesh");
        part(m.material_id); vec(m.position); vec(m.rotation); vec(m.scale);
        bits(m.radius); bits(m.height); bits(m.top_radius); bits(m.bottom_radius);
        number(static_cast<std::uint32_t>(m.radial_segments));
        number(static_cast<std::uint32_t>(m.rings));
    }
    return sha256_hex(sha256(reinterpret_cast<const std::uint8_t *>(text.data()), text.size()));
}
} // namespace

VWB_TEST(native_ordered_wildlife_definition_projects_both_presentation_paths) {
    for (const auto path : {NativeWildlifePresentationPath::animated_playable,
            NativeWildlifePresentationPath::procedural_fallback}) {
        const auto definition = surface_prop_test_fixture::definition("wildlife-definition");
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto c = catalog(); const auto presentations = wildlife(path);
        const auto ordered = NativeSurfacePropSourceOrderedStream::create(
            terrain.pin().definition().raw_terrain_seed(), 0, 0, world_digest(), 1U,
            terrain, c, exclusions(), NativeFeatureDeltaSnapshot::create({}, {}), presentations);
        const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
        const auto ordinal = wildlife_ordinal(ordered);
        const auto projected = NativeSurfaceWildlifeOrderedDefinition::create(
            ordered, placements, ordinal, terrain, c, presentations);
        const auto repeated = NativeSurfaceWildlifeOrderedDefinition::create(
            ordered, placements, ordinal, terrain, c, presentations);
        const auto &s = *ordered.attempts()[ordinal].wildlife;
        const auto &g = projected.construction();
        const auto &collider = projected.initial_collider();
        VWB_EXPECT_EQ(projected.placement().durable_id, collider.durable_id);
        VWB_EXPECT_EQ(float_bits(projected.placement().world_anchor.x), float_bits(collider.body_origin.x));
        VWB_EXPECT_EQ(float_bits(projected.placement().world_anchor.y), float_bits(collider.body_origin.y));
        VWB_EXPECT_EQ(float_bits(projected.placement().world_anchor.z), float_bits(collider.body_origin.z));
        VWB_EXPECT_EQ(float_bits(g.body_yaw), float_bits(collider.body_yaw));
        VWB_EXPECT_EQ(float_bits(g.collider_center.y), float_bits(collider.local_center.y));
        VWB_EXPECT_EQ(float_bits(g.collider_size.x), float_bits(collider.box_size.x));
        VWB_EXPECT_EQ(s.recipe.collision_layer, collider.collision_layer);
        VWB_EXPECT_EQ(s.recipe.collision_mask, collider.collision_mask);
        VWB_EXPECT_EQ(s.recipe.variant, projected.stream().recipe.variant);
        VWB_EXPECT_EQ(s.presentation.path, g.presentation_path);
        VWB_EXPECT_EQ(path == NativeWildlifePresentationPath::animated_playable ? 0U : 8U,
            g.procedural_meshes.size());
        VWB_EXPECT_EQ(s.recipe.collider.size_x, g.collider_size.x);
        VWB_EXPECT_EQ(s.recipe.collider.center_y, g.collider_center.y);
        VWB_EXPECT_EQ(projected.placement().world_anchor.x, g.movement.home.x);
        VWB_EXPECT_EQ(projected.placement().world_anchor.z, g.movement.home.z);
        VWB_EXPECT(g.movement.timer >= 0.8F && g.movement.timer <= 2.6F);
        VWB_EXPECT(g.movement.speed > 0.0F);
        VWB_EXPECT_EQ(projected.content_digest(), repeated.content_digest());
        VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
            NativeSurfaceWildlifeOrderedDefinition::create(ordered, placements, 28U, terrain, c, presentations));
        const NativeEffectiveTerrainSource stale(surface_prop_test_fixture::ready_pin(
            surface_prop_test_fixture::definition("wildlife-stale"), {0,0},
            surface_prop_test_fixture::empty_deltas()));
        VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
            NativeSurfaceWildlifeOrderedDefinition::create(ordered, placements, ordinal, stale, c, presentations));
        auto changed_profiles = tests::godot_oracle_environment_profiles();
        for (auto &profile : changed_profiles) {
            profile.rock_base_chance = 0.0; profile.tree_chance = 0.0;
            profile.forage_chance = 0.0; profile.wildlife_chance = 0.5;
        }
        const auto changed_catalog = NativeBiomeEnvironmentCatalog::create(changed_profiles);
        VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
            NativeSurfaceWildlifeOrderedDefinition::create(ordered, placements, ordinal, terrain,
                changed_catalog, presentations));
        for (std::uint32_t other = 0; other < ordered.attempts().size(); ++other) {
            if (ordered.attempts()[other].outcome == NativeSurfacePropClassificationOutcome::wildlife_recipe) continue;
            VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
                NativeSurfaceWildlifeOrderedDefinition::create(ordered, placements, other, terrain, c, presentations));
            break;
        }
        const auto wrong_path = wildlife(path == NativeWildlifePresentationPath::animated_playable
            ? NativeWildlifePresentationPath::procedural_fallback
            : NativeWildlifePresentationPath::animated_playable);
        VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
            NativeSurfaceWildlifeOrderedDefinition::create(ordered, placements, ordinal, terrain, c, wrong_path));
    }
}

VWB_TEST(native_wildlife_construction_decoder_rejects_partial_or_invalid_draws) {
    GodotPcg32 rng(17U);
    const auto s = NativeWildlifeStreamBuilder::create(NativeWildlifeBiomeGroup::forest_or_plains,
        wildlife(NativeWildlifePresentationPath::animated_playable), rng);
    const WorldFloat32Position anchor{3.0F, 4.0F, 5.0F};
    const auto g = decode_native_wildlife_construction(s, anchor);
    VWB_EXPECT_EQ(3.0F, g.movement.home.x);
    VWB_EXPECT(g.animation_speed_scale >= 0.75F && g.animation_speed_scale <= 1.1F);
    auto malformed = s;
    malformed.presentation.path = static_cast<NativeWildlifePresentationPath>(3);
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
        decode_native_wildlife_construction(malformed, anchor));
    malformed = s; malformed.direction_roll = std::nanf("");
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
        decode_native_wildlife_construction(malformed, anchor));
    malformed = s; malformed.primary_drop_count = 100;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
        decode_native_wildlife_construction(malformed, anchor));
    malformed = s; malformed.primary_drop_count = 0;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
        decode_native_wildlife_construction(malformed, anchor));
    malformed = s; malformed.extra_drop_count = 100;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
        decode_native_wildlife_construction(malformed, anchor));
    malformed = s; malformed.extra_drop_count = 0;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
        decode_native_wildlife_construction(malformed, anchor));
    malformed = s; malformed.presentation.variant = NativeWildlifeVariant::boar;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
        decode_native_wildlife_construction(malformed, anchor));
    malformed = s; malformed.presentation.asset_catalog_digest = {};
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
        decode_native_wildlife_construction(malformed, anchor));
    for (float invalid : {-0.01F, 1.0F, std::nanf("")}) {
        malformed = s; malformed.speed_roll = invalid;
        VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
            decode_native_wildlife_construction(malformed, anchor));
    }
}

VWB_TEST(native_wildlife_ordered_source_guards_reject_each_mutated_receipt_and_recipe_field) {
    const auto receipt = animal(NativeWildlifeVariant::deer, "deer_idle_walk",
        NativeWildlifePresentationPath::animated_playable);
    VWB_EXPECT(native_surface_wildlife_same_receipt(receipt, receipt));
    const auto receipt_change = [&](auto mutate) {
        auto altered = receipt; mutate(altered);
        VWB_EXPECT(!native_surface_wildlife_same_receipt(receipt, altered));
    };
    receipt_change([](auto &r) { ++r.schema_revision; });
    receipt_change([](auto &r) { r.asset_catalog_digest[0] ^= 1U; });
    receipt_change([](auto &r) { r.variant = NativeWildlifeVariant::hare; });
    receipt_change([](auto &r) { r.asset_id += ":wrong"; });
    receipt_change([](auto &r) { r.animation_clip_id += ":wrong"; });
    receipt_change([](auto &r) { r.path = NativeWildlifePresentationPath::procedural_fallback; });

    const auto recipe = NativeWildlifeRecipeCatalog::resolve(NativeWildlifeVariant::deer);
    VWB_EXPECT(native_surface_wildlife_same_recipe(recipe, recipe));
    const auto recipe_change = [&](auto mutate) {
        auto altered = recipe; mutate(altered);
        VWB_EXPECT(!native_surface_wildlife_same_recipe(recipe, altered));
    };
    recipe_change([](auto &r) { ++r.revision; });
    recipe_change([](auto &r) { r.variant = NativeWildlifeVariant::hare; });
    recipe_change([](auto &r) { r.material_id += ":wrong"; });
    recipe_change([](auto &r) { r.primary_drop_id += ":wrong"; });
    recipe_change([](auto &r) { --r.primary_drop_min; });
    recipe_change([](auto &r) { ++r.primary_drop_max; });
    recipe_change([](auto &r) { r.extra_drop_id += ":wrong"; });
    recipe_change([](auto &r) { --r.extra_drop_min; });
    recipe_change([](auto &r) { ++r.extra_drop_max; });
    recipe_change([](auto &r) { r.visual_scale += 0.1F; });
    recipe_change([](auto &r) { r.speed_multiplier += 0.1F; });
    recipe_change([](auto &r) { r.cold_speed_multiplier += 0.1F; });
    recipe_change([](auto &r) { r.collider.size_x += 0.1F; });
    recipe_change([](auto &r) { r.collider.size_y += 0.1F; });
    recipe_change([](auto &r) { r.collider.size_z += 0.1F; });
    recipe_change([](auto &r) { r.collider.center_y += 0.1F; });
    recipe_change([](auto &r) { ++r.collision_layer; });
    recipe_change([](auto &r) { ++r.collision_mask; });
    recipe_change([](auto &r) { r.navigation = static_cast<NativeWildlifeNavigationPolicy>(2); });
}

VWB_TEST(native_wildlife_ordered_admission_rejects_each_corrupt_source_fact) {
    const auto definition = surface_prop_test_fixture::definition("wildlife-admission");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto c = catalog(); const auto presentations = wildlife(NativeWildlifePresentationPath::animated_playable);
    const auto ordered = NativeSurfacePropSourceOrderedStream::create(
        terrain.pin().definition().raw_terrain_seed(), 0, 0, world_digest(), 1U,
        terrain, c, exclusions(), NativeFeatureDeltaSnapshot::create({}, {}), presentations);
    const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    const auto ordinal = wildlife_ordinal(ordered);
    auto receipt = ordered.source_receipt();
    auto attempt = ordered.attempts()[ordinal];
    auto placement = placements.entries()[ordinal];
    auto placement_digest = placements.content_digest();
    auto recomputed_digest = placement_digest;
    auto placement_final = placements.final_rng_state();
    const auto check = [&]() {
        validate_native_surface_wildlife_ordered_facts(ordinal, receipt, ordered.final_rng_state(),
            placement_final, placement_digest, recomputed_digest, attempt, placement,
            terrain.pin(), c, presentations);
    };
    check();
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected,
        validate_native_surface_wildlife_ordered_facts(28U, receipt, ordered.final_rng_state(),
            placement_final, placement_digest, recomputed_digest, attempt, placement,
            terrain.pin(), c, presentations));
    receipt.effective_source_digest[0] ^= 1U;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    receipt = ordered.source_receipt(); receipt.environment_profile_digest[0] ^= 1U;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    receipt = ordered.source_receipt(); ++placement_final;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    placement_final = placements.final_rng_state(); placement_digest[0] ^= 1U;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    placement_digest = placements.content_digest(); attempt.outcome = NativeSurfacePropClassificationOutcome::no_feature;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    attempt = ordered.attempts()[ordinal]; attempt.wildlife.reset();
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    attempt = ordered.attempts()[ordinal]; attempt.source.reset();
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    attempt = ordered.attempts()[ordinal]; placement.presence = NativeSurfacePropPlacementPresence::absent;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    placement = placements.entries()[ordinal]; placement.durable_id += ":wrong";
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    placement = placements.entries()[ordinal];
    attempt.wildlife->presentation.path = NativeWildlifePresentationPath::procedural_fallback;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    attempt = ordered.attempts()[ordinal]; attempt.wildlife->recipe.visual_scale += 0.1F;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    attempt = ordered.attempts()[ordinal]; attempt.wildlife->cold = !attempt.wildlife->cold;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    attempt = ordered.attempts()[ordinal];
    const auto group = native_surface_prop_wildlife_group(attempt.source->biome_id);
    const auto desired = attempt.wildlife->recipe.variant;
    bool found_different = false;
    for (float candidate : {0.0F, 0.99F}) {
        if (NativeWildlifeProfileSelector::select(group, candidate) == desired) continue;
        attempt.wildlife->profile_roll = candidate; found_different = true; break;
    }
    VWB_EXPECT(found_different);
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    attempt = ordered.attempts()[ordinal]; attempt.wildlife->profile_roll = -1.0F;
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
    attempt = ordered.attempts()[ordinal]; attempt.wildlife->recipe.variant = static_cast<NativeWildlifeVariant>(99);
    VWB_EXPECT_THROW(NativeSurfaceWildlifeOrderedDefinitionRejected, check());
}

VWB_TEST(native_wildlife_construction_matches_direct_godot_seeded_oracle) {
    // N4WildlifeConstructionOracle.gd, direct make_wildlife for all variants
    // and both presentation paths. These are constructor, not live movement bits.
    struct Expected { std::uint32_t seed; NativeWildlifeBiomeGroup biome;
        NativeWildlifeVariant variant; NativeWildlifePresentationPath path;
        std::uint64_t final_state;
        std::uint32_t yaw, scale, animation_speed, timer, speed, dx, dz;
        std::uint32_t torso_radius, torso_height; const char *geometry_digest; };
    constexpr Expected rows[] = {
        {0U, NativeWildlifeBiomeGroup::forest_or_plains, NativeWildlifeVariant::deer,
            NativeWildlifePresentationPath::animated_playable, 7438143122385300322ULL,
            1061790681U, 1059062302U, 1065778934U, 1074059364U,
            1059388251U, 3212578861U, 1043522667U, 0U, 0U,
            "4cc4189f5f4cb1f9ae9f3b1e113782a9e986dc8995bf4bcac2542d807f58eb11"},
        {4294967295U, NativeWildlifeBiomeGroup::cold, NativeWildlifeVariant::hare,
            NativeWildlifePresentationPath::animated_playable, 16245301135798602091ULL,
            1073853823U, 1063750316U, 1063594876U, 1065144254U,
            1060535934U, 3196341028U, 1064783492U, 0U, 0U,
            "d3a5d00e35b5a56b52de7564a4e5da3399b2b2781ab51ef018251c37ff4ed2d1"},
        {29U, NativeWildlifeBiomeGroup::swamp, NativeWildlifeVariant::boar,
            NativeWildlifePresentationPath::animated_playable, 15334278466591811515ULL,
            1085564025U, 1060141997U, 1061479621U, 1076008560U,
            1054671916U, 3199389730U, 1064296784U, 0U, 0U,
            "d3198330a0505ca0baf13c1e151d7f24441f36590be0431ecc1ca9706b6eb992"},
        {17U, NativeWildlifeBiomeGroup::forest_or_plains, NativeWildlifeVariant::deer,
            NativeWildlifePresentationPath::procedural_fallback, 16519574479884526239ULL,
            1066790039U, 1059648963U, 0U, 1073712690U,
            1057734056U, 3211185662U, 3202187059U, 1056628682U, 1061540283U,
            "0cee1cc93ca2df1817780186f7dad6077c6d693197d7e63c5c6b9a2f187df0bb"},
        {29U, NativeWildlifeBiomeGroup::swamp, NativeWildlifeVariant::boar,
            NativeWildlifePresentationPath::procedural_fallback, 15334278466591811515ULL,
            1085564025U, 1060655596U, 0U, 1076008560U,
            1054671916U, 3199389730U, 1064296784U, 1054909099U, 1060747227U,
            "d808da18a92a2ee6a830964ba299c505d38629ef0c1ecb1a9cac1ee933df2e42"},
        {4294967295U, NativeWildlifeBiomeGroup::cold, NativeWildlifeVariant::hare,
            NativeWildlifePresentationPath::procedural_fallback, 16245301135798602091ULL,
            1073853823U, 1064011039U, 0U, 1065144254U,
            1060535934U, 3196341028U, 1064783492U, 1055339035U, 1061351585U,
            "ff107b7280a43c17ea38bb5baf029280ad6f147d278995a7e30657095fd3f1bf"},
    };
    for (const auto &row : rows) {
        GodotPcg32 rng(row.seed);
        const auto stream = NativeWildlifeStreamBuilder::create(
            row.biome, wildlife(row.path), rng);
        const auto g = decode_native_wildlife_construction(stream, {0.0F, 0.0F, 0.0F});
        VWB_EXPECT_EQ(row.variant, stream.recipe.variant);
        VWB_EXPECT_EQ(row.final_state, stream.state_after);
        VWB_EXPECT_EQ(std::string(row.geometry_digest), geometry_digest(g));
        VWB_EXPECT_EQ(row.yaw, float_bits(g.body_yaw));
        VWB_EXPECT_EQ(row.scale, float_bits(g.visual_scale.x));
        VWB_EXPECT_EQ(row.animation_speed, float_bits(g.animation_speed_scale));
        VWB_EXPECT_EQ(row.timer, float_bits(g.movement.timer));
        VWB_EXPECT_EQ(row.speed, float_bits(g.movement.speed));
        VWB_EXPECT_EQ(row.dx, float_bits(g.movement.direction.x));
        VWB_EXPECT_EQ(row.dz, float_bits(g.movement.direction.z));
        if (row.path == NativeWildlifePresentationPath::procedural_fallback) {
            VWB_EXPECT_EQ(row.torso_radius, float_bits(g.procedural_meshes[0].radius));
            VWB_EXPECT_EQ(row.torso_height, float_bits(g.procedural_meshes[0].height));
        }
    }
}
