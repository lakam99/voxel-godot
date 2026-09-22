#include "native_world_deltas_v2_codec.hpp"

#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() {
    throw NativeWorldDeltasV2Rejected();
}

void validate_limits(const NativeWorldDeltasV2Limits &limits) {
    if (limits.max_terrain_records == 0U
        || limits.max_terrain_records > WorldDeltaStoreLimits::DEFAULT_MAX_DURABLE_TERRAIN_RECORDS
        || limits.max_removed_props == 0U
        || limits.max_removed_props > WorldDeltaStoreLimits::DEFAULT_MAX_FEATURE_TOMBSTONES
        || limits.max_player_blocks == 0U
        || limits.max_player_blocks > WorldDeltaStoreLimits::DEFAULT_MAX_PLAYER_CREATED_INSTANCES
        || limits.max_persisted_records == 0U
        || limits.max_persisted_records > NativeWorldDeltasV2Limits::DEFAULT_MAX_PERSISTED_RECORDS) {
        reject();
    }
}

void preflight_counts(
    const NativeWorldDeltasV2Payload &payload,
    const NativeWorldDeltasV2Limits &limits) {
    validate_limits(limits);
    const std::size_t terrain_count = payload.terrain_volume.durable_snapshot.records().size();
    const std::size_t removed_count = payload.removed_props.size();
    const std::size_t block_count = payload.blocks.size();
    if (terrain_count > limits.max_terrain_records
        || removed_count > limits.max_removed_props
        || block_count > limits.max_player_blocks) {
        reject();
    }
    // Subtraction form makes the combined bound explicit without allowing a
    // size_t addition to wrap before comparison.
    if (terrain_count > limits.max_persisted_records
        || removed_count > limits.max_persisted_records - terrain_count
        || block_count > limits.max_persisted_records - terrain_count - removed_count) {
        reject();
    }
}

} // namespace

NativeWorldDeltasV2Rejected::NativeWorldDeltasV2Rejected()
    : std::invalid_argument("invalid native world deltas v2") {}

WorldDeltaInitialSnapshot decode_native_world_deltas_v2(
    const NativeWorldDeltasV2Payload &payload,
    const NativePlayerBlocksV2Catalog &catalog,
    const std::vector<CellCoord> &already_occupied_cells,
    const NativeWorldDeltasV2Limits limits) {
    try {
        // Counts are checked before any record is inspected, so an oversized
        // sibling domain cannot hide behind (or spend work on) malformed data.
        preflight_counts(payload, limits);
        // Keep all decoded values local until all sibling domains have passed.
        // None of the domain codecs mutates runtime state, so an exception
        // cannot expose a partially imported world snapshot.
        NativeTerrainVolumeV2 terrain = validate_native_terrain_volume_v2(
            payload.terrain_volume, {limits.max_terrain_records});
        NativeFeatureDeltaSnapshot removed = decode_native_removed_props_v2_ids(payload.removed_props);
        NativeFeatureDeltaSnapshot blocks = decode_native_player_blocks_v2(
            payload.blocks, catalog, already_occupied_cells);

        NativeFeatureDeltaSnapshot features = NativeFeatureDeltaSnapshot::create(
            removed.tombstones(), blocks.player_created_instances());

        WorldDeltaInitialSnapshot result;
        // Never assign terrain.revision here. That number is legacy persisted
        // terrain metadata, not the native sequence spanning every domain.
        result.revision = 0U;
        result.terrain_volume = std::move(terrain);
        result.feature_delta_snapshot = std::move(features);
        return result;
    } catch (const std::invalid_argument &) {
        reject();
    }
}

NativeWorldDeltasV2Payload encode_native_world_deltas_v2(
    const WorldDeltaPinnedSnapshot &snapshot,
    const NativePlayerBlocksV2Catalog &catalog) {
    try {
        const NativeFeatureDeltaSnapshot &features = snapshot.feature_delta_snapshot();
        const NativeFeatureDeltaSnapshot removed_only = NativeFeatureDeltaSnapshot::create(
            features.tombstones(), {});
        const NativeFeatureDeltaSnapshot blocks_only = NativeFeatureDeltaSnapshot::create(
            {}, features.player_created_instances());

        return {
            snapshot.terrain_volume(),
            encode_native_removed_props_v2_ids(removed_only),
            encode_native_player_blocks_v2(blocks_only, catalog),
        };
    } catch (const std::invalid_argument &) {
        reject();
    }
}

} // namespace voxel::world_backend
