#include "test_harness.hpp"

#include "../core/native_terrain_volume_v2_import_builder.hpp"

#include <string>
#include <limits>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

NativeTypedWorldStateRecord record(const CellCoord cell) {
    NativeCellStateInput input;
    input.cell = cell;
    input.material = TerrainMaterialId::stone;
    input.biome = TerrainBiomeId::underground;
    input.solid = true;
    input.density = 1.25;
    input.metadata = NativeValue::object({{"saveDelta", NativeValue::boolean(true)}});
    input.block_id = NativeBlockIdentity::create("terrain.import.test");
    input.edit_reason = "import_test";
    input.generated = false;
    input.edited = true;
    return {NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable, make_native_cell_state(input)};
}

NativeTerrainVolumeV2ImportIdentity identity(const std::uint64_t revision = 7U) {
    return {"terrainVolume", 1U, 16U, revision};
}

NativeTerrainVolumeV2ImportChunk chunk(
    const CellCoord section, const std::uint64_t revision,
    std::vector<NativeTypedWorldStateRecord> records) {
    return {section, revision, std::move(records)};
}

} // namespace

VWB_TEST(native_terrain_volume_v2_import_builder_matches_decode_across_chunk_splits) {
    const auto first = record({0, 0, 0});
    const auto second = record({1, 0, 0});
    const auto third = record({0, 0, 16});
    NativeTerrainVolumeV2ImportBuilder whole;
    whole.begin(identity());
    whole.append({chunk({0, 0, 0}, 3U, {first, second}), chunk({0, 0, 1}, 4U, {third})});
    VWB_EXPECT_EQ(3U, whole.record_count());
    VWB_EXPECT_EQ(2U, whole.section_count());
    const NativeTerrainVolumeV2 whole_result = whole.finalize();

    NativeTerrainVolumeV2ImportBuilder split(2U);
    split.begin(identity());
    split.append({chunk({0, 0, 0}, 3U, {first})});
    split.append({chunk({0, 0, 0}, 3U, {second}), chunk({0, 0, 1}, 4U, {third})});
    const NativeTerrainVolumeV2 split_result = split.finalize();
    VWB_EXPECT_EQ(whole_result, split_result);
    VWB_EXPECT_EQ(whole_result, decode_native_terrain_volume_v2(encode_native_terrain_volume_v2(whole_result)));
    VWB_EXPECT(!whole.active());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, whole.finalize());
}

VWB_TEST(native_terrain_volume_v2_import_builder_rejects_identity_and_append_caps) {
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, NativeTerrainVolumeV2ImportBuilder(0U));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
        NativeTerrainVolumeV2ImportBuilder(NativeTerrainVolumeV2ImportBuilder::MAX_RECORDS_PER_APPEND + 1U));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, NativeTerrainVolumeV2ImportBuilder(1U, 0U));

    NativeTerrainVolumeV2ImportBuilder bad_identity;
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, bad_identity.begin({"playerBlocks", 1U, 16U, 1U}));
    VWB_EXPECT(!bad_identity.active());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, bad_identity.begin(identity()));

    NativeTerrainVolumeV2ImportBuilder builder(1U);
    builder.begin(identity());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
        builder.append({chunk({0, 0, 0}, 1U, {record({0, 0, 0}), record({1, 0, 0})})}));
    VWB_EXPECT(!builder.active());
    VWB_EXPECT_EQ(0U, builder.record_count());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.finalize());
}

VWB_TEST(native_terrain_volume_v2_import_builder_rejects_duplicate_reversed_and_missing_input) {
    const auto zero = record({0, 0, 0});
    const auto one = record({1, 0, 0});
    {
        NativeTerrainVolumeV2ImportBuilder builder;
        builder.begin(identity());
        builder.append({chunk({0, 0, 0}, 1U, {zero})});
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
            builder.append({chunk({0, 0, 0}, 1U, {zero})}));
        VWB_EXPECT_EQ(1U, builder.record_count());
        VWB_EXPECT(!builder.active());
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.finalize());
        VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
        VWB_EXPECT_EQ(0U, builder.record_count());
        VWB_EXPECT_EQ(1U, builder.section_count());
        VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
        VWB_EXPECT(builder.disposal_complete());
    }
    {
        NativeTerrainVolumeV2ImportBuilder builder;
        builder.begin(identity());
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
            builder.append({chunk({0, 0, 0}, 1U, {one, zero})}));
    }
    {
        NativeTerrainVolumeV2ImportBuilder builder;
        builder.begin(identity());
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
            builder.append({chunk({0, 0, 1}, 2U, {record({0, 0, 16})}),
                chunk({0, 0, 0}, 1U, {zero})}));
    }
    {
        NativeTerrainVolumeV2ImportBuilder builder;
        builder.begin(identity());
        builder.append({chunk({0, 0, 0}, 1U, {zero})});
        builder.append({chunk({1, 0, 0}, 2U, {record({16, 0, 0})})});
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
            builder.append({chunk({0, 0, 0}, 1U, {one})}));
        VWB_EXPECT_EQ(2U, builder.record_count());
        VWB_EXPECT_EQ(2U, builder.section_count());
        VWB_EXPECT_EQ(3U, builder.dispose_step(3U));
        VWB_EXPECT_EQ(0U, builder.record_count());
        VWB_EXPECT_EQ(1U, builder.section_count());
        VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
        VWB_EXPECT(builder.disposal_complete());
    }
    {
        NativeTerrainVolumeV2ImportBuilder builder;
        builder.begin(identity());
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
            builder.append({chunk({0, 0, 0}, 1U, {})}));
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.finalize());
    }
    {
        NativeTerrainVolumeV2ImportBuilder builder;
        builder.begin(identity());
        builder.append({chunk({0, 0, 0}, 1U, {zero})});
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
            builder.append({chunk({0, 0, 0}, 2U, {one})}));
    }
    {
        NativeTerrainVolumeV2ImportBuilder builder;
        builder.begin(identity());
        builder.append({chunk({0, 0, 0}, 1U, {zero})});
        auto malformed = record({1, 0, 0});
        malformed.state.local_cell.x = 16;
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
            builder.append({chunk({0, 0, 0}, 1U, {malformed})}));
        VWB_EXPECT(!builder.active());
        VWB_EXPECT_EQ(1U, builder.record_count());
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
            builder.append({chunk({0, 0, 0}, 1U, {one})}));
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.finalize());
        VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
        VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
        VWB_EXPECT(builder.disposal_complete());
    }
    {
        NativeTerrainVolumeV2ImportBuilder builder(2U, 2U);
        builder.begin(identity());
        builder.append({chunk({0, 0, 0}, 1U, {zero, one})});
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
            builder.append({chunk({0, 0, 0}, 1U, {record({2, 0, 0})})}));
        VWB_EXPECT_EQ(2U, builder.record_count());
        VWB_EXPECT_EQ(2U, builder.dispose_step(2U));
        VWB_EXPECT_EQ(0U, builder.record_count());
        VWB_EXPECT_EQ(1U, builder.section_count());
        VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
        VWB_EXPECT(builder.disposal_complete());
    }
}

VWB_TEST(native_terrain_volume_v2_import_builder_rejects_same_section_revision_change_and_drains) {
    NativeTerrainVolumeV2ImportBuilder builder;
    builder.begin(identity());
    builder.append({chunk({0, 0, 0}, 1U, {record({0, 0, 0})})});

    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
        builder.append({chunk({0, 0, 0}, 2U, {record({1, 0, 0})})}));
    VWB_EXPECT(!builder.active());
    VWB_EXPECT_EQ(1U, builder.record_count());
    VWB_EXPECT_EQ(1U, builder.section_count());
    VWB_EXPECT(!builder.disposal_complete());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.finalize());

    VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
    VWB_EXPECT_EQ(0U, builder.record_count());
    VWB_EXPECT_EQ(1U, builder.section_count());
    VWB_EXPECT(!builder.disposal_complete());
    VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
    VWB_EXPECT_EQ(0U, builder.record_count());
    VWB_EXPECT_EQ(0U, builder.section_count());
    VWB_EXPECT(builder.disposal_complete());
}

VWB_TEST(native_terrain_volume_v2_import_builder_accepts_full_production_capacity_in_bounded_appends) {
    NativeTerrainVolumeV2ImportBuilder builder(
        NativeTerrainVolumeV2ImportBuilder::MAX_RECORDS_PER_APPEND);
    builder.begin(identity(19U));
    for (std::int32_t section_x = 0; section_x < 16; ++section_x) {
        std::vector<NativeTypedWorldStateRecord> records;
        records.reserve(NativeTerrainVolumeV2Limits::MAX_CELLS_PER_SECTION);
        for (std::int32_t z = 0; z < 16; ++z) {
            for (std::int32_t y = 0; y < 16; ++y) {
                for (std::int32_t x = 0; x < 16; ++x) {
                    records.push_back(record({section_x * 16 + x, y, z}));
                }
            }
        }
        builder.append({chunk({section_x, 0, 0},
            static_cast<std::uint64_t>(section_x + 1), std::move(records))});
        VWB_EXPECT_EQ(static_cast<std::size_t>(section_x + 1) * 4096U, builder.record_count());
    }
    const NativeTerrainVolumeV2 full = builder.finalize();
    VWB_EXPECT_EQ(NativeTerrainVolumeV2Limits::DEFAULT_MAX_RECORDS,
        full.durable_snapshot.records().size());
    VWB_EXPECT_EQ(16U, full.section_revisions.size());
}

VWB_TEST(native_terrain_volume_v2_import_builder_abandons_only_unfinalized_input) {
    NativeTerrainVolumeV2ImportBuilder builder;
    builder.begin(identity());
    builder.append({chunk({0, 0, 0}, 1U, {record({0, 0, 0})})});
    VWB_EXPECT(builder.abandon());
    VWB_EXPECT(!builder.abandon());
    VWB_EXPECT_EQ(1U, builder.record_count());
    VWB_EXPECT_EQ(1U, builder.section_count());
    VWB_EXPECT(!builder.active());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.finalize());
    VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
    VWB_EXPECT_EQ(0U, builder.record_count());
    VWB_EXPECT_EQ(1U, builder.section_count());
    VWB_EXPECT(!builder.disposal_complete());
    VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
    VWB_EXPECT(builder.disposal_complete());
    VWB_EXPECT_EQ(0U, builder.dispose_step(1U));

    NativeTerrainVolumeV2ImportBuilder empty;
    empty.begin(identity());
    VWB_EXPECT(empty.abandon());
    VWB_EXPECT(empty.disposal_complete());
    VWB_EXPECT_EQ(0U, empty.dispose_step(1U));

    NativeTerrainVolumeV2ImportBuilder finalized;
    finalized.begin(identity());
    const NativeTerrainVolumeV2 result = finalized.finalize();
    VWB_EXPECT_EQ(7U, result.revision);
    VWB_EXPECT(!finalized.abandon());
}

VWB_TEST(native_terrain_volume_v2_import_builder_defers_finalize_failure_cleanup_to_bounded_steps) {
    NativeTerrainVolumeV2ImportBuilder builder;
    builder.begin(identity());
    auto invalid_durable_record = record({0, 0, 0});
    invalid_durable_record.state.metadata = NativeValue::object({
        {"saveDelta", NativeValue::boolean(false)}});
    builder.append({chunk({0, 0, 0}, 1U, {invalid_durable_record})});

    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.finalize());
    VWB_EXPECT(!builder.active());
    VWB_EXPECT_EQ(1U, builder.record_count());
    VWB_EXPECT_EQ(1U, builder.section_count());
    VWB_EXPECT(!builder.disposal_complete());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.finalize());
    VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
    VWB_EXPECT_EQ(0U, builder.record_count());
    VWB_EXPECT_EQ(1U, builder.section_count());
    VWB_EXPECT_EQ(1U, builder.dispose_step(1U));
    VWB_EXPECT(builder.disposal_complete());
}

VWB_TEST(native_terrain_volume_v2_import_builder_rejects_each_envelope_identity_boundary) {
    const std::vector<NativeTerrainVolumeV2ImportIdentity> invalid = {
        {"terrainVolume", 2U, 16U, 7U},
        {"terrainVolume", 1U, 8U, 7U},
        identity(9007199254740993ULL),
    };
    for (const auto &candidate : invalid) {
        NativeTerrainVolumeV2ImportBuilder builder;
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.begin(candidate));
        VWB_EXPECT(!builder.active());
        VWB_EXPECT(builder.disposal_complete());
    }
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
        NativeTerrainVolumeV2ImportBuilder(1U, NativeTerrainVolumeV2Limits::DEFAULT_MAX_RECORDS + 1U));
    NativeTerrainVolumeV2ImportBuilder already_started;
    already_started.begin(identity());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, already_started.begin(identity()));
}

VWB_TEST(native_terrain_volume_v2_import_builder_rejects_invalid_chunk_boundaries) {
    const auto first = record({0, 0, 0});
    const auto second = record({1, 0, 0});
    const std::vector<NativeTerrainVolumeV2ImportChunk> invalid_chunks = {
        chunk({0, 0, 0}, 9007199254740993ULL, {first}),
        chunk({std::numeric_limits<std::int32_t>::max(), 0, 0}, 1U, {first}),
        chunk({0, 0, 0}, 1U, {record({16, 0, 0})}),
    };
    for (const auto &invalid : invalid_chunks) {
        NativeTerrainVolumeV2ImportBuilder builder;
        builder.begin(identity());
        VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, builder.append({invalid}));
        VWB_EXPECT(!builder.active());
        VWB_EXPECT(builder.disposal_complete());
    }
    NativeTerrainVolumeV2ImportBuilder over_batch(2U);
    over_batch.begin(identity());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
        over_batch.append({chunk({0, 0, 0}, 1U, {first, second}),
            chunk({0, 0, 1}, 2U, {record({0, 0, 16})})}));
    VWB_EXPECT_EQ(0U, over_batch.record_count());

    NativeTerrainVolumeV2ImportBuilder empty_append;
    empty_append.begin(identity());
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected, empty_append.append({}));
    VWB_EXPECT_EQ(0U, empty_append.dispose_step(0U));
}

VWB_TEST(native_terrain_volume_v2_import_builder_caps_total_even_for_first_append) {
    NativeTerrainVolumeV2ImportBuilder builder(2U, 1U);
    VWB_EXPECT(!builder.disposal_complete());
    VWB_EXPECT_EQ(0U, builder.dispose_step(1U));
    builder.begin(identity());
    VWB_EXPECT(!builder.disposal_complete());
    VWB_EXPECT_EQ(0U, builder.dispose_step(1U));
    VWB_EXPECT_THROW(NativeTerrainVolumeV2ImportBuilderRejected,
        builder.append({chunk({0, 0, 0}, 1U, {record({0, 0, 0}), record({1, 0, 0})})}));
    VWB_EXPECT(builder.disposal_complete());
    VWB_EXPECT_EQ(0U, builder.record_count());

    NativeTerrainVolumeV2ImportBuilder finalized;
    finalized.begin(identity());
    finalized.finalize();
    VWB_EXPECT(!finalized.disposal_complete());
    VWB_EXPECT_EQ(0U, finalized.dispose_step(1U));
}
