#include "test_harness.hpp"
#include "../core/world_source.hpp"

#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

using namespace voxel::world_backend;
static_assert(!std::is_copy_assignable_v<WorldSourceDefinition>);
static_assert(!std::is_move_assignable_v<WorldSourceDefinition>);
static_assert(!std::is_copy_assignable_v<WorldSourcePin>);
static_assert(!std::is_move_assignable_v<WorldSourcePin>);
namespace {
WorldSourceDescriptor atlas_descriptor() {
    WorldSourceDescriptor d;
    d.raw_terrain_seed = admit_raw_terrain_seed("  atlas-1492\t");
    d.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("  atlas-1492\t");
    d.revisions.terrain_generator_revision = 7;
    d.revisions.lattice_query_revision = 3;
    d.revisions.cell_center_query_revision = 4;
    d.revisions.surface_column_query_revision = 5;
    return d;
}
NativeCellState stone_override(const CellCoord cell) {
    NativeCellStateInput state; state.cell = cell; state.density = 1.0; state.solid = true;
    state.material = TerrainMaterialId::stone; state.biome = TerrainBiomeId::plains; state.light = {0, 0};
    state.metadata = NativeValue::object({}); state.block_id = NativeBlockIdentity::create("stone");
    state.edit_reason = "source-test"; state.generated = false; state.edited = true;
    return make_native_cell_state(state);
}
std::uint32_t float32_bits(const float value) {
    std::uint32_t result = 0;
    std::memcpy(&result, &value, sizeof(result));
    return result;
}
} // namespace

VWB_TEST(world_source_definition_admits_validated_seed_and_rejects_boundary_errors) {
    const WorldSourceDefinition definition(atlas_descriptor());
    VWB_EXPECT_EQ(std::string("atlas-1492"), definition.admitted_biome_seed().utf8);
    VWB_EXPECT_EQ(std::string("  atlas-1492\t"), definition.raw_terrain_seed().utf8);
    VWB_EXPECT_EQ(7U, definition.revisions().terrain_generator_revision);
    VWB_EXPECT_EQ(3U, definition.revisions().lattice_query_revision);
    VWB_EXPECT_EQ(4U, definition.revisions().cell_center_query_revision);
    VWB_EXPECT_EQ(5U, definition.revisions().surface_column_query_revision);
    VWB_EXPECT_EQ(1.35, definition.constants().cell_size_meters);
    VWB_EXPECT_EQ(11.1, definition.constants().water_level_meters);
    WorldSourceDescriptor invalid = atlas_descriptor(); invalid.admitted_biome_seed.utf8 = "other";
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.raw_terrain_seed.admitted = false;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.raw_terrain_seed.utf8 = "other";
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.revisions.surface_column_query_revision = 0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.revisions.source_schema_revision = 0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.revisions.terrain_generator_revision = 0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.revisions.biome_region_field_revision = 0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.revisions.lattice_query_revision = 0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.revisions.cell_center_query_revision = 0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.revisions.biome_region_field_revision = 99;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.constants.cell_size_meters = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.constants.cell_size_meters = 0.0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.constants.cell_center_offset_cells = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.constants.cell_center_offset_cells = 0.0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.constants.cell_center_offset_cells = 1.0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.constants.minimum_surface_meters = 121.0;
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.constants.minimum_surface_meters = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.constants.maximum_surface_meters = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
    invalid = atlas_descriptor(); invalid.constants.water_level_meters = std::numeric_limits<double>::quiet_NaN();
    VWB_EXPECT_THROW(std::invalid_argument, WorldSourceDefinition{invalid});
}

VWB_TEST(world_source_raw_terrain_seed_utf8_admission_preserves_unicode_scalars_and_rejects_malformed_sequences) {
    const AdmittedTerrainSeed ascii = admit_raw_terrain_seed(std::string("A\0B", 3));
    const AdmittedTerrainSeed two = admit_raw_terrain_seed(std::string("\xC2\xA2", 2));
    const AdmittedTerrainSeed three = admit_raw_terrain_seed(std::string("\xE2\x82\xAC", 3));
    const AdmittedTerrainSeed three_low_boundary = admit_raw_terrain_seed(std::string("\xE0\xA0\x80", 3));
    const AdmittedTerrainSeed three_high_boundary = admit_raw_terrain_seed(std::string("\xED\x9F\xBF", 3));
    const AdmittedTerrainSeed four = admit_raw_terrain_seed(std::string("\xF0\x9F\x98\x80", 4));
    const AdmittedTerrainSeed four_low_boundary = admit_raw_terrain_seed(std::string("\xF0\x90\x80\x80", 4));
    const AdmittedTerrainSeed four_high_boundary = admit_raw_terrain_seed(std::string("\xF4\x8F\xBF\xBF", 4));
    VWB_EXPECT_EQ(std::vector<std::uint32_t>({'A', 0, 'B'}), ascii.code_points);
    VWB_EXPECT_EQ(std::vector<std::uint32_t>({0x00a2U}), two.code_points);
    VWB_EXPECT_EQ(std::vector<std::uint32_t>({0x20acU}), three.code_points);
    VWB_EXPECT_EQ(std::vector<std::uint32_t>({0x0800U}), three_low_boundary.code_points);
    VWB_EXPECT_EQ(std::vector<std::uint32_t>({0xd7ffU}), three_high_boundary.code_points);
    VWB_EXPECT_EQ(std::vector<std::uint32_t>({0x1f600U}), four.code_points);
    VWB_EXPECT_EQ(std::vector<std::uint32_t>({0x10000U}), four_low_boundary.code_points);
    VWB_EXPECT_EQ(std::vector<std::uint32_t>({0x10ffffU}), four_high_boundary.code_points);
    VWB_EXPECT(ascii == admit_raw_terrain_seed(std::string("A\0B", 3)));
    VWB_EXPECT(!(ascii == two));
    AdmittedTerrainSeed different_utf8 = ascii; different_utf8.utf8 = "A";
    VWB_EXPECT(!(ascii == different_utf8));
    AdmittedTerrainSeed different_admission = ascii; different_admission.admitted = false;
    VWB_EXPECT(!(ascii == different_admission));
    VWB_EXPECT_THROW(std::invalid_argument, validate_admitted_raw_terrain_seed({}, "", false));
    VWB_EXPECT_EQ(admit_raw_terrain_seed(""), validate_admitted_raw_terrain_seed({}, "", true));
    VWB_EXPECT_THROW(std::invalid_argument, validate_admitted_raw_terrain_seed({0x00e9U}, "e", true));
    const std::vector<std::string> malformed = {
        std::string("\x80", 1), std::string("\xc0\x80", 2), std::string("\xc2", 1), std::string("\xc2\x20", 2),
        std::string("\xe0", 1), std::string("\xe0\xa0", 2), std::string("\xe0\x20\x80", 3), std::string("\xe0\xa0\x20", 3),
        std::string("\xe0\x80\x80", 3), std::string("\xed\xa0\x80", 3),
        std::string("\xf0", 1), std::string("\xf0\x90", 2), std::string("\xf0\x20\x80\x80", 4),
        std::string("\xf0\x90\x20\x80", 4), std::string("\xf0\x90\x80\x20", 4), std::string("\xf0\x80\x80\x80", 4),
        std::string("\xf4\x90\x80\x80", 4), std::string("\xf5\x80\x80\x80", 4)
    };
    for (const std::string &value : malformed) VWB_EXPECT_THROW(std::invalid_argument, admit_raw_terrain_seed(value));
}

VWB_TEST(world_source_definition_digest_tracks_physical_facts_not_request_authority) {
    const WorldSourceDefinition first(atlas_descriptor()); const WorldSourceDefinition same(atlas_descriptor());
    VWB_EXPECT_EQ(first.physical_content_identity(), same.physical_content_identity());
    VWB_EXPECT_EQ(first.physical_content_identity().digest_hex(), sha256_hex(first.physical_content_identity().digest));
    WorldSourceDescriptor changed = atlas_descriptor(); changed.constants.cell_size_meters = 1.4;
    VWB_EXPECT(!(WorldSourceDefinition(changed).physical_content_identity() == first.physical_content_identity()));
    changed = atlas_descriptor(); changed.revisions.lattice_query_revision = 8;
    VWB_EXPECT(!(WorldSourceDefinition(changed).physical_content_identity() == first.physical_content_identity()));
    changed = atlas_descriptor(); changed.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("atlas-1493");
    VWB_EXPECT(!(WorldSourceDefinition(changed).physical_content_identity() == first.physical_content_identity()));
    changed = atlas_descriptor(); changed.raw_terrain_seed = admit_raw_terrain_seed("atlas-1492");
    VWB_EXPECT(!(WorldSourceDefinition(changed).physical_content_identity() == first.physical_content_identity()));
    changed = atlas_descriptor(); changed.constants.water_level_meters = 11.2;
    VWB_EXPECT(!(WorldSourceDefinition(changed).physical_content_identity() == first.physical_content_identity()));
    WorldDeltaStore store;
    WorldSourceRequestScope one{WorldSourcePin(first, store.pin()), {}}; WorldSourceRequestScope two{WorldSourcePin(first, store.pin()), {}};
    one.authority.owner.value = 11; one.authority.cancellation.value = 12; two.authority.owner.value = 27; two.authority.cancellation.value = 28;
    VWB_EXPECT_EQ(one.pin.physical_content_identity(), two.pin.physical_content_identity());
}

VWB_TEST(world_source_pin_is_immutable_at_its_delta_revision) {
    WorldDeltaStore store; const WorldSourceDefinition definition(atlas_descriptor()); const WorldSourcePin before(definition, store.pin());
    WorldTypedCellTransaction tx; tx.transaction_id = "source-pin-edit"; tx.expected_revision = 0;
    tx.operations.push_back({NativeCellStateNamespace::durable_terrain, {17, -3, -18}, WorldTypedCellOperationKind::set, stone_override({17, -3, -18})});
    VWB_EXPECT_EQ(1ULL, store.commit_typed_cells(tx).revision);
    const WorldSourcePin after(definition, store.pin());
    VWB_EXPECT_EQ(0ULL, before.terrain_delta_revision()); VWB_EXPECT_EQ(1ULL, after.terrain_delta_revision());
    VWB_EXPECT(!before.deltas().effective_typed_cell_at({17, -3, -18}).has_value()); VWB_EXPECT(after.deltas().effective_typed_cell_at({17, -3, -18}).has_value());
    VWB_EXPECT(!(before.physical_content_identity() == after.physical_content_identity()));
    VWB_EXPECT_EQ(definition.physical_content_identity(), after.definition().physical_content_identity());
}

VWB_TEST(world_source_query_types_keep_lattice_center_column_and_intent_distinct) {
    const WorldLatticeQuery lattice{{4, 5, 6}, WorldQueryIntent::terrain_mesh}; const WorldCellCenterQuery center{{4, 5, 6}, WorldQueryIntent::gameplay}; const WorldSurfaceColumnQuery column{4, 6, WorldQueryIntent::terrain_collision};
    VWB_EXPECT_EQ(WorldQueryKind::lattice_cell, query_kind(lattice)); VWB_EXPECT_EQ(WorldQueryKind::cell_center, query_kind(center)); VWB_EXPECT_EQ(WorldQueryKind::surface_column, query_kind(column));
    const WorldSourceDefinition definition(atlas_descriptor());
    VWB_EXPECT_EQ(3U, query_revision(definition, lattice)); VWB_EXPECT_EQ(4U, query_revision(definition, center)); VWB_EXPECT_EQ(5U, query_revision(definition, column));
    validate_world_query(lattice); validate_world_query(center); validate_world_query(column); VWB_EXPECT(lattice.coordinate == center.coordinate);
    WorldLatticeQuery invalid{{}, static_cast<WorldQueryIntent>(99)}; VWB_EXPECT_THROW(std::invalid_argument, validate_world_query(invalid));
    WorldCellCenterQuery invalid_center{{}, static_cast<WorldQueryIntent>(99)};
    VWB_EXPECT_THROW(std::invalid_argument, validate_world_query(invalid_center));
    WorldSurfaceColumnQuery invalid_column{0, 0, static_cast<WorldQueryIntent>(99)};
    VWB_EXPECT_THROW(std::invalid_argument, validate_world_query(invalid_column));
}

VWB_TEST(world_source_resolves_lattice_center_and_column_at_their_godot_float32_boundaries) {
    const WorldSourceDefinition definition(atlas_descriptor());
    const WorldLatticeQuery lattice{{-1, 17, 16777217}, WorldQueryIntent::terrain_mesh};
    const WorldCellCenterQuery center{{-1, 17, 16777217}, WorldQueryIntent::gameplay};
    const WorldSurfaceColumnQuery column{16777217, -1, WorldQueryIntent::terrain_collision};

    const WorldResolvedLatticeQuery lattice_result = resolve_world_query(definition, lattice);
    const WorldResolvedCellCenterQuery center_result = resolve_world_query(definition, center);
    const WorldResolvedSurfaceColumnQuery column_result = resolve_world_query(definition, column);

    VWB_EXPECT_EQ(lattice.coordinate, lattice_result.lattice_cell);
    VWB_EXPECT_EQ(center.coordinate, center_result.cell);
    VWB_EXPECT_EQ(lattice.intent, lattice_result.intent);
    VWB_EXPECT_EQ(center.intent, center_result.intent);
    VWB_EXPECT_EQ(column.intent, column_result.intent);
    // Exact binary32 results distinguish `Vector3(cell) * CELL` from the
    // center scalar expression before Vector3's storage boundary.
    VWB_EXPECT_EQ(0xbfaccccdu, float32_bits(lattice_result.lattice_position.x));
    VWB_EXPECT_EQ(0x41b7999au, float32_bits(lattice_result.lattice_position.y));
    VWB_EXPECT_EQ(0x4baccccdu, float32_bits(lattice_result.lattice_position.z));
    VWB_EXPECT_EQ(0xbf2ccccdu, float32_bits(center_result.center_position.x));
    VWB_EXPECT_EQ(0x41bd0000u, float32_bits(center_result.center_position.y));
    VWB_EXPECT_EQ(0x4bacccceu, float32_bits(center_result.center_position.z));
    VWB_EXPECT(float32_bits(lattice_result.lattice_position.z) != float32_bits(center_result.center_position.z));

    // The column's X/Z anchor is lattice-based.  It deliberately has no Y
    // field, so callers cannot reinterpret it as a Y=0 cell sample.
    VWB_EXPECT_EQ(16777217, column_result.lattice_x);
    VWB_EXPECT_EQ(-1, column_result.lattice_z);
    VWB_EXPECT_EQ(0x4baccccdu, float32_bits(column_result.lattice_position.x));
    VWB_EXPECT_EQ(0xbfaccccdu, float32_bits(column_result.lattice_position.z));
}

VWB_TEST(world_source_query_resolution_rejects_invalid_intents_before_coordinate_conversion) {
    const WorldSourceDefinition definition(atlas_descriptor());
    const auto invalid_intent = static_cast<WorldQueryIntent>(99);
    const WorldLatticeQuery invalid_lattice{{-1, -2, -3}, invalid_intent};
    const WorldCellCenterQuery invalid_center{{-1, -2, -3}, invalid_intent};
    const WorldSurfaceColumnQuery invalid_column{-1, -3, invalid_intent};
    VWB_EXPECT_THROW(std::invalid_argument, resolve_world_query(definition, invalid_lattice));
    VWB_EXPECT_THROW(std::invalid_argument, resolve_world_query(definition, invalid_center));
    VWB_EXPECT_THROW(std::invalid_argument, resolve_world_query(definition, invalid_column));
}
