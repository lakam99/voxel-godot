#pragma once

#include "native_typed_world_state_snapshot.hpp"
#include "native_value.hpp"

#include <cstdint>
#include <stdexcept>
#include <vector>

namespace voxel::world_backend {

// A pure structural representation of the current v2 `terrainVolume` save
// member. It does not parse JSON and does not own a runtime terrain store.
// Section revisions are retained independently because the typed cell snapshot
// intentionally has no section-revision field.
struct NativeTerrainVolumeV2SectionRevision final {
    CellCoord section;
    std::uint64_t revision = 0;

    bool operator==(const NativeTerrainVolumeV2SectionRevision &other) const noexcept;
};

struct NativeTerrainVolumeV2 final {
    std::uint64_t revision = 0;
    NativeTypedWorldStateSnapshot durable_snapshot = NativeTypedWorldStateSnapshot::create({});
    // Canonical z/y/x order. Every record in durable_snapshot has exactly one
    // matching section entry; empty sections are rejected rather than being
    // made into a second persistence representation.
    std::vector<NativeTerrainVolumeV2SectionRevision> section_revisions;

    bool operator==(const NativeTerrainVolumeV2 &other) const noexcept;
};

class NativeTerrainVolumeV2Rejected final : public std::invalid_argument {
public:
    NativeTerrainVolumeV2Rejected();
};

// Decode/encode the already-decoded NativeValue object for SaveSystem v2's
// terrainVolume domain. Both directions require precisely schemaVersion 1 and
// sectionSize 16; unknown fields, generated records, transient overlays, and
// saveDelta=false records fail closed. Player blocks, removed props, and every
// other top-level save domain are deliberately out of scope.
NativeTerrainVolumeV2 decode_native_terrain_volume_v2(const NativeValue &value);
NativeValue encode_native_terrain_volume_v2(const NativeTerrainVolumeV2 &volume);

} // namespace voxel::world_backend
