#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_rock_ordered_visual_plan.hpp"
#include "../core/native_surface_rock_footprint.hpp"

#include <cmath>
#include <limits>
#include <utility>

using namespace voxel::world_backend;

namespace {

Sha256Digest world_digest() { Sha256Digest d{}; d[0] = 47U; return d; }

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

std::vector<NativeBiomeEnvironmentProfile> profiles(bool empty_rock = false, double scale = 1.0) {
    auto result = tests::godot_oracle_environment_profiles();
    for (auto &profile : result) {
        profile.rock_base_chance = 1.0;
        if (empty_rock) profile.rock_families = {"missing"};
        profile.rock_scale = scale;
    }
    return result;
}

NativeSurfacePropSourceOrderedStream stream(const NativeEffectiveTerrainSource &terrain,
    const std::vector<NativeBiomeEnvironmentProfile> &source_profiles) {
    return NativeSurfacePropSourceOrderedStream::create(terrain.pin().definition().raw_terrain_seed(),
        0, 0, world_digest(), 1U, terrain,
        NativeBiomeEnvironmentCatalog::create(source_profiles), exclusions(),
        NativeFeatureDeltaSnapshot::create({}, {}), wildlife());
}

NativeSurfaceRockAssetRecord asset(const std::string &id, const std::string &path) {
    NativeSurfaceRockAssetRecord r;
    r.id = id; r.family = "rock"; r.path = path;
    r.size_x = 1.5; r.size_y = 0.9; r.size_z = 0.6;
    return r;
}

NativeSurfaceRockAssetCatalog catalog(const std::vector<NativeBiomeEnvironmentProfile> &p,
    const std::string &path = "res://rock_01.glb") {
    return NativeSurfaceRockAssetCatalog::create({asset("rock_01", path)},
        NativeBiomeEnvironmentCatalog::create(p));
}

std::uint32_t rock_ordinal(const NativeSurfacePropSourceOrderedStream &s) {
    for (std::uint32_t i = 0U; i < s.attempts().size(); ++i)
        if (s.attempts()[i].outcome == NativeSurfacePropClassificationOutcome::ordinary_rock) return i;
    throw std::runtime_error("no ordinary rock in focused test seed");
}

} // namespace

VWB_TEST(native_ordered_rock_visual_plan_binds_catalog_selection_without_changing_geometry) {
    const auto definition = surface_prop_test_fixture::definition("ordered-rock-visual-plan");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto p = profiles();
    const auto ordered = stream(terrain, p);
    const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    const auto ordinal = rock_ordinal(ordered);
    const auto assets = catalog(p);
    const auto plan = NativeSurfaceRockOrderedVisualPlan::create(ordered, placements, ordinal, terrain, assets);
    const auto repeat = NativeSurfaceRockOrderedVisualPlan::create(ordered, placements, ordinal, terrain, assets);
    VWB_EXPECT_EQ(NativeSurfaceRockVisualIntent::selected_asset, plan.intent());
    VWB_EXPECT_EQ(std::string("rock_01"), plan.selection().asset_id);
    VWB_EXPECT_EQ(std::string("res://rock_01.glb"), plan.selection().asset_path);
    VWB_EXPECT_EQ(1.5F, plan.selection().asset_size.x);
    VWB_EXPECT_EQ(0.9F, plan.selection().asset_size.y);
    VWB_EXPECT_EQ(0.6F, plan.selection().asset_size.z);
    VWB_EXPECT_EQ(1.0, plan.selection().rock_scale);
    VWB_EXPECT_EQ(assets.content_digest(), plan.selection().asset_catalog_digest);
    VWB_EXPECT_EQ(ordered.source_receipt().environment_profile_digest,
        plan.selection().environment_catalog_digest);
    VWB_EXPECT_EQ(plan.definition().content_digest(), repeat.definition().content_digest());
    const auto &draw = ordered.attempts()[ordinal].compatibility_draws;
    VWB_EXPECT_EQ(6U, draw.size());
    VWB_EXPECT_EQ(0.55 + static_cast<double>(draw[1]) * 0.7,
        plan.definition().input().visual_radius);
    VWB_EXPECT_EQ(placements.entries()[ordinal].world_anchor.y,
        plan.definition().input().position.y);
    auto changed = catalog(p, "res://rock_01-revised.glb");
    const auto revised = NativeSurfaceRockOrderedVisualPlan::create(
        ordered, placements, ordinal, terrain, changed);
    VWB_EXPECT_EQ(plan.definition().input().visual_radius, revised.definition().input().visual_radius);
    VWB_EXPECT(plan.definition().content_digest() != revised.definition().content_digest());
}

VWB_TEST(native_ordered_rock_visual_plan_accepts_empty_selection_as_primitive_intent) {
    const auto definition = surface_prop_test_fixture::definition("ordered-rock-visual-empty");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto p = profiles(true);
    const auto ordered = stream(terrain, p);
    const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    const auto ordinal = rock_ordinal(ordered);
    const auto assets = catalog(p);
    const auto plan = NativeSurfaceRockOrderedVisualPlan::create(ordered, placements, ordinal, terrain, assets);
    VWB_EXPECT_EQ(NativeSurfaceRockVisualIntent::primitive_required, plan.intent());
    VWB_EXPECT(plan.selection().asset_id.empty());
    VWB_EXPECT(plan.selection().asset_path.empty());
    VWB_EXPECT_EQ(0U, plan.selection().candidate_count);
    VWB_EXPECT_EQ(placements.entries()[ordinal].durable_id, plan.definition().input().durable_feature_id);
}

VWB_TEST(native_ordered_rock_visual_plan_rejects_environment_catalog_mismatch) {
    const auto definition = surface_prop_test_fixture::definition("ordered-rock-visual-mismatch");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto p = profiles();
    const auto ordered = stream(terrain, p);
    const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    const auto ordinal = rock_ordinal(ordered);
    const auto mismatched = catalog(profiles(false, 1.2));
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedVisualPlanRejected,
        NativeSurfaceRockOrderedVisualPlan::create(ordered, placements, ordinal, terrain, mismatched));
    const auto matching = catalog(p);
    VWB_EXPECT_THROW(NativeSurfaceRockOrderedVisualPlanRejected,
        NativeSurfaceRockOrderedVisualPlan::create(ordered, placements, 28U, terrain, matching));
    const auto changed_profiles = profiles(false, 1.2);
    const auto changed_stream = stream(terrain, changed_profiles);
    const auto changed_placements = NativeSurfacePropOrderedPlacement::create(changed_stream, terrain);
    const auto changed_plan = NativeSurfaceRockOrderedVisualPlan::create(changed_stream,
        changed_placements, rock_ordinal(changed_stream), terrain, mismatched);
    const auto original = NativeSurfaceRockOrderedVisualPlan::create(ordered, placements, ordinal, terrain, matching);
    VWB_EXPECT(original.definition().content_digest() != changed_plan.definition().content_digest());
}

VWB_TEST(native_ordered_rock_footprint_binds_imported_bounds_or_primitive_outcome) {
    const auto definition = surface_prop_test_fixture::definition("rock-footprint");
    const NativeEffectiveTerrainSource terrain(surface_prop_test_fixture::ready_pin(
        definition, {0,0}, surface_prop_test_fixture::empty_deltas()));
    const auto p = profiles();
    const auto ordered = stream(terrain, p);
    const auto placements = NativeSurfacePropOrderedPlacement::create(ordered, terrain);
    const auto ordinal = rock_ordinal(ordered);
    const auto assets = catalog(p);
    const auto plan = NativeSurfaceRockOrderedVisualPlan::create(ordered, placements, ordinal, terrain, assets);
    NativeSurfaceRockImportedBoundsReceipt receipt;
    receipt.asset_catalog_digest = assets.content_digest();
    receipt.glb_digest.fill(1U);
    receipt.asset_id = plan.selection().asset_id;
    receipt.asset_path = plan.selection().asset_path;
    receipt.imported_mesh_bounds = {-0.6786725521087646,0,-0.4762398600578308,
        0.7803832292556763,0.5639727115631104,0.44836854934692383};
    const auto imported = compose_native_surface_rock_footprint(ordered, placements, ordinal,
        terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &receipt);
    const auto repeated = compose_native_surface_rock_footprint(ordered, placements, ordinal,
        terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &receipt);
    VWB_EXPECT_EQ(imported.content_digest(), repeated.content_digest());
    VWB_EXPECT_EQ(terrain.pin().physical_content_identity().digest, imported.source_digest());
    VWB_EXPECT_EQ(1U, imported.entries().size());
    const auto &entry = imported.entries().front();
    VWB_EXPECT_EQ(plan.definition().input().durable_feature_id, entry.feature_id);
    VWB_EXPECT_EQ(NATIVE_FEATURE_FOOTPRINT_ALL_CHANNELS, entry.declared_channel_mask);
    const auto fallback = compose_native_surface_rock_footprint(ordered, placements, ordinal,
        terrain, assets, NativeSurfaceRockPublishedVisual::primitive_fallback, nullptr);
    VWB_EXPECT(imported.content_digest() != fallback.content_digest());
    for (const auto channel : {NativeFeatureFootprintChannel::render,
            NativeFeatureFootprintChannel::collision, NativeFeatureFootprintChannel::navigation}) {
        VWB_EXPECT(std::any_of(entry.runs.begin(), entry.runs.end(), [&](const auto &run) {
            return run.channel == channel;
        }));
    }
    for (const auto &run : entry.runs)
        VWB_EXPECT(run.channel != NativeFeatureFootprintChannel::terrain_source);
    const auto &anchor = plan.definition().input().position;
    const double size = terrain.pin().definition().constants().cell_size_meters;
    const auto covered = [&](NativeFeatureFootprintChannel channel, double x, double y, double z) {
        const int cx = static_cast<int>(std::floor(x/size));
        const int cy = static_cast<int>(std::floor(y/size));
        const int cz = static_cast<int>(std::floor(z/size));
        return std::any_of(entry.runs.begin(), entry.runs.end(), [&](const auto &run) {
            return run.channel == channel && run.first.x <= cx && cx <= run.last_x_inclusive
                && run.first.y == cy && run.first.z == cz;
        });
    };
    VWB_EXPECT(covered(NativeFeatureFootprintChannel::render,
        anchor.x + receipt.imported_mesh_bounds.min_x, anchor.y, anchor.z));
    VWB_EXPECT(covered(NativeFeatureFootprintChannel::collision,
        anchor.x, anchor.y + plan.definition().input().collision.center_y, anchor.z));
    auto bad = receipt;
    bad.asset_catalog_digest[0] ^= 1U;
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &bad));
    bad = receipt; bad.asset_id = "wrong";
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &bad));
    bad = receipt; bad.asset_path = "wrong";
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &bad));
    bad = receipt; bad.glb_digest.fill(0U);
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &bad));
    bad = receipt; bad.imported_mesh_bounds.min_x = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &bad));
    bad = receipt; bad.imported_mesh_bounds.max_z = -100.0;
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &bad));
    for (int component = 1; component < 6; ++component) {
        bad = receipt;
        double *values[] = {&bad.imported_mesh_bounds.min_x, &bad.imported_mesh_bounds.min_y,
            &bad.imported_mesh_bounds.min_z, &bad.imported_mesh_bounds.max_x,
            &bad.imported_mesh_bounds.max_y, &bad.imported_mesh_bounds.max_z};
        *values[component] = std::numeric_limits<double>::quiet_NaN();
        VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
            ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &bad));
    }
    for (int axis = 0; axis < 3; ++axis) {
        bad = receipt;
        double *minimum[] = {&bad.imported_mesh_bounds.min_x,
            &bad.imported_mesh_bounds.min_y, &bad.imported_mesh_bounds.min_z};
        double *maximum[] = {&bad.imported_mesh_bounds.max_x,
            &bad.imported_mesh_bounds.max_y, &bad.imported_mesh_bounds.max_z};
        *minimum[axis] = *maximum[axis] + 1.0;
        VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
            ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &bad));
    }
    bad = receipt; bad.imported_mesh_bounds.max_x = std::numeric_limits<double>::max();
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, &bad));
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::selected_import, nullptr));
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, NativeSurfaceRockPublishedVisual::primitive_fallback, &receipt));
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, ordinal, terrain, assets, static_cast<NativeSurfaceRockPublishedVisual>(99), nullptr));
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        ordered, placements, 28U, terrain, assets, NativeSurfaceRockPublishedVisual::primitive_fallback, nullptr));
    const auto empty_p = profiles(true);
    const auto empty_ordered = stream(terrain, empty_p);
    const auto empty_placements = NativeSurfacePropOrderedPlacement::create(empty_ordered, terrain);
    const auto empty_assets = catalog(empty_p);
    VWB_EXPECT_THROW(NativeSurfaceRockFootprintRejected, compose_native_surface_rock_footprint(
        empty_ordered, empty_placements, rock_ordinal(empty_ordered), terrain, empty_assets,
        NativeSurfaceRockPublishedVisual::selected_import, &receipt));
}

VWB_TEST(native_rock_projection_contains_all_direct_godot_scaled_mesh_aabbs) {
    // Direct renderer-capable constructor report SHA-256:
    // 00ac791f5035e844c9f1d5b3972543d556592de1aabee3de7aca4c4faa92b469.
    // Exact GLB POSITION bounds and hashes are from the independently scanned
    // six-asset receipt; import AABBs differ by <= one float32 ULP.
    struct Case {
        const char *id, *glb_sha;
        WorldFloat32Position anchor, visual_scale, asset_size;
        double yaw, radius, height_factor;
        NativeFeatureWorldBounds local;
        int x0,y0,z0,x1,y1,z1;
        bool fallback = false;
    };
    const Case cases[] = {
        {"rock_01","41085923f2d906b6335c811cb9e61576f45d1f091f873329fd330cadd15ff25d",
            {-72.9000015F,18.25F,-39.1500015F},{1.1514741F,0.8121346F,1.2339232F},
            {1.4591000F,0.9246000F,0.5640000F},0.0769559294,0.9582701921,1.0633807182,
            {-0.6786725521,0,-0.4762398601,0.7803832293,0.5639727116,0.4483685493},
            -55,13,-30,-54,14,-29},
        {"rock_02","596a5395284d2ae943986bcaa42209c79c1307b862c658ed63dda5013f82ab86",
            {-69.9000015F,18.25F,-35.1500015F},{1.7231119F,0.6555005F,1.3312012F},
            {1.2609000F,0.9295000F,1.0197999F},5.7142505646,0.7103191316,1.3604887962,
            {-0.6260432005,0,-0.5116717815,0.6348230839,1.0197832584,0.4178310335},
            -53,13,-28,-51,13,-26},
        {"rock_03","9d2e9d4d4a02772dfe386bda7fc23ab1e2283d6d72459ea2f67684a955aa2ef7",
            {-66.9000015F,18.25F,-31.1499996F},{1.7193065F,1.0377206F,1.4621220F},
            {1.6291000F,1.2517000F,0.8299000F},0.8493823409,1.0178905070,0.9778621435,
            {-0.7500827312,0,-0.6174744964,0.8790338039,0.8298857212,0.6342648864},
            -52,13,-25,-48,14,-22},
        {"rock_04","2a76fd45d3d3350c74327a7168ca27512b52c91d3fb0ac758c2b7cb28e397d51",
            {-63.9000015F,18.25F,-27.1499996F},{1.1681403F,0.7056683F,1.2794926F},
            {1.3483000F,1.4157000F,1.2823000F},5.6287336349,1.0743480325,1.4279734135,
            {-0.6730222106,0,-0.7087781429,0.6753228307,1.2823452950,0.7069584727},
            -49,13,-22,-47,14,-19},
        {"rock_05","deddad96918460356e1fa7b8ce120c76416df36e41a61ad2d864df79cca4d423",
            {-60.9000015F,18.25F,-23.1499996F},{1.3215606F,0.7081074F,1.3937008F},
            {2.0574000F,1.8181000F,1.2822000F},0.4076363742,0.8436694384,0.7832649678,
            {-1.0706269741,0,-0.8674660325,0.9867365956,1.2821774483,0.9506295919},
            -47,13,-19,-45,13,-17},
        {"rock_06","4bdbc37fa0607c816c86cfb3c705a32418463c356f7d1175e717d57341ae75b6",
            {-57.9000015F,18.25F,-19.1499996F},{1.5090028F,1.2947881F,1.1540726F},
            {2.8466001F,1.5017999F,1.0785000F},4.6682615280,1.0231833100,1.0549989939,
            {-1.3803905249,0,-0.8011751771,1.4661654234,1.0785475969,0.7006177306},
            -44,13,-16,-42,14,-14},
        {"rock_01","41085923f2d906b6335c811cb9e61576f45d1f091f873329fd330cadd15ff25d",
            {-54.9000015F,18.25F,-15.1499996F},{1.2579091F,1.1384482F,1.0263134F},
            {1.4591000F,0.9246000F,0.5640000F},2.8894546032,0.7558292687,1.1320907116,
            {-0.6786725521,0,-0.4762398601,0.7803832293,0.5639727116,0.4483685493},
            -42,13,-12,-40,14,-11,true},
    };
    for (const auto &case_ : cases) {
        NativeSurfaceRockDefinitionInput input;
        input.position = case_.anchor; input.rotation_y = case_.yaw;
        input.visual_radius = case_.radius; input.visual_height_factor = case_.height_factor;
        input.visual_scale_x = case_.visual_scale.x; input.visual_scale_y = case_.visual_scale.y;
        input.visual_scale_z = case_.visual_scale.z;
        input.collision = {static_cast<float>(case_.radius*1.05),
            static_cast<float>(case_.radius*0.42)};
        NativeSurfaceRockAssetSelection selected;
        selected.asset_catalog_digest.fill(5U); selected.asset_id = case_.id;
        selected.asset_path = std::string("res://assets/visual/generated/environment/") + case_.id + ".glb";
        selected.asset_size = case_.asset_size; selected.rock_scale = 0.94;
        NativeSurfaceRockImportedBoundsReceipt receipt;
        receipt.asset_catalog_digest = selected.asset_catalog_digest;
        receipt.asset_id = selected.asset_id; receipt.asset_path = selected.asset_path;
        receipt.imported_mesh_bounds = case_.local;
        for (std::size_t i=0; i<receipt.glb_digest.size(); ++i) {
            const auto digit = [](const char c) { return c <= '9' ? c-'0' : c-'a'+10; };
            receipt.glb_digest[i] = static_cast<std::uint8_t>(
                digit(case_.glb_sha[i*2])*16 + digit(case_.glb_sha[i*2+1]));
        }
        VWB_EXPECT_EQ(std::string(case_.glb_sha), sha256_hex(receipt.glb_digest));
        const auto outcome = case_.fallback ? NativeSurfaceRockPublishedVisual::primitive_fallback
            : NativeSurfaceRockPublishedVisual::selected_import;
        const auto runs = native_surface_rock_geometry_runs(input, selected, outcome,
            case_.fallback ? nullptr : &receipt, 1.35);
        for (int z=case_.z0; z<=case_.z1; ++z)
            for (int y=case_.y0; y<=case_.y1; ++y)
                for (int x=case_.x0; x<=case_.x1; ++x) {
                    const bool covered = std::any_of(runs.begin(), runs.end(), [&](const auto &run) {
                        return run.channel == NativeFeatureFootprintChannel::render
                            && run.first.z == z && run.first.y == y
                            && run.first.x <= x && x <= run.last_x_inclusive;
                    });
                    if (!covered) tests::fail("Godot rock runtime AABB cell outside native render footprint",
                        __FILE__, __LINE__, std::string(case_.id) + " cell=" + std::to_string(x)
                            + "," + std::to_string(y) + "," + std::to_string(z));
                }
    }
}
