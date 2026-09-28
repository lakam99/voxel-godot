#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_ore_cluster_definition.hpp"
#include "../core/native_surface_ore_footprint.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <sstream>
#include <utility>

using namespace voxel::world_backend;

namespace {

Sha256Digest world_digest() { Sha256Digest d{}; d[0] = 83U; return d; }

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

NativeBiomeEnvironmentCatalog catalog() {
    auto p = tests::godot_oracle_environment_profiles();
    for (auto &profile : p) profile.rock_base_chance = 1.0;
    return NativeBiomeEnvironmentCatalog::create(std::move(p));
}

NativeSurfacePropSourceOrderedStream stream(const NativeEffectiveTerrainSource &terrain,
    const NativeFeatureDeltaSnapshot &removed = NativeFeatureDeltaSnapshot::create({}, {})) {
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        0, 0, world_digest(), 1U, terrain, catalog(), exclusions(), removed, wildlife());
}

NativeSurfacePropOrderedPlacement placement(const NativeSurfacePropSourceOrderedStream &s,
    const NativeEffectiveTerrainSource &terrain) {
    return NativeSurfacePropOrderedPlacement::create(s, terrain);
}

NativeSurfacePropPlacementEntry root() {
    NativeSurfacePropPlacementEntry r;
    r.durable_id = "ore-root"; r.presence = NativeSurfacePropPlacementPresence::anchored;
    r.chunk_origin = {28.0F, 0.0F, -28.0F};
    r.local_position = {12.0F, 20.0F, 7.0F};
    return r;
}

float from_bits(std::uint32_t value) { float out; std::memcpy(&out, &value, sizeof(out)); return out; }
std::uint32_t bits(float value) { std::uint32_t out; std::memcpy(&out, &value, sizeof(out)); return out; }

std::vector<std::uint32_t> geometry_bits(const NativeSurfaceOreChildDefinition &child) {
    std::vector<std::uint32_t> out;
    const auto vec_bits = [&out](const WorldFloat32Position &v) {
        out.push_back(bits(v.x)); out.push_back(bits(v.y)); out.push_back(bits(v.z));
    };
    vec_bits(child.local_position); vec_bits(child.world_anchor);
    out.insert(out.end(), {bits(child.rotation_y), static_cast<std::uint32_t>(child.drop_count),
        bits(child.mesh_radius), bits(child.mesh_height)});
    vec_bits({0.0F, child.mesh_center_y, 0.0F}); vec_bits(child.mesh_scale);
    out.push_back(bits(child.collider_radius));
    vec_bits({0.0F, child.collider_center_y, 0.0F}); vec_bits(child.seam_mesh_size);
    for (const auto &seam : child.seams) { vec_bits(seam.local_position); vec_bits(seam.rotation); }
    out.push_back(bits(child.glint_mesh_radius)); out.push_back(bits(child.glint_mesh_height));
    for (const auto &glint : child.glints) { vec_bits(glint.local_position); vec_bits(glint.scale); }
    return out;
}

std::vector<std::uint32_t> oracle_bits(const char *csv) {
    std::vector<std::uint32_t> out;
    std::istringstream input(csv);
    std::string item;
    while (std::getline(input, item, ',')) out.push_back(static_cast<std::uint32_t>(std::stoull(item)));
    return out;
}

NativeSurfacePropPlacementEntry oracle_root(const std::string &id,
    std::uint32_t origin_x, std::uint32_t origin_z) {
    auto r = root();
    r.durable_id = id;
    r.chunk_origin = {from_bits(origin_x), 0.0F, from_bits(origin_z)};
    r.local_position = {from_bits(1108108902U), from_bits(1103259238U), from_bits(1076677837U)};
    return r;
}

} // namespace

VWB_TEST(native_surface_ore_decoder_maps_both_child_draw_sequences_and_float32_geometry) {
    GodotPcg32 rng(177U);
    const auto source = NativeOreClusterStream::create("ore-root", NativeOreKind::iron, rng);
    const auto &first = source.children()[0];
    const auto &second = source.children()[1];
    const auto a = decode_native_surface_ore_child(first, 0U, root(), NativeOreKind::iron);
    const auto b = decode_native_surface_ore_child(second, 1U, root(), NativeOreKind::iron);
    VWB_EXPECT(a.present && b.present);
    VWB_EXPECT_EQ(47U, first.float_draws.size()); VWB_EXPECT_EQ(48U, second.float_draws.size());
    VWB_EXPECT_EQ(std::string("ore-root"), a.durable_id);
    VWB_EXPECT_EQ(std::string("ore-root:cluster1"), b.durable_id);
    VWB_EXPECT_EQ(12.0F, a.local_position.x); VWB_EXPECT_EQ(7.0F, a.local_position.z);
    VWB_EXPECT_EQ(40.0F, a.world_anchor.x); VWB_EXPECT_EQ(-21.0F, a.world_anchor.z);
    VWB_EXPECT_EQ(static_cast<float>(0.58 + static_cast<double>(first.float_draws[3]) * 0.82),
        static_cast<float>(a.radius));
    VWB_EXPECT_EQ(static_cast<float>(static_cast<double>(first.float_draws[2]) * 6.28318530717958647692),
        a.rotation_y);
    VWB_EXPECT_EQ(static_cast<float>(a.radius * 1.05), a.collider_radius);
    VWB_EXPECT_EQ(static_cast<float>(a.radius * 0.42), a.collider_center_y);
    VWB_EXPECT_EQ(static_cast<float>(b.radius * 0.78), b.seam_mesh_size.x);
    VWB_EXPECT_EQ(static_cast<float>(b.radius * 0.13), static_cast<float>(b.glint_mesh_radius));
    VWB_EXPECT(b.local_position.x != root().local_position.x || b.local_position.z != root().local_position.z);
    VWB_EXPECT_EQ(first.state_before, a.state_before);
    VWB_EXPECT_EQ(first.state_after, a.state_after);
}

VWB_TEST(native_surface_ore_decoder_matches_direct_godot_engine_construction_oracle) {
    // Direct Godot service/engine capture: artifacts/native-world-backend/
    // n4-ore-construction-oracle.json, schema n4-ore-construction-oracle/v1.
    // This is construction parity, not headed gameplay or ItemCatalog admission.
    // Flattened bit fixtures cover every geometry field for both intact children:
    // local/global anchors, yaw/drop, base mesh and transform, collider,
    // five seam transforms, and three glint meshes/transforms. The two removed
    // oracle rows repeat child zero and omit child one; checked below.
    const std::array<std::array<const char *, 2>, 2> all_geometry{{
        {{
            "1108108902,1103264496,1076677837,3224161488,1103264496,1117559193,1074803109,2,1068463735,1070635308,0,1057775302,0,1070240256,1060300528,1065419150,1069038692,0,1058235267,0,1065933927,1042837946,1048357528,3202499324,1065153168,3208423644,1043662612,1085800545,1057787220,3204467946,1065246318,3209758514,1031007167,1085421811,1048792850,1053055391,1060858935,3208175272,1053866063,1083357826,1022796642,3191789720,1063625727,3208454873,1058706520,1084879324,1040041549,3180430252,1057377987,3209068373,1049531024,1057881356,1037380399,1043757877,1048357528,3203427806,1062751830,3209398636,1065353216,1065507260,1065353216,1034340058,1063996766,3209398636,1065353216,1064584417,1065353216,1031435123,1066699841,3209398636,1065353216,1062955599,1065353216",
            "1107863726,1103272630,1076744273,3228084304,1103272630,1117561270,1071716605,2,1062016440,1061027385,0,1050939744,0,1069916618,1065789741,1067741510,1062688462,0,1051477362,0,1059059543,1036312999,1041475901,1052542153,1057419550,3202833881,1046960151,1085960488,1055260542,3188591551,1054614120,3200258577,1023205188,1067081063,1051510582,1046017807,1057045897,3201831254,1052907151,1051535809,1017307119,1043107038,1058889856,3200660357,1036750531,1083125856,1059056742,1024178959,1052687123,3202200764,1057275825,1082596061,1058796839,1037388234,1041475901,3180323906,1059039143,3203261951,1065353216,1061834977,1065353216,3195496540,1056939336,3203261951,1065353216,1064086081,1065353216,3175221701,1057344964,3203261951,1065353216,1063255804,1065353216"
        }},
        {{
            "1108108902,1103272767,1076677837,3257008128,1103272767,3255592550,1075747779,1,1068600656,1069166530,0,1057884839,0,1070028336,1065553240,1066476819,1069182459,0,1058350280,0,1066040726,1042969390,1048554693,1057732024,1065817820,3208092752,1044202942,1076101708,1058171866,3205543136,1066334571,3207780821,1053357779,1083551826,1058059480,3180536434,1062846946,3210250227,1021682393,1076349460,1046097470,1044509676,1062039061,3207080681,1026116959,1080495292,1053484810,3203438496,1066194487,3209577246,1059088013,1055461633,1049170549,1043900274,1048554693,1056350056,1062609821,3209557464,1065353216,1066180934,1065353216,3204076302,1064993048,3209557464,1065353216,1060983949,1065353216,3202943147,1063679287,3209557464,1065353216,1066061648,1065353216",
            "1108312245,1103286000,1073334228,3256804785,1103286000,3255788788,1059870236,1,1068069197,1068553176,0,1057459671,0,1067816127,1064882044,1068297686,1068624427,0,1057903855,0,1065626188,1042459190,1047789393,3195921498,1065413775,3209299206,1053381054,1072016385,1016453460,1052905203,1065737567,3209561417,1055746382,1085159013,1051551995,3193142989,1057855765,3207005666,1030825678,1085389137,1056822734,3186874906,1064855894,3208343461,1055456020,1069452917,1047242485,1056479992,1060303994,3209151218,1058850340,1076470921,1048816121,1043347557,1047789393,3196480848,1063133198,3208940972,1065353216,1065039533,1065353216,3199668601,1064973027,3208940972,1065353216,1063059381,1065353216,3195295562,1063378175,3208940972,1065353216,1062264229,1065353216"
        }}
    }};
    struct Case { std::uint64_t seed; NativeOreKind kind; const char *id;
        std::uint32_t origin_x, origin_z; std::uint64_t before, after;
        std::uint32_t first_local_y, first_world_x, first_world_z;
        std::uint32_t first_radius, first_height, first_yaw, first_collider;
        std::uint32_t second_local_x, second_local_y, second_local_z;
        std::array<std::uint32_t,3> first_seam_position, first_seam_rotation;
        std::array<std::uint32_t,3> first_glint_position, first_glint_scale; };
    const std::array<Case, 2> cases{{
        {0U, NativeOreKind::iron, "世界🌲:-2,58:0", 3256300339U, 1117205299U,
            static_cast<std::uint64_t>(-8330585842245805678LL), 6842957682071426898ULL,
            1103264496U, 3224161488U, 1117559193U,
            1068463735U, 1070635308U, 1074803109U, 1069038692U,
            1107863726U, 1103272630U, 1076744273U,
            {3202499324U,1065153168U,3208423644U},
            {1043662612U,1085800545U,1057787220U},
            {3203427806U,1062751830U,3209398636U},
            {1065353216U,1065507260U,1065353216U}},
        {4294967295ULL, NativeOreKind::copper, "世界🌲:-30,-26:0", 3264688947U, 3256300339U,
            static_cast<std::uint64_t>(-9176265316429931931LL), 8243394605982837029ULL,
            1103272767U, 3257008128U, 3255592550U,
            1068600656U, 1069166530U, 1075747779U, 1069182459U,
            1108312245U, 1103286000U, 1073334228U,
            {1057732024U,1065817820U,3208092752U},
            {1044202942U,1076101708U,1058171866U},
            {1056350056U,1062609821U,3209557464U},
            {1065353216U,1066180934U,1065353216U}},
    }};
    for (std::size_t case_index = 0; case_index < cases.size(); ++case_index) {
        const auto &c = cases[case_index];
        GodotPcg32 rng(c.seed);
        VWB_EXPECT_EQ(c.before, rng.state());
        const auto stream = NativeOreClusterStream::create(c.id, c.kind, rng);
        VWB_EXPECT_EQ(c.after, stream.final_rng_state());
        const auto r = oracle_root(c.id, c.origin_x, c.origin_z);
        const auto first = decode_native_surface_ore_child(stream.children()[0], 0U, r, c.kind);
        const auto second = decode_native_surface_ore_child(stream.children()[1], 1U, r, c.kind);
        VWB_EXPECT_EQ(oracle_bits(all_geometry[case_index][0]), geometry_bits(first));
        VWB_EXPECT_EQ(oracle_bits(all_geometry[case_index][1]), geometry_bits(second));
        // make_ore explicitly sets both sphere mesh tessellations; these are
        // publication geometry, not Godot defaults left to the adapter.
        for (const auto *child : {&first, &second}) {
            VWB_EXPECT_EQ(9, child->mesh_radial_segments);
            VWB_EXPECT_EQ(5, child->mesh_rings);
            VWB_EXPECT_EQ(6, child->glint_radial_segments);
            VWB_EXPECT_EQ(3, child->glint_rings);
        }
        VWB_EXPECT_EQ(c.first_local_y, bits(first.local_position.y));
        VWB_EXPECT_EQ(c.first_world_x, bits(first.world_anchor.x));
        VWB_EXPECT_EQ(c.first_world_z, bits(first.world_anchor.z));
        VWB_EXPECT_EQ(c.first_radius, bits(first.mesh_radius));
        VWB_EXPECT_EQ(c.first_height, bits(first.mesh_height));
        VWB_EXPECT_EQ(c.first_yaw, bits(first.rotation_y));
        VWB_EXPECT_EQ(c.first_collider, bits(first.collider_radius));
        VWB_EXPECT_EQ(c.second_local_x, bits(second.local_position.x));
        VWB_EXPECT_EQ(c.second_local_y, bits(second.local_position.y));
        VWB_EXPECT_EQ(c.second_local_z, bits(second.local_position.z));
        const auto &seam = first.seams[0];
        const auto &glint = first.glints[0];
        VWB_EXPECT_EQ(c.first_seam_position[0], bits(seam.local_position.x));
        VWB_EXPECT_EQ(c.first_seam_position[1], bits(seam.local_position.y));
        VWB_EXPECT_EQ(c.first_seam_position[2], bits(seam.local_position.z));
        VWB_EXPECT_EQ(c.first_seam_rotation[0], bits(seam.rotation.x));
        VWB_EXPECT_EQ(c.first_seam_rotation[1], bits(seam.rotation.y));
        VWB_EXPECT_EQ(c.first_seam_rotation[2], bits(seam.rotation.z));
        VWB_EXPECT_EQ(c.first_glint_position[0], bits(glint.local_position.x));
        VWB_EXPECT_EQ(c.first_glint_position[1], bits(glint.local_position.y));
        VWB_EXPECT_EQ(c.first_glint_position[2], bits(glint.local_position.z));
        VWB_EXPECT_EQ(c.first_glint_scale[0], bits(glint.scale.x));
        VWB_EXPECT_EQ(c.first_glint_scale[1], bits(glint.scale.y));
        VWB_EXPECT_EQ(c.first_glint_scale[2], bits(glint.scale.z));
        GodotPcg32 removed_rng(c.seed);
        const auto removed = NativeOreClusterStream::create(c.id, c.kind,
            NativeFeatureDeltaSnapshot::create({{std::string(c.id) + ":cluster1"}}, {}), removed_rng);
        const std::uint64_t expected_removed_state = c.kind == NativeOreKind::iron
            ? 2085834082288173311ULL : 3429495335233395582ULL;
        VWB_EXPECT_EQ(expected_removed_state, removed.final_rng_state());
        const auto first_again = decode_native_surface_ore_child(removed.children()[0], 0U, r, c.kind);
        const auto missing = decode_native_surface_ore_child(removed.children()[1], 1U, r, c.kind);
        VWB_EXPECT_EQ(oracle_bits(all_geometry[case_index][0]), geometry_bits(first_again));
        VWB_EXPECT_EQ(bits(first.local_position.y), bits(first_again.local_position.y));
        VWB_EXPECT(!missing.present);
        VWB_EXPECT_EQ(0U, removed.children()[1].float_draws.size());
    }
}

VWB_TEST(native_surface_ore_decoder_rejects_invalid_child_receipts) {
    GodotPcg32 rng(177U);
    const auto source = NativeOreClusterStream::create("ore-root", NativeOreKind::iron, rng);
    auto child = source.children()[0];
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 2U, root(), NativeOreKind::iron));
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), static_cast<NativeOreKind>(99)));
    auto absent_root = root(); absent_root.presence = NativeSurfacePropPlacementPresence::absent;
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, absent_root, NativeOreKind::iron));
    child.durable_id = "other";
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child = source.children()[0]; child.float_draws.pop_back();
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child = source.children()[0]; child.drop_count = 3;
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child = source.children()[0]; child.drop_count = 0;
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child = source.children()[0]; child.float_draws[0] = -0.01F;
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child = source.children()[0]; child.float_draws[0] = std::numeric_limits<float>::infinity();
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child = source.children()[0]; child.float_draws[0] = 1.0F;
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child = source.children()[0]; child.skipped_by_tombstone = true;
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child.float_draws.clear();
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child.drop_count = 0;
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron));
    child.float_draws.clear(); child.drop_count = 0; child.state_after = child.state_before;
    const auto skipped = decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::iron);
    VWB_EXPECT(!skipped.present); VWB_EXPECT_EQ(0.0, skipped.radius);
    child = source.children()[1]; child.float_draws.pop_back();
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 1U, root(), NativeOreKind::iron));
    child = source.children()[0]; child.drop_count = 4;
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(child, 0U, root(), NativeOreKind::copper));
    auto bad_root = root(); bad_root.local_position.x = std::numeric_limits<float>::infinity();
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(source.children()[0], 0U, bad_root, NativeOreKind::iron));
    bad_root = root(); bad_root.local_position.y = std::numeric_limits<float>::infinity();
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(source.children()[0], 0U, bad_root, NativeOreKind::iron));
    bad_root = root(); bad_root.local_position.z = std::numeric_limits<float>::infinity();
    VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
        decode_native_surface_ore_child(source.children()[0], 0U, bad_root, NativeOreKind::iron));
}

VWB_TEST(native_surface_ore_composer_rejects_missing_optional_receipts) {
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ore-optional-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto ordered = stream(terrain);
        for (const auto &source_attempt : ordered.attempts()) {
            if (!source_attempt.ore_cluster) continue;
            auto attempt = source_attempt;
            validate_native_surface_ore_attempt_receipts(attempt);
            attempt.ore_cluster.reset();
            VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
                validate_native_surface_ore_attempt_receipts(attempt));
            attempt = source_attempt; attempt.prop_roll.reset();
            VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
                validate_native_surface_ore_attempt_receipts(attempt));
            attempt = source_attempt; attempt.ore_roll.reset();
            VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
                validate_native_surface_ore_attempt_receipts(attempt));
            found = true;
            break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_surface_ore_cluster_composes_source_bound_children_and_child_tombstone) {
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ore-definition-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto intact = stream(terrain);
        for (std::uint32_t ordinal = 0U; ordinal + 1U < intact.attempts().size(); ++ordinal) {
            if (!intact.attempts()[ordinal].ore_cluster) continue;
            const auto intact_set = placement(intact, terrain);
            const auto composed = NativeSurfaceOreClusterDefinition::create(
                intact, intact_set, ordinal, terrain);
            const auto repeat = NativeSurfaceOreClusterDefinition::create(
                intact, intact_set, ordinal, terrain);
            VWB_EXPECT_EQ(ordinal, composed.ordinal());
            VWB_EXPECT_EQ(intact.attempts()[ordinal].attempt.durable_id, composed.root_durable_id());
            VWB_EXPECT_EQ(sha256(composed.canonical_binary()), composed.content_digest());
            VWB_EXPECT_EQ(composed.content_digest(), repeat.content_digest());
            VWB_EXPECT(composed.children()[0].present && composed.children()[1].present);
            const auto child_id = composed.root_durable_id() + ":cluster1";
            const auto removed = stream(terrain, NativeFeatureDeltaSnapshot::create({{child_id}}, {}));
            const auto removed_def = NativeSurfaceOreClusterDefinition::create(
                removed, placement(removed, terrain), ordinal, terrain);
            VWB_EXPECT(removed_def.children()[0].present);
            VWB_EXPECT(!removed_def.children()[1].present);
            VWB_EXPECT_EQ(0.0, removed_def.children()[1].radius);
            VWB_EXPECT(composed.content_digest() != removed_def.content_digest());
            VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
                NativeSurfaceOreClusterDefinition::create(intact, placement(removed, terrain), ordinal, terrain));
            const auto stale_definition = surface_prop_test_fixture::definition("ore-definition-stale");
            const NativeEffectiveTerrainSource stale(surface_prop_test_fixture::ready_pin(
                stale_definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
            VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
                NativeSurfaceOreClusterDefinition::create(intact, intact_set, ordinal, stale));
            found = true;
            break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_surface_ore_cluster_composer_covers_iron_and_rejects_nonore_ordinal) {
    bool found_iron = false;
    bool rejected_nonore = false;
    for (std::uint32_t candidate = 0U; candidate < 128U && (!found_iron || !rejected_nonore); ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("ore-kind-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto ordered = stream(terrain);
        const auto set = placement(ordered, terrain);
        if (!rejected_nonore) {
            VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
                NativeSurfaceOreClusterDefinition::create(ordered, set, 28U, terrain));
            for (std::uint32_t i = 0U; i < ordered.attempts().size(); ++i) {
                if (ordered.attempts()[i].ore_cluster) continue;
                VWB_EXPECT_THROW(NativeSurfaceOreClusterDefinitionRejected,
                    NativeSurfaceOreClusterDefinition::create(ordered, set, i, terrain));
                rejected_nonore = true;
                break;
            }
        }
        for (std::uint32_t i = 0U; i < ordered.attempts().size(); ++i) {
            if (ordered.attempts()[i].outcome != NativeSurfacePropClassificationOutcome::unported_iron_ore_cluster)
                continue;
            const auto composed = NativeSurfaceOreClusterDefinition::create(ordered, set, i, terrain);
            VWB_EXPECT_EQ(NativeOreKind::iron, composed.kind());
            found_iron = true;
            break;
        }
    }
    VWB_EXPECT(found_iron && rejected_nonore);
}

VWB_TEST(native_surface_ore_footprints_cover_visual_and_physical_children) {
    bool found = false;
    for (std::uint32_t candidate = 0U; candidate < 32U && !found; ++candidate) {
        const auto definition = surface_prop_test_fixture::definition("feature-ore-" + std::to_string(candidate));
        const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
            definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
        const auto intact = stream(terrain);
        const auto set = placement(intact, terrain);
        for (std::uint32_t i = 0U; i < intact.attempts().size(); ++i) {
            if (!intact.attempts()[i].ore_cluster) continue;
            const auto ore = NativeSurfaceOreClusterDefinition::create(intact, set, i, terrain);
            const auto footprints = compose_native_surface_ore_footprints(intact, set, i, terrain);
            const auto repeated = compose_native_surface_ore_footprints(intact, set, i, terrain);
            VWB_EXPECT_EQ(footprints.content_digest(), repeated.content_digest());
            VWB_EXPECT_EQ(2U, footprints.entries().size());
            VWB_EXPECT_EQ(terrain.pin().physical_content_identity().digest, footprints.source_digest());
            const double cell_size = terrain.pin().definition().constants().cell_size_meters;
            const auto covered = [&](const NativeGeneratedFeatureFootprintEntry &entry,
                NativeFeatureFootprintChannel channel, double x, double y, double z) {
                const auto cx = static_cast<std::int32_t>(std::floor(x / cell_size));
                const auto cy = static_cast<std::int32_t>(std::floor(y / cell_size));
                const auto cz = static_cast<std::int32_t>(std::floor(z / cell_size));
                for (const auto &run : entry.runs)
                    if (run.channel == channel && run.first.y == cy && run.first.z == cz
                        && run.first.x <= cx && cx <= run.last_x_inclusive) return true;
                return false;
            };
            for (const auto &child : ore.children()) {
                const auto *entry = footprints.find(child.durable_id);
                VWB_EXPECT(entry != nullptr);
                VWB_EXPECT_EQ(NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS, entry->declared_channel_mask);
                VWB_EXPECT_EQ(ore.content_digest(), entry->generated_definition_digest);
                VWB_EXPECT(covered(*entry, NativeFeatureFootprintChannel::collision,
                    child.world_anchor.x + child.collider_radius,
                    child.world_anchor.y + child.collider_center_y, child.world_anchor.z));
                VWB_EXPECT(covered(*entry, NativeFeatureFootprintChannel::navigation,
                    child.world_anchor.x, child.world_anchor.y + child.collider_center_y,
                    child.world_anchor.z + child.collider_radius));
                VWB_EXPECT(covered(*entry, NativeFeatureFootprintChannel::render,
                    child.world_anchor.x + child.mesh_radius * child.mesh_scale.x,
                    child.world_anchor.y + child.mesh_center_y, child.world_anchor.z));
                const double c = std::cos(child.rotation_y), s = std::sin(child.rotation_y);
                const double seam_radius = 0.5 * std::sqrt(
                    child.seam_mesh_size.x * child.seam_mesh_size.x
                    + child.seam_mesh_size.y * child.seam_mesh_size.y
                    + child.seam_mesh_size.z * child.seam_mesh_size.z);
                for (const auto &seam : child.seams) {
                    const double x = child.world_anchor.x + c * seam.local_position.x - s * seam.local_position.z;
                    const double z = child.world_anchor.z + s * seam.local_position.x + c * seam.local_position.z;
                    VWB_EXPECT(covered(*entry, NativeFeatureFootprintChannel::render,
                        x - seam_radius, child.world_anchor.y + seam.local_position.y + seam_radius, z));
                    VWB_EXPECT(covered(*entry, NativeFeatureFootprintChannel::render,
                        x + seam_radius, child.world_anchor.y + seam.local_position.y - seam_radius, z));
                }
                for (const auto &glint : child.glints) {
                    const double x = child.world_anchor.x + c * glint.local_position.x - s * glint.local_position.z;
                    const double z = child.world_anchor.z + s * glint.local_position.x + c * glint.local_position.z;
                    const double radius = std::max(static_cast<double>(child.glint_mesh_radius)
                        * std::max(glint.scale.x, glint.scale.z),
                        static_cast<double>(child.glint_mesh_height) * glint.scale.y * 0.5);
                    VWB_EXPECT(covered(*entry, NativeFeatureFootprintChannel::render,
                        x - radius, child.world_anchor.y + glint.local_position.y, z - radius));
                    VWB_EXPECT(covered(*entry, NativeFeatureFootprintChannel::render,
                        x + radius, child.world_anchor.y + glint.local_position.y, z + radius));
                }
                for (const auto &run : entry->runs)
                    VWB_EXPECT(run.channel != NativeFeatureFootprintChannel::terrain_source);
            }
            const auto child_id = ore.children()[1].durable_id;
            const auto filtered = stream(terrain, NativeFeatureDeltaSnapshot::create({{child_id}}, {}));
            const auto filtered_set = placement(filtered, terrain);
            const auto after = compose_native_surface_ore_footprints(filtered, filtered_set, i, terrain);
            VWB_EXPECT_EQ(1U, after.entries().size());
            VWB_EXPECT(after.find(child_id) == nullptr);
            VWB_EXPECT(after.find(ore.children()[0].durable_id) != nullptr);
            VWB_EXPECT(footprints.content_digest() != after.content_digest());
            found = true; break;
        }
    }
    VWB_EXPECT(found);
}

VWB_TEST(native_surface_ore_footprint_contains_direct_godot_transformed_world_aabbs) {
    // N4OreConstructionOracle.gd v2, eight direct-engine cases. Each render
    // box is the union of the actual transformed AABBs of one stone, five
    // seams and three glints; the physical box is the sphere collider AABB.
    // These are independent Godot cell bounds, not bounds recomputed from the
    // native recipe under test. The production composer binds the same runs
    // to its ordered source/placement/terrain pin.
    struct CellBox { int x0,y0,z0,x1,y1,z1; };
    struct OracleCase {
        const char *id; NativeOreKind kind; std::uint64_t seed;
        std::uint32_t origin_x, origin_z;
        std::array<CellBox,2> render, physical;
        std::uint64_t intact_state, removed_state;
    };
    const std::array<OracleCase,4> cases{{
        {"世界🌲:-2,58:0", NativeOreKind::iron, 0U, 3256300339U, 1117205299U,
            {{{-4,17,56,-1,19,59},{-4,17,56,-2,18,59}}},
            {{{-4,17,56,-1,19,59},{-4,17,57,-3,18,58}}},
            6842957682071426898ULL, 2085834082288173311ULL},
        {"世界🌲:-30,-26:0", NativeOreKind::copper, 4294967295ULL, 3264688947U, 3256300339U,
            {{{-32,17,-28,-29,19,-25},{-32,17,-29,-28,19,-25}}},
            {{{-32,17,-28,-29,19,-25},{-31,17,-28,-29,19,-26}}},
            8243394605982837029ULL, 3429495335233395582ULL},
        {"世界🌲:54,58:0", NativeOreKind::iron, 177U, 1108816691U, 1117205299U,
            {{{52,18,56,55,19,59},{53,18,57,55,18,59}}},
            {{{53,17,57,54,19,58},{53,17,57,54,18,59}}},
            static_cast<std::uint64_t>(-4845579065015597969LL),
            static_cast<std::uint64_t>(-6120500400008941776LL)},
        {"世界🌲:82,30:0", NativeOreKind::copper, 4294967295ULL, 1117205299U, 1108816691U,
            {{{80,17,28,83,19,31},{80,17,27,84,19,31}}},
            {{{80,17,28,83,19,31},{81,17,28,83,19,30}}},
            8243394605982837029ULL, 3429495335233395582ULL},
    }};
    const auto covered = [](const std::vector<NativeFeatureFootprintRun> &runs,
            NativeFeatureFootprintChannel channel, int x, int y, int z) {
        return std::any_of(runs.begin(), runs.end(), [&](const auto &run) {
            return run.channel == channel && run.first.y == y && run.first.z == z
                && run.first.x <= x && x <= run.last_x_inclusive;
        });
    };
    const auto covers_box = [&](const std::vector<NativeFeatureFootprintRun> &runs,
            NativeFeatureFootprintChannel channel, const CellBox &box) {
        for (int z = box.z0; z <= box.z1; ++z)
            for (int y = box.y0; y <= box.y1; ++y)
                for (int x = box.x0; x <= box.x1; ++x)
                    VWB_EXPECT(covered(runs, channel, x, y, z));
    };
    for (const auto &oracle : cases) {
        const auto root = oracle_root(oracle.id, oracle.origin_x, oracle.origin_z);
        for (const bool remove_second : {false, true}) {
            GodotPcg32 rng(oracle.seed);
            const auto removed = NativeFeatureDeltaSnapshot::create(
                remove_second ? std::vector<NativeFeatureTombstone>{{std::string(oracle.id)+":cluster1"}}
                    : std::vector<NativeFeatureTombstone>{}, {});
            const auto source = NativeOreClusterStream::create(oracle.id, oracle.kind, removed, rng);
            VWB_EXPECT_EQ(remove_second ? oracle.removed_state : oracle.intact_state,
                source.final_rng_state());
            for (std::uint32_t index = 0; index < 2U; ++index) {
                const auto child = decode_native_surface_ore_child(source.children()[index],
                    index, root, oracle.kind);
                const auto runs = native_surface_ore_child_footprint_runs(child, 1.35);
                if (index == 1U && remove_second) {
                    VWB_EXPECT(!child.present && runs.empty());
                    continue;
                }
                VWB_EXPECT(child.present && !runs.empty());
                covers_box(runs, NativeFeatureFootprintChannel::render, oracle.render[index]);
                covers_box(runs, NativeFeatureFootprintChannel::collision, oracle.physical[index]);
                covers_box(runs, NativeFeatureFootprintChannel::navigation, oracle.physical[index]);
                VWB_EXPECT(std::none_of(runs.begin(), runs.end(), [](const auto &run) {
                    return run.channel == NativeFeatureFootprintChannel::terrain_source;
                }));
            }
        }
    }
}

VWB_TEST(native_surface_ore_world_bounds_quantize_negative_and_reject_unbounded) {
    const auto channel = NativeFeatureFootprintChannel::collision;
    const auto runs = native_feature_runs_for_bounds(
        {-2.2, -0.4, -1.9, 0.1, 1.2, 0.2}, 1.0, channel);
    VWB_EXPECT_EQ(9U, runs.size());
    VWB_EXPECT_EQ(-3, runs.front().first.x);
    VWB_EXPECT_EQ(0, runs.front().last_x_inclusive);
    VWB_EXPECT_EQ(-2, runs.front().first.z);
    VWB_EXPECT_EQ(-1, runs.front().first.y);
    VWB_EXPECT_EQ(0, runs.back().first.z);
    VWB_EXPECT_EQ(1, runs.back().first.y);
    const auto source_run = native_feature_runs_for_bounds({0,0,0,0,0,0}, 1.0,
        NativeFeatureFootprintChannel::terrain_source);
    VWB_EXPECT_EQ(NativeFeatureFootprintChannel::terrain_source, source_run.front().channel);
    NativeFeatureWorldBounds expanded{0,0,0,0,0,0};
    native_feature_bounds_include_sphere(expanded, -1.0, 2.0, 3.0, 0.5);
    VWB_EXPECT_EQ(-1.5, expanded.min_x);
    VWB_EXPECT_EQ(2.5, expanded.max_y);
    native_feature_bounds_enclose_body_yaw(expanded, 0.0, 0.0);
    VWB_EXPECT(expanded.min_z < -3.0 && expanded.max_z > 3.0);
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double inf = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_bounds_include_sphere(expanded, nan, 0, 0, 1));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_bounds_include_sphere(expanded, 0, nan, 0, 1));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_bounds_include_sphere(expanded, 0, 0, nan, 1));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_bounds_include_sphere(expanded, 0, 0, 0, inf));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_bounds_include_sphere(expanded, 0, 0, 0, -1));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_bounds_enclose_body_yaw(expanded, inf, 0));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_bounds_enclose_body_yaw(expanded, 0, inf));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({0,0,0,1,1,1}, 1.0,
            static_cast<NativeFeatureFootprintChannel>(99)));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({0,0,0,1,1,1}, 0.0, channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({0,0,0,1,1,1}, std::numeric_limits<double>::infinity(), channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({1,0,0,0,1,1}, 1.0, channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({0,1,0,1,0,1}, 1.0, channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({0,0,1,1,1,0}, 1.0, channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({-1.0e20,0,0,1,1,1}, 1.0, channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({0,0,0,1.0e20,1,1}, 1.0, channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({std::numeric_limits<double>::quiet_NaN(),0,0,1,1,1},
            1.0, channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({0,0,0,1,4096,1}, 1.0, channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({0,0,0,1,1,4096}, 1.0, channel));
    VWB_EXPECT_THROW(NativeFeatureFootprintGeometryRejected,
        native_feature_runs_for_bounds({0,0,0,1,64,64}, 1.0, channel));
}
