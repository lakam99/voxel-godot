#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "native_surface_prop_test_fixture.hpp"
#include "../core/native_surface_rock_ordered_visual_plan.hpp"

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
