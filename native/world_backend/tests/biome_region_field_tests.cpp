#include "test_harness.hpp"

#include "../core/biome_region_field.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

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
    const AdmittedBiomeSeed default_seed = BiomeRegionField::admit_utf8_seed(" \t\r\n ");
    VWB_EXPECT_EQ(std::string("default"), default_seed.utf8);
    VWB_EXPECT_EQ(code_points({'d', 'e', 'f', 'a', 'u', 'l', 't'}), default_seed.code_points);

    const AdmittedBiomeSeed unicode = BiomeRegionField::admit_utf8_seed("\xC2\xA0  seed-\xF0\x9F\x8C\xB2  \xE3\x80\x80");
    VWB_EXPECT_EQ(std::string("seed-\xF0\x9F\x8C\xB2"), unicode.utf8);
    VWB_EXPECT_EQ(code_points({'s', 'e', 'e', 'd', '-', 0x1f332U}), unicode.code_points);
    VWB_EXPECT_EQ(unicode, BiomeRegionField::validate_admitted_seed(unicode.code_points, unicode.utf8));

    VWB_EXPECT_THROW(std::invalid_argument, BiomeRegionField::admit_utf8_seed("\xC0\x80"));
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

VWB_TEST(biome_region_field_fixed_atlas_sample_matches_script_golden) {
    const BiomeRegionSample sample = BiomeRegionField::sample(atlas(), {14250.75, -8810.25});
    VWB_EXPECT_EQ((BiomeRegion{2, -2}), sample.region);
    VWB_EXPECT_EQ(std::string("biome-v2:atlas-1492:2,-2"), sample.region_id);
    VWB_EXPECT_EQ(std::string("plains"), sample.biome);
    VWB_EXPECT(near(14911.9013671875, sample.site_position.x, 1.0e-12));
    VWB_EXPECT(near(-9096.15234375, sample.site_position.z, 1.0e-12));
    VWB_EXPECT(near(0.646733634051165, sample.temperature, 1.0e-12));
    VWB_EXPECT(near(0.584567430750002, sample.moisture, 1.0e-12));
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
    VWB_EXPECT(edge.edge_distance_meters <= 0.001);
    VWB_EXPECT(edge.ecotone_weight >= 0.999999);

    const BiomeRegionSample core = BiomeRegionField::sample(atlas(), left_site);
    VWB_EXPECT(core.edge_distance_meters >= BiomeRegionField::MINIMUM_CORE_RADIUS_METERS);
    VWB_EXPECT_EQ(0.0, core.ecotone_weight);
    for (const BiomeVec2 point : std::vector<BiomeVec2>{{-13700.0, -22100.0}, {-1.0, -1.0}, {0.0, 0.0}, {7200.0, 9200.0}}) {
        const BiomeRegionSample sample = BiomeRegionField::sample(atlas(), point);
        VWB_EXPECT(sample.edge_distance_meters >= 0.0);
        VWB_EXPECT(sample.ecotone_weight >= 0.0 && sample.ecotone_weight <= 1.0);
    }
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
