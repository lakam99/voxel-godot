#include "test_harness.hpp"

#include "../core/native_natural_terrain_source.hpp"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

using namespace voxel::world_backend;
static_assert(!std::is_convertible_v<NativeCellState, NativeLatticeNumericFacts>);
static_assert(!std::is_convertible_v<NativeCellState, NativeSurfaceColumnFacts>);

namespace {
WorldSourceDefinition atlas_definition() {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    return WorldSourceDefinition(std::move(descriptor));
}
bool near(const double left, const double right, const double tolerance = 1.0e-12) { return std::abs(left - right) <= tolerance; }
std::uint32_t bits(const float value) { std::uint32_t output = 0; std::memcpy(&output, &value, sizeof(output)); return output; }
std::uint32_t fnv(const std::vector<std::uint32_t> &code_points) {
    std::uint32_t value = 2166136261U;
    for (const std::uint32_t code_point : code_points) { value ^= code_point; value *= 16777619U; }
    return value;
}
void append_ascii(std::vector<std::uint32_t> &target, const std::string &value) {
    for (const unsigned char character : value) target.push_back(character);
}
std::int32_t script_floor_divide(const std::int32_t value, const std::int32_t divisor) {
    return static_cast<std::int32_t>(std::floor(static_cast<float>(value) / static_cast<float>(divisor)));
}
double lava_salt01(const AdmittedTerrainSeed &seed, const CellCoord cell, const bool incorrectly_utf8_bytes) {
    std::vector<std::uint32_t> key = seed.code_points;
    key.push_back(':'); append_ascii(key, "terrain-volume-lava:");
    if (incorrectly_utf8_bytes) for (const unsigned char byte : seed.utf8) key.push_back(byte);
    else key.insert(key.end(), seed.code_points.begin(), seed.code_points.end());
    append_ascii(key, ":" + std::to_string(script_floor_divide(cell.x, 4)) + "," + std::to_string(script_floor_divide(cell.y, 2)) + "," + std::to_string(script_floor_divide(cell.z, 4)));
    return static_cast<double>(fnv(key) % 100000U) / 100000.0;
}
} // namespace

VWB_TEST(native_natural_terrain_rejects_unmigrated_shaping_input) {
    const WorldSourceDefinition definition = atlas_definition();
    for (const NativeTerrainShapingInput input : {NativeTerrainShapingInput::generated_town_profiles_present, NativeTerrainShapingInput::generated_site_profiles_present}) {
        try { const NativeNaturalTerrainSource unused(definition, {input}); (void)unused; VWB_EXPECT(false); }
        catch (const NativeNaturalTerrainUnsupported &error) { VWB_EXPECT_EQ(input, error.input()); }
    }
    const NativeNaturalTerrainSource source(definition);
    VWB_EXPECT_EQ(definition.physical_content_identity(), source.definition().physical_content_identity());
}

// These fixed natural-only cases were captured by
// scripts/testing/native_world/N3CoverageOracle.gd using
// WorldGenerationSystem.generate_cell_state(), then kept here as C++ goldens.
// The test does not search for values at runtime.
VWB_TEST(native_natural_terrain_matches_gdscript_fixed_biome_material_fluid_and_light_goldens) {
    const NativeNaturalTerrainSource source(atlas_definition());
    struct Golden { CellCoord cell; TerrainBiomeId biome; TerrainMaterialId material; TerrainFluidId fluid; bool solid; unsigned sky; };
    const std::vector<Golden> goldens = {
        {{-30208, 8, -65536}, TerrainBiomeId::beach, TerrainMaterialId::sand, TerrainFluidId::none, true, 0},
        {{-30208, 6, -65536}, TerrainBiomeId::beach, TerrainMaterialId::sand, TerrainFluidId::none, true, 0},
        {{-53504, 10, -57600}, TerrainBiomeId::desert, TerrainMaterialId::sand, TerrainFluidId::none, true, 0},
        {{-53504, 9, -57600}, TerrainBiomeId::desert, TerrainMaterialId::sand, TerrainFluidId::none, true, 0},
        {{26880, 11, -48640}, TerrainBiomeId::swamp, TerrainMaterialId::mud, TerrainFluidId::none, true, 0},
        {{26880, 9, -48640}, TerrainBiomeId::swamp, TerrainMaterialId::mud, TerrainFluidId::none, true, 0},
        {{-65536, 20, -65536}, TerrainBiomeId::snow, TerrainMaterialId::snow, TerrainFluidId::none, true, 0},
        {{-65536, 18, -65536}, TerrainBiomeId::snow, TerrainMaterialId::snow, TerrainFluidId::none, true, 0},
        {{-57600, 22, -65536}, TerrainBiomeId::tundra, TerrainMaterialId::stone, TerrainFluidId::none, true, 0},
        {{-57600, 20, -65536}, TerrainBiomeId::tundra, TerrainMaterialId::dirt, TerrainFluidId::none, true, 0},
        {{-35072, 19, -65536}, TerrainBiomeId::forest, TerrainMaterialId::grass, TerrainFluidId::none, true, 0},
        {{-35072, 17, -65536}, TerrainBiomeId::forest, TerrainMaterialId::dirt, TerrainFluidId::none, true, 0},
        {{-22016, 12, -65536}, TerrainBiomeId::plains, TerrainMaterialId::grass, TerrainFluidId::none, true, 0},
        {{62208, 21, -65536}, TerrainBiomeId::savanna, TerrainMaterialId::grass, TerrainFluidId::none, true, 0},
        {{-44288, 13, -65536}, TerrainBiomeId::taiga, TerrainMaterialId::grass, TerrainFluidId::none, true, 0},
        {{15104, 7, -65536}, TerrainBiomeId::ocean, TerrainMaterialId::grass, TerrainFluidId::none, true, 0},
        {{-56, -56, -128}, TerrainBiomeId::underground_air, TerrainMaterialId::lava, TerrainFluidId::lava, false, 0},
        {{-125, 3, -128}, TerrainBiomeId::underground_air, TerrainMaterialId::water, TerrainFluidId::water, false, 0},
        {{-128, -62, -128}, TerrainBiomeId::deep_underground, TerrainMaterialId::copper_ore, TerrainFluidId::none, true, 0},
        {{-43, -59, -128}, TerrainBiomeId::deep_underground, TerrainMaterialId::iron_ore, TerrainFluidId::none, true, 0},
        {{-128, -59, -128}, TerrainBiomeId::deep_underground, TerrainMaterialId::deep_stone, TerrainFluidId::none, true, 0},
        {{9, 9, -128}, TerrainBiomeId::beach, TerrainMaterialId::air, TerrainFluidId::none, false, 15},
        {{-127, 16, -128}, TerrainBiomeId::underground_air, TerrainMaterialId::air, TerrainFluidId::none, false, 0},
        {{-128, 18, -128}, TerrainBiomeId::underground, TerrainMaterialId::stone, TerrainFluidId::none, true, 0},
        {{-128, -26, -128}, TerrainBiomeId::underground_air, TerrainMaterialId::air, TerrainFluidId::none, false, 0},
    };
    for (const Golden &golden : goldens) {
        const NativeCellState actual = source.sample_cell_state({golden.cell, WorldQueryIntent::gameplay});
        VWB_EXPECT_EQ(golden.biome, actual.biome); VWB_EXPECT_EQ(golden.material, actual.material); VWB_EXPECT_EQ(golden.fluid, actual.fluid);
        VWB_EXPECT_EQ(golden.solid, actual.solid); VWB_EXPECT_EQ(golden.sky, static_cast<unsigned>(actual.light.sky));
    }
}

VWB_TEST(native_natural_terrain_rejects_float32_lattice_positions_that_leave_the_int32_cell_domain) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    descriptor.constants.cell_size_meters = 1.0e300;
    const NativeNaturalTerrainSource source(WorldSourceDefinition(std::move(descriptor)));
    VWB_EXPECT_THROW(std::invalid_argument, source.sample_lattice_numeric({{1, 0, 0}, WorldQueryIntent::terrain_mesh}));
}

VWB_TEST(native_natural_terrain_checks_int32_lattice_domain_after_float32_rounding) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    descriptor.constants.cell_size_meters = 1.0;
    const NativeNaturalTerrainSource source(WorldSourceDefinition(std::move(descriptor)));
    VWB_EXPECT_THROW(std::invalid_argument, source.sample_lattice_numeric({{std::numeric_limits<std::int32_t>::max(), 0, 0}, WorldQueryIntent::terrain_mesh}));
    const auto minimum = source.sample_lattice_numeric({{std::numeric_limits<std::int32_t>::min(), 0, 0}, WorldQueryIntent::terrain_mesh});
    VWB_EXPECT_EQ(std::numeric_limits<std::int32_t>::min(), minimum.lattice_cell.x);
    WorldSourceDescriptor subnormal;
    subnormal.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    subnormal.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    subnormal.constants.cell_size_meters = 1.0e-45;
    const NativeNaturalTerrainSource subnormal_source(WorldSourceDefinition(std::move(subnormal)));
    VWB_EXPECT_THROW(std::invalid_argument, subnormal_source.sample_lattice_numeric({{std::numeric_limits<std::int32_t>::min(), 0, 0}, WorldQueryIntent::terrain_mesh}));
}

VWB_TEST(native_natural_terrain_preserves_bottom_density_and_surface_water_precedence) {
    const NativeNaturalTerrainSource source(atlas_definition());
    const auto lattice_air = source.sample_lattice_numeric({{0, 64, 0}, WorldQueryIntent::terrain_mesh});
    const auto lattice_bottom = source.sample_lattice_numeric({{0, -64, 0}, WorldQueryIntent::terrain_mesh});
    const NativeCellState center_bottom = source.sample_cell_state({{0, -65, 0}, WorldQueryIntent::gameplay});
    VWB_EXPECT(!lattice_air.underground_air_void);
    VWB_EXPECT(lattice_bottom.density > 0.0); VWB_EXPECT(center_bottom.density > 0.0);
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    descriptor.constants.water_level_meters = 1000.0;
    const NativeNaturalTerrainSource flooded(WorldSourceDefinition(std::move(descriptor)));
    const NativeCellState water = flooded.sample_cell_state({{0, 64, 0}, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ(TerrainMaterialId::water, water.material); VWB_EXPECT_EQ(TerrainFluidId::water, water.fluid);
    const NativeCellState classified_water = flooded.sample_cell_state({{-35072, 64, -65536}, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ(TerrainBiomeId::ocean, classified_water.biome); VWB_EXPECT_EQ(TerrainMaterialId::water, classified_water.material);
    VWB_EXPECT_EQ(15U, static_cast<unsigned>(classified_water.light.sky));
}

// Fixed GDScript `generate_cell_state()` cases captured by N3CoverageOracle:
// shallow air, a deep non-lava hash that falls through to aquifer water, an
// above-aquifer void, and a deep desert void that must not become aquifer.
VWB_TEST(native_natural_terrain_matches_gdscript_underground_fluid_negative_goldens) {
    const NativeNaturalTerrainSource source(atlas_definition());
    const NativeCellState shallow = source.sample_cell_state({{-127, 16, -128}, WorldQueryIntent::gameplay});
    const NativeCellState lava_hash_false = source.sample_cell_state({{-62, -55, -128}, WorldQueryIntent::gameplay});
    const NativeCellState above_aquifer = source.sample_cell_state({{-128, 7, -128}, WorldQueryIntent::gameplay});
    const NativeCellState desert = source.sample_cell_state({{-53543, -37, -57728}, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ(TerrainMaterialId::air, shallow.material); VWB_EXPECT_EQ(TerrainFluidId::none, shallow.fluid);
    VWB_EXPECT_EQ(TerrainMaterialId::water, lava_hash_false.material); VWB_EXPECT_EQ(TerrainFluidId::water, lava_hash_false.fluid);
    VWB_EXPECT_EQ(TerrainMaterialId::air, above_aquifer.material); VWB_EXPECT_EQ(TerrainFluidId::none, above_aquifer.fluid);
    VWB_EXPECT_EQ(TerrainBiomeId::underground_air, desert.biome); VWB_EXPECT_EQ(TerrainMaterialId::air, desert.material); VWB_EXPECT_EQ(TerrainFluidId::none, desert.fluid);
}

VWB_TEST(native_natural_terrain_keeps_lava_depth_threshold_for_a_nondefault_pinned_source) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    descriptor.constants.world_bottom_cell_y = -60;
    descriptor.constants.minimum_surface_meters = -30.0;
    descriptor.constants.maximum_surface_meters = -30.0;
    const NativeNaturalTerrainSource source(WorldSourceDefinition(std::move(descriptor)));
    const NativeCellState state = source.sample_cell_state({{-62, -55, -128}, WorldQueryIntent::gameplay});
    VWB_EXPECT(state.fluid != TerrainFluidId::lava);
}

VWB_TEST(native_natural_terrain_query_types_do_not_collapse_to_cell_state) {
    const NativeNaturalTerrainSource source(atlas_definition());
    const CellCoord cell{-20, 13, -2};
    const auto lattice = source.sample_lattice_numeric({cell, WorldQueryIntent::terrain_mesh});
    const auto state = source.sample_cell_state({cell, WorldQueryIntent::gameplay});
    const auto column = source.sample_surface_column({cell.x, cell.z, WorldQueryIntent::terrain_collision});
    VWB_EXPECT_EQ(cell, lattice.lattice_cell); VWB_EXPECT_EQ(cell, state.cell);
    VWB_EXPECT_EQ(cell.x, column.cell_x); VWB_EXPECT_EQ(cell.z, column.cell_z);
    VWB_EXPECT(lattice.density != state.density);
    VWB_EXPECT(near(column.reference_surface_y, column.deformed_surface_y));
}

// GDScript goldens were captured from the existing
// scripts/testing/native_world/N2LatticeSourceOracle.gd.  Its source invokes
// WorldGenerationSystem's current natural (no town/site profile) rule; this
// test is deliberately not a self-comparison with the native implementation.
VWB_TEST(native_natural_terrain_matches_gdscript_natural_lattice_goldens) {
    const NativeNaturalTerrainSource source(atlas_definition());
    const auto surface = source.sample_lattice_numeric({{-20, 13, -2}, WorldQueryIntent::terrain_mesh});
    const auto cave_a = source.sample_lattice_numeric({{-33, -2, -5}, WorldQueryIntent::terrain_mesh});
    const auto cave_b = source.sample_lattice_numeric({{-32, -2, -5}, WorldQueryIntent::terrain_mesh});
    VWB_EXPECT(near(surface.density, 0.35099885559082367)); VWB_EXPECT(!surface.underground_air_void);
    VWB_EXPECT(near(cave_a.density, -0.6017665929014142)); VWB_EXPECT(cave_a.underground_air_void);
    VWB_EXPECT(near(cave_b.density, -0.35286612593816424)); VWB_EXPECT(cave_b.underground_air_void);
    const auto resolved = resolve_world_query(source.definition(), WorldLatticeQuery{{-20, 13, -2}, WorldQueryIntent::terrain_mesh});
    VWB_EXPECT_EQ(0xc1d80000U, bits(resolved.lattice_position.x));
}

VWB_TEST(native_natural_terrain_uses_raw_whitespace_and_unicode_terrain_seed_not_biome_admission) {
    auto definition_for = [](const std::string &raw) {
        WorldSourceDescriptor descriptor;
        descriptor.raw_terrain_seed = admit_raw_terrain_seed(raw);
        descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(raw);
        descriptor.revisions.terrain_generator_revision = 8;
        descriptor.revisions.lattice_query_revision = 6;
        descriptor.revisions.cell_center_query_revision = 7;
        descriptor.revisions.surface_column_query_revision = 8;
        return WorldSourceDefinition(std::move(descriptor));
    };
    const NativeNaturalTerrainSource trimmed(definition_for("atlas-1492"));
    const NativeNaturalTerrainSource spaced(definition_for(" atlas-1492 "));
    const NativeNaturalTerrainSource unicode(definition_for("caf\xC3\xA9"));
    const NativeNaturalTerrainSource byte_mojibake(definition_for("caf\xC3\x83\xC2\xA9"));
    VWB_EXPECT_EQ(trimmed.definition().admitted_biome_seed(), spaced.definition().admitted_biome_seed());
    VWB_EXPECT(!(trimmed.definition().physical_content_identity() == spaced.definition().physical_content_identity()));
    VWB_EXPECT_EQ(std::vector<std::uint32_t>({'c', 'a', 'f', 0x00e9U}), unicode.definition().raw_terrain_seed().code_points);
    bool whitespace_changed = false; bool unicode_changed = false;
    for (std::int32_t x = -48; x <= 48; x += 12) {
        const WorldSurfaceColumnQuery query{x, 17, WorldQueryIntent::gameplay};
        whitespace_changed = whitespace_changed || !near(trimmed.sample_surface_column(query).reference_surface_y, spaced.sample_surface_column(query).reference_surface_y);
        unicode_changed = unicode_changed || !near(unicode.sample_surface_column(query).reference_surface_y, byte_mojibake.sample_surface_column(query).reference_surface_y);
    }
    VWB_EXPECT(whitespace_changed); VWB_EXPECT(unicode_changed);
}

VWB_TEST(native_natural_terrain_consumes_pinned_water_and_world_bottom_constants) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1492");
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    descriptor.constants.world_bottom_cell_y = -10;
    descriptor.constants.water_level_meters = 1000.0;
    const NativeNaturalTerrainSource source(WorldSourceDefinition(std::move(descriptor)));
    const NativeCellState floor = source.sample_cell_state({{0, -9, 0}, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ(TerrainMaterialId::bedrock, floor.material);
    VWB_EXPECT_EQ(TerrainBiomeId::ocean, source.sample_surface_biome({0, 0, WorldQueryIntent::gameplay}));
}

VWB_TEST(native_natural_terrain_uses_unicode_scalars_inside_lava_salt_payload) {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("caf\xC3\xA9");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("caf\xC3\xA9");
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    const NativeNaturalTerrainSource source(WorldSourceDefinition(std::move(descriptor)));
    bool found_unicode_only_lava = false;
    // y=-55 is the first production lava band.  Filter with the independent
    // FNV oracle before sampling, so this test covers a bounded set of actual
    // generated cave cells rather than depending on a broad random search.
    for (std::int32_t z = -128; z <= 128 && !found_unicode_only_lava; ++z) {
        for (std::int32_t x = -128; x <= 128 && !found_unicode_only_lava; ++x) {
            const CellCoord cell{x, -55, z};
            const double unicode_salt = lava_salt01(source.definition().raw_terrain_seed(), cell, false);
            const double byte_salt = lava_salt01(source.definition().raw_terrain_seed(), cell, true);
            if (unicode_salt <= 0.82 || byte_salt > 0.82) continue;
            found_unicode_only_lava = source.sample_cell_state({cell, WorldQueryIntent::gameplay}).fluid == TerrainFluidId::lava;
        }
    }
    VWB_EXPECT(found_unicode_only_lava);
}

VWB_TEST(native_natural_terrain_matches_gdscript_cell_state_precedence) {
    const NativeNaturalTerrainSource source(atlas_definition());
    const NativeCellState state = source.sample_cell_state({{-20, 12, -2}, WorldQueryIntent::gameplay});
    const NativeCellState floor = source.sample_cell_state({{0, -64, 0}, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ(TerrainMaterialId::mud, state.material);
    VWB_EXPECT_EQ(TerrainFluidId::none, state.fluid);
    VWB_EXPECT_EQ(TerrainBiomeId::swamp, state.biome);
    VWB_EXPECT(state.generated && !state.edited); VWB_EXPECT_EQ(0U, static_cast<unsigned>(state.light.sky));
    VWB_EXPECT_EQ(TerrainMaterialId::bedrock, floor.material);
    VWB_EXPECT_EQ(TerrainBiomeId::deep_underground, floor.biome);
    VWB_EXPECT(floor.solid && floor.density >= 0.0); VWB_EXPECT_EQ(0U, static_cast<unsigned>(floor.light.sky));
}
