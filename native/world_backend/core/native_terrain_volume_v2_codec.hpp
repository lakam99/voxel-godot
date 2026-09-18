#pragma once

#include "native_typed_world_state_snapshot.hpp"
#include "native_value.hpp"

#include <cstddef>
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

struct NativeTerrainVolumeV2Limits final {
    // This is the production durable-record ceiling shared with the default
    // WorldDeltaStore. A section has 16^3 addressable cells, so this limit
    // also bounds the number of nonempty sections without inventing a second
    // independent capacity.
    static constexpr std::size_t MAX_CELLS_PER_SECTION = 16U * 16U * 16U;
    static constexpr std::size_t DEFAULT_MAX_RECORDS = 65536U;

    std::size_t max_records = DEFAULT_MAX_RECORDS;
};

// Validates the complete typed aggregate without converting it through
// NativeValue. This is the production-size admission path: it preserves the
// 65,536-record store capacity and a complete 4,096-cell section while
// enforcing the exact v2 structure and durable-state semantics. The returned
// value owns a freshly re-admitted canonical snapshot.
NativeTerrainVolumeV2 validate_native_terrain_volume_v2(
    const NativeTerrainVolumeV2 &volume,
    NativeTerrainVolumeV2Limits limits = {});

// Decode/encode the already-decoded NativeValue object for SaveSystem v2's
// terrainVolume domain. Both directions require precisely schemaVersion 1 and
// sectionSize 16; unknown fields, generated records, transient overlays, and
// saveDelta=false records fail closed. Player blocks, removed props, and every
// other top-level save domain are deliberately out of scope. NativeValue has
// intentionally small generic recursive-container limits, so these overloads
// are convenience representations rather than the production-size admission
// path. Production adapters must construct the typed aggregate and call
// validate_native_terrain_volume_v2 directly.
NativeTerrainVolumeV2 decode_native_terrain_volume_v2(const NativeValue &value);
NativeValue encode_native_terrain_volume_v2(const NativeTerrainVolumeV2 &volume);

} // namespace voxel::world_backend
