#include "test_harness.hpp"
#include "../core/world_source.hpp"

#include <limits>
#include <stdexcept>
#include <string>
#include <type_traits>

using namespace voxel::world_backend;
static_assert(!std::is_copy_assignable_v<WorldSourceDefinition>);
static_assert(!std::is_move_assignable_v<WorldSourceDefinition>);
static_assert(!std::is_copy_assignable_v<WorldSourcePin>);
static_assert(!std::is_move_assignable_v<WorldSourcePin>);
namespace {
WorldSourceDescriptor atlas_descriptor() {
    WorldSourceDescriptor d;
    d.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("  atlas-1492\t");
    d.revisions.terrain_generator_revision = 7;
    d.revisions.lattice_query_revision = 3;
    d.revisions.cell_center_query_revision = 4;
    d.revisions.surface_column_query_revision = 5;
    return d;
}
WorldDeltaState stone_override() {
    WorldDeltaState state; state.density = 1.0; state.solid = true; state.material = TerrainMaterialId::stone; state.resolved_biome = TerrainBiomeId::plains; return state;
}
} // namespace

VWB_TEST(world_source_definition_admits_validated_seed_and_rejects_boundary_errors) {
    const WorldSourceDefinition definition(atlas_descriptor());
    VWB_EXPECT_EQ(std::string("atlas-1492"), definition.admitted_biome_seed().utf8);
    VWB_EXPECT_EQ(7U, definition.revisions().terrain_generator_revision);
    VWB_EXPECT_EQ(3U, definition.revisions().lattice_query_revision);
    VWB_EXPECT_EQ(4U, definition.revisions().cell_center_query_revision);
    VWB_EXPECT_EQ(5U, definition.revisions().surface_column_query_revision);
    VWB_EXPECT_EQ(1.35, definition.constants().cell_size_meters);
    WorldSourceDescriptor invalid = atlas_descriptor(); invalid.admitted_biome_seed.utf8 = "other";
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
    WorldDeltaStore store;
    WorldSourceRequestScope one{WorldSourcePin(first, store.pin()), {}}; WorldSourceRequestScope two{WorldSourcePin(first, store.pin()), {}};
    one.authority.owner.value = 11; one.authority.cancellation.value = 12; two.authority.owner.value = 27; two.authority.cancellation.value = 28;
    VWB_EXPECT_EQ(one.pin.physical_content_identity(), two.pin.physical_content_identity());
}

VWB_TEST(world_source_pin_is_immutable_at_its_delta_revision) {
    WorldDeltaStore store; const WorldSourceDefinition definition(atlas_descriptor()); const WorldSourcePin before(definition, store.pin());
    WorldDeltaTransaction tx; tx.transaction_id = "source-pin-edit"; tx.expected_revision = 0;
    tx.operations.push_back({WorldDeltaNamespace::terrain_override, {17, -3, -18}, WorldDeltaOperationKind::set, stone_override()});
    VWB_EXPECT_EQ(1ULL, store.commit(tx).revision);
    const WorldSourcePin after(definition, store.pin());
    VWB_EXPECT_EQ(0ULL, before.terrain_delta_revision()); VWB_EXPECT_EQ(1ULL, after.terrain_delta_revision());
    VWB_EXPECT(!before.deltas().effective_value_at({17, -3, -18}).has_value()); VWB_EXPECT(after.deltas().effective_value_at({17, -3, -18}).has_value());
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
