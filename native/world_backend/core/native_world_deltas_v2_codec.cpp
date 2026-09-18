#include "native_world_deltas_v2_codec.hpp"

#include <utility>

namespace voxel::world_backend {
namespace {

[[noreturn]] void reject() {
    throw NativeWorldDeltasV2Rejected();
}

} // namespace

NativeWorldDeltasV2Rejected::NativeWorldDeltasV2Rejected()
    : std::invalid_argument("invalid native world deltas v2") {}

WorldDeltaInitialSnapshot decode_native_world_deltas_v2(
    const NativeWorldDeltasV2Payload &payload,
    const NativePlayerBlocksV2Catalog &catalog,
    const std::vector<CellCoord> &already_occupied_cells) {
    try {
        // Keep all decoded values local until all sibling domains have passed.
        // None of the domain codecs mutates runtime state, so an exception
        // cannot expose a partially imported world snapshot.
        NativeTerrainVolumeV2 terrain = decode_native_terrain_volume_v2(payload.terrain_volume);
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
            encode_native_terrain_volume_v2(snapshot.terrain_volume()),
            encode_native_removed_props_v2_ids(removed_only),
            encode_native_player_blocks_v2(blocks_only, catalog),
        };
    } catch (const std::invalid_argument &) {
        reject();
    }
}

} // namespace voxel::world_backend
