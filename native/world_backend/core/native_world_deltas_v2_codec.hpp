#pragma once

#include "native_player_blocks_v2_codec.hpp"
#include "native_removed_props_v2_codec.hpp"
#include "native_terrain_volume_v2_codec.hpp"
#include "world_delta_store.hpp"

#include <stdexcept>
#include <string>
#include <vector>

namespace voxel::world_backend {

// The three world-delta members written by MainSaveState v2. The typed outer
// value deliberately has no catch-all member: a caller must identify exactly
// terrainVolume, removedProps and blocks before crossing this pure-core
// boundary. Large removed-prop and block domains retain their dedicated typed
// representations instead of inheriting NativeValue's smaller container cap.
struct NativeWorldDeltasV2Payload final {
    NativeValue terrain_volume;
    std::vector<std::string> removed_props;
    std::vector<NativeValue> blocks;
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
    const std::vector<CellCoord> &already_occupied_cells);

// Reads terrain and both feature domains from one immutable WDS pin. Each
// feature domain is projected to a domain-only snapshot before invoking its
// existing strict encoder, so those codecs continue rejecting sibling data.
NativeWorldDeltasV2Payload encode_native_world_deltas_v2(
    const WorldDeltaPinnedSnapshot &snapshot,
    const NativePlayerBlocksV2Catalog &catalog);

} // namespace voxel::world_backend
