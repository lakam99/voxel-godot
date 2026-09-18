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
    VWB_EXPECT_EQ(34U, surface.prepared_payload_bytes);

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
