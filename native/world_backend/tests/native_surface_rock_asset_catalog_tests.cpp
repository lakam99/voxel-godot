#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"
#include "../core/native_surface_rock_asset_catalog.hpp"

#include <cmath>
#include <limits>

using namespace voxel::world_backend;

namespace {

NativeSurfaceRockAssetRecord rock(const std::string &id, const double x = 1.0,
    const double y = 1.0, const double z = 1.0) {
    NativeSurfaceRockAssetRecord value;
    value.id = id;
    value.family = "rock";
    value.path = "assets/visual/generated/environment/" + id + ".glb";
    value.biome_tags = {"plains", "forest", "mountain", "beach", "snow"};
    value.size_x = x; value.size_y = y; value.size_z = z;
    return value;
}

std::vector<NativeSurfaceRockAssetRecord> manifest_rocks() {
    return {rock("rock_01", 1.4591, 0.9246, 0.5640),
        rock("rock_02", 1.2609, 0.9295, 1.0198),
        rock("rock_03", 1.6291, 1.2517, 0.8299),
        rock("rock_04", 1.3483, 1.4157, 1.2823),
        rock("rock_05", 2.0574, 1.8181, 1.2822),
        rock("rock_06", 2.8466, 1.5018, 1.0785)};
}

NativeBiomeEnvironmentCatalog environment() {
    return NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
}

} // namespace

VWB_TEST(native_surface_rock_asset_catalog_matches_direct_godot_registry_selection_oracle) {
    const auto catalog = NativeSurfaceRockAssetCatalog::create(manifest_rocks(), environment());
    const auto forest = catalog.select("forest", "atlas-1492:10,20:3");
    VWB_EXPECT_EQ(std::string("rock_06"), forest.asset_id);
    VWB_EXPECT_EQ(std::string("forest"), forest.resolved_profile_biome);
    VWB_EXPECT_EQ(0.94, forest.rock_scale);
    VWB_EXPECT_EQ(6U, forest.candidate_count);
    VWB_EXPECT(forest.matched_biome_tag);
    VWB_EXPECT_EQ(static_cast<float>(2.8466), forest.asset_size.x);
    VWB_EXPECT_EQ(static_cast<float>(1.5018), forest.asset_size.y);
    VWB_EXPECT_EQ(static_cast<float>(1.0785), forest.asset_size.z);
    VWB_EXPECT_EQ(environment().content_digest(), forest.environment_catalog_digest);
    VWB_EXPECT_EQ(environment().profile_digest("forest"), forest.environment_profile_digest);
    VWB_EXPECT_EQ(catalog.content_digest(), forest.asset_catalog_digest);
    VWB_EXPECT_EQ(std::string("rock_03"), catalog.select("swamp", "atlas-1492:10,20:3").asset_id);
    VWB_EXPECT_EQ(std::string("rock_04"), catalog.select("desert", "atlas-1492:10,20:3").asset_id);
    const auto unknown = catalog.select("future_biome", "atlas-1492:10,20:3");
    VWB_EXPECT_EQ(std::string("rock_05"), unknown.asset_id);
    VWB_EXPECT_EQ(std::string("future_biome"), unknown.requested_biome);
    VWB_EXPECT_EQ(std::string("default"), unknown.resolved_profile_biome);
    VWB_EXPECT_EQ(environment().profile_digest("default"), unknown.environment_profile_digest);
    VWB_EXPECT(!unknown.matched_biome_tag);
    VWB_EXPECT_EQ(std::string("rock_02"), catalog.select("forest", "世界🌲:10,20:3").asset_id);
    VWB_EXPECT_EQ(221770655U, native_surface_rock_stable_hash("rock:forest:atlas-1492:10,20:3"));
    VWB_EXPECT_EQ(1074488173U, native_surface_rock_stable_hash("rock:forest:世界🌲:10,20:3"));
}

VWB_TEST(native_surface_rock_asset_catalog_preserves_tag_fallback_family_multiplicity_and_empty_selection) {
    auto profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : profiles) {
        if (profile.biome_id == "forest") profile.rock_families = {"rock", "rock"};
        if (profile.biome_id == "swamp") profile.rock_families = {"absent"};
    }
    auto rows = manifest_rocks();
    rows.resize(2U);
    rows[0].biome_tags = {"forest"};
    rows[1].biome_tags = {"snow"};
    const auto catalog = NativeSurfaceRockAssetCatalog::create(rows,
        NativeBiomeEnvironmentCatalog::create(profiles));
    const auto forest = catalog.select("forest", "id");
    VWB_EXPECT_EQ(2U, forest.candidate_count);
    VWB_EXPECT_EQ(std::string("rock_01"), forest.asset_id);
    VWB_EXPECT(forest.matched_biome_tag);
    const auto swamp = catalog.select("swamp", "id");
    VWB_EXPECT(swamp.asset_id.empty());
    VWB_EXPECT_EQ(0U, swamp.candidate_count);
    VWB_EXPECT(!swamp.matched_biome_tag);
    const auto beach = catalog.select("beach", "id");
    VWB_EXPECT_EQ(2U, beach.candidate_count);
    VWB_EXPECT(!beach.matched_biome_tag);
}

VWB_TEST(native_surface_rock_asset_catalog_filters_runtime_disabled_rows_and_tracks_semantic_identity) {
    auto rows = manifest_rocks();
    const auto intact = NativeSurfaceRockAssetCatalog::create(rows, environment());
    auto disabled = rows;
    disabled[5].runtime_enabled = false;
    const auto filtered = NativeSurfaceRockAssetCatalog::create(disabled, environment());
    VWB_EXPECT(filtered.content_digest() != intact.content_digest());
    VWB_EXPECT_EQ(5U, filtered.select("forest", "id").candidate_count);
    disabled[5].path += "_ignored";
    const auto same = NativeSurfaceRockAssetCatalog::create(disabled, environment());
    VWB_EXPECT_EQ(filtered.canonical_binary(), same.canonical_binary());
    rows[0].size_x += 0.001;
    VWB_EXPECT(intact.content_digest()
        != NativeSurfaceRockAssetCatalog::create(rows, environment()).content_digest());
    rows = manifest_rocks();
    rows[0].path += "_changed";
    VWB_EXPECT(intact.content_digest()
        != NativeSurfaceRockAssetCatalog::create(rows, environment()).content_digest());
    auto changed_profiles = tests::godot_oracle_environment_profiles();
    for (auto &profile : changed_profiles)
        if (profile.biome_id == "forest") profile.rock_scale = 0.93;
    const auto changed_environment = NativeSurfaceRockAssetCatalog::create(manifest_rocks(),
        NativeBiomeEnvironmentCatalog::create(changed_profiles));
    VWB_EXPECT(intact.content_digest() != changed_environment.content_digest());
}

VWB_TEST(native_surface_rock_asset_catalog_rejects_invalid_ready_snapshot_and_utf8) {
    auto rows = manifest_rocks();
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create({}, environment()));
    for (auto &row : rows) row.runtime_enabled = false;
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create(rows, environment()));
    rows = manifest_rocks(); rows[0].size_x = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create(rows, environment()));
    rows = manifest_rocks(); rows[0].path.clear();
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create(rows, environment()));
    const auto valid = NativeSurfaceRockAssetCatalog::create(manifest_rocks(), environment());
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected, valid.select("", "id"));
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected, valid.select("forest", ""));
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        valid.select("forest", std::string("\xC0\xAF", 2)));
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        native_surface_rock_stable_hash(std::string("\xED\xA0\x80", 3)));
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        native_surface_rock_stable_hash(std::string("\xF4\x90\x80\x80", 4)));
}

VWB_TEST(native_surface_rock_asset_catalog_admits_effective_registry_duplicates_and_empty_tags) {
    auto first = rock("rock_a");
    first.biome_tags = {"forest"};
    auto duplicate = rock("rock_a", 2.0, 3.0, 4.0);
    duplicate.biome_tags = {"snow"};
    const auto duplicate_catalog = NativeSurfaceRockAssetCatalog::create(
        {first, duplicate}, environment());
    // Family indexing retains both rows, while assets_by_id is last-write-wins.
    const auto forest = duplicate_catalog.select("forest", "id");
    VWB_EXPECT_EQ(2U, forest.candidate_count);
    VWB_EXPECT(!forest.matched_biome_tag);
    VWB_EXPECT_EQ(static_cast<float>(2.0), forest.asset_size.x);
    auto untagged = rock("rock_u");
    untagged.biome_tags.clear();
    const auto untagged_catalog = NativeSurfaceRockAssetCatalog::create({untagged}, environment());
    VWB_EXPECT(untagged_catalog.select("future_biome", "id").matched_biome_tag);
    VWB_EXPECT_EQ(environment().content_digest(), untagged_catalog.environment_digest());
    auto missing_id = rock("unused"); missing_id.id.clear();
    auto missing_family = rock("unused2"); missing_family.family.clear();
    const auto skipped = NativeSurfaceRockAssetCatalog::create(
        {missing_id, missing_family, untagged}, environment());
    VWB_EXPECT_EQ(untagged_catalog.canonical_binary(), skipped.canonical_binary());
}

VWB_TEST(native_surface_rock_asset_catalog_rejects_all_malformed_scalar_inputs) {
    auto rows = manifest_rocks();
    rows.resize(65537U);
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create(rows, environment()));
    rows = manifest_rocks(); rows[0].id.assign(4097U, 'x');
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create(rows, environment()));
    rows = manifest_rocks(); rows[0].size_y = std::numeric_limits<double>::infinity();
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create(rows, environment()));
    rows = manifest_rocks(); rows[0].size_z = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create(rows, environment()));
    for (int axis = 0; axis < 3; ++axis) {
        rows = manifest_rocks();
        if (axis == 0) rows[0].size_x = -1.0;
        if (axis == 1) rows[0].size_y = -1.0;
        if (axis == 2) rows[0].size_z = -1.0;
        VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
            NativeSurfaceRockAssetCatalog::create(rows, environment()));
    }
    rows = manifest_rocks(); rows[0].biome_tags.resize(257U, "forest");
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create(rows, environment()));
    for (int axis = 0; axis < 3; ++axis) {
        auto oversized = rock("rock_overflow");
        oversized.biome_tags = {"forest"};
        if (axis == 0) oversized.size_x = std::numeric_limits<double>::max();
        if (axis == 1) oversized.size_y = std::numeric_limits<double>::max();
        if (axis == 2) oversized.size_z = std::numeric_limits<double>::max();
        const auto catalog = NativeSurfaceRockAssetCatalog::create({oversized}, environment());
        VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected, catalog.select("forest", "id"));
    }
}

VWB_TEST(native_surface_rock_asset_catalog_utf8_hash_checks_all_codepoint_widths_and_rejections) {
    VWB_EXPECT(native_surface_rock_stable_hash("é") != native_surface_rock_stable_hash("e"));
    VWB_EXPECT(native_surface_rock_stable_hash("世界") != native_surface_rock_stable_hash("世界🌲"));
    for (const auto &bad : {std::string("\x80", 1), std::string("\xC2", 1),
            std::string("\xC2\x41", 2), std::string("\xE0\x80\x80", 3),
            std::string("\xF0\x80\x80\x80", 4), std::string("\xF4\x90\x80\x80", 4),
            std::string("\xF5\x80\x80\x80", 4)}) {
        VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected, native_surface_rock_stable_hash(bad));
    }
}

VWB_TEST(native_surface_rock_effective_registry_preserves_cross_family_membership_and_multiplicity) {
    auto old_value = rock("shared");
    old_value.family = "rock";
    old_value.biome_tags = {"forest"};
    auto final_value = old_value;
    final_value.family = "other";
    final_value.biome_tags = {"snow"};
    final_value.path = "assets/visual/generated/environment/final.glb";
    const auto raw = NativeSurfaceRockAssetCatalog::create({old_value, final_value}, environment());
    const auto effective = NativeSurfaceRockAssetCatalog::create_effective(
        {final_value}, {{"rock", {"shared", "shared"}}, {"other", {"shared"}}}, environment());
    const auto selected = effective.select("forest", "id");
    VWB_EXPECT_EQ(2U, selected.candidate_count);
    VWB_EXPECT(!selected.matched_biome_tag);
    VWB_EXPECT_EQ(std::string("shared"), selected.asset_id);
    VWB_EXPECT_EQ(final_value.path, selected.asset_path);
    VWB_EXPECT_EQ(1U, raw.select("forest", "id").candidate_count);
    VWB_EXPECT(raw.content_digest() != effective.content_digest());
    const auto fewer = NativeSurfaceRockAssetCatalog::create_effective(
        {final_value}, {{"rock", {"shared"}}, {"other", {"shared"}}}, environment());
    VWB_EXPECT_EQ(1U, fewer.select("forest", "id").candidate_count);
    VWB_EXPECT(fewer.content_digest() != effective.content_digest());
}

VWB_TEST(native_surface_rock_effective_registry_matches_direct_godot_selection_oracle) {
    auto rows = manifest_rocks();
    const auto catalog = NativeSurfaceRockAssetCatalog::create_effective(
        rows, {{"rock", {"rock_01", "rock_02", "rock_03", "rock_04", "rock_05", "rock_06"}}},
        environment());
    VWB_EXPECT_EQ(std::string("rock_06"), catalog.select("forest", "atlas-1492:10,20:3").asset_id);
    VWB_EXPECT_EQ(std::string("rock_03"), catalog.select("swamp", "atlas-1492:10,20:3").asset_id);
    VWB_EXPECT_EQ(std::string("rock_04"), catalog.select("desert", "atlas-1492:10,20:3").asset_id);
    VWB_EXPECT_EQ(std::string("rock_05"), catalog.select("future_biome", "atlas-1492:10,20:3").asset_id);
    VWB_EXPECT_EQ(std::string("rock_02"), catalog.select("forest", "世界🌲:10,20:3").asset_id);
    const auto reordered = NativeSurfaceRockAssetCatalog::create_effective(
        rows, {{"rock", {"rock_06", "rock_05", "rock_04", "rock_03", "rock_02", "rock_01"}}},
        environment());
    VWB_EXPECT_EQ(catalog.select("forest", "id").asset_id, reordered.select("forest", "id").asset_id);
    VWB_EXPECT(catalog.content_digest() != reordered.content_digest());
}

VWB_TEST(native_surface_rock_effective_registry_rejects_incoherent_capture) {
    auto row = rock("id");
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create_effective({}, {}, environment()));
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create_effective({row, row}, {{"rock", {"id"}}}, environment()));
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create_effective({row}, {{"rock", {"missing"}}}, environment()));
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create_effective({row}, {{"rock", {}}, {"rock", {}}}, environment()));
    row.runtime_enabled = false;
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create_effective({row}, {{"rock", {"id"}}}, environment()));
}

VWB_TEST(native_surface_rock_effective_registry_checks_each_bounded_numeric_lane) {
    auto row = rock("id");
    auto rows = std::vector<NativeSurfaceRockAssetRecord>(65537U, row);
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create_effective(rows, {}, environment()));
    auto families = std::vector<NativeSurfaceRockFamilyMembers>(65537U, {"rock", {}});
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create_effective({row}, families, environment()));
    row.biome_tags.resize(257U, "forest");
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create_effective({row}, {}, environment()));
    for (int axis = 0; axis < 3; ++axis) {
        for (int kind = 0; kind < 2; ++kind) {
            row = rock("id");
            const double bad = kind == 0 ? -1.0 : std::numeric_limits<double>::infinity();
            if (axis == 0) row.size_x = bad;
            if (axis == 1) row.size_y = bad;
            if (axis == 2) row.size_z = bad;
            VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
                NativeSurfaceRockAssetCatalog::create_effective({row}, {}, environment()));
        }
    }
    row = rock("id");
    VWB_EXPECT_THROW(NativeSurfaceRockAssetCatalogRejected,
        NativeSurfaceRockAssetCatalog::create_effective({row}, {{"rock", std::vector<std::string>(65537U, "id")}}, environment()));
}
