#include "test_harness.hpp"

#include "../core/native_effective_voxel_block.hpp"
#include "../core/native_terrain_shaping_registry.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

WorldSourceDefinition definition() {
    WorldSourceDescriptor descriptor;
    descriptor.raw_terrain_seed = admit_raw_terrain_seed("effective-voxel-block");
    descriptor.admitted_biome_seed = BiomeRegionField::admit_utf8_seed("effective-voxel-block");
    descriptor.revisions.terrain_generator_revision = 8;
    descriptor.revisions.lattice_query_revision = 6;
    descriptor.revisions.cell_center_query_revision = 7;
    descriptor.revisions.surface_column_query_revision = 8;
    descriptor.constants.minimum_surface_meters = 13.0;
    descriptor.constants.maximum_surface_meters = 13.0;
    return WorldSourceDefinition(std::move(descriptor));
}

std::vector<NativeTownRegionOverride> absent_towns(const NativeTerrainPageKey page) {
    std::vector<NativeTownRegionOverride> result;
    for (std::int32_t z = page.z - 1; z <= page.z + 1; ++z)
        for (std::int32_t x = page.x - 1; x <= page.x + 1; ++x)
            result.push_back({x, z, false, {}});
    return result;
}

WorldSourcePin ready_pin(const WorldSourceDefinition &source, const NativeTerrainPageKey primary,
                         const WorldDeltaPinnedSnapshot &deltas) {
    NativeSiteSourcePolicy policy;
    policy.engine_version_utf8 = "4.6.1.stable.official.14d19694e";
    policy.ordinary_region_cells = 140;
    policy.ordinary_spawn_chance = 0.08;
    NativeTerrainShapingRegistry registry(source, policy);
    const auto pages = world_effective_shaping_dependencies(source, primary);
    std::vector<NativeSiteSourceRegionKey> unresolved;
    for (const auto page : pages) {
        const auto provisional = registry.pin_page(page, absent_towns(page));
        for (const auto region : provisional.unresolved_dependencies())
            if (std::find(unresolved.begin(), unresolved.end(), region) == unresolved.end())
                unresolved.push_back(region);
    }
    NativeTerrainShapingRegistryBatch resolutions;
    resolutions.expected_revision = registry.revision();
    for (const auto region : unresolved) {
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
    for (const auto page : pages) pins.push_back(registry.pin_page(page, absent_towns(page)));
    return WorldSourcePin(source, deltas, primary, pins);
}

NativeCellState durable_edit(const CellCoord cell, const double density,
                             const TerrainMaterialId material) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = material;
    input.biome = TerrainBiomeId::plains;
    input.solid = density >= 0.0;
    input.density = density;
    input.fluid = material == TerrainMaterialId::water ? TerrainFluidId::water
        : material == TerrainMaterialId::lava ? TerrainFluidId::lava : TerrainFluidId::none;
    input.metadata = NativeValue::object({
        {"source", NativeValue::string("terrain_edit")},
        {"terrainMeshAffects", NativeValue::boolean(true)},
    });
    input.block_id = NativeBlockIdentity::create("voxel_block_test:"
        + std::to_string(cell.x) + ":" + std::to_string(cell.y) + ":" + std::to_string(cell.z));
    input.edit_reason = "voxel-block-test";
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input, NativeCellStateNamespace::durable_terrain);
}

WorldDeltaPinnedSnapshot deltas_with_edits(const std::vector<NativeCellState> &edits) {
    WorldDeltaStore store;
    if (!edits.empty()) {
        WorldTypedStateAdmission admission;
        admission.transaction_id = "voxel-block:edits";
        std::vector<NativeTypedWorldStateRecord> records;
        for (const auto &edit : edits) records.push_back({
            NativeCellStateNamespace::durable_terrain,
            NativeTypedWorldStatePersistence::durable, edit});
        admission.durable_snapshot = NativeTypedWorldStateSnapshot::create(std::move(records));
        static_cast<void>(store.admit_typed_state(admission));
    }
    return store.pin();
}

std::uint16_t raw_sdf(const NativeEffectiveVoxelBlock &block, const std::size_t i) {
    return static_cast<std::uint16_t>(block.sdf16_le[2U * i]
        | (static_cast<std::uint16_t>(block.sdf16_le[2U * i + 1U]) << 8U));
}

} // namespace

VWB_TEST(native_effective_voxel_block_zxy_order_and_golden_edit_bytes) {
    const auto def = definition();
    const auto deltas = [&]() { try { return deltas_with_edits({
        durable_edit({-2, 0, -2}, 0.0, TerrainMaterialId::grass),
        durable_edit({-2, 1, -2}, -1.35, TerrainMaterialId::air),
        durable_edit({-1, 0, -2}, 1.35, TerrainMaterialId::copper_ore),
        durable_edit({-1, 1, -2}, -1.35, TerrainMaterialId::lava),
        durable_edit({-2, 0, -1}, 675.0, TerrainMaterialId::bedrock),
        durable_edit({-2, 1, -1}, -675.0, TerrainMaterialId::water),
        durable_edit({-1, 0, -1}, 1.35, TerrainMaterialId::stone),
        durable_edit({-1, 1, -1}, 0.0, TerrainMaterialId::dirt),
    }); } catch (...) { throw std::runtime_error("negative edit admission failed"); } }();
    WorldSourcePin pin = [&]() {
        try { return ready_pin(def, {-1, -1}, deltas); }
        catch (...) { throw std::runtime_error("negative ready pin failed"); }
    }();
    NativeEffectiveTerrainSource source(std::move(pin));
    const auto block = [&]() {
        try { return encode_native_effective_voxel_block(source, {{-2, 0, -2}, {2, 2, 2}, 0}); }
        catch (...) { throw std::runtime_error("negative block encode failed"); }
    }();
    VWB_EXPECT_EQ(std::size_t{16}, block.sdf16_le.size());
    VWB_EXPECT_EQ(std::size_t{8}, block.indices8.size());
    // Independent installed-Godot VoxelBuffer.set_voxel_f oracle, generated by
    // artifacts/native-world-backend/n3-voxel-byte-encoder-focused/byte_oracle.gd.
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({0, 0, 65, 0, 191, 255, 65, 0,
        1, 128, 255, 127, 191, 255, 0, 0}), block.sdf16_le);
    VWB_EXPECT_EQ(std::uint16_t{0x8001}, raw_sdf(block, 4));
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({1, 0, 13, 3, 7, 15, 3, 2}), block.indices8);
    VWB_EXPECT_EQ(block.indices8, block.data5_8);
    VWB_EXPECT_EQ(source.pin().physical_content_identity(), block.pin_identity);
    VWB_EXPECT_EQ(source.pin().terrain_delta_revision(), block.terrain_delta_revision);
}

VWB_TEST(native_effective_voxel_block_lod_edits_and_stale_pin) {
    const auto def = definition();
    NativeEffectiveTerrainSource old_source(ready_pin(def, {0, 0}, deltas_with_edits({})));
    NativeEffectiveTerrainSource edited_source(ready_pin(def, {0, 0}, deltas_with_edits({
        durable_edit({2, 4, 2}, 0.0, TerrainMaterialId::iron_ore),
    })));
    const NativeEffectiveVoxelBlockRequest request{{0, 0, 0}, {2, 3, 2}, 1};
    const auto old_block = encode_native_effective_voxel_block(old_source, request);
    const auto edited_block = encode_native_effective_voxel_block(edited_source, request);
    const std::size_t edited_index = 2U + 3U * (1U + 2U * 1U);
    VWB_EXPECT_EQ(std::uint8_t{11}, edited_block.indices8[edited_index]);
    VWB_EXPECT(!(old_block.pin_identity == edited_block.pin_identity));
    VWB_EXPECT_EQ(old_source.pin().physical_content_identity(), old_block.pin_identity);
    VWB_EXPECT_EQ(std::size_t{12}, edited_block.indices8.size());
}

VWB_TEST(native_effective_voxel_block_rejects_invalid_bounds_atomically) {
    const auto def = definition();
    NativeEffectiveTerrainSource source(ready_pin(def, {0, 0}, deltas_with_edits({})));
    VWB_EXPECT_THROW(std::invalid_argument, encode_native_effective_voxel_block(source, {{0, 0, 0}, {0, 1, 1}, 0}));
    VWB_EXPECT_THROW(std::invalid_argument, encode_native_effective_voxel_block(source, {{0, 0, 0}, {1, 0, 1}, 0}));
    VWB_EXPECT_THROW(std::invalid_argument, encode_native_effective_voxel_block(source, {{0, 0, 0}, {1, 1, 0}, 0}));
    VWB_EXPECT_THROW(std::invalid_argument, encode_native_effective_voxel_block(source, {{0, 0, 0}, {33, 1, 1}, 0}));
    VWB_EXPECT_THROW(std::invalid_argument, encode_native_effective_voxel_block(source, {{0, 0, 0}, {1, 33, 1}, 0}));
    VWB_EXPECT_THROW(std::invalid_argument, encode_native_effective_voxel_block(source, {{0, 0, 0}, {1, 1, 33}, 0}));
    VWB_EXPECT_THROW(std::invalid_argument, encode_native_effective_voxel_block(source, {{0, 0, 0}, {1, 1, 1}, 25}));
    VWB_EXPECT_THROW(std::out_of_range, encode_native_effective_voxel_block(source, {{279, 0, 0}, {2, 1, 1}, 0}));
    VWB_EXPECT_THROW(std::out_of_range, encode_native_effective_voxel_block(source, {{-1, 0, 0}, {1, 1, 1}, 0}));
    VWB_EXPECT_THROW(std::out_of_range, encode_native_effective_voxel_block(source, {{0, std::numeric_limits<std::int32_t>::max(), 0}, {1, 2, 1}, 0}));
    const auto after = encode_native_effective_voxel_block(source, {{0, 0, 0}, {1, 1, 1}, 0});
    VWB_EXPECT_EQ(std::size_t{1}, after.indices8.size());
}

VWB_TEST(native_effective_voxel_block_material_channel_rejects_invalid_enum) {
    VWB_EXPECT_EQ(std::uint8_t{3}, native_voxel_material_channel_id(TerrainMaterialId::lava));
    VWB_EXPECT_EQ(std::uint8_t{15}, native_voxel_material_channel_id(TerrainMaterialId::water));
    VWB_EXPECT_THROW(std::invalid_argument,
        native_voxel_material_channel_id(static_cast<TerrainMaterialId>(255)));
}

VWB_TEST(native_effective_voxel_block_preserves_godot_sdf_threshold) {
    const auto def = definition();
    const auto deltas = deltas_with_edits({
        durable_edit({0, 0, 0}, -10.567796868800928, TerrainMaterialId::air),
    });
    NativeEffectiveTerrainSource source(ready_pin(def, {0, 0}, deltas));
    const auto block = encode_native_effective_voxel_block(source, {{0, 0, 0}, {1, 1, 1}, 0});
    // Independent installed-Godot VoxelBuffer oracle:
    // native_effective_voxel_threshold_oracle.gd emits raw 513 / [1, 2].
    VWB_EXPECT_EQ(std::vector<std::uint8_t>({1, 2}), block.sdf16_le);
}
