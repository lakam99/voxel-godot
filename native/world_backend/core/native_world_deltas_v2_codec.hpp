#pragma once

#include "native_player_blocks_v2_codec.hpp"
#include "native_removed_props_v2_codec.hpp"
#include "native_terrain_volume_v2_codec.hpp"
#include "world_delta_store.hpp"

#include <cstddef>
#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// The three world-delta members written by MainSaveState v2 after their outer
// envelope has been identified. Terrain is already a validated typed aggregate
// at this boundary: routing it back through NativeValue would incorrectly cap
// a complete 4,096-cell section and the supported 65,536-record checkpoint.
// Player blocks remain individually typed NativeValue records until their
// dedicated wire record is introduced, but the outer list has its own bound
// and never becomes one generic recursive value.
struct NativeWorldDeltasV2Payload final {
    NativeTerrainVolumeV2 terrain_volume;
    std::vector<std::string> removed_props;
    std::vector<NativeValue> blocks;
};

struct NativeWorldDeltasV2Limits final {
    static constexpr std::size_t DEFAULT_MAX_PERSISTED_RECORDS =
        WorldDeltaStoreLimits::DEFAULT_MAX_PERSISTED_RECORDS;

    std::size_t max_terrain_records = WorldDeltaStoreLimits::DEFAULT_MAX_DURABLE_TERRAIN_RECORDS;
    std::size_t max_removed_props = WorldDeltaStoreLimits::DEFAULT_MAX_FEATURE_TOMBSTONES;
    std::size_t max_player_blocks = WorldDeltaStoreLimits::DEFAULT_MAX_PLAYER_CREATED_INSTANCES;
    std::size_t max_persisted_records = DEFAULT_MAX_PERSISTED_RECORDS;
};

class NativeWorldDeltasV2Rejected final : public std::invalid_argument {
public:
    NativeWorldDeltasV2Rejected();
};

// Decodes all three domains before publishing a single constructor-ready
// initial snapshot. Any malformed domain aborts the complete operation. The
// persisted terrainVolume revision remains terrain metadata; the returned
// native global revision is always zero and must be selected separately by a
// future save-envelope/runtime owner.
WorldDeltaInitialSnapshot decode_native_world_deltas_v2(
    const NativeWorldDeltasV2Payload &payload,
    const NativePlayerBlocksV2Catalog &catalog,
    const std::vector<CellCoord> &already_occupied_cells,
    NativeWorldDeltasV2Limits limits = {});

// Reads terrain and both feature domains from one immutable WDS pin. Each
// feature domain is projected to a domain-only snapshot before invoking its
// existing strict encoder, so those codecs continue rejecting sibling data.
NativeWorldDeltasV2Payload encode_native_world_deltas_v2(
    const WorldDeltaPinnedSnapshot &snapshot,
    const NativePlayerBlocksV2Catalog &catalog);

} // namespace voxel::world_backend
