#include "test_harness.hpp"
#include "../core/native_terrain_shaping_registry.hpp"
#include "../core/world_source.hpp"

#include <algorithm>
#include <cmath>
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
NativeSiteSourcePolicy shaping_policy() {
    NativeSiteSourcePolicy policy;
    policy.engine_version_utf8 = "4.6.1.stable.official.14d19694e";
    policy.ordinary_region_cells = 140;
    policy.ordinary_spawn_chance = 0.08;
    return policy;
}
std::vector<NativeTerrainShapingPagePin> ready_shaping(
    NativeTerrainShapingRegistry &registry, const NativeTerrainPageKey page) {
    NativeTerrainShapingRegistryBatch batch; batch.expected_revision = registry.revision();
    std::vector<NativeSiteSourceRegionKey> unresolved;
    const std::vector<NativeTerrainPageKey> dependencies =
        world_effective_shaping_dependencies(registry.definition(), page);
    for (const NativeTerrainPageKey dependency : dependencies) {
        for (const NativeSiteSourceRegionKey region : registry.pin_page(dependency).unresolved_dependencies()) {
            if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end()) unresolved.push_back(region);
        }
    }
    for (const NativeSiteSourceRegionKey region : unresolved) {
        NativeSiteSourceResolution resolution; resolution.region = region;
        resolution.kind = NativeSiteSourceResolutionKind::absent;
        resolution.request_identity = registry.source_request_identity(region);
        resolution.worker_source_key.assign(64, 'a'); resolution.reason_code = "ordinary_structure_overlap";
        batch.resolutions.push_back(std::move(resolution));
    }
    if (!batch.resolutions.empty()) (void)registry.apply(batch);
    std::vector<NativeTerrainShapingPagePin> result;
    for (const NativeTerrainPageKey dependency : dependencies) result.push_back(registry.pin_page(dependency));
    return result;
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
    WorldDeltaStore store; NativeTerrainShapingRegistry registry(first, shaping_policy());
    const auto shaping = ready_shaping(registry, {0, 0});
    WorldSourceRequestScope one{WorldSourcePin(first, store.pin(), {0, 0}, shaping), {}};
    WorldSourceRequestScope two{WorldSourcePin(first, store.pin(), {0, 0}, shaping), {}};
    one.authority.owner.value = 11; one.authority.cancellation.value = 12; two.authority.owner.value = 27; two.authority.cancellation.value = 28;
    VWB_EXPECT_EQ(one.pin.physical_content_identity(), two.pin.physical_content_identity());
}

VWB_TEST(world_source_pin_is_immutable_at_its_delta_revision) {
    WorldDeltaStore store; const WorldSourceDefinition definition(atlas_descriptor());
    NativeTerrainShapingRegistry registry(definition, shaping_policy());
    const auto shaping = ready_shaping(registry, {-1, -1});
    const WorldSourcePin before(definition, store.pin(), {-1, -1}, shaping);
    WorldTypedCellTransaction tx; tx.transaction_id = "source-pin-edit"; tx.expected_revision = 0;
    tx.operations.push_back({NativeCellStateNamespace::durable_terrain, {-17, -3, -18}, WorldTypedCellOperationKind::set, stone_override({-17, -3, -18})});
    VWB_EXPECT_EQ(1ULL, store.commit_typed_cells(tx).revision);
    const WorldSourcePin after(definition, store.pin(), {-1, -1}, shaping);
    VWB_EXPECT_EQ(0ULL, before.terrain_delta_revision()); VWB_EXPECT_EQ(1ULL, after.terrain_delta_revision());
    VWB_EXPECT(!before.deltas().effective_typed_cell_at({-17, -3, -18}).has_value()); VWB_EXPECT(after.deltas().effective_typed_cell_at({-17, -3, -18}).has_value());
    VWB_EXPECT(!(before.physical_content_identity() == after.physical_content_identity()));
    VWB_EXPECT_EQ(definition.physical_content_identity(), after.definition().physical_content_identity());
}

VWB_TEST(world_source_page_pin_identity_tracks_only_local_typed_physical_content) {
    const WorldSourceDefinition definition(atlas_descriptor());
    NativeTerrainShapingRegistry registry(definition, shaping_policy());
    const auto shaping = ready_shaping(registry, {-2, -3});
    for (const auto &page : shaping) VWB_EXPECT_EQ(NativeTerrainShapingPageReadiness::ready, page.readiness());
    const auto primary = std::find_if(shaping.begin(), shaping.end(), [](const auto &value) {
        return value.page_key() == NativeTerrainPageKey{-2, -3};
    });
    VWB_EXPECT(primary != shaping.end());
    VWB_EXPECT_EQ(-560, primary->snapshot()->page_bounds().x);
    VWB_EXPECT_EQ(-840, primary->snapshot()->page_bounds().z);

    WorldDeltaStore store;
    const WorldSourcePin empty(definition, store.pin(), {-2, -3}, shaping);
    WorldTypedCellTransaction remote; remote.transaction_id = "remote"; remote.expected_revision = 0;
    for (const CellCoord cell : std::vector<CellCoord>{{0, 4, 0}, {-1000, 4, -840},
             {-560, 4, -1000}, {-560, 4, 0}}) {
        remote.operations.push_back({NativeCellStateNamespace::durable_terrain, cell,
            WorldTypedCellOperationKind::set, stone_override(cell)});
    }
    (void)store.commit_typed_cells(remote);
    const WorldSourcePin after_remote(definition, store.pin(), {-2, -3}, shaping);
    VWB_EXPECT_EQ(empty.physical_content_identity(), after_remote.physical_content_identity());
    VWB_EXPECT_EQ(empty.typed_projection_digest_for_page({-2, -3}),
        after_remote.typed_projection_digest_for_page({-2, -3}));
    VWB_EXPECT(empty.terrain_delta_revision() != after_remote.terrain_delta_revision());

    WorldTypedCellTransaction local; local.transaction_id = "local"; local.expected_revision = 1;
    local.operations.push_back({NativeCellStateNamespace::durable_terrain, {-560, -7, -840},
        WorldTypedCellOperationKind::set, stone_override({-560, -7, -840})});
    (void)store.commit_typed_cells(local);
    const WorldSourcePin after_local(definition, store.pin(), {-2, -3}, shaping);
    VWB_EXPECT(!(after_remote.physical_content_identity() == after_local.physical_content_identity()));

    WorldTypedCellTransaction overlay; overlay.transaction_id = "overlay"; overlay.expected_revision = 2;
    overlay.operations.push_back({NativeCellStateNamespace::scene_overlay, {-281, 99, -561},
        WorldTypedCellOperationKind::set, stone_override({-281, 99, -561})});
    (void)store.commit_typed_cells(overlay);
    const WorldSourcePin after_overlay(definition, store.pin(), {-2, -3}, shaping);
    VWB_EXPECT(!(after_local.physical_content_identity() == after_overlay.physical_content_identity()));
    VWB_EXPECT_EQ(-2, after_overlay.primary_terrain_shaping().page_key().x);
    VWB_EXPECT_EQ(-3, after_overlay.primary_terrain_shaping().page_key().z);

    NativeSiteSourceRegionKey remote_region{}; bool found_remote = false;
    for (std::int32_t x = 100; x < 1000 && !found_remote; ++x) {
        if (native_site_source_candidate_for_region(definition, {x, 100})) {
            remote_region = {x, 100}; found_remote = true;
        }
    }
    VWB_EXPECT(found_remote);
    VWB_EXPECT(found_remote);
    NativeTerrainShapingRegistryBatch batch; batch.expected_revision = registry.revision();
    NativeSiteSourceResolution resolution; resolution.region = remote_region;
    resolution.kind = NativeSiteSourceResolutionKind::absent;
    resolution.request_identity = registry.source_request_identity(remote_region);
    resolution.worker_source_key.assign(64, 'c');
    resolution.reason_code = "ordinary_structure_overlap";
    batch.resolutions.push_back(std::move(resolution));
    (void)registry.apply(batch);
    const auto later_shaping = ready_shaping(registry, {-2, -3});
    const WorldSourcePin after_registry_history(definition, store.pin(), {-2, -3}, later_shaping);
    VWB_EXPECT(primary->registry_revision() != later_shaping.front().registry_revision());
    VWB_EXPECT(!(primary->registry_content_identity() == later_shaping.front().registry_content_identity()));
    VWB_EXPECT_EQ(after_overlay.physical_content_identity(), after_registry_history.physical_content_identity());
    VWB_EXPECT_EQ(later_shaping.front().registry_revision(), after_registry_history.shaping_registry_revision());
    VWB_EXPECT_EQ(later_shaping.front().registry_content_identity(),
        after_registry_history.shaping_registry_content_identity());
    VWB_EXPECT_EQ(after_overlay.primary_terrain_shaping().physical_content_identity(),
        after_registry_history.primary_terrain_shaping().physical_content_identity());

    VWB_EXPECT_THROW(std::invalid_argument,
        store.pin().typed_projection_digest({0, 0, 0, 1}));
    VWB_EXPECT_THROW(std::invalid_argument,
        store.pin().typed_projection_digest({0, 0, 1, 0}));
    VWB_EXPECT_THROW(std::invalid_argument,
        store.pin().typed_projection_digest({std::numeric_limits<std::int32_t>::max(), 0, 2, 1}));
    VWB_EXPECT_THROW(std::invalid_argument,
        store.pin().typed_projection_digest({0, std::numeric_limits<std::int32_t>::max(), 1, 2}));
}

VWB_TEST(world_source_pin_rejects_unready_and_other_source_shaping) {
    const WorldSourceDefinition definition(atlas_descriptor());
    NativeTerrainShapingRegistry unresolved_registry(definition, shaping_policy());
    NativeTerrainShapingPagePin unresolved; bool found_unresolved = false;
    for (std::int32_t z = -32; z <= 32 && !found_unresolved; ++z) {
        for (std::int32_t x = -32; x <= 32; ++x) {
            const NativeTerrainShapingPagePin candidate = unresolved_registry.pin_page({x, z});
            if (!candidate.unresolved_dependencies().empty()) {
                unresolved = candidate; found_unresolved = true; break;
            }
        }
    }
    VWB_EXPECT(found_unresolved);
    WorldDeltaStore store;
    const NativeTerrainPageKey unresolved_page = unresolved.page_key();
    std::vector<NativeTerrainShapingPagePin> unresolved_set;
    for (const NativeTerrainPageKey dependency :
        world_effective_shaping_dependencies(definition, unresolved_page)) {
        unresolved_set.push_back(unresolved_registry.pin_page(dependency));
    }
    VWB_EXPECT_THROW(std::invalid_argument,
        WorldSourcePin(definition, store.pin(), unresolved_page, unresolved_set));

    WorldSourceDescriptor other_descriptor = atlas_descriptor();
    other_descriptor.raw_terrain_seed = admit_raw_terrain_seed("other-world-source");
    other_descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("other-world-source");
    const WorldSourceDefinition other(other_descriptor);
    NativeTerrainShapingRegistry other_registry(other, shaping_policy());
    const auto other_shaping = ready_shaping(other_registry, {2, -2});
    VWB_EXPECT_THROW(std::invalid_argument,
        WorldSourcePin(definition, store.pin(), {2, -2}, other_shaping));
}

VWB_TEST(world_source_effective_pin_canonicalizes_and_binds_float32_dependency_pages) {
    const WorldSourceDefinition definition(atlas_descriptor());
    const NativeTerrainPageKey primary{7, 0};
    const auto required = world_effective_shaping_dependencies(definition, primary);
    const auto boundary = resolve_world_query(
        definition, WorldLatticeQuery{{1960, 0, 0}, WorldQueryIntent::terrain_mesh});
    VWB_EXPECT_EQ(1959, static_cast<std::int32_t>(std::floor(
        static_cast<double>(boundary.lattice_position.x) / definition.constants().cell_size_meters)));
    VWB_EXPECT(std::find(required.begin(), required.end(), NativeTerrainPageKey{6, 0}) != required.end());
    VWB_EXPECT(required.size() > 1U);

    NativeTerrainShapingRegistry registry(definition, shaping_policy());
    const auto shaping = ready_shaping(registry, primary);
    WorldDeltaStore store;
    const WorldSourcePin canonical(definition, store.pin(), primary, shaping);
    VWB_EXPECT_EQ(required.size(), canonical.terrain_shaping_page_count());
    VWB_EXPECT_EQ((NativeTerrainPageKey{6, 0}), canonical.terrain_shaping_for_page({6, 0}).page_key());
    VWB_EXPECT_THROW(std::out_of_range, canonical.terrain_shaping_for_page({99, 99}));
    VWB_EXPECT_THROW(std::out_of_range, canonical.terrain_shaping_for_page({-999, -999}));
    VWB_EXPECT_THROW(std::out_of_range, canonical.typed_projection_digest_for_page({99, 99}));
    VWB_EXPECT_THROW(std::out_of_range, canonical.typed_projection_digest_for_page({-999, -999}));

    auto reversed = shaping; std::reverse(reversed.begin(), reversed.end());
    const WorldSourcePin reordered(definition, store.pin(), primary, reversed);
    VWB_EXPECT_EQ(canonical.physical_content_identity(), reordered.physical_content_identity());

    WorldTypedCellTransaction dependency_edit;
    dependency_edit.transaction_id = "dependency-page-edit";
    dependency_edit.expected_revision = 0;
    dependency_edit.operations.push_back({NativeCellStateNamespace::durable_terrain, {1959, 4, 0},
        WorldTypedCellOperationKind::set, stone_override({1959, 4, 0})});
    (void)store.commit_typed_cells(dependency_edit);
    const WorldSourcePin after_dependency_edit(definition, store.pin(), primary, shaping);
    VWB_EXPECT(!(canonical.physical_content_identity() == after_dependency_edit.physical_content_identity()));
    VWB_EXPECT(!(canonical.typed_projection_digest_for_page({6, 0})
        == after_dependency_edit.typed_projection_digest_for_page({6, 0})));

    WorldTypedCellTransaction outside_edit;
    outside_edit.transaction_id = "outside-effective-pages-edit";
    outside_edit.expected_revision = 1;
    outside_edit.operations.push_back({NativeCellStateNamespace::durable_terrain, {1000000, 4, 1000000},
        WorldTypedCellOperationKind::set, stone_override({1000000, 4, 1000000})});
    (void)store.commit_typed_cells(outside_edit);
    const WorldSourcePin after_outside_edit(definition, store.pin(), primary, shaping);
    VWB_EXPECT_EQ(after_dependency_edit.physical_content_identity(), after_outside_edit.physical_content_identity());
    const WorldSourcePin reordered_after_edits(definition, store.pin(), primary, reversed);
    VWB_EXPECT_EQ(after_outside_edit.physical_content_identity(), reordered_after_edits.physical_content_identity());

    auto duplicate = shaping; duplicate.push_back(shaping.front());
    VWB_EXPECT_THROW(std::invalid_argument,
        WorldSourcePin(definition, store.pin(), primary, duplicate));
    auto duplicate_in_place = shaping; duplicate_in_place.back() = shaping.front();
    VWB_EXPECT_THROW(std::invalid_argument,
        WorldSourcePin(definition, store.pin(), primary, duplicate_in_place));
    auto missing = shaping; missing.pop_back();
    VWB_EXPECT_THROW(std::invalid_argument,
        WorldSourcePin(definition, store.pin(), primary, missing));

    auto changed_dependency = shaping;
    const auto dependency = std::find_if(changed_dependency.begin(), changed_dependency.end(),
        [primary](const auto &value) { return !(value.page_key() == primary); });
    VWB_EXPECT(dependency != changed_dependency.end());
    const NativeTerrainPageKey dependency_key = dependency->page_key();
    *dependency = registry.pin_page(dependency_key, {{dependency_key.x, dependency_key.z, false, {}}});
    const WorldSourcePin dependency_changed(definition, store.pin(), primary, changed_dependency);
    VWB_EXPECT(!(after_outside_edit.physical_content_identity()
        == dependency_changed.physical_content_identity()));

    NativeSiteSourceRegionKey remote_region{}; bool found_remote = false;
    for (std::int32_t x = 100; x < 1000 && !found_remote; ++x) {
        if (native_site_source_candidate_for_region(definition, {x, 100})) {
            remote_region = {x, 100}; found_remote = true;
        }
    }
    NativeTerrainShapingRegistryBatch batch; batch.expected_revision = registry.revision();
    NativeSiteSourceResolution resolution; resolution.region = remote_region;
    resolution.kind = NativeSiteSourceResolutionKind::absent;
    resolution.request_identity = registry.source_request_identity(remote_region);
    resolution.worker_source_key.assign(64, 'd'); resolution.reason_code = "ordinary_structure_overlap";
    batch.resolutions.push_back(std::move(resolution)); (void)registry.apply(batch);
    const auto later = ready_shaping(registry, primary);
    auto mixed = shaping;
    const NativeTerrainPageKey replaced_key = mixed.front().page_key();
    const auto replacement = std::find_if(later.begin(), later.end(), [replaced_key](const auto &value) {
        return value.page_key() == replaced_key;
    });
    VWB_EXPECT(replacement != later.end()); mixed.front() = *replacement;
    VWB_EXPECT_THROW(std::invalid_argument,
        WorldSourcePin(definition, store.pin(), primary, mixed));

    NativeTerrainShapingRegistry other_history(definition, shaping_policy());
    (void)ready_shaping(other_history, primary);
    NativeSiteSourceRegionKey other_remote{}; bool found_other_remote = false;
    for (std::int32_t x = 1000; x < 2000 && !found_other_remote; ++x) {
        if (native_site_source_candidate_for_region(definition, {x, 101})) {
            other_remote = {x, 101}; found_other_remote = true;
        }
    }
    VWB_EXPECT(found_other_remote);
    NativeTerrainShapingRegistryBatch other_batch;
    other_batch.expected_revision = other_history.revision();
    NativeSiteSourceResolution other_resolution; other_resolution.region = other_remote;
    other_resolution.kind = NativeSiteSourceResolutionKind::absent;
    other_resolution.request_identity = other_history.source_request_identity(other_remote);
    other_resolution.worker_source_key.assign(64, 'e');
    other_resolution.reason_code = "ordinary_structure_overlap";
    other_batch.resolutions.push_back(std::move(other_resolution));
    (void)other_history.apply(other_batch);
    const auto other_later = ready_shaping(other_history, primary);
    VWB_EXPECT_EQ(later.front().registry_revision(), other_later.front().registry_revision());
    VWB_EXPECT(!(later.front().registry_content_identity()
        == other_later.front().registry_content_identity()));
    auto same_revision_mixed = later;
    same_revision_mixed.front() = other_later.front();
    VWB_EXPECT_THROW(std::invalid_argument,
        WorldSourcePin(definition, store.pin(), primary, same_revision_mixed));

    VWB_EXPECT_THROW(std::invalid_argument,
        world_effective_shaping_dependencies(definition, {std::numeric_limits<std::int32_t>::max(), 0}));

    WorldSourceDescriptor huge_cell = atlas_descriptor();
    huge_cell.constants.cell_size_meters = 1.0e300;
    VWB_EXPECT_THROW(std::invalid_argument,
        world_effective_shaping_dependencies(WorldSourceDefinition(huge_cell), {0, 0}));

    WorldSourceDescriptor subnormal_cell = atlas_descriptor();
    subnormal_cell.constants.cell_size_meters = 7.1e-46;
    VWB_EXPECT_THROW(std::invalid_argument,
        world_effective_shaping_dependencies(WorldSourceDefinition(subnormal_cell), {7669582, 0}));
    VWB_EXPECT_THROW(std::invalid_argument,
        world_effective_shaping_dependencies(WorldSourceDefinition(subnormal_cell), {-7669582, 0}));
}

VWB_TEST(world_source_effective_pin_includes_extreme_center_only_dependency_identity) {
    const WorldSourceDefinition definition(atlas_descriptor());
    const NativeTerrainPageKey primary{44384, 0};
    const CellCoord edge_cell{12427799, 0, 0};
    const auto lattice = resolve_world_query(
        definition, WorldLatticeQuery{edge_cell, WorldQueryIntent::terrain_mesh});
    const auto center = resolve_world_query(
        definition, WorldCellCenterQuery{edge_cell, WorldQueryIntent::gameplay});
    const auto remapped_x = [&](const float position) {
        return static_cast<std::int32_t>(std::floor(
            static_cast<double>(position) / definition.constants().cell_size_meters));
    };
    VWB_EXPECT_EQ(12427798, remapped_x(lattice.lattice_position.x));
    VWB_EXPECT_EQ(12427800, remapped_x(center.center_position.x));

    const auto required = world_effective_shaping_dependencies(definition, primary);
    VWB_EXPECT(std::find(required.begin(), required.end(), NativeTerrainPageKey{44385, 0})
        != required.end());
    NativeTerrainShapingRegistry registry(definition, shaping_policy());
    const auto shaping = ready_shaping(registry, primary);
    WorldDeltaStore store;
    const WorldSourcePin before(definition, store.pin(), primary, shaping);

    auto changed = shaping;
    const auto center_dependency = std::find_if(changed.begin(), changed.end(), [](const auto &value) {
        return value.page_key() == NativeTerrainPageKey{44385, 0};
    });
    VWB_EXPECT(center_dependency != changed.end());
    *center_dependency = registry.pin_page({44385, 0}, {{44385, 0, false, {}}});
    const WorldSourcePin after(definition, store.pin(), primary, changed);
    VWB_EXPECT(!(before.physical_content_identity() == after.physical_content_identity()));
}

VWB_TEST(world_source_effective_pin_includes_wgs_grid_numeric_dependency_identity) {
    const WorldSourceDefinition definition(atlas_descriptor());
    const NativeTerrainPageKey primary{88769, 0};
    const CellCoord edge_cell{24855320, 0, 0};
    const auto lattice = resolve_world_query(
        definition, WorldLatticeQuery{edge_cell, WorldQueryIntent::terrain_mesh});
    const auto center = resolve_world_query(
        definition, WorldCellCenterQuery{edge_cell, WorldQueryIntent::gameplay});
    const float grid_position = static_cast<float>(
        static_cast<double>(edge_cell.x) * definition.constants().cell_size_meters);
    const auto remapped_x = [&](const float position) {
        return static_cast<std::int32_t>(std::floor(
            static_cast<double>(position) / definition.constants().cell_size_meters));
    };
    VWB_EXPECT_EQ(88769, remapped_x(lattice.lattice_position.x) / NativeTerrainShapingSnapshot::PAGE_CELLS);
    VWB_EXPECT_EQ(88769, remapped_x(center.center_position.x) / NativeTerrainShapingSnapshot::PAGE_CELLS);
    VWB_EXPECT_EQ(24855318, remapped_x(grid_position));
    VWB_EXPECT_EQ(88768, remapped_x(grid_position) / NativeTerrainShapingSnapshot::PAGE_CELLS);

    const auto required = world_effective_shaping_dependencies(definition, primary);
    VWB_EXPECT(std::find(required.begin(), required.end(), NativeTerrainPageKey{88768, 0})
        != required.end());
    NativeTerrainShapingRegistry registry(definition, shaping_policy());
    const auto shaping = ready_shaping(registry, primary);
    WorldDeltaStore store;
    const WorldSourcePin before(definition, store.pin(), primary, shaping);
    VWB_EXPECT_EQ((NativeTerrainPageKey{88768, 0}),
        before.terrain_shaping_for_page({88768, 0}).page_key());

    auto changed = shaping;
    const auto grid_dependency = std::find_if(changed.begin(), changed.end(), [](const auto &value) {
        return value.page_key() == NativeTerrainPageKey{88768, 0};
    });
    VWB_EXPECT(grid_dependency != changed.end());
    *grid_dependency = registry.pin_page({88768, 0}, {{88768, 0, false, {}}});
    const WorldSourcePin after(definition, store.pin(), primary, changed);
    VWB_EXPECT(!(before.physical_content_identity() == after.physical_content_identity()));
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
    const WorldSurfaceColumnQuery column{9, -1, WorldQueryIntent::terrain_collision};

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

    // The direct column anchor mirrors `Vector2(float(cell.x) * CELL, ...)`:
    // scalar multiplication is binary64 and only the Vector2 storage boundary
    // narrows to binary32. It deliberately has no Y field.
    VWB_EXPECT_EQ(9, column_result.lattice_x);
    VWB_EXPECT_EQ(-1, column_result.lattice_z);
    VWB_EXPECT_EQ(0x41426666u, float32_bits(column_result.lattice_position.x));
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
