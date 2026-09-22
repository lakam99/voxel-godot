#include "test_harness.hpp"

#include "../core/native_world_deltas_v2_codec.hpp"

#include <algorithm>
#include <string>
#include <utility>
#include <vector>

using namespace voxel::world_backend;

namespace {

NativePlayerBlocksV2Catalog world_delta_catalog() {
    return NativePlayerBlocksV2Catalog::create({
        {"stoneBlock", 64U, true},
        {"door", 16U, true},
    });
}

NativeCellState durable_stone(const CellCoord cell, const std::string &reason = "test") {
    NativeCellStateInput input;
    input.cell = cell;
    input.block_id = NativeBlockIdentity::create("stone");
    input.material = TerrainMaterialId::stone;
    input.biome = TerrainBiomeId::plains;
    input.solid = true;
    input.density = 1.0;
    input.light = {4U, 2U};
    input.metadata = NativeValue::object({});
    input.edit_reason = reason;
    input.generated = false;
    input.edited = true;
    return make_native_cell_state(input, NativeCellStateNamespace::durable_terrain);
}

NativeTerrainVolumeV2 terrain_volume(
    const CellCoord cell = {1, 2, 3}, const std::uint64_t revision = 73U) {
    const NativeCellState state = durable_stone(cell);
    NativeTerrainVolumeV2 volume;
    volume.revision = revision;
    volume.durable_snapshot = NativeTypedWorldStateSnapshot::create({{
        NativeCellStateNamespace::durable_terrain,
        NativeTypedWorldStatePersistence::durable,
        state,
    }});
    volume.section_revisions = {{state.section, revision - 1U}};
    return volume;
}

NativeValue block_entry(
    const CellCoord cell, const double world_y = 2.5, const double facing = 0.25) {
    return NativeValue::object({
        {"cell", NativeValue::array({
            NativeValue::number(static_cast<double>(cell.x)),
            NativeValue::number(static_cast<double>(cell.y)),
            NativeValue::number(static_cast<double>(cell.z)),
        })},
        {"destroyed", NativeValue::boolean(false)},
        {"doorGroupId", NativeValue::string("")},
        {"doorPortalId", NativeValue::string("")},
        {"facing", NativeValue::number(facing)},
        {"jammed", NativeValue::boolean(false)},
        {"locked", NativeValue::boolean(false)},
        {"open", NativeValue::boolean(false)},
        {"type", NativeValue::string("stoneBlock")},
        {"worldY", NativeValue::number(world_y)},
    });
}

NativeWorldDeltasV2Payload payload(
    std::vector<std::string> removed = {"generated:tree:z", "generated:tree:a"},
    std::vector<NativeValue> blocks = {block_entry({8, 4, -2})}) {
    return {
        terrain_volume(),
        std::move(removed),
        std::move(blocks),
    };
}

NativeValue without_member(const NativeValue &value, const std::string &name) {
    NativeValue::Object object = value.as_object();
    object.erase(std::remove_if(object.begin(), object.end(), [&](const auto &member) {
        return member.first == name;
    }), object.end());
    return NativeValue::object(std::move(object));
}

} // namespace

VWB_TEST(native_world_deltas_v2_decodes_all_domains_into_one_zero_sequence_checkpoint) {
    const NativePlayerBlocksV2Catalog catalog = world_delta_catalog();
    const WorldDeltaInitialSnapshot decoded = decode_native_world_deltas_v2(payload(), catalog, {});

    VWB_EXPECT_EQ(0ULL, decoded.revision);
    VWB_EXPECT_EQ(73ULL, decoded.terrain_volume.revision);
    VWB_EXPECT_EQ(1U, decoded.terrain_volume.durable_snapshot.records().size());
    VWB_EXPECT(decoded.transient_overlays.empty());
    VWB_EXPECT_EQ(2U, decoded.feature_delta_snapshot.tombstones().size());
    VWB_EXPECT_EQ(std::string("generated:tree:a"),
        decoded.feature_delta_snapshot.tombstones()[0].feature_id);
    VWB_EXPECT_EQ(std::string("generated:tree:z"),
        decoded.feature_delta_snapshot.tombstones()[1].feature_id);
    VWB_EXPECT_EQ(1U, decoded.feature_delta_snapshot.player_created_instances().size());
    VWB_EXPECT((decoded.feature_delta_snapshot.player_created_instances()[0].cell == CellCoord{8, 4, -2}));
}

VWB_TEST(native_world_deltas_v2_roundtrips_nonempty_pinnable_terrain_and_blocks) {
    const NativePlayerBlocksV2Catalog catalog = world_delta_catalog();
    // WDS deliberately rejects live tombstone admission until the later
    // footprint catalog can invalidate generated geometry. Keep this pin
    // roundtrip nonempty in terrain and blocks; the combined tombstone+block
    // persistence value is covered independently below without weakening that
    // runtime safety boundary.
    const WorldDeltaInitialSnapshot decoded = decode_native_world_deltas_v2(
        payload({}, {block_entry({8, 4, -2})}), catalog, {});
    const WorldDeltaStore store({}, decoded);

    const NativeWorldDeltasV2Payload encoded = encode_native_world_deltas_v2(store.pin(), catalog);
    const WorldDeltaInitialSnapshot roundtrip = decode_native_world_deltas_v2(encoded, catalog, {});
    VWB_EXPECT_EQ(decoded.terrain_volume, roundtrip.terrain_volume);
    VWB_EXPECT_EQ(decoded.feature_delta_snapshot, roundtrip.feature_delta_snapshot);
    VWB_EXPECT_EQ(0ULL, roundtrip.revision);
}

VWB_TEST(native_world_deltas_v2_preserves_first_valid_free_block_and_normalizes_domain_order) {
    const NativePlayerBlocksV2Catalog catalog = world_delta_catalog();
    NativeWorldDeltasV2Payload raw = payload(
        {"zeta", "alpha"},
        {
            block_entry({4, 5, 6}, 5.25, 0.5),
            block_entry({4, 5, 6}, 99.0, 3.0),
            block_entry({7, 8, 9}, 8.25, 1.5),
            block_entry({10, 11, 12}, 11.25, 2.5),
        });

    const WorldDeltaInitialSnapshot decoded = decode_native_world_deltas_v2(
        raw, catalog, {{7, 8, 9}});
    VWB_EXPECT_EQ(std::string("alpha"), decoded.feature_delta_snapshot.tombstones()[0].feature_id);
    VWB_EXPECT_EQ(std::string("zeta"), decoded.feature_delta_snapshot.tombstones()[1].feature_id);
    VWB_EXPECT_EQ(2U, decoded.feature_delta_snapshot.player_created_instances().size());

    const auto &instances = decoded.feature_delta_snapshot.player_created_instances();
    const auto first = std::find_if(instances.begin(), instances.end(), [](const auto &instance) {
        return instance.cell == CellCoord{4, 5, 6};
    });
    VWB_EXPECT(first != instances.end());
    VWB_EXPECT_EQ(5.25, first->world_y);
    VWB_EXPECT(std::none_of(instances.begin(), instances.end(), [](const auto &instance) {
        return instance.cell == CellCoord{7, 8, 9};
    }));

}

VWB_TEST(native_world_deltas_v2_keeps_equal_text_valid_across_tombstone_and_block_domains) {
    const NativePlayerBlocksV2Catalog catalog = world_delta_catalog();
    const CellCoord cell = {-3, 7, 11};
    const std::string shared_id = native_player_block_v2_instance_id(cell);
    const WorldDeltaInitialSnapshot decoded = decode_native_world_deltas_v2(
        payload({shared_id}, {block_entry(cell)}), catalog, {});

    VWB_EXPECT_EQ(1U, decoded.feature_delta_snapshot.tombstones().size());
    VWB_EXPECT_EQ(1U, decoded.feature_delta_snapshot.player_created_instances().size());
    VWB_EXPECT_EQ(shared_id, decoded.feature_delta_snapshot.tombstones()[0].feature_id);
    VWB_EXPECT_EQ(shared_id, decoded.feature_delta_snapshot.player_created_instances()[0].instance_id);
}

VWB_TEST(native_world_deltas_v2_aborts_the_complete_decode_when_any_domain_is_malformed) {
    const NativePlayerBlocksV2Catalog catalog = world_delta_catalog();

    NativeWorldDeltasV2Payload bad_terrain = payload();
    bad_terrain.terrain_volume.section_revisions.clear();
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(bad_terrain, catalog, {}));

    NativeWorldDeltasV2Payload bad_removed = payload();
    bad_removed.removed_props = {"duplicate", "duplicate"};
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(bad_removed, catalog, {}));

    NativeWorldDeltasV2Payload bad_blocks = payload();
    bad_blocks.blocks = {without_member(block_entry({1, 2, 3}), "cell")};
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(bad_blocks, catalog, {}));
}

VWB_TEST(native_world_deltas_v2_preflights_independent_domains_and_combined_capacity) {
    const NativePlayerBlocksV2Catalog catalog = world_delta_catalog();
    const NativeWorldDeltasV2Payload valid = payload(
        {"generated:tree:a", "generated:tree:b"},
        {block_entry({8, 4, -2}), block_entry({9, 4, -2})});

    NativeWorldDeltasV2Limits exact;
    exact.max_terrain_records = 1U;
    exact.max_removed_props = 2U;
    exact.max_player_blocks = 2U;
    exact.max_persisted_records = 5U;
    const WorldDeltaInitialSnapshot decoded = decode_native_world_deltas_v2(valid, catalog, {}, exact);
    VWB_EXPECT_EQ(1U, decoded.terrain_volume.durable_snapshot.records().size());
    VWB_EXPECT_EQ(2U, decoded.feature_delta_snapshot.tombstones().size());
    VWB_EXPECT_EQ(2U, decoded.feature_delta_snapshot.player_created_instances().size());

    NativeWorldDeltasV2Limits too_little_terrain = exact;
    too_little_terrain.max_terrain_records = 0U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(valid, catalog, {}, too_little_terrain));

    NativeWorldDeltasV2Limits too_little_removed = exact;
    too_little_removed.max_removed_props = 1U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(valid, catalog, {}, too_little_removed));

    NativeWorldDeltasV2Limits too_little_blocks = exact;
    too_little_blocks.max_player_blocks = 1U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(valid, catalog, {}, too_little_blocks));

    NativeWorldDeltasV2Limits too_little_total = exact;
    too_little_total.max_persisted_records = 4U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(valid, catalog, {}, too_little_total));

    NativeWorldDeltasV2Limits removed_exceeds_remaining = exact;
    removed_exceeds_remaining.max_persisted_records = 1U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(valid, catalog, {}, removed_exceeds_remaining));
}

VWB_TEST(native_world_deltas_v2_rejects_invalid_limit_policies_before_record_validation) {
    const NativePlayerBlocksV2Catalog catalog = world_delta_catalog();
    NativeWorldDeltasV2Payload malformed = payload({}, {NativeValue::null()});

    NativeWorldDeltasV2Limits zero_total;
    zero_total.max_persisted_records = 0U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(malformed, catalog, {}, zero_total));

    NativeWorldDeltasV2Limits zero_removed;
    zero_removed.max_removed_props = 0U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(malformed, catalog, {}, zero_removed));

    NativeWorldDeltasV2Limits zero_blocks;
    zero_blocks.max_player_blocks = 0U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(malformed, catalog, {}, zero_blocks));

    NativeWorldDeltasV2Limits over_terrain;
    over_terrain.max_terrain_records = NativeTerrainVolumeV2Limits::DEFAULT_MAX_RECORDS + 1U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(malformed, catalog, {}, over_terrain));

    NativeWorldDeltasV2Limits over_removed;
    over_removed.max_removed_props = NativeFeatureDeltaLimits::MAX_TOMBSTONES + 1U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(malformed, catalog, {}, over_removed));

    NativeWorldDeltasV2Limits over_blocks;
    over_blocks.max_player_blocks = NativePlayerBlocksV2Limits::MAX_BLOCKS + 1U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(malformed, catalog, {}, over_blocks));

    NativeWorldDeltasV2Limits over_total;
    over_total.max_persisted_records = NativeWorldDeltasV2Limits::DEFAULT_MAX_PERSISTED_RECORDS + 1U;
    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        decode_native_world_deltas_v2(malformed, catalog, {}, over_total));
}

VWB_TEST(native_world_deltas_v2_export_is_bound_to_one_immutable_pin) {
    const NativePlayerBlocksV2Catalog catalog = world_delta_catalog();
    const WorldDeltaInitialSnapshot decoded = decode_native_world_deltas_v2(
        payload({}, {block_entry({8, 4, -2})}), catalog, {});
    WorldDeltaStore store({}, decoded);
    const WorldDeltaPinnedSnapshot before = store.pin();

    WorldTypedCellTransaction transaction;
    transaction.transaction_id = "world-deltas-v2:later-terrain";
    transaction.expected_revision = 0U;
    transaction.operations.push_back({
        NativeCellStateNamespace::durable_terrain,
        {32, 6, 32},
        WorldTypedCellOperationKind::set,
        durable_stone({32, 6, 32}, "later"),
    });
    static_cast<void>(store.commit_typed_cells(transaction));
    const WorldDeltaPinnedSnapshot after = store.pin();

    const NativeWorldDeltasV2Payload before_encoded = encode_native_world_deltas_v2(before, catalog);
    const NativeWorldDeltasV2Payload after_encoded = encode_native_world_deltas_v2(after, catalog);
    const WorldDeltaInitialSnapshot before_roundtrip = decode_native_world_deltas_v2(before_encoded, catalog, {});
    const WorldDeltaInitialSnapshot after_roundtrip = decode_native_world_deltas_v2(after_encoded, catalog, {});

    VWB_EXPECT_EQ(1U, before_roundtrip.terrain_volume.durable_snapshot.records().size());
    VWB_EXPECT_EQ(2U, after_roundtrip.terrain_volume.durable_snapshot.records().size());
    VWB_EXPECT_EQ(decoded.feature_delta_snapshot, before_roundtrip.feature_delta_snapshot);
    VWB_EXPECT_EQ(decoded.feature_delta_snapshot, after_roundtrip.feature_delta_snapshot);
    VWB_EXPECT_EQ(0ULL, before_roundtrip.revision);
    VWB_EXPECT_EQ(0ULL, after_roundtrip.revision);
}

VWB_TEST(native_world_deltas_v2_aborts_the_complete_encode_when_a_domain_is_not_exportable) {
    const NativePlayerBlocksV2Catalog import_catalog = world_delta_catalog();
    const WorldDeltaInitialSnapshot decoded = decode_native_world_deltas_v2(
        payload({}, {block_entry({8, 4, -2})}), import_catalog, {});
    const WorldDeltaStore store({}, decoded);
    const NativePlayerBlocksV2Catalog incompatible_export_catalog =
        NativePlayerBlocksV2Catalog::create({{"door", 16U, true}});

    VWB_EXPECT_THROW(NativeWorldDeltasV2Rejected,
        encode_native_world_deltas_v2(store.pin(), incompatible_export_catalog));
}
