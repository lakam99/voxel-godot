#include "test_harness.hpp"

#include "../core/native_effective_terrain_batch.hpp"
#include "../core/native_terrain_shaping_registry.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

bool near(const double left, const double right) {
    return std::abs(left - right) <= 1.0e-9;
}

WorldSourceDefinition flat_definition() {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("effective-batch-flat");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("effective-batch-flat");
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    descriptor.constants.minimum_surface_meters = 13.0;
    descriptor.constants.maximum_surface_meters = 13.0;
    return WorldSourceDefinition(std::move(descriptor));
}

NativeSiteSourcePolicy site_policy() {
    NativeSiteSourcePolicy policy;
    policy.engine_version_utf8 = "4.6.1.stable.official.14d19694e";
    policy.ordinary_region_cells = 140;
    policy.ordinary_spawn_chance = 0.08;
    return policy;
}

std::vector<NativeTownRegionOverride> absent_towns(const NativeTerrainPageKey page) {
    std::vector<NativeTownRegionOverride> result;
    for (std::int32_t z = page.z - 1; z <= page.z + 1; ++z)
        for (std::int32_t x = page.x - 1; x <= page.x + 1; ++x)
            result.push_back({x, z, false, {}});
    return result;
}

WorldSourcePin ready_pin(
    const WorldSourceDefinition &definition, const NativeTerrainPageKey primary,
    const WorldDeltaPinnedSnapshot &deltas) {
    NativeTerrainShapingRegistry registry(definition, site_policy());
    const auto pages = world_effective_shaping_dependencies(definition, primary);
    std::vector<NativeSiteSourceRegionKey> unresolved;
    for (const NativeTerrainPageKey page : pages) {
        const auto provisional = registry.pin_page(page, absent_towns(page));
        for (const NativeSiteSourceRegionKey region : provisional.unresolved_dependencies())
            if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end())
                unresolved.push_back(region);
    }
    NativeTerrainShapingRegistryBatch resolutions;
    resolutions.expected_revision = registry.revision();
    for (const NativeSiteSourceRegionKey region : unresolved) {
        NativeSiteSourceResolution resolution;
        resolution.region = region;
        resolution.request_identity = registry.source_request_identity(region);
        resolution.worker_source_key.assign(64, 'b');
        resolution.kind = NativeSiteSourceResolutionKind::absent;
        resolution.reason_code = "ordinary_structure_overlap";
        resolutions.resolutions.push_back(std::move(resolution));
    }
    if (!resolutions.resolutions.empty()) static_cast<void>(registry.apply(resolutions));
    std::vector<NativeTerrainShapingPagePin> pins;
    for (const NativeTerrainPageKey page : pages)
        pins.push_back(registry.pin_page(page, absent_towns(page)));
    return WorldSourcePin(definition, deltas, primary, pins);
}

NativeCellState edit(
    const CellCoord cell, const NativeCellStateNamespace name_space,
    const double density, const TerrainMaterialId material,
    const TerrainBiomeId biome, const TerrainFluidId fluid,
    const NativeCellLight light) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = material;
    input.biome = biome;
    input.solid = density >= 0.0;
    input.density = density;
    input.fluid = fluid;
    input.light = light;
    input.metadata = NativeValue::object({
        {"source", NativeValue::string("terrain_edit")},
        {"terrainMeshAffects", NativeValue::boolean(true)},
    });
    input.block_id = NativeBlockIdentity::create("batch_block");
    input.edit_reason = "batch-test";
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input, name_space);
}

WorldDeltaPinnedSnapshot layered_deltas() {
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "effective-batch:layers";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({{
        NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable,
        edit({1, 0, 0}, NativeCellStateNamespace::durable_terrain, 2.0,
            TerrainMaterialId::stone, TerrainBiomeId::beach,
            TerrainFluidId::none, {4, 5}),
    }});
    admission.transient_overlays.push_back({
        NativeCellStateNamespace::scene_overlay,
        NativeTypedWorldStatePersistence::transient,
        edit({2, 0, 0}, NativeCellStateNamespace::scene_overlay, -0.5,
            TerrainMaterialId::water, TerrainBiomeId::town,
            TerrainFluidId::water, {6, 7}),
    });
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot same_cell_layered_deltas() {
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "effective-batch:same-cell-layers";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({{
        NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable,
        edit({1, 0, 0}, NativeCellStateNamespace::durable_terrain, 2.0,
            TerrainMaterialId::stone, TerrainBiomeId::beach,
            TerrainFluidId::none, {4, 5}),
    }});
    admission.transient_overlays.push_back({
        NativeCellStateNamespace::scene_overlay,
        NativeTypedWorldStatePersistence::transient,
        edit({1, 0, 0}, NativeCellStateNamespace::scene_overlay, -0.5,
            TerrainMaterialId::water, TerrainBiomeId::town,
            TerrainFluidId::water, {6, 7}),
    });
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot raised_column_deltas(const bool mask_with_scene_air) {
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = mask_with_scene_air
        ? "effective-batch:raised-column-masked"
        : "effective-batch:raised-column";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({{
        NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable,
        edit({3, 12, 0}, NativeCellStateNamespace::durable_terrain, 2.0,
            TerrainMaterialId::stone, TerrainBiomeId::plains,
            TerrainFluidId::none, {0, 0}),
    }});
    if (mask_with_scene_air) {
        admission.transient_overlays.push_back({
            NativeCellStateNamespace::scene_overlay,
            NativeTypedWorldStatePersistence::transient,
            edit({3, 12, 0}, NativeCellStateNamespace::scene_overlay, -0.5,
                TerrainMaterialId::air, TerrainBiomeId::plains,
                TerrainFluidId::none, {15, 0}),
        });
    }
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot capped_roof_deltas() {
    std::vector<NativeTypedWorldStateRecord> records;
    for (const std::int32_t y : {14, 15}) {
        records.push_back({
            NativeCellStateNamespace::durable_terrain,
            NativeTypedWorldStatePersistence::durable,
            edit({4, y, 0}, NativeCellStateNamespace::durable_terrain, 2.0,
                TerrainMaterialId::stone, TerrainBiomeId::plains,
                TerrainFluidId::none, {0, 0}),
        });
    }
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "effective-batch:capped-roof";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(records));
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot all_air_column_deltas() {
    std::vector<NativeTypedWorldStateRecord> overlays;
    for (std::int32_t y = -64; y <= 14; ++y) {
        overlays.push_back({
            NativeCellStateNamespace::scene_overlay,
            NativeTypedWorldStatePersistence::transient,
            edit({5, y, 0}, NativeCellStateNamespace::scene_overlay, -0.5,
                TerrainMaterialId::air, TerrainBiomeId::plains,
                TerrainFluidId::none, {15, 0}),
        });
    }
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "effective-batch:all-air-column";
    admission.transient_overlays = std::move(overlays);
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot metadata_deltas(
    const std::string &payload, const bool retain_identifiers) {
    NativeCellStateInput input;
    input.cell = {1, 0, 0};
    input.material = TerrainMaterialId::stone;
    input.biome = TerrainBiomeId::beach;
    input.solid = true;
    input.density = 2.0;
    input.metadata = NativeValue::object({
        {"emptyArray", NativeValue::array({})},
        {"emptyObject", NativeValue::object({})},
        {"enabled", NativeValue::boolean(true)},
        {"nested", NativeValue::array({NativeValue::object({
            {"payload", NativeValue::string(payload)},
        })})},
        {"number", NativeValue::number(17.25)},
        {"optional", NativeValue::null()},
        {"source", NativeValue::string("terrain_edit")},
        {"terrainMeshAffects", NativeValue::boolean(true)},
    });
    if (retain_identifiers) {
        input.block_id = NativeBlockIdentity::create("metadata_block");
        input.edit_reason = "metadata-test";
    }
    input.generated = false;
    input.edited = true;
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "effective-batch:metadata";
    if (retain_identifiers) {
        admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({{
            NativeCellStateNamespace::durable_terrain,
            NativeTypedWorldStatePersistence::durable,
            make_native_cell_state(input, NativeCellStateNamespace::durable_terrain),
        }});
    } else {
        admission.durable_snapshot = NativeTypedWorldStateSnapshot::create({});
        admission.transient_overlays.push_back({
            NativeCellStateNamespace::scene_overlay,
            NativeTypedWorldStatePersistence::transient,
            make_native_cell_state(input, NativeCellStateNamespace::scene_overlay),
        });
    }
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

WorldDeltaPinnedSnapshot empty_deltas() {
    const WorldDeltaStore store;
    return store.pin();
}

WorldSourceDefinition tall_definition() {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("effective-batch-tall");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("effective-batch-tall");
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    descriptor.constants.world_bottom_cell_y = -1000;
    descriptor.constants.minimum_surface_meters = 1000.0;
    descriptor.constants.maximum_surface_meters = 1000.0;
    return WorldSourceDefinition(std::move(descriptor));
}

WorldSourceDefinition int32_top_definition() {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("effective-batch-int32-top");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed(
        "effective-batch-int32-top");
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    descriptor.constants.minimum_surface_meters = 13.0;
    descriptor.constants.maximum_surface_meters =
        (static_cast<double>(std::numeric_limits<std::int32_t>::max()) - 4.0)
            * descriptor.constants.cell_size_meters;
    return WorldSourceDefinition(std::move(descriptor));
}

std::size_t projection_state_payload(const NativeCellState &state) {
    return 54U + state.metadata.canonical_binary().size()
        + (state.block_id ? state.block_id->value().size() : 0U)
        + (state.edit_reason ? state.edit_reason->size() : 0U);
}

WorldDeltaPinnedSnapshot projection_deltas() {
    std::vector<NativeTypedWorldStateRecord> records;
    const auto append = [&](const CellCoord cell, const double density,
                            const TerrainMaterialId material,
                            const TerrainFluidId fluid = TerrainFluidId::none,
                            const NativeCellLight light = NativeCellLight{}) {
        records.push_back({
            NativeCellStateNamespace::durable_terrain,
            NativeTypedWorldStatePersistence::durable,
            edit(cell, NativeCellStateNamespace::durable_terrain, density,
                material, TerrainBiomeId::plains, fluid, light),
        });
    };
    append({20, 10, 0}, 1.0, TerrainMaterialId::stone);
    records.back().state.metadata = NativeValue::object({
        {"arrayValue", NativeValue::array({
            NativeValue::boolean(false), NativeValue::string("nested")})},
        {"nullValue", NativeValue::null()},
        {"numberValue", NativeValue::number(17.25)},
        {"objectValue", NativeValue::object({
            {"child", NativeValue::number(-2.5)}})},
        {"source", NativeValue::string("terrain_edit")},
        {"terrainMeshAffects", NativeValue::boolean(true)},
    });
    append({20, 11, 0}, -0.5, TerrainMaterialId::water,
        TerrainFluidId::water, {3, 7});
    append({20, 12, 0}, -0.5, TerrainMaterialId::air);
    append({21, 10, 0}, 1.0, TerrainMaterialId::stone);
    for (std::int32_t y = 11; y <= 14; ++y)
        append({21, y, 0}, -0.5, TerrainMaterialId::air);
    append({22, 9, 0}, 1.0, TerrainMaterialId::stone);
    for (std::int32_t y = 10; y <= 14; ++y)
        append({22, y, 0}, -0.5, TerrainMaterialId::air);
    append({23, 9, 0}, 1.0, TerrainMaterialId::stone);
    append({23, 10, 0}, 1.0, TerrainMaterialId::stone);
    append({24, 12, 0}, 1.0, TerrainMaterialId::stone);
    append({25, 8, 0}, 1.0, TerrainMaterialId::stone);
    append({25, 9, 0}, -0.5, TerrainMaterialId::air);
    for (std::int32_t y = 8; y <= 12; ++y)
        append({26, y, 0}, -0.5, TerrainMaterialId::air);
    append({-1, 14, -1}, 1.0, TerrainMaterialId::stone);
    append({-1, 15, -1}, -0.5, TerrainMaterialId::air);
    append({-2, -63, -1}, 1.0, TerrainMaterialId::bedrock);
    append({-2, -62, -1}, -0.5, TerrainMaterialId::air);
    append({27, 10, 0}, 1.0, TerrainMaterialId::stone);
    append({27, 11, 0}, -0.5, TerrainMaterialId::air);
    append({27, 12, 0}, 1.0, TerrainMaterialId::stone);
    append({28, 11, 0}, 1.0, TerrainMaterialId::stone);
    append({28, 12, 0}, -0.5, TerrainMaterialId::air);
    append({28, 13, 0}, -0.5, TerrainMaterialId::air);
    append({29, 9, 0}, 1.0, TerrainMaterialId::stone);
    append({29, 10, 0}, 1.0, TerrainMaterialId::stone);
    append({29, 11, 0}, -0.5, TerrainMaterialId::air);
    append({29, 12, 0}, -0.5, TerrainMaterialId::air);
    WorldDeltaStore store;
    WorldTypedStateAdmission admission;
    admission.transaction_id = "effective-batch:projection";
    admission.durable_snapshot = NativeTypedWorldStateSnapshot::create(
        std::move(records));
    admission.transient_overlays.push_back({
        NativeCellStateNamespace::scene_overlay,
        NativeTypedWorldStatePersistence::transient,
        edit({23, 10, 0}, NativeCellStateNamespace::scene_overlay, -0.5,
            TerrainMaterialId::air, TerrainBiomeId::plains,
            TerrainFluidId::none, {15, 0}),
    });
    static_cast<void>(store.admit_typed_state(admission));
    return store.pin();
}

NativeEffectiveTerrainBatchRejectReason rejected_reason(
    const NativeEffectiveTerrainBatch &batch,
    const NativeEffectiveTerrainBatchRequest &request) {
    try {
        static_cast<void>(batch.execute(request));
    } catch (const NativeEffectiveTerrainBatchRejected &error) {
        VWB_EXPECT(std::string(error.what()).find("batch limit exceeded") != std::string::npos);
        return error.reason();
    }
    VWB_EXPECT(false);
    return NativeEffectiveTerrainBatchRejectReason::total_limit;
}

NativeEffectiveTerrainBatchRejectReason projection_rejected_reason(
    const NativeEffectiveTerrainBatch &batch,
    const NativeEffectiveTerrainProjectionBatchRequest &request) {
    try {
        static_cast<void>(batch.execute_projections(request));
    } catch (const NativeEffectiveTerrainBatchRejected &error) {
        VWB_EXPECT(std::string(error.what()).find("limit exceeded") != std::string::npos);
        return error.reason();
    }
    VWB_EXPECT(false);
    return NativeEffectiveTerrainBatchRejectReason::projection_total_limit;
}

} // namespace

VWB_TEST(native_effective_batch_preserves_channel_order_duplicates_and_typed_facts) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatch batch(ready_pin(definition, {0, 0}, layered_deltas()));
    VWB_EXPECT(batch.pin().terrain_shaping_page_count() > 0U);
    VWB_EXPECT_EQ(4096U, batch.limits().max_surface_columns);

    NativeEffectiveTerrainBatchRequest request;
    request.surface_columns = {
        {2, 0, WorldQueryIntent::gameplay},
        {0, 0, WorldQueryIntent::gameplay},
        {2, 0, WorldQueryIntent::gameplay},
    };
    request.cell_centers = {
        {{2, 0, 0}, WorldQueryIntent::gameplay},
        {{1, 0, 0}, WorldQueryIntent::gameplay},
        {{2, 0, 0}, WorldQueryIntent::gameplay},
        {{0, 0, 0}, WorldQueryIntent::gameplay},
    };
    request.lattice_numeric = {
        {{2, 0, 0}, WorldQueryIntent::terrain_mesh},
        {{1, 0, 0}, WorldQueryIntent::terrain_mesh},
        {{1, 0, 0}, WorldQueryIntent::terrain_mesh},
    };
    const double cell = definition.constants().cell_size_meters;
    request.world_numeric = {
        {{static_cast<float>(2.5 * cell), static_cast<float>(0.5 * cell), static_cast<float>(0.5 * cell)}},
        {{static_cast<float>(1.5 * cell), static_cast<float>(0.5 * cell), static_cast<float>(0.5 * cell)}},
        {{static_cast<float>(2.5 * cell), static_cast<float>(0.5 * cell), static_cast<float>(0.5 * cell)}},
    };
    request.surface_projection_numeric = {
        {{1, 0, 0}, WorldQueryIntent::terrain_collision},
        {{2, 0, 0}, WorldQueryIntent::terrain_collision},
        {{1, 0, 0}, WorldQueryIntent::terrain_collision},
    };

    const NativeEffectiveTerrainBatchResult result = batch.execute(request);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchResult::SCHEMA_REVISION,
        result.schema_revision);
    VWB_EXPECT_EQ((NativeTerrainPageKey{0, 0}), result.primary_page);
    VWB_EXPECT_EQ(batch.pin().definition().physical_content_identity(),
        result.definition_physical_identity);
    VWB_EXPECT_EQ(batch.pin().physical_content_identity(),
        result.pin_physical_identity);
    VWB_EXPECT_EQ(batch.pin().terrain_delta_revision(), result.terrain_delta_revision);
    VWB_EXPECT_EQ(batch.pin().shaping_registry_revision(), result.shaping_registry_revision);
    VWB_EXPECT_EQ(batch.pin().shaping_registry_content_identity(),
        result.shaping_registry_content_identity);
    VWB_EXPECT(result.prepared_payload_bytes > 0U);
    VWB_EXPECT_EQ(3U, result.surface_columns.size());
    VWB_EXPECT_EQ(2, result.surface_columns[0].requested.x);
    VWB_EXPECT_EQ(0, result.surface_columns[1].source_x);
    VWB_EXPECT_EQ(2, result.surface_columns[2].source_x);
    VWB_EXPECT(near(13.0, result.surface_columns[0].reference_surface_y));
    VWB_EXPECT(near(13.0, result.surface_columns[0].deformed_surface_y));
    VWB_EXPECT(near(13.5, result.surface_columns[0].volume_surface_y));
    VWB_EXPECT_EQ(result.surface_columns[0].biome, result.surface_columns[2].biome);

    VWB_EXPECT_EQ(4U, result.cell_centers.size());
    VWB_EXPECT_EQ((CellCoord{2, 0, 0}), result.cell_centers[0].source_cell);
    VWB_EXPECT_EQ(TerrainMaterialId::water, result.cell_centers[0].material);
    VWB_EXPECT_EQ(TerrainBiomeId::town, result.cell_centers[0].biome);
    VWB_EXPECT_EQ(TerrainFluidId::water, result.cell_centers[0].fluid);
    VWB_EXPECT(!result.cell_centers[0].solid);
    VWB_EXPECT_EQ((NativeCellLight{6, 7}), result.cell_centers[0].light);
    VWB_EXPECT(!result.cell_centers[0].generated && result.cell_centers[0].edited);
    VWB_EXPECT(result.cell_centers[0].edited_sparse_state.has_value());
    VWB_EXPECT_EQ(result.cell_centers[0].edited_sparse_state,
        result.cell_centers[2].edited_sparse_state);
    VWB_EXPECT_EQ(TerrainMaterialId::stone, result.cell_centers[1].material);
    VWB_EXPECT(result.cell_centers[1].solid);
    VWB_EXPECT(!result.cell_centers[3].edited_sparse_state.has_value());
    VWB_EXPECT(result.cell_centers[3].generated && !result.cell_centers[3].edited);

    // Lattice numeric ignores scene overlays but carries durable sparse state.
    VWB_EXPECT(result.lattice_numeric[0].facts.generated);
    VWB_EXPECT(!result.lattice_numeric[0].edited_sparse_state.has_value());
    VWB_EXPECT(near(2.0, result.lattice_numeric[1].facts.density));
    VWB_EXPECT(result.lattice_numeric[1].edited_sparse_state.has_value());
    VWB_EXPECT_EQ(result.lattice_numeric[1].edited_sparse_state,
        result.lattice_numeric[2].edited_sparse_state);

    VWB_EXPECT(near(-0.5, result.world_numeric[0].facts.density));
    VWB_EXPECT(result.world_numeric[0].edited_sparse_state.has_value());
    VWB_EXPECT(near(2.0, result.world_numeric[1].facts.density));
    VWB_EXPECT_EQ(result.world_numeric[0].edited_sparse_state,
        result.world_numeric[2].edited_sparse_state);

    VWB_EXPECT(near(2.0, result.surface_projection_numeric[0].facts.density));
    VWB_EXPECT(result.surface_projection_numeric[0].edited_sparse_state.has_value());
    VWB_EXPECT(near(-0.5, result.surface_projection_numeric[1].facts.density));
    VWB_EXPECT_EQ(result.surface_projection_numeric[0].edited_sparse_state,
        result.surface_projection_numeric[2].edited_sparse_state);
}

VWB_TEST(native_effective_batch_surface_columns_own_effective_volume_surface_y) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatchRequest request;
    request.surface_columns.push_back({3, 0, WorldQueryIntent::gameplay});

    const auto ordinary = NativeEffectiveTerrainBatch(
        ready_pin(definition, {0, 0}, empty_deltas())).execute(request);
    VWB_EXPECT(near(13.0, ordinary.surface_columns[0].reference_surface_y));
    VWB_EXPECT(near(13.0, ordinary.surface_columns[0].deformed_surface_y));
    VWB_EXPECT(near(13.5, ordinary.surface_columns[0].volume_surface_y));

    const auto durable = NativeEffectiveTerrainBatch(
        ready_pin(definition, {0, 0}, raised_column_deltas(false))).execute(request);
    VWB_EXPECT(near(13.0, durable.surface_columns[0].reference_surface_y));
    VWB_EXPECT(near(17.55, durable.surface_columns[0].volume_surface_y));

    // Effective typed-cell precedence is part of the column scan: transient
    // scene air at the same cell masks the durable solid and restores the
    // generated column top. The shaped/reference height never changes.
    const auto layered = NativeEffectiveTerrainBatch(
        ready_pin(definition, {0, 0}, raised_column_deltas(true))).execute(request);
    VWB_EXPECT(near(13.0, layered.surface_columns[0].reference_surface_y));
    VWB_EXPECT(near(13.0, layered.surface_columns[0].deformed_surface_y));
    VWB_EXPECT(near(13.5, layered.surface_columns[0].volume_surface_y));

    // The original service probes no more than the admitted world top. A
    // solid at that bound whose immediate upper neighbour is also solid is
    // not an exposed top, so the scan continues to the ordinary terrain.
    request.surface_columns[0].x = 4;
    const auto capped = NativeEffectiveTerrainBatch(
        ready_pin(definition, {0, 0}, capped_roof_deltas())).execute(request);
    VWB_EXPECT(near(13.5, capped.surface_columns[0].volume_surface_y));

    // If no effective solid exists in the bounded column, the GDScript owner
    // falls back to the shaped/reference height rather than quantizing it.
    request.surface_columns[0].x = 5;
    const auto all_air = NativeEffectiveTerrainBatch(
        ready_pin(definition, {0, 0}, all_air_column_deltas())).execute(request);
    VWB_EXPECT(near(13.0, all_air.surface_columns[0].volume_surface_y));
}

VWB_TEST(native_effective_batch_preserves_high_coordinate_source_remaps) {
    const auto definition = flat_definition();
    constexpr std::int32_t grid_x = 24855320;
    constexpr std::int32_t source_x = 24855318;
    const std::int32_t page_x = *floor_divide(grid_x, NativeTerrainShapingSnapshot::PAGE_CELLS);
    NativeEffectiveTerrainBatch batch(ready_pin(definition, {page_x, 0}, empty_deltas()));
    NativeEffectiveTerrainBatchRequest request;
    request.lattice_numeric.push_back({{grid_x, 0, 0}, WorldQueryIntent::terrain_mesh});
    request.world_numeric.push_back({
        {static_cast<float>(static_cast<double>(grid_x) * definition.constants().cell_size_meters),
            0.0F, 0.0F},
    });
    request.surface_projection_numeric.push_back(
        {{grid_x, 0, 0}, WorldQueryIntent::terrain_collision});
    const auto result = batch.execute(request);
    VWB_EXPECT_EQ(grid_x, result.lattice_numeric[0].facts.requested_cell.x);
    VWB_EXPECT(result.lattice_numeric[0].facts.source_cell.x != grid_x);
    VWB_EXPECT_EQ(source_x, result.world_numeric[0].facts.source_cell.x);
    VWB_EXPECT_EQ(source_x, result.surface_projection_numeric[0].facts.source_cell.x);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchQueryKind::arbitrary_world_numeric,
        native_effective_batch_query_kind(request.world_numeric[0]));
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchQueryKind::surface_projection_numeric,
        native_effective_batch_query_kind(request.surface_projection_numeric[0]));
    VWB_EXPECT_EQ(WorldQueryIntent::terrain_mesh, result.world_numeric[0].requested.intent);
    VWB_EXPECT_EQ(WorldQueryIntent::terrain_collision,
        result.surface_projection_numeric[0].requested.intent);

    // The WGS surface-projection fallback classifies generated material with
    // world_to_cell3(position), not with the pre-float32 requested grid cell.
    // Search this deterministic page for a strata witness where those two
    // coordinate owners differ. Lattice material deliberately keeps requested
    // coordinates, so equality here would preserve the old mistranslation.
    NativeEffectiveTerrainSource source(
        ready_pin(definition, {page_x, 0}, empty_deltas()));
    bool observed_remapped_material = false;
    for (std::int32_t z = 0; z < NativeTerrainShapingSnapshot::PAGE_CELLS
        && !observed_remapped_material; ++z) {
        for (std::int32_t y = -40; y <= -8; ++y) {
            const WorldLatticeQuery query{
                {grid_x, y, z}, WorldQueryIntent::terrain_collision};
            const auto projection = source.sample_surface_projection_numeric(query);
            const auto lattice = source.sample_lattice_numeric(
                {{grid_x, y, z}, WorldQueryIntent::terrain_mesh});
            if (projection.generated && lattice.generated
                && projection.density >= 0.0 && lattice.density >= 0.0
                && projection.material != lattice.material) {
                observed_remapped_material = true;
                break;
            }
        }
    }
    VWB_EXPECT(observed_remapped_material);
}

VWB_TEST(native_effective_batch_pairs_lattice_edits_only_with_durable_sparse_state) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatch batch(
        ready_pin(definition, {0, 0}, same_cell_layered_deltas()));
    NativeEffectiveTerrainBatchRequest request;
    request.cell_centers.push_back({{1, 0, 0}, WorldQueryIntent::gameplay});
    request.lattice_numeric.push_back({{1, 0, 0}, WorldQueryIntent::terrain_mesh});
    const auto result = batch.execute(request);

    VWB_EXPECT_EQ(TerrainMaterialId::water, result.cell_centers[0].material);
    VWB_EXPECT(near(-0.5, result.cell_centers[0].density));
    VWB_EXPECT_EQ(TerrainMaterialId::stone, result.lattice_numeric[0].facts.material);
    VWB_EXPECT(near(2.0, result.lattice_numeric[0].facts.density));
    VWB_EXPECT(result.lattice_numeric[0].edited_sparse_state.has_value());
    VWB_EXPECT_EQ(TerrainMaterialId::stone,
        result.lattice_numeric[0].edited_sparse_state->material);
    VWB_EXPECT(near(2.0,
        result.lattice_numeric[0].edited_sparse_state->density));
}

VWB_TEST(native_effective_batch_reports_float32_center_remapped_source_cell) {
    const auto definition = flat_definition();
    constexpr std::int32_t requested_x = 12427799;
    constexpr std::int32_t remapped_x = 12427800;
    const std::int32_t page_x = *floor_divide(
        requested_x, NativeTerrainShapingSnapshot::PAGE_CELLS);
    NativeEffectiveTerrainBatch batch(
        ready_pin(definition, {page_x, 0}, empty_deltas()));
    NativeEffectiveTerrainBatchRequest request;
    request.cell_centers.push_back(
        {{requested_x, 0, 0}, WorldQueryIntent::gameplay});
    const auto result = batch.execute(request);

    VWB_EXPECT_EQ(requested_x,
        result.cell_centers[0].requested.coordinate.x);
    VWB_EXPECT_EQ(remapped_x, result.cell_centers[0].source_cell.x);
    VWB_EXPECT(result.cell_centers[0].source_cell.x
        != result.cell_centers[0].requested.coordinate.x);
}

VWB_TEST(native_effective_batch_enforces_each_channel_and_overflow_safe_total_cap) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatchLimits limits;
    limits.max_surface_columns = 1;
    limits.max_cell_centers = 1;
    limits.max_lattice_numeric = 1;
    limits.max_world_numeric = 1;
    limits.max_surface_projection_numeric = 1;
    limits.max_total_queries = std::numeric_limits<std::size_t>::max();
    NativeEffectiveTerrainBatch batch(ready_pin(definition, {0, 0}, empty_deltas()), limits);

    NativeEffectiveTerrainBatchRequest request;
    request.surface_columns.resize(2);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::surface_column_limit,
        rejected_reason(batch, request));
    request = {}; request.cell_centers.resize(2);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::cell_center_limit,
        rejected_reason(batch, request));
    request = {}; request.lattice_numeric.resize(2);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::lattice_numeric_limit,
        rejected_reason(batch, request));
    request = {}; request.world_numeric.resize(2);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::world_numeric_limit,
        rejected_reason(batch, request));
    request = {}; request.surface_projection_numeric.resize(2);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::surface_projection_numeric_limit,
        rejected_reason(batch, request));

    limits.max_total_queries = 1;
    NativeEffectiveTerrainBatch total_batch(
        ready_pin(definition, {0, 0}, empty_deltas()), limits);
    request = {};
    request.surface_columns.push_back({0, 0, WorldQueryIntent::gameplay});
    request.cell_centers.push_back({{0, 0, 0}, WorldQueryIntent::gameplay});
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::total_limit,
        rejected_reason(total_batch, request));

    // The diagnostic fallback is total and deterministic even for a corrupted
    // enum supplied only by this direct constructor test.
    NativeEffectiveTerrainBatchRejected unknown(
        static_cast<NativeEffectiveTerrainBatchRejectReason>(255));
    VWB_EXPECT_EQ(std::string("native effective terrain batch rejected"), std::string(unknown.what()));
}

VWB_TEST(native_effective_batch_numeric_query_types_keep_distinct_coordinate_conventions) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatch batch(ready_pin(definition, {0, 0}, empty_deltas()));
    NativeEffectiveTerrainBatchRequest request;
    request.world_numeric.push_back({{
        static_cast<float>(9.5 * definition.constants().cell_size_meters),
        0.0F, 0.0F,
    }});
    request.surface_projection_numeric.push_back(
        {{9, 0, 0}, WorldQueryIntent::terrain_collision});
    const auto result = batch.execute(request);
    VWB_EXPECT_EQ(9, result.world_numeric[0].facts.source_cell.x);
    VWB_EXPECT_EQ(8, result.surface_projection_numeric[0].facts.source_cell.x);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchQueryKind::arbitrary_world_numeric,
        native_effective_batch_query_kind(result.world_numeric[0].requested));
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchQueryKind::surface_projection_numeric,
        native_effective_batch_query_kind(
            result.surface_projection_numeric[0].requested));

    request = {};
    request.world_numeric.push_back({{0.0F, 0.0F, 0.0F},
        WorldQueryIntent::terrain_collision});
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute(request));
    request.world_numeric[0].intent = WorldQueryIntent::terrain_mesh;
    request.world_numeric[0].semantic_revision = 2;
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute(request));

    request = {};
    request.surface_projection_numeric.push_back(
        {{0, 0, 0}, WorldQueryIntent::gameplay});
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute(request));
    request.surface_projection_numeric[0].intent = WorldQueryIntent::terrain_collision;
    request.surface_projection_numeric[0].semantic_revision = 2;
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute(request));
}

VWB_TEST(native_effective_batch_prepared_payload_cap_covers_static_and_nested_dynamic_bytes) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatchRequest surface_request;
    surface_request.surface_columns.push_back({0, 0, WorldQueryIntent::gameplay});
    NativeEffectiveTerrainBatch baseline(
        ready_pin(definition, {0, 0}, empty_deltas()));
    const auto surface = baseline.execute(surface_request);
    VWB_EXPECT_EQ(42U, surface.prepared_payload_bytes);

    NativeEffectiveTerrainBatchLimits limits;
    limits.max_prepared_payload_bytes = surface.prepared_payload_bytes;
    NativeEffectiveTerrainBatch exact_static(
        ready_pin(definition, {0, 0}, empty_deltas()), limits);
    VWB_EXPECT_EQ(surface.prepared_payload_bytes,
        exact_static.execute(surface_request).prepared_payload_bytes);
    --limits.max_prepared_payload_bytes;
    NativeEffectiveTerrainBatch below_static(
        ready_pin(definition, {0, 0}, empty_deltas()), limits);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::prepared_payload_limit,
        rejected_reason(below_static, surface_request));

    NativeEffectiveTerrainBatchRequest edited_request;
    edited_request.cell_centers.push_back(
        {{1, 0, 0}, WorldQueryIntent::gameplay});
    NativeEffectiveTerrainBatch no_optional_strings(
        ready_pin(definition, {0, 0}, metadata_deltas("x", false)));
    const auto small = no_optional_strings.execute(edited_request);
    NativeEffectiveTerrainBatch large_metadata(
        ready_pin(definition, {0, 0}, metadata_deltas(std::string(2048, 'm'), true)));
    const auto large = large_metadata.execute(edited_request);
    VWB_EXPECT(large.prepared_payload_bytes > small.prepared_payload_bytes + 2046U);
    const NativeCellState &retained = *large.cell_centers[0].edited_sparse_state;
    const std::size_t expected_large_bytes = 42U + 54U
        + retained.metadata.canonical_binary().size()
        + retained.block_id->value().size() + retained.edit_reason->size();
    VWB_EXPECT_EQ(expected_large_bytes, large.prepared_payload_bytes);

    limits = {};
    limits.max_prepared_payload_bytes = large.prepared_payload_bytes;
    NativeEffectiveTerrainBatch exact_dynamic(
        ready_pin(definition, {0, 0}, metadata_deltas(std::string(2048, 'm'), true)),
        limits);
    VWB_EXPECT_EQ(large.prepared_payload_bytes,
        exact_dynamic.execute(edited_request).prepared_payload_bytes);
    --limits.max_prepared_payload_bytes;
    NativeEffectiveTerrainBatch below_dynamic(
        ready_pin(definition, {0, 0}, metadata_deltas(std::string(2048, 'm'), true)),
        limits);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::prepared_payload_limit,
        rejected_reason(below_dynamic, edited_request));

    edited_request.cell_centers.push_back(
        {{1, 0, 0}, WorldQueryIntent::gameplay});
    const auto duplicated = large_metadata.execute(edited_request);
    VWB_EXPECT_EQ(large.prepared_payload_bytes * 2U,
        duplicated.prepared_payload_bytes);
    limits.max_prepared_payload_bytes = large.prepared_payload_bytes;
    NativeEffectiveTerrainBatch duplicate_limited(
        ready_pin(definition, {0, 0}, metadata_deltas(std::string(2048, 'm'), true)),
        limits);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::prepared_payload_limit,
        rejected_reason(duplicate_limited, edited_request));

    // Admission must reject from a bounded canonical-size walk; the batch
    // implementation must not serialize this maximum-size metadata string
    // merely to discover that only one byte remains.
    NativeEffectiveTerrainBatchRequest maximum_metadata_request;
    maximum_metadata_request.cell_centers.push_back(
        {{1, 0, 0}, WorldQueryIntent::gameplay});
    limits = {};
    limits.max_prepared_payload_bytes = 42U + 54U + 3U + 1U;
    NativeEffectiveTerrainBatch maximum_metadata_limited(
        ready_pin(definition, {0, 0}, metadata_deltas(
            std::string(NativeValueLimits::MAX_STRING_BYTES, 'm'), true)),
        limits);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::prepared_payload_limit,
        rejected_reason(maximum_metadata_limited, maximum_metadata_request));
}

VWB_TEST(native_effective_batch_rejects_mixed_invalid_queries_without_observable_partial_result) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatch batch(ready_pin(definition, {0, 0}, empty_deltas()));
    NativeEffectiveTerrainBatchRequest request;
    request.surface_columns = {
        {0, 0, WorldQueryIntent::gameplay},
        {1000000, 1000000, WorldQueryIntent::gameplay},
    };
    VWB_EXPECT_THROW(std::out_of_range, batch.execute(request));

    request = {};
    request.world_numeric = {
        {{0.0F, 0.0F, 0.0F}},
        {{1000000.0F, 0.0F, 1000000.0F}},
    };
    VWB_EXPECT_THROW(std::out_of_range, batch.execute(request));

    request = {};
    request.cell_centers.push_back(
        {{0, 0, 0}, static_cast<WorldQueryIntent>(255)});
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute(request));

    request = {};
    request.world_numeric.push_back(
        {{std::numeric_limits<float>::quiet_NaN(), 0.0F, 0.0F}});
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute(request));

    // No mutable cursor or staged result survives rejection; the same pinned
    // wrapper remains usable and returns only this later valid request.
    request = {};
    request.surface_columns.push_back({0, 0, WorldQueryIntent::gameplay});
    const auto recovered = batch.execute(request);
    VWB_EXPECT_EQ(1U, recovered.surface_columns.size());
    VWB_EXPECT(recovered.cell_centers.empty());
    VWB_EXPECT(recovered.lattice_numeric.empty());
    VWB_EXPECT(recovered.world_numeric.empty());
    VWB_EXPECT(recovered.surface_projection_numeric.empty());
}

VWB_TEST(native_effective_projection_batch_preserves_order_full_states_fluid_and_positions) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatch batch(
        ready_pin(definition, {0, 0}, projection_deltas()));
    NativeEffectiveTerrainProjectionBatchRequest request;
    const NativeEffectiveSurfaceProjectionQuery surface{
        {20, 10, 0}, 1, 1, WorldQueryIntent::gameplay, 1};
    request.surface_projections = {surface, surface};
    request.walkable_projections = {surface, surface};
    const double known_y = 12.25 * definition.constants().cell_size_meters;
    request.known_height_projections = {
        {{21, 99, 0}, known_y, WorldQueryIntent::gameplay, 1},
        {{22, -99, 0}, known_y, WorldQueryIntent::gameplay, 1},
        {{21, 99, 0}, known_y, WorldQueryIntent::gameplay, 1},
    };
    const auto result = batch.execute_projections(request);
    VWB_EXPECT_EQ(NativeEffectiveTerrainProjectionBatchResult::SCHEMA_REVISION,
        result.schema_revision);
    VWB_EXPECT_EQ(batch.pin().physical_content_identity(), result.pin_physical_identity);
    VWB_EXPECT_EQ(batch.pin().terrain_delta_revision(), result.terrain_delta_revision);
    VWB_EXPECT_EQ(21U, result.admitted_vertical_candidates);
    VWB_EXPECT_EQ(41U, result.admitted_cell_reads);
    VWB_EXPECT(result.prepared_payload_bytes > 0U);
    VWB_EXPECT_EQ(2U, result.surface_projections.size());
    VWB_EXPECT_EQ(2U, result.walkable_projections.size());
    VWB_EXPECT_EQ(3U, result.known_height_projections.size());

    const auto &projected = result.surface_projections[0];
    VWB_EXPECT(projected.facts.found);
    VWB_EXPECT_EQ((CellCoord{20, 10, 0}), projected.facts.solid_cell);
    VWB_EXPECT_EQ((CellCoord{20, 11, 0}), projected.facts.air_cell);
    VWB_EXPECT(projected.facts.solid_state->solid);
    VWB_EXPECT(!projected.facts.air_state->solid);
    VWB_EXPECT_EQ(TerrainFluidId::water, projected.facts.air_state->fluid);
    VWB_EXPECT_EQ((NativeCellLight{3, 7}), projected.facts.air_state->light);
    const std::size_t one_surface_payload = 76U
        + projection_state_payload(*projected.facts.solid_state)
        + projection_state_payload(*projected.facts.air_state);
    VWB_EXPECT(one_surface_payload > 76U + 108U);
    NativeEffectiveTerrainProjectionBatchRequest one_surface_request;
    one_surface_request.surface_projections = {surface};
    VWB_EXPECT_EQ(one_surface_payload,
        batch.execute_projections(one_surface_request).prepared_payload_bytes);
    VWB_EXPECT_EQ(projected.facts.solid_cell,
        result.surface_projections[1].facts.solid_cell);
    VWB_EXPECT_EQ(projected.facts.air_state,
        result.surface_projections[1].facts.air_state);
    const float expected_center_x = static_cast<float>(20.5
        * definition.constants().cell_size_meters);
    VWB_EXPECT_EQ(expected_center_x, projected.facts.position.x);
    VWB_EXPECT_EQ(static_cast<float>(11.0 * definition.constants().cell_size_meters),
        projected.facts.position.y);

    const auto &walkable = result.walkable_projections[0].facts;
    VWB_EXPECT(walkable.projection.found && walkable.walkable);
    VWB_EXPECT(walkable.headroom_state.has_value());
    VWB_EXPECT(!walkable.headroom_state->solid);
    VWB_EXPECT(walkable.occupancy.has_value());
    VWB_EXPECT(walkable.occupancy->walkable_air);
    VWB_EXPECT(walkable.occupancy->floor_solid);
    VWB_EXPECT(!walkable.occupancy->ceiling_solid);
    // Legacy walkability is solidity/headroom based: fluid in the standing
    // cell remains visible in the full state but does not make it unwalkable.
    VWB_EXPECT_EQ(TerrainFluidId::water, walkable.occupancy->fluid);

    const auto &third_candidate = result.known_height_projections[0].facts;
    VWB_EXPECT_EQ(NativeKnownHeightProjectionStatus::ready, third_candidate.status);
    VWB_EXPECT_EQ((CellCoord{21, 10, 0}), third_candidate.projection.solid_cell);
    VWB_EXPECT_EQ((CellCoord{21, 11, 0}), third_candidate.projection.air_cell);
    VWB_EXPECT(third_candidate.walkable && third_candidate.occupancy->walkable_air);
    VWB_EXPECT_EQ(static_cast<float>(21.0 * definition.constants().cell_size_meters),
        third_candidate.projection.position.x);
    VWB_EXPECT_EQ(static_cast<float>(known_y), third_candidate.projection.position.y);
    // A fourth candidate at y=9 would succeed in this column.  The current
    // GDScript range has exactly three candidates, notwithstanding its stale
    // nearby "four cells" comment, so the native shadow must mismatch.
    const auto &no_fourth = result.known_height_projections[1].facts;
    VWB_EXPECT_EQ(NativeKnownHeightProjectionStatus::mismatch, no_fourth.status);
    VWB_EXPECT(!no_fourth.projection.found);
    VWB_EXPECT(!no_fourth.headroom_state.has_value());
    VWB_EXPECT(!no_fourth.occupancy.has_value());
    VWB_EXPECT_EQ(third_candidate.projection.solid_cell,
        result.known_height_projections[2].facts.projection.solid_cell);
}

VWB_TEST(native_effective_projection_batch_matches_edit_precedence_clamps_and_empty_results) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatch batch(
        ready_pin(definition, {0, 0}, projection_deltas()));
    NativeEffectiveTerrainProjectionBatchRequest request;
    request.surface_projections = {
        {{24, 10, 0}, 4, 4, WorldQueryIntent::gameplay, 1},
        {{25, 10, 0}, 4, 4, WorldQueryIntent::gameplay, 1},
        {{23, 10, 0}, 1, 1, WorldQueryIntent::gameplay, 1},
        {{26, 10, 0}, 1, 1, WorldQueryIntent::gameplay, 1},
        {{29, 8, 0}, 1, 1, WorldQueryIntent::gameplay, 1},
        {{20, -1000, 0}, 1, 1, WorldQueryIntent::gameplay, 1},
    };
    request.walkable_projections = {
        {{27, 10, 0}, 1, 1, WorldQueryIntent::gameplay, 1},
        {{26, 10, 0}, 1, 1, WorldQueryIntent::gameplay, 1},
    };
    request.known_height_projections = {
        {{28, 0, 0}, 12.25 * definition.constants().cell_size_meters,
            WorldQueryIntent::gameplay, 1},
        {{29, 0, 0}, 9.25 * definition.constants().cell_size_meters,
            WorldQueryIntent::gameplay, 1},
        {{27, 0, 0}, 10.25 * definition.constants().cell_size_meters,
            WorldQueryIntent::gameplay, 1},
    };
    const auto result = batch.execute_projections(request);
    VWB_EXPECT_EQ((CellCoord{24, 12, 0}),
        result.surface_projections[0].facts.solid_cell);
    VWB_EXPECT_EQ((CellCoord{25, 8, 0}),
        result.surface_projections[1].facts.solid_cell);
    VWB_EXPECT_EQ((CellCoord{23, 9, 0}),
        result.surface_projections[2].facts.solid_cell);
    VWB_EXPECT(!result.surface_projections[2].facts.solid_state->generated);
    VWB_EXPECT(!result.surface_projections[3].facts.found);
    VWB_EXPECT(!result.surface_projections[3].facts.solid_state.has_value());
    VWB_EXPECT(!result.surface_projections[3].facts.air_state.has_value());
    VWB_EXPECT(!result.surface_projections[4].facts.found);
    VWB_EXPECT(!result.surface_projections[5].facts.found);
    VWB_EXPECT(!result.walkable_projections[0].facts.walkable);
    VWB_EXPECT(result.walkable_projections[0].facts.occupancy.has_value());
    VWB_EXPECT(result.walkable_projections[0].facts.occupancy->ceiling_solid);
    VWB_EXPECT(!result.walkable_projections[0].facts.occupancy->walkable_air);
    VWB_EXPECT(!result.walkable_projections[1].facts.projection.found);
    VWB_EXPECT(!result.walkable_projections[1].facts.occupancy.has_value());
    VWB_EXPECT_EQ(NativeKnownHeightProjectionStatus::ready,
        result.known_height_projections[0].facts.status);
    VWB_EXPECT_EQ((CellCoord{28, 11, 0}),
        result.known_height_projections[0].facts.projection.solid_cell);
    VWB_EXPECT_EQ(NativeKnownHeightProjectionStatus::mismatch,
        result.known_height_projections[1].facts.status);
    VWB_EXPECT_EQ(NativeKnownHeightProjectionStatus::mismatch,
        result.known_height_projections[2].facts.status);

    NativeEffectiveTerrainBatch negative(
        ready_pin(definition, {-1, -1}, projection_deltas()));
    request = {};
    request.surface_projections = {
        {{-1, 13, -1}, std::numeric_limits<std::int32_t>::max(), -9,
            WorldQueryIntent::gameplay, 1},
        {{-2, -63, -1}, -4, std::numeric_limits<std::int32_t>::max(),
            WorldQueryIntent::gameplay, 1},
    };
    const auto clamped = negative.execute_projections(request);
    VWB_EXPECT_EQ((CellCoord{-1, 14, -1}),
        clamped.surface_projections[0].facts.solid_cell);
    VWB_EXPECT_EQ((CellCoord{-2, -63, -1}),
        clamped.surface_projections[1].facts.solid_cell);
    VWB_EXPECT_EQ(static_cast<float>(-0.5 * definition.constants().cell_size_meters),
        clamped.surface_projections[0].facts.position.x);
    VWB_EXPECT_EQ(6U, clamped.admitted_vertical_candidates);

    // maxi(1, maxUp/maxDown) is part of the GDScript contract.
    request.surface_projections[0].max_up_cells = 1;
    request.surface_projections[0].max_down_cells = 1;
    request.surface_projections[1].max_up_cells = 1;
    request.surface_projections[1].max_down_cells = 1;
    const auto normalized = negative.execute_projections(request);
    VWB_EXPECT_EQ(clamped.surface_projections[0].facts.solid_cell,
        normalized.surface_projections[0].facts.solid_cell);
    VWB_EXPECT_EQ(clamped.surface_projections[1].facts.solid_cell,
        normalized.surface_projections[1].facts.solid_cell);
}

VWB_TEST(native_effective_projection_batch_enforces_query_vertical_payload_and_atomic_limits) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatchLimits limits;
    limits.max_surface_projections = 1;
    limits.max_walkable_projections = 1;
    limits.max_known_height_projections = 1;
    NativeEffectiveTerrainBatch batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    const NativeEffectiveSurfaceProjectionQuery query{
        {20, 10, 0}, 1, 1, WorldQueryIntent::gameplay, 1};
    const NativeEffectiveKnownHeightProjectionQuery known{
        {21, 0, 0}, 12.25 * definition.constants().cell_size_meters,
        WorldQueryIntent::gameplay, 1};
    NativeEffectiveTerrainProjectionBatchRequest request;
    request.surface_projections = {query, query};
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::surface_projection_limit,
        projection_rejected_reason(batch, request));
    request = {}; request.walkable_projections = {query, query};
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::walkable_projection_limit,
        projection_rejected_reason(batch, request));
    request = {}; request.known_height_projections = {known, known};
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::known_height_projection_limit,
        projection_rejected_reason(batch, request));

    limits.max_projection_total_queries = 1;
    NativeEffectiveTerrainBatch total_batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    request = {}; request.surface_projections = {query}; request.walkable_projections = {query};
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::projection_total_limit,
        projection_rejected_reason(total_batch, request));

    limits.max_projection_total_queries = 4096;
    limits.max_projection_vertical_candidates_per_query = 2;
    NativeEffectiveTerrainBatch per_query_batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    request = {}; request.known_height_projections = {known};
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::projection_vertical_per_query_limit,
        projection_rejected_reason(per_query_batch, request));

    limits.max_projection_vertical_candidates_per_query = 512;
    limits.max_projection_total_vertical_candidates = 5;
    request.known_height_projections = {known, known};
    limits.max_known_height_projections = 2;
    NativeEffectiveTerrainBatch vertical_total_batch_two(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::projection_vertical_total_limit,
        projection_rejected_reason(vertical_total_batch_two, request));

    limits.max_projection_total_vertical_candidates = 65536;
    limits.max_projection_cell_reads_per_query = 4;
    NativeEffectiveTerrainBatch cell_reads_per_query_batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    request.known_height_projections = {known};
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::projection_cell_reads_per_query_limit,
        projection_rejected_reason(cell_reads_per_query_batch, request));
    limits.max_projection_cell_reads_per_query = 1025;
    limits.max_projection_total_cell_reads = 9;
    NativeEffectiveTerrainBatch cell_reads_total_batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    request.known_height_projections = {known, known};
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::projection_cell_reads_total_limit,
        projection_rejected_reason(cell_reads_total_batch, request));

    NativeEffectiveTerrainBatch baseline(
        ready_pin(definition, {0, 0}, projection_deltas()));
    request = {}; request.surface_projections = {query};
    const auto accepted = baseline.execute_projections(request);
    limits = {};
    limits.max_projection_payload_bytes = accepted.prepared_payload_bytes - 1U;
    NativeEffectiveTerrainBatch payload_batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::projection_payload_limit,
        projection_rejected_reason(payload_batch, request));
    limits.max_projection_payload_bytes = 75U;
    NativeEffectiveTerrainBatch fixed_payload_batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::projection_payload_limit,
        projection_rejected_reason(fixed_payload_batch, request));
    limits.max_projection_payload_bytes = accepted.prepared_payload_bytes;
    NativeEffectiveTerrainBatch exact_payload_batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    VWB_EXPECT_EQ(accepted.prepared_payload_bytes,
        exact_payload_batch.execute_projections(request).prepared_payload_bytes);

    const NativeEffectiveKnownHeightProjectionQuery known_miss{
        {21, 0, 0}, -1000000.0, WorldQueryIntent::gameplay, 1};
    request = {};
    request.known_height_projections = {known_miss};
    const auto known_fixed = baseline.execute_projections(request);
    VWB_EXPECT_EQ(102U, known_fixed.prepared_payload_bytes);
    VWB_EXPECT_EQ(NativeKnownHeightProjectionStatus::mismatch,
        known_fixed.known_height_projections[0].facts.status);
    limits = {};
    limits.max_projection_payload_bytes = 102U;
    NativeEffectiveTerrainBatch exact_known_payload_batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    VWB_EXPECT_EQ(102U,
        exact_known_payload_batch.execute_projections(request).prepared_payload_bytes);
    limits.max_projection_payload_bytes = 101U;
    NativeEffectiveTerrainBatch over_known_payload_batch(
        ready_pin(definition, {0, 0}, projection_deltas()), limits);
    VWB_EXPECT_EQ(NativeEffectiveTerrainBatchRejectReason::projection_payload_limit,
        projection_rejected_reason(over_known_payload_batch, request));

    request.surface_projections.push_back({
        {1000000, 10, 1000000}, 1, 1, WorldQueryIntent::gameplay, 1});
    VWB_EXPECT_THROW(std::out_of_range, baseline.execute_projections(request));
    request = {}; request.surface_projections = {query};
    VWB_EXPECT_EQ(1U, baseline.execute_projections(request).surface_projections.size());
}

VWB_TEST(native_effective_projection_queries_reject_invalid_semantics_and_domain) {
    const auto definition = flat_definition();
    NativeEffectiveTerrainBatch batch(
        ready_pin(definition, {0, 0}, projection_deltas()));
    NativeEffectiveTerrainProjectionBatchRequest request;
    request.surface_projections.push_back(
        {{20, 10, 0}, 1, 1, WorldQueryIntent::terrain_collision, 1});
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute_projections(request));
    request.surface_projections[0].intent = WorldQueryIntent::gameplay;
    request.surface_projections[0].semantic_revision = 2;
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute_projections(request));
    request = {};
    request.known_height_projections.push_back(
        {{21, 0, 0}, std::numeric_limits<double>::quiet_NaN(),
            WorldQueryIntent::gameplay, 1});
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute_projections(request));
    request.known_height_projections[0].surface_y = 13.0;
    request.known_height_projections[0].intent = WorldQueryIntent::terrain_collision;
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute_projections(request));
    request.known_height_projections[0].intent = WorldQueryIntent::gameplay;
    request.known_height_projections[0].semantic_revision = 2;
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute_projections(request));
    request.known_height_projections[0].semantic_revision = 1;
    request.known_height_projections[0].surface_y =
        static_cast<double>(std::numeric_limits<std::int32_t>::max())
            * definition.constants().cell_size_meters;
    VWB_EXPECT_THROW(std::invalid_argument, batch.execute_projections(request));

    const auto tall = tall_definition();
    NativeEffectiveTerrainBatch tall_batch(
        ready_pin(tall, {0, 0}, empty_deltas()));
    request = {};
    request.surface_projections.push_back(
        {{0, 0, 0}, 1000, 1000, WorldQueryIntent::gameplay, 1});
    VWB_EXPECT_THROW(std::length_error, tall_batch.execute_projections(request));

    const auto int32_top = int32_top_definition();
    NativeEffectiveTerrainBatch int32_top_batch(
        ready_pin(int32_top, {0, 0}, empty_deltas()));
    request.surface_projections[0] =
        {{0, 0, 0}, 1, 1, WorldQueryIntent::gameplay, 1};
    VWB_EXPECT_THROW(std::invalid_argument,
        int32_top_batch.execute_projections(request));
}
