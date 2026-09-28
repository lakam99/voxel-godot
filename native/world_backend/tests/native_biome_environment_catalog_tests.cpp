#include "test_harness.hpp"
#include "native_biome_environment_oracle_fixture.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

using namespace voxel::world_backend;

namespace {

NativeBiomeEnvironmentCatalog oracle_catalog() {
    return NativeBiomeEnvironmentCatalog::create(tests::godot_oracle_environment_profiles());
}

template <typename Mutator>
void expect_invalid_profile(Mutator mutate) {
    auto values = tests::godot_oracle_environment_profiles();
    mutate(values.front());
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected,
        NativeBiomeEnvironmentCatalog::create(std::move(values)));
}

std::uint64_t bits64(double value) {
    std::uint64_t bits = 0U;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}
std::uint32_t bits32(float value) {
    std::uint32_t bits = 0U;
    std::memcpy(&bits, &value, sizeof(bits));
    return bits;
}

} // namespace

VWB_TEST(native_biome_environment_catalog_admits_all_thirteen_resolved_godot_profiles_and_default_fallback) {
    const auto catalog = oracle_catalog();
    VWB_EXPECT_EQ(13U, catalog.profiles().size());
    VWB_EXPECT_EQ(std::string("default"), catalog.fallback_id());
    VWB_EXPECT_EQ(std::string("default"), catalog.profile_for_biome("future_biome").biome_id);
    VWB_EXPECT_EQ(std::string("default"), catalog.profile_for_biome("zzzz_future_biome").biome_id);
    VWB_EXPECT_EQ(catalog.profile_digest("default"), catalog.profile_digest("future_biome"));
    VWB_EXPECT_EQ(catalog.profile_digest("default"), catalog.profile_digest("zzzz_future_biome"));
    VWB_EXPECT_EQ(std::string("alpine"), catalog.profiles().front().biome_id);
    VWB_EXPECT_EQ(std::string("tundra"), catalog.profiles().back().biome_id);
    VWB_EXPECT_EQ(std::string("conifer"), catalog.profile_for_biome("alpine").tree_architecture);
    VWB_EXPECT_EQ(std::string("ecological_conifer_tree"), catalog.profile_for_biome("alpine").tree_families.front());
    VWB_EXPECT_EQ(bits64(0.55), bits64(catalog.profile_for_biome("alpine").rock_base_chance));
    VWB_EXPECT_EQ(0x3eae147bU,
        bits32(catalog.profile_for_biome("forest").detail_thresholds.front()));
}

VWB_TEST(native_biome_environment_catalog_identity_is_semantic_sorted_and_field_sensitive) {
    auto values = tests::godot_oracle_environment_profiles();
    const auto first = NativeBiomeEnvironmentCatalog::create(values);
    std::reverse(values.begin(), values.end());
    const auto reordered = NativeBiomeEnvironmentCatalog::create(values);
    VWB_EXPECT_EQ(first.canonical_binary(), reordered.canonical_binary());
    VWB_EXPECT_EQ(first.content_digest(), reordered.content_digest());
    VWB_EXPECT(first.profile_digest("forest") != first.profile_digest("alpine"));

    values[8U].tree_chance = std::nextafter(values[8U].tree_chance, 1.0);
    const auto changed_scalar = NativeBiomeEnvironmentCatalog::create(values);
    VWB_EXPECT(first.content_digest() != changed_scalar.content_digest());
    VWB_EXPECT(first.profile_digest(values[8U].biome_id) != changed_scalar.profile_digest(values[8U].biome_id));

    values = tests::godot_oracle_environment_profiles();
    values[0U].detail_thresholds[0U] = std::nextafter(values[0U].detail_thresholds[0U], 1.0F);
    const auto changed_packed = NativeBiomeEnvironmentCatalog::create(values);
    VWB_EXPECT(first.content_digest() != changed_packed.content_digest());
    VWB_EXPECT(first.profile_digest("alpine") != changed_packed.profile_digest("alpine"));
}

VWB_TEST(native_biome_environment_catalog_rejects_missing_duplicate_and_unknown_profiles) {
    auto values = tests::godot_oracle_environment_profiles();
    values.pop_back();
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected, NativeBiomeEnvironmentCatalog::create(values));
    values = tests::godot_oracle_environment_profiles();
    values.back().biome_id = "alpine";
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected, NativeBiomeEnvironmentCatalog::create(values));
    values.back().biome_id = "other";
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected, NativeBiomeEnvironmentCatalog::create(values));
    values = tests::godot_oracle_environment_profiles();
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected,
        NativeBiomeEnvironmentCatalog::create(values, "forest"));
}

VWB_TEST(native_biome_environment_catalog_rejects_nonfinite_and_invalid_resolved_policy) {
    auto values = tests::godot_oracle_environment_profiles();
    values[0U].tree_chance = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected, NativeBiomeEnvironmentCatalog::create(values));
    values = tests::godot_oracle_environment_profiles();
    values[0U].detail_thresholds.back() = 0.99F;
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected, NativeBiomeEnvironmentCatalog::create(values));
    values = tests::godot_oracle_environment_profiles();
    values[0U].detail_scale_mins[0U] = values[0U].detail_scale_maxs[0U] + 1.0F;
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected, NativeBiomeEnvironmentCatalog::create(values));
    values = tests::godot_oracle_environment_profiles();
    values[0U].tree_age_band_thresholds[1U] = values[0U].tree_age_band_thresholds[0U];
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected, NativeBiomeEnvironmentCatalog::create(values));
    values = tests::godot_oracle_environment_profiles();
    values[0U].tree_families.clear();
    VWB_EXPECT_THROW(NativeBiomeEnvironmentCatalogRejected, NativeBiomeEnvironmentCatalog::create(values));
}

VWB_TEST(native_biome_environment_catalog_validates_every_resolved_field_boundary) {
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const float fnan = std::numeric_limits<float>::quiet_NaN();
    expect_invalid_profile([](auto &p) { p.forage_material.clear(); });
    expect_invalid_profile([](auto &p) { p.forage_drop.clear(); });
    expect_invalid_profile([](auto &p) { p.tree_architecture.clear(); });
    expect_invalid_profile([](auto &p) { p.forage_material = std::string(65537U, 'x'); });
    expect_invalid_profile([](auto &p) { p.tree_families = std::vector<std::string>(65U, "tree"); });
    expect_invalid_profile([](auto &p) { p.rock_families.clear(); });
    expect_invalid_profile([](auto &p) { p.rock_families = std::vector<std::string>(65U, "rock"); });
    expect_invalid_profile([](auto &p) { p.tree_families.front().clear(); });
    expect_invalid_profile([](auto &p) { p.rock_families.front().clear(); });
    expect_invalid_profile([](auto &p) { p.detail_types = std::vector<std::string>(65U, "detail"); });
    expect_invalid_profile([](auto &p) { p.detail_thresholds.pop_back(); });
    expect_invalid_profile([](auto &p) { p.detail_y_offsets.pop_back(); });
    expect_invalid_profile([](auto &p) { p.detail_scale_mins.pop_back(); });
    expect_invalid_profile([](auto &p) { p.detail_scale_maxs.pop_back(); });
    expect_invalid_profile([&](auto &p) { p.detail_thresholds[0] = fnan; });
    expect_invalid_profile([](auto &p) { p.detail_thresholds[0] = 0.0F; });
    expect_invalid_profile([](auto &p) { p.detail_thresholds[0] = 1.1F; });
    expect_invalid_profile([&](auto &p) { p.detail_y_offsets[0] = fnan; });
    expect_invalid_profile([&](auto &p) { p.detail_scale_mins[0] = fnan; });
    expect_invalid_profile([&](auto &p) { p.detail_scale_maxs[0] = fnan; });
    expect_invalid_profile([](auto &p) { p.forage_drop_max = p.forage_drop_min - 1; });
    expect_invalid_profile([](auto &p) { p.tree_scale = -1.0; });
    expect_invalid_profile([&](auto &p) { p.tree_scale = nan; });
    expect_invalid_profile([](auto &p) { p.rock_scale = -1.0; });
    expect_invalid_profile([](auto &p) { p.forage_radius = -1.0; });
    expect_invalid_profile([](auto &p) { p.tree_chance = -0.1; });
    expect_invalid_profile([](auto &p) { p.tree_chance = 1.1; });
    expect_invalid_profile([](auto &p) { p.rock_base_chance = 1.1; });
    expect_invalid_profile([](auto &p) { p.forage_chance = 1.1; });
    expect_invalid_profile([](auto &p) { p.wildlife_chance = 1.1; });
    expect_invalid_profile([](auto &p) { p.weather_precip = 1.1; });
    expect_invalid_profile([](auto &p) { p.weather_clouds = 1.1; });
    expect_invalid_profile([](auto &p) { p.detail_max_height_above_water = -1.0; });
    expect_invalid_profile([](auto &p) { p.tree_height_min = -1.0; });
    expect_invalid_profile([&](auto &p) { p.tree_height_max = nan; });
    expect_invalid_profile([](auto &p) { p.tree_height_max = p.tree_height_min - 1.0; });
    expect_invalid_profile([](auto &p) { p.crown_radius_min = -1.0; });
    expect_invalid_profile([&](auto &p) { p.crown_radius_max = nan; });
    expect_invalid_profile([](auto &p) { p.crown_radius_max = p.crown_radius_min - 1.0; });
    expect_invalid_profile([](auto &p) { p.trunk_radius_min = -1.0; });
    expect_invalid_profile([&](auto &p) { p.trunk_radius_max = nan; });
    expect_invalid_profile([](auto &p) { p.trunk_radius_max = p.trunk_radius_min - 1.0; });
    expect_invalid_profile([](auto &p) { p.old_growth_chance = 1.1; });
    expect_invalid_profile([](auto &p) { p.wind_response = -1.0; });
    expect_invalid_profile([](auto &p) { p.canopy_density = -1.0; });
    expect_invalid_profile([](auto &p) { p.natural_prop_exclusion_margin = -1.0; });
    expect_invalid_profile([](auto &p) { p.tree_visibility_range = -1.0; });
    expect_invalid_profile([](auto &p) { p.tree_shadow_range = -1.0; });
    expect_invalid_profile([](auto &p) { p.tree_age_min_years = -1.0; });
    expect_invalid_profile([&](auto &p) { p.tree_age_typical_years = nan; });
    expect_invalid_profile([&](auto &p) { p.tree_age_max_years = nan; });
    expect_invalid_profile([](auto &p) { p.tree_age_min_years = p.tree_age_typical_years + 1.0; });
    expect_invalid_profile([](auto &p) { p.tree_age_max_years = p.tree_age_typical_years - 1.0; });
    expect_invalid_profile([&](auto &p) { p.tree_maturity_cell_scale = nan; });
    expect_invalid_profile([](auto &p) { p.tree_maturity_cell_scale = 7.0; });
    expect_invalid_profile([](auto &p) { p.tree_maturity_influence = 1.1; });
    expect_invalid_profile([](auto &p) { p.tree_local_age_span = 0.0; });
    expect_invalid_profile([](auto &p) { p.tree_local_age_span = 1.01; });
    expect_invalid_profile([&](auto &p) { p.tree_age_distribution_skew = nan; });
    expect_invalid_profile([](auto &p) { p.tree_age_distribution_skew = 0.1; });
    expect_invalid_profile([](auto &p) { p.tree_age_distribution_skew = 3.1; });
    expect_invalid_profile([&](auto &p) { p.tree_height_growth_exponent = nan; });
    expect_invalid_profile([](auto &p) { p.tree_height_growth_exponent = 0.1; });
    expect_invalid_profile([](auto &p) { p.tree_height_growth_exponent = 2.1; });
    expect_invalid_profile([&](auto &p) { p.tree_girth_growth_exponent = nan; });
    expect_invalid_profile([](auto &p) { p.tree_girth_growth_exponent = 0.1; });
    expect_invalid_profile([](auto &p) { p.tree_girth_growth_exponent = 2.1; });
    expect_invalid_profile([&](auto &p) { p.tree_crown_growth_exponent = nan; });
    expect_invalid_profile([](auto &p) { p.tree_crown_growth_exponent = 0.1; });
    expect_invalid_profile([](auto &p) { p.tree_crown_growth_exponent = 2.1; });
    expect_invalid_profile([](auto &p) { p.tree_architecture = "unknown"; });
    expect_invalid_profile([&](auto &p) { p.tree_age_band_thresholds[0] = fnan; });
    expect_invalid_profile([](auto &p) { p.tree_age_band_thresholds[3] = 1.0F; });
}
