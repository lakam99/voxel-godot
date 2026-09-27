#include "test_harness.hpp"

#include "../core/biome_region_field.hpp"
#include "../core/world_source.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include <utility>

namespace voxel::world_backend::tests {
namespace {

bool near(const double left, const double right, const double tolerance = 1.0e-12) {
    return std::abs(left - right) <= tolerance;
}

std::vector<std::uint32_t> code_points(const std::initializer_list<std::uint32_t> values) {
    return {values};
}

const AdmittedBiomeSeed &atlas() {
    static const AdmittedBiomeSeed value = BiomeRegionField::admit_utf8_seed("atlas-1492");
    return value;
}

} // namespace

VWB_TEST(biome_region_field_admits_unicode_seeds_by_code_point_and_matches_strip_default_boundary) {
    const AdmittedBiomeSeed default_seed = BiomeRegionField::admit_utf8_seed("\x01\x09\x1f \r\n\x20");
    VWB_EXPECT_EQ(std::string("default"), default_seed.utf8);
    VWB_EXPECT_EQ(code_points({'d', 'e', 'f', 'a', 'u', 'l', 't'}), default_seed.code_points);

    const AdmittedBiomeSeed ascii_controls = BiomeRegionField::admit_utf8_seed("\x01\x1f  seed-\xF0\x9F\x8C\xB2\x20\x1e");
    VWB_EXPECT_EQ(std::string("seed-\xF0\x9F\x8C\xB2"), ascii_controls.utf8);
    VWB_EXPECT_EQ(code_points({'s', 'e', 'e', 'd', '-', 0x1f332U}), ascii_controls.code_points);

    // U+00A0 and U+3000 are not strip_edges characters. Their presence at an
    // edge prevents any following ASCII control/space from being trimmed.
    const AdmittedBiomeSeed nbsp = BiomeRegionField::admit_utf8_seed("\x1f \xC2\xA0seed\x20");
    VWB_EXPECT_EQ(std::string("\xC2\xA0seed"), nbsp.utf8);
    VWB_EXPECT_EQ(code_points({0x00a0U, 's', 'e', 'e', 'd'}), nbsp.code_points);
    const AdmittedBiomeSeed ideographic = BiomeRegionField::admit_utf8_seed("seed\x20\xE3\x80\x80");
    VWB_EXPECT_EQ(std::string("seed\x20\xE3\x80\x80"), ideographic.utf8);
    VWB_EXPECT_EQ(code_points({'s', 'e', 'e', 'd', 0x20U, 0x3000U}), ideographic.code_points);
    VWB_EXPECT_EQ(ascii_controls,
        BiomeRegionField::validate_admitted_seed(ascii_controls.code_points, ascii_controls.utf8));

    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::admit_utf8_seed("\xC0\x80"));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::admit_utf8_seed(std::string("seed\0suffix", 11)));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::validate_admitted_seed(code_points({'a'}), "b"));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::validate_admitted_seed(code_points({0xd800U}), "\xED\xA0\x80"));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::validate_admitted_seed({}, ""));
}

VWB_TEST(biome_region_field_uses_unicode_scalar_fnv_not_utf8_bytes) {
    const std::vector<std::uint32_t> scalar = code_points({0x00e9U});
    // FNV-1a over one Godot Unicode code point: (2166136261 xor 233) * 16777619.
    VWB_EXPECT_EQ(0.84409860002067805, BiomeRegionField::stable_unit(scalar));
    const AdmittedBiomeSeed unicode = BiomeRegionField::admit_utf8_seed("\xC3\xA9");
    const AdmittedBiomeSeed byte_like = BiomeRegionField::admit_utf8_seed("\xC3\xA9x");
    VWB_EXPECT_EQ(scalar, unicode.code_points);
    VWB_EXPECT(BiomeRegionField::stable_unit(unicode.code_points)
        != BiomeRegionField::stable_unit(byte_like.code_points));
    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::stable_unit(code_points({0x110000U})));
}

VWB_TEST(biome_region_field_utf8_validation_covers_all_scalar_encodings_and_rejections) {
    const std::vector<std::uint32_t> all_widths = code_points({0x007fU, 0x07ffU, 0xffffU, 0x10ffffU});
    const std::string encoded("\x7f\xDF\xBF\xEF\xBF\xBF\xF4\x8F\xBF\xBF", 10);
    VWB_EXPECT_EQ(all_widths,
        BiomeRegionField::validate_admitted_seed(all_widths, encoded).code_points);

    for (const std::string &invalid : std::vector<std::string>{
             "\x80", "\xC2", "\xC2\x41", "\xE0\xA0", "\xE0\x80\x80",
             "\xE1\x41\x80", "\xE1\x80\x41", "\xED\xA0\x80", "\xF0\x90\x80",
             "\xF0", "\xF4", "\xF0\x80\x80\x80", "\xF1\x41\x80\x80", "\xF1\x80\x41\x80",
             "\xF1\x80\x80\x41", "\xF4\x90\x80\x80"}) {
        VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::admit_utf8_seed(invalid));
    }
    // Keep this explicit-sized sequence outside the aggregate initializer so
    // coverage observes the F0 overlong-prefix rejection edge directly.
    const std::string overlong_four_byte("\xF0\x80\x80\x80", 4);
    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::admit_utf8_seed(overlong_four_byte));
    const std::string above_unicode_limit("\xF5", 1);
    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::admit_utf8_seed(above_unicode_limit));
    VWB_EXPECT_EQ(code_points({0x0800U}), BiomeRegionField::admit_utf8_seed("\xE0\xA0\x80").code_points);
    VWB_EXPECT_EQ(code_points({0xd7ffU}), BiomeRegionField::admit_utf8_seed("\xED\x9F\xBF").code_points);
    VWB_EXPECT_EQ(code_points({0x10000U}), BiomeRegionField::admit_utf8_seed("\xF0\x90\x80\x80").code_points);
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::validate_admitted_seed(all_widths, "not-the-same"));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::validate_admitted_seed(code_points({'a'}), std::string("a\0", 2)));
    // Direct invalid-scalar validation remains fail-closed. It necessarily
    // reaches the canonical/presentation mismatch before the later scalar
    // guard: a strict UTF-8 decoder cannot produce a surrogate or >U+10FFFF.
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::validate_admitted_seed(code_points({0xd800U}), "a"));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::validate_admitted_seed(code_points({0x110000U}), "a"));
}

VWB_TEST(biome_region_field_value_equality_and_interpolation_contracts_cover_each_field) {
    const AdmittedBiomeSeed seed = atlas();
    VWB_EXPECT_EQ(seed, (AdmittedBiomeSeed{seed.code_points, seed.utf8}));
    AdmittedBiomeSeed different_seed = seed;
    different_seed.code_points.back() = '3';
    VWB_EXPECT(!(seed == different_seed));
    different_seed = seed;
    different_seed.utf8 += "x";
    VWB_EXPECT(!(seed == different_seed));

    VWB_EXPECT_EQ((BiomeRegion{4, -5}), (BiomeRegion{4, -5}));
    VWB_EXPECT(!(BiomeRegion{4, -5} == BiomeRegion{3, -5}));
    VWB_EXPECT(!(BiomeRegion{4, -5} == BiomeRegion{4, -4}));
    VWB_EXPECT_EQ((BiomeVec2{1.0F, -2.0F}), (BiomeVec2{1.0F, -2.0F}));
    VWB_EXPECT(!(BiomeVec2{1.0F, -2.0F} == BiomeVec2{2.0F, -2.0F}));
    VWB_EXPECT(!(BiomeVec2{1.0F, -2.0F} == BiomeVec2{1.0F, -3.0F}));

    const BiomeRegionSample sample = BiomeRegionField::sample(seed, {14250.75F, -8810.25F});
    for (unsigned field = 0; field < 14U; ++field) {
        BiomeRegionSample changed = sample;
        if (field == 0U) ++changed.version;
        if (field == 1U) ++changed.region.x;
        if (field == 2U) ++changed.region.z;
        if (field == 3U) changed.region_id += ":other";
        if (field == 4U) changed.site_position.x += 1.0F;
        if (field == 5U) changed.site_position.z += 1.0F;
        if (field == 6U) changed.biome += ":other";
        if (field == 7U) changed.temperature += 1.0;
        if (field == 8U) changed.moisture += 1.0;
        if (field == 9U) changed.second_distance_meters += 1.0;
        if (field == 10U) changed.edge_distance_meters += 1.0;
        if (field == 11U) changed.ecotone_weight += 1.0;
        if (field == 12U) changed.minimum_core_radius_meters += 1.0;
        if (field == 13U) changed.minimum_core_diameter_meters += 1.0;
        VWB_EXPECT(!(sample == changed));
    }

    const double a = BiomeRegionField::value_noise(seed, {-2.0F, -3.0F}, "interpolation");
    const double b = BiomeRegionField::value_noise(seed, {-1.0F, -3.0F}, "interpolation");
    const double c = BiomeRegionField::value_noise(seed, {-2.0F, -2.0F}, "interpolation");
    const double d = BiomeRegionField::value_noise(seed, {-1.0F, -2.0F}, "interpolation");
    VWB_EXPECT(near((a + b + c + d) * 0.25,
        BiomeRegionField::value_noise(seed, {-1.5F, -2.5F}, "interpolation")));
}

VWB_TEST(biome_region_field_public_validation_and_coordinate_error_paths_are_strict) {
    const AdmittedBiomeSeed seed = atlas();
    VWB_EXPECT(BiomeRegionField::climate_channel(seed, {-2, 3}, "temperature") >= 0.0);
    VWB_EXPECT(BiomeRegionField::climate_channel(seed, {-2, 3}, "moisture") <= 1.0);
    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::climate_channel(seed, {0, 0}, ""));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::site_position(AdmittedBiomeSeed{{}, ""}, {0, 0}));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::region_id(AdmittedBiomeSeed{code_points({'a'}), "b"}, {0, 0}));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::value_noise(seed, {0.0F, std::numeric_limits<float>::infinity()}, "x"));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::value_noise(seed, {-std::numeric_limits<float>::max(), 0.0F}, "x"));
    // INT32_MIN remains a valid lattice origin: its required successor is
    // representable. INT32_MAX remains rejected by the max-exclusive contract.
    VWB_EXPECT(BiomeRegionField::value_noise(seed,
        {static_cast<float>(std::numeric_limits<std::int32_t>::min()), 0.0F}, "x") >= 0.0);
    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::value_noise(seed,
        {static_cast<float>(std::numeric_limits<std::int32_t>::max()), 0.0F}, "x"));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::sample(seed, {0.0F, std::numeric_limits<float>::infinity()}));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::sample(seed, {-std::numeric_limits<float>::max(), 0.0F}));
    // Sampling needs the complete predecessor/current/successor z row. Both
    // extrema therefore reject before the floor-to-int32 conversion, just as
    // the established x-bound checks do for value noise.
    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::sample(seed,
        {0.0F, static_cast<float>(static_cast<double>(std::numeric_limits<std::int32_t>::min())
                    * BiomeRegionField::REGION_SPACING_METERS)}));
    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::sample(seed,
        {0.0F, static_cast<float>(static_cast<double>(std::numeric_limits<std::int32_t>::max())
                    * BiomeRegionField::REGION_SPACING_METERS)}));
}

VWB_TEST(biome_region_field_fixed_atlas_sample_matches_script_golden) {
    const BiomeRegionSample sample = BiomeRegionField::sample(atlas(), {14250.75, -8810.25});
    VWB_EXPECT_EQ((BiomeRegion{2, -2}), sample.region);
    VWB_EXPECT_EQ(std::string("biome-v2:atlas-1492:2,-2"), sample.region_id);
    VWB_EXPECT_EQ(std::string("plains"), sample.biome);
    VWB_EXPECT_EQ(2U, sample.version);
    VWB_EXPECT(near(14911.9013671875, sample.site_position.x, 1.0e-12));
    VWB_EXPECT(near(-9096.15234375, sample.site_position.z, 1.0e-12));
    VWB_EXPECT(near(0.646733634051165, sample.temperature, 1.0e-12));
    VWB_EXPECT(near(0.584567430750002, sample.moisture, 1.0e-12));
    VWB_EXPECT(near(5146.0498046875, sample.second_distance_meters, 1.0e-6));
    VWB_EXPECT(near(2212.86477661133, sample.edge_distance_meters, 1.0e-8));
    VWB_EXPECT_EQ(0.0, sample.ecotone_weight);
    VWB_EXPECT_EQ(2680.0, sample.minimum_core_radius_meters);
    VWB_EXPECT_EQ(5360.0, sample.minimum_core_diameter_meters);
}

VWB_TEST(biome_region_field_negative_coordinates_sites_and_order_are_deterministic) {
    const BiomeRegion region{-3, -2};
    const BiomeVec2 site = BiomeRegionField::site_position(atlas(), region);
    VWB_EXPECT(near(-15042.0400390625, site.x, 1.0e-12));
    VWB_EXPECT(near(-9013.3798828125, site.z, 1.0e-12));
    VWB_EXPECT_EQ(std::string("biome-v2:atlas-1492:-3,-2"), BiomeRegionField::region_id(atlas(), region));

    const BiomeRegionSample first = BiomeRegionField::sample(atlas(), {-16100.125, -7340.875});
    const BiomeRegionSample changed = BiomeRegionField::sample(
        BiomeRegionField::admit_utf8_seed("atlas-other"), {-16100.125, -7340.875});
    const BiomeRegionSample second = BiomeRegionField::sample(atlas(), {-16100.125, -7340.875});
    VWB_EXPECT_EQ(first, second);
    VWB_EXPECT_EQ((BiomeRegion{-3, -2}), first.region);
    VWB_EXPECT(near(0.508754403198706, first.temperature, 1.0e-12));
    VWB_EXPECT(near(0.505056611180023, first.moisture, 1.0e-12));
    VWB_EXPECT(near(1244.63323974609, first.edge_distance_meters, 1.0e-8));
    VWB_EXPECT(first.region_id != changed.region_id);
    VWB_EXPECT(first.edge_distance_meters >= 0.0);
}

VWB_TEST(biome_region_field_ecotone_nearest_second_nearest_and_bounds_are_explicit) {
    const BiomeVec2 left_site = BiomeRegionField::site_position(atlas(), {0, 0});
    const BiomeVec2 right_site = BiomeRegionField::site_position(atlas(), {1, 0});
    const BiomeVec2 boundary{
        static_cast<float>((left_site.x + right_site.x) * 0.5F),
        static_cast<float>((left_site.z + right_site.z) * 0.5F)};
    const BiomeRegionSample edge = BiomeRegionField::sample(atlas(), boundary);
    VWB_EXPECT(near(3041.38623046875, edge.second_distance_meters, 1.0e-6));
    VWB_EXPECT(edge.edge_distance_meters <= 0.001);
    VWB_EXPECT(edge.ecotone_weight >= 0.999999);

    const BiomeRegionSample core = BiomeRegionField::sample(atlas(), left_site);
    VWB_EXPECT(core.edge_distance_meters >= BiomeRegionField::MINIMUM_CORE_RADIUS_METERS);
    VWB_EXPECT_EQ(0.0, core.ecotone_weight);
    for (const BiomeVec2 point : std::vector<BiomeVec2>{{-13700.0, -22100.0}, {-1.0, -1.0}, {0.0, 0.0}, {7200.0, 9200.0}}) {
        const BiomeRegionSample sample = BiomeRegionField::sample(atlas(), point);
        VWB_EXPECT(sample.second_distance_meters >= sample.edge_distance_meters);
        VWB_EXPECT(sample.edge_distance_meters >= 0.0);
        VWB_EXPECT(sample.ecotone_weight >= 0.0 && sample.ecotone_weight <= 1.0);
    }
}

VWB_TEST(biome_region_field_exact_ties_keep_z_then_x_winner_and_second_candidate_order) {
    // At this supported global-coordinate magnitude Godot Vector2 float32
    // storage coalesces the nine jittered 6km sites. Every candidate is an
    // exact distance tie, making the script's loop order observable: z outer
    // then x inner, with strict `<` preserving the first and second entries.
    const BiomeVec2 far_point{6000000000000.0F, 6000000000000.0F};
    const std::int32_t grid_x = static_cast<std::int32_t>(std::floor(
        static_cast<double>(far_point.x) / BiomeRegionField::REGION_SPACING_METERS));
    const std::int32_t grid_z = static_cast<std::int32_t>(std::floor(
        static_cast<double>(far_point.z) / BiomeRegionField::REGION_SPACING_METERS));
    const BiomeRegion first_candidate{grid_x - 1, grid_z - 1};
    const BiomeRegion second_candidate{grid_x, grid_z - 1};
    const BiomeVec2 first_site = BiomeRegionField::site_position(atlas(), first_candidate);
    const BiomeVec2 second_site = BiomeRegionField::site_position(atlas(), second_candidate);
    const BiomeRegionSample tied = BiomeRegionField::sample(atlas(), far_point);
    VWB_EXPECT_EQ(first_candidate, tied.region);
    VWB_EXPECT_EQ(first_site, tied.site_position);
    VWB_EXPECT_EQ(first_site, second_site);
    const float dx = far_point.x - second_site.x;
    const float dz = far_point.z - second_site.z;
    VWB_EXPECT_EQ(static_cast<double>(std::sqrt(dx * dx + dz * dz)), tied.second_distance_meters);
    VWB_EXPECT_EQ(0.0, tied.edge_distance_meters);
}

VWB_TEST(biome_region_field_climate_and_biome_thresholds_match_script_inequalities) {
    VWB_EXPECT_EQ(std::string("snow"), BiomeRegionField::biome_for_climate(0.189999, 1.0));
    VWB_EXPECT_EQ(std::string("tundra"), BiomeRegionField::biome_for_climate(0.19, 0.419999));
    VWB_EXPECT_EQ(std::string("taiga"), BiomeRegionField::biome_for_climate(0.19, 0.42));
    VWB_EXPECT_EQ(std::string("taiga"), BiomeRegionField::biome_for_climate(0.329999, 0.42));
    VWB_EXPECT_EQ(std::string("swamp"), BiomeRegionField::biome_for_climate(0.33, 0.790001));
    VWB_EXPECT_EQ(std::string("desert"), BiomeRegionField::biome_for_climate(0.700001, 0.299999));
    VWB_EXPECT_EQ(std::string("savanna"), BiomeRegionField::biome_for_climate(0.700001, 0.30));
    VWB_EXPECT_EQ(std::string("savanna"), BiomeRegionField::biome_for_climate(0.600001, 0.489999));
    VWB_EXPECT_EQ(std::string("forest"), BiomeRegionField::biome_for_climate(0.60, 0.620001));
    VWB_EXPECT_EQ(std::string("plains"), BiomeRegionField::biome_for_climate(0.60, 0.62));
}

VWB_TEST(biome_region_field_value_noise_and_failure_boundaries_are_total) {
    const double exact_lattice = BiomeRegionField::value_noise(atlas(), {-2.0, -3.0}, "temperature-broad");
    const double just_right = BiomeRegionField::value_noise(atlas(), {-1.999, -2.999}, "temperature-broad");
    VWB_EXPECT(exact_lattice >= 0.0 && exact_lattice <= 1.0);
    VWB_EXPECT(just_right >= 0.0 && just_right <= 1.0);
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::value_noise(atlas(), {std::numeric_limits<double>::infinity(), 0.0}, "x"));
    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::value_noise(atlas(), {0.0, 0.0}, ""));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::value_noise(atlas(), {static_cast<double>(std::numeric_limits<std::int32_t>::max()), 0.0}, "x"));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::sample(atlas(), {std::numeric_limits<double>::quiet_NaN(), 0.0}));
    VWB_EXPECT_THROW(std::invalid_argument,
        BiomeRegionField::sample(atlas(), {static_cast<double>(std::numeric_limits<std::int32_t>::max())
            * BiomeRegionField::REGION_SPACING_METERS, 0.0}));
}

} // namespace voxel::world_backend::tests

namespace voxel::world_backend::tests {
VWB_TEST(borrowed_regional_numeric_cursor_matches_independent_script_goldens) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    const WorldSourceDefinition definition(std::move(descriptor));
    EvaluatorStamp stamp{}; stamp.incarnation = 11U; stamp.generation = 1U;
    stamp.definition_digest = definition.physical_content_identity().digest;
    struct Golden { BiomeVec2 position; BiomeRegion region; double temperature; double moisture; double edge; };
    // Same independently captured script facts as the existing field tests.
    const std::array<Golden, 2> goldens{{
        {{14250.75F, -8810.25F}, {2, -2}, 0.646733634051165, 0.584567430750002, 2212.86477661133},
        {{-16100.125F, -7340.875F}, {-3, -2}, 0.508754403198706, 0.505056611180023, 1244.63323974609}
    }};
    for (const auto &golden : goldens) {
        BiomeCursor cursor; WorkQuota zero(0U);
        VWB_EXPECT_EQ(0U, begin_biome(cursor, stamp, golden.position, zero).consumed_work);
        VWB_EXPECT_EQ(EvalStatus::idle, cursor.status);
        WorkQuota start(1U); (void)begin_biome(cursor, stamp, golden.position, start);
        for (std::size_t calls = 0U; cursor.status == EvalStatus::pending && calls < 20000U; ++calls) {
            WorkQuota quota(1U); const auto step = advance_biome(cursor, stamp, definition, quota);
            VWB_EXPECT_EQ(1U - quota.remaining(), step.step.consumed_work);
            VWB_EXPECT(step.step.consumed_work > 0U || step.step.status != EvalStatus::pending);
        }
        VWB_EXPECT_EQ(EvalStatus::ready, cursor.status);
        VWB_EXPECT_EQ(golden.region, cursor.result.region);
        VWB_EXPECT(near(golden.temperature, cursor.result.temperature));
        VWB_EXPECT(near(golden.moisture, cursor.result.moisture));
        VWB_EXPECT(near(golden.edge, cursor.result.edge_distance_meters, 1.0e-8));
        VWB_EXPECT_EQ(RegionalBiome::plains, cursor.result.biome);
        const auto original = BiomeRegionField::sample(definition.admitted_biome_seed(), golden.position);
        VWB_EXPECT_EQ(original.site_position, cursor.result.site_position);
        VWB_EXPECT_EQ(original.second_distance_meters, cursor.result.second_distance_meters);
        VWB_EXPECT_EQ(original.ecotone_weight, cursor.result.ecotone_weight);
        WorkQuota repeat(0U); const auto ready = advance_biome(cursor, stamp, definition, repeat);
        VWB_EXPECT_EQ(EvalStatus::ready, ready.step.status); VWB_EXPECT_EQ(0U, ready.step.consumed_work);
        VWB_EXPECT_EQ(EvalStatus::idle, reset_biome(cursor).status);
    }
}

VWB_TEST(borrowed_regional_parent_stamp_survives_nested_key_reset_and_rejects_drift) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed(" \xF0\x9F\x8C\xB2 ");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(" \xF0\x9F\x8C\xB2 ");
    const WorldSourceDefinition definition(std::move(descriptor));
    EvaluatorStamp stamp{}; stamp.incarnation = 12U; stamp.generation = 2U;
    stamp.definition_digest = definition.physical_content_identity().digest;
    BiomeCursor cursor; WorkQuota start(1U); (void)begin_biome(cursor, stamp, {-500.0F, -900.0F}, start);
    WorkQuota prefix(200U); (void)advance_biome(cursor, stamp, definition, prefix);
    VWB_EXPECT_EQ(stamp, cursor.stamp);
    auto other = stamp; ++other.revision;
    const auto old_stage = cursor.stage;
    const auto old_key = cursor.key.hash.value;
    WorkQuota zero(0U);
    VWB_EXPECT_EQ(EvalReason::identity, advance_biome(cursor, other, definition, zero).step.reason);
    VWB_EXPECT_EQ(EvalStatus::pending, cursor.status); VWB_EXPECT_EQ(old_stage, cursor.stage);
    VWB_EXPECT_EQ(old_key, cursor.key.hash.value);
    WorkQuota positive(1U);
    VWB_EXPECT_EQ(EvalReason::identity, advance_biome(cursor, other, definition, positive).step.reason);
    VWB_EXPECT_EQ(EvalStatus::rejected, cursor.status); VWB_EXPECT_EQ(stamp, cursor.stamp);
    VWB_EXPECT_EQ(old_key, cursor.key.hash.value);
    VWB_EXPECT_EQ(EvalStatus::cancelled, cancel_biome(cursor).status);
    VWB_EXPECT_EQ(EvalStatus::idle, reset_biome(cursor).status);
    WorkQuota invalid(1U);
    VWB_EXPECT_EQ(EvalReason::input, begin_biome(cursor, stamp,
        {std::numeric_limits<float>::infinity(), 0.0F}, invalid).reason);
    VWB_EXPECT_EQ(1U, invalid.remaining());
}
} // namespace voxel::world_backend::tests
